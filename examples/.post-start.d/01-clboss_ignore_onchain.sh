#!/bin/sh
assert_that_lightningd_rpc_socket_exists() {
  if [ ! -e "${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" ] || [ ! -S "${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" ]; then
    echo ".post-start.d/01-clboss_ignore_onchain.sh: \"${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc\" is not a socket!"
    exit 0
  fi
}

clboss_loaded() {
  CLBOSS_PATH=$(lightning-cli --rpc-file="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" -k plugin subcommand=list | jq -r '.plugins[] | select(.name == "/usr/local/bin/clboss") | .name')
  [ -n "${CLBOSS_PATH}" ]
}
clboss_internet_connection() {
  lightning-cli --rpc-file="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" clboss-status | jq -r '.internet.connection'
}

assert_that_lightningd_rpc_socket_exists
clboss_loaded || { echo ".post-start.d/01-clboss_ignore_onchain.sh: CLBOSS is not loaded."; exit 0; }

CLBOSS_STATUS=$(clboss_internet_connection)
while [ "${CLBOSS_STATUS}" != "offline" ] && [ "${CLBOSS_STATUS}" != "online" ]; do sleep .25; assert_that_lightningd_rpc_socket_exists; CLBOSS_STATUS=$(clboss_internet_connection); done

( set -x && /usr/local/bin/lightning-cli --rpc-file="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" clboss-ignore-onchain )
