#!/usr/bin/env bash
# Compile src/gaia/fastmm.pyx (Cython) into the user site-packages as a top-level
# `fastmm` module. Kept in a script (not inline in the Dockerfile) to avoid fragile
# nested-quote escaping. The analyzer falls back to pure Python if this is absent,
# so a failure here is non-fatal to correctness (only speed).
set -e
SRC=/home/irisowner/dev/src/gaia/fastmm.pyx
work=/tmp/fastmm_build
mkdir -p "$work"
cp "$SRC" "$work/fastmm.pyx"
cd "$work"
python3 -c "from Cython.Build import cythonize; cythonize('fastmm.pyx', language_level=3)"
inc=$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')
site=$(python3 -c 'import site; print(site.getusersitepackages())')
mkdir -p "$site"
x86_64-linux-gnu-gcc -shared -fPIC -O2 -I"$inc" fastmm.c \
  -o "$site/fastmm.cpython-312-x86_64-linux-gnu.so"
echo "built fastmm -> $site"
