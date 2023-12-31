#!/usr/bin/env bash

: "${DO_CHOWN:=true}"
: "${CLBOSS:=true}"
: "${NETWORK_RPCD_AUTH_SET:=false}"
: "${PORT_FORWARDING:=false}"
: "${START_CL_REST:=true}"
: "${START_RTL:=true}"
: "${START_IN_BACKGROUND:=false}"
: "${EXPOSE_TCP_RPC:=false}"
: "${SU_WHITELIST_ENV:=PYTHONPATH}"
: "${OFFLINE:=false}"

declare -g -i DO_RUN=1
declare -g -i SETUP_SIGNAL_HANDLER=1

__info() {
  if [[ "${1}" == "-q" ]]; then
    shift 1; echo "${*}"
  else
    echo "INFO: ${*}"
  fi
}
__warning() {
  echo "WARNING: ${*}" >&2
}
__error() {
  echo "ERROR: ${*}" >&2; exit 1
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

  if [[ "${CLBOSS}" == "true" ]] && grep -q -E '^#plugin=/usr/local/bin/clboss' "${LIGHTNINGD_CONFIG_FILE}"; then
    sed -i 's@^#plugin=/usr/local/bin/clboss@plugin=/usr/local/bin/clboss@' "${LIGHTNINGD_CONFIG_FILE}" || \
      __error "Failed to enable CLBOSS."
  elif [[ "${CLBOSS}" == "false" ]] && grep -q -E '^plugin=/usr/local/bin/clboss' "${LIGHTNINGD_CONFIG_FILE}"; then
    sed -i 's@^plugin=/usr/local/bin/clboss@#plugin=/usr/local/bin/clboss@' "${LIGHTNINGD_CONFIG_FILE}" || \
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

  while [[ ${DO_RUN} -ne 0 ]]; do
    DO_RUN=0; rm -f "${NETWORK_DATA_DIRECTORY}/lightning-rpc"

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
        __error "Failed to bind-addr in \"${LIGHTNINGD_CONFIG_FILE}\"."
      sed -i -E '/#\s*<VPN-ANNOUNCE-ADDR>/{n;s/^#?announce-addr=.*/announce-addr='"${PORT_FORWARDING__HOST}"':'"${PORT_FORWARDING__PORT}"'/}' "${LIGHTNINGD_CONFIG_FILE}" || \
        __error "Failed to bind-addr in \"${LIGHTNINGD_CONFIG_FILE}\"."
    elif [[ "${PORT_FORWARDING}" != "true" || -z "${PORT_FORWARDING_ADDRESS}" ]]; then
      sed -i -E '/#\s*<VPN-BIND-ADDR>/{n;s/^(bind-addr=.*)/#\1/}' "${LIGHTNINGD_CONFIG_FILE}"
      sed -i -E '/#\s*<VPN-ANNOUNCE-ADDR>/{n;s/^(announce-addr=.*)/#\1/}' "${LIGHTNINGD_CONFIG_FILE}"
    fi

    CL_REST_CONFIG_FILE="${LIGHTNINGD_HOME}/.config/c-lightning-REST/cl-rest-config.json"
    if [[ "${START_CL_REST}" == "true" && -s "${CL_REST_CONFIG_FILE}" ]]; then
      if grep -q -E '<CL_REST_PORT>' "${CL_REST_CONFIG_FILE}"; then
        sed -i 's@<CL_REST_PORT>@'"${C_LIGHTNING_REST_PORT}"'@' "${CL_REST_CONFIG_FILE}" || \
          __error "Failed to update \"${CL_REST_CONFIG_FILE}\"."
      fi
      if grep -q -E '<CL_REST_DOCPORT>' "${CL_REST_CONFIG_FILE}"; then
        sed -i 's@<CL_REST_DOCPORT>@'"${C_LIGHTNING_REST_DOCPORT}"'@' "${CL_REST_CONFIG_FILE}" || \
          __error "Failed to update \"${CL_REST_CONFIG_FILE}\"."
      fi
      if grep -q -E '<CL_REST_LNRPCPATH>' "${CL_REST_CONFIG_FILE}"; then
        sed -i 's@<CL_REST_LNRPCPATH>@'"${NETWORK_DATA_DIRECTORY}"'/lightning-rpc@' "${CL_REST_CONFIG_FILE}" || \
          __error "Failed to update \"${CL_REST_CONFIG_FILE}\"."
      fi
    elif [[ "${START_CL_REST}" == "true" && ! -s "${CL_REST_CONFIG_FILE}" ]]; then
      __warning "c-lightning-REST configuration file does not exist or is empty. Will hence not start c-lightning-REST."
      START_CL_REST="false"
    fi
    [[ "${START_CL_REST}" == "true" ]] || START_RTL="false"

    RTL_CONFIG_FILE="${LIGHTNINGD_HOME}/.config/RTL/RTL-Config.json"
    if [[ "${START_RTL}" == "true" && -s "${RTL_CONFIG_FILE}" ]]; then
      if grep -q -E '<RTL-PASSWORD>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        [[ -n "${RTL_PASSWORD}" ]] || RTL_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        sed -i 's@<RTL-PASSWORD>@'"${RTL_PASSWORD}"'@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\"."
        __info "RTL password is \"${RTL_PASSWORD}\"."
      fi
      if grep -q -E '<RTL_PORT>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        sed -i 's@<RTL_PORT>@'"${RTL_PORT}"'@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\"."
      fi
      if grep -q -E '<RTL-DB-DIRECTORY-PATH>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        sed -i 's@<RTL-DB-DIRECTORY-PATH>@'"${LIGHTNINGD_HOME}"'/.config/RTL@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\"."
      fi
      if grep -q -E '<RTL-LN-SERVER-PORT>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        sed -i 's@<RTL-LN-SERVER-PORT>@'"${C_LIGHTNING_REST_PORT}"'@' "${RTL_CONFIG_FILE}" || \
          __error "Failed to update \"${RTL_CONFIG_FILE}\"."
      fi
    elif [[ "${START_RTL}" == "true" && ! -s "${RTL_CONFIG_FILE}" ]]; then
      START_RTL="false"
    fi

    [[ "${START_IN_BACKGROUND}" == "true" ]] || [[ "${EXPOSE_TCP_RPC}" != "true" && "${START_CL_REST}" != "true" ]] || START_IN_BACKGROUND="true"

    [[ -z "${LIGHTNINGD_NETWORK}" ]] || set -- --network="${LIGHTNINGD_NETWORK}" "${@}"

    if [[ "${OFFLINE}" == "true" ]]; then
      __warning "Will start Core Lightning in off-line mode."
      set -- --offline "${@}"
    fi

    if [[ "${START_IN_BACKGROUND}" == "true" ]]; then
      set -m

      if [[ ${SETUP_SIGNAL_HANDLER} -eq 1 ]]; then
        SETUP_SIGNAL_HANDLER=0

        __sighup_handler() {
          if [[ -z "${LIGHTNINGD_RPC_SOCKET}" ]]; then
            echo "entrypoint.sh: SIGHUP not supported; location of Core Lightning RPC socket is unknown." >&2
          elif ! which lightning-cli > /dev/null 2>&1; then
            echo "entrypoint.sh: SIGHUP not supported; location of Core Lightning CLI is unknown." >&2
          else
            DO_RUN=1; echo "entrypoint.sh: Received SIGHUP, restarting Core Lightning..." >&2
            lightning-cli --rpc-file="${LIGHTNINGD_RPC_SOCKET}" stop
          fi
        }
        trap '__sighup_handler' SIGHUP
      fi

      declare -g -i LIGHTNINGD_PID=0 CL_REST_PID=0 RTL_PID=0
      set -- "${LIGHTNINGD}" "${@}"; su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c "set -x && exec ${*}" - lightning $(: core-lightning) &
      LIGHTNINGD_PID=${!}; __info "Core Lightning starting..."; declare -i T=$(( $(date '+%s') + 120)); declare -g LIGHTNINGD_RPC_SOCKET=""
      while true; do
        t=$(( T - $(date '+s') )); [[ ${t} -lt 10 ]] || t=10
        i=$(inotifywait --event create,open --format '%f' --timeout ${t} --quiet "${NETWORK_DATA_DIRECTORY}")
        kill -0 ${LIGHTNINGD_PID} > /dev/null 2>&1 || __error "Failed to start Core Lightning."
        if [[ "${i}" == "lightning-rpc" ]]; then LIGHTNINGD_RPC_SOCKET="${NETWORK_DATA_DIRECTORY}/lightning-rpc"; break; fi
        [[ $(date '+s') -lt ${T} ]] || { __warning "Failed to get notification for Core Lightning RPC socket!"; break; }
      done
      __info "Core Lightning started."

      if [[ -d "${LIGHTNINGD_DATA}/.post-start.d" && $(find "${LIGHTNINGD_DATA}/.post-start.d" -mindepth 1 -maxdepth 1 -type f -name '*.sh' | wc -l) -gt 0 ]]; then
        for f in "${LIGHTNINGD_DATA}/.post-start.d"/*.sh; do
          __info -q "--- Executing \"${f}\":"
          "${f}" || __warning "\"${f}\" exited with error code ${?}."
          __info -q "--- Finished executing \"${f}\"."
        done
      fi

      if [[ "${EXPOSE_TCP_RPC}" == "true" && -n "${LIGHTNINGD_RPC_SOCKET}" ]]; then
        __info "RPC available on IPv4 TCP port ${LIGHTNINGD_RPC_PORT}"
        su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c "exec /usr/bin/socat TCP4-LISTEN:${LIGHTNINGD_RPC_PORT},fork,reuseaddr UNIX-CONNECT:${NETWORK_DATA_DIRECTORY}/lightning-rpc" - lightning &
      fi

      if [[ "${START_CL_REST}" == "true" ]]; then
        su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c 'cd /usr/local/c-lightning-REST && exec node cl-rest.js' - lightning &
        CL_REST_PID=${!}; __info "c-lightning-REST starting..."
        if [[ ! -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/access.macaroon" ]]; then
          while read -r i; do if [[ "${i}" == "access.macaroon" ]]; then break; fi
          done < <(inotifywait -e create,open --format '%f' --quiet "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs" --monitor)
        fi
        __info "c-lightning-REST started."
        if grep -q -E '<RTL-MACAROON-PATH>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
          # shellcheck disable=SC2015
          mkdir "/tmp/RTL-macaroon" && \
            cp -a "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/access.macaroon" "/tmp/RTL-macaroon/" && \
            sed -i 's@<RTL-MACAROON-PATH>@/tmp/RTL-macaroon@' "${RTL_CONFIG_FILE}" || \
           { __warning "Failed to set macaroon for RTL. Will hence not start RTL."; START_RTL="false"; }
        fi
        if [[ "${START_RTL}" == "true" ]]; then
          __info "Starting RTL."
          su -s /bin/sh -w "${SU_WHITELIST_ENV}" -c 'cd /usr/local/RTL && exec node rtl' - lightning &
          RTL_PID=${!}; kill -0 ${RTL_PID} > /dev/null 2>&1 && __info "RTL started."
        fi
      fi

      __info "Foregrounding Core Lightning."
      fg '%?core-lightning'

      [[ ${RTL_PID} -eq 0 ]] || kill "${RTL_PID}"
      [[ ${CL_REST_PID} -eq 0 ]] || kill "${CL_REST_PID}"
    else
      ( set -x && su-exec lightning "${LIGHTNINGD}" "${@}" )
    fi
  done
else
  exec "${@}"
fi
