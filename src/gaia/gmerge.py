"""Tiny, dependency-free coordinator helpers.

Kept separate from gaia.analyze so the coordinator process never imports the
analyzer's heavier deps (isal, csv, re, fastmm, ckernel). Two jobs:

* plan(in_dir, tmp_dir)  - discover the input files, sorted biggest-first (Python
  glob + os.path.getsize is ~0.03s vs ~0.18s for ObjectScript FileSetFunc), and
  return parallel (input_path, part_path) lists for the WorkMgr fan-out.
* merge_parts(...)       - concatenate the worker .part files (binary chunked bulk
  IO; the ObjectScript stream ReadLine merge was ~4s/file at this scale).
"""
import glob
import os

HEADER = b"source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change\n"


def plan(in_dir, tmp_dir):
    """Return (inputs, parts): the EpochPhotometry files in in_dir sorted by
    descending size (longest-processing-time-first scheduling), paired with a
    per-file .part output path in tmp_dir. Returned as two parallel lists so
    ObjectScript can index them 1:1 when queueing WorkMgr callbacks."""
    files = glob.glob(os.path.join(in_dir, "EpochPhotometry_*.csv.gz"))
    files.sort(key=lambda f: -os.path.getsize(f))
    os.makedirs(tmp_dir, exist_ok=True)
    parts = [os.path.join(tmp_dir, "p_%d.csv" % i) for i in range(len(files))]
    return files, parts


def init_output(out_path):
    """Create/truncate the output CSV with just the header. Used by the
    shared-append path, where workers then flock-append their rows to it."""
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(HEADER)


def count_rows(out_path):
    """Count data rows (lines minus the header) in the finished output."""
    total = 0
    with open(out_path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            total += b.count(b"\n")
    return max(0, total - 1)   # minus the header line


def merge_parts(part_paths, out_path):
    """Concatenate worker .part files into out_path with the CSV header (binary
    chunked). Returns the number of data rows written."""
    rows = 0
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as out:
        out.write(HEADER)
        for p in part_paths:
            try:
                f = open(p, "rb")
            except FileNotFoundError:
                continue
            with f:
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    out.write(b)
                    rows += b.count(b"\n")
    return rows
