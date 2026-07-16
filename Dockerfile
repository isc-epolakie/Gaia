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

## Compile the full C kernel (src/gaia/ckernel.pyx) into user site-packages as a
## top-level `ckernel` module: libdeflate decompress + OpenMP parallel scan +
## write, all in C. `do ^RunScript` calls it directly. Cython is the only build
## dependency; the runtime docker mount shadows src/gaia, so the .so must live in
## site-packages, not there.
RUN pip install --user --break-system-packages cython
RUN bash /home/irisowner/dev/scripts/build_kernel.sh

RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
	iris merge IRIS merge.cpf && \
	iris session IRIS < iris.script && \
    iris stop IRIS quietly safely