# Builds priv/plugins/quickjs.wasm, the sandbox runtime for uploaded plugins:
# QuickJS-ng plus firefly_runtime.c, compiled for wasm32-wasi (preview 1, reactor) with
# Debian's clang and wasi-libc. Pinned image, packages and source commit keep
# the output byte-for-byte reproducible; see build.sh.
FROM docker.io/debian:trixie-20261027-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     clang-19=1:19.1.7-3+b1 lld-19=1:19.1.7-3+b1 libclang-rt-19-dev-wasm32=1:19.1.7-3 \
     wasi-libc=0.0~git20241209.574b88d-2 \
  && rm -rf /var/lib/apt/lists/*

# build.sh checks out the pinned QuickJS-ng commit next to this file.
COPY quickjs /src/quickjs
COPY firefly_runtime.c /src/

WORKDIR /src/quickjs
RUN mkdir /out \
  && clang-19 --target=wasm32-wasi \
     -O2 -mexec-model=reactor -D_GNU_SOURCE -D_WASI_EMULATED_SIGNAL -DNDEBUG \
     -ffile-prefix-map=/src=. -I. \
     quickjs.c libregexp.c libunicode.c dtoa.c ../firefly_runtime.c \
     -lwasi-emulated-signal \
     -Wl,--strip-all -Wl,-z,stack-size=1048576 -Wl,--initial-memory=2097152 \
     -o /out/quickjs.wasm
