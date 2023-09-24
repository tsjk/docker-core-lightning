#!/bin/sh
if [ "${1}" == "--prepare-qemu" -o "${1}" == "--prepare-qemu-only" ]; then
  [ "${1}" == "--prepare-qemu-only" ] && PREPARE_ONLY=1 || PREPARE_ONLY=0
  shift 1; p="/$0"; p="${p%/*}"; p="${p:-.}"; p="${p##/}/"; d=$(cd "${p}"; pwd)
  { [ -x "${d}/qemu-binfmt-conf.sh" ] || {
    wget -qO- "https://raw.githubusercontent.com/qemu/qemu/master/scripts/qemu-binfmt-conf.sh" > "${d}/qemu-binfmt-conf.sh" && \
      chmod 0755 "${d}/qemu-binfmt-conf.sh"; }; } && \
    { if which qemu-aarch64-static > /dev/null 2>&1; then
        q=$(which qemu-aarch64-static); q_dirname=$(dirname "${q}")
        [ -n "${q_dirname}" ] && \
          ( for f in /proc/sys/fs/binfmt_misc/qemu-*; do [[ ! -e "${f}" ]] || echo '-1' | sudo tee "${f}" > /dev/null || exit 1; done ) && \
          sudo "${d}/qemu-binfmt-conf.sh" --qemu-suffix -static --qemu-path "${q_dirname}" --persistent yes
     elif which qemu-aarch64 > /dev/null 2>&1; then
        q=$(which qemu-aarch64); q_dirname=$(dirname "${q}")
        [ -n "${q_dirname}" ] && \
          ( for f in /proc/sys/fs/binfmt_misc/qemu-*; do [[ ! -e "${f}" ]] || echo '-1' | sudo tee "${f}" > /dev/null || exit 1; done ) && \
          sudo "${d}/qemu-binfmt-conf.sh" --qemu-path "${q_dirname}" --persistent yes
     else
       echo "Found neither qemu-aarch64-static nor qemu-aarch64."; exit 1
     fi; } || exit 1
  [ ${PREPARE_ONLY} -ne 1 ] || exit 0
fi

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
