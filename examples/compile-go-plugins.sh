#!/bin/sh
__GO_VERSION="1.22.10"
case "$(uname -m)" in
  "x86_64") __GO_URL="https://go.dev/dl/go${__GO_VERSION}.linux-amd64.tar.gz" ;;
  "aarch64") __GO_URL="https://go.dev/dl/go${__GO_VERSION}.linux-arm64.tar.gz" ;;
  "armv7l") __GO_URL="https://go.dev/dl/go${__GO_VERSION}.linux-armv6l.tar.gz" ;;
  *) echo "ERROR: Unsupported machine type: $(uname -m)."; exit 1  ;; \
esac

__PLUGIN_REPO_PATH="/home/lightning/.lightning/.plugins"
__PLUGIN_PATH="/home/lightning/.lightning/plugins"

__install_go() {
  { [ $(find /var/lib/apt/lists/ -mindepth 1 -maxdepth 1 -name '*_debian_dists_*' | wc -l) -gt 0 ] || { \
      apt-get update; apt-get --no-install-recommends -qq -y dist-upgrade; }; } && \
    apt-get install --no-install-recommends -qq -y \
      autoconf automake build-essential gettext libarchive-tools libc-dev libev-dev libevent-dev libffi-dev \
      libgmp-dev libpq-dev libsqlite3-dev libssl-dev libtool pkg-config protobuf-compiler zlib1g zlib1g-dev && \
      rm -rf /usr/local/go && wget -qO- "${__GO_URL}" | bsdtar -C /usr/local -xzf -
}


n="peerswap"; v="v20241224"
if [ ! -e "${__PLUGIN_PATH}/${n}" ] || [ -L "${__PLUGIN_PATH}/${n}" ]; then
  s="${__PLUGIN_REPO_PATH}/${n}"
  p="${__PLUGIN_REPO_PATH}/_available/${n}-${v}/${n}"
  { [ -x "${p}" ] && ! ldd -r "${p}" 2>&1 | grep -qF "undefined symbol: "; } || {
    echo "INFO: Installing plugin \"${n}-${v}\"..." && \
      { which go > /dev/null 2>&1 || __install_go; } && \
      { echo "$PATH" | grep -q -E '(^|:)/usr/local/go/bin(:|$)' || export PATH="$PATH:/usr/local/go/bin"; } && \
      ( cd "${s}" && mkdir -p "$(dirname "${p}")" && \
          git config --global --add safe.directory "${s}" && make cln-release && mv "${n}" "${p}" ) && \
      chown -R lightning:lightning "$(dirname "${p}")" && chmod 0755 "${p}" && \
      rm -f "${__PLUGIN_PATH}/${n}" && \
      ( cd "${__PLUGIN_PATH}" && ln -rsv "${p}" && chown -h lightning:lightning "$(basename "${p}")" ) && \
      echo "INFO: Installation of plugin \"${n}\" finished." || { echo "ERROR: Installation of \"${n}\" failed."; exit 1; }
  }
  [ -L "${__PLUGIN_PATH}/${n}" ] || ( cd "${__PLUGIN_PATH}" && ln -rsv "${p}" && chown -h lightning:lightning "$(basename "${p}")" )
fi
