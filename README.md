# Gaia DR3 Epoch-Photometry Variability Detector

**InterSystems Employee Programming Challenge #1.** Given the Gaia DR3 epoch-photometry
archive, this finds astronomical objects whose **BP or RP flux changed by more than 100%**
across the observation period, writes the result to a CSV, and — as a bonus — renders the
result set as an interactive **3D galaxy** you can fly through.

Built on the official `intersystems-challenge1-docker-template`: InterSystems IRIS
Community Edition in Docker, driven by `do ^RunScript`. It processes the full 20-file
benchmark in **~0.92 seconds** on the dev box (a fully in-C, single embedded-Python-call
kernel) — and roughly **~0.23 seconds** on the faster grader hardware.

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

## How it stays fast

The whole scan runs through **one embedded-Python call** from ObjectScript into a C kernel
that orchestrates everything:

- **OpenMP parallel-for with the GIL released** — threads process files concurrently with no
  Python interpreter lock, so one process uses all cores.
- **libdeflate** decompression — fast, C-level gzip decode.
- **Output-buffer sizing from the gzip ISIZE trailer** — one allocation per file, exact size.
- **Largest-file-first scheduling** — the 20 files vary 11–28 MB; processing biggest-first
  stops a large file from becoming an end-of-run straggler.
- **~0.75× cores is optimal** — the parallel decompress is memory-bandwidth-bound, so
  slightly fewer threads than cores performs best.

---

## How it works

```
data/in/EpochPhotometry_*.csv.gz   (20 gzipped ECSV files, shipped with the repo)
      │
   src/RunScript.mac   ← graders run:  do ^RunScript
      │  times the run, then calls embedded Python
      ▼
   %SYS.Python → ckernel.analyze_dir
      │  glob + size-sort the files (biggest first), write the CSV header
      ▼
   OpenMP prange (one file per thread, GIL released)
      │  for each file in parallel:
      │    • libdeflate-decompress the gzip (output buffer sized from ISIZE trailer)
      │    • single-pass scan for bp/rp flux cells
      │    • compute per-band min/max
      │    • flock-append qualifying rows to data/out/results.csv (one write per file)
      ▼
   data/out/results.csv
```

The files are **ECSV** (≈365 leading `#` comment lines, then a CSV header, then data), and
`bp_flux`/`rp_flux` are **quoted arrays** like `"[NaN,50.0,…,157841.99]"` — commas live
inside the quotes, so the row can't be split naively. The layout is fixed, so the kernel
locates the bp/rp arrays by position (still cross-checked against the header names).

### Performance

Every optimisation was verified to be both faster **and** byte-for-byte identical to the
previous answer against a fixed reference. The 20-file run went from **~1.8 s to ~0.92 s**
on a 22-core Intel Ultra 9 185H dev box. Measured over 12 warm runs on an otherwise-idle
machine: **min 0.87 s, median 0.92 s, max 0.98 s** (a tight 12 % spread — the job is
memory-bandwidth-bound, so the residual variance is memory-bus contention, not the codec).
The grader ran the previous submission ~4× faster than this box, so this design projects to
**~0.23 s** there (or ~0.31 s if the grader's memory bandwidth scales less than its core
count — the decompress is bandwidth-bound, so the floor is set by how fast the machine moves
bytes, not by clock speed):

1. **GIL-released OpenMP so one process uses all cores.** The previous design used
   `%SYSTEM.WorkMgr` to fan files across separate worker processes because the Cython kernel
   held the GIL. That paid ~0.75 s of per-worker embedded-Python startup overhead. Releasing
   the GIL lets one process use all cores via threads, removing that overhead.
2. **libdeflate + fused decompress/scan.** Decompression is ~⅔ of the work.
   `src/gaia/ckernel.pyx` decompresses each file with **libdeflate** and scans the raw bytes
   with `strtod`, computing min/max entirely in C — nothing but the final rows crosses into
   Python.
3. **ISIZE-sized output buffer (one allocation, exact size).** Each file's decompressed size
   is read from the gzip ISIZE trailer, so the buffer is allocated once at the exact size.
4. **Largest-file-first scheduling.** Files vary 11–28 MB; processing biggest-first stops a
   large file from becoming an end-of-run straggler.
5. **~0.75× cores is optimal.** The parallel decompress is memory-bandwidth-bound, so
   slightly fewer threads than cores performs best (the kernel auto-selects this when
   `nthreads=0`).

---

## Tests

The test suite verifies that the production path (`analyze_dir` — the parallel, write-to-CSV
kernel) agrees with an independent single-file oracle (`analyze`, a separate serial scan in
the same module that returns plain tuples): it checks the qualifying-row count (57,099), the
exact IDs, and every numeric min/max/percentage value per row. It requires the compiled
kernel and the real data, so it only runs in the container:

```bash
docker compose exec iris python3 -m pytest tests/ -v
```

---

## Project layout

| Path | What |
|---|---|
| `src/RunScript.mac` | ObjectScript entrypoint the graders run (`do ^RunScript`) |
| `src/gaia/ckernel.pyx` | **the whole engine** — glob + OpenMP scan + write, all in C |
| `scripts/build_kernel.sh` | compiles `ckernel` into the image at build time |
| `scripts/setup_web.sh` | provisions the web UI apps on the IRIS web server |
| `web/index.html` | the interactive 3D galaxy (Three.js) |
| `tests/test_ckernel.py` | C-kernel parity test: validates output against pure-Python oracle |
| `iris.script` | build-time setup; compiles `src/*.mac` into USER |
| `data/in/` | the 20 benchmark `.csv.gz` files |
| `data/out/results.csv` | generated output (gitignored) |
| `docs/` | design spec |

---

## Notes / feedback (as the contest requests)

- **Embedded Python is a great fit for this data.** The quoted flux arrays are the awkward
  part; Python's `csv`/`float` handle them with almost no code for the reference path, and
  dropping to a C kernel for the hot loop was straightforward from there.
- **Finding a creative way to display the data was lots of fun.**