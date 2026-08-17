#!/usr/bin/env bash
# Nextcloud 32 auf Ubuntu 24.04 LTS mit Apache, MariaDB und PHP 8.3
# Ausführen mit: sudo bash nextcloud-install-ubuntu24.sh

set -Eeuo pipefail
trap 'echo; echo "FEHLER in Zeile ${LINENO}: ${BASH_COMMAND}" >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "Dieses Skript muss mit sudo oder als root ausgeführt werden." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# Konfiguration
# -----------------------------
NEXTCLOUD_VERSION="32.0.0"
NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"
INSTALL_DIR="/var/www/nextcloud"
DATA_DIR="/var/nextcloud-data"
APACHE_SITE="/etc/apache2/sites-available/nextcloud.conf"
DB_NAME="Nextcloud_DB"
DB_USER="Nextcloud_User"
WEBMIN_VERSION="2.021"
WEBMIN_URL="https://sourceforge.net/projects/webadmin/files/webmin/${WEBMIN_VERSION}/webmin_${WEBMIN_VERSION}_all.deb/download"

TMP_DIR="$(mktemp -d /tmp/nextcloud-install.XXXXXX)"
ARCHIVE="${TMP_DIR}/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"
DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

step() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

# -----------------------------
# Vorprüfungen
# -----------------------------
step "Vorprüfungen"

if [[ -f "${INSTALL_DIR}/config/config.php" ]]; then
  echo "Es existiert bereits eine konfigurierte Installation: ${INSTALL_DIR}/config/config.php" >&2
  echo "Aus Sicherheitsgründen wird abgebrochen." >&2
  exit 1
fi

if [[ -d "${INSTALL_DIR}" ]] && [[ -n "$(find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "${INSTALL_DIR} ist nicht leer. Bitte sichern und bereinigen oder abbrechen." >&2
  exit 1
fi

# -----------------------------
# Pakete
# -----------------------------
step "Pakete installieren"
apt-get update
apt-get install -y \
  apache2 mariadb-server \
  php8.3 libapache2-mod-php8.3 php8.3-cli \
  php8.3-gd php8.3-mysql php8.3-curl php8.3-mbstring \
  php8.3-intl php8.3-gmp php8.3-bcmath php8.3-xml \
  php8.3-imagick php8.3-zip php8.3-apcu php8.3-redis \
  bzip2 ca-certificates openssl tar wget

systemctl enable --now apache2 mariadb

# -----------------------------
# PHP
# -----------------------------
step "PHP konfigurieren"
PHP_INI="/etc/php/8.3/apache2/php.ini"
sed -i -E 's/^memory_limit\s*=.*/memory_limit = 512M/' "${PHP_INI}"
sed -i -E 's/^upload_max_filesize\s*=.*/upload_max_filesize = 10G/' "${PHP_INI}"
sed -i -E 's/^post_max_size\s*=.*/post_max_size = 10G/' "${PHP_INI}"
sed -i -E 's/^max_execution_time\s*=.*/max_execution_time = 3600/' "${PHP_INI}"
sed -i -E 's/^max_input_time\s*=.*/max_input_time = 3600/' "${PHP_INI}"

# -----------------------------
# Apache
# -----------------------------
step "Apache konfigurieren"
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
apache2ctl configtest

# -----------------------------
# MariaDB
# -----------------------------
step "MariaDB-Datenbank und Benutzer anlegen"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME}
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
  IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER '${DB_USER}'@'localhost'
  IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON ${DB_NAME}.*
  TO '${DB_USER}'@'localhost';

FLUSH PRIVILEGES;
SQL

MYSQL_PWD="${DB_PASSWORD}" mariadb \
  --host=localhost \
  --user="${DB_USER}" \
  "${DB_NAME}" \
  -e 'SELECT 1;' >/dev/null

# -----------------------------
# Nextcloud
# -----------------------------
step "Nextcloud ${NEXTCLOUD_VERSION} herunterladen und installieren"
wget --https-only --no-verbose -O "${ARCHIVE}" "${NEXTCLOUD_URL}"
tar -xjf "${ARCHIVE}" -C "${TMP_DIR}"
cp -a "${TMP_DIR}/nextcloud/." "${INSTALL_DIR}/"

mkdir -p "${DATA_DIR}"
chown -R www-data:www-data "${INSTALL_DIR}" "${DATA_DIR}"
chmod 750 "${DATA_DIR}"

# -----------------------------
# Apache neu laden
# -----------------------------
step "Dienste neu starten"
systemctl restart apache2
systemctl restart mariadb

# -----------------------------
# Webmin optional installieren
# -----------------------------
step "Webmin installieren"
WEBMIN_DEB="${TMP_DIR}/webmin_${WEBMIN_VERSION}_all.deb"
wget --https-only --no-verbose -O "${WEBMIN_DEB}" "${WEBMIN_URL}"
dpkg -i "${WEBMIN_DEB}" || apt-get install -f -y

# -----------------------------
# Ausgabe
# -----------------------------
IP_ADDRESS="$(hostname -I | awk '{print $1}')"
cat <<EOF

============================================================
Installation vorbereitet
============================================================

Nextcloud-Version:   ${NEXTCLOUD_VERSION}
Webadresse:          http://${IP_ADDRESS}/
Datenordner:         ${DATA_DIR}

Datenbanktyp:        MySQL/MariaDB
Datenbankhost:       localhost
Datenbankname:       ${DB_NAME}
Datenbankbenutzer:   ${DB_USER}
Datenbankpasswort:   ${DB_PASSWORD}

Im Nextcloud-Installer eintragen:
  Datenordner:       ${DATA_DIR}
  Datenbankbenutzer: ${DB_USER}
  Datenbankpasswort: ${DB_PASSWORD}
  Datenbankname:     ${DB_NAME}
  Datenbankhost:     localhost

WICHTIG: Speichere dieses Passwort sicher.
============================================================
EOF

systemctl is-active --quiet apache2 || { echo "Apache läuft nicht korrekt." >&2; exit 1; }
systemctl is-active --quiet mariadb || { echo "MariaDB läuft nicht korrekt." >&2; exit 1; }

echo "Fertig. Für den Internetbetrieb anschließend HTTPS, Firewall und Backups einrichten."
exit 0

# Nach der Webinstallation empfiehlt sich ein Cronjob als www-data:
# sudo crontab -u www-data -e
# */5 * * * * php -f /var/www/nextcloud/cron.php
