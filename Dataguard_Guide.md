# Oracle Data Guard – Configuration, Network Tuning, Lag Troubleshooting, Switchover & Failover

Source of truth for the "as-is" section: `dataguard_configuration.txt` in this repo.
Items marked **[VERIFY]** are not in that file and must be confirmed on the actual systems before the runbook is used.

---

## 1. Current configuration (as-is)

### 1.1 Topology

| Item | Value (from file) |
|---|---|
| Primary `db_unique_name` | `MIBPRCDB` |
| Physical standby (DR) | `MIBDRCDB` (dest 2) |
| Other DG_CONFIG members | `eisdcbkp` (dest 3, remote backup/standby via SCAN), `GGINTMIN` (dest 4), `GGDRDB` (dest 5) – the GG* entries are GoldenGate foreign-archive targets, not standbys |
| Primary RAC | **6 instances / 6 redo threads** (v$log shows threads 1-6) |
| Transport mode | **ASYNC** to MIBDRCDB, no compression, `AFFIRM NO` |
| Protection mode | **[VERIFY]** `select protection_mode, protection_level from v$database;` (ASYNC transport ⇒ Maximum Performance) |
| Broker | **[VERIFY]** `show parameter dg_broker_start` (you switch over manually, so likely FALSE) |

```
 MIBPRCDB (6-node RAC)
   |-- dest_1  local FRA (all_logfiles, all_roles)
   |-- dest_2  ASYNC --> MIBDRCDB            ENABLED   <- the real DR standby
   |-- dest_3  ASYNC --> eisdcbkp (SCAN:1786) DEFERRED
   |-- dest_4  ASYNC/ARCH --> GG_DB (GGINTMIN) ENABLED  (GoldenGate archive feed)
   '-- dest_5  ASYNC/ARCH --> GGDRDB           DEFERRED
```

### 1.2 Key parameters

| Parameter | Value | Meaning / comment |
|---|---|---|
| `log_archive_config` | `DG_CONFIG=(MIBDRCDB,MIBPRCDB,eisdcbkp,GGINTMIN,GGDRDB)` | Every db_unique_name that may send/receive redo. A new standby must be added here on **all** members. |
| `log_archive_dest_1` | `location=USE_DB_RECOVERY_FILE_DEST valid_for=(all_logfiles,all_roles) db_unique_name=MIBPRCDB` | Local archiving. Good: valid in every role. |
| `log_archive_dest_2` | `service=MIBDRCDB async valid_for=(online_logfiles,primary_role) net_timeout=30 reopen=60 max_failure=10 db_unique_name=MIBDRCDB` | Redo transport to DR. See notes below. |
| `log_archive_dest_state_2` | ENABLE | |
| `log_archive_dest_3` | `SERVICE=eisdczdingest-scan1:1786/eisdcbkp:dedicated ASYNC VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=eisdcbkp` | `:dedicated` forces a dedicated server connection. **State = DEFER** – not shipping right now. |
| `log_archive_dest_4` / `_5` | `SERVICE=GG_DB / GGDRDB ASYNC NOREGISTER ARCH MAX_CONNECTIONS=3 ... TEMPLATE=/gg_foreign_archives/...` | GoldenGate downstream archive copies. dest_4 ENABLED, dest_5 DEFERRED. Not DG standbys. |
| `archive_lag_target` | 900 | Forces a log switch on every thread at least every 15 min. |
| `log_archive_max_processes` | 16 | Archiver (ARCn) processes; also used for gap resolution. |
| `log_archive_min_succeed_dest` | 1 | Only local dest_1 must succeed for a log to be reusable (normal for ASYNC). |
| `log_archive_format` | `%t_%s_%r.arc` | |

Dest 2 attribute notes:

* `ASYNC` – LGWR ships redo from the log buffer without waiting for the standby (no commit-time impact from network latency, but potential data loss on failover = current lag).
* `valid_for=(online_logfiles,primary_role)` – only ships **current redo while this DB is primary**. After a switchover this destination is inert on the new standby; that is correct, but the **new primary must have its own dest pointing back to the old primary** (see §5, step "prepare new primary").
* `reopen=60 max_failure=10` – after a failed connection, retry every 60 s, and **give up after 10 consecutive failures**. After that the destination goes to ERROR/"closed" and will not retry until you re-enable it (`alter system set log_archive_dest_state_2=defer; ... =enable;`). This is a classic cause of "lag keeps growing and nobody noticed" after a network outage > 10 min. Consider `max_failure=0` (retry forever) and monitor instead.
* `net_timeout=30` – effective for SYNC; with ASYNC it has little practical effect. Keep or remove, but don't rely on it for ASYNC.
* No `compression` – `COMPRESSION=DISABLE` in `gv$archive_dest`. Compression needs the Advanced Compression option (licence).

### 1.3 Redo logs

| | Primary online redo (v$log) | Standby redo (v$standby_log) |
|---|---|---|
| Size | ~10 GB (1.0737E+10 bytes) | ~10 GB |
| Block size | 512 | 512 |
| Members | 2 per group | – |
| Groups | 60 = **10 per thread × 6 threads** | 66 = **11 per thread × 6 threads** |

Standby redo rule: **(online groups per thread + 1) × threads** – 66 = (10+1)×6. ✔ Correct, and the sizes match the online logs, as required. Because the primary can become a standby after switchover, these SRLs must exist on **both** databases. The listing shows them `UNASSIGNED` on the primary, which is expected (SRLs are only used when it is a standby).

**Observation:** 10 GB logs mean a log switch only every few minutes on a busy thread but every 15 min (archive_lag_target) on a quiet one. ASYNC transport ships redo continuously from the log buffer, so large logs do not by themselves delay the standby; they do make archive-based gap fills (a 10 GB file per sequence) slow.

### 1.4 Parameters not in the file – check on both sites **[VERIFY]**

```sql
show parameter fal_server
show parameter fal_client
show parameter standby_file_management     -- should be AUTO
show parameter db_file_name_convert
show parameter log_file_name_convert
show parameter db_unique_name
show parameter dg_broker_start
show parameter db_lost_write_protect       -- TYPICAL recommended
show parameter db_block_checking
show parameter db_flashback_retention_target
select flashback_on, force_logging from v$database;   -- both should be YES (needed for reinstate / no nologging holes)
```

On the standby: `fal_server=MIBPRCDB`; after a switchover each side's `fal_server` must point to the **other** side (set both in advance, §5).

### 1.5 Scripts in the config file / repo

| Script | Purpose |
|---|---|
| `er.sql <dest_id>` | Shows `gv$archive_dest` row per instance for one destination: error, status, last log sequence shipped, valid_type, remote template. Run `@er 2` first when lag is reported. |
| `missing_log.sql`, `role.sql` (repo) | Gap check / role check – see the files. |

Reading the `@er 2` output in the file: all 6 instances show `STATUS=VALID`, empty ERROR, and `LOG_SEQUENCE` equal to each thread's current online log (269123, 270827, 240591, 237713, 218223, 209205 = the CURRENT groups in v$log). That means redo was being shipped to the DR in real time, with no destination errors at the time of capture. The `@er 4` output shows `LOG_SEQUENCE 0` for GG – GoldenGate is receiving files via the ARCH template rather than a sequence counter, which is normal for that feed.

---

## 2. Network parameters

Redo transport is a long-lived TCP stream per instance (LGWR/NSS → RFS on the standby), so throughput is limited by **bandwidth-delay product (BDP)** and TCP window sizing, not just by link speed.

### 2.1 Size the pipe first

```
Redo rate (MB/s)   = from AWR "Redo size per second" at peak, or:
  select thread#, round(sum(blocks*block_size)/1024/1024) mb, count(*)
  from v$archived_log where first_time > sysdate-1 group by thread#;
BDP (bytes)        = bandwidth (bytes/s) × RTT (s)
Required bandwidth ≥ peak redo rate × 1.3 (headroom for catch-up)
```

Measure RTT: `ping -c 20 <standby-host>` or `tnsping MIBDRCDB`. A 1 Gbit/s link with 40 ms RTT has BDP ≈ 5 MB; default buffers (128 KB–few MB) will cap throughput far below link speed.

### 2.2 Oracle Net – `sqlnet.ora` (both primary and standby, in the Grid/DB home used by the listener & instances)

```
# Session data unit – larger = fewer, bigger packets for redo
DEFAULT_SDU_SIZE = 65535      # 12.2+ allows up to 2097152 (2 MB); test before raising
# Socket buffers – set to ~3 × BDP (must be ≤ OS rmem_max/wmem_max, see 2.3)
SEND_BUF_SIZE = 10485760
RECV_BUF_SIZE = 10485760
# Detect dead peers (important for DG so RFS/NSS don't hang for hours)
SQLNET.EXPIRE_TIME = 10       # minutes
TCP.NODELAY = YES             # default; leave on
```

Also set the SDU/buffers on the **TNS alias** and **listener** for the DR service so both ends negotiate it:

```
MIBDRCDB =
  (DESCRIPTION =
    (SDU = 65535)
    (SEND_BUF_SIZE = 10485760)(RECV_BUF_SIZE = 10485760)
    (ADDRESS = (PROTOCOL = TCP)(HOST = <dr-scan>)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = MIBDRCDB)))

# listener.ora – same SDU / buffer attributes on the listening address / DESCRIPTION
```

(`dest_3` already uses an easy-connect string with a dedicated server; if it is ever re-enabled, note that SDU/buffer sizes cannot be set in easy connect – use a tnsnames alias.)

### 2.3 OS TCP settings (Linux, both sites – values are starting points)

```
# /etc/sysctl.d/99-dataguard.conf
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.core.netdev_max_backlog = 30000
```

`sysctl -p /etc/sysctl.d/99-dataguard.conf`; **restart the redo-shipping sessions** (defer/enable the dest) for new sockets to pick up buffers.

Other network items:

* **MTU / jumbo frames** – use the same MTU end-to-end; mismatched MTU + blocked ICMP causes silent fragmentation stalls. Test: `ping -M do -s 8972 <host>` (jumbo) / `-s 1472` (standard).
* **Firewalls / WAN accelerators** – must not do SSL or Oracle Net "inspection" (SQL*Net ALG); stateful firewalls with short idle timeouts drop idle redo connections → use `SQLNET.EXPIRE_TIME` below the firewall idle timeout.
* **Ports** – listener port(s) on both sides open both directions (needed after switchover). Include the SCAN port for RAC.
* **Redo compression** (`COMPRESSION=ENABLE` on the dest) – use when bandwidth-bound and CPU is available; requires Advanced Compression licence.
* **Redo transport encryption / TLS** – see `tls_in_prod.txt` in this repo if the DR link is TLS.
* **Multiple RAC instances** – each primary instance opens its own stream, so aggregate throughput is the sum; make sure the DR SCAN/listener is not funnelling everything to one node. Specific `SERVICE`/`SERVER=DEDICATED` entries are fine.

### 2.4 Verify

```sql
-- Transport destination health, every instance
select inst_id, dest_id, status, error, gap_status, archived_seq#, applied_seq#
from gv$archive_dest_status where dest_id=2;

-- Network round-trip as seen by Oracle for ASYNC (12c+)
select * from v$redo_dest_resp_histogram where dest_id=2;
```

---

## 3. Lag – tuning and troubleshooting

### 3.1 Two kinds of lag – find which one first

On the **standby**:

```sql
col name for a25
select name, value, unit, time_computed from v$dataguard_stats
where name in ('transport lag','apply lag','apply finish time','estimated startup time');
```

| Symptom | Meaning | Look at |
|---|---|---|
| **transport lag** high | Redo has not arrived at the standby | primary → network, dest errors, LGWR/NSS, bandwidth |
| **apply lag** high, transport ≈ 0 | Redo is there but not applied | MRP, standby I/O, parallelism, long-running recovery, redo apply stuck |
| Both high | Often transport first, then apply catching up; check transport first | |

Always check per **thread** (6 threads) – one stuck instance's stream can hide behind healthy ones:

```sql
-- primary
select thread#, max(sequence#) from v$archived_log where dest_id=1 group by thread#;
-- standby
select thread#, max(sequence#) from v$archived_log where applied='YES' group by thread#;
select thread#, max(sequence#) received from v$archived_log group by thread#;
```

### 3.2 Transport lag checklist (primary side)

1. `@er 2` (script in this repo) – any ERROR text? STATUS other than VALID?
   * `ORA-12541/12514/12170/12535` → listener/TNS/firewall/network.
   * `ORA-16086` standby has no SRL / SRL too small. `ORA-16191/1017` → password-file/ SYS password mismatch between sites (redo transport uses the password file).
   * Destination `ERROR` with `max_failure` exhausted → re-enable:
     ```sql
     alter system set log_archive_dest_state_2=defer  scope=memory;
     alter system set log_archive_dest_state_2=enable scope=memory;
     ```
2. `select * from v$archive_gap;` on standby – a gap. Fix by letting FAL fetch it (`fal_server`), or copy the missing archive log and `alter database register logfile '<file>';`.
3. Primary alert log + `dest_2` `NSS`/`LNS`/`TTnn` trace for messages about slow network / "LGWR: ASYNC … timeout".
4. Network: throughput test with `iperf3` between hosts; compare to peak redo rate (§2.1). `netstat -s | grep -i retrans`, `ss -ti dst <standby-ip>` (look at `cwnd`, `rtt`, `retrans`).
5. Redo generation spikes: batch jobs, index rebuilds, `NOLOGGING`, huge loads → check AWR / `v$sysstat 'redo size'`; the pipe may simply be smaller than the peak.
6. Log buffer pressure on primary: waits `log file parallel write`, `LGWR wait for redo copy`; archiving stuck (`log_archive_max_processes`, FRA full). Check `select * from v$recovery_file_dest;`.
7. Reduce load: enable redo **compression**, increase SDU/socket buffers (§2), or run catch-up via archived logs (ARCH) in parallel (already 16 ARCn).

### 3.3 Apply lag checklist (standby side)

```sql
-- Is MRP running, what is it doing?
select process, status, thread#, sequence#, block#, blocks from v$managed_standby order by process;
-- Apply rate
select * from v$recovery_progress where item in ('Active Apply Rate','Average Apply Rate','Redo Applied','Last Applied Redo','Active Time');
-- Parallel recovery servers
select * from v$dataguard_process;      -- 12.2+
-- What apply is waiting on
select event, total_waits, time_waited from v$system_event
where event like '%recovery%' or event like 'db file%' order by time_waited desc;
select * from v$standby_event_histogram;
```

Typical causes and fixes:

| Cause | Evidence | Fix |
|---|---|---|
| MRP stopped / not started | no `MRP0` in v$managed_standby | `alter database recover managed standby database using current logfile disconnect;` |
| Standby storage slow | `db file parallel write`, high apply I/O wait, `free buffer waits` | faster/more disks, ASM rebalance, more `db_writer_processes`, check no backup/RMAN on the standby at the same time |
| Single-threaded recovery | one `MRP0` and no PR0x slaves | enable parallel recovery: `alter database recover managed standby database using current logfile parallel 16 disconnect;` (start with CPU count / 2); or `recovery_parallelism`. 12.2+ auto-parallel for multi-instance redo apply (MIRA) – works across RAC standby instances. |
| Redo apply of large single transactions / NOLOGGING recovery | stuck on one sequence | wait; check `v$recovery_progress` |
| Insufficient SGA / `db_cache_size` on standby | `free buffer waits` | give the standby a proper buffer cache; same hugepage setup as primary (see `hugepage.sh`) |
| Real-time apply off | apply only after full archive logs | use `USING CURRENT LOGFILE` (needs SRLs – present) |
| Delay configured | `DELAY=` on dest or apply | `alter database recover managed standby database cancel; … nodelay` |
| Lost write / corruption | MRP crashes ORA-600/ORA-10567 | alert log, `db_lost_write_protect`, re-instantiate the datafile from primary (RMAN `restore from service`) |

### 3.4 Quick lag monitoring query (run every few minutes)

```sql
-- standby
select name, value from v$dataguard_stats where name in ('transport lag','apply lag');
-- primary – is every thread's current seq on the standby?
select inst_id, dest_id, status, error, log_sequence from gv$archive_dest where dest_id in (2);
```

---

## 4. Manual switchover vs failover

| | **Switchover** | **Failover** |
|---|---|---|
| When | Planned (maintenance, DR test) | Primary lost / unrecoverable |
| Data loss | None | Possible (up to the transport lag, ASYNC); zero only if the lag was 0 |
| Old primary | Becomes standby immediately | Must be **reinstated** (Flashback) or rebuilt |
| Reversible | Yes, any time | Only if flashback was on |
| Downtime | Minutes | Minutes (+ rebuild later) |

---

## 5. Manual switchover runbook (MIBPRCDB ⇄ MIBDRCDB)

> Run each step on the indicated site. `P` = current primary (MIBPRCDB), `S` = standby (MIBDRCDB). Test in non-prod first. Confirm Oracle version: the `SWITCHOVER TO … VERIFY` / `ALTER DATABASE SWITCHOVER` commands need 12.2+, otherwise use the `COMMIT TO SWITCHOVER` form.

### 5.1 Prechecks (T-1 day and again T-30 min)

```sql
-- P and S
select name, db_unique_name, database_role, open_mode, protection_mode, switchover_status from v$database;
select force_logging, flashback_on from v$database;
-- S: lag
select name, value from v$dataguard_stats where name in ('transport lag','apply lag');   -- should be 0
-- S: no gap
select * from v$archive_gap;
-- both: SRLs exist and match (60 online + 66 standby on P, same on S)
select thread#, count(*) from v$standby_log group by thread#;
-- P: dest healthy
@er 2
-- P: no invalid objects / jobs risk – stop scheduler/DBMS_JOB, GG, batch
-- P: switchover_status should be TO STANDBY or SESSIONS ACTIVE
-- Password files identical on both sites (same SYS password), listener & TNS on both sides tested both directions
-- fal_server / log_archive_dest_2 for the *reverse* direction prepared (below)
-- Backup: take a fresh backup and a guaranteed restore point on both DBs:
create restore point before_switchover guarantee flashback database;
```

12.2+ validation (no changes made):

```sql
-- P
alter database switchover to MIBDRCDB verify;
```

Prepare the **reverse direction in advance** (so the new primary ships to the old one immediately):

```sql
-- On S (to become primary): point dest_2 at the old primary, set fal toward it
alter system set log_archive_dest_2='service=MIBPRCDB async valid_for=(online_logfiles,primary_role) net_timeout=30 reopen=60 max_failure=10 db_unique_name=MIBPRCDB' scope=both sid='*';
alter system set log_archive_dest_state_2=defer scope=both sid='*';   -- enable after the switch
alter system set fal_server='MIBPRCDB' scope=both sid='*';
-- On P: fal_server must point to the future primary
alter system set fal_server='MIBDRCDB' scope=both sid='*';
```

On both: `log_archive_config` already lists both names ✔.

### 5.2 Quiesce the application and the GG/other consumers

* Stop application connections/services (`srvctl stop service -d MIBPRCDB`).
* Stop GoldenGate extract(s) reading from `GG_DB` / `GGDRDB` feeds, **after** letting them reach the current SCN (`SEND EXTRACT … LOGEND` / lag 0). dest_4/dest_5 are `VALID_FOR=(…,PRIMARY_ROLE)`, so after the switchover they ship from the new primary only, if its dest_4/5 are configured identically (§5.6).
* Stop scheduler jobs, `alter system archive log current;` on P and check the standby has received and applied it:

```sql
-- P
alter system archive log current;                 -- RAC: this switches all threads
-- S, repeat until max applied seq per thread = P's last seq
select thread#, max(sequence#) from v$archived_log where applied='YES' group by thread#;
```

### 5.3 Convert the primary to a standby (P)

RAC primary: shut down all instances except one first.

```
srvctl stop instance -d MIBPRCDB -i MIBPRCDB2,MIBPRCDB3,MIBPRCDB4,MIBPRCDB5,MIBPRCDB6 -o immediate
```

On the remaining instance:

```sql
select switchover_status from v$database;     -- TO STANDBY (or SESSIONS ACTIVE)
alter database commit to switchover to physical standby with session shutdown;   -- all versions
-- 12.2+ one-step alternative, run on P (also converts S for you if the broker/redo is up):
-- alter database switchover to MIBDRCDB;

shutdown immediate
startup mount
```

### 5.4 Convert the standby to the primary (S)

```sql
select switchover_status from v$database;     -- must be TO PRIMARY (or SESSIONS ACTIVE)
alter database commit to switchover to primary with session shutdown;
alter database open;
-- RAC: bring up the other instances
srvctl start database -d MIBDRCDB      -- or start the rest of the instances
```

If `TO PRIMARY` is not reached, the last redo hasn't arrived/applied – check the end-of-redo (EOR) marker: `select * from v$archived_log order by first_time desc` and the alert logs; do **not** use `FORCE`.

### 5.5 Start redo on the new primary and apply on the new standby

```sql
-- New primary (MIBDRCDB)
alter system set log_archive_dest_state_2=enable scope=both sid='*';
alter system switch logfile;
-- New standby (MIBPRCDB)
alter database recover managed standby database using current logfile parallel 16 disconnect;
```

(`srvctl modify database -d MIBPRCDB -role PHYSICAL_STANDBY -startoption mount` and `srvctl modify database -d MIBDRCDB -role PRIMARY -startoption open` so CRS starts them correctly after a reboot; do the same for **role-based services**: `srvctl modify service … -role PRIMARY`.)

### 5.6 Rebuild secondary destinations and downstream feeds on the new primary

* Destinations 3, 4, 5 on the new primary (`MIBDRCDB`): replicate the `log_archive_dest_3/4/5` definitions and states (GG templates, eisdcbkp service) – **if the DR database does not already have them, GG and eisdcbkp stop receiving redo after the switchover**.
* Re-point GG extract to the new primary, restart.
* Fix `log_archive_dest_2` leftovers and TNS aliases for apps/clients (use a role-based service/SCAN so clients follow automatically).

### 5.7 Post-checks

```sql
-- both
select name, db_unique_name, database_role, open_mode, switchover_status from v$database;
-- new primary
@er 2
select dest_id, status, error, gap_status from v$archive_dest_status where dest_id=2;
-- new standby
select process, status, thread#, sequence# from v$managed_standby;
select name, value from v$dataguard_stats;
-- new primary: log switch test, standby catches up in seconds
alter system switch logfile;
```

Start application services on the new primary: `srvctl start service -d MIBDRCDB`.
Drop the restore point when satisfied: `drop restore point before_switchover;`.

### 5.8 Switch back

Repeat the same procedure with roles reversed. Keep the config symmetric (§5.1 "reverse direction") so each side is always ready.

---

## 6. Failover runbook (primary unavailable)

**Decide first**: can the primary be restored quickly? A failover is a one-way decision. Record the last received/applied SCN.

On the standby (MIBDRCDB):

```sql
-- 1. See what we have
select thread#, max(sequence#) from v$archived_log group by thread#;
select * from v$archive_gap;
-- 2. Copy any available archived/SRL data from the old primary if reachable and register:
--    alter database register or replace logfile '<file>';
-- 3. Finish apply (applies all received redo, including partial SRL contents)
alter database recover managed standby database finish;     -- add FORCE if it hangs
-- 4. Activate (11g-style) …
alter database commit to switchover to primary with session shutdown;   -- if status is TO PRIMARY
--    … or
alter database activate physical standby database;                     -- if data loss is accepted
--    12.2+ single command:
-- alter database failover to MIBDRCDB;
alter database open;
```

After the failover:

1. Open the app services on the new primary; check GG, backups, other destinations (§5.6).
2. When the old primary is repaired, **do not open it** – it would diverge. Reinstate it:
   ```sql
   -- on the new primary: find the SCN where the standby became primary
   select standby_became_primary_scn from v$database;
   -- on the old primary (mount): flashback to just before that SCN
   flashback database to scn <standby_became_primary_scn>;
   alter database convert to physical standby;
   -- startup mount; start MRP; update dest_2/fal_server as in §5.1
   ```
   If flashback is unavailable/insufficient, re-create it from RMAN (`duplicate … from active database` or `restore from service`).
3. Re-check `log_archive_dest_*`, `fal_server`, SRLs, and password files on both sides.

---

## 7. Common pitfalls (summary)

1. `max_failure=10 reopen=60` exhausts after ~10 min of outage → destination silently closes; monitor `gv$archive_dest.status`.
2. After switchover, the new primary has no `dest_3/4/5` → GG / eisdcbkp starve. Pre-configure and test.
3. `fal_server` not flipped → gap resolution fails after the role change.
4. SRLs missing or smaller than online logs on either site → ORA-16086 / transport stalls.
5. Password-file mismatch → ORA-1017/ORA-16191 on transport.
6. `FORCE_LOGGING` not YES → NOLOGGING operations leave unrecoverable blocks on the standby.
7. Switching over RAC without stopping the other instances → `SESSIONS ACTIVE` / failure.
8. `archive_lag_target=900` with 6 threads of 10 GB logs: fine for ASYNC, but a quiet thread still ships a mostly empty file every 15 min; don't lower it unless the RPO demands it.
9. Standby apply not started in real-time mode (`USING CURRENT LOGFILE`).
10. Applications connecting by host name instead of role-based service/SCAN → manual TNS edits every switchover.

---

## 8. Quick-reference queries

```sql
-- Role / mode
select name, db_unique_name, database_role, open_mode, protection_mode, switchover_status from v$database;
-- Dest status (primary)
select inst_id, dest_id, status, target, archiver, schedule, destination, error from gv$archive_dest where dest_id in (2,3,4,5);
-- Lag (standby)
select name, value, time_computed from v$dataguard_stats;
-- Gap (standby)
select * from v$archive_gap;
-- MRP / RFS
select process, status, client_process, thread#, sequence#, block# from v$managed_standby;
-- Last applied per thread (standby)
select thread#, max(sequence#) from v$archived_log where applied='YES' group by thread#;
-- Log shipping history
select thread#, sequence#, first_time, applied from v$archived_log where dest_id=2 order by first_time desc fetch first 20 rows only;
-- Standby redo logs
select group#, thread#, sequence#, status, bytes/1024/1024/1024 gb from v$standby_log;
```
