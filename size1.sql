COL TABLE_OWNER        FOR A30
COL TABLE_NAME         FOR A50
COL PARTITION_NAME     FOR A30
COL SUBPARTITION_NAME  FOR A30

WITH owner_ AS
(
    SELECT 'EISAPP' owner
    FROM dual
),

/* ============================================================
   HASH SUBPARTITION SIZE
   ============================================================ */
subpart_size AS
(
    SELECT
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name,
        SUM(NVL(sg.bytes,0)) / 1024 / 1024 AS subpart_size_mb
    FROM dba_tab_subpartitions tsp
         LEFT JOIN dba_segments sg
           ON sg.owner = tsp.table_owner
          AND sg.segment_name = tsp.table_name
          AND sg.partition_name = tsp.partition_name
          AND sg.subpartition_name = tsp.subpartition_name
    WHERE tsp.table_owner = (SELECT owner FROM owner_)
      AND tsp.table_name = '&tab_name'
      AND tsp.partition_name = '&part_name'
    GROUP BY
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name
),

/* ============================================================
   LOB SUBPARTITION SIZE
   ============================================================ */
lob_size AS
(
    SELECT
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name,
        SUM(NVL(sg.bytes,0)) / 1024 / 1024 AS lob_size_mb
    FROM dba_tab_subpartitions tsp
         JOIN dba_lob_partitions lp
           ON lp.table_owner = tsp.table_owner
          AND lp.table_name = tsp.table_name
          AND lp.partition_name = tsp.partition_name
          AND lp.subpartition_name = tsp.subpartition_name
         JOIN dba_segments sg
           ON sg.owner = lp.table_owner
          AND sg.segment_name = lp.lob_name
          AND sg.partition_name = lp.partition_name
          AND sg.subpartition_name = lp.subpartition_name
    WHERE tsp.table_owner = (SELECT owner FROM owner_)
      AND tsp.table_name = '&tab_name'
      AND tsp.partition_name = '&part_name'
    GROUP BY
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name
)

SELECT
    s.table_owner,
    s.table_name,
    s.partition_name,
    s.subpartition_name,
    ROUND(s.subpart_size_mb,2) AS subpart_size_mb,
    ROUND(NVL(l.lob_size_mb,0),2) AS lob_size_mb,
    ROUND(
        s.subpart_size_mb +
        NVL(l.lob_size_mb,0),
        2
    ) AS total_size_mb
FROM subpart_size s
LEFT JOIN lob_size l
       ON l.table_owner       = s.table_owner
      AND l.table_name        = s.table_name
      AND l.partition_name    = s.partition_name
      AND l.subpartition_name = s.subpartition_name
ORDER BY
    s.partition_name,
    s.subpartition_name;