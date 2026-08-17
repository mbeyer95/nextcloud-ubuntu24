#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo; echo "FEHLER in Zeile ${LINENO}: ${BASH_COMMAND}" >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "Bitte mit sudo oder als root ausführen." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# Konfiguration
# ============================================================
NEXTCLOUD_VERSION="32.0.0"
NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"
INSTALL_DIR="/var/www/nextcloud"
DATA_DIR="/var/nextcloud-data"
APACHE_SITE="/etc/apache2/sites-available/nextcloud.conf"
DB_NAME="Nextcloud_DB"
DB_USER="Nextcloud_User"
INSTALL_WEBMIN="1"   # 1 = installieren, 0 = überspringen
WEBMIN_VERSION="2.021"
WEBMIN_URL="https://sourceforge.net/projects/webadmin/files/webmin/${WEBMIN_VERSION}/webmin_${WEBMIN_VERSION}_all.deb/download"

TMP_DIR="$(mktemp -d /tmp/nextcloud-install.XXXXXX)"
ARCHIVE="${TMP_DIR}/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

step() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

# ============================================================
# Admin-Passwort abfragen
# ============================================================
step "Administratorkonto vorbereiten"

read -r -p "Nextcloud-Administr Benutzername [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

if [[ ! "${ADMIN_USER}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Ungültiger Benutzername. Nur Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich verwenden." >&2
  exit 1
fi

while true; do
  read -r -s -p "Passwort für ${ADMIN_USER}: " ADMIN_PASSWORD
  echo
  read -r -s -p "Passwort wiederholen: " ADMIN_PASSWORD_CONFIRM
  echo

  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    echo "Das Passwort darf nicht leer sein." >&2
  elif [[ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]]; then
    echo "Die Passwörter stimmen nicht überein." >&2
  elif (( ${#ADMIN_PASSWORD} < 12 )); then
    echo "Bitte mindestens 12 Zeichen verwenden." >&2
  else
    break
  fi
  echo
 done

# ============================================================
# Vorprüfung einer bestehenden Installation
# ============================================================
step "Vorprüfung"

if [[ -f "${INSTALL_DIR}/config/config.php" ]]; then
  if sudo -u www-data php "${INSTALL_DIR}/occ" status 2>/dev/null | grep -q "installed: true"; then
    echo "Es ist bereits eine vollständige Nextcloud-Installation vorhanden." >&2
    echo "Abbruch, damit keine Daten überschrieben werden." >&2
    exit 1
  fi

  BACKUP_CONFIG="${INSTALL_DIR}/config/config.php.incomplete.$(date +%Y%m%d-%H%M%S)"
  echo "Unvollständige Konfiguration wird gesichert nach: ${BACKUP_CONFIG}"
  cp -a "${INSTALL_DIR}/config/config.php" "${BACKUP_CONFIG}"
  rm -f "${INSTALL_DIR}/config/config.php"
fi

if [[ -d "${INSTALL_DIR}" ]] && [[ -n "$(find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "Vorhandene Nextcloud-Dateien werden verwendet." 
fi

# ============================================================
# Pakete installieren
# ============================================================
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

# ============================================================
# PHP konfigurieren
# ============================================================
step "PHP konfigurieren"

PHP_INI="/etc/php/8.3/apache2/php.ini"
sed -i -E 's/^memory_limit\s*=.*/memory_limit = 512M/' "${PHP_INI}"
sed -i -E 's/^upload_max_filesize\s*=.*/upload_max_filesize = 10G/' "${PHP_INI}"
sed -i -E 's/^post_max_size\s*=.*/post_max_size = 10G/' "${PHP_INI}"
sed -i -E 's/^max_execution_time\s*=.*/max_execution_time = 3600/' "${PHP_INI}"
sed -i -E 's/^max_input_time\s*=.*/max_input_time = 3600/' "${PHP_INI}"

# ============================================================
# Apache konfigurieren
# ============================================================
step "Apache konfigurieren"

a2enmod rewrite headers env dir mime >/dev/null

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

# ============================================================
# Nextcloud herunterladen, falls noch nicht vorhanden
# ============================================================
step "Nextcloud-Dateien vorbereiten"

if [[ ! -f "${INSTALL_DIR}/occ" ]]; then
  wget --https-only --no-verbose -O "${ARCHIVE}" "${NEXTCLOUD_URL}"
  tar -xjf "${ARCHIVE}" -C "${TMP_DIR}"
  mkdir -p "${INSTALL_DIR}"
  cp -a "${TMP_DIR}/nextcloud/." "${INSTALL_DIR}/"
else
  echo "Nextcloud-Dateien sind bereits vorhanden; Download wird übersprungen."
fi

# ============================================================
# Datenordner und Berechtigungen
# ============================================================
step "Dateirechte setzen"

mkdir -p "${DATA_DIR}"
chown -R www-data:www-data "${INSTALL_DIR}" "${DATA_DIR}"
chmod 750 "${DATA_DIR}"

# ============================================================
# MariaDB-Datenbank und Benutzer
# ============================================================
step "MariaDB einrichten"

DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

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
  -h localhost \
  -u "${DB_USER}" \
  "${DB_NAME}" \
  -e 'SELECT 1;' >/dev/null

echo "MariaDB-Verbindung erfolgreich getestet."

# ============================================================
# Nextcloud per occ installieren
# ============================================================
step "Nextcloud per occ installieren"

if sudo -u www-data php "${INSTALL_DIR}/occ" status 2>/dev/null | grep -q "installed: true"; then
  echo "Nextcloud ist bereits installiert; occ maintenance:install wird übersprungen."
else
  sudo -u www-data php "${INSTALL_DIR}/occ" maintenance:install \
    --database="mysql" \
    --database-name="${DB_NAME}" \
    --database-user="${DB_USER}" \
    --database-pass="${DB_PASSWORD}" \
    --admin-user="${ADMIN_USER}" \
    --admin-pass="${ADMIN_PASSWORD}" \
    --data-dir="${DATA_DIR}"
fi

# ============================================================
# Trusted Domain und Hintergrundaufgaben
# ============================================================
step "Nextcloud-Grundeinstellungen setzen"

SERVER_IP="$(hostname -I | awk '{print $1}')"

sudo -u www-data php "${INSTALL_DIR}/occ" config:system:set trusted_domains 0 --value="localhost"
sudo -u www-data php "${INSTALL_DIR}/occ" config:system:set trusted_domains 1 --value="${SERVER_IP}"
phpenmod -v 8.3 -s cli,apache2 apcu
sudo -u www-data php "${INSTALL_DIR}/occ" config:system:set memcache.local --value='\OC\Memcache\APCu'
sudo -u www-data php "${INSTALL_DIR}/occ" background:cron

# Cronjob nur einmal eintragen.
CRON_LINE="*/5 * * * * php -f ${INSTALL_DIR}/cron.php"
( crontab -u www-data -l 2>/dev/null || true ) | grep -Fq "${INSTALL_DIR}/cron.php" || \
  ( crontab -u www-data -l 2>/dev/null || true; echo "${CRON_LINE}" ) | crontab -u www-data -

# ============================================================
# Webmin optional installieren
# ============================================================
if [[ "${INSTALL_WEBMIN}" == "1" ]]; then
  step "Webmin installieren"
  WEBMIN_DEB="${TMP_DIR}/webmin_${WEBMIN_VERSION}_all.deb"
  wget --https-only --no-verbose -O "${WEBMIN_DEB}" "${WEBMIN_URL}"
  dpkg -i "${WEBMIN_DEB}" || apt-get install -f -y
else
  echo "Webmin wird übersprungen."
fi

# ============================================================
# Abschlussprüfung und Ausgabe
# ============================================================
step "Installation prüfen"

systemctl restart apache2
systemctl restart mariadb
systemctl is-active --quiet apache2
systemctl is-active --quiet mariadb
sudo -u www-data php "${INSTALL_DIR}/occ" status

cat <<EOF

============================================================
INSTALLATION ERFOLGREICH ABGESCHLOSSEN
============================================================

Webadresse:          http://${SERVER_IP}/
Nextcloud-Benutzer:  ${ADMIN_USER}
Datenbankname:       ${DB_NAME}
Datenbankbenutzer:   ${DB_USER}
Datenbankpasswort:   ${DB_PASSWORD}
Datenordner:         ${DATA_DIR}

Das Datenbankpasswort wurde automatisch erzeugt. Bitte sicher speichern.
Für einen öffentlich erreichbaren Server anschließend HTTPS, Firewall und
regelmäßige Backups einrichten.
============================================================
EOF

unset ADMIN_PASSWORD ADMIN_PASSWORD_CONFIRM DB_PASSWORD
exit 0
