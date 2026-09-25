col TABLE_NAME for a50
col TABLE_OWNER for a30
col PARTITION_NAME for a30


WITH
owner_
AS
(SELECT 'EISAPP' owner ---<--- put the tables' owner
FROM dual
)
SELECT ps.table_owner
      ,ps.table_name
      ,ps.partition_name
      ,ps.part_size_mb
      ,pls.part_lob_size_mb
      ,(ps.part_size_mb+pls.part_lob_size_mb) all_part_size_mb
FROM
(SELECT tp.table_owner
      ,tp.table_name
      ,tp.partition_name
      ,(sg.bytes)/(1024*1024) part_size_mb
FROM dba_tab_partitions tp
    ,dba_segments      sg
    ,owner_ o
WHERE tp.table_owner    = o.owner
  AND sg.owner          = tp.table_owner
  AND sg.segment_name  = tp.table_name
  AND sg.partition_name = tp.partition_name
) ps
,
(SELECT tp.table_owner
      ,tp.table_name
      ,tp.partition_name
      ,SUM(sg.bytes)/(1024*1024) part_lob_size_mb
FROM dba_tab_partitions tp
    ,dba_lob_partitions lp
    ,dba_segments      sg
    ,owner_            ow
WHERE tp.table_owner    = ow.owner
  AND lp.table_owner    = tp.table_owner
  AND lp.table_name    = tp.table_name
  AND lp.partition_name = tp.partition_name
  AND sg.owner          = lp.table_owner
  AND sg.segment_name  = lp.lob_name
  AND sg.partition_name = lp.lob_partition_name
GROUP BY tp.table_owner
        ,tp.table_name
        ,tp.partition_name
) pls
WHERE pls.table_owner    = ps.table_owner
  AND pls.table_name    = ps.table_name
  AND pls.partition_name = ps.partition_name
  and ps.table_name='&tab_name'
  and ps.partition_name='&part_name';
