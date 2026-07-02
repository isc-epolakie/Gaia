# Gaia DR3 Epoch-Photometry Variability Detector

InterSystems Employee Programming Challenge #1. Given the Gaia DR3 epoch-photometry
archive, this finds astronomical objects whose **BP or RP flux changed by more than
100%** across the observation period and writes the result to a CSV.

Built on the official `intersystems-challenge1-docker-template`: IRIS Community Edition
in Docker, driven by `do ^RunScript`. The analysis runs in **embedded Python** inside IRIS.

## What it computes

For each `source_id` in the 20 benchmark files
(`EpochPhotometry_000000-003111.*` … `EpochPhotometry_020985-021233.*`):

1. Read the per-transit `bp_flux` and `rp_flux` arrays.
2. Keep only **valid** flux values (see below).
3. For each band, `min_flux = min`, `max_flux = max`, and
   `percentage_change = ((max_flux − min_flux) / min_flux) × 100`.
4. The source's `percentage_change` is the **larger** of the BP and RP values.
5. Emit the source only if `percentage_change > 100`.

### What counts as a valid flux value

The task says to ignore "missing, null, NaN, or otherwise invalid flux values." We treat a
value as valid only if it parses as a **finite number and is strictly positive (> 0)**.
Negative and zero fluxes are unphysical — Gaia itself flags negative flux as rejected
(`variability_flag_*_reject`) — and dividing by a zero or negative `min_flux` would make the
percentage meaningless. Everything else (NaN, empty, `null`, non-numeric, ≤ 0) is dropped.

With this rule roughly **75%** of sources exceed 100% change — epoch photometry captures
real transits with large flux swings, so big percentages (including very large ones from
near-zero minima) are expected and kept as-is, per the literal formula.

### Output

`data/out/results.csv`, with a header row and one qualifying source per line:

```
source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change
```

A band with no valid flux leaves its two columns blank. Rows are sorted by
`percentage_change` descending. (~57,000 rows for the 20-file benchmark.)

## How it works

```
data/in/EpochPhotometry_*.csv.gz   (20 gzipped ECSV files, shipped with the template)
      │
   src/RunScript.mac   ← graders run  do ^RunScript
      │  times the run, then calls the parallel coordinator
      ▼
   Gaia.Analyze.Run (ObjectScript)
      │  fans the 20 files across %SYSTEM.WorkMgr worker jobs — each a separate
      │  process with its own embedded Python, so parsing scales across CPU cores
      │  with no GIL contention
      ├───► Gaia.Work.ProcessFile → gaia.analyze.write_part   (one worker per file)
      │        • gunzip + skip the ECSV '#' header lines
      │        • extract source_id / bp_flux / rp_flux (fast positional parse)
      │        • keep finite & >0 flux, per-band min/max/%, take the max, keep >100
      │        • write qualifying rows to a per-file .part
      ▼
   gaia.analyze.merge_parts  →  data/out/results.csv   (header + all parts)
```

The files are **ECSV** (≈365 leading `#` comment lines, then a CSV header, then data), and
`bp_flux`/`rp_flux` are **quoted arrays** like `"[NaN,50.0,…,157841.99]"` — the commas live
inside the quotes. `gzip` streams each file a row at a time (flat memory, no extraction step).

**Performance.** Profiling drove the 20-file run from ~16.5 s to **~2 s** (≈8×). In order
of impact:
1. *Parallelism (`%SYSTEM.WorkMgr`).* The 20 files are independent, so they are processed
   concurrently across worker jobs — the idiomatic IRIS way to scale, and each worker has
   its own Python interpreter so there is no GIL bottleneck.
2. *Faster decompression (`isal`).* Decompression is ~⅔ of the work; `isal.igzip`
   decompresses gzip ~2× faster than the stdlib. The analyzer falls back to stdlib `gzip`
   if `isal` is absent, so it still runs anywhere.
3. *Fast parse.* A row is 48 columns of mostly huge quoted arrays; `csv.reader` alone cost
   ~6.8 s parsing all of it. We instead pull only the three fields we need — `source_id`
   and the `bp_flux`/`rp_flux` array groups — walking the arrays with a regex and stopping
   once both are found (the ~31 trailing array columns are never scanned). Columns are
   still resolved from the header, so a layout change is detected, not mis-parsed. The
   readable `csv`-based `analyze_file` is kept as a reference and a test asserts the fast
   path matches it exactly.
4. *Longest-processing-time-first scheduling.* Files vary 11–28 MB; queueing the biggest
   first keeps a large file from becoming an end-of-run straggler (~2.1 s → ~1.5 s of
   compute). Beyond this the work is memory-bandwidth-bound and plateaus at ~4–5× scaling.

## Run it

Prerequisites: [git](https://git-scm.com) and [Docker Desktop](https://www.docker.com/products/docker-desktop).

```bash
docker-compose up --build -d
docker-compose exec iris iris session iris
USER>do ^RunScript
```

`RunScript` and the `Gaia.*` classes are pre-compiled into the USER namespace at image
build time (see `iris.script`), so `do ^RunScript` is ready to run immediately. It prints
the number of sources over 100%, the output path, and the elapsed time, and writes
`data/out/results.csv`.

## Tests

The analyzer is plain Python (no IRIS dependency), so its parsing and math are unit-tested on
the host:

```bash
PYTHONPATH=src python -m pytest tests/ -v
```

## Project layout

| Path | What |
|---|---|
| `src/RunScript.mac` | ObjectScript entrypoint the graders run (`do ^RunScript`) |
| `src/Gaia/Analyze.cls` | parallel coordinator: fan the files across WorkMgr, merge results |
| `src/Gaia/Work.cls` | one WorkMgr unit: analyze a single file via embedded Python |
| `src/gaia/analyze.py` | embedded-Python analyzer (parse → per-band min/max/% → filter → CSV) |
| `tests/test_analyze.py` | host unit tests: parsing, math, and fast/reference parity |
| `iris.script` | build-time setup; pre-compiles `src/*.cls` + `src/*.mac` into USER |
| `data/in/` | the 20 benchmark `.csv.gz` files (from the template) |
| `data/out/results.csv` | generated output (gitignored) |
| `docs/` | design spec |

## Notes / feedback (as the contest requests)

- **Embedded Python was a great fit.** The hardest part of the data is the quoted flux
  arrays; Python's `csv` + `float()` handle the quoting and NaN with almost no code, and
  `gzip` streams the ECSV files directly — no LOAD DATA gymnastics (which wouldn't fit
  array-valued text anyway).
- Calling Python from `RunScript.mac` via `##class(%SYS.Python).Import(...)` is clean; the
  one quirk was reading a returned Python tuple from ObjectScript, done with
  `result."__getitem__"(0)`.
- Getting the classes + routine auto-loaded so `do ^RunScript` "just works" needed
  `$System.OBJ.ImportDir(dir,"*.cls","ck",,1)` then `...,"*.mac",...` in `iris.script` —
  a single `ImportDir` wildcard only handles one file type, and `LoadDir` without the
  wildcard silently loaded nothing.
- **`%SYSTEM.WorkMgr` was the right tool for the speedup.** The 20 files are independent,
  so fanning them across worker jobs (separate processes, each with its own embedded
  Python) sidesteps the GIL and scales across cores. Worth knowing: WorkMgr suppresses
  `Write` output from inside the coordination, and the win only appears once the classes
  are actually recompiled into the image (a stale compiled `^RunScript` will keep running
  the old code — rebuild after changes).
- Columns are located by name, never by index, so a future column-order change can't
  silently corrupt the result.
