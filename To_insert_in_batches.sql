--1) to create task

BEGIN
  DBMS_PARALLEL_EXECUTE.create_task (task_name => 'test_task');
END;
/

--2) to define chunk properties

BEGIN
  DBMS_PARALLEL_EXECUTE.create_chunks_by_rowid(task_name   => 'test_task',
                                               table_owner => 'IIBARCH',
                                               table_name  => 'BACK_PROCESS_CLOBDET_2021_2',
                                               by_row      => FALSE,
                                               chunk_size  => 10000);
END;
/
--3) to check status

COLUMN task_name FORMAT A10
SELECT task_name,
       status
FROM   user_parallel_execute_tasks;
SELECT chunk_id, status, start_rowid, end_rowid
FROM   user_parallel_execute_chunks
WHERE  task_name = 'test_task'
ORDER BY chunk_id;

--4) to execute the chunks
DECLARE
  l_sql_stmt VARCHAR2(32767);

BEGIN
  l_sql_stmt := 'insert  into IIBARCH.BACK_PROCESS_CLOBDET_2021_2C select * from IIBARCH.BACK_PROCESS_CLOBDET_2021_2
                 WHERE rowid BETWEEN :start_id AND :end_id';
  DBMS_PARALLEL_EXECUTE.run_task(task_name      => 'test_task',
                                 sql_stmt       => l_sql_stmt,
                                 language_flag  => DBMS_SQL.NATIVE,
