------------------------------------------------------------------------------------------------------------------------
--
-- File name:   x9m2_disk.sql  (v2)
--
-- Purpose:     Exadata X9M-2 disk topology:
--                ASM diskgroup -> ASM disk -> griddisk -> celldisk -> LUN -> physical disk
--
--              Adapted from the idea of Tanel Poder's exadisktopo.sql (tpt-oracle), reworked for X8M/X9M:
--                - RoCE cells: v$cell_config.cellname is an IP pair ("ip1;ip2"), so the cell hostname is shown instead
--                - every join also matches on cellname (no cross-cell matches)
--                - ASM disks are matched by PATH ('o/<cellname>/<griddisk>')
--                - celldisk -> LUN -> physical disk joins try several keys (id, name, device, physicalDrives)
--                - XMLTABLE instead of deprecated EXTRACTVALUE/XMLSEQUENCE
--                - v$asm_disk_stat / v$asm_diskgroup_stat (no ASM disk rediscovery)
--
-- Sections:    1. Top-down topology (griddisks in ASM)
--              2. Bottom-up topology (all physical disks incl. flash FD_xx / PMEM PM_xx)
--              3. ASM-only view per diskgroup/cell  (covers cells NOT visible in v$cell_config)
--              4. Diagnostics: cells visible, raw XML of CELLDISKS / LUNS / PHYSICALDISKS
--
-- Note:        v$cell_config only lists the cells this instance has config for. If section 3 shows
--              cells/diskgroups missing from section 1, run this script from the ASM instance (+ASMn).
--
-- Usage:       @x9m2_disk.sql
--
------------------------------------------------------------------------------------------------------------------------

SET LINES 400 PAGES 5000 TRIMSPOOL ON TRIMOUT ON VERIFY OFF FEEDBACK ON LONG 4000

COL cell_host      FOR A16
COL asm_diskgroup  FOR A10
COL asm_disk       FOR A30
COL asm_mode       FOR A8
COL griddisk       FOR A30
COL gd_gb          FOR 9999990
COL celldisk       FOR A22
COL cd_type        FOR A10
COL lun_id         FOR A8
COL lun_dev        FOR A14
COL physdisk       FOR A10
COL pd_type        FOR A10
COL slot           FOR A6
COL pd_status      FOR A12
COL failgroup      FOR A18

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 1. Top-down: ASM diskgroup -> griddisk -> celldisk -> LUN -> physical disk ====
------------------------------------------------------------------------------------------------------------------------
BREAK ON asm_diskgroup SKIP 1 ON cell_host SKIP 1

WITH cfg AS (
  SELECT /*+ MATERIALIZE */ cellname, conftype, XMLTYPE(confval) x
  FROM   v$cell_config
  WHERE  conftype IN ('CELL','PHYSICALDISKS','CELLDISKS','GRIDDISKS','LUNS')
),
cell AS (
  SELECT c.cellname, TRIM(t.cell_host) cell_host
  FROM   cfg c, XMLTABLE('/cli-output/cell' PASSING c.x
           COLUMNS cell_host VARCHAR2(64) PATH 'name') t
  WHERE  c.conftype = 'CELL'
),
gd AS (
  SELECT c.cellname, TRIM(t.gd_name) gd_name, TRIM(t.celldisk) celldisk, t.gd_size
  FROM   cfg c, XMLTABLE('/cli-output/griddisk' PASSING c.x
           COLUMNS gd_name   VARCHAR2(64) PATH 'name',
                   celldisk  VARCHAR2(64) PATH 'cellDisk',
                   gd_size   VARCHAR2(30) PATH 'size') t
  WHERE  c.conftype = 'GRIDDISKS'
),
cd AS (
  SELECT c.cellname, TRIM(t.cd_name) cd_name, TRIM(t.cd_type) cd_type, TRIM(t.lun) lun,
         TRIM(t.physdisk) physdisk, TRIM(t.devname) devname
  FROM   cfg c, XMLTABLE('/cli-output/celldisk' PASSING c.x
           COLUMNS cd_name   VARCHAR2(64) PATH 'name',
                   cd_type   VARCHAR2(30) PATH 'diskType',
                   lun       VARCHAR2(64) PATH 'lun',
                   physdisk  VARCHAR2(64) PATH 'physicalDisk',
                   devname   VARCHAR2(64) PATH 'deviceName') t
  WHERE  c.conftype = 'CELLDISKS'
),
lun AS (
  SELECT c.cellname, TRIM(t.lun_id) lun_id, TRIM(t.celldisk) celldisk, TRIM(t.lun_dev) lun_dev,
         TRIM(t.physdrives) physdrives
  FROM   cfg c, XMLTABLE('/cli-output/lun' PASSING c.x
           COLUMNS lun_id     VARCHAR2(64)  PATH 'id',
                   celldisk   VARCHAR2(64)  PATH 'cellDisk',
                   lun_dev    VARCHAR2(64)  PATH 'deviceName',
                   physdrives VARCHAR2(200) PATH 'physicalDrives') t
  WHERE  c.conftype = 'LUNS'
),
pd AS (
  SELECT c.cellname, TRIM(t.pd_id) pd_id, TRIM(t.pd_name) pd_name, TRIM(t.pd_type) pd_type,
         TRIM(t.slot) slot, TRIM(t.pd_status) pd_status, TRIM(t.luns) luns
  FROM   cfg c, XMLTABLE('/cli-output/physicaldisk' PASSING c.x
           COLUMNS pd_id     VARCHAR2(64)  PATH 'id',
                   pd_name   VARCHAR2(64)  PATH 'name',
                   pd_type   VARCHAR2(30)  PATH 'diskType',
                   slot      VARCHAR2(30)  PATH 'slotNumber',
                   pd_status VARCHAR2(60)  PATH 'status',
                   luns      VARCHAR2(200) PATH 'luns') t
  WHERE  c.conftype = 'PHYSICALDISKS'
)
SELECT adg.name                                          asm_diskgroup,
       NVL(cell.cell_host, gd.cellname)                  cell_host,
       ad.name                                           asm_disk,
       ad.mode_status                                    asm_mode,
       gd.gd_name                                        griddisk,
       ROUND(TO_NUMBER(gd.gd_size)/1024/1024/1024)       gd_gb,
       cd.cd_name                                        celldisk,
       cd.cd_type,
       lun.lun_id,
       lun.lun_dev,
       pd.pd_name                                        physdisk,
       pd.slot,
       SUBSTR(pd.pd_status,1,12)                         pd_status
FROM   gd
LEFT JOIN cell ON cell.cellname = gd.cellname
LEFT JOIN v$asm_disk_stat ad
       ON ad.path = 'o/' || gd.cellname || '/' || gd.gd_name
LEFT JOIN v$asm_diskgroup_stat adg ON adg.group_number = ad.group_number
LEFT JOIN cd  ON cd.cellname  = gd.cellname AND cd.cd_name = gd.celldisk
LEFT JOIN lun ON lun.cellname = cd.cellname
             AND (   lun.celldisk = cd.cd_name
                  OR lun.lun_id   = cd.lun
                  OR lun.lun_dev  = cd.devname)
LEFT JOIN pd  ON pd.cellname  = cd.cellname
             AND (   pd.pd_id   = cd.physdisk
                  OR pd.pd_name = cd.physdisk
                  OR pd.pd_name = lun.physdrives
                  OR pd.pd_id   = lun.physdrives
                  OR pd.luns    = lun.lun_id)
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
  SELECT c.cellname, TRIM(t.cell_host) cell_host
  FROM   cfg c, XMLTABLE('/cli-output/cell' PASSING c.x
           COLUMNS cell_host VARCHAR2(64) PATH 'name') t
  WHERE  c.conftype = 'CELL'
),
gd AS (
  SELECT c.cellname, TRIM(t.gd_name) gd_name, TRIM(t.celldisk) celldisk
  FROM   cfg c, XMLTABLE('/cli-output/griddisk' PASSING c.x
           COLUMNS gd_name   VARCHAR2(64) PATH 'name',
                   celldisk  VARCHAR2(64) PATH 'cellDisk') t
  WHERE  c.conftype = 'GRIDDISKS'
),
cd AS (
  SELECT c.cellname, TRIM(t.cd_name) cd_name, TRIM(t.cd_type) cd_type, TRIM(t.lun) lun,
         TRIM(t.physdisk) physdisk, TRIM(t.devname) devname
  FROM   cfg c, XMLTABLE('/cli-output/celldisk' PASSING c.x
           COLUMNS cd_name   VARCHAR2(64) PATH 'name',
                   cd_type   VARCHAR2(30) PATH 'diskType',
                   lun       VARCHAR2(64) PATH 'lun',
                   physdisk  VARCHAR2(64) PATH 'physicalDisk',
                   devname   VARCHAR2(64) PATH 'deviceName') t
  WHERE  c.conftype = 'CELLDISKS'
),
lun AS (
  SELECT c.cellname, TRIM(t.lun_id) lun_id, TRIM(t.celldisk) celldisk, TRIM(t.lun_dev) lun_dev,
         TRIM(t.physdrives) physdrives
  FROM   cfg c, XMLTABLE('/cli-output/lun' PASSING c.x
           COLUMNS lun_id     VARCHAR2(64)  PATH 'id',
                   celldisk   VARCHAR2(64)  PATH 'cellDisk',
                   lun_dev    VARCHAR2(64)  PATH 'deviceName',
                   physdrives VARCHAR2(200) PATH 'physicalDrives') t
  WHERE  c.conftype = 'LUNS'
),
pd AS (
  SELECT c.cellname, TRIM(t.pd_id) pd_id, TRIM(t.pd_name) pd_name, TRIM(t.pd_type) pd_type,
         TRIM(t.slot) slot, TRIM(t.pd_status) pd_status, TRIM(t.luns) luns
  FROM   cfg c, XMLTABLE('/cli-output/physicaldisk' PASSING c.x
           COLUMNS pd_id     VARCHAR2(64)  PATH 'id',
                   pd_name   VARCHAR2(64)  PATH 'name',
                   pd_type   VARCHAR2(30)  PATH 'diskType',
                   slot      VARCHAR2(30)  PATH 'slotNumber',
                   pd_status VARCHAR2(60)  PATH 'status',
                   luns      VARCHAR2(200) PATH 'luns') t
  WHERE  c.conftype = 'PHYSICALDISKS'
)
SELECT NVL(cell.cell_host, pd.cellname)   cell_host,
       pd.pd_name                         physdisk,
       pd.pd_type,
       pd.slot,
       SUBSTR(pd.pd_status,1,12)          pd_status,
       lun.lun_id,
       lun.lun_dev,
       cd.cd_name                         celldisk,
       cd.cd_type,
       gd.gd_name                         griddisk,
       ad.name                            asm_disk,
       adg.name                           asm_diskgroup
FROM   pd
LEFT JOIN cell ON cell.cellname = pd.cellname
LEFT JOIN lun ON lun.cellname = pd.cellname
             AND (   lun.physdrives = pd.pd_name
                  OR lun.physdrives = pd.pd_id
                  OR lun.lun_id     = pd.luns)
LEFT JOIN cd  ON cd.cellname  = pd.cellname
             AND (   cd.physdisk = pd.pd_id
                  OR cd.physdisk = pd.pd_name
                  OR cd.cd_name  = lun.celldisk
                  OR cd.lun      = lun.lun_id)
LEFT JOIN gd  ON gd.cellname  = cd.cellname AND gd.celldisk = cd.cd_name
LEFT JOIN v$asm_disk_stat ad
       ON ad.path = 'o/' || gd.cellname || '/' || gd.gd_name
LEFT JOIN v$asm_diskgroup_stat adg ON adg.group_number = ad.group_number
ORDER  BY cell_host, pd.pd_type, physdisk, celldisk, griddisk;

CLEAR BREAKS

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 3. ASM-only view: every diskgroup / cell (failgroup), incl. cells missing from v$cell_config ====
------------------------------------------------------------------------------------------------------------------------
BREAK ON asm_diskgroup SKIP 1

SELECT dg.name                                         asm_diskgroup,
       d.failgroup                                     failgroup,
       REGEXP_SUBSTR(d.path, '^o/([^/]+)/', 1, 1, NULL, 1) cell_ips,
       COUNT(*)                                        disks,
       SUM(CASE WHEN d.mode_status <> 'ONLINE' THEN 1 ELSE 0 END) not_online,
       ROUND(SUM(d.total_mb)/1024)                     total_gb,
       ROUND(SUM(d.free_mb)/1024)                      free_gb,
       CASE WHEN EXISTS (SELECT 1 FROM v$cell_config c
                         WHERE c.cellname = REGEXP_SUBSTR(d.path, '^o/([^/]+)/', 1, 1, NULL, 1))
            THEN 'YES' ELSE 'NO' END                   in_cell_config
FROM   v$asm_disk_stat d
JOIN   v$asm_diskgroup_stat dg ON dg.group_number = d.group_number
GROUP  BY dg.name, d.failgroup, REGEXP_SUBSTR(d.path, '^o/([^/]+)/', 1, 1, NULL, 1)
ORDER  BY 1, 2;

CLEAR BREAKS

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 4. Diagnostics ====
------------------------------------------------------------------------------------------------------------------------
COL cellname FOR A40
COL conftype FOR A20
COL xml_sample FOR A200

PROMPT -- 4a. Cells visible in v$cell_config with their hostnames
SELECT c.cellname, t.cell_host
FROM   v$cell_config c,
       XMLTABLE('/cli-output/cell' PASSING XMLTYPE(c.confval)
                COLUMNS cell_host VARCHAR2(64) PATH 'name') t
WHERE  c.conftype = 'CELL'
ORDER  BY t.cell_host;

PROMPT -- 4b. Raw XML: first CELLDISK entry (check element names: lun / physicalDisk / deviceName)
SELECT DBMS_LOB.SUBSTR(confval, 1500, DBMS_LOB.INSTR(confval, '<celldisk>')) xml_sample
FROM   v$cell_config WHERE conftype = 'CELLDISKS' AND ROWNUM = 1;

PROMPT -- 4c. Raw XML: first LUN entry (check element names: id / cellDisk / deviceName / physicalDrives)
SELECT DBMS_LOB.SUBSTR(confval, 1500, DBMS_LOB.INSTR(confval, '<lun>')) xml_sample
FROM   v$cell_config WHERE conftype = 'LUNS' AND ROWNUM = 1;

PROMPT -- 4d. Raw XML: first PHYSICALDISK entry (check element names: id / name / luns / slotNumber)
SELECT DBMS_LOB.SUBSTR(confval, 1500, DBMS_LOB.INSTR(confval, '<physicaldisk>')) xml_sample
FROM   v$cell_config WHERE conftype = 'PHYSICALDISKS' AND ROWNUM = 1;
