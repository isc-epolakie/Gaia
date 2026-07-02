"""Gaia DR3 epoch-photometry variability analyzer.

For each source in the DR3 epoch-photometry files, look at the per-transit BP and
RP flux arrays, keep only valid flux values, and compute how much each band varied:

    percentage_change = ((max_flux - min_flux) / min_flux) * 100

The source's percentage_change is the larger of its BP and RP values, and we emit
the source only when that exceeds 100%.

Design notes / feedback (the contest asks for these):
- The files are ECSV: ~365 leading '#' comment lines, then a CSV header, then data.
  We just skip every line starting with '#' and let csv.reader parse the rest.
- bp_flux / rp_flux are QUOTED arrays like "[NaN,50.0,...]" — the commas are inside
  the quotes, so a naive split breaks. Python's csv module handles the quoting for
  free, which is a big reason embedded Python is a pleasant fit here.
- "Valid" flux = a finite number that is > 0. The task says ignore missing / null /
  NaN / "otherwise invalid"; negative and zero flux are unphysical (Gaia itself flags
  negative flux as rejected) and dividing by a zero/negative min would be nonsense.
- Pure functions (no IRIS dependency) so this runs and unit-tests on the host too;
  RunScript.mac calls run() inside IRIS via embedded Python.
"""
import csv
import glob
import gzip
import math
import os

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
    with gzip.open(path, "rt", newline="") as f:
        data_lines = (line for line in f if not line.startswith("#"))
        yield from csv.reader(data_lines)


def analyze_file(path):
    """Yield qualifying result rows (as lists matching OUTPUT_HEADER) from one file.

    Also yields via the returned generator; callers count total vs qualifying.
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
