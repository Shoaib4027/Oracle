SELECT 
    consumer_name,
    name,
    thread#,
    sequence#,
    (sequence# - LAG(sequence#) OVER (PARTITION BY thread# ORDER BY sequence#)) AS diff,
    CASE 
        WHEN (sequence# - LAG(sequence#) OVER (PARTITION BY thread# ORDER BY sequence#)) > 1 
        THEN 'MISSING: ' || (LAG(sequence#) OVER (PARTITION BY thread# ORDER BY sequence#) + 1) 
             || ' TO ' || (sequence# - 1)
    END AS missing_range
FROM 
    dba_registered_archived_log
WHERE 
    consumer_name = 'MIQ4'
    AND thread# = 1
ORDER BY 
    sequence#;