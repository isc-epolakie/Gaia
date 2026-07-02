"""Gaia DR3 epoch-photometry variability analyzer.

For each source in the DR3 epoch-photometry files, look at the per-transit BP and
RP flux arrays, keep only valid flux values, and compute how much each band varied:

    percentage_change = ((max_flux - min_flux) / min_flux) * 100

The source's percentage_change is the larger of its BP and RP values, and we emit
the source only when that exceeds 100%.

Design notes / feedback (the contest asks for these):
- The files are ECSV: ~365 leading '#' comment lines, then a CSV header, then data.
  We skip every line starting with '#'.
- bp_flux / rp_flux are QUOTED arrays like "[NaN,50.0,...]" - the commas are inside
  the quotes, so a naive split of the whole row breaks. There are two paths here:
  * analyze_file() - readable reference using csv.reader (handles the quoting for free).
  * analyze_file_fast() - the production path. csv.reader spends ~6.8s parsing all 48
    columns' quoting; we instead extract only source_id and the bp/rp array groups, cutting
    the single-thread parse from ~15.7s to ~11s. A test asserts the two paths agree exactly.
  The files are then fanned across %SYSTEM.WorkMgr workers (see src/Gaia/*.cls), taking the
  full run to ~3s.
- "Valid" flux = a finite number that is > 0. The task says ignore missing / null /
  NaN / "otherwise invalid"; negative and zero flux are unphysical (Gaia itself flags
  negative flux as rejected) and dividing by a zero/negative min would be nonsense.
- Pure functions (no IRIS dependency) so this runs and unit-tests on the host too.
"""
import csv
import glob
import gzip
import math
import os

# isal.igzip decompresses gzip ~2x faster than the stdlib (decompression is the
# single biggest cost here). Fall back to stdlib gzip if isal isn't installed so
# the analyzer still runs anywhere (host tests, etc.).
try:
    from isal import igzip as _gz
except ImportError:  # pragma: no cover
    _gz = gzip

# The three columns we need, located by name from the header (never by index, so a
# column-order change in a future release can't silently corrupt results).
COL_SOURCE_ID = "source_id"
COL_BP_FLUX = "bp_flux"
COL_RP_FLUX = "rp_flux"

OUTPUT_HEADER = [
    "source_id", "bp_min_flux", "bp_max_flux",
    "rp_min_flux", "rp_max_flux", "percentage_change",
]


def parse_flux_array(cell):
    """Parse a flux-array cell into a list of valid floats.

    Accepts values like '[NaN,50.02,60.9,157841.99]' (the surrounding quotes are
    already stripped by csv.reader) or '' / '[]'. Keeps only finite, strictly
    positive numbers; drops NaN, empty, null, non-numeric, and non-positive tokens.
    """
    if not cell:
        return []
    s = cell.strip()
    if s.startswith("["):
        s = s[1:]
    if s.endswith("]"):
        s = s[:-1]
    out = []
    for tok in s.split(","):
        tok = tok.strip()
        if not tok or tok.lower() in ("nan", "null", "none"):
            continue
        try:
            v = float(tok)
        except ValueError:
            continue
        if math.isfinite(v) and v > 0:
            out.append(v)
    return out


def band_stats(values):
    """Return (min, max, pct) for a band, or (None, None, None) if no valid values.

    pct = ((max - min) / min) * 100. With a single value min == max so pct == 0.
    """
    if not values:
        return None, None, None
    mn = min(values)
    mx = max(values)
    pct = ((mx - mn) / mn) * 100.0
    return mn, mx, pct


def _rows(path):
    """Yield csv rows from a (gzipped) ECSV file, skipping '#' comment lines."""
    with _gz.open(path, "rt", newline="") as f:
        data_lines = (line for line in f if not line.startswith("#"))
        yield from csv.reader(data_lines)


def analyze_file(path):
    """Yield qualifying result rows (as lists matching OUTPUT_HEADER) from one file.

    Reference (readable) implementation using csv.reader; analyze_file_fast below
    produces identical results but avoids the ~6.8s csv.reader overhead by
    extracting only the three fields we need. Kept for cross-checking in tests.
    """
    it = _rows(path)
    header = next(it)
    idx = {name: header.index(name) for name in (COL_SOURCE_ID, COL_BP_FLUX, COL_RP_FLUX)}
    si, bi, ri = idx[COL_SOURCE_ID], idx[COL_BP_FLUX], idx[COL_RP_FLUX]
    for row in it:
        if len(row) <= ri:
            continue
        bp_min, bp_max, bp_pct = band_stats(parse_flux_array(row[bi]))
        rp_min, rp_max, rp_pct = band_stats(parse_flux_array(row[ri]))
        pcts = [p for p in (bp_pct, rp_pct) if p is not None]
        if not pcts:
            continue
        pct = max(pcts)
        yield row[si], bp_min, bp_max, rp_min, rp_max, pct


# --- Fast path -------------------------------------------------------------
# csv.reader spends ~6.8s parsing all 48 columns' quoting when we need only 3.
# The row layout is fixed: the first 3 fields are scalar (no commas), then every
# remaining field is a quoted "[...]" array. So source_id is the 2nd scalar, and
# bp_flux / rp_flux are specific "[...]" groups. We walk the array groups with a
# regex and STOP once we've seen the rp group (the ~31 trailing arrays are never
# parsed). Column positions are still resolved from the header (not hard-coded),
# so a layout change is detected, not silently mis-parsed.
import re  # noqa: E402
_ARR = re.compile(r"\[[^\]]*\]")           # str form (reference / fallback)
_ARRB = re.compile(rb"\[[^\]]*\]")         # bytes form (production fast path)

# C-level min/max over a flux cell (bytes). ~3x faster than the Python loop and,
# on bytes input, makes the parse cost effectively free behind gzip decompression.
# The compiled module lives in user site-packages as top-level `fastmm` (the
# docker mount shadows a copy inside src/gaia); `gaia.fastmm` is the fallback for
# a locally-built host copy; pure Python is the final fallback.
try:
    try:
        from fastmm import minmax as _minmax_bytes
    except ImportError:
        from gaia.fastmm import minmax as _minmax_bytes
except ImportError:  # pragma: no cover
    def _minmax_bytes(cell):           # cell: bytes WITHOUT brackets
        mn = mx = None
        for tok in cell.split(b","):
            if not tok or tok[0] in (78, 110):   # 'N' / 'n'
                continue
            try:
                v = float(tok)
            except ValueError:
                continue
            if 0.0 < v < 1.7976931348623157e308:
                if mn is None or v < mn:
                    mn = v
                if mx is None or v > mx:
                    mx = v
        return mn, mx


def _minmax_valid(cell):
    """min/max of finite, >0 values in a bracketed '[...]' str cell (reference
    path used by analyze_file and its parity test)."""
    mn = mx = None
    for tok in cell[1:-1].split(","):
        if not tok:
            continue
        c = tok[0]
        if c == "N" or c == "n":      # NaN / null
            continue
        try:
            v = float(tok)
        except ValueError:
            continue
        if v > 0.0:                    # finite & positive (inf is caught below)
            if v == float("inf"):
                continue
            if mn is None or v < mn:
                mn = v
            if mx is None or v > mx:
                mx = v
    return mn, mx


def _header_array_indices(header_line):
    """From the header line, return (source_id_scalar_ok, bp_group, rp_group):
    which 0-based '[...]'-group corresponds to bp_flux and rp_flux."""
    cols = header_line.rstrip("\n").split(",")
    # Columns 0..2 (solution_id, source_id, n_transits) are scalar; every column
    # from transit_id (index 3) onward is a quoted "[...]" array. So the Nth array
    # group corresponds to column (3 + N), i.e. array_index = column_index - 3.
    first_array = 3
    bp = cols.index(COL_BP_FLUX) - first_array
    rp = cols.index(COL_RP_FLUX) - first_array
    return cols.index(COL_SOURCE_ID), bp, rp


def analyze_file_fast(path):
    """Fast per-file analyzer: yields (source_id, bp_min, bp_max, rp_min, rp_max,
    pct) for every scored source. Identical results to analyze_file.

    Works entirely in BYTES (no str decode): gzip -> bytes lines -> bytes regex
    for the two array cells we need -> C-level min/max. This keeps the parse cost
    behind the (dominant) decompression cost."""
    with _gz.open(path, "rb") as f:
        header_line = None
        for line in f:
            if line[:1] == b"#":
                continue
            header_line = line
            break
        sidx, bg, rg = _header_array_indices(header_line.decode())
        hi = bg if bg > rg else rg
        for line in f:
            if line[:1] == b"#":
                continue
            # source_id: leading scalars are comma-separated and have no commas,
            # so a bounded split of the pre-'[' prefix is safe and cheap.
            sid = line.split(b",", sidx + 1)[sidx]
            # Walk the "[...]" groups, grab the bp and rp ones, stop at the later
            # of the two (the trailing ~31 array columns are never scanned).
            bp_cell = rp_cell = None
            i = 0
            for m in _ARRB.finditer(line):
                if i == bg:
                    bp_cell = m.group()
                if i == rg:
                    rp_cell = m.group()
                if i == hi:
                    break
                i += 1
            if rp_cell is None and bp_cell is None:
                continue
            bmn, bmx = _minmax_bytes(bp_cell[1:-1]) if bp_cell is not None else (None, None)
            rmn, rmx = _minmax_bytes(rp_cell[1:-1]) if rp_cell is not None else (None, None)
            bp_pct = ((bmx - bmn) / bmn) * 100.0 if bmn is not None else None
            rp_pct = ((rmx - rmn) / rmn) * 100.0 if rmn is not None else None
            if bp_pct is None and rp_pct is None:
                continue
            pct = bp_pct if rp_pct is None else rp_pct if bp_pct is None else (bp_pct if bp_pct >= rp_pct else rp_pct)
            # sid is bytes here; decode just this one small field for the CSV
            yield sid.decode(), bmn, bmx, rmn, rmx, pct


def write_part(path, out_path):
    """Worker unit: analyze one file, write qualifying (>100%) rows to out_path
    (no header). Returns (seen, qualified). Called by IRIS WorkMgr workers."""
    seen = q = 0
    with open(out_path, "w", newline="") as f:
        for sid, bmn, bmx, rmn, rmx, pct in analyze_file_fast(path):
            seen += 1
            if pct > 100.0:
                q += 1
                f.write("%s,%s,%s,%s,%s,%r\n" % (sid, _fmt(bmn), _fmt(bmx), _fmt(rmn), _fmt(rmx), pct))
    return seen, q


def merge_parts(part_paths, out_path):
    """Concatenate worker .part files into out_path with the CSV header. Done in
    Python (fast bulk IO) rather than ObjectScript stream ReadLine (very slow).
    Returns the number of data rows written."""
    rows = 0
    with open(out_path, "w", newline="") as out:
        out.write(",".join(OUTPUT_HEADER) + "\n")
        for p in part_paths:
            if not os.path.exists(p):
                continue
            with open(p, "r") as f:
                data = f.read()
            if data:
                out.write(data)
                rows += data.count("\n")
    return rows


def _fmt(v):
    return "" if v is None else repr(v)


def run(in_dir, out_path):
    """Process every EpochPhotometry_*.csv.gz in in_dir, write results.csv to
    out_path (with header), return (sources_seen, sources_qualified).

    Results are sorted by percentage_change descending (not required, but tidy).
    """
    files = sorted(glob.glob(os.path.join(in_dir, "EpochPhotometry_*.csv.gz")))
    seen = 0
    results = []
    for path in files:
        for sid, bpmn, bpmx, rpmn, rpmx, pct in analyze_file(path):
            seen += 1
            if pct > 100.0:
                results.append((sid, bpmn, bpmx, rpmn, rpmx, pct))
    results.sort(key=lambda r: r[5], reverse=True)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(OUTPUT_HEADER)
        for sid, bpmn, bpmx, rpmn, rpmx, pct in results:
            w.writerow([sid, _fmt(bpmn), _fmt(bpmx), _fmt(rpmn), _fmt(rpmx), repr(pct)])
    return seen, len(results)
