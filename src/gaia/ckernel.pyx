# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
"""Full C kernel for the DR3 variability scan.

Everything heavy happens in C: read the gzip file, decompress it with libdeflate
in one shot, then scan the decompressed buffer for the bp/rp flux array cells,
compute per-band min/max, and emit ONLY the qualifying rows. The 1.5 GB of
decompressed text never becomes Python objects.

Two entry points share one scanner:
  * analyze(path, bg, rg, thr)            -> Python list of tuples  (parity test)
  * analyze_to_file(path, bg, rg, thr, out) -> writes rows to `out` (production),
                                               returns the row count

libdeflate is declared inline (prototypes only) and linked against the system
libdeflate.so.0; no dev headers required. analyze.py falls back to the pure
Python / Cython-minmax path if this module isn't built.
"""
from libc.stdlib cimport malloc, realloc, free, strtod
from libc.string cimport memcpy
from libc.stdio cimport (FILE, fopen, fclose, fread, fseek, ftell,
                         SEEK_END, SEEK_SET)

cdef extern from "stdio.h":
    int fprintf(FILE *, const char *, ...)
    int snprintf(char *, size_t, const char *, ...)

cdef extern from "fcntl.h":
    int open(const char *, int, ...)
    int O_WRONLY
    int O_CREAT
    int O_APPEND

cdef extern from "unistd.h":
    ssize_t write(int, const void *, size_t)
    int close(int)

cdef extern from "sys/file.h":
    int flock(int, int)
    int LOCK_EX
    int LOCK_UN

cdef extern from *:
    """
    typedef struct libdeflate_decompressor libdeflate_decompressor;
    libdeflate_decompressor *libdeflate_alloc_decompressor(void);
    void libdeflate_free_decompressor(libdeflate_decompressor *);
    int libdeflate_gzip_decompress(libdeflate_decompressor *d,
        const void *in_, size_t in_nbytes, void *out, size_t out_avail,
        size_t *actual_out);
    """
    ctypedef struct libdeflate_decompressor:
        pass
    libdeflate_decompressor *libdeflate_alloc_decompressor()
    void libdeflate_free_decompressor(libdeflate_decompressor *d)
    int libdeflate_gzip_decompress(libdeflate_decompressor *d, const void *in_,
        size_t in_nbytes, void *out, size_t out_avail, size_t *actual_out)

cdef enum:
    NL = 10        # \n
    HASH = 35      # #
    COMMA = 44     # ,
    SPACE = 32
    LBRK = 91      # [
    RBRK = 93      # ]
    CH_N = 78      # N
    CH_n = 110     # n

cdef double DMAX = 1.7976931348623157e308


# --- read file + gzip-decompress into a malloc'd buffer; sets *outlen ---
cdef char* _slurp(str path, size_t* outlen) except NULL:
    cdef bytes pb = path.encode()
    cdef const char* cpath = pb
    cdef FILE* fp = fopen(cpath, "rb")
    if fp == NULL:
        raise IOError("cannot open " + path)
    fseek(fp, 0, SEEK_END)
    cdef long csz = ftell(fp)
    fseek(fp, 0, SEEK_SET)
    cdef char* cbuf = <char*>malloc(csz)
    if cbuf == NULL:
        fclose(fp); raise MemoryError()
    fread(cbuf, 1, csz, fp)
    fclose(fp)
    cdef size_t cap = <size_t>csz * 12 + (1 << 20)
    cdef char* out = <char*>malloc(cap)
    cdef libdeflate_decompressor* d = libdeflate_alloc_decompressor()
    cdef size_t actual = 0
    cdef int rc = libdeflate_gzip_decompress(d, cbuf, csz, out, cap, &actual)
    while rc != 0:                       # output buffer too small -> grow, retry
        cap = cap * 2
        out = <char*>realloc(out, cap)
        if out == NULL:
            free(cbuf); libdeflate_free_decompressor(d); raise MemoryError()
        rc = libdeflate_gzip_decompress(d, cbuf, csz, out, cap, &actual)
    libdeflate_free_decompressor(d)
    free(cbuf)
    outlen[0] = actual
    return out


def analyze(str path, int bg, int rg, double threshold):
    """Return a Python list of (source_id, bp_min, bp_max, rp_min, rp_max, pct)
    for rows whose max(bp_pct, rp_pct) > threshold. Used by the parity test."""
    cdef size_t n = 0
    cdef char* out = _slurp(path, &n)
    results = []
    cdef size_t i = 0, le, q, sid_s, sid_e, p
    cdef int grp, fld
    cdef double bmn, bmx, rmn, rmx, v, bp_pct, rp_pct, pct
    cdef bint bp_ok, rp_ok
    cdef char* end
    cdef char* ln
    cdef size_t llen
    cdef char c
    while i < n:
        le = i
        while le < n and out[le] != NL:
            le += 1
        ln = out + i
        llen = le - i
        if llen == 0 or ln[0] == HASH:
            i = le + 1; continue
        sid_s = 0; sid_e = 0; q = 0; fld = 0
        while q < llen:
            if ln[q] == COMMA:
                fld += 1
                if fld == 1: sid_s = q + 1
                elif fld == 2: sid_e = q; break
            q += 1
        bp_ok = False; rp_ok = False; bmn = bmx = rmn = rmx = 0
        grp = -1; q = 0
        while q < llen:
            if ln[q] == LBRK:
                grp += 1
                if grp == bg or grp == rg:
                    p = q + 1
                    while p < llen and ln[p] != RBRK:
                        c = ln[p]
                        if c == COMMA or c == SPACE:
                            p += 1; continue
                        if c == CH_N or c == CH_n:
                            while p < llen and ln[p] != COMMA and ln[p] != RBRK:
                                p += 1
                            continue
                        v = strtod(ln + p, &end)
                        if end == ln + p:
                            p += 1; continue
                        p = end - ln
                        if v > 0.0 and v < DMAX:
                            if grp == bg:
                                if not bp_ok: bmn = v; bmx = v; bp_ok = True
                                elif v < bmn: bmn = v
                                elif v > bmx: bmx = v
                            else:
                                if not rp_ok: rmn = v; rmx = v; rp_ok = True
                                elif v < rmn: rmn = v
                                elif v > rmx: rmx = v
                    q = p
                    if grp >= bg and grp >= rg:
                        break
            q += 1
        if bp_ok or rp_ok:
            bp_pct = ((bmx - bmn) / bmn * 100.0) if bp_ok else -1.0
            rp_pct = ((rmx - rmn) / rmn * 100.0) if rp_ok else -1.0
            pct = bp_pct if bp_pct >= rp_pct else rp_pct
            if pct > threshold:
                results.append((
                    ln[sid_s:sid_e].decode(),
                    bmn if bp_ok else None, bmx if bp_ok else None,
                    rmn if rp_ok else None, rmx if rp_ok else None, pct))
        i = le + 1
    free(out)
    return results


def analyze_to_file(str path, int bg, int rg, double threshold, str out_path):
    """Scan `path` and write qualifying CSV rows (no header) to `out_path`,
    entirely in C. Returns the number of rows written. This is the production
    worker unit — no per-row Python objects are created.

    Blank flux columns (a band with no valid values) are written empty. Numbers
    use %.17g so the value round-trips exactly (matches Python's repr precision)."""
    cdef size_t n = 0
    cdef char* out = _slurp(path, &n)
    cdef bytes ob = out_path.encode()
    cdef FILE* of = fopen(<const char*>ob, "wb")
    if of == NULL:
        free(out); raise IOError("cannot write " + out_path)
    cdef size_t i = 0, le, q, sid_s, sid_e, p
    cdef int grp, fld
    cdef long written = 0
    cdef double bmn, bmx, rmn, rmx, v, bp_pct, rp_pct, pct
    cdef bint bp_ok, rp_ok
    cdef char* end
    cdef char* ln
    cdef size_t llen
    cdef char c
    cdef char saved
    while i < n:
        le = i
        while le < n and out[le] != NL:
            le += 1
        ln = out + i
        llen = le - i
        if llen == 0 or ln[0] == HASH:
            i = le + 1; continue
        sid_s = 0; sid_e = 0; q = 0; fld = 0
        while q < llen:
            if ln[q] == COMMA:
                fld += 1
                if fld == 1: sid_s = q + 1
                elif fld == 2: sid_e = q; break
            q += 1
        bp_ok = False; rp_ok = False; bmn = bmx = rmn = rmx = 0
        grp = -1; q = 0
        while q < llen:
            if ln[q] == LBRK:
                grp += 1
                if grp == bg or grp == rg:
                    p = q + 1
                    while p < llen and ln[p] != RBRK:
                        c = ln[p]
                        if c == COMMA or c == SPACE:
                            p += 1; continue
                        if c == CH_N or c == CH_n:
                            while p < llen and ln[p] != COMMA and ln[p] != RBRK:
                                p += 1
                            continue
                        v = strtod(ln + p, &end)
                        if end == ln + p:
                            p += 1; continue
                        p = end - ln
                        if v > 0.0 and v < DMAX:
                            if grp == bg:
                                if not bp_ok: bmn = v; bmx = v; bp_ok = True
                                elif v < bmn: bmn = v
                                elif v > bmx: bmx = v
                            else:
                                if not rp_ok: rmn = v; rmx = v; rp_ok = True
                                elif v < rmn: rmn = v
                                elif v > rmx: rmx = v
                    q = p
                    if grp >= bg and grp >= rg:
                        break
            q += 1
        if bp_ok or rp_ok:
            bp_pct = ((bmx - bmn) / bmn * 100.0) if bp_ok else -1.0
            rp_pct = ((rmx - rmn) / rmn * 100.0) if rp_ok else -1.0
            pct = bp_pct if bp_pct >= rp_pct else rp_pct
            if pct > threshold:
                # NUL-terminate the source_id in-place to print it (we restore it)
                saved = ln[sid_e]
                ln[sid_e] = 0
                if bp_ok and rp_ok:
                    fprintf(of, "%s,%.17g,%.17g,%.17g,%.17g,%.17g\n",
                            ln + sid_s, bmn, bmx, rmn, rmx, pct)
                elif bp_ok:
                    fprintf(of, "%s,%.17g,%.17g,,,%.17g\n",
                            ln + sid_s, bmn, bmx, pct)
                else:
                    fprintf(of, "%s,,,%.17g,%.17g,%.17g\n",
                            ln + sid_s, rmn, rmx, pct)
                ln[sid_e] = saved
                written += 1
        i = le + 1
    fclose(of)
    free(out)
    return written


def analyze_to_shared(str path, int bg, int rg, double threshold, str shared_path):
    """Like analyze_to_file, but instead of a private part file, build all
    qualifying rows in one heap buffer and append them to `shared_path` in a
    SINGLE flock-guarded write(). This removes the separate merge pass: every
    worker appends straight to the final CSV. Safety: the whole buffer is written
    under LOCK_EX in one write() call, so concurrent workers can't interleave
    lines. Returns the number of rows written."""
    cdef size_t n = 0
    cdef char* out = _slurp(path, &n)

    # growable output buffer
    cdef size_t obcap = 1 << 20
    cdef char* ob = <char*>malloc(obcap)
    cdef size_t obn = 0
    cdef char tmp[512]
    cdef int wrote
    cdef long rows = 0

    cdef size_t i = 0, le, q, sid_s, sid_e, p
    cdef int grp, fld
    cdef double bmn, bmx, rmn, rmx, v, bp_pct, rp_pct, pct
    cdef bint bp_ok, rp_ok
    cdef char* end
    cdef char* ln
    cdef size_t llen
    cdef char c, saved
    while i < n:
        le = i
        while le < n and out[le] != NL:
            le += 1
        ln = out + i
        llen = le - i
        if llen == 0 or ln[0] == HASH:
            i = le + 1; continue
        sid_s = 0; sid_e = 0; q = 0; fld = 0
        while q < llen:
            if ln[q] == COMMA:
                fld += 1
                if fld == 1: sid_s = q + 1
                elif fld == 2: sid_e = q; break
            q += 1
        bp_ok = False; rp_ok = False; bmn = bmx = rmn = rmx = 0
        grp = -1; q = 0
        while q < llen:
            if ln[q] == LBRK:
                grp += 1
                if grp == bg or grp == rg:
                    p = q + 1
                    while p < llen and ln[p] != RBRK:
                        c = ln[p]
                        if c == COMMA or c == SPACE:
                            p += 1; continue
                        if c == CH_N or c == CH_n:
                            while p < llen and ln[p] != COMMA and ln[p] != RBRK:
                                p += 1
                            continue
                        v = strtod(ln + p, &end)
                        if end == ln + p:
                            p += 1; continue
                        p = end - ln
                        if v > 0.0 and v < DMAX:
                            if grp == bg:
                                if not bp_ok: bmn = v; bmx = v; bp_ok = True
                                elif v < bmn: bmn = v
                                elif v > bmx: bmx = v
                            else:
                                if not rp_ok: rmn = v; rmx = v; rp_ok = True
                                elif v < rmn: rmn = v
                                elif v > rmx: rmx = v
                    q = p
                    if grp >= bg and grp >= rg:
                        break
            q += 1
        if bp_ok or rp_ok:
            bp_pct = ((bmx - bmn) / bmn * 100.0) if bp_ok else -1.0
            rp_pct = ((rmx - rmn) / rmn * 100.0) if rp_ok else -1.0
            pct = bp_pct if bp_pct >= rp_pct else rp_pct
            if pct > threshold:
                saved = ln[sid_e]
                ln[sid_e] = 0
                if bp_ok and rp_ok:
                    wrote = snprintf(tmp, 512, "%s,%.17g,%.17g,%.17g,%.17g,%.17g\n",
                                     ln + sid_s, bmn, bmx, rmn, rmx, pct)
                elif bp_ok:
                    wrote = snprintf(tmp, 512, "%s,%.17g,%.17g,,,%.17g\n",
                                     ln + sid_s, bmn, bmx, pct)
                else:
                    wrote = snprintf(tmp, 512, "%s,,,%.17g,%.17g,%.17g\n",
                                     ln + sid_s, rmn, rmx, pct)
                ln[sid_e] = saved
                if wrote > 0:
                    while obn + wrote > obcap:
                        obcap = obcap * 2
                        ob = <char*>realloc(ob, obcap)
                    memcpy(ob + obn, tmp, wrote)
                    obn += wrote
                    rows += 1
        i = le + 1
    free(out)

    # one locked append of the whole buffer
    cdef bytes sb = shared_path.encode()
    cdef int fd = open(<const char*>sb, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0:
        flock(fd, LOCK_EX)
        if obn > 0:
            write(fd, ob, obn)
        flock(fd, LOCK_UN)
        close(fd)
    free(ob)
    return rows
