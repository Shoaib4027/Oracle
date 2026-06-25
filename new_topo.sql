COL asm_diskgroup      FOR A15
COL asm_disk           FOR A35
COL griddisk_name      FOR A35
COL celldisk_name      FOR A35
COL cellname           FOR A20
COL physdisk_name      FOR A15
COL physdisk_status    FOR A12

WITH
pd AS (
    SELECT c.cellname,
           x.name name,
           x.status,
           x.physicalserial
    FROM v$cell_config c,
         XMLTABLE(
           '/cli-output/physicaldisk'
           PASSING XMLTYPE(c.confval)
           COLUMNS
             name           VARCHAR2(100) PATH 'name',
             status         VARCHAR2(100) PATH 'status',
             physicalserial VARCHAR2(200) PATH 'physicalSerial'
         ) x
    WHERE c.conftype='PHYSICALDISKS'
),
cd AS (
    SELECT c.cellname,
           x.name,
           x.physicaldisk,
           x.devicepartition
    FROM v$cell_config c,
         XMLTABLE(
           '/cli-output/celldisk'
           PASSING XMLTYPE(c.confval)
           COLUMNS
             name            VARCHAR2(100) PATH 'name',
             physicaldisk    VARCHAR2(200) PATH 'physicalDisk',
             devicepartition VARCHAR2(100) PATH 'devicePartition'
         ) x
    WHERE c.conftype='CELLDISKS'
),
gd AS (
    SELECT c.cellname,
           x.name,
           x.asmdiskname,
           x.celldisk
    FROM v$cell_config c,
         XMLTABLE(
           '/cli-output/griddisk'
           PASSING XMLTYPE(c.confval)
           COLUMNS
             name        VARCHAR2(100) PATH 'name',
             asmdiskname VARCHAR2(100) PATH 'asmDiskName',
             celldisk    VARCHAR2(100) PATH 'cellDisk'
         ) x
    WHERE c.conftype='GRIDDISKS'
)
SELECT
       dg.name                asm_diskgroup,
       ad.name                asm_disk,
       gd.name                griddisk_name,
       cd.name                celldisk_name,
       pd.cellname,
       cd.devicepartition     cd_devicepart,
       pd.name                physdisk_name,
       pd.status              physdisk_status
FROM gv$asm_disk ad
LEFT JOIN v$asm_diskgroup dg
       ON dg.group_number = ad.group_number
LEFT JOIN gd
       ON gd.asmdiskname = ad.name
LEFT JOIN cd
       ON cd.name = gd.celldisk
      AND cd.cellname = gd.cellname
LEFT JOIN pd
       ON pd.physicalserial = cd.physicaldisk
      AND pd.cellname = cd.cellname
ORDER BY
       dg.name,
       ad.name,
       gd.name,
       cd.name;