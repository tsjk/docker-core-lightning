#!/usr/bin/env bash

set -m

__info() {
  if [[ "${1}" == "-q" ]]; then
    shift 1; echo "${*}"
  else
    echo "gossip-store-watcher.sh[INFO]: ${*}"
  fi
}
__warning() {
  echo "gossip-store-watcher.sh[WARNING]: ${*}" >&2
}
__error() {
  echo "gossip-store-watcher.sh[ERROR]: ${*}" >&2; exit 1
}

__sigterm_handler() {
  __info "Received SIGTERM: Terminating..."
  R=0; [ -z "${SLEEP_PID}" ] || ! kill -0 "${SLEEP_PID}" > /dev/null 2>&1 || kill "${SLEEP_PID}"
  exit 0
}
trap '__sigterm_handler' SIGTERM


__usage() {
  echo "Usage: ${0} [--entrypoint-script-pid <pid>] [--check-interval-in-seconds <seconds>] [--size-limit-in-bytes <bytes>] [--restart-on-limit] [--disable-restart-when-file-exists <file>] <lightningd_data_directory>" >&2
}

CHECK_INTERVAL=$(( 1 * 60 * 60 ))
SIZE_LIMIT=$(( ((3 * 1024) + 512) * 1024 * 1024 ))
SIZE_LIMIT_MIN=$(( 128 * 1024 * 1024 ))
SIZE_LIMIT_MAX=$(( ((4 * 1024) - 64) * 1024 * 1024 ))
RESTART_CLN=0
GOSSIP_STORE=''
M=''
R=2
ENTRYPOINT_PID=''
SLEEP_PID=''

while [ "${1:0:1}" = "-" ]; do
  if [ "${1}" = "--entrypoint-script-pid" ] && [ -n "${2}" ] && echo "${2}" | grep -q -E '^[1-9][0-9]*$'; then
    ENTRYPOINT_PID="${2}"; shift 2
  elif [ "${1}" = "--check-interval-in-seconds" ] && [ -n "${2}" ] && echo "${2}" | grep -q -E '^[1-9][0-9]*$'; then
    CHECK_INTERVAL="${2}"; shift 2
    [ "${CHECK_INTERVAL}" -ge 900 ] || __error "Check interval of ${CHECK_INTERVAL}s is nonsensically low, should be at least 900s."
  elif [ "${1}" = "--size-limit-in-bytes" ] && [ -n "${2}" ] && echo "${2}" | grep -q -E '^[1-9][0-9]*$'; then
    SIZE_LIMIT="${2}"; shift 2
    [ "${SIZE_LIMIT}" -ge "${SIZE_LIMIT_MIN}" ] || __error "Size limit of ${SIZE_LIMIT}B is nonsensically low, should be at least ${SIZE_LIMIT_MIN}B."
    [ "${SIZE_LIMIT}" -le "${SIZE_LIMIT_MAX}" ] || __error "Size limit of ${SIZE_LIMIT}B is too high, should be at most ${SIZE_LIMIT_MAX}B."
  elif [ "${1}" = "--restart-on-limit" ]; then
    if [ -n "${2}" ] && echo "${2}" | grep -q -i -E '^true|false$'; then
      [ "${2,,}" = "false" ] || RESTART_CLN=1; shift 2
    else
      RESTART_CLN=1; shift 1
    fi
  elif [ "${1}" = "--disable-restart-when-file-exists" ] && [ -n "${2}" ]; then
    M="${2}"; shift 2
  else
    __usage; exit 1
  fi
done

[ -n "${1}" ] || { __usage; exit 1; }

GOSSIP_STORE="${1}/gossip_store"; M="${1}/.disable-cln-restart"; shift 1

[ ${#} -eq 0 ] || { __usage; exit 1; }

if [ -z "${ENTRYPOINT_PID}" ]; then
  [ -n "${PPID}" ] || PPID=$(awk '{ print $4 }' "/proc/${$}/stat")
  [ -n "${PPID}" ] || __error "\${PPID} is empty!"
  ENTRYPOINT_PID="${PPID}"
fi
[ -n "${ENTRYPOINT_PID}" ] || __error "\${ENTRYPOINT_PID} is empty!"
[ -d "/proc/${ENTRYPOINT_PID}" ] || __error "No process with pid ${ENTRYPOINT_PID} found!"

[ -z "${GOSSIP_STORE_WATCHER_VALIDATE_ARGS}" ] || exit 0

ENTRYPOINT_CMDLINE=$(tr '\0' ' ' < "/proc/${ENTRYPOINT_PID}/cmdline")
[ ${RESTART_CLN} -eq 0 ] || [ "${ENTRYPOINT_CMDLINE}" = "bash /entrypoint.sh lightningd " ] || \
  { __warning "Entry point script pid does not point to container entry point script - restart on limit disabled."; RESTART_CLN=0; }

if [ ${RESTART_CLN} -ne 0 ]; then
  __info "Entering main loop, checking size of \"${GOSSIP_STORE}\" every ${CHECK_INTERVAL} second(s) and will restart Core Lightning when size exceeds ${SIZE_LIMIT}B."
else
  __info "Entering main loop, checking size of \"${GOSSIP_STORE}\" every ${CHECK_INTERVAL} second(s) and will print warning messages when size exceeds ${SIZE_LIMIT}B."
fi

while [ ${R} -ne 0 ]; do
  [ -s "gossip_store" ] && GOSSIP_STORE_SIZE=$(stat -c '%s' "${GOSSIP_STORE}") || GOSSIP_STORE_SIZE=0
  if [ "${GOSSIP_STORE_SIZE}" -gt "${SIZE_LIMIT}" ]; then
    __warning "\"${GOSSIP_STORE}\" has size ${GOSSIP_STORE_SIZE}B has exceeded the size limit of ${SIZE_LIMIT}B."
    if [ ${RESTART_CLN} -ne 0 ]; then
      if [ ${R} -gt 1 ]; then
        __warning "No additional action is taken after the initial check."; R=1
      elif [ -e "${M}" ]; then
        __warning "\"${M}\" exists - not restarting Core Lightning."
      else
        __info "Sending parent \"entrypoint.sh\" a HUP signal to restart Core Lightning."
        kill -HUP "${PPID}"
      fi
   fi
  fi
  { sleep "${CHECK_INTERVAL}" & } > /dev/null 2>&1; SLEEP_PID="${!}"
  wait "${SLEEP_PID}"; SLEEP_PID=''
done
