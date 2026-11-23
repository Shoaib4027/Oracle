------------------------------------------------------------------------------------------------------------------------
--
-- File name:   x9m2_disk.sql
--
-- Purpose:     Exadata X9M-2 disk topology:
--                ASM diskgroup -> ASM disk -> griddisk -> celldisk -> LUN -> physical disk
--
--              Adapted from the idea of Tanel Poder's exadisktopo.sql (tpt-oracle), reworked for X8M/X9M:
--                - RoCE cells: v$cell_config.cellname is an IP pair ("ip1;ip2"), so the cell hostname is shown instead
--                - every join also matches on cellname (no cross-cell matches)
--                - ASM disks are matched by PATH ('o/<cellname>/<griddisk>'), not by griddisk asmDiskName
--                - XMLTABLE instead of deprecated EXTRACTVALUE/XMLSEQUENCE
--                - v$asm_disk_stat / v$asm_diskgroup_stat (no ASM disk rediscovery)
--                - section 2 shows flash (FD_xx) and PMEM (PM_xx) celldisks, which have no ASM disk
--
-- Usage:       @x9m2_disk.sql      (run from a DB or ASM instance on the Exadata compute node)
--
------------------------------------------------------------------------------------------------------------------------

SET LINES 300 PAGES 5000 TRIMSPOOL ON VERIFY OFF FEEDBACK ON

COL cell_host      FOR A16
COL asm_diskgroup  FOR A12
COL asm_disk       FOR A28
COL asm_mode       FOR A8
COL griddisk       FOR A28
COL gd_size        FOR A10
COL celldisk       FOR A16
COL cd_type        FOR A10
COL lun_dev        FOR A12
COL physdisk       FOR A10
COL pd_type        FOR A10
COL slot           FOR A6
COL pd_status      FOR A14

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 1. Top-down: ASM diskgroup -> griddisk -> celldisk -> LUN -> physical disk ====
------------------------------------------------------------------------------------------------------------------------
BREAK ON asm_diskgroup SKIP 1

WITH cfg AS (
  SELECT /*+ MATERIALIZE */ cellname, conftype, XMLTYPE(confval) x
  FROM   v$cell_config
  WHERE  conftype IN ('CELL','PHYSICALDISKS','CELLDISKS','GRIDDISKS','LUNS')
),
cell AS (
  SELECT c.cellname, t.cell_host
  FROM   cfg c, XMLTABLE('/cli-output/cell' PASSING c.x
           COLUMNS cell_host VARCHAR2(64) PATH 'name') t
  WHERE  c.conftype = 'CELL'
),
gd AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/griddisk' PASSING c.x
           COLUMNS gd_name   VARCHAR2(64) PATH 'name',
                   celldisk  VARCHAR2(64) PATH 'cellDisk',
                   asm_name  VARCHAR2(64) PATH 'asmDiskName',
                   gd_size   VARCHAR2(30) PATH 'size',
                   gd_status VARCHAR2(30) PATH 'status') t
  WHERE  c.conftype = 'GRIDDISKS'
),
cd AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/celldisk' PASSING c.x
           COLUMNS cd_name   VARCHAR2(64) PATH 'name',
                   cd_type   VARCHAR2(30) PATH 'diskType',
                   lun       VARCHAR2(64) PATH 'lun',
                   physdisk  VARCHAR2(64) PATH 'physicalDisk',
                   devpart   VARCHAR2(64) PATH 'devicePartition') t
  WHERE  c.conftype = 'CELLDISKS'
),
lun AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/lun' PASSING c.x
           COLUMNS lun_id    VARCHAR2(64) PATH 'id',
                   celldisk  VARCHAR2(64) PATH 'cellDisk',
                   lun_dev   VARCHAR2(64) PATH 'deviceName',
                   wcache    VARCHAR2(40) PATH 'lunWriteCacheMode') t
  WHERE  c.conftype = 'LUNS'
),
pd AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/physicaldisk' PASSING c.x
           COLUMNS pd_id     VARCHAR2(64) PATH 'id',
                   pd_name   VARCHAR2(64) PATH 'name',
                   pd_type   VARCHAR2(30) PATH 'diskType',
                   slot      VARCHAR2(30) PATH 'slotNumber',
                   pd_status VARCHAR2(60) PATH 'status') t
  WHERE  c.conftype = 'PHYSICALDISKS'
)
SELECT adg.name                           asm_diskgroup,
       ad.name                            asm_disk,
       ad.mode_status                     asm_mode,
       gd.gd_name                         griddisk,
       gd.gd_size,
       cd.cd_name                         celldisk,
       cd.cd_type,
       NVL(cell.cell_host, gd.cellname)   cell_host,
       lun.lun_dev,
       pd.pd_name                         physdisk,
       pd.slot,
       SUBSTR(pd.pd_status,1,14)          pd_status
FROM   gd
LEFT JOIN cell ON cell.cellname = gd.cellname
LEFT JOIN v$asm_disk_stat ad
       ON ad.path = 'o/' || gd.cellname || '/' || gd.gd_name
LEFT JOIN v$asm_diskgroup_stat adg ON adg.group_number = ad.group_number
LEFT JOIN cd  ON cd.cellname  = gd.cellname AND cd.cd_name  = gd.celldisk
LEFT JOIN lun ON lun.cellname = cd.cellname AND (lun.celldisk = cd.cd_name OR lun.lun_id = cd.lun)
LEFT JOIN pd  ON pd.cellname  = cd.cellname AND (pd.pd_id = cd.physdisk OR pd.pd_name = cd.physdisk)
ORDER  BY asm_diskgroup, cell_host, celldisk, griddisk;

CLEAR BREAKS

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 2. Bottom-up: physical disk -> LUN -> celldisk -> griddisk -> ASM (includes flash FD_xx and PMEM PM_xx) ====
------------------------------------------------------------------------------------------------------------------------
BREAK ON cell_host SKIP 1

WITH cfg AS (
  SELECT /*+ MATERIALIZE */ cellname, conftype, XMLTYPE(confval) x
  FROM   v$cell_config
  WHERE  conftype IN ('CELL','PHYSICALDISKS','CELLDISKS','GRIDDISKS','LUNS')
),
cell AS (
  SELECT c.cellname, t.cell_host
  FROM   cfg c, XMLTABLE('/cli-output/cell' PASSING c.x
           COLUMNS cell_host VARCHAR2(64) PATH 'name') t
  WHERE  c.conftype = 'CELL'
),
gd AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/griddisk' PASSING c.x
           COLUMNS gd_name   VARCHAR2(64) PATH 'name',
                   celldisk  VARCHAR2(64) PATH 'cellDisk') t
  WHERE  c.conftype = 'GRIDDISKS'
),
cd AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/celldisk' PASSING c.x
           COLUMNS cd_name   VARCHAR2(64) PATH 'name',
                   cd_type   VARCHAR2(30) PATH 'diskType',
                   lun       VARCHAR2(64) PATH 'lun',
                   physdisk  VARCHAR2(64) PATH 'physicalDisk') t
  WHERE  c.conftype = 'CELLDISKS'
),
lun AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/lun' PASSING c.x
           COLUMNS lun_id    VARCHAR2(64) PATH 'id',
                   celldisk  VARCHAR2(64) PATH 'cellDisk',
                   lun_dev   VARCHAR2(64) PATH 'deviceName') t
  WHERE  c.conftype = 'LUNS'
),
pd AS (
  SELECT c.cellname, t.*
  FROM   cfg c, XMLTABLE('/cli-output/physicaldisk' PASSING c.x
           COLUMNS pd_id     VARCHAR2(64) PATH 'id',
                   pd_name   VARCHAR2(64) PATH 'name',
                   pd_type   VARCHAR2(30) PATH 'diskType',
                   slot      VARCHAR2(30) PATH 'slotNumber',
                   pd_status VARCHAR2(60) PATH 'status') t
  WHERE  c.conftype = 'PHYSICALDISKS'
)
SELECT NVL(cell.cell_host, pd.cellname)   cell_host,
       pd.pd_name                         physdisk,
       pd.pd_type,
       pd.slot,
       SUBSTR(pd.pd_status,1,14)          pd_status,
       lun.lun_dev,
       cd.cd_name                         celldisk,
       cd.cd_type,
       gd.gd_name                         griddisk,
       ad.name                            asm_disk,
       adg.name                           asm_diskgroup
FROM   pd
LEFT JOIN cell ON cell.cellname = pd.cellname
LEFT JOIN cd  ON cd.cellname  = pd.cellname AND (cd.physdisk = pd.pd_id OR cd.physdisk = pd.pd_name)
LEFT JOIN lun ON lun.cellname = cd.cellname AND (lun.celldisk = cd.cd_name OR lun.lun_id = cd.lun)
LEFT JOIN gd  ON gd.cellname  = cd.cellname AND gd.celldisk = cd.cd_name
LEFT JOIN v$asm_disk_stat ad
       ON ad.path = 'o/' || gd.cellname || '/' || gd.gd_name
LEFT JOIN v$asm_diskgroup_stat adg ON adg.group_number = ad.group_number
ORDER  BY cell_host, pd.pd_type, celldisk, griddisk;

CLEAR BREAKS

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 3. Diagnostics (if sections 1/2 show empty columns or errors) ====
------------------------------------------------------------------------------------------------------------------------
COL cellname FOR A40
COL conftype FOR A20
COL path     FOR A70

PROMPT -- 3a. Config types available per cell (all of CELL, CELLDISKS, GRIDDISKS, LUNS, PHYSICALDISKS should exist)
SELECT cellname, conftype, DBMS_LOB.GETLENGTH(confval) len
FROM   v$cell_config
ORDER  BY cellname, conftype;

PROMPT -- 3b. ASM disk path format (expected: o/<cell ip1;ip2>/<griddisk name>)
SELECT path, name FROM v$asm_disk_stat WHERE ROWNUM <= 5;

PROMPT -- 3c. Raw XML sample of one GRIDDISKS entry (check element names)
SET LONG 4000
SELECT DBMS_LOB.SUBSTR(confval, 2000, 1) griddisk_xml
FROM   v$cell_config
WHERE  conftype = 'GRIDDISKS' AND ROWNUM = 1;
