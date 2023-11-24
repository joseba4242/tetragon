# This Dockerfile can be used to compile natively on amd64 and cross-compile on
# amd64 for arm64.
#
# It can technically build natively on arm64 and cross-compile on arm64 for
# amd64 but the steps involving the gcc cross compiler might need rework. It's
# assumed that if [ $BUILDARCH != $TARGET_ARCH ] we are cross-compiling from
# amd64 to arm64
#
# For help on Docker cross compilation see the following blogpost:
# https://www.docker.com/blog/faster-multi-platform-builds-dockerfile-cross-compilation-guide/

# First builder (cross-)compile the BPF programs
FROM --platform=$BUILDPLATFORM quay.io/cilium/clang:aeaada5cf60efe8d0e772d032fe3cc2bc613739c@sha256:b440ae7b3591a80ffef8120b2ac99e802bbd31dee10f5f15a48566832ae0866f as bpf-builder
WORKDIR /go/src/github.com/cilium/tetragon
RUN apt-get update && apt-get install -y linux-libc-dev
COPY . ./
ARG TARGET_ARCH
RUN make tetragon-bpf LOCAL_CLANG=1 TARGET_ARCH=$TARGET_ARCH

# Second builder (cross-)compile:
# - tetragon (pkg/bpf uses CGO, so a gcc cross compiler is needed)
# - tetra
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.21.4@sha256:57bf74a970b68b10fe005f17f550554406d9b696d10b29f1a4bdc8cae37fd063 as tetragon-builder
WORKDIR /go/src/github.com/cilium/tetragon
ARG TETRAGON_VERSION TARGET_ARCH BUILDARCH
RUN apt-get update
RUN if [ $BUILDARCH != $TARGET_ARCH ]; \
    then apt-get install -y libelf-dev zlib1g-dev crossbuild-essential-$TARGET_ARCH; \
    else apt-get install -y libelf-dev zlib1g-dev; fi
COPY . ./
RUN if [ $BUILDARCH != $TARGET_ARCH ]; \
    then make tetragon-image LOCAL_CLANG=1 VERSION=$TETRAGON_VERSION TARGET_ARCH=$TARGET_ARCH CC=aarch64-linux-gnu-gcc; \
    else make tetragon-image LOCAL_CLANG=1 VERSION=$TETRAGON_VERSION TARGET_ARCH=$TARGET_ARCH; fi

# Third builder (cross-)compile a stripped gops
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.21.4-alpine@sha256:110b07af87238fbdc5f1df52b00927cf58ce3de358eeeb1854f10a8b5e5e1411 as gops
ARG TARGET_ARCH
RUN apk add --no-cache git \
# renovate: datasource=github-releases depName=google/gops
 && git clone --depth 1 --branch v0.3.28 https://github.com/google/gops /gops \
 && cd /gops \
 && GOARCH=$TARGET_ARCH go build -ldflags="-s -w" .

# This builder (cross-)compile a stripped static version of bpftool.
# This step was kept because the downloaded version includes LLVM libs with the
# disassembler that makes the static binary grow from ~2Mo to ~30Mo.
#FROM --platform=$BUILDPLATFORM quay.io/cilium/clang:aeaada5cf60efe8d0e772d032fe3cc2bc613739c@sha256:b440ae7b3591a80ffef8120b2ac99e802bbd31dee10f5f15a48566832ae0866f as bpftool-builder
#WORKDIR /bpftool
#ARG TARGET_ARCH BUILDARCH
#RUN if [ $BUILDARCH != $TARGET_ARCH ]; \
#    then apt-get update && echo "deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse\n\
#deb [arch=amd64] http://security.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse\n\
#deb [arch=amd64] http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse\n\
#deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse\n\
#deb [arch=arm64] http://ports.ubuntu.com/ jammy main restricted universe multiverse\n\
#deb [arch=arm64] http://ports.ubuntu.com/ jammy-updates main restricted universe multiverse\n\
#deb [arch=arm64] http://ports.ubuntu.com/ jammy-security main restricted universe multiverse\n\
#deb [arch=arm64] http://ports.ubuntu.com/ jammy-backports main restricted universe multiverse" > /etc/apt/sources.list \
#    && dpkg --add-architecture arm64; fi
#RUN apt-get update
#RUN if [ $BUILDARCH != $TARGET_ARCH ]; \
#    then apt-get install -y curl git llvm gcc pkg-config zlib1g-dev libelf1 libcap2 zlib1g libelf-dev libcap-dev crossbuild-essential-${TARGET_ARCH}; \
#    else apt-get install -y curl git llvm gcc pkg-config zlib1g-dev libelf-dev libcap-dev; fi
# v7.1.0
#ENV BPFTOOL_REV "b01941c8f7890489f09713348a7d89567538504b"
#RUN git clone --recurse-submodules https://github.com/libbpf/bpftool.git . && git checkout ${BPFTOOL_REV}
#RUN if [ $BUILDARCH != $TARGET_ARCH ]; \
#    then make -C src EXTRA_CFLAGS=--static CC=aarch64-linux-gnu-gcc -j $(nproc) && aarch64-linux-gnu-strip src/bpftool; \
#    else make -C src EXTRA_CFLAGS=--static -j $(nproc) && strip src/bpftool; fi

# This stage downloads a stripped static version of bpftool with LLVM disassembler
FROM --platform=$BUILDPLATFORM quay.io/cilium/alpine-curl@sha256:408430f548a8390089b9b83020148b0ef80b0be1beb41a98a8bfe036709c196e as bpftool-downloader
ARG TARGET_ARCH
ARG BPFTOOL_TAG=v7.2.0-snapshot.0
RUN curl -L https://github.com/libbpf/bpftool/releases/download/${BPFTOOL_TAG}/bpftool-${BPFTOOL_TAG}-${TARGET_ARCH}.tar.gz | tar xz && chmod +x bpftool

# Almost final step runs on target platform (might need emulation) and
# retrieves (cross-)compiled binaries from builders
FROM docker.io/library/alpine:3.18.4@sha256:eece025e432126ce23f223450a0326fbebde39cdf496a85d8c016293fc851978 as base-build
RUN apk add iproute2
RUN mkdir /var/lib/tetragon/ && \
    mkdir -p /etc/tetragon/tetragon.conf.d/ && \
    mkdir -p /etc/tetragon/tetragon.tp.d/ && \
    apk add --no-cache --update bash
COPY --from=tetragon-builder /go/src/github.com/cilium/tetragon/tetragon /usr/bin/
COPY --from=tetragon-builder /go/src/github.com/cilium/tetragon/tetra /usr/bin/
COPY --from=gops /gops/gops /usr/bin/
COPY --from=bpf-builder /go/src/github.com/cilium/tetragon/bpf/objs/*.o /var/lib/tetragon/
ENTRYPOINT ["/usr/bin/tetragon"]

# This target only builds with the `--target release` option and reduces the
# size of the final image with a static build of bpftool without the LLVM
# disassembler
FROM base-build as release
COPY --from=bpftool-downloader /bpftool /usr/bin/bpftool
#COPY --from=bpftool-builder bpftool/src/bpftool /usr/bin/bpftool

#FROM base-build
#COPY --from=bpftool-downloader /bpftool /usr/bin/bpftool
