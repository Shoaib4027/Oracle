SELECT partition_name,
       ROUND(SUM(bytes)/1024/1024/1024,2) size_gb
FROM (
        /* Table subpartitions */
        SELECT sp.partition_name,
               s.bytes
        FROM dba_tab_subpartitions sp,
             dba_segments s
        WHERE s.owner = sp.table_owner
          AND s.segment_name = sp.table_name
          AND s.partition_name = sp.subpartition_name

        UNION ALL

        /* LOB subpartitions */
        SELECT lp.partition_name,
               s.bytes
        FROM dba_lob_subpartitions lp,
             dba_segments s
        WHERE s.owner = lp.table_owner
          AND s.segment_name = lp.lob_subpartition_name
)
WHERE partition_name = 'JUNE_PARTITION'
GROUP BY partition_name;