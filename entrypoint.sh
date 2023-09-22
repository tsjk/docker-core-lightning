#!/usr/bin/env bash

: "${DO_CHOWN:=true}"
: "${EXPOSE_TCP_RPC:=false}"
: "${START_CL_REST:=true}"
: "${START_RTL:=true}"
: "${START_IN_BACKGROUND:=false}"
: "${OFFLINE:=false}"

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
    __error "\"${LIGHTNINGD_CONFIG_FILE}\" is zero-sized! You need to wire in your own Core Lightning configuration."
fi


if [[ "${1}" == "${LIGHTNINGD}" ]]; then
  if [[ "${PUID}" =~ ^[0-9][0-9]*$ && "${PGID}" =~ ^[0-9][0-9]*$ ]]; then
    { [[ $(getent group lightning | cut -d ':' -f 3) -eq ${PGID} ]] || gruopmod --non-unique --gid ${PGID} lightning; } && \
      { [[ $(getent passwd lightning | cut -d ':' -f 3) -eq ${PUID} ]] || usermod --non-unique --uid ${PUID} lightning; } || \
      __error "Failed to change uid or gid or \"lightning\" user."; fi
  [[ "${DO_CHOWN}" != "true" ]] || \
    { [[ -n "${LIGHTNINGD_HOME}" && -d "${LIGHTNINGD_HOME}" ]] && chown -R lightning:lightning "${LIGHTNINGD_HOME}"; } || \
      __error "chown -R lightning:lightning \"${LIGHTNINGD_HOME}\" - returned with error"

  [[ -z "${NETWORK_RPCD}" ]] || { [[ -e /tmp/socat-network_rpc.lock ]] && [[ -e /tmp/socat-network_rpc.pid ]] && kill -0 `cat /tmp/socat-network_rpc.pid` > /dev/null 2>&1; } || {
      rm -f /tmp/socat-network_rpc.lock /tmp/socat-network_rpc.pid
      su -s /bin/sh lightning -c "exec /usr/bin/socat -L /tmp/socat-network_rpc.lock TCP4-LISTEN:8332,bind=127.0.0.1,reuseaddr,fork TCP4:${NETWORK_RPCD}" &
      echo $! > /tmp/socat-network_rpc.pid
      kill -0 $(< /tmp/socat-network_rpc.pid) > /dev/null 2>&1 || __error "Failed to setup socat for crypto daemon's rpc service"; }
  [[ -z "${TOR_SOCKSD}" ]] || { [[ -e /tmp/socat-tor_socks.lock ]] && [[ -e /tmp/socat-tor_socks.pid ]] && kill -0 `cat /tmp/socat-tor_socks.pid` > /dev/null 2>&1; } || {
      rm -f /tmp/socat-tor_socks.lock /tmp/socat-tor_socks.pid
      su -s /bin/sh lightning -c "exec /usr/bin/socat -L /tmp/socat-tor_socks.lock TCP4-LISTEN:9050,bind=127.0.0.1,reuseaddr,fork TCP4:${TOR_SOCKSD}" &
      echo $! > /tmp/socat-tor_socks.pid
      kill -0 $(< /tmp/socat-tor_socks.pid) > /dev/null 2>&1 || __error "Failed to setup socat for Tor SOCKS service"; }
  [[ -z "${TOR_CTRLD}" ]] || { [[ -e /tmp/socat-tor_ctrl.lock ]] && [[ -e /tmp/socat-tor_ctrl.pid ]] && kill -0 `cat /tmp/socat-tor_ctrl.pid` > /dev/null 2>&1; } || {
      rm -f /tmp/socat-tor_ctrl.lock /tmp/socat-tor_ctrl.pid
      su -s /bin/sh lightning -c "exec /usr/bin/socat -L /tmp/socat-tor_ctrl.lock  TCP4-LISTEN:9051,bind=127.0.0.1,reuseaddr,fork TCP4:${TOR_CTRLD}" &
      echo $! > /tmp/socat-tor_ctrl.pid
      kill -0 $(< /tmp/socat-tor_ctrl.pid) > /dev/null 2>&1 || __error "Failed to setup socat for Tor control service"; }

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
      echo "RTL password is \"${RTL_PASSWORD}\"."
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

  [[ "${EXPOSE_TCP_RPC}" != "true" && "${START_CL_REST}" != "true" ]] || START_IN_BACKGROUND="true"

  if [[ "${OFFLINE}" == "true" ]]; then
    __warning "Will start Core Lightning in off-line mode."
    set -- --offline "${@}"
  fi

  if [[ "${START_IN_BACKGROUND}" == "true" ]]; then
    set -m

    set -- "${LIGHTNINGD}" --network="${LIGHTNINGD_NETWORK}" "${@}"; su -s /bin/sh lightning -c "${*}" &
    echo "Core-Lightning starting..."
    while read -r i; do if [[ "${i}" == "lightning-rpc" ]]; then break; fi
    done < <(inotifywait -e create,open --format '%f' --quiet "${NETWORK_DATA_DIRECTORY}" --monitor)
    echo "Core-Lightning started."
    if [[ "${EXPOSE_TCP_RPC}" == "true" ]]; then
      echo "RPC available on IPv4 TCP port ${LIGHTNINGD_RPC_PORT}"
      su -s /bin/sh lightning \
         -c "/usr/bin/socat TCP4-LISTEN:${LIGHTNINGD_RPC_PORT},fork,reuseaddr UNIX-CONNECT:${NETWORK_DATA_DIRECTORY}/lightning-rpc" &
    fi

    if [[ "${START_CL_REST}" == "true" ]]; then
      su -s /bin/sh lightning -c 'cd /usr/local/c-lightning-REST && node cl-rest.js' &
      echo "c-lightning-REST starting..."
      if [[ ! -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/access.macaroon" ]]; then
        while read -r i; do if [[ "${i}" == "access.macaroon" ]]; then break; fi
        done < <(inotifywait -e create,open --format '%f' --quiet "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs" --monitor)
      fi
      echo "c-lightning-REST started."
      if grep -q -E '<RTL-MACAROON-PATH>' "${RTL_CONFIG_FILE}" 2>/dev/null; then
        mkdir "/tmp/RTL-macaroon" && \
          cp -a "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/access.macaroon" "/tmp/RTL-macaroon/" && \
            sed -i 's@<RTL-MACAROON-PATH>@/tmp/RTL-macaroon@' "${RTL_CONFIG_FILE}" || \
           { __warning "Failed to set macaroon for RTL. Will hence not start RTL."; START_RTL="false"; }
      fi
      if [[ "${START_RTL}" == "true" ]]; then
        echo "Starting RTL."
	su -s /bin/sh lightning -c 'cd /usr/local/RTL && node rtl' &
      fi
    fi

    fg %-
  else
    shift 1; su-exec lightning "${LIGHTNINGD}" --network="${LIGHTNINGD_NETWORK}" "${@}"
  fi
else
  exec "${@}"
fi
