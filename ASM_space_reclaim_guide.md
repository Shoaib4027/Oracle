# Reclaiming space in an ASM diskgroup after dropping tables

Companion to `reclaim_asm_space.sql` (all queries) and `datafile_size_reclaim.txt` (resize output from our database).

## 1. The core idea

**Dropping tables does not return space to ASM.** It only frees space *inside* the datafiles.
The diskgroup gets space back only when a datafile is **shrunk (RESIZE)** or **dropped**.
Oracle never shrinks datafiles automatically, even with autoextend off.

## 2. Highest used block (HWM) - why files will not always shrink

A datafile can only shrink down to its **highest used block**: the end of the last extent that still belongs to a segment. It is calculated from `dba_extents` each time (`MAX(block_id + blocks - 1)` per file); it is not a stored value.

Example, 31 GB file with table A (0-10 GB), B (10-20 GB), C (20-31 GB):

| Action | Highest used block | Can shrink to |
|---|---|---|
| Drop A | stays at 31 GB (B, C still beyond it) | cannot shrink |
| Drop C | 20 GB | about 20 GB |
| Drop B and C | 10 GB | about 10 GB |

So dropping a table only helps if its extents were at the **end** of the file. Resizing below the highest used block fails with **ORA-03297**.

Dropped tables also sit in the **recycle bin** (still counted as used) unless dropped with `PURGE`. Run `PURGE DBA_RECYCLEBIN`.

## 3. Options to reclaim space (dropping tables is not the only one)

| Option | Command | Downtime |
|---|---|---|
| Drop empty datafiles | `ALTER TABLESPACE ts DROP DATAFILE 'file'` | None |
| Resize datafiles | `ALTER DATABASE DATAFILE 'file' RESIZE nM` | None |
| Shrink segments | `ALTER TABLE t ENABLE ROW MOVEMENT; ALTER TABLE t SHRINK SPACE` | Brief locks |
| Move objects online | `ALTER TABLE t MOVE ONLINE`, `ALTER INDEX i REBUILD ONLINE` | None (12.2+) |
| New tablespace, move, drop old | `DROP TABLESPACE old INCLUDING CONTENTS AND DATAFILES` | None to short |
| Purge recycle bin | `PURGE DBA_RECYCLEBIN` | None |
| Replace old undo/temp | switch to new undo tablespace, drop old | None |
| Delete obsolete backups/archivelogs | `RMAN> DELETE OBSOLETE;` | None |
| Drop/truncate unneeded data | `DROP TABLE ... PURGE`, `TRUNCATE ... DROP STORAGE` | Depends |
| Compress while moving | `ALTER TABLE t MOVE ... COMPRESS ...` (see sections 8 and 10) | Locks DML unless `ONLINE` is supported for that combination |
| Bigfile tablespaces | new bigfile tablespace, move objects | Planning needed |

Only dropping/truncating makes data disappear; everything else keeps the data.

## 4. Step by step procedure

1. Purge the recycle bin.
2. Find each file's minimum size (SQL file, section 2).
3. Drop completely empty files (section 3A / 5A). Not allowed for the first file of a tablespace or any file with extents.
4. Resize files whose free space is at the end (section 3B / 5B).
5. For files that cannot shrink, find what blocks them (section 6):
   - 6A: last extents of one file
   - 6B: blocking segment for every file in a tablespace
   - 6C: segments blocking the most files (move these first)
6. Move or shrink the blocking segments (table: `MOVE ONLINE`; index: `REBUILD ONLINE`; LOB: `MOVE LOB(col) STORE AS (TABLESPACE new_ts)`), then rerun step 2 and resize.
7. For tablespaces that are mostly empty: create a new tablespace, move live objects, drop the old one.
8. Check the diskgroup: `SELECT name, total_mb, free_mb, usable_file_mb FROM v$asm_diskgroup;` or `asmcmd lsdg`.

Do drops in batches in a quiet window and check `v$asm_diskgroup` between batches. Take a backup first.

## 5. Our database findings

Source: `datafile_size_reclaim.txt` (PDB `ARCDRCDB`, path `+ARCHDATA/ARCDRCDB/331CA43E.../DATAFILE/`).

- 9,410 datafiles, about **258 TB** allocated, mostly 31 GB smallfiles.
- Several tablespaces sit at **1,023 files**, the smallfile limit (1,022), so no more files can be added.
- Biggest tablespaces: IIB_ARCH_TBS_NEW (31.7 TB), IIB_ARCH_TBS_NEW3 (31.7 TB), ASSM_TBS_NEW (31 TB), IIB_ARCH_TBS (25.6 TB), IIB_ARCH_TBS_NEW4 (23 TB), IIB_ARCH_TBS_NEW1 (22.9 TB), ARCH_TBS (22.1 TB).
- Running the generated resizes (1,193 statements) frees about **10.4 TB**, of which about **5.8 TB** is non-undo, non-system:
  - Undo (`UNDOTBS_NEW` 1.9 TB, `UNDO_2` 2.8 TB): about 4.6 TB, but extent check ignores unexpired undo, so these may not shrink. Do not resize; create a new undo tablespace, switch, drop the old one.
  - SYSTEM / SYSAUX: about 30 GB. Do not resize.
  - Largest non-undo gains: IIB_ARCH_TBS_NEW 1.7 TB, IIB_ARCH_TBS_NEW1 1.2 TB, IIB_ARCH_TBS 1.0 TB, IIB_ARCH_TBS_NEW3 0.5 TB.
- 97 files shrink to under 1 GB: drop them instead of resizing (unless first file of the tablespace).
- Figures are approximate (the earlier listing rounded sizes to whole GB).
- Resizes alone reach only about 5.8 TB of 258 TB. Large further gains need the move-to-new-tablespace approach.

## 6. Cautions

- `dba_extents` is very slow on a database this size: filter by tablespace, one at a time; or use `dba_free_space`.
- Block size is hardcoded as 8192 in several queries: change it if different.
- Do not move undo segments (`TYPE2 UNDO`).
- Review every spooled script before running it.

---

# Part 2: Worked case, IIB_ARCH_TBS_NEW1 (11 Nov 2026)

Oracle 19c Enterprise Edition, RU 19.32, on Exadata (HCC in use). Session run in PDB `ARCHSI`. All queries are in `reclaim_asm_space.sql` (sections 6 to 11); raw output is in `datafile_size_reclaim.txt`.

## 7. What we found

### 7.1 Starting point

| Item | Value |
|---|---|
| Tablespace | `IIB_ARCH_TBS_NEW1` |
| Size / used / free | 22,941 GB / 10,378 GB / 12,563 GB (45% used) |
| Datafiles | 740 smallfiles, block size 8 KB |
| Problem | 12.5 TB is free *inside* the files but the files cannot shrink |

### 7.2 Why the files cannot shrink

The per-file highest-used-block query (section 6B in the SQL file; the labels 6B/6C in the output file are swapped against the SQL file) showed that nearly every file ends at block **4,063,231**, about **31 GB**, which is almost the 32 GB smallfile maximum (4,194,303 blocks).

- 371 of 740 files end at exactly 4,063,231; most others are only slightly lower.
- So the last extent of almost every file is still in use, and `RESIZE` fails with **ORA-03297**.
- The free 12.5 TB is scattered in gaps from dropped or truncated partitions, behind these last extents.

### 7.3 Which segments sit at the end of the files

The per-segment query (6C in the SQL file) showed that a few segments block most files:

| Segment | Type | Files blocked |
|---|---|---|
| `SYS_LOB0001029983C00004$$` | LOB partition | 124 |
| `BACKEND_PROCESSING_LOG_2022C` | table partition | 101 |
| `API_PROCESS_CLOBDET_2022_1` | table | 79 |
| `ORCH_API_DETAILS_2023_2C` | table partition | 44 |
| `SYS_LOB0001030079C00006$$` | LOB partition | 42 |
| `API_DETAILS_23C`, `API_LOG_2023_2C` | table partition | 41 each |
| others | | 1 to 40 each |

Roughly the top 11 segments account for about 560 of the 740 files.

### 7.4 How much data has to move (section 7A)

About **4.2 TB** in total. The largest items:

| Table | Blocking data | Detail |
|---|---|---|
| `BACKEND_DETAILS_CLOB_23_2C` | about 860 GB | `JUN_23` table partition only 4 GB; the `OUTPUT_DATA` LOB partition is 857 GB |
| `ORCH_API_DETAILS_2023_2C` | about 1.2 TB | `JUL_23` table 582 GB; LOBs 612 GB (`OUTPUT_DATA`), 14 GB, 1 GB |
| `API_DETAILS_23_2C` | about 800 GB | `JUL_23` table 394 GB; LOBs about 390 GB (`OUTPUT_DATA`) and 20 GB |
| `API_DETAILS_23C` | 438 GB | `JAN_23` 217 GB, `FEB_23` 221 GB |
| `API_DETAILS_CLOB_2023C` | about 300 GB | table partition 2 GB; the rest is LOB partitions (173, 73, 25, 24 GB) |
| `API_PROCESS_CLOBDET_2022_1` | 159 GB | non-partitioned table |
| `API_LOG_2023_2C` | 151 GB | `JUN_23` |
| `BACKEND_PROCESSING_LOG_2022C` / `_2023_2C` | 137 GB / 40 GB | `AUG_22`, `SEP_22`, `OCT_22` / `JUN_23` |

The LOB mapping (7B) confirmed, for example, that `SYS_LOB0001029983C00004$$` is `BACKEND_DETAILS_CLOB_23_2C.OUTPUT_DATA`. About 3.3 TB of the 4.2 TB is LOB data.

### 7.5 Destination tablespace

`IIB_ARCH_TBS` (about 10.1 TB free, 60% used) and `IIB_ARCH_TBS_NEW` (about 10.1 TB free, 68% used) are almost identical. We chose **`IIB_ARCH_TBS`**: more free space, lower used percentage, and 4.2 TB (less after compression) leaves about 6 TB free. Both are ASSM (needed for SecureFile LOBs).

### 7.6 What else is in NEW1

- **Recycle bin objects.** About 40 partitions named `BIN$...` (dropped 2020 tables, `JUN_2020` to `JAN_2021`, each with 7-8 LOB partitions x 3 LOB columns) are still in the tablespace. Do not move them: check their size (section 10A) and purge if they are not needed (`PURGE TABLESPACE IIB_ARCH_TBS_NEW1;`, irreversible).
- **More blockers later.** After the first round the next segments become the end-of-file blockers (e.g. `API_LOG_2022C`, `API_PROCESS_DET_2022C`, `API_PROCESS_DET_2024_1C`, `ORCH_API_DETAILS_2024_1C`, `ORCH_API_LOG_24_1C`). Section 8B shows what remains. Expect two or three rounds.
- **Expected result.** The tablespace holds 10.4 TB of data, 4.2 TB of it in the first batch. A realistic outcome is shrinking NEW1 from about 22.9 TB to somewhere between 7 and 10 TB (13 to 16 TB returned to ASM) over several rounds. This is an estimate, not a measurement.

## 8. Compression explained

Compression helps twice here: the moved data lands smaller in the destination, and the destination needs less free space.

### 8.1 The types at a glance

| Type | Syntax (19c) | Applies to | Compresses on | Licence |
|---|---|---|---|---|
| Basic table compression | `ROW STORE COMPRESS BASIC` (or `COMPRESS`) | table data | direct-path operations only (`MOVE`, `INSERT /*+APPEND*/`, CTAS) | included in Enterprise Edition |
| Advanced Row Compression (formerly OLTP) | `ROW STORE COMPRESS ADVANCED` (old: `COMPRESS FOR OLTP`) | table data | direct-path and normal inserts/updates | Advanced Compression Option (ACO) |
| Hybrid Columnar Compression (HCC) | `COMPRESS FOR QUERY LOW/HIGH`, `ARCHIVE LOW/HIGH` | table data | direct-path operations only | Exadata (or other supported Oracle storage), not ACO |
| SecureFile LOB compression ("Advanced LOB compression") | `LOB (c) STORE AS SECUREFILE (COMPRESS LOW/MEDIUM/HIGH)` | out-of-line LOB data | any write to the LOB | ACO |
| SecureFile deduplication | `STORE AS SECUREFILE (DEDUPLICATE)` | LOB data | any write | ACO |
| Advanced Index Compression | `CREATE INDEX ... COMPRESS ADVANCED LOW/HIGH` | indexes | index build and DML | ACO |

Compression ratios depend entirely on the data. Always measure (section 8.7) before estimating savings.

### 8.2 Basic compression

- Block-level: repeated values in a block are stored once in a symbol table at the start of the block.
- Only data loaded by a direct-path operation is compressed. Later row inserts and updates are stored uncompressed, so it suits data that no longer changes. A `MOVE` is a direct-path operation, so it compresses existing rows.
- Included in Enterprise Edition; no extra licence.

### 8.3 Advanced Row Compression (OLTP compression)

- Same block-level idea as Basic, but it also compresses data from ordinary DML: a block is compressed when it fills up to a threshold, so heavily updated tables stay compressed.
- Typical savings are smaller than HCC (commonly 2x to 4x, data dependent).
- Requires the Advanced Compression Option. In `dba_feature_usage_statistics` it appears as `HeapCompression`.

### 8.4 Hybrid Columnar Compression (HCC)

- Stores rows in **compression units (CUs)**, several blocks long, and inside a CU the data is organised by **column**. Similar values sit together, so the ratio is much higher than block-level compression.
- Levels: `QUERY LOW` and `QUERY HIGH` favour scan speed; `ARCHIVE LOW` and `ARCHIVE HIGH` give the best ratio and are the slowest. Commonly cited ratios are several-fold for QUERY and more for ARCHIVE, but this is data dependent.
- Needs Exadata (or other Oracle-supported storage). Compression happens only on direct-path loads.
- Normal inserts into an HCC table are stored in a lower-level format (the usage view shows this as `Hybrid Columnar Compression Conventional Load`). Updating an HCC row moves the row out of its CU and can lock the whole CU, so HCC is for read-mostly or archive data.
- **HCC does not compress LOB segments.** It applies to the table's own blocks: the non-LOB columns and the LOB locators. That is why the table partitions are small but their LOB partitions are huge. (Behaviour for small in-row LOB values was not verified: measure it, section 8.7.)
- HCC is not part of ACO; it is a feature of the Exadata storage.

### 8.5 SecureFile LOB compression (Advanced LOB compression) and deduplication

- Only **SecureFile** LOBs can be compressed. BasicFile LOBs cannot; moving them with `STORE AS SECUREFILE` converts them. Needs an ASSM tablespace.
- Levels: `LOW` (least CPU, smaller saving), `MEDIUM` (the default for plain `COMPRESS`), `HIGH` (best ratio, most CPU). For archive text such as JSON or XML, `HIGH` is reasonable; it is also what the existing compressed LOBs here use.
- Compression is transparent. Reads decompress on the fly.
- `DEDUPLICATE` stores identical LOB values once. It is a separate feature with uncertain benefit for our data, so it is **not** used in these moves.
- Licensed under ACO. In `dba_feature_usage_statistics` it shows as `SecureFile Compression (user)`.
- **Extended data type columns** (`VARCHAR2(32767)` when `MAX_STRING_SIZE=EXTENDED`) are stored in hidden SecureFile LOBs but `STORE AS` is not allowed for them (ORA-14692), so their compression cannot be set this way (see section 9).

### 8.6 What our data uses today (section 9 output)

| Object | Current state |
|---|---|
| Most table partitions in NEW1 | HCC `QUERY HIGH` |
| `API_DETAILS_CLOB_2023C`, `BACKEND_DETAILS_CLOB_23_2C`, `ORCH_API_DETAILS_CLOB_24_1C` partitions | `ADVANCED` |
| `API_PROCESS_CLOBDET_2022_1` (159 GB) | no table compression |
| Almost all LOBs | SecureFile, **not compressed** (`COMPRESSION = NO`, no dedup) |
| Some LOBs of `API_DETAILS_CLOB_2023C`, `ORCH_API_DETAILS_CLOB_24_1C` | SecureFile `HIGH` |
| Destination tablespaces | ASSM, 8 KB |

So table compression is already done and is **kept** by the move. The saving opportunity is the uncompressed LOBs: the 857 GB, 612 GB and 390 GB LOB partitions among them.

### 8.7 Measuring the benefit

Use `DBMS_COMPRESSION.GET_COMPRESSION_RATIO` on one mid-size partition (section 9D in the SQL file; it needs a scratch tablespace). Do this before promising a number. It has not been run yet for this tablespace.

### 8.8 Licensing

- `dba_feature_usage_statistics` shows what the database has used, not what you are entitled to. In this database `SecureFile Compression (user)`, `SecureFile Deduplication (user)`, `HeapCompression` and `Hybrid Columnar Compression` all show as currently used (last use 08-Nov-2026), so they were already in use.
- Confirm entitlement for Advanced Compression with whoever manages the Oracle licences. If it is not covered, drop `COMPRESS HIGH` from the LOB clauses and keep plain `SECUREFILE (TABLESPACE ...)`.

## 9. Problems met and corrections

| Issue | Cause | Fix |
|---|---|---|
| `ONLINE UPDATE INDEXES` order | In 19c `ONLINE` goes last for partition moves | Use `UPDATE INDEXES PARALLEL 4 ONLINE` |
| HCC and `ONLINE` | Not assumed to work together | Section 10 statements omit `ONLINE`; each partition is locked against DML while it moves (archive data is idle) |
| Generator also produced `BIN$` objects | LOB-only generator had no filter | Recycle bin objects skipped; purge them instead |
| **ORA-14692: STORE AS clause is not allowed for extended character type column** | `EXCEPTION_DESC` and `DB_APPLICATION_NAME` are `VARCHAR2(32767)`, stored as hidden LOBs; the generator took them from `dba_lob_partitions` | Generators now skip `VARCHAR2/NVARCHAR2/RAW` columns longer than 4000 bytes (section 11) |
| Section labels | 6B/6C are swapped between the SQL file and the output file | Use the query text, not the label |
| 9D not yet run | Needs a scratch tablespace | Run on one partition to confirm LOB ratio |

**Open question:** the hidden LOB segments of extended columns cannot be moved or compressed with `STORE AS`. They are expected to follow the table partition to the new tablespace, but this has not been confirmed. After the test move, run the check at the end of section 11 of the SQL file. If any still show `IIB_ARCH_TBS_NEW1`, they will keep blocking the files.

## 10. The move procedure

Prerequisites: backup, a quiet window, enough archive-log/FRA space (a 4 TB move generates a lot of redo), and the destination checked for free space.

1. **Purge the recycle bin objects** if confirmed unwanted (section 10A of the SQL file).
2. **Generate statements** from the repo (do not edit old output):
   - Section 10B: partition moves, keeping each table partition's compression and compressing LOBs with `SECUREFILE ... COMPRESS HIGH`
   - Section 10C: LOB-only partitions whose table partition is already elsewhere
   - Section 10D: the non-partitioned `API_PROCESS_CLOBDET_2022_1` (check its LOB column types first)
3. **Test on one small partition** and check: it completes, indexes are usable, size after the move, and the section 11 check for the hidden LOB segments. Example (as corrected after ORA-14692):

```sql
ALTER TABLE IIBARCH.API_DETAILS_CLOB_2023C MOVE PARTITION JAN_23
  TABLESPACE IIB_ARCH_TBS ROW STORE COMPRESS ADVANCED
  LOB (INPUT_DATA)  STORE AS SECUREFILE (TABLESPACE IIB_ARCH_TBS COMPRESS HIGH)
  LOB (OUTPUT_DATA) STORE AS SECUREFILE (TABLESPACE IIB_ARCH_TBS COMPRESS HIGH)
  UPDATE INDEXES PARALLEL 4;
```

4. **Move in this order,** one table or partition at a time, and rerun the blocker query (6C) between batches:
   1. `BACKEND_DETAILS_CLOB_23_2C` `JUN_23`
   2. `ORCH_API_DETAILS_2023_2C` `JUL_23`, then `API_DETAILS_23_2C` `JUL_23`
   3. `API_DETAILS_23C` `JAN_23`, `FEB_23`; `API_LOG_2023_2C`; `API_PROCESS_CLOBDET_2022_1`
   4. `BACKEND_PROCESSING_LOG_2022C`, `BACKEND_PROCESSING_LOG_2023_2C`, then the small remaining partitions and LOB-only partitions
5. **Check indexes** after each batch: `dba_ind_partitions` / `dba_indexes WHERE status = 'UNUSABLE'`; rebuild with `ALTER INDEX ... REBUILD [PARTITION ...] TABLESPACE ... ONLINE`. Section 8C lists index segments of the moved tables still in NEW1.
6. **Reclaim:** rerun the resize generator (section 7E), run the `RESIZE` statements, drop any files left with no extents, then check `v$asm_diskgroup`.
7. **Repeat** until the remaining blockers are acceptable.

## 11. Status (11 Nov 2026) and next steps

- Done: analysis of blockers, destination choice, compression review, generators for table, LOB and non-partitioned moves, fix for extended columns.
- In progress: the first test move (`API_DETAILS_CLOB_2023C` `JAN_23`) has been started; its result is not recorded here yet.
- Next: check the test partition (completion, indexes, hidden LOB segment location, new size); run 10A (recycle bin size) and 9D (LOB compression ratio); then work through the order in section 10; repeat the HWM check and resize after each batch.
