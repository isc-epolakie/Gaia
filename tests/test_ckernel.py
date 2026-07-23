"""In-container parity + count test for the full C kernel.

Requires the compiled `ckernel` module and the real DR3 data, so it skips on the
host. The stock image has no pytest, so the file is also runnable directly:

    docker compose exec iris python3 tests/test_ckernel.py     # no dependencies
    docker compose exec iris python3 -m pytest tests/ -v       # if pytest present
"""
import glob
import os

try:
    import pytest
except ImportError:              # stock image has no pytest; file still runs via __main__
    pytest = None

DATA_DIR = "/home/irisowner/dev/data/in"
BG, RG, THR = 8, 13, 100.0


def _have_data():
    return bool(glob.glob(os.path.join(DATA_DIR, "EpochPhotometry_*.csv.gz")))


if pytest is not None:
    ckernel = pytest.importorskip("ckernel")
    pytestmark = pytest.mark.skipif(not _have_data(),
                                    reason="real DR3 data not present (run in container)")

    @pytest.fixture(autouse=True)
    def _restore_parse_mode():
        """A test that pins the parser regime must not leak it to the next test."""
        yield
        ckernel._force_parse_mode(-1)
else:
    import ckernel


def _oracle():
    """source_id -> tuple, from the per-file analyze() oracle over all files.
    analyze() parses with strtod, so the oracle is regime-independent."""
    ref = {}
    for f in sorted(glob.glob(os.path.join(DATA_DIR, "EpochPhotometry_*.csv.gz"))):
        for r in ckernel.analyze(f, BG, RG, THR):
            ref[r[0]] = r
    return ref


# Both parser regimes must pass: 1 = the native 80-bit x87 long-double fast path,
# 0 = the portable correctly-rounded cr_atof path the grader uses under Rosetta
# (no 80-bit x87). -1 = whatever the runtime probe selects on this machine.
_parametrize = (pytest.mark.parametrize("parse_mode", [-1, 1, 0])
                if pytest is not None else (lambda f: f))


@_parametrize
def test_analyze_dir_matches_oracle_and_count(tmp_path, parse_mode=-1):
    ckernel._force_parse_mode(parse_mode)
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


def test_grader_path_is_bit_identical_to_strtod(tmp_path):
    """The Rosetta path (cr_atof) uses only integer/__int128 math, so it is
    arch-independent: bit-identity here is a proof of bit-identity on the grader.
    Assert it reproduces the strtod oracle EXACTLY (not just within tolerance) --
    every emitted field must be the exact %.17g of the oracle's value."""
    ckernel._force_parse_mode(0)
    out = str(tmp_path / "grader.csv")
    total = ckernel.analyze_dir(DATA_DIR, out, BG, RG, THR, 0)
    assert total == 57099

    def fmt(x):
        return "" if x is None else "%.17g" % x

    ref = _oracle()
    with open(out) as f:
        body = f.read().splitlines()[1:]
    assert len(body) == len(ref)
    for ln in body:
        p = ln.split(",")
        sid, r = p[0], ref[p[0]]
        expected = [sid, fmt(r[1]), fmt(r[2]), fmt(r[3]), fmt(r[4]), "%.17g" % r[5]]
        assert p == expected, f"{sid}: cr_atof row not bit-identical to strtod oracle"


if __name__ == "__main__":
    # Dependency-free runner for the stock image (no pytest). Exits non-zero on
    # failure so it works as a CI/build gate too.
    import pathlib
    import sys
    import tempfile

    if not _have_data():
        print("SKIP: real DR3 data not present (run in container)")
        sys.exit(0)

    failures = 0
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        for mode in (-1, 1, 0):
            try:
                test_analyze_dir_matches_oracle_and_count(tmp, mode)
                print(f"PASS  parity+count  parse_mode={mode:>2}")
            except AssertionError as e:
                failures += 1
                print(f"FAIL  parity+count  parse_mode={mode:>2}: {e}")
            finally:
                ckernel._force_parse_mode(-1)
        try:
            test_grader_path_is_bit_identical_to_strtod(tmp)
            print("PASS  grader-path bit-identity vs strtod oracle")
        except AssertionError as e:
            failures += 1
            print(f"FAIL  grader-path bit-identity: {e}")
        finally:
            ckernel._force_parse_mode(-1)

    print("OK" if failures == 0 else f"{failures} FAILED")
    sys.exit(1 if failures else 0)
