#!/usr/bin/env bash

set -m

: "${DEVELOPER:=false}"
: "${DO_CHOWN:=true}"
: "${CLBOSS:=true}"
: "${NETWORK_RPCD_AUTH_SET:=false}"
: "${PORT_FORWARDING:=false}"
: "${GOSSIP_STORE_WATCHER:=::::}"
: "${START_RTL:=true}"
: "${START_IN_BACKGROUND:=false}"
: "${EXPOSE_TCP_RPC:=false}"
: "${SU_WHITELIST_ENV:=PYTHONPATH}"
: "${OFFLINE:=false}"

declare -g -i DO_RUN=1
declare -g -i SETUP_SIGNAL_HANDLERS=1
declare -g _SIGHUP_HANDLER_LOCK=$(mktemp -d)
declare -g _SIGTERM_HANDLER_LOCK=$(mktemp -d)
declare -g _SIGUSR1_HANDLER_LOCK=$(mktemp -d)
declare -g -a GOSSIP_STORE_WATCHER_O=( '--check-interval-in-seconds' '--size-limit-in-bytes' '--restart-on-limit' '--disable-restart-when-file-exists' )
declare -g -a GOSSIP_STORE_WATCHER_ARGS

__info() {
  if [[ "${1}" == "-q" ]]; then
    shift 1; echo "${*}"
  else
    echo "entrypoint.sh[INFO]: ${*}"
  fi
}
__warning() {
  echo "entrypoint.sh[WARNING]: ${*}" >&2
}
__error() {
  echo "entrypoint.sh[ERROR]: ${*}" >&2; exit 1
}

if [[ -x "/usr/bin/lightningd" ]]; then
  LIGHTNINGD="/usr/bin/lightningd"
else
  LIGHTNINGD="/usr/local/bin/lightningd"
fi
NETWORK_DATA_DIRECTORY="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}"

if [[ $(echo "$1" | cut -c1) == "-" ]]; then
  set -- lightningd "${@}"; fi

if [[ "${1}" == "lightningd" ]]; then
  for a; do [[ "${a}" =~ ^--conf=.*$ ]] && LIGHTNINGD_CONFIG_FILE="${a##--conf=}"; done
  if [[ -n "${LIGHTNINGD_CONFIG_FILE}" ]]; then
    set -- "${LIGHTNINGD}" "${@:2}"
  else
    LIGHTNINGD_CONFIG_FILE="${LIGHTNINGD_HOME}/.config/lightning/lightningd.conf"
    set -- "${LIGHTNINGD}" --conf="${LIGHTNINGD_CONFIG_FILE}" "${@:2}"
  fi
  [[ -s "${LIGHTNINGD_CONFIG_FILE}" ]] || \
    __error "Refusing to start; \"${LIGHTNINGD_CONFIG_FILE}\" is zero-sized."

  [[ "${NETWORK_RPCD_AUTH_SET}" != "false" ]] || \
    __error "Refusing to start; NETWORK_RPCD_AUTH_SET is set to \"false\"."

  if [[ "${NETWORK_RPCD_AUTH_SET}" == "true" ]]; then
    sed -i 's@^bitcoin-rpcuser=.*@bitcoin-rpcuser='"${NETWORK_RPCD_USER}"'@' "${LIGHTNINGD_CONFIG_FILE}" || \
      __error "Failed to update bitcoin-rpcuser in \"${LIGHTNINGD_CONFIG_FILE}\"."
    sed -i 's@^bitcoin-rpcpassword=.*@bitcoin-rpcpassword='"${NETWORK_RPCD_PASSWORD}"'@' "${LIGHTNINGD_CONFIG_FILE}" || \
      __error "Failed to update bitcoin-rpcpassword in \"${LIGHTNINGD_CONFIG_FILE}\"."
  fi
fi


if [[ "${1}" == "${LIGHTNINGD}" ]]; then
  shift 1

  if [[ "${PUID}" =~ ^[0-9][0-9]*$ && "${PGID}" =~ ^[0-9][0-9]*$ ]]; then
    # shellcheck disable=SC2015,SC2086
    { [[ $(getent group lightning | cut -d ':' -f 3) -eq ${PGID} ]] || groupmod --non-unique --gid ${PGID} lightning; } && \
      { [[ $(getent passwd lightning | cut -d ':' -f 3) -eq ${PUID} ]] || usermod --non-unique --uid ${PUID} lightning; } || \
      __error "Failed to change uid or gid or \"lightning\" user."; fi
  [[ "${DO_CHOWN}" != "true" ]] || { \
    # shellcheck disable=SC2015
    [[ -n "${LIGHTNINGD_HOME}" && -d "${LIGHTNINGD_HOME}" ]] && chown -R lightning:lightning "${LIGHTNINGD_HOME}" || \
      __error "Failed to do chown on \"${LIGHTNINGD_HOME}\"."; }

  if [[ -d "${LIGHTNINGD_DATA}/.env.d" && $(find "${LIGHTNINGD_DATA}/.env.d" -mindepth 1 -maxdepth 1 -type f | wc -l) -gt 0 ]]; then
    find "${LIGHTNINGD_DATA}/.env.d" -mindepth 1 -maxdepth 1 -type f | sort | while read -r; do
      if [[ -s "${REPLY}" ]]; then
        __info -q "--- Sourcing \"${REPLY}\":"
        # shellcheck disable=SC1090
        . "${REPLY}" || __error "Failed to source file \"${REPLY}\""
        __info -q "--- Finished sourcing \"${REPLY}\"."
      else
        __error "Found zero-sized file \"${f}\"!"
      fi
    done
  fi

  ! grep -q -F '<backspace>' <<< "${GOSSIP_STORE_WATCHER}" || __error "Invalid setting of GOSSIP_STORE_WATCHER (contains \"<backspace>\"): \"${GOSSIP_STORE_WATCHER}\"."
  readarray -t GOSSIP_STORE_WATCHER_SETTINGS <(echo -n "${GOSSIP_STORE_WATCHER}:" | sed -E 's/\\\\/<backspace>/g' | perl -0nE 'say for split /(?<!\\):/' | perl -0pe 's/(?<!\\)\\:/:/g; s/<backspace>/\\/')
  if [[ ${#GOSSIP_STORE_WATCHER_SETTINGS[@]} -eq 0 ]]; then
    GOSSIP_STORE_WATCHER_ARGS=("${NETWORK_DATA_DIRECTORY}")
  elif [[ ${#GOSSIP_STORE_WATCHER_SETTINGS[@]} -le 5 ]]; then
    declare -i a_i=0
    for a in "${GOSSIP_STORE_WATCHER_SETTINGS[@]}"; do
      if [[ ${a_i} -eq 0 ]]; then
        if [[ -n "${a}" && "${a}" == "0" ]]; then
          GOSSIP_STORE_WATCHER_ARGS=(); break
        else
          GOSSIP_STORE_WATCHER_ARGS=("--entrypoint-script-pid" "${$}")
          GOSSIP_STORE_WATCHER_ARGS+=("${GOSSIP_STORE_WATCHER_O[${a_i}]}" "${a}")
        fi
      elif [[ ${a_i} -gt 0 && -n "${a}" ]]; then
        [[ ${a_i} -eq 4 ]] || GOSSIP_STORE_WATCHER_ARGS+=("${GOSSIP_STORE_WATCHER_O[${a_i}]}")
        GOSSIP_STORE_WATCHER_ARGS+=("${a}")
      elif [[ ${a_i} -eq 4 && -z "${a}" ]]; then
        GOSSIP_STORE_WATCHER_ARGS+=("${NETWORK_DATA_DIRECTORY}")
      fi
      a_i+=1
    done
  else
    __error "Invalid setting of GOSSIP_STORE_WATCHER: \"${GOSSIP_STORE_WATCHER}\"."
  fi
  [[ ${#GOSSIP_STORE_WATCHER_ARGS[@]} -eq 0 ]] || \
    GOSSIP_STORE_WATCHER_VALIDATE_ARGS=1 /usr/local/bin/gossip-store-watcher.sh "${GOSSIP_STORE_WATCHER_ARGS[@]}" || \
    __error "Validation of arguments for gossip store watcher failed [${GOSSIP_STORE_WATCHER_ARGS[*]}]."

  if [[ -d "${LIGHTNINGD_DATA}/.pre-start.d" && $(find "${LIGHTNINGD_DATA}/.pre-start.d" -mindepth 1 -maxdepth 1 -type f -name '*.sh' | wc -l) -gt 0 ]]; then
    for f in "${LIGHTNINGD_DATA}/.pre-start.d"/*.sh; do
      if [[ -x "${f}" ]]; then
        __info -q "--- Executing \"${f}\":"
        "${f}" || __error "\"${f}\" exited with error code ${?}."
        __info -q "--- Finished executing \"${f}\"."
      else
        __error "Found non-executable file \"${f}\"! Either make it executable, or remove it."
      fi
    done
  fi

  if [[ -d "${LIGHTNINGD_DATA}/.post-start.d" && $(find "${LIGHTNINGD_DATA}/.post-start.d" -mindepth 1 -maxdepth 1 -type f -name '*.sh' | wc -l) -gt 0 ]]; then
    START_IN_BACKGROUND="true"
    for f in "${LIGHTNINGD_DATA}/.post-start.d"/*.sh; do
      if [[ ! -x "${f}" ]]; then
        __error "Found non-executable file \"${f}\"! Either make it executable, or remove it."
      fi
    done
  fi

  if [[ "${PORT_FORWARDING}" == "true" && -n "${PORT_FORWARDING_ADDRESS}" ]]; then
    if [[ "${PORT_FORWARDING_ADDRESS}" == "PROTONWIRE" ]]; then
      get_forwarding_address() { curl -s 'http://protonwire:1009' | awk -F ':' '($1 == "TCP") { printf("%s:%s", $2, $3); }'; }
    elif [[ "${PORT_FORWARDING_ADDRESS:0:2}" == "()" ]]; then
      eval "get_forwarding_address${PORT_FORWARDING_ADDRESS}"
    elif ! echo "${PORT_FORWARDING_ADDRESS}" | grep -q -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}:[1-9][0-9]*$'; then
      __error "PORT_FORWARDING_ADDRESS is set to an unsupported value."
    fi
    if type get_forwarding_address 2> /dev/null | head -n 1 | grep -q -E '^get_forwarding_address is a function$'; then
      PORT_FORWARDING_ADDRESS=$(get_forwarding_address | tr -d '\r')
      echo "${PORT_FORWARDING_ADDRESS}" | grep -q -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}:[1-9][0-9]*$' || \
        __error "Function for getting port forwarding address does not work."
    fi
  fi

  if [[ "${CLBOSS}" == "true" ]] && grep -q -E '^#plugin=/usr/local/bin/clboss$' "${LIGHTNINGD_CONFIG_FILE}"; then
    sed -i -e 's@^#plugin=/usr/local/bin/clboss$@plugin=/usr/local/bin/clboss@' \
           -Ee 's@^\s*#(clboss-.+=.+)$@\1@' "${LIGHTNINGD_CONFIG_FILE}" || \
      __error "Failed to enable CLBOSS."
  elif [[ "${CLBOSS}" != "true" ]] && grep -q -E '^plugin=/usr/local/bin/clboss$' "${LIGHTNINGD_CONFIG_FILE}"; then
    sed -i -e 's@^plugin=/usr/local/bin/clboss$@#plugin=/usr/local/bin/clboss@' \
           -Ee 's@^(\s*)clboss-+=.+)@\#\1@' "${LIGHTNINGD_CONFIG_FILE}" || \
      __error "Failed to disable CLBOSS."
  fi

  if [[ -n "${TOR_SERVICE_PASSWORD}" ]]; then
    sed -i 's@^(#)?tor-service-password=.*@tor-service-password='"${TOR_SERVICE_PASSWORD}"'@' "${LIGHTNINGD_CONFIG_FILE}" || \
      __error "Failed to update tor-service-password in \"${LIGHTNINGD_CONFIG_FILE}\"."
  fi

  # shellcheck disable=SC2046
  [[ -z "${NETWORK_RPCD}" ]] || { [[ -e /tmp/socat-network_rpc.lock ]] && [[ -e /tmp/socat-network_rpc.pid ]] && kill -0 $(cat /tmp/socat-network_rpc.pid) > /dev/null 2>&1; } || {
      rm -f /tmp/socat-network_rpc.lock /tmp/socat-network_rpc.pid
      su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c "exec /usr/bin/socat -L /tmp/socat-network_rpc.lock TCP4-LISTEN:8332,bind=127.0.0.1,reuseaddr,fork TCP4:${NETWORK_RPCD}" - lightning &
      echo $! > /tmp/socat-network_rpc.pid
      # shellcheck disable=SC2046
      kill -0 $(< /tmp/socat-network_rpc.pid) > /dev/null 2>&1 || __error "Failed to setup socat for crypto daemon's rpc service"; }
  # shellcheck disable=SC2046
  [[ -z "${TOR_SOCKSD}" ]] || { [[ -e /tmp/socat-tor_socks.lock ]] && [[ -e /tmp/socat-tor_socks.pid ]] && kill -0 $(cat /tmp/socat-tor_socks.pid) > /dev/null 2>&1; } || {
      rm -f /tmp/socat-tor_socks.lock /tmp/socat-tor_socks.pid
      su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c "exec /usr/bin/socat -L /tmp/socat-tor_socks.lock TCP4-LISTEN:9050,bind=127.0.0.1,reuseaddr,fork TCP4:${TOR_SOCKSD}" - lightning &
      echo $! > /tmp/socat-tor_socks.pid
      # shellcheck disable=SC2046
      kill -0 $(< /tmp/socat-tor_socks.pid) > /dev/null 2>&1 || __error "Failed to setup socat for Tor SOCKS service"; }
  # shellcheck disable=SC2046
  [[ -z "${TOR_CTRLD}" ]] || { [[ -e /tmp/socat-tor_ctrl.lock ]] && [[ -e /tmp/socat-tor_ctrl.pid ]] && kill -0 $(cat /tmp/socat-tor_ctrl.pid) > /dev/null 2>&1; } || {
      rm -f /tmp/socat-tor_ctrl.lock /tmp/socat-tor_ctrl.pid
      su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c "exec /usr/bin/socat -L /tmp/socat-tor_ctrl.lock  TCP4-LISTEN:9051,bind=127.0.0.1,reuseaddr,fork TCP4:${TOR_CTRLD}" - lightning &
      echo $! > /tmp/socat-tor_ctrl.pid
      # shellcheck disable=SC2046
      kill -0 $(< /tmp/socat-tor_ctrl.pid) > /dev/null 2>&1 || __error "Failed to setup socat for Tor control service"; }

  declare -g -i LIGHTNINGD_PID=0 LIGHTNINGD_REAL_PID=0 LIGHTNINGD_RPC_SOCAT_PID=0 RTL_PID=0
  declare -g -a LIGHTNINGD_ARGS=("${@}")
  while [[ ${DO_RUN} -ne 0 ]]; do
    __info "This is Core Lightning container v24.02.2-20240827"
    DO_RUN=0; set -- "${LIGHTNINGD_ARGS[@]}"; rm -f "${NETWORK_DATA_DIRECTORY}/lightning-rpc"

    if [[ "${PORT_FORWARDING}" == "true" && -n "${PORT_FORWARDING_ADDRESS}" ]]; then
      if type get_forwarding_address 2> /dev/null | head -n 1 | grep -q -E '^get_forwarding_address is a function$'; then
        PORT_FORWARDING_ADDRESS__OLD="${PORT_FORWARDING_ADDRESS}"
        PORT_FORWARDING_ADDRESS=$(get_forwarding_address | tr -d '\r')
        if ! echo "${PORT_FORWARDING_ADDRESS}" | grep -q -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}:[1-9][0-9]*$'; then
          __warning "Function for getting port forwarding address returned an invalid address - reusing previous valid address \"${PORT_FORWARDING_ADDRESS__OLD}\"."
          PORT_FORWARDING_ADDRESS="${PORT_FORWARDING_ADDRESS__OLD}"
        fi
      fi
      PORT_FORWARDING__HOST="${PORT_FORWARDING_ADDRESS%%:*}"; PORT_FORWARDING__PORT="${PORT_FORWARDING_ADDRESS##*:}"
      __info "Port forwarding host is \"${PORT_FORWARDING__HOST}\""; __info "Port forwarding port is \"${PORT_FORWARDING__PORT}\""
      sed -i -E '/#\s*<VPN-BIND-ADDR>/{n;s/^#?bind-addr=.*/bind-addr=0.0.0.0:'"${PORT_FORWARDING__PORT}"'/}' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to update bind-addr in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E '/#\s*<VPN-ANNOUNCE-ADDR>/{n;s/^#?announce-addr=.*/announce-addr='"${PORT_FORWARDING__HOST}"':'"${PORT_FORWARDING__PORT}"'/}' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to update announce-addr in \"${LIGHTNINGD_CONFIG_FILE}\"."
    elif [[ "${PORT_FORWARDING}" != "true" || -z "${PORT_FORWARDING_ADDRESS}" ]]; then
      sed -i -E '/#\s*<VPN-BIND-ADDR>/{n;s/^(bind-addr=.*)/\#\1/}' "${LIGHTNINGD_CONFIG_FILE}"
      sed -i -E '/#\s*<VPN-ANNOUNCE-ADDR>/{n;s/^(announce-addr=.*)/\#\1/}' "${LIGHTNINGD_CONFIG_FILE}"
    fi

    if [[ -n "${CLNREST_PORT}" && "${CLNREST_PORT}" =~ ^[1-9][0-9]*$ && ${CLNREST_PORT} -gt 0 && ${CLNREST_PORT} -lt 65535 ]]; then
      sed -i -E 's/(^\s*#)?clnrest-port=.*/clnrest-port='"${CLNREST_PORT}"'/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to update clnrest-port in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E 's/^\s*#(clnrest-protocol=.*)$/\1/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to update clnrest-protocol in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E 's/^\s*#(clnrest-host=.*)$/\1/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to update clnrest-host in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E 's/^\s*(disable-plugin=clnrest\.py)\s*$/\#\1/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to comment the disabling of the clnrest plugin in \"${LIGHTNINGD_CONFIG_FILE}\"."
      grep -q -E '^\s*clnrest-port=.+' "${LIGHTNINGD_CONFIG_FILE}" && \
        grep -q -E '^\s*clnrest-protocol=.+' "${LIGHTNINGD_CONFIG_FILE}" && \
        grep -q -E '^\s*clnrest-host=.+' "${LIGHTNINGD_CONFIG_FILE}" && \
        ! grep -q -E '^\s*disable-plugin=clnrest\.py' "${LIGHTNINGD_CONFIG_FILE}" ||
        __error "Failed to apply clnrest plugin configuration to \"${LIGHTNINGD_CONFIG_FILE}\"."
    else
      sed -i -E 's/^\s*(clnrest-port=.*)/\#\1/'"${CLNREST_PORT}"'/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to comment clnrest-port in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E 's/^\s*(clnrest-protocol=.*)/\#\1/'"${CLNREST_PORT}"'/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to comment clnrest-protocol in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E 's/^\s*(clnrest-host=.*)/\#\1/'"${CLNREST_PORT}"'/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to comment clnrest-host in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E 's/^\s*#(disable-plugin=clnrest\.py)\s*/\1/' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to uncomment the disabling of the clnrest plugin in \"${LIGHTNINGD_CONFIG_FILE}\"."
      ! grep -q -E '^\s*clnrest-port=.*' "${LIGHTNINGD_CONFIG_FILE}" && \
        ! grep -q -E '^\s*clnrest-protocol=.*' "${LIGHTNINGD_CONFIG_FILE}" && \
        ! grep -q -E '^\s*clnrest-host=.*' "${LIGHTNINGD_CONFIG_FILE}" && \
        grep -q -E '^\s*disable-plugin=clnrest\.py' "${LIGHTNINGD_CONFIG_FILE}" ||
        __error "Failed to apply clnrest plugin configuration to \"${LIGHTNINGD_CONFIG_FILE}\"."
      START_RTL="false"
    fi

    RTL_CONFIG_FILE="${LIGHTNINGD_HOME}/.config/RTL/RTL-Config.json"
    if [[ "${START_RTL}" == "true" && -s "${RTL_CONFIG_FILE}" ]]; then
      if grep -q -E '<RTL-PASSWORD>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        [[ -n "${RTL_PASSWORD}" ]] || RTL_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        sed -i 's@<RTL-PASSWORD>@'"${RTL_PASSWORD}"'@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\" with generated password."
        __info "RTL password is \"${RTL_PASSWORD}\"."
      fi
      if grep -q -E '<RTL_PORT>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        sed -i 's@<RTL_PORT>@'"${RTL_PORT}"'@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\" with listening port."
      fi
      if grep -q -E '<RTL-DB-DIRECTORY-PATH>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        sed -i 's@<RTL-DB-DIRECTORY-PATH>@'"${LIGHTNINGD_HOME}"'/.config/RTL@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\" with database directory path."
      fi
      if grep -q -E '<CLNREST-PORT>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        sed -i 's@<CLNREST-PORT>@'"${CLNREST_PORT}"'@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\" with CLNRest port."
      fi
    elif [[ "${START_RTL}" == "true" && ! -s "${RTL_CONFIG_FILE}" ]]; then
      START_RTL="false"
    fi

    [[ "${START_IN_BACKGROUND}" == "true" ]] || \
      [[ ${#GOSSIP_STORE_WATCHER_ARGS[@]} -eq 0 && "${EXPOSE_TCP_RPC}" != "true" && "${START_CL_REST}" != "true" ]] || START_IN_BACKGROUND="true"

    [[ -z "${LIGHTNINGD_NETWORK}" ]] || grep -q -E '^\s*network='"${LIGHTNINGD_NETWORK}"'\s*(#.*)?$' "${LIGHTNINGD_CONFIG_FILE}" || \
      grep -q -E '(^|\s)--network='"${LIGHTNINGD_NETWORK}"'(\s|$)' <<< "${*}" || set -- "${@}" "--network=${LIGHTNINGD_NETWORK}"
    [[ "${DEVELOPER}" != "true" ]] || grep -q -E '(^|\s)--developer(\s|$)' <<< "${*}" || set -- "${@}" --developer
    [[ "${CLBOSS}" != "true" ]] || ! grep -q -E '^\s*plugin=/usr/local/bin/clboss$' "${LIGHTNINGD_CONFIG_FILE}" || \
      grep -q -E '(^|\s)--allow-deprecated-apis=true(\s|$)' <<< "${*}" || set -- "${@}" --allow-deprecated-apis=true

    if [[ "${OFFLINE}" == "true" ]]; then
      __warning "Will start Core Lightning in off-line mode."
      grep -q -E '(^|\s)--offline(\s|$)' <<< "${*}" || set -- "${@}" --offline
    fi

    if [[ "${START_IN_BACKGROUND}" == "true" ]]; then
      if [[ ${SETUP_SIGNAL_HANDLERS} -eq 1 ]]; then
        SETUP_SIGNAL_HANDLERS=0

        __sigterm_handler() {
          __info "SIGTERM received"
          if mkdir "${_SIGTERM_HANDLER_LOCK}/lock" > /dev/null 2>&1; then
            if [[ -z "${LIGHTNINGD_RPC_SOCKET}" ]]; then
              __warning "SIGTERM not handled; location of Core Lightning RPC socket is unknown."
            elif ! which lightning-cli > /dev/null 2>&1; then
              __warning "SIGTERM not handled; location of Core Lightning CLI is unknown."
            elif [[ ${LIGHTNINGD_REAL_PID} -lt 1 ]] || ! kill -0 ${LIGHTNINGD_REAL_PID} > /dev/null 2>&1; then
              __warning "SIGTERM not handled; Core Lightning seems not to be running."
            else
              DO_RUN=0; __info "Handling SIGTERM -- stopping Core Lightning."
              lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" stop
            fi
            rmdir "${_SIGTERM_HANDLER_LOCK}/lock"
          else
            __warning "An instance of SIGTERM handler is already running."
          fi
        }
        trap '__sigterm_handler' SIGTERM

        __sighup_handler() {
          __info "SIGHUP received"
          if mkdir "${_SIGHUP_HANDLER_LOCK}/lock" > /dev/null 2>&1; then
            if [[ -z "${LIGHTNINGD_RPC_SOCKET}" ]]; then
              __warning "SIGHUP not handled; location of Core Lightning RPC socket is unknown."
            elif ! which lightning-cli > /dev/null 2>&1; then
              __warning "SIGHUP not handled; location of Core Lightning CLI is unknown."
            elif [[ ${LIGHTNINGD_REAL_PID} -lt 1 ]] || ! kill -0 ${LIGHTNINGD_REAL_PID} > /dev/null 2>&1; then
              __warning "SIGHUP not handled; Core Lightning seems not to be running."
            else
              DO_RUN=1; __info "Handling SIGHUP -- restarting Core Lightning..."
              lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" stop
            fi
            rmdir "${_SIGHUP_HANDLER_LOCK}/lock"
          else
            __warning "An instance of SIGHUP handler is already running."
          fi
        }
        trap '__sighup_handler' SIGHUP
      fi

      [[ ${#GOSSIP_STORE_WATCHER_ARGS[@]} -eq 0 ]] || /usr/local/bin/gossip-store-watcher.sh "${GOSSIP_STORE_WATCHER_ARGS[@]}" &

      set -- "${LIGHTNINGD}" "${@}"
      su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c "set -x && exec ${*}" - lightning $(: core-lightning) &
      LIGHTNINGD_PID=${!}; __info "Core Lightning starting..."; declare -i T=$(( $(date '+%s') + 900)); declare -g LIGHTNINGD_RPC_SOCKET=""
      while true; do
        t=$(( T - $(date '+s') )); [[ ${t} -lt 10 ]] || t=10
        i=$(inotifywait --event create,open --format '%f' --timeout ${t} --quiet "${NETWORK_DATA_DIRECTORY}")
        kill -0 ${LIGHTNINGD_PID} > /dev/null 2>&1 || __error "Failed to start Core Lightning."
        if [[ "${i}" == "lightning-rpc" ]]; then LIGHTNINGD_RPC_SOCKET="${NETWORK_DATA_DIRECTORY}/lightning-rpc"; break; fi
        [[ $(date '+s') -lt ${T} ]] || { __warning "Failed to get notification for Core Lightning RPC socket!"; break; }
        [[ $(( (((T + 1 - $(date '+s')) / 10) + 1) % 6 )) -ne 0 ]] || __info "Waiting for Core Lightning RPC socket, will wait $(( T - $(date '+s') )) seconds more..."
      done
      LIGHTNINGD_REAL_PID=$(pgrep -P ${LIGHTNINGD_PID} | head -n 1)
      __info "Core Lightning started (PID: ${LIGHTNINGD_REAL_PID})"

      if [[ -d "${LIGHTNINGD_DATA}/.post-start.d" && $(find "${LIGHTNINGD_DATA}/.post-start.d" -mindepth 1 -maxdepth 1 -type f -name '*.sh' | wc -l) -gt 0 ]]; then
        for f in "${LIGHTNINGD_DATA}/.post-start.d"/*.sh; do
          __info -q "--- Executing \"${f}\":"
          "${f}" || __warning "\"${f}\" exited with error code ${?}."
          __info -q "--- Finished executing \"${f}\"."
        done
      fi

      if [[ "${EXPOSE_TCP_RPC}" == "true" && -n "${LIGHTNINGD_RPC_SOCKET}" ]]; then
        __info "RPC available on IPv4 TCP port ${LIGHTNINGD_RPC_PORT}"
        su -s /bin/sh -w "${SU_WHITELIST_ENV}" \
           -c "exec /usr/bin/socat TCP4-LISTEN:${LIGHTNINGD_RPC_PORT},fork,reuseaddr UNIX-CONNECT:${NETWORK_DATA_DIRECTORY}/lightning-rpc" - lightning $(: cln-rpc-socat) &
        LIGHTNINGD_RPC_SOCAT_PID=${!}
      fi

      if [[ "${START_RTL}" == "true" ]]; then
        __wait_for_rpc_liveness() {
          [[ -n "${LIGHTNINGD_RPC_SOCKET}" ]] || { __warning "Failed to communicate through the Core Lightning RPC socket (LIGHTNINGD_RPC_SOCKET is unset!)"; return 1; }
          local -i T=$(( $(date '+%s') + 120)) t=0; local NODE_ID=''
          while [[ -z "${NODE_ID}" ]]; do
            t=$(( T - $(date '+s') )); [[ ${t} -lt 10 ]] || t=10
            NODE_ID=$(lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" getinfo | jq -r '.id')
            echo "${NODE_ID}" | grep -q -E '^[0-9a-f]{66}$' || NODE_ID=''
            [[ $(date '+s') -lt ${T} ]] || { __warning "Failed to communicate through the Core Lightning RPC socket!"; break; }
            sleep ${t}
          done
          [[ -n "${NODE_ID}" ]]
        }
        if grep -q -E '<RTL-RUNE-PATH>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
          if __wait_for_rpc_liveness; then
            if [[ -z "${RTL_RUNE}" ]]; then
              declare -i RUNE_COUNT=$(lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" showrunes | jq -r '.runes | length')
              if [[ ${RUNE_COUNT} -eq 0 ]]; then
                lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" createrune > /dev/null 2>&1
                if [[ $(lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" showrunes | jq -r '.runes | length') -eq 1 ]]; then
                  RTL_RUNE=$(lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" showrunes | jq -r '.runes[0].rune')
                fi
              elif [[ ${RUNE_COUNT} -eq 1 ]]; then
                  RTL_RUNE=$(lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" showrunes | jq -r '.runes[0].rune')
              else
                __warning "More than one rune exists, and it has not been specified which to use for RTL."
              fi
            elif [[ "${RTL_RUNE}" =~ ^[0-9][0-9]*$ ]]; then
              RTL_RUNE=$(lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" showrunes | jq -r --arg rune_id "${RTL_RUNE}" '.runes[] | select(.unique_id == $rune_id) | .rune')
            else
              [[ "$(lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" -k showrunes "rune=${RTL_RUNE}") | jq -r '.runes[].rune' | head -n 1)" == "${RTL_RUNE}" ]] || RTL_RUNE='null'
            fi
          else
            [[ -z "${RTL_RUNE}" || ! "${RTL_RUNE}" =~ ^[0-9][0-9]*$ ]] || RTL_RUNE='null'
          fi
          # shellcheck disable=SC2015
          [[ -n "${RTL_RUNE}" && "${RTL_RUNE}" != "null" ]] && \
            touch "/tmp/RTL-rune" && \
            echo "LIGHTNING_RUNE=\"${RTL_RUNE}\"" > "/tmp/RTL-rune" && \
            sed -i 's@<RTL-RUNE-PATH>@/tmp/RTL-rune@' "${RTL_CONFIG_FILE}" || \
           { __warning "Failed to set rune for RTL. Will hence not start RTL."; START_RTL="false"; }
        fi
        if [[ "${START_RTL}" == "true" ]]; then
          __info "Starting RTL."
          su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c 'cd /usr/local/RTL && exec node rtl' - lightning &
          RTL_PID=${!}; while kill -0 ${RTL_PID} > /dev/null 2>&1 && [[ -z "$(pgrep -P ${RTL_PID})" ]]; do sleep 1; done
          [[ -n "$(pgrep -P ${RTL_PID})" ]] && __info "RTL started (PID: $(pgrep -P ${RTL_PID} | head -n 1))."
          if ! type __sigusr1_handler > /dev/null 2>&1; then
            __sigusr1_handler() {
              __info "SIGUSR1 received"
              if mkdir "${_SIGUSR1_HANDLER_LOCK}/lock" > /dev/null 2>&1; then
                if [[ "${START_RTL}" == "true" ]]; then
                  __info "Handling SIGUSR1 -- restarting RTL..." >&2
                  if [[ ${RTL_PID} -gt 0 ]] && kill -0 ${RTL_PID} > /dev/null 2>&1 && [[ -n "$(pgrep -P ${RTL_PID})" ]]; then
                    local __rtl_pid=$(pgrep -P ${RTL_PID} | head -n 1)
                    __info "Handling SIGUSR1 -- sending interrupt signal to existing RTL instance (PID: ${__rtl_pid})..."; kill -INT ${__rtl_pid}
                    local T=$(( $(date '+%s') + 60)) t=0
                    while kill -0 ${RTL_PID} > /dev/null 2>&1; do
                      t=$(( T - $(date '+s') )); [[ ${t} -lt 2 ]] || t=2
                      [[ $(date '+s') -lt ${T} ]] || { __warning "Failed to stop running RTL instance!"; return; }
                      sleep 2
                    done
                    __info "Handling SIGUSR1 -- existing RTL instance stopped."
                  else
                    __warning "Handling SIGUSR1 -- no existing RTL instance found."
                  fi
                  RTL_PID=0; su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c 'cd /usr/local/RTL && exec node rtl' - lightning &
                  RTL_PID=${!}; while kill -0 ${RTL_PID} > /dev/null 2>&1 && [[ -z "$(pgrep -P ${RTL_PID})" ]]; do sleep 1; done
                  [[ -n "$(pgrep -P ${RTL_PID})" ]] && __info "Handling SIGUSR1 -- RTL started (PID: $(pgrep -P ${RTL_PID} | head -n 1))." >&2
                else
                  __warning "Handling SIGUSR1 -- RTL is disabled."
                fi
                rmdir "${_SIGUSR1_HANDLER_LOCK}/lock"
              else
                __warning "An instance of SIGUSR1 handler is already running."
              fi
            }
            trap '__sigusr1_handler' SIGUSR1
          fi
        fi
      fi

      __info "Entering normal run mode (PIDs: ${LIGHTNINGD_PID} <- ${LIGHTNINGD_REAL_PID})."
      while kill -0 ${LIGHTNINGD_PID} > /dev/null 2>&1; do wait ${LIGHTNINGD_PID}; done
      __info "Exited normal run mode."
      if kill -0 ${LIGHTNINGD_REAL_PID} > /dev/null 2>&1; then
        __warning "Core Lightning Daemon is still running after normal run mode exited!"
         [[ -z "${LIGHTNINGD_RPC_SOCKET}" ]] || ! which lightning-cli > /dev/null 2>&1 || lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" stop
      fi
      ! kill -0 ${LIGHTNINGD_REAL_PID} > /dev/null 2>&1 && { LIGHTNINGD_REAL_PID=0; __info "Core Lightning exited."; }

      [[ ${RTL_PID} -eq 0 || -z "$(pgrep -P ${RTL_PID})" ]] || {
        __info "Sending RTL an interrupt signal."; kill -INT $(pgrep -P ${RTL_PID} | head -n 1); RTL_PID=0
      }
      [[ ${LIGHTNINGD_RPC_SOCAT_PID} -eq 0 || -z "$(pgrep -P ${LIGHTNINGD_RPC_SOCAT_PID})" ]] || {
        __info "Sending Core Lightning Daemon socat RPC proxy a terminate signal."
        kill $(pgrep -P ${LIGHTNINGD_RPC_SOCAT_PID} | head -n 1); LIGHTNINGD_RPC_SOCAT_PID=0
      }
      if [[ ${DO_RUN} -ne 0 ]]; then
        sleep 5
        __info "Core Lightning restart initiated."
      else
        rm -rf "${_SIGHUP_HANDLER_LOCK}" "${_SIGTERM_HANDLER_LOCK}" "${_SIGUSR1_HANDLER_LOCK}"
        __info "Core Lightning container exiting."
      fi
    else
      ( set -x && su-exec lightning "${LIGHTNINGD}" "${@}" )
    fi
  done
else
  exec "${@}"
fi
