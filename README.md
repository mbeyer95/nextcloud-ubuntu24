# Nextcloud 32 Installation in Ubuntu 24

1. Das Script "main.sh" mit sudo ausführen. Es wird nun automatisch Webmin und Nextcloud heruntergeladen, installiert und konfiguriert.
2. Nach der erfolgreichen Installation die angezeigten Infos (Webadresse, Datenbank-User, Datenbank-Passwort, Datenbank-Name und Datenbank-Host) abspeichern.
2. Die Webadresse im Browser eingeben.
3. Ein erstes Administrator-Konto anlegen und die notierten Datenbank-Einstellungen eintragen.
4. Nextcloud installieren.
5. Das Script "trusted_domain.sh" mit sudo ausführen. Falls man die Nextcloud von außen mit einer Domain-Adresse erreichbar machen möchte, dann muss diese zur sicheren Liste hinzugefügt werden.
6. Die Domain/Domains eintragen, der vertraut werden sollen (wird in die config.php von Nextcloud gespeichert).
