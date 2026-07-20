#!/usr/bin/env bash
# Compile the full C kernel (src/gaia/ckernel.pyx) into the user site-packages
# as a top-level `ckernel` module. It links libdeflate and OpenMP (libgomp).
# The whole DR3 job runs inside this one module; there is no fallback path.
set -e

site=$(python3 -c 'import site; print(site.getusersitepackages())')
inc=$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')
tag=$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
mkdir -p "$site"

work=/tmp/gaia_build
mkdir -p "$work"

# ckernel links libdeflate. The image ships libdeflate.so.0 but no dev symlink,
# so make a linkable name; at runtime the loader finds libdeflate.so.0 on the
# standard path, so no LD_LIBRARY_PATH is needed.
libdir="$HOME/.gaia-lib"
mkdir -p "$libdir"
ln -sf /usr/lib/x86_64-linux-gnu/libdeflate.so.0 "$libdir/libdeflate.so"

cp /home/irisowner/dev/src/gaia/ckernel.pyx "$work/ckernel.pyx"
cd "$work"
python3 -c "from Cython.Build import cythonize; cythonize('ckernel.pyx', language_level=3)"
x86_64-linux-gnu-gcc -shared -fPIC -O3 -fopenmp -I"$inc" ckernel.c \
  -L"$libdir" -ldeflate \
  -o "$site/ckernel${tag}"

echo "built ckernel -> $site/ckernel${tag}"
