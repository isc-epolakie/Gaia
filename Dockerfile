ARG IMAGE=intersystems/iris-community:latest-em
FROM $IMAGE

WORKDIR /home/irisowner/dev
COPY . .

## Embedded Python environment
ENV IRISUSERNAME="_SYSTEM"
ENV IRISPASSWORD="SYS"
ENV IRISNAMESPACE="USER"
ENV PYTHON_PATH=/usr/irissys/bin/
ENV PATH="/usr/irissys/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/irisowner/bin"

## isal (igzip) decompresses the gzipped inputs ~2x faster than stdlib gzip;
## decompression is the dominant cost, so this is the biggest single speedup.
## Installed into the irisowner user site so embedded Python (%SYS.Python) sees it.
## The analyzer falls back to stdlib gzip if this package is ever absent.
RUN pip install --user --break-system-packages isal cython

## Compile the C-level flux min/max (src/gaia/fastmm.pyx) into user site-packages
## as a top-level `fastmm` module. ~3x faster than the Python parse loop; the
## analyzer falls back to pure Python if the module is absent. The runtime docker
## mount shadows src/gaia, so the .so must live in site-packages, not there.
RUN bash /home/irisowner/dev/scripts/build_fastmm.sh

RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
	iris merge IRIS merge.cpf && \
	iris session IRIS < iris.script && \
    iris stop IRIS quietly safely