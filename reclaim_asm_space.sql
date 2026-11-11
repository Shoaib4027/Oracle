-- =============================================================
-- Reclaim space in an ASM diskgroup after dropping tables
-- Run as SYSDBA. Review every statement before executing.
-- Take a backup first.
-- =============================================================

-- -------------------------------------------------------------
-- 1. Purge the recycle bin
-- -------------------------------------------------------------
SELECT COUNT(*) FROM dba_recyclebin;
PURGE DBA_RECYCLEBIN;

-- -------------------------------------------------------------
-- 2. Datafile sizes and how far each can shrink
-- -------------------------------------------------------------
SELECT file_id, file_name, tablespace_name, ROUND(bytes/1024/1024/1024) size_gb
FROM   dba_data_files
ORDER  BY tablespace_name, file_id;

-- Minimum size each file can shrink to (replace 8192 with your block size)
SELECT a.file_id, a.file_name,
       CEIL((NVL(b.hwm,1) * 8192)/1024/1024) smallest_mb,
       CEIL(a.bytes/1024/1024)               current_mb
FROM   dba_data_files a
LEFT JOIN (SELECT file_id, MAX(block_id + blocks - 1) hwm
           FROM   dba_extents
           GROUP  BY file_id) b
       ON a.file_id = b.file_id
ORDER  BY a.file_id;

-- Space still used per tablespace
SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024/1024, 2) gb
FROM   dba_segments
GROUP  BY tablespace_name
ORDER  BY gb DESC;

-- -------------------------------------------------------------
-- 3. Reclaim the space
-- -------------------------------------------------------------

-- 3A. Datafile is completely empty (e.g. the new 31g file): drop it
ALTER TABLESPACE <ts_name> DROP DATAFILE '<+DG/path/file>';
-- Fails if it is the first file of the tablespace or holds any extents.

-- 3B. Free space is at the end of the file: resize down
ALTER DATABASE DATAFILE '<file>' RESIZE 100G;   -- any size >= smallest_mb

-- 3C. Extents scattered (ORA-03297): move objects to a new tablespace
CREATE TABLESPACE new_ts DATAFILE '+DATA' SIZE 50G AUTOEXTEND ON;
ALTER TABLE owner.t MOVE ONLINE TABLESPACE new_ts;       -- 12.2+ online
ALTER INDEX owner.i REBUILD ONLINE TABLESPACE new_ts;
ALTER TABLE owner.t MOVE LOB(col) STORE AS (TABLESPACE new_ts);  -- LOB columns
DROP TABLESPACE old_ts INCLUDING CONTENTS AND DATAFILES;

-- Alternative to moving: shrink segments in place, then retry the resize
ALTER TABLE owner.t ENABLE ROW MOVEMENT;
ALTER TABLE owner.t SHRINK SPACE;

-- 3D. Whole tablespace no longer needed
DROP TABLESPACE <ts> INCLUDING CONTENTS AND DATAFILES;

-- -------------------------------------------------------------
-- 4. Verify diskgroup free space
-- -------------------------------------------------------------
SELECT name, total_mb, free_mb, usable_file_mb FROM v$asm_diskgroup;
-- Shell: asmcmd lsdg

-- -------------------------------------------------------------
-- Notes
-- -------------------------------------------------------------
-- Oracle never shrinks datafiles automatically, even with autoextend off.
-- If in ARCHIVELOG mode, check the FRA: SELECT * FROM v$recovery_file_dest;
--   and run in RMAN: DELETE OBSOLETE;

-- =============================================================
-- 5. Generate statements for many datafiles (large databases)
-- Run inside the PDB. Review the spooled files before running them.
-- Do drops in batches in a quiet window; check v$asm_diskgroup between batches.
-- dba_extents can be very slow on huge databases; if so, use dba_free_space
-- and treat a file as empty when free bytes are within a few MB of its size.
-- =============================================================

-- 5A. Drop statements for datafiles that hold no extents
SET PAGESIZE 0 LINESIZE 300 FEEDBACK OFF
SPOOL drop_empty_datafiles.sql
SELECT 'ALTER TABLESPACE '||d.tablespace_name||
       ' DROP DATAFILE '''||d.file_name||''';'
FROM   dba_data_files d
WHERE  d.tablespace_name NOT IN ('SYSTEM','SYSAUX')
AND    d.tablespace_name NOT LIKE 'UNDO%'
AND    d.file_id <> (SELECT MIN(x.file_id) FROM dba_data_files x
                     WHERE x.tablespace_name = d.tablespace_name)
AND    NOT EXISTS (SELECT 1 FROM dba_extents e WHERE e.file_id = d.file_id);
SPOOL OFF

-- 5B. Resize statements for non-empty files (down to highest used block)
SPOOL resize_datafiles.sql
SELECT 'ALTER DATABASE DATAFILE '''||a.file_name||''' RESIZE '||
       (CEIL(NVL(b.hwm,1)*(SELECT value FROM v$parameter WHERE name='db_block_size')/1024/1024)+1)||'M;'
FROM   dba_data_files a
JOIN  (SELECT file_id, MAX(block_id+blocks-1) hwm FROM dba_extents GROUP BY file_id) b
  ON   a.file_id = b.file_id
WHERE  a.bytes/1024/1024 > CEIL(b.hwm*8192/1024/1024)+1024;   -- only if it frees >1 GB (8192 = block size)
SPOOL OFF

-- =============================================================
-- 6. Find which segments sit at the highest used block (block the shrink)
-- dba_extents is slow on huge databases: filter by tablespace, one at a time.
-- Replace 8192 with your block size. Do not move undo segments (TYPE2 UNDO);
-- handle undo by switching to a new undo tablespace.
-- After moving/shrinking a blocking segment, rerun section 2 and resize.
-- =============================================================

-- 6A. Last extents of one file (first row = segment holding the highest used block)
SELECT owner, segment_name, partition_name, segment_type,
       block_id, blocks,
       ROUND(blocks*8192/1024/1024) extent_mb
FROM   dba_extents
WHERE  file_id = <file_id>
ORDER  BY block_id DESC
FETCH FIRST 10 ROWS ONLY;

-- 6B. Blocking segment for every file in a tablespace
SELECT file_id, owner, segment_name, partition_name, segment_type,
       block_id + blocks - 1 AS hwm_block
FROM  (SELECT e.*,
              ROW_NUMBER() OVER (PARTITION BY file_id ORDER BY block_id DESC) rn
       FROM   dba_extents e
       WHERE  tablespace_name = '<TABLESPACE>')
WHERE  rn = 1
ORDER  BY file_id;

-- 6C. Segments blocking the most files (move these first)
SELECT owner, segment_name, segment_type, COUNT(*) files_blocked
FROM  (SELECT e.*,
              ROW_NUMBER() OVER (PARTITION BY file_id ORDER BY block_id DESC) rn
       FROM   dba_extents e
       WHERE  tablespace_name = '<TABLESPACE>')
WHERE  rn = 1
GROUP  BY owner, segment_name, segment_type
ORDER  BY files_blocked DESC;

-- Fixes by segment type:
--   table : ALTER TABLE owner.t MOVE ONLINE TABLESPACE new_ts;
--   index : ALTER INDEX owner.i REBUILD ONLINE TABLESPACE new_ts;
--   LOB   : ALTER TABLE owner.t MOVE LOB(col) STORE AS (TABLESPACE new_ts);

-- =============================================================
-- 7. IIB_ARCH_TBS_NEW1: move the blocking segments (Oracle 19c, RU 19.32)
-- Source tablespace : IIB_ARCH_TBS_NEW1
-- Destination       : IIB_ARCH_TBS (about 10 TB free; IIB_ARCH_TBS_NEW is similar)
-- Run 7A and 7B first and send the output; the move script is built from it.
-- ONLINE partition move is supported in 19c; the ONLINE keyword goes LAST.
-- =============================================================

-- 7A. Size of every blocking segment (how much data will be moved)
SELECT owner, segment_name, partition_name, segment_type,
       ROUND(SUM(bytes)/1024/1024/1024) gb
FROM   dba_segments
WHERE  tablespace_name = 'IIB_ARCH_TBS_NEW1'
AND    owner = 'IIBARCH'
AND   (segment_name IN ('BACKEND_PROCESSING_LOG_2022C','API_PROCESS_CLOBDET_2022_1',
                        'ORCH_API_DETAILS_2023_2C','API_DETAILS_23C','API_LOG_2023_2C',
                        'BACKEND_PROCESSING_LOG_2023_2C','API_DETAILS_23_2C',
                        'BACKEND_DETAILS_CLOB_23_2C','API_DETAILS_CLOB_2023C')
    OR   segment_name LIKE 'SYS_LOB00010299%' OR segment_name LIKE 'SYS_LOB00010300%'
    OR   segment_name LIKE 'SYS_LOB00009277%' OR segment_name LIKE 'SYS_LOB00009337%')
GROUP  BY owner, segment_name, partition_name, segment_type
ORDER  BY gb DESC;

-- 7B. Map the SYS_LOB segments to their parent table and column
SELECT owner, table_name, column_name, segment_name
FROM   dba_lobs
WHERE  segment_name IN ('SYS_LOB0001029983C00004$$','SYS_LOB0001030079C00006$$',
       'SYS_LOB0001030079C00004$$','SYS_LOB0000927654C00006$$','SYS_LOB0000933731C00006$$',
       'SYS_LOB0001030079C00005$$','SYS_LOB0001030040C00005$$','SYS_LOB0000927654C00005$$',
       'SYS_LOB0001030040C00004$$','SYS_LOB0001029983C00003$$');

-- 7C. Generate partition moves (table partition + its LOB partitions together)
SET LINES 300 PAGES 0 FEEDBACK OFF LONG 100000
DEFINE dest=IIB_ARCH_TBS
SPOOL move_partitions.sql
SELECT 'ALTER TABLE '||p.table_owner||'.'||p.table_name||
       ' MOVE PARTITION '||p.partition_name||' TABLESPACE &dest'||
       NVL((SELECT ' '||LISTAGG('LOB ('||l.column_name||') STORE AS (TABLESPACE &dest)',' ')
                        WITHIN GROUP (ORDER BY l.column_name)
            FROM   dba_lob_partitions l
            WHERE  l.table_owner = p.table_owner AND l.table_name = p.table_name
            AND    l.partition_name = p.partition_name
            AND    NOT EXISTS (SELECT 1 FROM dba_tab_columns c WHERE c.owner = l.table_owner AND c.table_name = l.table_name
                                   AND c.column_name = l.column_name AND c.data_type IN ('VARCHAR2','NVARCHAR2','RAW')
                                   AND c.data_length > 4000)),'')||
       ' UPDATE INDEXES PARALLEL 4 ONLINE;' AS stmt
FROM   dba_tab_partitions p
WHERE  p.table_owner = 'IIBARCH'
AND    p.tablespace_name = 'IIB_ARCH_TBS_NEW1'
AND    p.table_name IN ('BACKEND_PROCESSING_LOG_2022C','ORCH_API_DETAILS_2023_2C',
       'API_DETAILS_23C','API_LOG_2023_2C','BACKEND_PROCESSING_LOG_2023_2C',
       'API_DETAILS_23_2C','BACKEND_DETAILS_CLOB_23_2C','API_DETAILS_CLOB_2023C')
ORDER  BY p.table_name, p.partition_position;
SPOOL OFF

-- 7C-2. LOB partitions still in NEW1 whose table partition is already elsewhere
SELECT table_owner, table_name, partition_name, column_name, lob_partition_name
FROM   dba_lob_partitions
WHERE  tablespace_name = 'IIB_ARCH_TBS_NEW1' AND table_owner = 'IIBARCH'
AND    (table_owner, table_name, partition_name) NOT IN
       (SELECT table_owner, table_name, partition_name FROM dba_tab_partitions
        WHERE tablespace_name = 'IIB_ARCH_TBS_NEW1');
-- Fix: ALTER TABLE owner.t MOVE PARTITION p LOB (col) STORE AS (TABLESPACE &dest) ONLINE;

-- 7C-3. Subpartitioned tables (check if anything is returned)
SELECT table_owner, table_name, COUNT(*) FROM dba_tab_subpartitions
WHERE  tablespace_name = 'IIB_ARCH_TBS_NEW1' GROUP BY table_owner, table_name;

-- 7D. Non-partitioned tables (API_PROCESS_CLOBDET_2022_1 blocks 79 files)
SPOOL move_tables.sql
SELECT 'ALTER TABLE '||t.owner||'.'||t.table_name||' MOVE ONLINE TABLESPACE &dest'||
       NVL((SELECT ' '||LISTAGG('LOB ('||l.column_name||') STORE AS (TABLESPACE &dest)',' ')
                        WITHIN GROUP (ORDER BY l.column_name)
            FROM dba_lobs l WHERE l.owner = t.owner AND l.table_name = t.table_name
            AND    NOT EXISTS (SELECT 1 FROM dba_tab_columns c WHERE c.owner = l.owner AND c.table_name = l.table_name
                                   AND c.column_name = l.column_name AND c.data_type IN ('VARCHAR2','NVARCHAR2','RAW')
                                   AND c.data_length > 4000)),'')||
       ' PARALLEL 4;'
FROM   dba_tables t
WHERE  t.tablespace_name = 'IIB_ARCH_TBS_NEW1'
AND    t.table_name IN ('API_PROCESS_CLOBDET_2022_1','EVC_UNIQUE_REQUEST_ID_ARC2',
                        'PMSBY_JS_FEED_MASTER');
SPOOL OFF
-- Indexes: ALTER INDEX owner.PMSBY_TXN_MASTER_25_PK1 REBUILD TABLESPACE &dest ONLINE;
--          ALTER INDEX owner.<idx> REBUILD PARTITION <p> TABLESPACE &dest ONLINE;

-- 7E. After the moves: rerun 6B/6C, check for unusable indexes, then resize
SELECT index_owner, index_name, partition_name FROM dba_ind_partitions WHERE status='UNUSABLE';
SELECT owner, index_name FROM dba_indexes WHERE status='UNUSABLE';

SPOOL resize_new1.sql
SELECT 'ALTER DATABASE DATAFILE '''||f.file_name||''' RESIZE '||
       CEIL((NVL(e.hwm,1) * t.block_size)/1024/1024 + 10)||'M;'
FROM   dba_data_files f
JOIN   dba_tablespaces t ON t.tablespace_name = f.tablespace_name
LEFT JOIN (SELECT file_id, MAX(block_id + blocks - 1) hwm
           FROM dba_extents WHERE tablespace_name = 'IIB_ARCH_TBS_NEW1'
           GROUP BY file_id) e ON e.file_id = f.file_id
WHERE  f.tablespace_name = 'IIB_ARCH_TBS_NEW1'
AND    f.bytes/1024/1024 > CEIL((NVL(e.hwm,1) * t.block_size)/1024/1024 + 10);
SPOOL OFF
-- Files with no extents left can be dropped:
--   ALTER TABLESPACE IIB_ARCH_TBS_NEW1 DROP DATAFILE '<file>';
-- Move in batches; check archive/FRA space and v$asm_diskgroup between batches.

-- =============================================================
-- 8. Follow-up after 7A/7B output (about 4.2 TB of blockers, fits in IIB_ARCH_TBS)
-- Run 7C (table partitions + LOBs) and 7D first, then 8A for LOB-only partitions.
-- =============================================================

-- 8A. LOB partitions in NEW1 whose table partition is already in another
-- tablespace (e.g. API_DETAILS_CLOB_2023C SYS_LOB_P54376/P52851, 246 GB).
-- Moves only the LOB segment; test on a small partition first.
SPOOL move_lob_only.sql
SELECT 'ALTER TABLE '||l.table_owner||'.'||l.table_name||' MOVE PARTITION '||
       l.partition_name||' LOB ('||l.column_name||') STORE AS (TABLESPACE &dest);'
FROM   dba_lob_partitions l
WHERE  l.table_owner = 'IIBARCH'
AND    l.tablespace_name = 'IIB_ARCH_TBS_NEW1'
AND    l.table_name NOT LIKE 'BIN$%'
AND    NOT EXISTS (SELECT 1 FROM dba_tab_columns c WHERE c.owner = l.table_owner AND c.table_name = l.table_name
                       AND c.column_name = l.column_name AND c.data_type IN ('VARCHAR2','NVARCHAR2','RAW')
                       AND c.data_length > 4000)   -- skip recycle bin objects
AND    NOT EXISTS (SELECT 1 FROM dba_tab_partitions p
                   WHERE  p.table_owner = l.table_owner AND p.table_name = l.table_name
                   AND    p.partition_name = l.partition_name
                   AND    p.tablespace_name = 'IIB_ARCH_TBS_NEW1')
ORDER  BY l.table_name, l.partition_name, l.column_name;
SPOOL OFF

-- 8B. Everything else left in NEW1 after the moves (next round of blockers)
SELECT owner, segment_type, ROUND(SUM(bytes)/1024/1024/1024) gb
FROM   dba_segments
WHERE  tablespace_name = 'IIB_ARCH_TBS_NEW1'
GROUP  BY owner, segment_type
ORDER  BY gb DESC;

-- 8C. Index segments of the moved tables that are still in NEW1
SELECT i.owner, i.index_name, i.table_name, s.segment_type, ROUND(SUM(s.bytes)/1024/1024/1024) gb
FROM   dba_indexes i
JOIN   dba_segments s ON s.owner = i.owner AND s.segment_name = i.index_name
WHERE  s.tablespace_name = 'IIB_ARCH_TBS_NEW1'
GROUP  BY i.owner, i.index_name, i.table_name, s.segment_type
ORDER  BY gb DESC;

-- =============================================================
-- 9. Is the data already compressed? Can we compress while moving?
-- Run 9A-9C and send the output. 9D estimates savings on one small partition.
-- LICENSE: BASIC table compression is included in Enterprise Edition.
--   ROW STORE COMPRESS ADVANCED and SecureFile LOB compression/dedup
--   need the Advanced Compression Option.
-- =============================================================

-- 9A. Table compression status
SELECT table_name, partition_name, compression, compress_for
FROM   dba_tab_partitions
WHERE  table_owner = 'IIBARCH' AND tablespace_name = 'IIB_ARCH_TBS_NEW1'
ORDER  BY table_name, partition_position;

SELECT table_name, compression, compress_for
FROM   dba_tables
WHERE  owner = 'IIBARCH'
AND    table_name IN ('API_PROCESS_CLOBDET_2022_1','EVC_UNIQUE_REQUEST_ID_ARC2');

-- 9B. LOB partitions: BasicFile or SecureFile, compressed or not
SELECT table_name, column_name, securefile, compression, deduplication,
       COUNT(*) lob_partitions
FROM   dba_lob_partitions
WHERE  table_owner = 'IIBARCH' AND tablespace_name = 'IIB_ARCH_TBS_NEW1'
GROUP  BY table_name, column_name, securefile, compression, deduplication
ORDER  BY table_name, column_name;

SELECT table_name, column_name, securefile, compression, deduplication, in_row
FROM   dba_lobs
WHERE  owner = 'IIBARCH' AND table_name = 'API_PROCESS_CLOBDET_2022_1';

-- 9C. Destination must be ASSM for SecureFile LOBs
SELECT tablespace_name, segment_space_management, block_size
FROM   dba_tablespaces
WHERE  tablespace_name IN ('IIB_ARCH_TBS','IIB_ARCH_TBS_NEW','IIB_ARCH_TBS_NEW1');

-- 9D. Estimate savings on one small partition (needs a scratch tablespace, e.g. USERS)
SET SERVEROUTPUT ON
DECLARE
  l_blk_cmp PLS_INTEGER; l_blk_uncmp PLS_INTEGER; l_rows_cmp PLS_INTEGER;
  l_rows_uncmp PLS_INTEGER; l_ratio NUMBER; l_str VARCHAR2(200); l_lobcnt PLS_INTEGER;
BEGIN
  -- table partition, BASIC compression
  DBMS_COMPRESSION.GET_COMPRESSION_RATIO('USERS','IIBARCH','BACKEND_DETAILS_CLOB_23_2C','JUN_23',
      DBMS_COMPRESSION.COMP_BASIC, l_blk_cmp, l_blk_uncmp, l_rows_cmp, l_rows_uncmp,
      l_ratio, l_str, 1000000);
  DBMS_OUTPUT.PUT_LINE('TABLE '||l_str||' ratio='||l_ratio);
  -- LOB, SecureFile MEDIUM (replace partition with a small one from 7A)
  DBMS_COMPRESSION.GET_COMPRESSION_RATIO('USERS','IIBARCH','BACKEND_DETAILS_CLOB_23_2C',
      'OUTPUT_DATA','JUN_23', DBMS_COMPRESSION.COMP_LOB_MEDIUM,
      l_blk_cmp, l_blk_uncmp, l_lobcnt, l_ratio, l_str, 1000);
  DBMS_OUTPUT.PUT_LINE('LOB   '||l_str||' ratio='||l_ratio);
END;
/

-- 9E. Move syntax with compression (use after 9A-9D)
-- Table partition, BASIC (archive data only; later DML is not recompressed):
--   ALTER TABLE owner.t MOVE PARTITION p TABLESPACE &dest ROW STORE COMPRESS BASIC
--     LOB (col) STORE AS SECUREFILE (TABLESPACE &dest COMPRESS MEDIUM)
--     UPDATE INDEXES PARALLEL 4 ONLINE;
-- LOB-only move with compression:
--   ALTER TABLE owner.t MOVE PARTITION p
--     LOB (col) STORE AS SECUREFILE (TABLESPACE &dest COMPRESS MEDIUM);

-- =============================================================
-- 10. Findings from section 9 output
--  * Table partitions already HCC (QUERY HIGH) or ADVANCED: keep that setting.
--  * Nearly all LOBs are SecureFile but NOT compressed (HCC does not cover LOBs).
--  * API_PROCESS_CLOBDET_2022_1 (159 GB) has no table compression.
--  * NEW1 holds many BIN$ (recycle bin) partitions from 2020 tables: check and
--    purge them instead of moving them.
-- No ONLINE below: HCC + online move is not assumed to work; archive data is idle.
-- Test on a small partition first (e.g. API_DETAILS_CLOB_2023C JAN_23, 2 GB).
-- =============================================================

-- 10A. Recycle bin objects in NEW1 (confirm they are not needed, then purge)
SELECT owner, original_name, type, COUNT(*) objs,
       ROUND(SUM(space)*8192/1024/1024/1024) gb
FROM   dba_recyclebin
WHERE  ts_name = 'IIB_ARCH_TBS_NEW1'
GROUP  BY owner, original_name, type
ORDER  BY gb DESC;

SELECT ROUND(SUM(bytes)/1024/1024/1024) bin_gb
FROM   dba_segments
WHERE  tablespace_name = 'IIB_ARCH_TBS_NEW1' AND segment_name LIKE 'BIN$%';
-- PURGE TABLESPACE IIB_ARCH_TBS_NEW1;      -- irreversible; removes flashback ability

-- 10B. Partition moves keeping each table partition's compression, LOBs compressed
DEFINE dest=IIB_ARCH_TBS
SPOOL move_partitions_compress.sql
SELECT 'ALTER TABLE '||p.table_owner||'.'||p.table_name||
       ' MOVE PARTITION '||p.partition_name||' TABLESPACE &dest'||
       CASE WHEN p.compression = 'ENABLED' THEN
              CASE WHEN p.compress_for IN ('BASIC','ADVANCED')
                   THEN ' ROW STORE COMPRESS '||p.compress_for
                   ELSE ' COMPRESS FOR '||p.compress_for END
       END||
       NVL((SELECT ' '||LISTAGG('LOB ('||l.column_name||
                   ') STORE AS SECUREFILE (TABLESPACE &dest COMPRESS HIGH)',' ')
                   WITHIN GROUP (ORDER BY l.column_name)
            FROM   dba_lob_partitions l
            WHERE  l.table_owner = p.table_owner AND l.table_name = p.table_name
            AND    l.partition_name = p.partition_name
            AND    NOT EXISTS (SELECT 1 FROM dba_tab_columns c WHERE c.owner = l.table_owner AND c.table_name = l.table_name
                                   AND c.column_name = l.column_name AND c.data_type IN ('VARCHAR2','NVARCHAR2','RAW')
                                   AND c.data_length > 4000)),'')||
       ' UPDATE INDEXES PARALLEL 4;' AS stmt
FROM   dba_tab_partitions p
WHERE  p.table_owner = 'IIBARCH'
AND    p.tablespace_name = 'IIB_ARCH_TBS_NEW1'
AND    p.table_name IN ('BACKEND_PROCESSING_LOG_2022C','ORCH_API_DETAILS_2023_2C',
       'API_DETAILS_23C','API_LOG_2023_2C','BACKEND_PROCESSING_LOG_2023_2C',
       'API_DETAILS_23_2C','BACKEND_DETAILS_CLOB_23_2C','API_DETAILS_CLOB_2023C')
ORDER  BY p.table_name, p.partition_position;
SPOOL OFF

-- 10C. LOB-only partitions, compressed (replaces 8A when compressing)
SPOOL move_lob_only_compress.sql
SELECT 'ALTER TABLE '||l.table_owner||'.'||l.table_name||' MOVE PARTITION '||
       l.partition_name||' LOB ('||l.column_name||
       ') STORE AS SECUREFILE (TABLESPACE &dest COMPRESS HIGH);'
FROM   dba_lob_partitions l
WHERE  l.table_owner = 'IIBARCH'
AND    l.tablespace_name = 'IIB_ARCH_TBS_NEW1'
AND    l.table_name NOT LIKE 'BIN$%'
AND    NOT EXISTS (SELECT 1 FROM dba_tab_columns c WHERE c.owner = l.table_owner AND c.table_name = l.table_name
                       AND c.column_name = l.column_name AND c.data_type IN ('VARCHAR2','NVARCHAR2','RAW')
                       AND c.data_length > 4000)
AND    NOT EXISTS (SELECT 1 FROM dba_tab_partitions p
                   WHERE  p.table_owner = l.table_owner AND p.table_name = l.table_name
                   AND    p.partition_name = l.partition_name
                   AND    p.tablespace_name = 'IIB_ARCH_TBS_NEW1')
ORDER  BY l.table_name, l.partition_name, l.column_name;
SPOOL OFF

-- 10D. Non-partitioned API_PROCESS_CLOBDET_2022_1: add HCC + LOB compression
-- (check the ratio with 9D first; its LOBs are in-row, small LOBs are not compressed)
ALTER TABLE IIBARCH.API_PROCESS_CLOBDET_2022_1 MOVE TABLESPACE &dest COMPRESS FOR QUERY HIGH
  LOB (REQUEST)   STORE AS SECUREFILE (TABLESPACE &dest COMPRESS HIGH)
  LOB (RESPONSE)  STORE AS SECUREFILE (TABLESPACE &dest COMPRESS HIGH)
  LOB (EXCEPTION) STORE AS SECUREFILE (TABLESPACE &dest COMPRESS HIGH)
  UPDATE INDEXES PARALLEL 4;

-- =============================================================
-- 11. Extended data types (MAX_STRING_SIZE=EXTENDED): ORA-14692
-- VARCHAR2(32767) columns are stored in hidden SecureFile LOBs. They appear in
-- dba_lobs/dba_lob_partitions but STORE AS is NOT allowed for them, so the
-- generators above now skip them. List them:
-- =============================================================
SELECT owner, table_name, column_name, data_type, data_length
FROM   dba_tab_columns
WHERE  owner = 'IIBARCH' AND data_type IN ('VARCHAR2','NVARCHAR2','RAW') AND data_length > 4000
ORDER  BY table_name, column_name;

-- After moving a partition, confirm the hidden LOB segments followed the table
-- (if any still show IIB_ARCH_TBS_NEW1 they will keep blocking the datafiles):
SELECT column_name, lob_partition_name, tablespace_name, compression
FROM   dba_lob_partitions
WHERE  table_owner = 'IIBARCH' AND table_name = 'API_DETAILS_CLOB_2023C'
AND    partition_name = 'JAN_23'
ORDER  BY column_name;
