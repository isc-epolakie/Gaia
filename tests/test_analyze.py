"""Host-side unit tests for the DR3 epoch-photometry analyzer.

Pure Python, no IRIS needed:  PYTHONPATH=src python -m pytest tests/ -v
"""
import gzip
import os
import csv
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from gaia.analyze import (  # noqa: E402
    parse_flux_array, band_stats, run, OUTPUT_HEADER,
    analyze_file, analyze_file_fast,
)


# ---- parse_flux_array ----

def test_parse_keeps_finite_positive_only():
    cell = "[NaN,50.0,60.0,-3.0,0.0,100.0,null,]"
    assert parse_flux_array(cell) == [50.0, 60.0, 100.0]

def test_parse_empty_and_bracket_only():
    assert parse_flux_array("") == []
    assert parse_flux_array("[]") == []

def test_parse_nan_case_insensitive():
    assert parse_flux_array("[nan,NAN,NaN,7.0]") == [7.0]


# ---- band_stats ----

def test_band_stats_pct():
    mn, mx, pct = band_stats([50.0, 200.0])
    assert (mn, mx) == (50.0, 200.0)
    assert abs(pct - 300.0) < 1e-9          # (200-50)/50*100

def test_band_stats_single_value_is_zero_pct():
    assert band_stats([42.0]) == (42.0, 42.0, 0.0)

def test_band_stats_empty():
    assert band_stats([]) == (None, None, None)


# ---- run() over a synthetic ECSV file ----

def _write_ecsv(path, rows):
    """rows: list of (source_id, bp_flux_cell, rp_flux_cell)."""
    header = ["solution_id", "source_id", "n_transits", "bp_flux", "rp_flux"]
    with gzip.open(path, "wt", newline="") as f:
        f.write("# %ECSV 1.0\n# ---\n# comment line that must be skipped\n")
        w = csv.writer(f)
        w.writerow(header)
        for sid, bp, rp in rows:
            w.writerow([1, sid, 3, bp, rp])

def _write_real_ecsv(path, rows):
    """Write a file with the REAL DR3 column layout so analyze_file_fast's
    positional array indexing (arrays start at col 3, bp_flux=col11, rp_flux=col16)
    is exercised. rows: list of (source_id, bp_cell, rp_cell)."""
    # 48 columns; fill the array columns we don't use with a dummy "[1.0]".
    header = ["solution_id","source_id","n_transits","transit_id","g_transit_time",
        "g_transit_flux","g_transit_flux_error","g_transit_flux_over_error","g_transit_mag",
        "g_transit_n_obs","bp_obs_time","bp_flux","bp_flux_error","bp_flux_over_error","bp_mag",
        "rp_obs_time","rp_flux"] + [f"pad_{i}" for i in range(17, 48)]
    with gzip.open(path, "wt", newline="") as f:
        f.write("# %ECSV 1.0\n# comment\n")
        w = csv.writer(f)
        w.writerow(header)
        for sid, bp, rp in rows:
            row = [1, sid, 3] + ["[1.0]"] * (len(header) - 3)
            row[11] = bp   # bp_flux
            row[16] = rp   # rp_flux
            w.writerow(row)

def test_fast_matches_reference(tmp_path):
    p = str(tmp_path / "EpochPhotometry_000000-000001.csv.gz")
    _write_real_ecsv(p, [
        ("111", "[50.0,200.0,NaN]", "[100.0,150.0]"),
        ("222", "[100.0,180.0]", "[10.0,40.0]"),
        ("333", "[NaN,-1.0,0.0]", "[]"),          # bp no valid; rp none -> pad[1.0] used? no, rp empty
        ("444", "[5.0,5.0]", "[7.0,7.0]"),        # single-ish -> 0%
    ])
    ref = {r[0]: r for r in analyze_file(p)}
    fast = {r[0]: r for r in analyze_file_fast(p)}
    assert set(ref) == set(fast)
    for sid in ref:
        for j in range(1, 6):
            a, b = ref[sid][j], fast[sid][j]
            if a is None or b is None:
                assert a == b
            else:
                assert abs(a - b) < 1e-9

def test_run_filters_and_formats(tmp_path):
    in_dir = tmp_path / "in"; in_dir.mkdir()
    _write_ecsv(str(in_dir / "EpochPhotometry_000000-000001.csv.gz"), [
        # BP 50->200 = 300% (qualifies via BP); RP 100->150 = 50%
        ("111", "[50.0,200.0,NaN]", "[100.0,150.0]"),
        # BP 100->180 = 80%; RP 10->40 = 300% (qualifies via RP, max-of-two)
        ("222", "[100.0,180.0]", "[10.0,40.0]"),
        # both < 100% -> excluded
        ("333", "[100.0,150.0]", "[100.0,120.0]"),
        # no valid flux at all -> excluded
        ("444", "[NaN,-1.0,0.0]", "[]"),
    ])
    out = tmp_path / "out" / "results.csv"
    seen, qualified = run(str(in_dir), str(out))

    # 444 has no valid flux in either band, so it yields no score and isn't counted;
    # 111, 222, 333 are scored (seen=3); 111 and 222 exceed 100% (qualified=2).
    assert seen == 3
    assert qualified == 2

    with open(out, newline="") as f:
        rows = list(csv.reader(f))
    assert rows[0] == OUTPUT_HEADER
    ids = [r[0] for r in rows[1:]]
    assert ids == ["111", "222"]          # sorted by pct desc (both 300%, stable order)
    assert "333" not in ids and "444" not in ids

def test_run_band_with_no_valid_leaves_blanks(tmp_path):
    in_dir = tmp_path / "in"; in_dir.mkdir()
    # BP qualifies (10->100 = 900%), RP has no valid values -> blank rp columns
    _write_ecsv(str(in_dir / "EpochPhotometry_000000-000001.csv.gz"), [
        ("999", "[10.0,100.0]", "[NaN,-5.0]"),
    ])
    out = tmp_path / "out" / "results.csv"
    run(str(in_dir), str(out))
    with open(out, newline="") as f:
        rows = list(csv.reader(f))
    row = rows[1]
    # source_id,bp_min,bp_max,rp_min,rp_max,pct
    assert row[0] == "999"
    assert row[3] == "" and row[4] == ""      # rp blank
    assert abs(float(row[5]) - 900.0) < 1e-9
