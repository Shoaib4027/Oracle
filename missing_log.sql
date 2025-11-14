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



miib_arch_2_161117_1156944397.log miib_arch_5_134327_1156944397.log miib_arch_2_161118_1156944397.log miib_arch_6_125329_1156944397.log miib_arch_6_125328_1156944397.log miib_arch_2_161116_1156944397.log 
this are file i want to find missing sequence suppose between 161116 and 16118 for miib_arch_2 how will i do it linux
