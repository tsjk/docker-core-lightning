#!/bin/sh
#
# Needs to be run as user lightning.
# Example of compose entry:
#    healthcheck:
#      test: ["CMD", "su -c /home/lightning/.cln-healthcheck.sh lightning"]
#      interval: 300s
#      start_period: 15s
#
# Note that you need to bind the script into the container as well.
#
[ $(pgrep -u lightning -f "^\/usr\/local\/bin\/lightningd(\ .*)?\$" | wc -l) -eq 1 ] || exit 1
PID=$(pgrep -u lightning -f "^\/usr\/local\/bin\/lightningd(\ .*)?\$"); [ -n "${PID}" ] || exit 1
PROCESS_AGE=$(ps -h -p "${PID}" -o etimes 2> /dev/null | xargs)
if [ "${PROCESS_AGE}" -gt 15 ]; then
  CLN_INFO=$(mktemp); R=1
  lightning-cli --network="${LIGHTNINGD_NETWORK}" getinfo > "${CLN_INFO}"
  if jq -r '.id' < "${CLN_INFO}" | grep -qE '^[0-9a-f]{66}$'; then
    [ "$(jq -r '.warning_bitcoind_sync' < "${CLN_INFO}")" != "null" ] || \
      [ "$(jq -r '.warning_lightningd_sync' < "${CLN_INFO}")" != "null" ] || R=0
  fi
  rm "${CLN_INFO}"
fi
exit "${R}"
