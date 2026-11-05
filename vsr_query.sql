set echo on;
set define off;
set time on timing on;
spool /tmp/vsr_batch1.txt;
insert into "IIBARCH"."BACKEND_DETAILS_TMP_DATA" SELECT /*+parallel(04)*/ urn,INPUT_DATA,OUTPUT_DATA,creation_date_time FROM IIBARCH.backend_details_26q4 PARTITION(OCT_26)
WHERE creation_date_time between to_date('12-OCT-202600:00:00','DD-MON-YYYY HH24:MI:SS')
and to_date('13-OCT-2026 23:59:59','DD-MON-YYYY HH24:MI:SS')
and URN IN
(select  URN from iibarch.backend_log_26q4 PARTITION(OCT_26) where
request_date_time between to_date('12-OCT-2026 00:00:00','DD-MON-YYYY HH24:MI:SS')
and to_date('13-OCT-2026 23:59:59','DD-MON-YYYY HH24:MI:SS')
AND END_POINT_URL='https://cmp.sbi.bank.in/eis/updateOrder' and source_id='NB')
group by urn, INPUT_DATA, OUTPUT_DATA, creation_date_time;
commit;
spool off;
