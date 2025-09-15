set lines 300 pages 3000
col index_name for a30
col index_owner for a30
col OPERATION for a30
col OPTIONS for a40

select distinct
      p.sql_id,
          p.plan_hash_value,
          p.object_name as index_name,
          p.object_owner as index_owner,
          p.operation,
          p.options
from dba_hist_sql_plan p
where p.object_type='INDEX'
     and  p.object_name ='&1'
         and  p.object_owner='EISAPP'
         and p.operation like 'INDEX%'
         and exists ( select 1 from dba_hist_sqlstat s where s.sql_id=p.sql_id and s.plan_hash_value=p.plan_hash_value);
