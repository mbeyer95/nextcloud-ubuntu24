#!/bin/bash

# Updates installieren
echo "Updates werden installiert."
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
echo

# Alle benötigten Pakete werden installiert
echo "Alle benötigten Pakete werden installiert."
sudo apt install apache2 mariadb-server php8.3 libapache2-mod-php8.3 php8.3-gd php8.3-mysql \
php8.3-curl php8.3-mbstring php8.3-intl php8.3-gmp php8.3-bcmath php8.3-xml php8.3-imagick php8.3-zip bzip2 -y
echo

# Webmin wird installiert
echo "Webmin wird installiert."
cd /tmp
sudo apt install unzip -y
wget https://sourceforge.net/projects/webadmin/files/webmin/2.021/webmin_2.021_all.deb
dpkg -i /tmp/webmin_2.021_all.deb
sudo apt install unzip -y
apt --fix-broken install -y
dpkg -i /tmp/webmin_2.021_all.deb
echo

# PHP mehr Arbeitsspeicher zuweisen
echo "PHP wird mehr Arbeitsspeicher zugewiesen."
sed -i "s|memory_limit = 128M|memory_limit = 1024M|" /etc/php/8.3/apache2/php.ini

cd /var/www/html
rm -rf index.html
echo

# Nextcloud herunterladen
echo "Nextcloud wird heruntergeladen."
wget https://download.nextcloud.com/server/releases/nextcloud-32.0.0.tar.bz2
echo

# Nextcloud entpacken und abgelegt.
echo "Nextcloud wird entpackt und Verzeichnis wird angelegt."
tar xjf nextcloud-32.0.0.tar.bz2
mv nextcloud/* .
rm -rf nextcloud
rm -rf nextcloud-32.0.0.tar.bz2
echo

# Besitzer vom Nextcloud Verzeichnis ändern
echo "Besitzer vom Nextcloud Verzeichnis ändern."
cd /var/www
sudo chown -R www-data:www-data html
echo

# Apache neustarten
echo "Apache wird neugestartet."
sudo systemctl restart apache2
echo

# Datenbank erstellen
echo "Datenbank wird erstellt."
mysql_root_pw=$(openssl rand -base64 16)
datenbankname=Nextcloud_DB
datenbankuser=Nextcloud_User
datenbankpw=$(openssl rand -base64 16)
MYSQL_CMD="sudo mysql -u root -p${mysql_root_pw}"
SQL_CMD="CREATE DATABASE \`${datenbankname}\`; GRANT ALL PRIVILEGES ON \`${datenbankname}\`.* TO '${datenbankuser}'@'localhost' IDENTIFIED BY '${datenbankpw}'; FLUSH PRIVILEGES;"
echo $SQL_CMD | $MYSQL_CMD

# Apache neustarten
echo "Apache wird neugestartet."
sudo systemctl restart apache2
echo

# Sicherheit verbessern
echo "Sicherheit verbessern..."
# PHP Buffering ausschalten in php.ini
sed -i "s|output_buffering = 4096|output_buffering = Off|" /etc/php/8.3/apache2/php.ini
# AllowOverride von /var/www/ auf "All" gesetzt in apache2.conf 
sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
echo

# Apache neustarten
echo "Apache wird neugestartet."
sudo systemctl restart apache2
echo

# Infos anzeigen
echo -e "MYSQL/MariaDB Root Passwort: \e[35m$mysql_root_pw\e[0m"
echo -e "Webadresse: \e[35mhttp://$(hostname -I | cut -d' ' -f1)\e[0m"
echo -e "Datenbank-Benutzer: \e[35m$datenbankuser\e[0m"
echo -e "Datenbank-Passwort: \e[35m$datenbankpw\e[0m"
echo -e "Datenbank-Name: \e[35m$datenbankname\e[0m"
echo -e "Datenbank-Host: \e[35mlocalhost\e[0m"
