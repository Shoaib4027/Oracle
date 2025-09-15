set lines 300 pages 300
col onwer for a30
col table_name for a30
col index_name for a30
SELECT seg.owner, idx.table_name, idx.index_name, SUM(seg.bytes)/1024/1024 as index_size_mb
  FROM dba_segments seg,
  dba_indexes idx
  WHERE idx.table_owner in
(
'EISAPP'
)
  AND idx.table_name IN
  (
  select table_name from dba_tables where nvl(num_rows,0) > 1000000
  )
  AND idx.owner = seg.owner
  AND idx.index_name = seg.segment_name
  GROUP BY seg.owner, idx.index_name, idx.table_name order by 4,2;

