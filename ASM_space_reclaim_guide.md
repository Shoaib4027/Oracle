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
| Compress | `ALTER TABLE t MOVE COMPRESS` | None (online) |
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
