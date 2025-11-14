WITH foreign_logs AS (
    SELECT THREAD#, SEQUENCE#
    FROM V$FOREIGN_ARCHIVED_LOG
    WHERE APPLIED='NO'
),
registered_logs AS (
    SELECT THREAD#, SEQUENCE#
    FROM DBA_REGISTERED_ARCHIVED_LOG
),
missing AS (
    SELECT f.thread#, f.sequence#
    FROM foreign_logs f
    LEFT JOIN registered_logs r
      ON f.thread# = r.thread# AND f.sequence# = r.sequence#
    WHERE r.sequence# IS NULL
)
SELECT 
    thread#,
    MIN(sequence#) AS gap_start,
    MAX(sequence#) AS gap_end,
    COUNT(*) AS gap_count
FROM missing
GROUP BY thread#
ORDER BY thread#;