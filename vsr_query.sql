  awk '/^20[0-9][0-9]-/{ts=substr($0,1,16)}
  /^ORA-04031: unable/{n=split($0,a,"\""); c[ts" |
  "a[6]" | "a[8]]++}
  END{for(k in c) print k" | "c[k]}' \
  /u01/app/oracle/diag/rdbms/hibdrcdb/HIBDRCDB1/trace/
  alert_HIBDRCDB1.log | sort



awk '/^20[0-9][0-9]-/{ts=substr($0,1,19)}
  ts>="2026-11-08T15:20" && ts<="2026-11-08T16:20" &&
  /Reconfiguration|MRP0|Managed Standby|Media
  Recovery|terminat/{print ts" "$0}' \
  /u01/app/oracle/diag/rdbms/hibdrcdb/HIBDRCDB1/trace/
  alert_HIBDRCDB1.log