------------------------------------------------------------------------------------------------------------------------
--
-- File name:   x9m2_disk.sql  (v3)
--
-- Purpose:     Exadata X9M-2 disk topology:
--                ASM diskgroup -> ASM disk -> griddisk -> celldisk -> physical disk -> LUN
--
--              Adapted from the idea of Tanel Poder's exadisktopo.sql (tpt-oracle), reworked for X8M/X9M
--              using the XML layout actually returned by v$cell_config on this cell software:
--
--                griddisk.cellDisk          = celldisk.name
--                celldisk.physicalDisk      = physicaldisk.physicalSerial   (e.g. 046V6G)
--                physicaldisk.luns          = lun.id                        (e.g. 0_0)
--                ASM disk path              = 'o/' || cellname || '/' || griddisk.name
--
--                (physicaldisk has no <id>, celldisk has no <lun>, lun has no <cellDisk> on this version)
--
-- Sections:    1. Top-down topology (griddisks in ASM)
--              2. Bottom-up topology (all physical disks incl. flash FD_xx / PMEM PM_xx)
--              3. ASM-only view per diskgroup/cell  (covers cells NOT visible in v$cell_config)
--              4. Cells visible in v$cell_config
--
-- Note:        v$cell_config only lists the cells this instance has config for. If section 3 shows
--              diskgroups/cells missing from section 1 (IN_CELL_CONFIG = NO), run from the ASM instance.
--
-- Usage:       @x9m2_disk.sql
--
------------------------------------------------------------------------------------------------------------------------

SET LINES 400 PAGES 5000 TRIMSPOOL ON TRIMOUT ON VERIFY OFF FEEDBACK ON

COL cell_host      FOR A16
COL asm_diskgroup  FOR A10
COL asm_disk       FOR A30
COL asm_mode       FOR A8
COL griddisk       FOR A30
COL gd_gb          FOR 9999990
COL celldisk       FOR A22
COL cd_type        FOR A10
COL cd_dev         FOR A10
COL physdisk       FOR A8
COL pd_serial      FOR A10
COL pd_type        FOR A10
COL slot           FOR A4
COL pd_status      FOR A12
COL pd_model       FOR A28
COL lun_id         FOR A6
COL raid           FOR A4
COL failgroup      FOR A18
COL cell_ips       FOR A30
COL cellname       FOR A30

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 1. Top-down: ASM diskgroup -> griddisk -> celldisk -> physical disk -> LUN ====
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
  SELECT c.cellname, TRIM(t.gd_name) gd_name, TRIM(t.celldisk) celldisk, TRIM(t.gd_size) gd_size
  FROM   cfg c, XMLTABLE('/cli-output/griddisk' PASSING c.x
           COLUMNS gd_name   VARCHAR2(64) PATH 'name',
                   celldisk  VARCHAR2(64) PATH 'cellDisk',
                   gd_size   VARCHAR2(30) PATH 'size') t
  WHERE  c.conftype = 'GRIDDISKS'
),
cd AS (
  SELECT c.cellname, TRIM(t.cd_name) cd_name, TRIM(t.cd_type) cd_type,
         TRIM(t.physdisk) physdisk, TRIM(t.devname) devname
  FROM   cfg c, XMLTABLE('/cli-output/celldisk' PASSING c.x
           COLUMNS cd_name   VARCHAR2(64) PATH 'name',
                   cd_type   VARCHAR2(30) PATH 'diskType',
                   physdisk  VARCHAR2(64) PATH 'physicalDisk',
                   devname   VARCHAR2(64) PATH 'deviceName') t
  WHERE  c.conftype = 'CELLDISKS'
),
pd AS (
  SELECT c.cellname, TRIM(t.pd_name) pd_name, TRIM(t.serial) serial, TRIM(t.pd_type) pd_type,
         TRIM(t.slot) slot, TRIM(t.pd_status) pd_status, TRIM(t.luns) luns,
         TRIM(REPLACE(REGEXP_REPLACE(t.model, '\s+', ' '), '"')) model
  FROM   cfg c, XMLTABLE('/cli-output/physicaldisk' PASSING c.x
           COLUMNS pd_name   VARCHAR2(64)  PATH 'name',
                   serial    VARCHAR2(64)  PATH 'physicalSerial',
                   pd_type   VARCHAR2(30)  PATH 'diskType',
                   slot      VARCHAR2(30)  PATH 'slotNumber',
                   pd_status VARCHAR2(60)  PATH 'status',
                   luns      VARCHAR2(200) PATH 'luns',
                   model     VARCHAR2(100) PATH 'makeModel') t
  WHERE  c.conftype = 'PHYSICALDISKS'
),
lun AS (
  SELECT c.cellname, TRIM(t.lun_id) lun_id, TRIM(t.lun_dev) lun_dev, TRIM(t.raid) raid
  FROM   cfg c, XMLTABLE('/cli-output/lun' PASSING c.x
           COLUMNS lun_id   VARCHAR2(64) PATH 'id',
                   lun_dev  VARCHAR2(64) PATH 'deviceName',
                   raid     VARCHAR2(10) PATH 'raidLevel') t
  WHERE  c.conftype = 'LUNS'
)
SELECT adg.name                                    asm_diskgroup,
       NVL(cell.cell_host, gd.cellname)            cell_host,
       ad.name                                     asm_disk,
       ad.mode_status                              asm_mode,
       gd.gd_name                                  griddisk,
       ROUND(TO_NUMBER(gd.gd_size)/1024/1024/1024) gd_gb,
       cd.cd_name                                  celldisk,
       cd.devname                                  cd_dev,
       pd.pd_name                                  physdisk,
       pd.serial                                   pd_serial,
       pd.slot,
       SUBSTR(pd.pd_status,1,12)                   pd_status,
       lun.lun_id,
       lun.raid
FROM   gd
LEFT JOIN cell ON cell.cellname = gd.cellname
LEFT JOIN v$asm_disk_stat ad       ON ad.path = 'o/' || gd.cellname || '/' || gd.gd_name
LEFT JOIN v$asm_diskgroup_stat adg ON adg.group_number = ad.group_number
LEFT JOIN cd  ON cd.cellname  = gd.cellname AND cd.cd_name = gd.celldisk
LEFT JOIN pd  ON pd.cellname  = cd.cellname AND pd.serial  = cd.physdisk
LEFT JOIN lun ON lun.cellname = pd.cellname AND lun.lun_id = pd.luns
ORDER  BY asm_diskgroup, cell_host, celldisk, griddisk;

CLEAR BREAKS

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 2. Bottom-up: physical disk -> LUN -> celldisk -> griddisk -> ASM (includes flash and PMEM) ====
------------------------------------------------------------------------------------------------------------------------
BREAK ON cell_host SKIP 1 ON physdisk ON pd_serial ON pd_type ON slot ON pd_status ON pd_model

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
  SELECT c.cellname, TRIM(t.cd_name) cd_name, TRIM(t.cd_type) cd_type,
         TRIM(t.physdisk) physdisk, TRIM(t.devname) devname
  FROM   cfg c, XMLTABLE('/cli-output/celldisk' PASSING c.x
           COLUMNS cd_name   VARCHAR2(64) PATH 'name',
                   cd_type   VARCHAR2(30) PATH 'diskType',
                   physdisk  VARCHAR2(64) PATH 'physicalDisk',
                   devname   VARCHAR2(64) PATH 'deviceName') t
  WHERE  c.conftype = 'CELLDISKS'
),
pd AS (
  SELECT c.cellname, TRIM(t.pd_name) pd_name, TRIM(t.serial) serial, TRIM(t.pd_type) pd_type,
         TRIM(t.slot) slot, TRIM(t.pd_status) pd_status, TRIM(t.luns) luns,
         TRIM(REPLACE(REGEXP_REPLACE(t.model, '\s+', ' '), '"')) model
  FROM   cfg c, XMLTABLE('/cli-output/physicaldisk' PASSING c.x
           COLUMNS pd_name   VARCHAR2(64)  PATH 'name',
                   serial    VARCHAR2(64)  PATH 'physicalSerial',
                   pd_type   VARCHAR2(30)  PATH 'diskType',
                   slot      VARCHAR2(30)  PATH 'slotNumber',
                   pd_status VARCHAR2(60)  PATH 'status',
                   luns      VARCHAR2(200) PATH 'luns',
                   model     VARCHAR2(100) PATH 'makeModel') t
  WHERE  c.conftype = 'PHYSICALDISKS'
),
lun AS (
  SELECT c.cellname, TRIM(t.lun_id) lun_id, TRIM(t.lun_dev) lun_dev
  FROM   cfg c, XMLTABLE('/cli-output/lun' PASSING c.x
           COLUMNS lun_id   VARCHAR2(64) PATH 'id',
                   lun_dev  VARCHAR2(64) PATH 'deviceName') t
  WHERE  c.conftype = 'LUNS'
)
SELECT NVL(cell.cell_host, pd.cellname)   cell_host,
       pd.pd_name                         physdisk,
       pd.serial                          pd_serial,
       pd.pd_type,
       pd.slot,
       SUBSTR(pd.pd_status,1,12)          pd_status,
       SUBSTR(pd.model,1,28)              pd_model,
       lun.lun_id,
       cd.cd_name                         celldisk,
       cd.devname                         cd_dev,
       gd.gd_name                         griddisk,
       adg.name                           asm_diskgroup
FROM   pd
LEFT JOIN cell ON cell.cellname = pd.cellname
LEFT JOIN lun  ON lun.cellname  = pd.cellname AND lun.lun_id  = pd.luns
LEFT JOIN cd   ON cd.cellname   = pd.cellname AND cd.physdisk = pd.serial
LEFT JOIN gd   ON gd.cellname   = cd.cellname AND gd.celldisk = cd.cd_name
LEFT JOIN v$asm_disk_stat ad       ON ad.path = 'o/' || gd.cellname || '/' || gd.gd_name
LEFT JOIN v$asm_diskgroup_stat adg ON adg.group_number = ad.group_number
ORDER  BY cell_host, pd.pd_type, TO_NUMBER(REGEXP_SUBSTR(pd.slot, '^\d+')), physdisk, griddisk;

CLEAR BREAKS

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 3. ASM-only view: every diskgroup / cell (failgroup), incl. cells missing from v$cell_config ====
------------------------------------------------------------------------------------------------------------------------
BREAK ON asm_diskgroup SKIP 1

WITH d AS (
  SELECT d.group_number, d.failgroup, d.mode_status, d.total_mb, d.free_mb,
         REGEXP_SUBSTR(d.path, '^o/([^/]+)/', 1, 1, NULL, 1) cell_ips
  FROM   v$asm_disk_stat d
),
cc AS (SELECT DISTINCT cellname FROM v$cell_config)
SELECT dg.name                                                asm_diskgroup,
       d.failgroup,
       d.cell_ips,
       COUNT(*)                                               disks,
       SUM(CASE WHEN d.mode_status <> 'ONLINE' THEN 1 ELSE 0 END) not_online,
       ROUND(SUM(d.total_mb)/1024)                            total_gb,
       ROUND(SUM(d.free_mb)/1024)                             free_gb,
       NVL2(MAX(cc.cellname), 'YES', 'NO')                    in_cell_config
FROM   d
JOIN   v$asm_diskgroup_stat dg ON dg.group_number = d.group_number
LEFT JOIN cc ON cc.cellname = d.cell_ips
GROUP  BY dg.name, d.failgroup, d.cell_ips
ORDER  BY 1, 2;

CLEAR BREAKS

------------------------------------------------------------------------------------------------------------------------
PROMPT
PROMPT ==== 4. Cells visible in v$cell_config ====
------------------------------------------------------------------------------------------------------------------------
SELECT c.cellname, t.cell_host
FROM   v$cell_config c,
       XMLTABLE('/cli-output/cell' PASSING XMLTYPE(c.confval)
                COLUMNS cell_host VARCHAR2(64) PATH 'name') t
WHERE  c.conftype = 'CELL'
ORDER  BY t.cell_host;
