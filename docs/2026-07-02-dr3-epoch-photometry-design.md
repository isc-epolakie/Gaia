# Gaia DR3 Epoch Photometry Variability — Design

**Date:** 2026-07-02
**Contest:** InterSystems Employee Programming Challenge #1 (revised task, DR3 epoch photometry).
**Template:** built on `intersystems-challenge1-docker-template` (required).

## 1. Task (restated)

For each `source_id` in the first 20 DR3 epoch-photometry files, process the `bp_flux`
and `rp_flux` arrays, ignore invalid flux values, compute per-band min/max valid flux,
compute `percentage_change = ((max - min) / min) * 100` for each band, take the larger of
the BP and RP values as the source's `percentage_change`, and emit the source **only if
that value > 100**.

Output CSV columns (exact order):
`source_id, bp_min_flux, bp_max_flux, rp_min_flux, rp_max_flux, percentage_change`

## 2. Data reality (verified against the files)

- Files are **ECSV** (Enhanced CSV): ~365 leading comment lines starting with `#`, then a
  standard CSV header row, then data rows. Data starts at the first non-`#` line.
- Header has 48 columns; the ones we need: `source_id` (col 2), `bp_flux` (col 12),
  `rp_flux` (col 17).
- `bp_flux` / `rp_flux` are **quoted arrays**: a CSV field of the form
  `"[NaN,50.02,60.92,...,157841.99,...]"` — commas live *inside* the quotes, so a naive
  comma split breaks. A proper CSV parser (Python `csv`) handles the quoting.
- Invalid values appear as `NaN` (and possibly empty/`null`). Verified `NaN` present.
- Scale: ~5,346 rows/file × 20 ≈ **107k sources**. Small — correctness over raw speed.
- Empirically, with the valid-flux rule below, **~79% of sources exceed 100%** in file 0
  (values from ~100% to >600,000%), so the criterion yields a large, real result set.

## 3. Definitions (locked)

- **Valid flux** = a value that parses as a finite number AND is `> 0`. This excludes
  `NaN`, null/empty, non-numeric, and non-positive values. Rationale: the task says ignore
  "missing, null, NaN, or otherwise invalid" — negative/zero flux is unphysical (matches
  Gaia's `variability_flag_*_reject` = "negative (unphysical) flux") and dividing by a
  zero/negative `min_flux` is nonsensical. This is also what makes the `%` well-defined.
- **Per band** (BP, RP): from the valid values, `min_flux = min`, `max_flux = max`,
  `pct = ((max - min) / min) * 100`. A band needs ≥1 valid point to have min/max; with a
  single valid point min==max so pct=0 (harmless). A band with **0 valid points** is
  omitted (its min/max are empty in the output and it contributes no pct).
- **Source percentage_change** = the larger of the computable BP and RP pct values.
- **Qualify** if `percentage_change > 100`.
- **Output fields for a qualifying source**: `bp_min_flux, bp_max_flux` from BP (empty if
  BP had no valid points), `rp_min_flux, rp_max_flux` from RP (empty if none),
  `percentage_change`.

## 4. Architecture

Everything runs inside the template's IRIS Community container, driven by `do ^RunScript`.

```
data/in/EpochPhotometry_*.csv.gz   (20 files, committed in the template)
      | RunScript.mac (ObjectScript entrypoint the graders run)
      |   - records start time
      |   - calls the embedded-Python analyzer
      v
src/gaia/analyze.py  (embedded Python, +3 Experts bonus)
      |   - for each of the 20 .gz files: stream rows with gzip + csv
      |   - skip the ECSV '#' comment lines, read the header, locate columns by name
      |   - parse bp_flux/rp_flux arrays, filter to valid (finite & >0)
      |   - compute per-band min/max/pct, take max, keep if > 100
      |   - write data/out/results.csv with the required header + rows
      v
data/out/results.csv   (the deliverable)
      | (optional, later) web UI reads a JSON view of this for the galaxy visualization
```

**Why embedded Python (not host DB-API):** the graders run `do ^RunScript` *inside* the
container, so the solution must run there. Embedded Python via `%SYS.Python` is confirmed
working in this image (3.12.3) and earns the +3 Python bonus. Python's `csv` + `float()`
parse the quoted flux arrays and NaN cleanly with very little code.

**Why streaming, not LOAD DATA:** the flux data is array-valued text, not a flat numeric
table — SQL `LOAD DATA` doesn't fit. Streaming each file row-by-row in Python keeps memory
flat (one row at a time) and is plenty fast at this scale.

## 5. Components

| File | Responsibility |
|---|---|
| `src/RunScript.mac` | ObjectScript entrypoint (graders run `do ^RunScript`). Times the run, calls the Python analyzer, prints elapsed + row count. |
| `src/gaia/__init__.py` | marks the package |
| `src/gaia/analyze.py` | the analyzer: `run(in_dir, out_path) -> (n_sources, n_qualified)`; pure-Python, testable on the host too |
| `data/out/results.csv` | output (gitignored; regenerated) |
| `tests/test_analyze.py` | host unit tests for the parsing + math on tiny synthetic ECSV fixtures |
| `README.md` | rewritten: task, how it works, install/run, the valid-flux rationale, feedback comments |

### `analyze.py` interface

```python
def parse_flux_array(cell: str) -> list[float]:
    """'[NaN,50.0,...]' or '' -> list of valid (finite, >0) floats."""

def band_stats(values: list[float]) -> tuple[float|None, float|None, float|None]:
    """-> (min, max, pct) or (None,None,None) if no valid values.
       pct = ((max-min)/min)*100."""

def run(in_dir: str, out_path: str) -> tuple[int,int]:
    """Process every EpochPhotometry_*.csv.gz in in_dir, write results.csv,
       return (sources_seen, sources_qualified)."""
```

### CSV output format

- Header line: `source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change`
  (the task lists these columns; a header aids the required "produce a csv file with
  columns …". If graders want headerless, it's a one-line toggle — noted in README.)
- One qualifying source per line. Empty field for a band with no valid flux.
- `percentage_change` printed with full float precision; min/max fluxes as parsed floats.
- Sorted by `percentage_change` descending (stable, useful; not required but harmless).

## 6. RunScript contract

`do ^RunScript` must run with no arguments and produce `data/out/results.csv`. It:
1. ensures `data/out` exists,
2. calls `##class(%SYS.Python).Import("gaia.analyze").run("/home/irisowner/dev/data/in", "/home/irisowner/dev/data/out/results.csv")` (with `/home/irisowner/dev/src` on `sys.path`),
3. prints elapsed seconds (already scaffolded) and the qualifying-row count.

Reads directly from the committed `.gz` files (Python `gzip`), so no separate extraction
step is required — simpler and avoids the `data/temp` dance (the template's extraction step
is optional; we note this).

## 7. Web UI (phase 2, after the CSV core works)

Adapt the existing three.js galaxy from the prior project to visualize DR3 results:
each qualifying source is a star, colored/sized by `percentage_change` (log-scaled, since
values span many orders of magnitude). Served from the IRIS Community built-in web server
as before. This is a separate phase; the CSV RunScript is the graded core and comes first.

## 8. Out of scope (YAGNI)

- No LOAD DATA / SQL table (data is array-valued text).
- No G-band processing (task only asks BP/RP).
- No handling of Gaia releases other than the provided DR3 files.
- The prior project's flux-scatter proxy is gone — DR3 gives real per-epoch arrays, so we
  compute true min/max.

## 9. Success criteria

1. `do ^RunScript` in the template container produces `data/out/results.csv` with the exact
   required columns, one qualifying source per line.
2. Parsing correctly ignores NaN/null/empty/non-positive flux and handles the quoted arrays.
3. Per-band min/max and the max-of-two `percentage_change` match a hand-computed reference
   (unit tests).
4. README documents install, run, how it works, and the valid-flux rationale, with in-code
   feedback comments (contest asks for these).
5. Uses IRIS embedded Python as the compute language (+3 bonus).
