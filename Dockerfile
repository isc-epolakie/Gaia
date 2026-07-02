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
RUN pip install --user --break-system-packages isal

RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
	iris merge IRIS merge.cpf && \
	iris session IRIS < iris.script && \
    iris stop IRIS quietly safely