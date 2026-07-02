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
      │  times the run, then calls the embedded-Python analyzer
      ▼
   src/gaia/analyze.py  (embedded Python)
      │  • stream each .gz with gzip + csv, skipping the ECSV '#' header lines
      │  • locate source_id / bp_flux / rp_flux columns by NAME
      │  • parse the quoted flux arrays, keep finite & >0 values
      │  • per-band min/max/%, take the max, keep if > 100
      ▼
   data/out/results.csv
```

The files are **ECSV** (≈365 leading `#` comment lines, then a CSV header, then data), and
`bp_flux`/`rp_flux` are **quoted arrays** like `"[NaN,50.0,…,157841.99]"` — the commas live
inside the quotes. Python's `csv` module parses the quoting for free, and `gzip` streams the
files a row at a time, so memory stays flat and no separate extraction step is needed.

## Run it

Prerequisites: [git](https://git-scm.com) and [Docker Desktop](https://www.docker.com/products/docker-desktop).

```bash
docker-compose up --build -d
docker-compose exec iris iris session iris
USER>do ^RunScript
```

`RunScript` is pre-compiled into the USER namespace at image build time (see `iris.script`),
so it is ready to run immediately. It prints the number of sources scored, the number over
100%, and the elapsed time, and writes `data/out/results.csv`.

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
| `src/gaia/analyze.py` | embedded-Python analyzer (parse → per-band min/max/% → filter → CSV) |
| `tests/test_analyze.py` | host unit tests for the parsing and math |
| `iris.script` | build-time setup; pre-compiles `src/*.mac` into USER |
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
- Getting the routine auto-loaded so `do ^RunScript` "just works" needed
  `$System.OBJ.ImportDir(dir,"*.mac","ck",,1)` in `iris.script` — `LoadDir` without the
  wildcard silently loaded nothing.
- Columns are located by name, never by index, so a future column-order change can't
  silently corrupt the result.
