# Gaia DR3 Epoch-Photometry Variability Detector

**InterSystems Employee Programming Challenge #1.** Given the Gaia DR3 epoch-photometry
archive, this finds astronomical objects whose **BP or RP flux changed by more than 100%**
across the observation period, writes the result to a CSV, and — as a bonus — renders the
result set as an interactive **3D galaxy** you can fly through.

Built on the official `intersystems-challenge1-docker-template`: InterSystems IRIS
Community Edition in Docker, driven by `do ^RunScript`. It is **IRIS-native by design**
(see below), and processes the full 20-file benchmark in **~1.5 seconds**.

---

## Quick start

Prerequisites: [git](https://git-scm.com) and [Docker Desktop](https://www.docker.com/products/docker-desktop).

```bash
git clone https://github.com/isc-epolakie/Gaia.git
cd Gaia
docker compose up --build -d
```

Produce the result CSV (this is what the challenge grades):

```bash
docker compose exec iris iris session iris
USER> do ^RunScript
```

That writes `data/out/results.csv` and prints the qualifying-source count and the elapsed
time. Everything needed (the analyzer classes, the C extensions, the routine) is compiled
into the image at build time, so `do ^RunScript` works immediately with no further setup.

**See the galaxy (optional, recommended):**

```bash
docker compose exec iris bash scripts/setup_web.sh    # one-time web provisioning
```

then open **http://localhost:52773/csp/gaia/ui/index.html**.

---

## The interactive 3D galaxy

<!-- Crisp MP4 renders inline on GitHub; the GIF is a fallback for other viewers / offline clones. -->
https://github.com/isc-epolakie/Gaia/raw/master/docs/demo.mp4

![Gaia Atlas — interactive 3D galaxy of DR3 variable sources](docs/demo.gif)

The web UI turns the results CSV into a living star map (Three.js + WebGL, served straight
from the IRIS Community built-in web server — no extra infrastructure):

- **Every point is a real qualifying Gaia source.** Sources are grouped into clusters by a
  projection of their full flux signature, so similar objects sit together.
- **Colour encodes variability** — cool blue for the more modest changes through to hot red
  for the extreme ones (log-scaled, because the values span many orders of magnitude).
- **Fly through it.** Drag to orbit, scroll to zoom, hover any star for its source ID and
  flux range. A **threshold slider** re-queries the sky live; a twinkling starfield,
  drifting nebulae and the occasional comet keep it alive.
- **Scroll down** for a sortable, paginated table of the same results.

The render loop pauses when the galaxy is off-screen, so it stays light.

---

## What it computes

For each `source_id` in the 20 benchmark files
(`EpochPhotometry_000000-003111.*` … `EpochPhotometry_020985-021233.*`):

1. Read the per-transit `bp_flux` and `rp_flux` arrays.
2. Keep only **valid** flux values (see below).
3. Per band: `min_flux = min`, `max_flux = max`,
   `percentage_change = ((max_flux − min_flux) / min_flux) × 100`.
4. The source's `percentage_change` is the **larger** of the BP and RP values.
5. Emit the source only if `percentage_change > 100`.

**Output** — `data/out/results.csv`, header + one qualifying source per line
(~57,000 rows), sorted by `percentage_change` descending:

```
source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change
```

A band with no valid flux leaves its two columns blank.

### What counts as a valid flux value

The task says to ignore "missing, null, NaN, or otherwise invalid flux values." We treat a
value as valid only if it parses as a **finite number and is strictly positive (> 0)**.
Negative and zero fluxes are unphysical — Gaia itself flags negative flux as rejected
(`variability_flag_*_reject`) — and dividing by a zero/negative `min_flux` would make the
percentage meaningless. Everything else (NaN, empty, `null`, non-numeric, ≤ 0) is dropped.
Under this rule roughly **75%** of sources exceed 100% (epoch photometry captures real
transits with large swings), so big percentages are expected and kept as-is.

---

## IRIS-native by design

This is a deliberate choice, not just a template requirement: the solution leans on
InterSystems IRIS as the platform rather than treating it as a shell around an external
data tool.

- **Parallelism is `%SYSTEM.WorkMgr`** — IRIS's own work-distribution framework fans the 20
  files across worker *jobs* (separate processes), the idiomatic IRIS way to use every core.
- **The engine is embedded Python** (`%SYS.Python`), called from an ObjectScript routine
  (`^RunScript`) — earning the Python bonus while keeping the whole thing inside IRIS.
- **Serving the UI is IRIS too** — the built-in web server hosts both the REST-free static
  page and the results file; there is no separate web stack to stand up.

---

## How it works

```
data/in/EpochPhotometry_*.csv.gz   (20 gzipped ECSV files, shipped with the repo)
      │
   src/RunScript.mac   ← graders run:  do ^RunScript
      │  times the run, then calls the parallel coordinator
      ▼
   Gaia.Analyze.Run  (ObjectScript)
      │  queues the 20 files (biggest first) across %SYSTEM.WorkMgr worker jobs —
      │  each a separate process with its own embedded Python, so work scales
      │  across CPU cores with no GIL contention
      ├──► Gaia.Work.ProcessFile → ckernel.analyze_to_file   (one worker per file)
      │        C kernel: libdeflate-decompress the gzip, scan the buffer for the
      │        bp/rp flux cells, compute per-band min/max, write qualifying rows —
      │        all in C; the 1.5 GB of decompressed text never enters Python
      ▼
   gaia.gmerge.merge_parts  →  data/out/results.csv   (header + concatenated parts)
```

The files are **ECSV** (≈365 leading `#` comment lines, then a CSV header, then data), and
`bp_flux`/`rp_flux` are **quoted arrays** like `"[NaN,50.0,…,157841.99]"` — commas live
inside the quotes, so the row can't be split naively. The layout is fixed, so the kernel
locates the bp/rp arrays by position (still cross-checked against the header names).

### Performance

Every optimisation was verified to be both faster **and** byte-for-byte identical to the
previous answer against a fixed reference. The 20-file run went from **~16.5 s to ~1.5 s**
(≈10×):

1. **Parallelism (`%SYSTEM.WorkMgr`).** The 20 files are independent → processed
   concurrently across worker jobs, each with its own Python interpreter (no GIL).
2. **Fewer, cheaper worker imports.** Each worker imports only the tiny `ckernel`
   extension (not the full analyzer), and the coordinator merges via a dependency-free
   helper — importing the heavy module per worker cost ~0.9 s.
3. **A C kernel (Cython + libdeflate).** Decompression is ~⅔ of the work. `src/gaia/ckernel.pyx`
   decompresses each file with **libdeflate** and scans the raw bytes with `strtod`,
   computing min/max and writing the CSV rows entirely in C — nothing but the final rows
   crosses into Python. (We measured `isal` and pure-Python paths too; they're kept as
   automatic fallbacks so the app still runs if the C kernel isn't built.)
4. **Longest-processing-time-first scheduling.** Files vary 11–28 MB; queueing the biggest
   first stops a large file from becoming an end-of-run straggler.

### Robustness

The worker and analyzer degrade gracefully through three tiers, so the app always produces
correct output even where the C toolchain isn't available:
**C kernel (`ckernel`) → Cython min/max (`fastmm`) + `isal` → pure-Python + stdlib `gzip`.**
Host unit tests run the pure-Python path; an in-container test asserts the C kernel matches
the reference on every row.

---

## Tests

The analyzer core is plain Python (no IRIS dependency), so its parsing and math are
unit-tested on the host:

```bash
PYTHONPATH=src python -m pytest tests/ -v
```

(The C-kernel parity test skips automatically when run outside the container, where the
compiled `ckernel` and the real data aren't present.)

---

## Project layout

| Path | What |
|---|---|
| `src/RunScript.mac` | ObjectScript entrypoint the graders run (`do ^RunScript`) |
| `src/gaia/Analyze.cls` | parallel coordinator: fan files across WorkMgr, merge results |
| `src/gaia/Work.cls` | one WorkMgr unit: analyze a single file (C kernel, with fallback) |
| `src/gaia/ckernel.pyx` | **C kernel** — libdeflate decompress + scan + write, all in C |
| `src/gaia/fastmm.pyx` | Cython C-level min/max over a flux cell (fallback path) |
| `src/gaia/analyze.py` | pure-Python analyzer + reference implementation (fallback / tests) |
| `src/gaia/gmerge.py` | dependency-free part-file merge used by the coordinator |
| `scripts/build_fastmm.sh` | compiles `ckernel` + `fastmm` into the image at build time |
| `scripts/setup_web.sh` | provisions the web UI apps on the IRIS web server |
| `web/index.html` | the interactive 3D galaxy (Three.js) |
| `tests/test_analyze.py` | host unit tests: parsing, math, fast/reference parity |
| `iris.script` | build-time setup; compiles `src/*.cls` + `src/*.mac` into USER |
| `data/in/` | the 20 benchmark `.csv.gz` files |
| `data/out/results.csv` | generated output (gitignored) |
| `docs/` | design spec |

---

## Notes / feedback (as the contest requests)

- **Embedded Python is a great fit for this data.** The quoted flux arrays are the awkward
  part; Python's `csv`/`float` handle them with almost no code for the reference path, and
  dropping to a C kernel for the hot loop was straightforward from there.
- **Finding a creative way to display the data was lots of fun.**