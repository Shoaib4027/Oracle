-- rman_backup_type_check.sql
--
-- Shows whether RMAN backups were whole database backups, and whether
-- level 1 incrementals were differential or cumulative.
--
-- Run where the backup records are held (the instance that ran RMAN),
-- or adapt to the RMAN catalog views if you use a catalog.
-- Both queries look back 30 days.

set lines 200 pages 200

-- ---------------------------------------------------------------------------
-- 1. Whole database backups
--
--    INPUT_TYPE values:
--      DB FULL                        whole database, non-incremental or level 0
--      DB INCR                        whole database, incremental
--      ARCHIVELOG                     archived logs only
--      DATAFILE FULL / DATAFILE INCR
--      / TABLESPACE etc.              only part of the database
-- ---------------------------------------------------------------------------
col input_type for a14
col status     for a24
col in_size    for a12
col out_size   for a12
col duration   for a12

select session_key,
       input_type,
       status,
       to_char(start_time,'DD-MON-YY HH24:MI') started,
       to_char(end_time,'DD-MON-YY HH24:MI')   ended,
       output_device_type device,
       input_bytes_display  in_size,
       output_bytes_display out_size,
       time_taken_display   duration
from   v$rman_backup_job_details
where  start_time >= sysdate - 30
order  by start_time desc;

-- ---------------------------------------------------------------------------
-- 2. Level 0, differential or cumulative
--
--    Oracle does not store this as an attribute, so it is inferred using
--    datafile 1 as a sample:
--      cumulative   level 1 starts from the last level 0
--      differential level 1 starts from the previous backup
--
--    The first level 1 after a level 0 looks the same either way, so check
--    the later level 1 backups. To confirm, check the RMAN script: without
--    the CUMULATIVE keyword, a level 1 backup is differential.
--
--    UNKNOWN means the base backup may have aged out of the control file,
--    or there are overlapping or duplicate backups.
-- ---------------------------------------------------------------------------
col backup_type for a40

with b as (
  select completion_time,
         incremental_level lvl,
         incremental_change#,
         checkpoint_change#,
         lag(checkpoint_change#) over (order by checkpoint_change#, completion_time) prev_ckp,
         lag(incremental_level)  over (order by checkpoint_change#, completion_time) prev_lvl,
         last_value(case when incremental_level = 0 then checkpoint_change# end ignore nulls)
           over (order by checkpoint_change#, completion_time
                 rows between unbounded preceding and 1 preceding) last_l0_ckp
  from   v$backup_datafile
  where  file# = 1
)
select to_char(completion_time,'DD-MON-YY HH24:MI') completed,
       lvl,
       incremental_change#,
       checkpoint_change#,
       case
         when lvl is null then 'FULL (not incremental)'
         when lvl = 0 then 'LEVEL 0 (incremental base)'
         when prev_lvl = 0 and incremental_change# = prev_ckp
              then 'LEVEL 1 - first after L0 (can be either)'
         when incremental_change# = last_l0_ckp then 'LEVEL 1 CUMULATIVE'
         when incremental_change# = prev_ckp then 'LEVEL 1 DIFFERENTIAL'
         else 'LEVEL 1 - UNKNOWN (check base backup)'
       end backup_type
from   b
where  completion_time >= sysdate - 30
order  by completion_time desc;
