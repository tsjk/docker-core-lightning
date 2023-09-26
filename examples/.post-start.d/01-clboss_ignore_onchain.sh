#!/bin/sh
( set -x &&/usr/local/bin/lightning-cli --rpc-file="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}/lightning-rpc" clboss-ignore-onchain )
