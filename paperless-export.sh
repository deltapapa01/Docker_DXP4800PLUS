#!/bin/bash
#Aufruf: sudo /home/deltapapa/scripts/paperlessngx/export.sh

#Sollte das Script nicht mit Sudo aufgerufen werden, bricht es ab:
if [ "$EUID" -ne 0 ]; then
  echo "Dieses Skript muss mit Root-Rechten (sudo) ausgeführt werden um Docker zu stoppen."
  exit 1
fi

# Funktion: Aktueller Zeitstempel erstellen
timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# Erstelle ein Logfile und speicher es dort, wo das Exporter-Skript liegt. 
absolute_path=$(dirname -- $(readlink -fn -- "$0"))
logfile="${absolute_path}/exporter.log"
[ -f "${logfile}" ] && rm -f "${logfile}"
[ ! -f "${logfile}" ] && install -m 777 /dev/null "${logfile}"

#schreibt den Beginn des PaperlessNGX - Exports in die log-Datei
echo "$(timestamp) - starte PaperlessNGX-Exporter" | tee -a "${logfile}"

# Name des Containers
CONTAINER_NAME="Paperless-ngx"

# Pfad zum Exportverzeichnis
BACKUP_DIR="/usr/src/paperless/export"

# Anzahl der zu behaltenden Sicherungen
KEEP_COUNT=3

# Pfad zum Verzeichnis, welches bereinigt werden soll:
TARGET_DIR="/volume1/docker/paperless-ngx/export"

# sollte das Verzeichnis zum Export nicht existieren, wird es erstellt:
echo "Prüfe, ob das Verzeichnis $BACKUP_DIR exisiert, erstelle dieses bei Bedarf..." | tee -a "${logfile}"
mkdir -p "$BACKUP_DIR"

# PaperlessNGX - Exporter starten und ZIP Datei erstellen
echo "Initiiere den Prozess document_exporter in Paperless..." | tee -a "${logfile}"
docker exec "$CONTAINER_NAME" document_exporter "$BACKUP_DIR" -z > >(tee -a "${logfile}") 2>&1

# Zip Dateien die älter als Keep_Count sind löschen
echo "Lösche Sicherungen in $TARGET_DIR, welche älter als $KEEP_COUNT Tage sind..." | tee -a "${logfile}"
find $TARGET_DIR -name "*.zip" -type f -mtime +$KEEP_COUNT > >(tee -a "${logfile}") 2>&1

# Abschlussmeldung
echo "$(timestamp) - PaperlessNGX-Exporter abgeschlossen." | tee -a "${logfile}"