#!/bin/sh

case "$(uname -m)" in
  "x86_64") __GO_URL="https://go.dev/dl/go1.18.10.linux-amd64.tar.gz" ;;
  "aarch64") __GO_URL="https://go.dev/dl/go1.18.10.linux-arm64.tar.gz" ;;
  "armv7l") __GO_URL="https://go.dev/dl/go1.10.10.linux-armv6l.tar.gz" ;;
  *) echo "ERROR: Unsupported machine type: $(uname -m)."; exit 1  ;; \
esac

n="circular"
if [ -L "/home/lightning/.lightning/plugins/_enabled/${n}" ]; then
  s="/home/lightning/.lightning/plugins/.lightningd-plugins/circular"
  p="/home/lightning/.lightning/plugins/_available/${n}"
  { [ -x "${p}" ] && ! ldd -r "${p}" 2>&1 | grep -qF "undefined symbol: "; } || {
    echo "INFO: Installing plugin \"${n}\"..." && \
      { which go > /dev/null 2>&1 || \
          apt-get install -y --no-install-recommends \
              autoconf automake build-essential gettext libarchive-tools libc-dev libev-dev libevent-dev libffi-dev \
              libgmp-dev libpq-dev libsqlite3-dev libssl-dev libtool pkg-config protobuf-compiler zlib1g zlib1g-dev; } && \
      ( rm -rf /usr/local/go && wget -qO- "${__GO_URL}" | bsdtar -C /usr/local -xzf - ) && \
      export PATH="$PATH:/usr/local/go/bin" && \
      ( cd "${s}" && go build -o "${p}" "cmd/circular"/*.go ) && \
      chown lightning:lightning "${p}" && chmod 0755 "${p}" && \
      echo "INFO: Installation of plugin \"${n}\" finished." || { echo "ERROR: Installation of \"${n}\" failed."; exit 1; }
  }
fi
