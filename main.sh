#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo; fail "Fehler in Zeile ${LINENO}: ${BASH_COMMAND}"' ERR

# -----------------------------
# Farben und Darstellung
# -----------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BLUE=$'\033[1;34m'
  C_CYAN=$'\033[1;36m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
  C_WHITE=$'\033[1;37m'
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

ask_default() {
  local prompt="$1" default="$2" value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

# -----------------------------
# Root-Prüfung
# -----------------------------
[[ "${EUID}" -eq 0 ]] || fail "Bitte mit sudo oder als root ausführen."
export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# Allgemeine Einstellungen
# -----------------------------
NEXTCLOUD_VERSION="32.0.0"
INSTALL_DIR="/var/www/nextcloud"
DATA_DIR="/var/nextcloud-data"
APACHE_SITE="/etc/apache2/sites-available/nextcloud.conf"

section "Nextcloud-Installation"
printf '%sEine allgemeine Installation wird vorbereitet.%s\n' "$C_CYAN" "$C_RESET"
printf 'Version: %sNextcloud %s%s\n' "$C_WHITE" "$NEXTCLOUD_VERSION" "$C_RESET"

ADMIN_USER="$(ask_default 'Administratorkonto' 'admin')"
[[ "${ADMIN_USER}" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "Der Admin-Benutzer darf nur Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich enthalten."

while true; do
  read -r -s -p "Passwort für ${ADMIN_USER}: " ADMIN_PASSWORD
  echo
  read -r -s -p "Passwort wiederholen: " ADMIN_PASSWORD_CONFIRM
  echo
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    warn "Das Passwort darf nicht leer sein."
  elif [[ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]]; then
    warn "Die Passwörter stimmen nicht überein."
  elif (( ${#ADMIN_PASSWORD} < 12 )); then
    warn "Bitte mindestens 12 Zeichen verwenden."
  else
    break
  fi
done

DB_NAME="$(ask_default 'Datenbankname' 'nextcloud')"
DB_USER="$(ask_default 'Datenbankbenutzer' 'nextcloud')"
[[ "${DB_NAME}" =~ ^[a-zA-Z0-9_]+$ ]] || fail "Der Datenbankname enthält ungültige Zeichen."
[[ "${DB_USER}" =~ ^[a-zA-Z0-9_]+$ ]] || fail "Der Datenbankbenutzer enthält ungültige Zeichen."

DATA_DIR="$(ask_default 'Datenverzeichnis' "${DATA_DIR}")"
SITE_NAME="$(ask_default 'Anzeigename der Nextcloud' 'Nextcloud')"
SITE_SLOGAN="$(ask_default 'Slogan, leer lassen zum Überspringen' '')"
BRAND_COLOR="$(ask_default 'Primärfarbe als Hexwert' '#0082C9')"
INSTALL_WEBMIN="$(ask_default 'Webmin installieren? 1=ja, 0=nein' '0')"

NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"
TMP_DIR="$(mktemp -d /tmp/nextcloud-install.XXXXXX)"
ARCHIVE="${TMP_DIR}/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"
DB_PASSWORD=""

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

# -----------------------------
# Vorprüfung
# -----------------------------
section "Vorprüfung"

if [[ -f "${INSTALL_DIR}/config/config.php" ]]; then
  if sudo -u www-data php "${INSTALL_DIR}/occ" status 2>/dev/null | grep -q 'installed: true'; then
    fail "Eine vollständige Nextcloud-Installation existiert bereits. Es wurde nichts verändert."
  fi
  BACKUP_CONFIG="${INSTALL_DIR}/config/config.php.incomplete.$(date +%Y%m%d-%H%M%S)"
  cp -a "${INSTALL_DIR}/config/config.php" "${BACKUP_CONFIG}"
  rm -f "${INSTALL_DIR}/config/config.php"
  ok "Unvollständige Konfiguration gesichert: ${BACKUP_CONFIG}"
fi

# -----------------------------
# Pakete
# -----------------------------
section "Systempakete installieren"
apt-get update
apt-get install -y \
  apache2 mariadb-server redis-server \
  php8.3 libapache2-mod-php8.3 php8.3-cli \
  php8.3-gd php8.3-mysql php8.3-curl php8.3-mbstring \
  php8.3-intl php8.3-gmp php8.3-bcmath php8.3-xml \
  php8.3-imagick php8.3-zip php8.3-apcu php8.3-redis \
  bzip2 ca-certificates openssl tar wget \
  libnet-ssleay-perl libauthen-pam-perl libio-pty-perl unzip

systemctl enable --now apache2 mariadb redis-server
ok "Pakete installiert und Dienste gestartet."

# -----------------------------
# PHP
# -----------------------------
section "PHP konfigurieren"
PHP_INI="/etc/php/8.3/apache2/php.ini"
sed -i -E 's/^memory_limit\s*=.*/memory_limit = 512M/' "${PHP_INI}"
sed -i -E 's/^upload_max_filesize\s*=.*/upload_max_filesize = 10G/' "${PHP_INI}"
sed -i -E 's/^post_max_size\s*=.*/post_max_size = 10G/' "${PHP_INI}"
sed -i -E 's/^max_execution_time\s*=.*/max_execution_time = 3600/' "${PHP_INI}"
sed -i -E 's/^max_input_time\s*=.*/max_input_time = 3600/' "${PHP_INI}"
phpenmod -v 8.3 -s cli,apache2 apcu redis opcache

cat > /etc/php/8.3/apache2/conf.d/99-nextcloud-performance.ini <<'EOF'
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=60
EOF
ok "PHP 8.3, APCu und OPcache konfiguriert."

# -----------------------------
# Apache
# -----------------------------
section "Apache konfigurieren"
a2enmod rewrite headers env dir mime >/dev/null
mkdir -p "${INSTALL_DIR}"

cat > "${APACHE_SITE}" <<EOF
<VirtualHost *:80>
    DocumentRoot ${INSTALL_DIR}

    <Directory ${INSTALL_DIR}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    <IfModule mod_dav.c>
        Dav off
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

a2ensite nextcloud.conf >/dev/null
if [[ -e /etc/apache2/sites-enabled/000-default.conf ]]; then
  a2dissite 000-default.conf >/dev/null || true
fi
ok "Apache-Konfiguration erstellt."

# -----------------------------
# Nextcloud-Dateien
# -----------------------------
section "Nextcloud herunterladen"
if [[ ! -f "${INSTALL_DIR}/occ" ]]; then
  wget --https-only --no-verbose -O "${ARCHIVE}" "${NEXTCLOUD_URL}"
  tar -xjf "${ARCHIVE}" -C "${TMP_DIR}"
  mkdir -p "${INSTALL_DIR}"
  cp -a "${TMP_DIR}/nextcloud/." "${INSTALL_DIR}/"
  ok "Nextcloud ${NEXTCLOUD_VERSION} entpackt."
else
  info "Nextcloud-Dateien sind bereits vorhanden; Download wird übersprungen."
fi

mkdir -p "${DATA_DIR}"
chown -R www-data:www-data "${INSTALL_DIR}" "${DATA_DIR}"
chmod 750 "${DATA_DIR}"

# -----------------------------
# MariaDB
# -----------------------------
section "Datenbank einrichten"
DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME}
  CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

MYSQL_PWD="${DB_PASSWORD}" mariadb -h localhost -u "${DB_USER}" "${DB_NAME}" -e 'SELECT 1;' >/dev/null
ok "Datenbankverbindung erfolgreich getestet."

# -----------------------------
# CLI-Installation
# -----------------------------
section "Nextcloud installieren"
sudo -u www-data php "${INSTALL_DIR}/occ" maintenance:install \
  --database=mysql \
  --database-name="${DB_NAME}" \
  --database-user="${DB_USER}" \
  --database-pass="${DB_PASSWORD}" \
  --admin-user="${ADMIN_USER}" \
  --admin-pass="${ADMIN_PASSWORD}" \
  --data-dir="${DATA_DIR}"
ok "Nextcloud wurde erfolgreich installiert."

# -----------------------------
# Cache, Branding und Cron
# -----------------------------
section "Cache, Branding und Cron konfigurieren"
SERVER_IP="$(hostname -I | awk '{print $1}')"
OCC=(sudo -u www-data php "${INSTALL_DIR}/occ")

"${OCC[@]}" config:system:set trusted_domains 0 --value='localhost'
"${OCC[@]}" config:system:set trusted_domains 1 --value="${SERVER_IP}"

PRIMARY_DOMAIN=""
DOMAIN_INDEX=2
PROXY_MODE=""

add_domain() {
  local domain="$1"
  domain="$(printf '%s' "${domain}" | tr -d '[:space:]')"
  [[ -z "${domain}" ]] && return 0
  if [[ ! "${domain}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    warn "Ungültige Domain/IP übersprungen: ${domain}"
    return 0
  fi
  "${OCC[@]}" config:system:set trusted_domains "${DOMAIN_INDEX}" --value="${domain}"
  ok "Trusted Domain hinzugefügt: ${domain}"
  if [[ -z "${PRIMARY_DOMAIN}" && "${domain}" != "${SERVER_IP}" ]]; then
    PRIMARY_DOMAIN="${domain}"
  fi
  DOMAIN_INDEX=$((DOMAIN_INDEX + 1))
}

read -r -p "Nginx Proxy Manager auf anderem Host verwenden? [j/N]: " PROXY_MODE
if [[ "${PROXY_MODE,,}" == "j" || "${PROXY_MODE,,}" == "ja" ]]; then
  read -r -p "Öffentliche HTTPS-Domain (z.B. cloud.example.de): " PROXY_DOMAIN
  PROXY_DOMAIN="$(printf '%s' "${PROXY_DOMAIN}" | tr -d '[:space:]')"
  [[ "${PROXY_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Ungültige Proxy-Domain."

  read -r -p "IP-Adresse des Nginx Proxy Managers: " PROXY_IP
  PROXY_IP="$(printf '%s' "${PROXY_IP}" | tr -d '[:space:]')"
  [[ "${PROXY_IP}" =~ ^[A-Fa-f0-9:.]+$ ]] || fail "Ungültige Proxy-IP-Adresse."

  PRIMARY_DOMAIN="${PROXY_DOMAIN}"
  "${OCC[@]}" config:system:set trusted_domains "${DOMAIN_INDEX}" --value="${PROXY_DOMAIN}"
  "${OCC[@]}" config:system:set trusted_proxies 0 --value="${PROXY_IP}"
  "${OCC[@]}" config:system:set overwritehost --value="${PROXY_DOMAIN}"
  "${OCC[@]}" config:system:set overwriteprotocol --value='https'
  "${OCC[@]}" config:system:set overwrite.cli.url --value="https://${PROXY_DOMAIN}"
  PUBLIC_ADDRESS="https://${PROXY_DOMAIN}/"
  DOMAIN_INDEX=$((DOMAIN_INDEX + 1))
  ok "Reverse Proxy für ${PROXY_DOMAIN} konfiguriert."
else
  read -r -p "Erste Domain oder zusätzliche IP (optional): " DOMAIN_INPUT
  add_domain "${DOMAIN_INPUT}"

  while true; do
    read -r -p "Weitere Domain/IP hinzufügen? [j/N]: " ADD_MORE
    [[ "${ADD_MORE,,}" == "j" || "${ADD_MORE,,}" == "ja" ]] || break
    read -r -p "Domain oder IP: " DOMAIN_INPUT
    add_domain "${DOMAIN_INPUT}"
  done

  if [[ -n "${PRIMARY_DOMAIN}" ]]; then
    "${OCC[@]}" config:system:set overwrite.cli.url --value="http://${PRIMARY_DOMAIN}"
    PUBLIC_ADDRESS="http://${PRIMARY_DOMAIN}/"
  else
    "${OCC[@]}" config:system:set overwrite.cli.url --value="http://${SERVER_IP}"
    PUBLIC_ADDRESS="http://${SERVER_IP}/"
  fi
fi
"${OCC[@]}" config:system:set memcache.local --value='\OC\Memcache\APCu'
"${OCC[@]}" config:system:set memcache.locking --value='\OC\Memcache\Redis'
"${OCC[@]}" config:system:set redis host --value='127.0.0.1'
"${OCC[@]}" config:system:set redis port --type=integer --value=6379
"${OCC[@]}" app:enable theming >/dev/null 2>&1 || true
"${OCC[@]}" config:app:set theming name --value="${SITE_NAME}"
"${OCC[@]}" config:app:set theming color --value="${BRAND_COLOR}"
if [[ -n "${SITE_SLOGAN}" ]]; then
  "${OCC[@]}" config:app:set theming slogan --value="${SITE_SLOGAN}"
fi
"${OCC[@]}" background:cron

CRON_LINE="*/5 * * * * php -f ${INSTALL_DIR}/cron.php"
( crontab -u www-data -l 2>/dev/null || true ) | grep -Fq "${INSTALL_DIR}/cron.php" || \
  ( crontab -u www-data -l 2>/dev/null || true; echo "${CRON_LINE}" ) | crontab -u www-data -
ok "Redis, APCu, Branding und Cron eingerichtet."

# -----------------------------
# Webmin optional
# -----------------------------
if [[ "${INSTALL_WEBMIN}" == '1' ]]; then
  section "Webmin installieren"
  WEBMIN_VERSION="2.021"
  WEBMIN_DEB="${TMP_DIR}/webmin_${WEBMIN_VERSION}_all.deb"
  WEBMIN_URL="https://sourceforge.net/projects/webadmin/files/webmin/${WEBMIN_VERSION}/webmin_${WEBMIN_VERSION}_all.deb/download"
  wget --https-only --no-verbose -O "${WEBMIN_DEB}" "${WEBMIN_URL}"
  dpkg -i "${WEBMIN_DEB}" || apt-get install -f -y
  ok "Webmin installiert."
else
  info "Webmin wurde übersprungen."
fi

# -----------------------------
# Abschlussprüfung
# -----------------------------
section "Installation prüfen"
apache2ctl configtest
systemctl restart apache2 mariadb redis-server
systemctl is-active --quiet apache2
systemctl is-active --quiet mariadb
systemctl is-active --quiet redis-server
"${OCC[@]}" status

WEBMIN_ADDRESS="http://${SERVER_IP}:10000"

printf '\n%s============================================================%s\n' "$C_GREEN" "$C_RESET"
printf '%s  INSTALLATION ERFOLGREICH ABGESCHLOSSEN%s\n' "$C_GREEN" "$C_RESET"
printf '%s============================================================%s\n' "$C_GREEN" "$C_RESET"
printf 'Nextcloud-Adresse:       %s%s%s\n' "$C_WHITE" "$PUBLIC_ADDRESS" "$C_RESET"
printf 'Nextcloud-Administrator: %s%s%s\n' "$C_WHITE" "$ADMIN_USER" "$C_RESET"
printf 'Nextcloud-Adminpasswort: %s%s%s\n' "$C_WHITE" "$ADMIN_PASSWORD" "$C_RESET"
printf 'Datenbankname:           %s%s%s\n' "$C_WHITE" "$DB_NAME" "$C_RESET"
printf 'Datenbankbenutzer:       %s%s%s\n' "$C_WHITE" "$DB_USER" "$C_RESET"
printf 'Datenbankpasswort:       %s%s%s\n' "$C_WHITE" "$DB_PASSWORD" "$C_RESET"
printf 'Datenverzeichnis:        %s%s%s\n' "$C_WHITE" "$DATA_DIR" "$C_RESET"
if [[ "${INSTALL_WEBMIN}" == '1' ]]; then
  printf 'Webmin-Adresse:          %s%s%s\n' "$C_WHITE" "$WEBMIN_ADDRESS" "$C_RESET"
  printf 'Webmin-Benutzer:         %sroot%s\n' "$C_WHITE" "$C_RESET"
fi
printf 'Darstellung:  %sName, Farbe und optionaler Slogan wurden gesetzt.%s\n' "$C_WHITE" "$C_RESET"
printf '\n%sWichtig:%s Die Zugangsdaten werden nur im Terminal angezeigt.\n' "$C_YELLOW" "$C_RESET"
printf '%sFür den öffentlichen Betrieb HTTPS, Firewall und Backups einrichten.%s\n' "$C_YELLOW" "$C_RESET"

exit 0
