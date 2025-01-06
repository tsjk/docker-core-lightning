#!/bin/sh
clboss_internet_connection() { lightning-cli --rpc-file="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" | jq -r '.internet.connection'; }

CLBOSS_STATUS=$(clboss_internet_connection)
while [ "${CLBOSS_STATUS}" != "offline" -a "${CLBOSS_STATUS}" != "online" ]; do sleep .25; CLBOSS_STATUS=$(clboss_internet_connection); done

( set -x && /usr/local/bin/lightning-cli --rpc-file="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" clboss-ignore-onchain )
