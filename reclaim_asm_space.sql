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
