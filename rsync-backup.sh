#!/bin/bash
#aufruf im terminal: /volume1/tools/scripts/backup/audio-dxp4800+_auf_ds918+.sh
#aufruf im crontab: 20 02 * * * /volume1/tools/scripts/backup/audio-dxp4800+_auf_ds918+.sh

# Definition von Quelle (lokal) und Ziel (remote)
SOURCE_DIR="/volume2/audio/"
REMOTE_USER="user"
REMOTE_HOST="xxx.xxx.xx.xx"
REMOTE_DEST_DIR="/volume1/backup_audio/"

# Funktion: Aktueller Zeitstempel
timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# Erstelle ein Logfile und speicher es dort, wo das rsync-Skript liegt. 
absolute_path=$(dirname -- $(readlink -fn -- "$0"))
logfile="${absolute_path}/audio.log"
[ -f "${logfile}" ] && rm -f "${logfile}"
[ ! -f "${logfile}" ] && install -m 777 /dev/null "${logfile}"

echo "$(timestamp) - Starte Remote-Synchronisierung" | tee -a "${logfile}"

# Rsync-Befehl über SSH
# -e ssh: Gibt SSH als Remote-Shell an
# -z: Komprimiert die Daten während der Übertragung (nützlich für Netzwerkübertragungen)
# -a: Archivmodus (rekursiv, erhält Berechtigungen, Zeitstempel, Eigentümer etc.)
# -v: Ausführliche Ausgabe (zeigt, was passiert)
# --delete: Löscht Dateien im Ziel, die in der Quelle nicht mehr existieren (Spiegelung)
# --dry-run: (Optional) Simuliert den Vorgang nur, ohne tatsächlich Daten zu kopieren/löschen
rsync -ah --stats -e ssh "$SOURCE_DIR" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DEST_DIR" > >(tee -a "${logfile}") 2>&1
echo "$(timestamp) - Remote-Synchronisierung abgeschlossen." | tee -a "${logfile}"