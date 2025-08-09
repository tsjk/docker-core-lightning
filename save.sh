#!/bin/sh
TAG="${1}"; ARCH=$(echo "${1}" | grep -P -o '(?<=-)(amd64|arm32v7|arm64)$'); TAG="${1%-${ARCH}}"; shift 1
[ -n "${1}" ] && { TARGET="${1}"; shift 1; } || TARGET="."

[ -n "${ARCH}" ] && [ -n "${TAG}" ] && [ -d "${TARGET}" ] && ( \
  set -x && \
  podman image tag localhost/local/core-lightning:${ARCH}-latest localhost/local/core-lightning:${TAG}-${ARCH} && \
  podman image save localhost/local/core-lightning:${TAG}-${ARCH} | pv -trabC | xz -T0 > "${TARGET}/core-lightning-${ARCH}-${TAG}.tar.xz"; \
)
