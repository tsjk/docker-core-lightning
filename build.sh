#!/bin/sh
if [ -z "${1}" ]; then
  PLATFORM="linux/amd64"; TAG_PREFIX="amd64"
else
  case "${1}" in
    "linux/arm64")    PLATFORM="linux/arm64";   TAG_PREFIX="arm64"    ;;
    "linux/arm32v7")  PLATFORM="linux/arm32v7"; TAG_PREFIX="arm32v7"  ;;
    "linux/amd64")    PLATFORM="linux/amd64";   TAG_PREFIX="amd64"    ;;
    "all")            PLATFORM="linux/amd64"; \
                      PLATFORM+=",linux/arm64"; \
                      PLATFORM+=",linux/arm32v7"      ;;
    *) echo "UNSUPPORTED PLATFORM: ${1}" >&2; exit 1  ;;
  esac
fi

export BUILDAH_FORMAT='docker' && \
  { if echo "${PLATFORM}" | grep -q -E '.*,.*'; then
      buildah bud --platform "${PLATFORM}" --pull --layers --manifest local/core-lightning:latest --file Dockerfile .
    else
      buildah bud --platform "${PLATFORM}" --pull --layers --tag local/core-lightning:${TAG_PREFIX}-latest --file Dockerfile . && \
      echo "NOTE: Add the new images to a manifest if needed."
    fi
  }
