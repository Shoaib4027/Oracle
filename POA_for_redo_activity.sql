select a.GROUP#,b.thread#,a.TYPE,member,bytes/1024/1024/1024 from v$logfile a,v$log b where a.group#=b.group# order by 1;  For ORL


select a.GROUP#,b.thread#,a.TYPE,member,bytes/1024/1024/1024 from v$logfile a,v$standby_log b where a.group#=b.group# order by 1; For SRL

ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 1 ('+EISDATA','+EISRECO') SIZE 10G;


PR:
For MIIB PR DB ORL range is 1 to 60 group per node 10 files. ------------------------------- same time
For MIIB PR DB SRL range is 111 to 1166 group 

DR:
 
 SRL group start from 61 to 126 per node 11 files. ------------------------------------------ same time
 ORL group start from 1 to 60 per node 10 files.
 
 ===================================================================================================================================================
 
— primary db

alter system set log_archive_dest_state_2 = defer scope = memory;      ------------------------ same time start redo activity at Primary DB.


 MRP stopped at standby
 
 alter system set standby_file_management=MANUAL;
 recover managed standby database cancel;
 
 — drop standby redologs in standby and primary
 
alter database drop standby logfile group 61;
alter database drop standby logfile group 62;
alter database drop standby logfile group 63;
alter database drop standby logfile group 64;
alter database drop standby logfile group 65;
alter database drop standby logfile group 66;
alter database drop standby logfile group 67;
alter database drop standby logfile group 68;
alter database drop standby logfile group 69;
alter database drop standby logfile group 70;
alter database drop standby logfile group 71;

above SRL for for thread 1 do run same commands for remaining group upto 126


alter database drop standby logfile group 72;
alter database drop standby logfile group 73;
alter database drop standby logfile group 74;
alter database drop standby logfile group 75;
alter database drop standby logfile group 76;
alter database drop standby logfile group 77;
alter database drop standby logfile group 78;
alter database drop standby logfile group 79;
alter database drop standby logfile group 80;
alter database drop standby logfile group 81;
alter database drop standby logfile group 82;

alter database drop standby logfile group 83;
alter database drop standby logfile group 84;
alter database drop standby logfile group 85;
alter database drop standby logfile group 86;
alter database drop standby logfile group 87;
alter database drop standby logfile group 88;
alter database drop standby logfile group 89;
alter database drop standby logfile group 90;
alter database drop standby logfile group 91;
alter database drop standby logfile group 92;
alter database drop standby logfile group 93;

alter database drop standby logfile group 94;
alter database drop standby logfile group 95;
alter database drop standby logfile group 96;
alter database drop standby logfile group 97;
alter database drop standby logfile group 98;
alter database drop standby logfile group 99;
alter database drop standby logfile group 100;
alter database drop standby logfile group 101;
alter database drop standby logfile group 102;
alter database drop standby logfile group 103;
alter database drop standby logfile group 104;

alter database drop standby logfile group 105;
alter database drop standby logfile group 106;
alter database drop standby logfile group 107;
alter database drop standby logfile group 108;
alter database drop standby logfile group 109;
alter database drop standby logfile group 110;
alter database drop standby logfile group 111;
alter database drop standby logfile group 112;
alter database drop standby logfile group 113;
alter database drop standby logfile group 114;
alter database drop standby logfile group 115;

alter database drop standby logfile group 116;
alter database drop standby logfile group 117;
alter database drop standby logfile group 118;
alter database drop standby logfile group 119;
alter database drop standby logfile group 120;
alter database drop standby logfile group 121;
alter database drop standby logfile group 122;
alter database drop standby logfile group 123;
alter database drop standby logfile group 124;
alter database drop standby logfile group 125;
alter database drop standby logfile group 126;

 ========================================================================================================================
 — recreate the standby redologs in standby
 
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 61 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 62 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 63 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 64 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 65 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 66 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 67 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 68 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 69 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 70 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 71 ('+EISDATA','+EISRECO') SIZE 10G;
              
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 72 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 73 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 74 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 75 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 76 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 77 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 78 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 79 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 80 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 81 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 82 ('+EISDATA','+EISRECO') SIZE 10G;
               
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 83 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 84 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 85 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 86 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 87 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 88 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 89 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 90 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 91 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 92 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 93 ('+EISDATA','+EISRECO') SIZE 10G;
                
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 94 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 95 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 96 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 97 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 98 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 99 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 100 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 101 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 102 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 103 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 104 ('+EISDATA','+EISRECO') SIZE 10G;
                  
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 105 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 106 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 107 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 108 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 109 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 110 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 111 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 112 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 113 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 114 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 115 ('+EISDATA','+EISRECO') SIZE 10G;
                     
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 116 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 117 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 118 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 119 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 120 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 121 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 122 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 123 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 124 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 125 ('+EISDATA','+EISRECO') SIZE 10G;
 ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 126 ('+EISDATA','+EISRECO') SIZE 10G;

===============================================================================================================================================


At Primary DB:

For MIIB PR DB ORL range is 1 to 60 group per node 10 files.

Do changes thread wise:  For thread 1

select a.GROUP#,b.thread#,a.TYPE,b.status,member,bytes/1024/1024/1024 from v$logfile a,v$log b where a.group#=b.group# and thread#=&thread_number;  

INACTIVE  status groups take first to drop and recreate

alter database drop logfile group 1;
alter database drop logfile group 2;
alter database drop logfile group 3;
alter database drop logfile group 4;
alter database drop logfile group 5;
alter database drop logfile group 6;
alter database drop logfile group 7;
alter database drop logfile group 8;
alter database drop logfile group 9;
alter database drop logfile group 10;

ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 1 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 2 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 3 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 4 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 5 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 6 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 7 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 8 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 9 ('+EISDATA','+EISRECO') SIZE 10G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 10 ('+EISDATA','+EISRECO') SIZE 10G;


Do the same for all thread 2 to 6
select a.GROUP#,b.thread#,a.TYPE,b.status,member,bytes/1024/1024/1024 from v$logfile a,v$log b where a.group#=b.group# and thread#=&thread_number; 
