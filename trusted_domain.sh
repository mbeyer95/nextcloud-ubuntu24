#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo; fail "Fehler in Zeile ${LINENO}: ${BASH_COMMAND}"' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "Bitte mit sudo oder als root ausführen." >&2
  exit 1
fi

if [[ ! -f /var/www/nextcloud/occ ]]; then
  echo "Nextcloud wurde unter /var/www/nextcloud nicht gefunden." >&2
  exit 1
fi

if sudo -u www-data php /var/www/nextcloud/occ status 2>/dev/null | grep -q 'installed: true'; then
  :
else
  echo "Nextcloud ist nicht vollständig installiert." >&2
  exit 1
fi

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'
  C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_WHITE=$'\033[1;37m'
else
  C_RESET=''; C_BLUE=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_WHITE=''
fi

info() { printf '%sINFO%s  %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%sOK%s    %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%sWARN%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '%sFEHLER%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
section() {
  printf '\n%s============================================================%s\n' "$C_BLUE" "$C_RESET"
  printf '%s  %s%s\n' "$C_WHITE" "$1" "$C_RESET"
  printf '%s============================================================%s\n' "$C_BLUE" "$C_RESET"
}

OCC=(sudo -u www-data php /var/www/nextcloud/occ)
SERVER_IP="$(hostname -I | awk '{print $1}')"
DOMAIN_INDEX=2
PUBLIC_ADDRESS="http://${SERVER_IP}/"

add_domain() {
  local domain="$1"
  domain="$(printf '%s' "${domain}" | tr -d '[:space:]')"
  [[ -z "${domain}" ]] && return 0
  [[ "${domain}" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "Ungültige Domain oder IP: ${domain}"
  "${OCC[@]}" config:system:set trusted_domains "${DOMAIN_INDEX}" --value="${domain}"
  ok "Trusted Domain hinzugefügt: ${domain}"
  DOMAIN_INDEX=$((DOMAIN_INDEX + 1))
}

section "Trusted Domains konfigurieren"
info "Die vorhandenen Einträge 0 (localhost) und 1 (Server-IP) bleiben erhalten."

read -r -p "Weitere Domain oder IP hinzufügen? [j/N]: " FIRST_DOMAIN
if [[ "${FIRST_DOMAIN,,}" == "j" || "${FIRST_DOMAIN,,}" == "ja" ]]; then
  read -r -p "Domain oder IP: " DOMAIN_INPUT
  add_domain "${DOMAIN_INPUT}"
fi

while true; do
  read -r -p "Noch eine weitere Domain/IP hinzufügen? [j/N]: " ADD_MORE
  [[ "${ADD_MORE,,}" == "j" || "${ADD_MORE,,}" == "ja" ]] || break
  read -r -p "Domain oder IP: " DOMAIN_INPUT
  add_domain "${DOMAIN_INPUT}"
done

section "Reverse Proxy prüfen"
read -r -p "Wird Nextcloud über Nginx Proxy Manager auf einem anderen Host veröffentlicht? [j/N]: " USE_NPM

if [[ "${USE_NPM,,}" == "j" || "${USE_NPM,,}" == "ja" ]]; then
  read -r -p "Öffentliche HTTPS-Domain, z.B. cloud.example.de: " PUBLIC_DOMAIN
  PUBLIC_DOMAIN="$(printf '%s' "${PUBLIC_DOMAIN}" | tr -d '[:space:]')"
  [[ "${PUBLIC_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Ungültige öffentliche Domain."

  read -r -p "IP-Adresse des Nginx Proxy Managers: " PROXY_IP
  PROXY_IP="$(printf '%s' "${PROXY_IP}" | tr -d '[:space:]')"
  [[ "${PROXY_IP}" =~ ^[A-Fa-f0-9:.]+$ ]] || fail "Ungültige Proxy-IP-Adresse."

  "${OCC[@]}" config:system:set trusted_domains "${DOMAIN_INDEX}" --value="${PUBLIC_DOMAIN}"
  "${OCC[@]}" config:system:set trusted_proxies 0 --value="${PROXY_IP}"
  "${OCC[@]}" config:system:set overwritehost --value="${PUBLIC_DOMAIN}"
  "${OCC[@]}" config:system:set overwriteprotocol --value='https'
  "${OCC[@]}" config:system:set overwrite.cli.url --value="https://${PUBLIC_DOMAIN}"
  PUBLIC_ADDRESS="https://${PUBLIC_DOMAIN}/"

  ok "Nginx Proxy Manager für ${PUBLIC_DOMAIN} konfiguriert."
else
  read -r -p "Soll die lokale IP als bevorzugte URL verwendet werden? [J/n]: " USE_IP
  if [[ "${USE_IP,,}" != "n" && "${USE_IP,,}" != "nein" ]]; then
    "${OCC[@]}" config:system:set overwrite.cli.url --value="http://${SERVER_IP}"
    PUBLIC_ADDRESS="http://${SERVER_IP}/"
  fi
fi

section "Konfiguration prüfen"
"${OCC[@]}" config:system:get trusted_domains
"${OCC[@]}" status

cat <<EOF

============================================================
KONFIGURATION ABGESCHLOSSEN
============================================================

Bevorzugte Adresse: ${PUBLIC_ADDRESS}
Server-IP:          ${SERVER_IP}

Falls Nginx Proxy Manager verwendet wird:
  Proxy-Ziel:       http://${SERVER_IP}:80
  Websockets:       aktivieren
  SSL:              Let's Encrypt und Force SSL aktivieren

NPM Advanced Configuration:
  client_max_body_size 10G;
  proxy_read_timeout 3600s;
  proxy_send_timeout 3600s;
  proxy_hide_header Upgrade;

Wichtig: Die Zugangsdaten werden nicht gespeichert und nicht angezeigt.
============================================================
EOF

exit 0
