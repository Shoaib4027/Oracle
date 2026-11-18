-- orphans.sql
-- Investigate ASM diskgroup usable space / orphaned files (NORMAL redundancy)
-- Run on the ASM instance as SYSASM. Set the diskgroup below.
--
-- USABLE_FILE_MB = (FREE_MB - REQUIRED_MIRROR_FREE_MB) / 2   (normal redundancy)
-- REQUIRED_MIRROR_FREE_MB = space reserved to re-mirror the largest failgroup/disk,
-- so a big gap between FREE and USABLE is usually NOT orphan files.

DEFINE ASMGROUP="ARCHDATA"

set linesize 250 pagesize 500 verify off
col name format a60
col type format a20
col dbname format a30
col failgroup format a30

PROMPT ===== 1. Diskgroup free vs usable vs required mirror free (GB) =====
SELECT name, type, total_mb/1024 total_gb, free_mb/1024 free_gb,
       required_mirror_free_mb/1024 req_mirror_gb,
       usable_file_mb/1024 usable_gb, offline_disks
FROM v$asm_diskgroup WHERE name='&ASMGROUP';

PROMPT ===== 2. Failgroup layout (uneven failgroups raise the reserve) =====
SELECT failgroup, COUNT(*) disks, ROUND(SUM(total_mb)/1024) total_gb,
       ROUND(SUM(free_mb)/1024) free_gb
FROM v$asm_disk
WHERE group_number=(SELECT group_number FROM v$asm_diskgroup WHERE name='&ASMGROUP')
GROUP BY failgroup ORDER BY 1;

PROMPT ===== 3. Rebalance running? =====
SELECT * FROM v$asm_operation;

PROMPT ===== 4. Offline / missing disks? =====
SELECT mode_status, state, COUNT(*) cnt FROM v$asm_disk
WHERE group_number=(SELECT group_number FROM v$asm_diskgroup WHERE name='&ASMGROUP')
GROUP BY mode_status, state;

PROMPT ===== 5. Top 50 files by allocated space =====
SELECT SUBSTR(a.name,1,60) name, f.type, ROUND(f.bytes/1024/1024/1024,2) gb,
       ROUND(f.space/1024/1024/1024,2) alloc_gb
FROM v$asm_file f JOIN v$asm_alias a
  ON f.group_number=a.group_number AND f.file_number=a.file_number
WHERE f.group_number=(SELECT group_number FROM v$asm_diskgroup WHERE name='&ASMGROUP')
  AND a.system_created='Y'
ORDER BY f.space DESC FETCH FIRST 50 ROWS ONLY;

PROMPT ===== 6. Allocated space by database directory and file type (GB) =====
SELECT REGEXP_SUBSTR(a.name,'^[^/]+') dbname, f.type,
       ROUND(SUM(f.space)/1024/1024/1024) alloc_gb
FROM v$asm_file f JOIN v$asm_alias a
  ON f.group_number=a.group_number AND f.file_number=a.file_number
WHERE f.group_number=(SELECT group_number FROM v$asm_diskgroup WHERE name='&ASMGROUP')
  AND a.system_created='Y'
GROUP BY REGEXP_SUBSTR(a.name,'^[^/]+'), f.type ORDER BY 3 DESC;

PROMPT ===== 7. Run in EACH database using this diskgroup (compare with step 5/6) =====
PROMPT Files in ASM but missing from this output are orphan candidates.
PROMPT
PROMPT SELECT 'ARCHLOG' t, name FROM v$archived_log WHERE deleted='NO' AND name LIKE '+&ASMGROUP%'
PROMPT UNION ALL SELECT 'DATAFILE', name FROM v$datafile WHERE name LIKE '+&ASMGROUP%'
PROMPT UNION ALL SELECT 'TEMPFILE', name FROM v$tempfile WHERE name LIKE '+&ASMGROUP%'
PROMPT UNION ALL SELECT 'BACKUP', handle FROM v$backup_piece WHERE handle LIKE '+&ASMGROUP%';

PROMPT ===== 8. RMAN checks (run in each database) =====
PROMPT RMAN> crosscheck archivelog all;
PROMPT RMAN> list expired archivelog all;
PROMPT RMAN> report obsolete;

PROMPT ===== asmcmd (OS level) =====
PROMPT asmcmd du +&ASMGROUP/*
PROMPT asmcmd ls +&ASMGROUP
PROMPT
PROMPT WARNING: do not rm anything in ASM until verified orphaned.
