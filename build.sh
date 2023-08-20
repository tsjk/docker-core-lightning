#!/bin/sh
if [ -z "${1}" ]; then
  PLATFORM="linux/amd64"
else
  case "${1}" in
    "linux/arm64")    PLATFORM="linux/arm64"          ;;
    "linux/arm32v7")  PLATFORM="linux/arm32v7"        ;;
    "linux/amd64")    PLATFORM="linux/amd64"          ;;
    "all")            PLATFORM="linux/amd64"; \
                      PLATFORM+=",linux/arm64"; \
                      PLATFORM+=",linux/arm32v7"      ;;
    *) echo "UNSUPPORTED PLATFORM: ${1}" >&2; exit 1  ;;
  esac
fi

export BUILDAH_FORMAT='docker' && \
  buildah bud --platform "${PLATFORM}" --pull --layers --manifest local/core-lightning:latest --file Dockerfile .
