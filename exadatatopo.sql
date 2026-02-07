COL cellname        FOR A12
COL physdisk        FOR A25
COL phys_status     FOR A12
COL lun_device      FOR A25
COL lun_raid        FOR A6
COL celldisk        FOR A30
COL cd_part         FOR A20
COL griddisk        FOR A30
COL asm_disk        FOR A30
COL asm_dg          FOR A20

PROMPT =========================================================
PROMPT  EXADATA X9M-2 NVMe - MERGED DISK TOPOLOGY (SINGLE QUERY)
PROMPT =========================================================

WITH
pd AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/physicaldisk/id/text()')     AS phys_id,
        EXTRACTVALUE(VALUE(v), '/physicaldisk/name/text()')   AS physdisk,
        EXTRACTVALUE(VALUE(v), '/physicaldisk/status/text()') AS phys_status
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/physicaldisk'))) v
    WHERE c.conftype = 'PHYSICALDISKS'
),
lun AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/lun/deviceName/text()') AS lun_device,
        EXTRACTVALUE(VALUE(v), '/lun/raidLevel/text()')  AS lun_raid,
        EXTRACTVALUE(VALUE(v), '/lun/status/text()')     AS lun_status
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/lun'))) v
    WHERE c.conftype = 'LUNS'
),
cd AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/celldisk/name/text()')             AS celldisk,
        EXTRACTVALUE(VALUE(v), '/celldisk/devicePartition/text()') AS cd_part
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/celldisk'))) v
    WHERE c.conftype = 'CELLDISKS'
),
gd AS (
    SELECT
        c.cellname,
        EXTRACTVALUE(VALUE(v), '/griddisk/name/text()')        AS griddisk,
        EXTRACTVALUE(VALUE(v), '/griddisk/cellDisk/text()')    AS celldisk,
        EXTRACTVALUE(VALUE(v), '/griddisk/asmDiskName/text()') AS asm_disk
    FROM v$cell_config c,
         TABLE(XMLSEQUENCE(EXTRACT(XMLTYPE(c.confval),
               '/cli-output/griddisk'))) v
    WHERE c.conftype = 'GRIDDISKS'
)
SELECT
    cd.cellname,
    pd.physdisk,
    pd.phys_status,
    lun.lun_device,
    lun.lun_raid,
    cd.celldisk,
    cd.cd_part,
    gd.griddisk,
    ad.name   AS asm_disk,
    adg.name  AS asm_dg
FROM cd
LEFT JOIN gd
       ON gd.celldisk = cd.celldisk
LEFT JOIN v$asm_disk ad
       ON ad.name = gd.asm_disk
LEFT JOIN v$asm_diskgroup adg
       ON adg.group_number = ad.group_number
/* NVMe: no direct mapping, joined only by cellname */
LEFT JOIN pd
       ON pd.cellname = cd.cellname
LEFT JOIN lun
       ON lun.cellname = cd.cellname
ORDER BY
    cd.cellname,
    cd.celldisk,
    gd.griddisk,
    ad.name;