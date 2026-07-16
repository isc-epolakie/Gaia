"""In-container parity + count test for the full C kernel.

Requires the compiled `ckernel` module and the real DR3 data, so it skips
on the host:  docker compose exec iris python3 -m pytest tests/ -v
"""
import glob
import os
import sys

import pytest

DATA_DIR = "/home/irisowner/dev/data/in"
BG, RG, THR = 8, 13, 100.0


def _have_data():
    return bool(glob.glob(os.path.join(DATA_DIR, "EpochPhotometry_*.csv.gz")))


ckernel = pytest.importorskip("ckernel")
pytestmark = pytest.mark.skipif(not _have_data(),
                                reason="real DR3 data not present (run in container)")


def _oracle():
    """source_id -> tuple, from the per-file analyze() oracle over all files."""
    ref = {}
    for f in sorted(glob.glob(os.path.join(DATA_DIR, "EpochPhotometry_*.csv.gz"))):
        for r in ckernel.analyze(f, BG, RG, THR):
            ref[r[0]] = r
    return ref


def test_analyze_dir_matches_oracle_and_count(tmp_path):
    out = str(tmp_path / "results.csv")
    total = ckernel.analyze_dir(DATA_DIR, out, BG, RG, THR, 0)
    assert total == 57099

    with open(out) as f:
        lines = f.read().splitlines()
    assert lines[0] == ("source_id,bp_min_flux,bp_max_flux,"
                        "rp_min_flux,rp_max_flux,percentage_change")
    body = lines[1:]
    assert len(body) == total

    # ids in the CSV match the oracle's ids exactly
    csv_ids = {ln.split(",", 1)[0] for ln in body}
    ref = _oracle()
    assert csv_ids == set(ref)

    # parse CSV and verify numeric values match the oracle
    for ln in body:
        fields = ln.split(",")
        source_id = fields[0]
        # parse: "" -> None, else float
        def parse_field(f):
            return None if f == "" else float(f)
        bp_min = parse_field(fields[1])
        bp_max = parse_field(fields[2])
        rp_min = parse_field(fields[3])
        rp_max = parse_field(fields[4])
        pct = float(fields[5])

        oracle_row = ref[source_id]  # (id, bp_min, bp_max, rp_min, rp_max, pct)

        # compare: None must match None; floats compared with relative tolerance
        def floats_close(a, b):
            if a is None and b is None:
                return True
            if a is None or b is None:
                return False
            return abs(a - b) < 1e-9 * max(1, abs(a))

        assert floats_close(bp_min, oracle_row[1]), f"{source_id}: bp_min mismatch"
        assert floats_close(bp_max, oracle_row[2]), f"{source_id}: bp_max mismatch"
        assert floats_close(rp_min, oracle_row[3]), f"{source_id}: rp_min mismatch"
        assert floats_close(rp_max, oracle_row[4]), f"{source_id}: rp_max mismatch"
        assert floats_close(pct, oracle_row[5]), f"{source_id}: pct mismatch"
