# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
"""C-level min/max over a Gaia flux-array cell.

The per-token float parse + min/max loop was the single biggest Python-level cost
(~1.4s of the run). Scanning the raw bytes buffer with strtod in Cython does the
same work ~3x faster and, on bytes input (no str decode/encode), effectively hides
the parse cost behind gzip decompression. Pure-Python `_minmax_valid` in analyze.py
remains the reference/fallback when this compiled module is unavailable.

Input: a flux cell WITHOUT the surrounding brackets, e.g. b"NaN,50.0,157841.99".
Valid = finite and > 0 (matches the analyzer's rule). Returns (min, max) floats or
(None, None) if there are no valid values.
"""
from libc.stdlib cimport strtod


def minmax(bytes cell):
    cdef char* s = cell
    cdef Py_ssize_t n = len(cell), i = 0
    cdef char* p
    cdef char* end
    cdef double v, mn = 0, mx = 0
    cdef bint have = False
    while i < n:
        # skip separators / whitespace
        while i < n and (s[i] == c',' or s[i] == c' '):
            i += 1
        if i >= n:
            break
        # NaN / null token -> skip to next comma
        if s[i] == c'N' or s[i] == c'n':
            while i < n and s[i] != c',':
                i += 1
            continue
        p = s + i
        v = strtod(p, &end)
        if end == p:                 # not a number; advance one and retry
            i += 1
            continue
        i = end - s
        # strtod yields +inf for overflow; v>0 keeps positives, v<=DBL_MAX via compare
        if v > 0.0 and v < 1.7976931348623157e308:
            if not have:
                mn = v
                mx = v
                have = True
            elif v < mn:
                mn = v
            elif v > mx:
                mx = v
    if not have:
        return (None, None)
    return (mn, mx)
