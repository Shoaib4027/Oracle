WITH lvl0 AS (
    SELECT file#, MAX(checkpoint_change#) chk
    FROM v$backup_datafile bd
    JOIN v$backup_set bs
      ON bs.set_stamp = bd.set_stamp
     AND bs.set_count = bd.set_count
    WHERE bs.incremental_level = 0
    GROUP BY file#
),
lvl1 AS (
    SELECT 
        bs.completion_time,
        bd.file#,
        bd.incremental_change#,
        bd.checkpoint_change#,
        l.chk lvl0_chk
    FROM v$backup_set bs
    JOIN v$backup_datafile bd
      ON bs.set_stamp = bd.set_stamp
     AND bs.set_count = bd.set_count
    JOIN lvl0 l
      ON l.file# = bd.file#
    WHERE bs.incremental_level = 1
)
SELECT 
    completion_time,
    file#,
    checkpoint_change#,
    incremental_change#,
    CASE 
        WHEN incremental_change# = lvl0_chk 
        THEN 'CUMULATIVE'
        ELSE 'DIFFERENTIAL'
    END AS detected_type
FROM lvl1
ORDER BY completion_time DESC;