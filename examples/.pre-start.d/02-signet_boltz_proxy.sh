#!/bin/bash
__B=$(basename "${BASH_SOURCE[0]}")
__PIDFILE="/tmp/signet-boltz-proxy.pid"
__LOGFILE="/tmp/signet-boltz-proxy.log"
if [ -z "${TOR_SOCKSD}" ]; then
  printf '%s - INFO: \"TOR_SOCKSD\" environment variable is unset - not starting Boltz proxy.\n' "${__B}"
  exit 0
fi

curl -LSs -m 15 --socks5-hostname "${TOR_SOCKSD}" -s 'https://check.torproject.org/' 2> /dev/null | \
  grep -E 'Your IP address appears to be|Congratulations' | uniq | sed 's/<[^>]*>/\n/g' | \
  xargs | grep -qE 'Your IP address appears to be: [0-9]{1,3}(\.[0-9]{1,3}){3}$' || \
    printf '%s - WARNING: Tor proxy seems not to be working! Starting Boltz proxy anyway...\n' "${__B}"

if [ -s "${__PIDFILE}" ]; then
  __PID=$(cat "${__PIDFILE}")
  if kill -0 "${__PID}" > /dev/null 2>&1; then
    printf '%s - INFO: Boltz proxy is already running...\n' "${__B}"
  else
    printf '%s - WARNING: pid file exists but process does not! Deleting pid file...\n' "${__B}"
    rm -f "${__PIDFILE}"
  fi
fi
if [ ! -f "${__PIDFILE}" ]; then
  TOR_SOCKSD_HOST=$(echo "${TOR_SOCKSD}" | sed -E 's/:[0-9]+$//')
  TOR_SOCKSD_PORT=$(echo "${TOR_SOCKSD}" | grep -Po '(?<=:)[0-9]+(?=$)')
  { socat -d -d -L"${__PIDFILE}" "TCP4-LISTEN:8080,fork" "SOCKS4A:${TOR_SOCKSD_HOST}:boltz7ckqss7j66wjjqlm334qccsrjie552gdnvn6vwztnzk7bqwsdad.onion:80,socksport=${TOR_SOCKSD_PORT}" > "${__LOGFILE}" 2>&1 & } > /dev/null 2>&1
  printf '%s - INFO: Proxy started.\n' "${__B}"
fi
