#!/bin/sh
__PLUGIN_REPO_PATH="/home/lightning/.lightning/.plugins"
__PLUGIN_PATH="/home/lightning/.lightning/plugins"

__install_rust() {
  { [ $(find /var/lib/apt/lists/ -mindepth 1 -maxdepth 1 -name '*_debian_dists_*' | wc -l) -gt 0 ] || { \
      apt-get update; apt-get --no-install-recommends -qq -y dist-upgrade; }; } && \
    apt-get install -y --no-install-recommends \
      autoconf automake build-essential gettext libc-dev libev-dev libevent-dev libffi-dev \
      libgmp-dev libpq-dev libsqlite3-dev libssl-dev libtool pkg-config protobuf-compiler zlib1g zlib1g-dev && \
    curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --default-toolchain=1.82 --component=rustfmt
}

LANG=C.UTF-8
LANGUAGE=C.UTF-8
LC_ALL=C.UTF-8

echo "${PATH}" | grep -q -E '(^|:)/root/\.cargo/bin(:|$)' || PATH="${PATH}:/root/.cargo/bin"

n="watchtower-client"; v="v20240905"
if [ ! -e "${__PLUGIN_PATH}/${n}" ] || [ -L "${__PLUGIN_PATH}/${n}" ]; then
  s="${__PLUGIN_REPO_PATH}/rust-teos/watchtower-plugin"; p="${__PLUGIN_REPO_PATH}/_available/${n}-${v}/${n}"
  { [ -x "${p}" ] && ! ldd -r "${p}" 2>&1 | grep -qF "undefined symbol: "; } || {
    echo "INFO: Installing plugin \"${n}\"..." && \
      { which rustc > /dev/null 2>&1 || __install_rust; } && \
      ( cd "${s}" && rm -rf ../target && cargo build --locked --release && \
          mkdir -p "$(dirname "${p}")" && \
          mv -v ".././target/release/${n}" "${p}" ) && \
        chown -R lightning:lightning "$(dirname "${p}")" && chmod 0755 "${p}" && \
        rm -f "${__PLUGIN_PATH}/${n}" && \
        ( cd "${__PLUGIN_PATH}" && ln -rsv "${p}" && chown -h lightning:lightning "$(basename "${p}")" ) && \
        echo "INFO: Installation of plugin \"${n}\" finished." || { echo "ERROR: Installation of plugin \"${n}\" failed."; exit 1; }
  }
  [ -L "${__PLUGIN_PATH}/${n}" ] || ( cd "${__PLUGIN_PATH}" && ln -rsv "${p}" && chown -h lightning:lightning "$(basename "${p}")" )
fi
