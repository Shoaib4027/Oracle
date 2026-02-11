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
        bs.set_stamp,
        bs.set_count,
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
    l1.completion_time,
    l1.file#,
    bp.handle AS backup_piece_name,
    l1.checkpoint_change#,
    l1.incremental_change#,
    CASE 
        WHEN l1.incremental_change# = l1.lvl0_chk 
        THEN 'CUMULATIVE'
        ELSE 'DIFFERENTIAL'
    END AS detected_type
FROM lvl1 l1
JOIN v$backup_piece bp
  ON l1.set_stamp = bp.set_stamp
 AND l1.set_count = bp.set_count
ORDER BY l1.completion_time DESC;