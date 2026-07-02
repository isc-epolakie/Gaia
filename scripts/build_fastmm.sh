#!/usr/bin/env bash
# Compile the Cython C extensions into the user site-packages (top-level modules):
#   * fastmm  - C min/max over a flux cell (used by the Python fast-path fallback)
#   * ckernel - full C kernel: libdeflate decompress + scan + write (production path)
# Kept in a script (not inline in the Dockerfile) to avoid fragile nested-quote
# escaping. The analyzer falls back to pure Python if these are absent, so a
# failure here is non-fatal to correctness (only speed).
set -e

site=$(python3 -c 'import site; print(site.getusersitepackages())')
inc=$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')
mkdir -p "$site"

work=/tmp/gaia_build
mkdir -p "$work"

# fastmm (no external libs)
cp /home/irisowner/dev/src/gaia/fastmm.pyx "$work/fastmm.pyx"
cd "$work"
python3 -c "from Cython.Build import cythonize; cythonize('fastmm.pyx', language_level=3)"
x86_64-linux-gnu-gcc -shared -fPIC -O3 -I"$inc" fastmm.c \
  -o "$site/fastmm.cpython-312-x86_64-linux-gnu.so"

# ckernel links libdeflate. The image ships libdeflate.so.0 but no dev symlink,
# so make a linkable name; at runtime the loader finds libdeflate.so.0 on the
# standard path, so no LD_LIBRARY_PATH is needed.
libdir="$HOME/.gaia-lib"
mkdir -p "$libdir"
ln -sf /usr/lib/x86_64-linux-gnu/libdeflate.so.0 "$libdir/libdeflate.so"
cp /home/irisowner/dev/src/gaia/ckernel.pyx "$work/ckernel.pyx"
python3 -c "from Cython.Build import cythonize; cythonize('ckernel.pyx', language_level=3)"
x86_64-linux-gnu-gcc -shared -fPIC -O3 -I"$inc" ckernel.c \
  -L"$libdir" -ldeflate \
  -o "$site/ckernel.cpython-312-x86_64-linux-gnu.so"

echo "built fastmm + ckernel -> $site"
