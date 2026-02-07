COL cellname            HEAD CELLNAME       FOR A20
COL lun_devicename      HEAD LUN_DEVICE     FOR A20
COL physdisk_name       HEAD PHYSDISK       FOR A30
COL physdisk_status     HEAD PHYSDISK_STAT  FOR A15
COL celldisk_name       HEAD CELLDISK       FOR A30
COL cd_devicepart       HEAD CD_PART        FOR A20
COL griddisk_name       HEAD GRIDDISK       FOR A30
COL asm_disk            HEAD ASMDISK        FOR A30
COL asm_diskgroup       HEAD ASM_DG         FOR A20
COL lunWriteCacheMode   HEAD LUN_WC_MODE    FOR A15

PROMPT =========================================================
PROMPT  EXADATA X9M-2 NVMe — EXADISCTOPO STYLE REPORT
PROMPT =========================================================

WITH
pd AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/physicaldisk/name/text()')   AS physdisk_name,
        EXTRACTVALUE(VALUE(v), '/physicaldisk/status/text()') AS physdisk_status
    FROM v$cell_config c
       , TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
              '/cli-output/physicaldisk'))) v
    WHERE c.conftype = 'PHYSICALDISKS'
),
lun AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/lun/deviceName/text()')       AS lun_devicename,
        EXTRACTVALUE(VALUE(v), '/lun/lunWriteCacheMode/text()') AS lunWriteCacheMode
    FROM v$cell_config c
       , TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
              '/cli-output/lun'))) v
    WHERE c.conftype = 'LUNS'
),
cd AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/celldisk/name/text()')             AS celldisk_name,
        EXTRACTVALUE(VALUE(v), '/celldisk/devicePartition/text()')  AS cd_devicepart
    FROM v$cell_config c
       , TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
              '/cli-output/celldisk'))) v
    WHERE c.conftype = 'CELLDISKS'
),
gd AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/griddisk/name/text()')        AS griddisk_name,
        EXTRACTVALUE(VALUE(v), '/griddisk/asmDiskName/text()') AS asm_disk
    FROM v$cell_config c
       , TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
              '/cli-output/griddisk'))) v
    WHERE c.conftype = 'GRIDDISKS'
),
asm AS (
    SELECT name, group_number FROM v$asm_disk
),
asg AS (
    SELECT group_number, name FROM v$asm_diskgroup
)
SELECT
    cd.cellname,
    lun.lun_devicename,
    pd.physdisk_name,
    pd.physdisk_status,
    cd.celldisk_name,
    cd.cd_devicepart,
    gd.griddisk_name,
    asm.name         AS asm_disk,
    asg.name         AS asm_diskgroup,
    lun.lunWriteCacheMode
FROM cd
LEFT JOIN gd
       ON gd.celldisk_name = cd.celldisk_name
LEFT JOIN lun
       ON lun.cellname = cd.cellname
LEFT JOIN pd
       ON pd.cellname = cd.cellname
LEFT JOIN asm
       ON asm.name = gd.asm_disk
LEFT JOIN asg
       ON asg.group_number = asm.group_number
ORDER BY
    cd.cellname,
    cd.celldisk_name,
    gd.griddisk_name,
    asm.name;