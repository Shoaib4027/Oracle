COL cellname            HEAD CELLNAME       FOR A20
COL lun_devicename      HEAD LUN_DEVICE     FOR A20
COL physdisk_name       HEAD PHYSDISK       FOR A30
COL physdisk_status     HEAD PHYSDISK_STAT  FOR A15
COL celldisk_name       HEAD CELLDISK       FOR A30
COL cd_devicepart       HEAD CD_PART        FOR A20
COL griddisk_name       HEAD GRIDDISK       FOR A30
COL asm_disk            HEAD ASMDISK        FOR A30
COL asm_diskgroup       HEAD ASM_DG         FOR A20

BREAK ON cellname SKIP 1

PROMPT Showing Exadata disk topology from Physical Disk -> Celldisk -> Griddisk -> ASM

WITH
pd AS (
    SELECT /*+ MATERIALIZE */
           c.cellname,
           EXTRACTVALUE(VALUE(v), '/physicaldisk/id/text()')      AS id,
           EXTRACTVALUE(VALUE(v), '/physicaldisk/name/text()')    AS name,
           EXTRACTVALUE(VALUE(v), '/physicaldisk/status/text()')  AS status
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/physicaldisk'))) v
    WHERE c.conftype = 'PHYSICALDISKS'
),
cd AS (
    SELECT /*+ MATERIALIZE */
           c.cellname,
           EXTRACTVALUE(VALUE(v), '/celldisk/name/text()')              AS name,
           EXTRACTVALUE(VALUE(v), '/celldisk/devicePartition/text()')  AS devicePartition,
           EXTRACTVALUE(VALUE(v), '/celldisk/physicalDisk/text()')     AS physicalDisk
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/celldisk'))) v
    WHERE c.conftype = 'CELLDISKS'
),
gd AS (
    SELECT /*+ MATERIALIZE */
           c.cellname,
           EXTRACTVALUE(VALUE(v), '/griddisk/name/text()')        AS name,
           EXTRACTVALUE(VALUE(v), '/griddisk/cellDisk/text()')    AS cellDisk,
           EXTRACTVALUE(VALUE(v), '/griddisk/asmDiskName/text()') AS asmDiskName
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/griddisk'))) v
    WHERE c.conftype = 'GRIDDISKS'
),
lun AS (
    SELECT /*+ MATERIALIZE */
           c.cellname,
           EXTRACTVALUE(VALUE(v), '/lun/deviceName/text()') AS deviceName,
           EXTRACTVALUE(VALUE(v), '/lun/cellDisk/text()')   AS cellDisk,
           EXTRACTVALUE(VALUE(v), '/lun/lunWriteCacheMode/text()')
                                                             AS lunWriteCacheMode
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/lun'))) v
    WHERE c.conftype = 'LUNS'
)
SELECT
       cd.cellname,
       SUBSTR(lun.deviceName,1,20)      AS lun_devicename,
       pd.name                          AS physdisk_name,
       SUBSTR(pd.status,1,15)           AS physdisk_status,
       cd.name                          AS celldisk_name,
       SUBSTR(cd.devicePartition,1,20)  AS cd_devicepart,
       gd.name                          AS griddisk_name,
       ad.name                          AS asm_disk,
       adg.name                         AS asm_diskgroup,
       lun.lunWriteCacheMode
FROM cd
LEFT JOIN pd
       ON pd.id = cd.physicalDisk
LEFT JOIN lun
       ON lun.cellDisk = cd.name
LEFT JOIN gd
       ON gd.cellDisk = cd.name
LEFT JOIN v$asm_disk ad
       ON ad.name = gd.asmDiskName
LEFT JOIN v$asm_diskgroup adg
       ON adg.group_number = ad.group_number
ORDER BY
       cd.cellname,
       cd.name,
       gd.name,
       ad.name;

CLEAR BREAKS