# Creating a RAC Physical Standby – Methods, Production Best Practice, Runbooks

Companion to `Dataguard_Guide.md` (as-is configuration, tuning, switchover/failover).
Environment used for examples: Oracle 19c, RAC primary `MIBPRCDB` (6 nodes) -> RAC standby `MIBDRCDB` (6 nodes), ~20-30 ms RTT, backhaul port 1785, 10 GB redo logs, Max Performance/ASYNC.
Lab example at the end of §4 uses `teszt` / `standby` (2 nodes).

> Passwords are written as `<SYS_PASSWORD>`. Never put a real password on a command line (visible in `ps`, shell history, logs) or in this repo.
> Test the whole procedure on non-prod first. Anything marked **[VERIFY]** must be confirmed on your systems.

**Contents:** 1 Choosing a method · 2 Planning and sizing · 3 Prerequisites checklist · 4 Method A – backup-based RMAN duplicate (recommended) · 5 Method B – active duplicate · 6 Method C – restore from service (manual, 12c+) · 7 Method D – DBCA (lab/small DB) · 8 Converting to RAC and registering in CRS · 9 Configure Data Guard after the build · 10 Validation · 11 Production best practices · 12 Troubleshooting · 13 Rollback · 14 Timeline template

---

## 1. Choosing a method

| Method | How it gets the data | Impact on primary | Network | Control / restartability | Use when |
|---|---|---|---|---|---|
| **A. RMAN duplicate from backup** (`DUPLICATE ... FOR STANDBY` without `FROM ACTIVE DATABASE`) | Reads backup pieces (copied/ shipped/ NFS to DR site) | Very low (only metadata/ archived logs) | Backup transfer is done once, offline, any tool (rsync, NFS, tape, Exadata/ZDLRA) | High; can resume after failure | **Production, large DB, WAN.** Recommended. |
| **B. RMAN active duplicate** (`FROM ACTIVE DATABASE`) | Streams datafiles primary -> standby over SQL*Net | High (I/O + CPU + network for hours) | Needs sustained bandwidth, `COMPRESSED BACKUPSET` helps | Medium; failure restarts the whole thing | Medium DB, good link, no usable backup, short outage window |
| **C. RMAN `RESTORE ... FROM SERVICE` / `RECOVER STANDBY DATABASE FROM SERVICE`** | Restores datafiles straight from the primary's service, roll forward from the same service | Medium; can be throttled, per-file | Same as B but resumable per datafile | Highest granularity; used also to **re-sync a lagging standby** with an incremental | Rebuild/re-sync, or when you want full manual control |
| **D. DBCA `-createDuplicateDB -createAsStandby`** | Wrapper around B | As B | As B | Low (hard to tune/resume) | Labs, small DBs |
| **E. OCI/OEM/Cloud Control wizards** | Wrapper around B | As B | As B | Low | Teams that standardise on the tool |

**Rule of thumb for MIBPRCDB:** Method A for the first build (no load on the primary, WAN-friendly, repeatable), then Method C's incremental roll forward to shorten the catch-up. Use B only if there is no recent usable backup.

How long will it take? `time ≈ (DB size [after compression if used]) / min(disk read, network, disk write throughput)`. Measure the weakest link (e.g. 1 Gbit/s ≈ 100 MB/s ≈ 360 GB/h; 10 Gbit/s ≈ 1 GB/s ≈ 3.6 TB/h in practice about 60-70% of that).

---

## 2. Planning and sizing

1. **Capacity on the standby**: ASM `+DATA` ≥ total datafile size + growth; `+RECO/+FRA` ≥ archived logs for the apply lag you accept + flashback logs (target: 24 h of redo + changed blocks) + standby redo logs. Add 20-30 % headroom. Check `v$asm_diskgroup`, `ASM compatible` attributes (`compatible.asm`, `compatible.rdbms`) are ≥ what the primary uses.
2. **Same Oracle home, same patch level** (RU, one-offs): `opatch lspatches` must match on all nodes of both sites. Do **not** build with a lower patch level on the standby.
3. **Same OS-level tuning**: hugepages, `ulimit`, kernel parameters, time zone/NTP (clock skew breaks `redo apply` ordering checks and logging), same character set.
4. **Network**: ports open both directions (listener 1785 backhaul and, if used, SCAN), the whole redo path tuned (SDU, socket buffers, `rmem_max/wmem_max`) – see `Dataguard_Guide.md` §2. Latency ~20-30 ms: use compression for the initial copy, ASYNC for ongoing.
5. **Name resolution**: `tnsnames.ora` on every node of both sites with aliases for both databases (static + dynamic), identical in both directions so a switchover needs no change.
6. **Security**: if TDE is used, copy the wallet (and auto-login wallet) to the standby; copy `orapw` (password file; in 19c it is also stored in ASM for RAC – use `orapwd` with `file='+DATA/...'` or `srvctl` pwfile config). The SYS password must be the same on all sites. Add the `SYS`/`SYSDG`/`SYSBACKUP` users needed for Data Guard.
7. **Maintenance window**: Methods A/B/C do not need downtime on the primary. Plan a change record, a rollback (§13) and the decision point "abort if not synchronised by X".
8. **Backup retention**: archived logs required between the start of the backup and the end of apply must **not** be deleted on the primary (see §11.6).

---

## 3. Prerequisites checklist

### 3.1 Primary

```sql
select name, db_unique_name, log_mode, force_logging, flashback_on, database_role, protection_mode from v$database;
```

| Item | Required value | Fix |
|---|---|---|
| Log mode | `ARCHIVELOG` | `alter database archivelog;` (needs restart, single window) |
| `force_logging` | `YES` | `alter database force logging;` |
| `flashback_on` | `YES` (strongly recommended) | `alter database flashback on;` (check FRA size first) |
| `db_recovery_file_dest(_size)` | Set and large enough | `alter system set ... scope=both sid='*';` |
| Standby redo logs | (online groups per thread + 1) × threads, **same size as online logs** | see §9.2 |
| Password file | exists, shared by all RAC nodes | `srvctl config database -d <db>` shows the path |
| `standby_file_management` | `AUTO` | `alter system set standby_file_management=AUTO scope=both sid='*';` |
| `remote_login_passwordfile` | `EXCLUSIVE` | spfile |
| `db_block_checking`, `db_lost_write_protect` | Evaluate (`TYPICAL` for lost write; `MEDIUM` on the standby) | see guide §1.4 |
| Dedicated `SYS`-capable connection from the standby to the primary | works from **every standby node** | `sqlplus sys/...@MIBPRCDB as sysdba` |
| Latest RMAN full/incremental backup available (Method A) | A recent backup of **datafiles + archived logs + controlfile + spfile**, restorable and tested | `list backup summary; restore database validate;` |

### 3.2 Standby hosts

| Item | Check |
|---|---|
| GI running, ASM diskgroups mounted on all standby nodes | `crsctl stat res -t`, `asmcmd lsdg` |
| DB software installed, same RU, same `ORACLE_HOME` path ideally | `opatch lspatches` |
| OS users, groups, limits as on primary | `id oracle`, `ulimit -a` |
| Static listener entry for the **auxiliary instance** (NOMOUNT needs static registration) | see §4.3 and guide §1.7 |
| `/etc/oratab` entry for the standby, `ORACLE_SID` set | |
| Enough space in `$ORACLE_BASE/admin/<db_unique_name>/{adump}` (create directories) | |
| Same `compatible`, `nls_*`, character set (automatic with duplicate) | |

### 3.3 Information to collect before starting

```sql
-- primary
select * from v$version;
select name, value from v$parameter where isdefault='FALSE' order by name;   -- save for the standby spfile
select thread#, group#, bytes/1024/1024 mb, members from v$log order by thread#, group#;
select thread#, group#, bytes/1024/1024 mb from v$standby_log order by thread#, group#;
select count(*), sum(bytes)/1024/1024/1024 gb from v$datafile;
select * from v$recovery_file_dest;
select instance_number, instance_name, host_name, thread# from gv$instance;
```

---

## 4. Method A – RMAN duplicate from backup (recommended for production)

Flow: take/identify backup -> move it to the DR site -> prepare the auxiliary instance -> `DUPLICATE ... FOR STANDBY` -> catch up with an incremental -> convert to RAC -> configure DG.

### 4.1 Backup on the primary (if a fresh one is needed)

```
RMAN> CONFIGURE DEVICE TYPE DISK PARALLELISM 8 BACKUP TYPE TO COMPRESSED BACKUPSET;
RMAN> BACKUP AS COMPRESSED BACKUPSET SECTION SIZE 64G DATABASE FORMAT '/backup/MIBPRCDB/dg_%d_%T_%U_s%s_p%p' TAG 'DG_BUILD';
RMAN> BACKUP ARCHIVELOG ALL NOT BACKED UP FORMAT '/backup/MIBPRCDB/arc_%d_%T_%U' TAG 'DG_BUILD';
RMAN> BACKUP CURRENT CONTROLFILE FOR STANDBY FORMAT '/backup/MIBPRCDB/stbyctl_%d_%T_%U' TAG 'DG_BUILD';
RMAN> BACKUP SPFILE FORMAT '/backup/MIBPRCDB/spf_%d_%T_%U' TAG 'DG_BUILD';
```

* `SECTION SIZE` splits big datafiles (multi-section backup) so all channels work in parallel.
* Use the same backup pieces for the first full + later incrementals (§4.7).
* If you already have regular backups (`eisdcbkp`, tape, ZDLRA), reuse them; verify first: `RESTORE DATABASE VALIDATE;` (reads the pieces, restores nothing).

### 4.2 Move the backup to the DR site

Any of: NFS/ZFS share visible to both sites; `rsync -a --partial --inplace -e "ssh"` with parallel streams; ZDLRA/Data Domain replication; tape/vault. The pieces must be visible to the standby auxiliary instance **under the same path as recorded in the catalog/controlfile**, or you use `BACKUP LOCATION` (§4.4 variant 2).

### 4.3 Prepare the auxiliary instance (standby node 1)

1. **Directories and environment**

```bash
export ORACLE_SID=MIBDRCDB1
export ORACLE_HOME=/u01/app/oracle/product/19.0.0.0/dbhome_1
mkdir -p /u01/app/oracle/admin/MIBDRCDB/adump
```

2. **Password file**: copy from the primary (or create with `orapwd`, same SYS password). For RAC with shared storage:

```bash
orapwd file='+DATA/MIBDRCDB/orapwMIBDRCDB' dbuniquename=MIBDRCDB password=<SYS_PASSWORD>   # ASM location, supported 12.2+
```
   Prefer copying the **primary's** file, so every user (SYSDG, SYSBACKUP, ...) is identical: `asmcmd pwcopy` on the primary, then `pwcopy` on the standby.

3. **Minimal init file** (`$ORACLE_HOME/dbs/initMIBDRCDB1.ora`) – the duplicate rebuilds the real spfile:

```
db_name='MIBPRCDB'
db_unique_name='MIBDRCDB'
sga_target=2G
# use db_create_file_dest etc. in SPFILE SET clause of the DUPLICATE
```

4. **Static listener** entry for the auxiliary (already exists as `GLOBAL_DBNAME=MIBDRCDB / SID_NAME=MIBDRCDB1` in the backhaul listener – see guide §1.7). `tnsping MIBDRCDB_AUX` from the primary must work.
5. **Start the instance NOMOUNT**:

```sql
sqlplus / as sysdba
SQL> startup nomount pfile='$ORACLE_HOME/dbs/initMIBDRCDB1.ora';
```

### 4.4 The DUPLICATE command

Connect to the **primary as TARGET** (metadata, catalog) and the standby as **AUXILIARY** (static service!):

```bash
rman target sys@MIBPRCDB auxiliary sys@MIBDRCDB_AUX  [catalog rman@RCAT]
```

**Variant 1 – backups visible under the same path/catalog** (no `FROM ACTIVE DATABASE`):

```
RMAN> RUN {
  ALLOCATE AUXILIARY CHANNEL a1 DEVICE TYPE DISK;
  ALLOCATE AUXILIARY CHANNEL a2 DEVICE TYPE DISK;
  ... (one channel per CPU/IO path, 8-16 typically)
  DUPLICATE TARGET DATABASE FOR STANDBY
    DORECOVER
    SPFILE
      SET db_unique_name='MIBDRCDB'
      SET cluster_database='FALSE'
      SET db_create_file_dest='+DATA'
      SET db_recovery_file_dest='+FRA'
      SET db_recovery_file_dest_size='<size>'
      SET control_files='+DATA','+FRA'
      SET fal_server='MIBPRCDB'
      SET log_archive_config='DG_CONFIG=(MIBPRCDB,MIBDRCDB)'
      SET log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=MIBDRCDB'
      SET log_archive_dest_2=''
      SET standby_file_management='AUTO'
      SET audit_file_dest='/u01/app/oracle/admin/MIBDRCDB/adump'
      SET local_listener=''
      SET remote_listener=''
    NOFILENAMECHECK;
}
```

* `DORECOVER` applies the archived logs available in the backup so the standby is as current as possible.
* `SPFILE ... SET` makes RMAN create the standby spfile from the primary's with these overrides. `cluster_database='FALSE'` for the build is deliberate (§8).
* Put **all** parameters whose values differ (instance/db_unique_name, dests, listeners, ASM locations) in `SET` clauses. Anything not set is copied from the primary.
* `NOFILENAMECHECK` is required when the datafile paths are the same string on both sites (e.g. both `+DATA`).

**Variant 2 – backup in an arbitrary directory (12.2+):**

```
RMAN> DUPLICATE TARGET DATABASE FOR STANDBY DORECOVER
        SPFILE SET db_unique_name='MIBDRCDB' ... NOFILENAMECHECK
        BACKUP LOCATION '/backup/MIBPRCDB';
```
Everything needed (datafile + archived log backups, controlfile for standby) must be inside that location.

**Variant 3 – active duplicate:** see §5.

### 4.5 Monitor

```sql
-- on the auxiliary during the duplicate
select * from v$session_longops where opname like 'RMAN%' and sofar<>totalwork;
-- on the OS
tail -f $ORACLE_BASE/diag/rdbms/mibdrcdb/MIBDRCDB1/trace/alert_MIBDRCDB1.log
```

### 4.6 What a successful duplicate leaves behind

Standby instance `MIBDRCDB1` **mounted** (not open, not recovering), controlfile = standby controlfile, spfile created, datafiles restored and recovered to the last archived log in the backup. Verify:

```sql
select name, db_unique_name, database_role, open_mode, protection_mode, controlfile_type from v$database;
-- expect PHYSICAL STANDBY, MOUNTED, STANDBY controlfile
```

### 4.7 Catch up – incremental roll forward (shortens the gap before redo shipping starts)

The duplicate finishes with the standby behind the primary by the time taken for the transfer and restore. If archived logs back to the backup are still on the primary, simply enabling redo transport (§9) is enough. If **not** (or if the gap is huge), roll forward with a compressed incremental taken **directly from the primary service** (12c+/18c+ syntax, resumes after failure):

```
RMAN> CONNECT TARGET sys@MIBDRCDB   (standby, mounted)
RMAN> RECOVER STANDBY DATABASE FROM SERVICE MIBPRCDB
        USING COMPRESSED BACKUPSET
        SECTION SIZE 64G;
```
This replaces datafile blocks changed since the standby's SCN (incremental based on the datafile checkpoint SCN) – much smaller than a full restore. If the controlfile is also stale (new datafiles were added meanwhile):

```
RMAN> RESTORE STANDBY CONTROLFILE FROM SERVICE MIBPRCDB;
RMAN> ALTER DATABASE MOUNT;
RMAN> CATALOG START WITH '+DATA/MIBDRCDB/DATAFILE/' NOPROMPT;   -- if datafile names changed
RMAN> RECOVER STANDBY DATABASE FROM SERVICE MIBPRCDB USING COMPRESSED BACKUPSET;
```

### 4.8 Lab example (2-node, 19c, DBCA)

```bash
# ⚠ lab only – do not use for production, password shown as placeholder
dbca -silent -createDuplicateDB \
  -gdbName teszt -sid teszt \
  -initParams db_create_file_dest=+DATA,db_recovery_file_dest=+FRA \
  -primaryDBConnectionString racnode1:1521/teszt \
  -sysPassword '<SYS_PASSWORD>' \
  -createAsStandby -adminManaged -databaseConfigType RAC \
  -nodelist racnode2-1,racnode2-2 \
  -dbUniqueName standby
```

---

## 5. Method B – active duplicate

Same preparation as §4.3 (auxiliary instance in NOMOUNT, password file, static listener). Command:

```
RMAN> RUN {
  ALLOCATE CHANNEL p1 DEVICE TYPE DISK;   -- target channels (primary)
  ... p1..pN
  ALLOCATE AUXILIARY CHANNEL a1 DEVICE TYPE DISK;
  ... a1..aN
  DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE
    USING COMPRESSED BACKUPSET
    SECTION SIZE 64G
    DORECOVER
    SPFILE
      SET db_unique_name='MIBDRCDB'
      SET cluster_database='FALSE'
      ...as in §4.4...
    NOFILENAMECHECK;
}
```

Points:

* `USING COMPRESSED BACKUPSET` compresses on the primary, decompresses on the standby – big win on a 30 ms WAN, costs CPU on the primary (consider `BASIC`/`MEDIUM`/`HIGH` via `CONFIGURE COMPRESSION ALGORITHM`).
* `USING BACKUPSET` (without compression) is the minimum for 12c+; without it RMAN uses image copies (slower).
* `SECTION SIZE` is what spreads one big file over many channels.
* Throttle if needed (primary is production): fewer channels, `RATE` on channels, or run during the quiet window.
* No fallback: if it fails you restart from scratch (datafiles already copied are not reused unless you use Method C).
* The primary must keep archived logs for the whole duration.

---

## 6. Method C – restore from service (manual, resumable)

Use when you want per-step control or to rebuild a broken standby. Also the standard way to re-sync a standby after a gap that archive logs cannot fill.

```
-- on the standby (auxiliary instance prepared as §4.3)
RMAN> CONNECT TARGET sys@MIBDRCDB
RMAN> RESTORE STANDBY CONTROLFILE FROM SERVICE MIBPRCDB;
RMAN> ALTER DATABASE MOUNT;
RMAN> RUN {
  ALLOCATE CHANNEL c1 DEVICE TYPE DISK; ... c8
  SET NEWNAME FOR DATABASE TO '+DATA';           -- only if diskgroup differs (OMF)
  RESTORE DATABASE FROM SERVICE MIBPRCDB
         USING COMPRESSED BACKUPSET SECTION SIZE 64G;
  SWITCH DATABASE TO COPY;
}
RMAN> RECOVER STANDBY DATABASE FROM SERVICE MIBPRCDB USING COMPRESSED BACKUPSET;
```

* Datafiles restored are tracked in the controlfile, so a repeated `RESTORE DATABASE` skips what is already done (`restore ... from service` is restartable).
* Create the spfile for the standby yourself (`create spfile='+DATA/MIBDRCDB/spfileMIBDRCDB.ora' from pfile`) and set the parameters in §9.1.

---

## 7. Method D – DBCA (lab / small database only)

`dbca -silent -createDuplicateDB -createAsStandby ...` (command in §4.8). What it does: copies password file, starts the auxiliary, runs RMAN `DUPLICATE ... FROM ACTIVE DATABASE FOR STANDBY`, creates the spfile, **registers the DB and instances in CRS** (`PHYSICAL_STANDBY`, start option `MOUNT`), mounts all RAC instances.

Why not for production: no control of channels/section size/compression, password on the command line, restart = full restart, unclear what is set for DG (you still do §9 manually).

Flags: `-gdbName` = DB_NAME (same as primary); `-dbUniqueName` = unique per site; `-sid` = instance prefix; `-nodelist` = standby nodes; `-primaryDBConnectionString` = host:port/service (use a service reachable from all standby nodes); `-initParams` = comma separated, no spaces.

---

## 8. Converting to RAC and registering in CRS

Duplicate builds a **single instance** (`cluster_database=FALSE`). Convert after the data is restored:

```sql
-- on instance 1 (standby, mounted)
alter system set cluster_database=TRUE scope=spfile sid='*';
-- per-instance parameters copied from the primary spfile, verify they exist:
--   MIBDRCDB1.instance_number=1, MIBDRCDB1.thread=1, MIBDRCDB1.undo_tablespace='UNDOTBS1'  ... through instance 6
select sid, name, value from v$spparameter where name in ('instance_number','thread','undo_tablespace') order by 1,2;
create pfile='/tmp/pfileMIBDRCDB.ora' from spfile;
shutdown immediate
```

Register with CRS (as `oracle`):

```bash
srvctl add database -db MIBDRCDB -oraclehome /u01/app/oracle/product/19.0.0.0/dbhome_1 \
   -dbtype RAC -role PHYSICAL_STANDBY -startoption MOUNT -stopoption IMMEDIATE \
   -spfile +DATA/MIBDRCDB/spfileMIBDRCDB.ora -pwfile +DATA/MIBDRCDB/orapwMIBDRCDB \
   -diskgroup DATA,FRA -policy AUTOMATIC
srvctl add instance -db MIBDRCDB -instance MIBDRCDB1 -node <node1>
... through MIBDRCDB6
srvctl start database -db MIBDRCDB -startoption MOUNT
srvctl status database -db MIBDRCDB -verbose
```

`-role PHYSICAL_STANDBY -startoption MOUNT` is essential: after a node reboot CRS must not open the standby read-only unless you intentionally run Active Data Guard (then use `-startoption "READ ONLY"`).

Create the spfile **in ASM** and have each `init<SID>.ora` in `$ORACLE_HOME/dbs` contain only `SPFILE='+DATA/MIBDRCDB/spfileMIBDRCDB.ora'`.

---

## 9. Configure Data Guard after the build

### 9.1 Parameters (both sites; values for MIBDRCDB shown)

```sql
alter system set db_unique_name='MIBDRCDB' scope=spfile sid='*';   -- already set
alter system set log_archive_config='DG_CONFIG=(MIBPRCDB,MIBDRCDB)' scope=both sid='*';
alter system set fal_server='MIBPRCDB' scope=both sid='*';
alter system set standby_file_management='AUTO' scope=both sid='*';
alter system set db_lost_write_protect='TYPICAL' scope=both sid='*';
alter system set db_block_checking='MEDIUM' scope=both sid='*';   -- standby; test primary separately
alter system set log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=MIBDRCDB' scope=both sid='*';
-- reverse-direction destination for switchover, DEFERRED until needed:
alter system set log_archive_dest_2='SERVICE=MIBPRCDB ASYNC NOAFFIRM REOPEN=15 MAX_FAILURE=0 COMPRESSION=DISABLE VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=MIBPRCDB' scope=both sid='*';
alter system set log_archive_dest_state_2='DEFER' scope=both sid='*';
```

Check the ones you already know from the existing primary (`Dataguard_Guide.md` §1.2/§1.4/§10). `dg_broker_start`: see §11.10.

### 9.2 Standby redo logs (on **both** databases)

Size = online log size (10 GB here). Count = (online groups per thread + 1) per thread. Primary has 10/thread -> 11 SRL per thread (66 total). Standby side must also have them:

```sql
select thread#, count(*), max(bytes)/1024/1024 mb from v$standby_log group by thread#;
-- if missing, per thread (OMF):
alter database add standby logfile thread 1 size 10G;   -- repeat 11 times per thread, threads 1..6
```
If the standby has more or fewer threads than the primary, create for each *primary* thread. Verify after the duplicate – a standby created from the primary controlfile sometimes already has them.

### 9.3 Enable transport on the primary

```sql
-- primary
alter system set log_archive_dest_2='SERVICE=MIBDRCDB ASYNC NOAFFIRM REOPEN=15 MAX_FAILURE=0 COMPRESSION=DISABLE VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=MIBDRCDB' scope=both sid='*';
alter system set log_archive_dest_state_2='ENABLE' scope=both sid='*';
alter system archive log current;           -- or switch each thread
```
`REOPEN`/`MAX_FAILURE` values are from the tuning proposal in the guide §10 – apply only after testing.

### 9.4 Start apply on **one** standby instance

```sql
-- standby, one instance only (the others stay mounted)
alter database recover managed standby database using current logfile disconnect from session;
```
* `USING CURRENT LOGFILE` = real-time apply (SRLs required).
* Stop with `alter database recover managed standby database cancel;`.
* Choose the apply instance deliberately; for RAC, `srvctl` has no MRP service, so document where it runs and which node takes over if it fails (restart MRP on another node).
* Parallel recovery: default uses `PARALLEL` = CPU count; tune with `alter database recover managed standby database ... parallel <n>` only if apply is the bottleneck.

### 9.5 Optional: Active Data Guard (read-only with apply)

Needs the ADG licence. `alter database open read only; alter database recover managed standby database using current logfile disconnect;` Then set CRS start option `READ ONLY`. Block change tracking on the standby for fast incrementals (`alter database enable block change tracking using file '+DATA';`) also needs ADG.

---

## 10. Validation

### 10.1 Immediately after enabling transport

```sql
-- primary
select inst_id, dest_id, status, error, gap_status from gv$archive_dest_status where dest_id=2;
select thread#, max(sequence#) from v$archived_log where dest_id=2 group by thread#;

-- standby
select name, value, time_computed from v$dataguard_stats where name in ('transport lag','apply lag','apply finish time');
select inst_id, process, status, thread#, sequence# from gv$managed_standby order by inst_id, process;
select thread#, low_sequence#, high_sequence# from v$archive_gap;   -- must be empty
select thread#, max(sequence#) applied from v$archived_log where applied='YES' group by thread#;
```

### 10.2 Integrity

```
RMAN> VALIDATE DATABASE;             -- on the standby, reads all blocks (schedule off-peak)
```
```sql
select * from v$database_block_corruption;   -- empty
```
Compare object/row counts of a few critical tables **after** opening the standby read-only (ADG) or via a snapshot standby test.

### 10.3 Role and CRS

```bash
srvctl config database -db MIBDRCDB          # role PHYSICAL_STANDBY, start option MOUNT
srvctl status database -db MIBDRCDB -verbose
crsctl stat res -t
```

### 10.4 Failover readiness test (before go-live)

1. Switchover test and back (runbook in `Dataguard_Guide.md` §5).
2. Test in non-prod: failover (guide §6) and reinstate (needs flashback).
3. Run the application's smoke tests against the new primary.

---

## 11. Production best practices – in depth

### 11.1 Method and impact
Prefer backup-based builds (Method A). Active duplicate pulls the entire DB through the primary's I/O and CPU; on a 30 ms link a TB-class DB takes many hours and competes with the workload. Use `SECTION SIZE`, `COMPRESSED BACKUPSET`, and limit channels. Never run it during month-end/batch peaks.

### 11.2 Identical software, tested transport
Same RU and one-offs both sides. Test the network (iperf3/ `tnsping`, `oradebug`) before the build. Set `SDU=65535`, socket buffers, `rmem/wmem_max`, `TCP.NODELAY` (guide §2).

### 11.3 Standby redo logs and archivers
(Online groups per thread + 1) SRLs per thread, same size, on **both** databases (even though the primary does not use them until a switchover). `log_archive_max_processes` ≥ 4 + number of destinations (you use 16). Put SRLs on fast storage – the standby I/O is write-heavy.

### 11.4 Transport mode and protection mode
Maximum Performance + `ASYNC` is correct across a 30 ms WAN. `SYNC/AFFIRM` (Max Availability) adds ~RTT to every commit – only consider it with a separate low-latency far-sync (`FAL`/`Far Sync` instance). `NOAFFIRM` avoids waiting for the standby disk write. See guide §9.4.

### 11.5 Enable flashback on both sites
Without flashback you cannot reinstate the old primary after a failover (full rebuild instead) and cannot use snapshot standby/ flashback-based tests. Size the FRA for retention (`db_flashback_retention_target`) and monitor `v$recovery_file_dest` and `v$flashback_database_log`.

### 11.6 Archive log retention and deletion policy
Do **not** let RMAN or a script delete archived logs the standby has not yet received/applied. Use one of:
```
RMAN> CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;
```
With **multiple destinations** (here: `eisdcbkp` and GoldenGate feeds) `ALL STANDBY` waits for all of them – a broken GG destination can fill the FRA. Common alternatives: `BACKED UP 2 TIMES TO DEVICE TYPE DISK` combined with a minimum retention window (e.g. keep 24 h), and monitor `v$flash_recovery_area_usage`. Always keep the archived logs that cover any running duplicate/roll-forward.

### 11.7 Security
Copy the TDE wallet and use the same master key; keep the wallet backup; protect `orapw` files; use a dedicated `SYSDG`/`SYSBACKUP` administrative account for DG operations where possible; use TLS for `SQL*Net` (e.g. `tls_in_prod.txt` in this repo) and restrict the listener port by firewall rules. Do not publish `sys` passwords anywhere (this repo, tickets, chat).

### 11.8 RAC specifics
* Build as single instance, then convert (§8). Do not create duplicates with `cluster_database=TRUE` in the spfile `SET`.
* Same number of instances/threads on the standby is recommended; fewer is allowed (one apply instance anyway) but a switchover needs all primary threads' redo mapped to SRLs.
* One apply instance: pin it to the node with the best CPU/I/O; document the failover of MRP.
* Use **SCAN** only for client connections; for redo transport use explicit backhaul addresses (as in this setup) or a `LOAD_BALANCE=OFF`, `FAILOVER=ON` list, and make sure all standby nodes' listeners accept the service.

### 11.9 Storage and file naming
Prefer OMF (`db_create_file_dest='+DATA'`) on both sides so no `*_FILE_NAME_CONVERT` is needed. If paths differ, set `db_file_name_convert`/`log_file_name_convert` in the standby spfile **before** the duplicate. `standby_file_management=AUTO` on both sides so new datafiles on the primary appear on the standby automatically. Keep the ASM diskgroup layout equivalent (redundancy, `au_size` where relevant).

### 11.10 Data Guard Broker (consider enabling)
Broker (`dg_broker_start=TRUE`, `dg_broker_config_file1/2` on shared storage) gives validated switchover/failover, monitoring (`SHOW CONFIGURATION`), and is a prerequisite for Fast-Start Failover and observers. Manual runbooks (guide §5/§6) remain valid; if you enable the broker, **stop setting `log_archive_dest_n` by hand** (the broker owns them).
```
DGMGRL> CREATE CONFIGURATION dg AS PRIMARY DATABASE IS MIBPRCDB CONNECT IDENTIFIER IS MIBPRCDB;
DGMGRL> ADD DATABASE MIBDRCDB AS CONNECT IDENTIFIER IS MIBDRCDB MAINTAINED AS PHYSICAL;
DGMGRL> ENABLE CONFIGURATION;
DGMGRL> VALIDATE DATABASE MIBDRCDB;      -- pre-switchover readiness
```

### 11.11 Monitoring and alerting (from day one)
Alert when: `transport lag` or `apply lag` > threshold (e.g. 5/10 min), `v$archive_gap` non-empty, destination status ≠ `VALID`, MRP not running, FRA > 80 %, standby `alert.log` has `ORA-00600`, `ORA-16xxx`. See guide §3.4 for the polling query. Test the alerts by stopping apply for a minute.

### 11.12 Backup strategy after the standby exists
Back up from the **standby** to offload the primary (backups taken on the standby are usable on the primary and vice versa as the DB is the same): full + incremental, archived log backups, and a **backup of the standby controlfile and spfile**. Using a recovery catalog is strongly recommended (the DB_UNIQUE_NAME is what RMAN records for each site).

### 11.13 Change management
Document: IP/ports, service names, DB_UNIQUE_NAMEs, the apply instance, SRL layout, runbooks, who can switch, the maximum acceptable lag (RPO) and the RTO. Re-run the switchover test after every major change (patch, network change, OS upgrade).

### 11.14 Patching (rolling)
Patch the standby first (it can lag behind meanwhile), then switchover and patch the old primary (Data Guard Standby-First patching, Oracle's recommended procedure for RUs). Never patch both at the same time.

---

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `RMAN-04006: error from auxiliary database: ORA-12154 / ORA-12514` | No static service for the NOMOUNT instance, wrong alias | Static `SID_LIST` entry (guide §1.7); `tnsping` from the primary; use `GLOBAL_DBNAME` that matches the connect string |
| `ORA-01017` on auxiliary | SYS password differs / password file not copied | Copy the primary password file; same password |
| `RMAN-06023: no backup or copy of datafile n found` | Backup not visible to the standby/catalog | Check path, `BACKUP LOCATION`, or `CATALOG START WITH` |
| `RMAN-05001: auxiliary file name conflicts with a file used by the target` | Same path on both sites | `NOFILENAMECHECK` |
| `ORA-19504/ORA-15041` | Diskgroup out of space | Add space, check `v$asm_diskgroup` |
| Duplicate OK but no redo shipping | `dest_state_2=DEFER`, not in `log_archive_config`, wrong `DB_UNIQUE_NAME`, standby listener | Check `v$archive_dest.error`, `v$dataguard_status`, alert.log |
| Standby redo not applying | MRP not started, no SRLs, gap | `v$managed_standby`, `v$archive_gap`; add SRLs; restart MRP |
| Gap that archived logs cannot fill (logs deleted) | Deletion policy too aggressive | Incremental roll forward (§4.7) |
| `ORA-16191: Primary log shipping client not logged on standby` | Password file mismatch, TCPS/wallet | Resync password file; check `remote_login_passwordfile` |
| CRS starts the standby open read-only | Wrong `srvctl` start option / role | `srvctl modify database -db MIBDRCDB -startoption MOUNT -role PHYSICAL_STANDBY` |
| `ORA-12528` on static-only listener | Instance down but service advertised statically | Start the instance; use dynamic registration for clients |

Useful logs: standby `alert_<SID>.log`, `v$dataguard_status`, `v$managed_standby`, RMAN output with `msgno`, listener log on both sides.

---

## 13. Rollback (if the build fails or is abandoned)

1. Primary: `alter system set log_archive_dest_state_2='DEFER';` (and clear `log_archive_dest_2` if you want).
2. Standby: `srvctl stop database -db MIBDRCDB`, `srvctl remove database -db MIBDRCDB` (and instances), `drop` the files if needed: `RMAN> startup mount force; drop database including backups;` (**only on the standby, never on the primary**).
3. Remove the extra entries from `log_archive_config` if added.
4. Release the archived logs held back for the build (revert the deletion-policy exception).

---

## 14. Timeline template (fill in estimates)

| Step | Owner | Est. | Notes |
|---|---|---|---|
| Prechecks (§3), change approval | DBA | 1 day | |
| Backup (or confirm backup) + validate | DBA/backup team | per size | `restore database validate` |
| Transfer backup to DR | Infra | per size/bandwidth | |
| Prepare auxiliary, static listener, password file | DBA | 1 h | |
| DUPLICATE | DBA | per size/throughput | monitor |
| Roll forward incremental | DBA | 1-3 h | |
| Convert to RAC, `srvctl` registration | DBA | 1 h | |
| DG parameters, SRLs, enable transport, start MRP | DBA | 1 h | |
| Validation + lag stabilisation | DBA | 4-24 h | watch lag |
| Switchover test + back | DBA + app | 2-4 h | non-prod first |
| Handover, monitoring, runbook sign-off | Team | 1 day | |

---

## 15. References

Oracle Data Guard Concepts and Administration 19c; RMAN Backup and Recovery User's Guide 19c (Duplicating Databases); Oracle Data Guard Broker 19c; Oracle MAA Data Guard best-practice papers.
