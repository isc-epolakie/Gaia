"""Tiny, dependency-free merge helper for the coordinator.

Kept separate from gaia.analyze so the coordinator process doesn't pay to import
the analyzer's heavier deps (isal, csv, re, fastmm, ckernel) just to concatenate
the worker .part files. Bulk file IO in Python — the ObjectScript stream ReadLine
merge was ~4s/file at this scale."""

HEADER = "source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change\n"


def merge_parts(part_paths, out_path):
    """Concatenate worker .part files into out_path with the CSV header.
    Returns the number of data rows written."""
    import os
    rows = 0
    with open(out_path, "w", newline="") as out:
        out.write(HEADER)
        for p in part_paths:
            if not os.path.exists(p):
                continue
            with open(p, "r") as f:
                data = f.read()
            if data:
                out.write(data)
                rows += data.count("\n")
    return rows
