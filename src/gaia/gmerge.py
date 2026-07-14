"""Tiny, dependency-free merge helper for the pure-Python fallback path.

Kept separate from gaia.analyze so importing it never pulls in the analyzer's
heavier deps (isal, csv, re, fastmm, ckernel). Only used when the compiled C
kernel is absent: the coordinator then has each worker write a private .part
file and calls merge_parts() to concatenate them into the final CSV. On the
normal C-kernel path the workers append straight to the output and this module
is not imported at all.
"""
import os

HEADER = b"source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change\n"


def merge_parts(part_paths, out_path):
    """Concatenate worker .part files into out_path with the CSV header (binary
    chunked bulk IO; the ObjectScript stream ReadLine merge was ~4s/file at this
    scale). Returns the number of data rows written."""
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
