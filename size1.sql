COL TABLE_NAME        FOR A50
COL TABLE_OWNER       FOR A30
COL PARTITION_NAME    FOR A30
COL SUBPARTITION_NAME FOR A30

WITH
owner_
AS
(
    SELECT 'EISAPP' owner
    FROM dual
),

/* ============================================================
   TABLE SUBPARTITION SIZE
   ============================================================ */
ps
AS
(
    SELECT
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name,
        SUM(sg.bytes)/(1024*1024) part_size_mb
    FROM dba_tab_subpartitions tsp,
         dba_segments sg,
         owner_ o
    WHERE tsp.table_owner       = o.owner
      AND sg.owner              = tsp.table_owner
      AND sg.segment_name       = tsp.table_name
      AND sg.partition_name     = tsp.partition_name
      AND sg.subpartition_name  = tsp.subpartition_name
    GROUP BY
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name
),

/* ============================================================
   LOB SUBPARTITION SIZE
   ============================================================ */
pls
AS
(
    SELECT
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name,
        SUM(sg.bytes)/(1024*1024) part_lob_size_mb
    FROM dba_tab_subpartitions tsp,
         dba_lob_subpartitions lsp,
         dba_segments sg,
         owner_ ow
    WHERE tsp.table_owner       = ow.owner
      AND lsp.table_owner       = tsp.table_owner
      AND lsp.table_name        = tsp.table_name
      AND lsp.parent_table_partition = tsp.partition_name
      AND lsp.parent_table_subpartition = tsp.subpartition_name
      AND sg.owner              = lsp.table_owner
      AND sg.segment_name       = lsp.lob_name
      AND sg.partition_name     = lsp.partition_name
      AND sg.subpartition_name  = lsp.subpartition_name
    GROUP BY
        tsp.table_owner,
        tsp.table_name,
        tsp.partition_name,
        tsp.subpartition_name
)

SELECT
    ps.table_owner,
    ps.table_name,
    ps.partition_name,
    ps.subpartition_name,
    ROUND(ps.part_size_mb,2) part_size_mb,
    ROUND(NVL(pls.part_lob_size_mb,0),2) part_lob_size_mb,
    ROUND(
        ps.part_size_mb + NVL(pls.part_lob_size_mb,0),
        2
    ) all_part_size_mb
FROM ps,
     pls
WHERE pls.table_owner(+)       = ps.table_owner
  AND pls.table_name(+)        = ps.table_name
  AND pls.partition_name(+)    = ps.partition_name
  AND pls.subpartition_name(+) = ps.subpartition_name
  AND ps.table_name            = '&tab_name'
  AND ps.partition_name        = '&part_name'
ORDER BY
    ps.partition_name,
    ps.subpartition_name;