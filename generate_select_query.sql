SELECT 
    column_name,
    LISTAGG(
        'SELECT MIN(' || column_name || ') AS MIN_' || column_name ||
        ', MAX(' || column_name || ') AS MAX_' || column_name ||
        ' FROM ' || owner || '.' || table_name || ';',
        CHR(10)
    ) WITHIN GROUP (ORDER BY table_name) AS min_max_queries
FROM dba_tab_columns
WHERE owner = 'IIBARCH'
  AND data_type LIKE '%TIME%'
GROUP BY column_name
HAVING COUNT(DISTINCT table_name) > 1
ORDER BY column_name;