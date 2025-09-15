#!/bin/bash

set -xe
export ORACLE_SID=MIBPRCDB2
export ORACLE_HOME=/u01/app/oracle/product/19.0.0.0/dbhome_1
export ORACLE_HOSTNAME=eissiprdbadm02
export ORACLE_PDB_SID=MIIBDRDB

date_in_file=$( date +%d_%m_%y)
#connection_string
user="sys"
password="password"
host="eissipr-scan1.sbi.co.in."
port="1786"
service="MIIBPRDB_SRV"



DUMP_DIRECTORY="STATIC"
DUMP_FILE="STATIC_TABLES_EXP_"${date_in_file}"_%L.dmp"
LOG_FILE="STATIC_TABLES_EXP_$date_in_file.log"

TABLE_TO_EXPORT="EISAPP.API_CONSUMER_DETAILS,EISAPP.CACHE_DETAILS,EISAPP.URL_MAPPER,EISAPP.SOURCE_MAPPER,EISAPP.SOURCE_MAPPER_CONTACT,EISAPP.SUPERVISORY_OVERRIDE_AUDIT,EISAPP.SUPERVISORY_OVERRIDE_MASTER,EISAPP.THIRD_PARTY_API_PARAMETER,EISAPP.THIRD_PARTY_API_MASTER,EISAPP.THIRD_PARTY_API_ACCESS_MASTER,EISAPP.SYS_URL_MAPPER"

expdp_command="
expdp
'$user/$password@$host:$port/$service as  sysdba'  \
DIRECTORY=$DUMP_DIRECTORY \
DUMPFILE=$DUMP_FILE \
LOGFILE=$LOG_FILE \
TABLES=$TABLE_TO_EXPORT \
compression=all \
COMPRESSION_ALGORITHM=MEDIUM \
cluster=N \
exclude=STATISTICS \
logtime=all \
metrics=yes \
parallel=4 \
"


#Execute_the_command

echo "Starting export of tables: $TABLE_TO_EXPORT"
echo "command: $expdp_command"

$expdp_command

if [ $? -eq 0 ]
then
echo "Export Successfull"
else
echo "Export failed,Check the log file"
fi

rsync -av -e ssh /backup_new/EXPDP/IIB_EXPDP/STATIC_TABLES/* oracle@10.188.10.82:/ftpbkp/db_bkp
if [ $? -eq 0 ]
then
echo "File_transfered"
else
echo "File_transfered not transfered"
fi
