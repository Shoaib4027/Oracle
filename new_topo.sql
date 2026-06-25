COL asm_diskgroup      FOR A20
COL asm_disk           FOR A30
COL griddisk_name      FOR A30
COL celldisk_name      FOR A30
COL cellname           FOR A20
COL physdisk_name      FOR A20
COL physdisk_status    FOR A15
COL lunwritecachemode  FOR A20

WITH
pd AS (
    SELECT c.cellname,
           x.id,
           x.name,
           x.status
    FROM v$cell_config c,
         XMLTABLE(
           '/cli-output/physicaldisk'
           PASSING XMLTYPE(c.confval)
           COLUMNS
             id     VARCHAR2(100) PATH 'id',
             name   VARCHAR2(100) PATH 'name',
             status VARCHAR2(100) PATH 'status'
         ) x
    WHERE c.conftype='PHYSICALDISKS'
),
cd AS (
    SELECT c.cellname,
           x.name,
           x.id,
           x.physicaldisk,
           x.devicepartition
    FROM v$cell_config c,
         XMLTABLE(
           '/cli-output/celldisk'
           PASSING XMLTYPE(c.confval)
           COLUMNS
             id              VARCHAR2(100) PATH 'id',
             name            VARCHAR2(100) PATH 'name',
             physicaldisk    VARCHAR2(100) PATH 'physicalDisk',
             devicepartition VARCHAR2(100) PATH 'devicePartition'
         ) x
    WHERE c.conftype='CELLDISKS'
),
gd AS (
    SELECT c.cellname,
           x.name,
           x.asmdiskname,
           x.celldisk,
           x.asmdiskgroupname
    FROM v$cell_config c,
         XMLTABLE(
           '/cli-output/griddisk'
           PASSING XMLTYPE(c.confval)
           COLUMNS
             name             VARCHAR2(100) PATH 'name',
             asmdiskname      VARCHAR2(100) PATH 'asmDiskName',
             celldisk         VARCHAR2(100) PATH 'cellDisk',
             asmdiskgroupname VARCHAR2(100) PATH 'asmDiskgroupName'
         ) x
    WHERE c.conftype='GRIDDISKS'
),
lun AS (
    SELECT c.cellname,
           x.celldisk,
           x.lunwritecachemode
    FROM v$cell_config c,
         XMLTABLE(
           '/cli-output/lun'
           PASSING XMLTYPE(c.confval)
           COLUMNS
             celldisk          VARCHAR2(100) PATH 'cellDisk',
             lunwritecachemode VARCHAR2(100) PATH 'lunWriteCacheMode'
         ) x
    WHERE c.conftype='LUNS'
)
SELECT
       dg.name                        asm_diskgroup,
       ad.name                        asm_disk,
       gd.name                        griddisk_name,
       cd.name                        celldisk_name,
       pd.cellname,
       cd.devicepartition             cd_devicepart,
       pd.name                        physdisk_name,
       pd.status                      physdisk_status,
       lun.lunwritecachemode
FROM gv$asm_disk ad
LEFT JOIN v$asm_diskgroup dg
       ON dg.group_number = ad.group_number
LEFT JOIN gd
       ON UPPER(gd.asmdiskname) = UPPER(ad.name)
LEFT JOIN cd
       ON cd.name = gd.celldisk
      AND cd.cellname = gd.cellname
LEFT JOIN pd
       ON pd.id = cd.physicaldisk
      AND pd.cellname = cd.cellname
LEFT JOIN lun
       ON lun.celldisk = cd.name
      AND lun.cellname = cd.cellname
ORDER BY
       dg.name,
       ad.name,
       gd.name,
       cd.name,
       pd.name;