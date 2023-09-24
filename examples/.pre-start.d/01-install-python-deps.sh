#!/bin/sh
export PIP_ROOT_USER_ACTION=ignore
( cd "/home/lightning/.lightning/plugins/.lightningd-plugins" && \
    for p in clearnet currencyrate feeadjuster noise rebalance summary; do
      pip3 install --prefix=/usr -r "${p}/requirements.txt" || {
        echo "ERROR: Failed to install requirements for plugin \"${p}\"!"; exit 1; }
    done
)
