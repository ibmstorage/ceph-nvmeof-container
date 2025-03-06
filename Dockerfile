# syntax = docker/dockerfile:1.4

ARG SPDK_IMAGE \
    CONTAINER_REGISTRY \
    NVMEOF_TARGET  # either 'gateway' or 'cli'

#------------------------------------------------------------------------------
# Base image for NVMEOF_TARGET=cli (nvmeof-cli)
FROM registry.redhat.io/ubi10/ubi:latest AS base-cli
ENV GRPC_DNS_RESOLVER=native
ENTRYPOINT ["python3", "-m", "control.cli"]
CMD []

#------------------------------------------------------------------------------
ARG SPDK_IMAGE
FROM ${SPDK_IMAGE} AS base-gateway

# Define paths safely
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV LD_LIBRARY_PATH="/lib64:/usr/lib64"

RUN --mount=type=secret,id=org-id,target=/run/secrets/org-id \
    --mount=type=secret,id=activation-key,target=/run/secrets/activation-key \
    ["/usr/bin/python3", "-c", "import subprocess; key = open('/run/secrets/activation-key').read().strip(); org = open('/run/secrets/org-id').read().strip(); cmd = ['/usr/sbin/subscription-manager', 'register', '--activationkey=' + key, '--org=' + org]; subprocess.run(cmd, check=True)"]

RUN subscription-manager repos --enable=codeready-builder-for-rhel-10-$(uname -m)-rpms

#------------------------------------------------------------------------------
ARG REMOTE_SOURCES
ARG REMOTE_SOURCES_DIR

COPY $REMOTE_SOURCES $REMOTE_SOURCES_DIR
WORKDIR ${REMOTE_SOURCES_DIR}/${REMOTE_SOURCES}/app

RUN dnf install -y python3-rados python3-rbd gdb ceph-mon-client-nvmeof librbd1 dnf-plugins-core openssl --nobest --allowerasing
RUN mkdir -p /src

ENTRYPOINT ["python3", "-m", "control"]
CMD ["-c", "ceph-nvmeof.conf"]

#------------------------------------------------------------------------------
# Intermediate layer for Python set-up
FROM base-$NVMEOF_TARGET AS python-intermediate

# RUN \
#     --mount=type=cache,target=/var/cache/dnf \
#     --mount=type=cache,target=/var/lib/dnf \
#     dnf update -y --exclude=openssl-fips-provider

ENV PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=UTF-8 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PIP_NO_CACHE_DIR=off \
    PYTHON_MAJOR=3 \
    PYTHON_MINOR=12 \
    PDM_PREFER_BINARY=:all: \
    PIP_ONLY_BINARY=:all: \
    PIP_DEFAULT_TIMEOUT=100

ARG APPDIR=/src

ARG NVMEOF_NAME \
    NVMEOF_SUMMARY \
    NVMEOF_DESCRIPTION \
    NVMEOF_URL \
    NVMEOF_VERSION \
    NVMEOF_MAINTAINER \
    NVMEOF_TAGS \
    NVMEOF_WANTS \
    NVMEOF_EXPOSE_SERVICES \
    BUILD_DATE \
    NVMEOF_GIT_REPO \
    NVMEOF_GIT_BRANCH \
    NVMEOF_GIT_COMMIT \
    NVMEOF_SPDK_VERSION \
    NVMEOF_CEPH_VERSION \
    NVMEOF_GIT_MODIFIED_FILES \
    SPDK_GIT_REPO \
    SPDK_GIT_BRANCH \
    SPDK_GIT_COMMIT \
    HUGEPAGES \
    HUGEPAGES_DIR

ENV NVMEOF_VERSION="${NVMEOF_VERSION}" \
      NVMEOF_GIT_REPO="${NVMEOF_GIT_REPO}" \
      NVMEOF_GIT_BRANCH="${NVMEOF_GIT_BRANCH}" \
      NVMEOF_GIT_COMMIT="${NVMEOF_GIT_COMMIT}" \
      BUILD_DATE="${BUILD_DATE}" \
      NVMEOF_SPDK_VERSION="${NVMEOF_SPDK_VERSION}" \
      NVMEOF_CEPH_VERSION="${NVMEOF_CEPH_VERSION}" \
      NVMEOF_GIT_MODIFIED_FILES="${NVMEOF_GIT_MODIFIED_FILES}" \
      SPDK_GIT_REPO="${SPDK_GIT_REPO}" \
      SPDK_GIT_BRANCH="${SPDK_GIT_BRANCH}" \
      SPDK_GIT_COMMIT="${SPDK_GIT_COMMIT}" \
      HUGEPAGES="${HUGEPAGES}" \
      HUGEPAGES_DIR="${HUGEPAGES_DIR}"

# Generic labels
LABEL name="$NVMEOF_NAME" \
      version="$NVMEOF_VERSION" \
      summary="$NVMEOF_SUMMARY" \
      description="$NVMEOF_DESCRIPTION" \
      maintainer="$NVMEOF_MAINTAINER" \
      release="" \
      url="$NVMEOF_URL" \
      build-date="$BUILD_DATE" \
      vcs-ref="$NVMEOF_GIT_COMMIT"

# k8s-specific labels
LABEL io.k8s.display-name="$NVMEOF_SUMMARY" \
      io.k8s.description="$NVMEOF_DESCRIPTION"

# k8s-specific labels
LABEL io.openshift.tags="$NVMEOF_TAGS" \
      io.openshift.wants="$NVMEOF_WANTS" \
      io.openshift.expose-services="$NVMEOF_EXPOSE_SERVICES"

# Ceph-specific labels
LABEL io.ceph.component="$NVMEOF_NAME" \
      io.ceph.summary="$NVMEOF_SUMMARY" \
      io.ceph.description="$NVMEOF_DESCRIPTION" \
      io.ceph.url="$NVMEOF_URL" \
      io.ceph.version="$NVMEOF_VERSION" \
      io.ceph.maintainer="$NVMEOF_MAINTAINER" \
      io.ceph.git.repo="$NVMEOF_GIT_REPO" \
      io.ceph.git.branch="$NVMEOF_GIT_BRANCH" \
      io.ceph.git.commit="$NVMEOF_GIT_COMMIT"

ENV PYTHONPATH=$APPDIR/__pypackages__/$PYTHON_MAJOR.$PYTHON_MINOR/lib

WORKDIR $APPDIR

#------------------------------------------------------------------------------
FROM python-intermediate AS builder-base
ARG PDM_VERSION=2.26.8 \
    PDM_INSTALL_CMD=install \
    PDM_INSTALL_FLAGS="-v --no-isolation --no-self --no-editable" \
    PDM_INSTALL_DEV="--dev"
ENV PDM_INSTALL_FLAGS="$PDM_INSTALL_FLAGS $PDM_INSTALL_DEV"

ENV PDM_CHECK_UPDATE=0

# https://pdm.fming.dev/latest/usage/advanced/#use-pdm-in-a-multi-stage-dockerfile
RUN \
    --mount=type=cache,target=/var/cache/dnf \
    --mount=type=cache,target=/var/lib/dnf \
    dnf install -y python3-pip gcc gcc-c++ python3-devel libffi-devel git openssl-devel rust cargo 
RUN \
    --mount=type=cache,target=/root/.cache/pip \
    pip install -U pip "setuptools<82" wheel

RUN \
    --mount=type=cache,target=/root/.cache/pip \
    pip install --ignore-installed pdm==$PDM_VERSION

RUN \
    --mount=type=cache,target=/root/.cache/pip \
    pip install maturin

#------------------------------------------------------------------------------
FROM builder-base AS builder

COPY pyproject.toml pdm.lock pdm.toml ./
RUN \
    --mount=type=cache,target=/root/.cache/pdm \
    pdm install -v --no-isolation --no-self --no-editable

COPY . .
COPY ceph-nvmeof.conf /src/
RUN pdm run protoc

#------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM python-intermediate
ARG NVMEOF_CLI_VERSION
ENV NVMEOF_CLI_VERSION="${NVMEOF_CLI_VERSION}"
COPY --from=builder /src /src

ENV PYTHONPATH=/src:$PYTHONPATH

RUN subscription-manager unregister || true