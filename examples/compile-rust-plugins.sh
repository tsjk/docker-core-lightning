#!/bin/sh

LANG=C.UTF-8
LANGUAGE=C.UTF-8
LC_ALL=C.UTF-8

echo "${PATH}" | grep -q -E '(^|:)/root/\.cargo/bin(:|$)' || PATH="${PATH}:/root/.cargo/bin"

n="watchtower-client"
if [ -L "/home/lightning/.lightning/plugins/_enabled/${n}" ]; then
  s="/home/lightning/.lightning/plugins/rust-teos/watchtower-plugin"
  p="/home/lightning/.lightning/plugins/_available/${n}"
  { [ -x "${p}" ] && ! ldd -r "${p}" 2>&1 | grep -qF "undefined symbol: "; } || {
    echo "INFO: Installing plugin \"${n}\"..." && \
      { which rustc > /dev/null 2>&1 || {
        apt-get update && \
          apt-get install -y --no-install-recommends \
            autoconf automake build-essential gettext libc-dev libev-dev libevent-dev libffi-dev \
            libgmp-dev libpq-dev libsqlite3-dev libssl-dev libtool pkg-config protobuf-compiler zlib1g zlib1g-dev && \
          curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
          rustup toolchain install stable --component rustfmt --allow-downgrade; }; } && \
      ( cd "${s}" && rm -rf ../target && cargo build --locked --release && \
          mv -v ".././target/release/${n}" "${p}" ) && \
        chown lightning:lightning "${p}" && chmod 0755 "${p}" && \
        echo "INFO: Installation of plugin \"${n}\" finished." || { echo "ERROR: Installation of plugin \"${n}\" failed."; exit 1; }
  }
fi
