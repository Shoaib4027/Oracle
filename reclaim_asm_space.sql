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
            AND    l.partition_name = p.partition_name),'')||
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
            FROM dba_lobs l WHERE l.owner = t.owner AND l.table_name = t.table_name),'')||
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
