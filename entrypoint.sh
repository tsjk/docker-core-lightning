#!/usr/bin/env bash

: "${DO_CHOWN:=true}"
: "${EXPOSE_TCP_RPC:=false}"
: "${START_CL_REST:=false}"
: "${START_IN_BACKGROUND:=false}"

networkdatadir="${LIGHTNINGD_DATA}/${LIGHTNINGD_NETWORK}"
if [[ -x "/usr/bin/lightningd" ]]; then
  LIGHTNINGD="/usr/bin/lightningd"
else
  LIGHTNINGD="/usr/local/bin/lightningd"
fi

if [[ $(echo "$1" | cut -c1) == "-" ]]; then
  set -- lightningd "${@}"; fi

if [[ "${1}" == "lightningd" ]]; then
  for a; do [[ "${a}" =~ ^--conf=.*$ ]] && config_file="${a##--conf=}"; done
  [[ -z "${config_file}" || -f "${config_file}" ]] || exit 1
  if [[ -n "${config_file}" ]]; then
    set -- "${LIGHTNINGD}" "${@:2}"
  else
    [[ -f "${LIGHTNINGD_HOME}/.config/lightning/lightningd.conf" ]] && \
      config_file="${LIGHTNINGD_HOME}/.config/lightning/lightningd.conf" || exit 1
    set -- "${LIGHTNINGD}" --conf="${config_file}" "${@:2}"
  fi
fi

if [[ "${1}" == "${LIGHTNINGD}" ]]; then
  if [[ "${PUID}" =~ ^[0-9][0-9]*$ && "${PGID}" =~ ^[0-9][0-9]*$ ]]; then
    { [[ $(getent group lightning | cut -d ':' -f 3) -eq ${PGID} ]] || gruopmod --non-unique --gid ${PGID} lightning; } && \
    { [[ $(getent passwd lightning | cut -d ':' -f 3) -eq ${PUID} ]] || usermod --non-unique --uid ${PUID} lightning; } || exit 1; fi
  [[ "${DO_CHOWN}" != "true" ]] || \
    { [[ -n "${LIGHTNINGD_HOME}" && -d "${LIGHTNINGD_HOME}" ]] && chown -R lightning:lightning "${LIGHTNINGD_HOME}"; } || exit 1

  [[ -z "${NETWORK_RPCD}" ]] || { [[ -e /tmp/socat-network_rpc.lock ]] && [[ -e /tmp/socat-network_rpc.pid ]] && kill -0 `cat /tmp/socat-network_rpc.pid` > /dev/null 2>&1; } || {
      rm -f /tmp/socat-network_rpc.lock /tmp/socat-network_rpc.pid
      su -s /bin/sh lightning -c "exec /usr/bin/socat -L /tmp/socat-network_rpc.lock TCP4-LISTEN:8332,bind=127.0.0.1,reuseaddr,fork TCP4:${NETWORK_RPCD}" &
      echo $! > /tmp/socat-network_rpc.pid; }
  [[ -z "${TOR_SOCKSD}" ]] || { [[ -e /tmp/socat-tor_socks.lock ]] && [[ -e /tmp/socat-tor_socks.pid ]] && kill -0 `cat /tmp/socat-tor_socks.pid` > /dev/null 2>&1; } || {
      rm -f /tmp/socat-tor_socks.lock /tmp/socat-tor_socks.pid
      su -s /bin/sh lightning -c "exec /usr/bin/socat -L /tmp/socat-tor_socks.lock TCP4-LISTEN:9050,bind=127.0.0.1,reuseaddr,fork TCP4:${TOR_SOCKSD}" &
      echo $! > /tmp/socat-tor_socks.pid; }
  [[ -z "${TOR_CTRLD}" ]] || { [[ -e /tmp/socat-tor_ctrl.lock ]] && [[ -e /tmp/socat-tor_ctrl.pid ]] && kill -0 `cat /tmp/socat-tor_ctrl.pid` > /dev/null 2>&1; } || {
      rm -f /tmp/socat-tor_ctrl.lock /tmp/socat-tor_ctrl.pid
      su -s /bin/sh lightning -c "exec /usr/bin/socat -L /tmp/socat-tor_ctrl.lock  TCP4-LISTEN:9051,bind=127.0.0.1,reuseaddr,fork TCP4:${TOR_CTRLD}" &
      echo $! > /tmp/socat-tor_ctrl.pid; }

  [[ ! -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/cl-rest-config.json" || \
     ! -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/access.macaroon" || \
     ! -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/certificate.pem" || \
     ! -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/key.pem" || \
     ! -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/certs/rootKey.key" ]] || START_CL_REST="true"
  [[ "${EXPOSE_TCP_RPC}" != "true" && "${START_CL_REST}" != "true" ]] || START_IN_BACKGROUND="true"

  if [[ "${START_IN_BACKGROUND}" == "true" ]]; then
    set -m

    set -- "${LIGHTNINGD}" --network="${LIGHTNINGD_NETWORK}" "${@}"; su -s /bin/sh lightning -c "${*}" &

    echo "Core-Lightning starting..."
    while read -r i; do if [[ "${i}" == "lightning-rpc" ]]; then break; fi
    done < <(inotifywait -e create,open --format '%f' --quiet "${networkdatadir}" --monitor)
    echo "Core-Lightning started."
    if [[ "${EXPOSE_TCP_RPC}" == "true" ]]; then
      echo "RPC available on IPv4 TCP port ${LIGHTNINGD_RPC_PORT}"
      su -s /bin/sh lightning \
         -c "/usr/bin/socat TCP4-LISTEN:${LIGHTNINGD_RPC_PORT},fork,reuseaddr UNIX-CONNECT:${networkdatadir}/lightning-rpc" &
    fi

    if [[ -s "${LIGHTNINGD_HOME}/.config/c-lightning-REST/cl-rest-config.json" ]]; then
      echo "Starting c-lightning-REST."
      ( cd /usr/local/c-lightning-REST && node cl-rest.js & )
    fi

    fg %-
  else
    shift 1; su-exec lightning "${LIGHTNINGD}" --network="${LIGHTNINGD_NETWORK}" "${@}"
  fi
else
  exec "${@}"
fi
