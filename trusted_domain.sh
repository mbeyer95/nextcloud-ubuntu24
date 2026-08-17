#!/bin/bash
config="/var/www/html/config/config.php"
if [ ! -f "$config" ]; then echo "❌ config.php nicht gefunden"; exit 1; fi

read -p "Domain eingeben (z.B. cloud.gela-roosh.de): " domain
if [ -n "$domain" ]; then
  php -r "\$c=include '$config'; \$c['trusted_domains'][]=trim(\$argv[1]); file_put_contents('$config','<?php \$CONFIG = '.var_export(\$c,true).';');" "$domain"
  echo "✅ $domain hinzugefügt"
fi

while true; do
  read -p "Weitere Domain? (j/n): " answer
  [ "$answer" != "j" ] && break
  read -p "Domain: " domain
  if [ -n "$domain" ]; then
    php -r "\$c=include '$config'; \$c['trusted_domains'][]=trim(\$argv[1]); file_put_contents('$config','<?php \$CONFIG = '.var_export(\$c,true).';');" "$domain"
    echo "✅ $domain hinzugefügt"
  fi
done
