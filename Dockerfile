# syntax = docker/dockerfile:1.4

ARG SPDK_IMAGE \
    CONTAINER_REGISTRY \
    NVMEOF_TARGET  # either 'gateway' or 'cli'

#------------------------------------------------------------------------------
# Base image for NVMEOF_TARGET=cli (nvmeof-cli)
FROM registry.redhat.io/ubi10/ubi:latest AS base-cli

RUN dnf install -y \
        python3.12 \
        python3.12-pip \
        python3.12-devel \
        ceph-common \
        openssl \
        libaio \
        numactl-libs \
        libbsd \
    && dnf clean all

ENV GRPC_DNS_RESOLVER=native
ENTRYPOINT ["python3", "-m", "control.cli"]
CMD []

#------------------------------------------------------------------------------
# Base image for NVMEOF_TARGET=gateway (nvmeof-gateway)
ARG SPDK_IMAGE
FROM ${SPDK_IMAGE} AS base-gateway

ARG REMOTE_SOURCES
ARG REMOTE_SOURCES_DIR
ARG ARCH

ENV GRPC_DNS_RESOLVER=native

# COPY $REMOTE_SOURCES $REMOTE_SOURCES_DIR

WORKDIR ${REMOTE_SOURCES_DIR}/${REMOTE_SOURCES}/app

RUN --mount=type=secret,id=org-id \
    --mount=type=secret,id=activation-key \
    set -euxo pipefail && \
    subscription-manager register \
        --activationkey=$(cat /run/secrets/activation-key) \
        --org=$(cat /run/secrets/org-id) && \
    subscription-manager repos \
        --enable=rhel-10-for-${ARCH}-baseos-rpms \
        --enable=rhel-10-for-${ARCH}-appstream-rpms \
        --enable=codeready-builder-for-rhel-10-${ARCH}-rpms || true

RUN dnf install -y \
        python3.12 \
        ceph-common \
        libaio \
        numactl \
        numactl-libs \
        libbsd \
        json-c \
        libibverbs \
        librdmacm \
    --setopt=install_weak_deps=0 \
    && dnf clean all

RUN dnf install -y python3-rados python3-rbd gdb ceph-mon-client-nvmeof librbd1 dnf-plugins-core openssl --nobest --allowerasing

COPY ${REMOTE_SOURCES_DIR}/${REMOTE_SOURCES}/app /src

ENTRYPOINT ["python3", "-m", "control"]
CMD ["-c", "ceph-nvmeof.conf"]

#------------------------------------------------------------------------------
FROM base-${NVMEOF_TARGET} AS python-intermediate

RUN dnf install -y \
        gcc gcc-c++ \
        python3.12-devel \
        libffi-devel \
        openssl-devel \
        git \
        make \
        pkgconf-pkg-config \
    && dnf clean all

ENV PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=UTF-8 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PYTHONPATH=/src/__pypackages__/3.12/lib

WORKDIR /src

#------------------------------------------------------------------------------
FROM python-intermediate AS builder-base
ARG PDM_VERSION=2.26.8 \
    PDM_INSTALL_CMD=sync \
    PDM_INSTALL_FLAGS="-v --no-isolation --no-self --no-editable" \
    PDM_INSTALL_DEV="--dev"
ENV PDM_INSTALL_FLAGS="$PDM_INSTALL_FLAGS $PDM_INSTALL_DEV"

ENV PDM_CHECK_UPDATE=0

# https://pdm.fming.dev/latest/usage/advanced/#use-pdm-in-a-multi-stage-dockerfile
RUN \
    --mount=type=cache,target=/var/cache/dnf \
    --mount=type=cache,target=/var/lib/dnf \
    dnf install -y python3-pip gcc gcc-c++ python3-devel libffi-devel git

RUN pip install -U pip setuptools wheel

RUN pip install pdm==$PDM_VERSION

#------------------------------------------------------------------------------
FROM builder-base AS builder

COPY pyproject.toml pdm.lock pdm.toml ./
RUN pdm "$PDM_INSTALL_CMD" $PDM_INSTALL_FLAGS

COPY . .
RUN pdm run protoc

#------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM python-intermediate
ARG NVMEOF_CLI_VERSION
ENV NVMEOF_CLI_VERSION="${NVMEOF_CLI_VERSION}"
COPY --from=builder /src /src

ENV PYTHONPATH=/src:$PYTHONPATH

RUN subscription-manager unregister || true