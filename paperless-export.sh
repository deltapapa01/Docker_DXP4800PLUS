#!/bin/bash

# Name des Containers
CONTAINER_NAME="Paperless-ngx"

# Pfad zum Exportverzeichnis aus Sicht des Containers
BACKUP_DIR="../export"

# Anzahl der zu behaltenden Sicherungen
KEEP_COUNT=3

# Pfad zum Verzeichnis, welches bereinigt werden soll, aus Sicht des Containers
TARGET_DIR="/app/volume1/docker/paperless-ngx/export"

#####################################################################################
################# Programmablauf, keine Änderungen ab hier vornehmen ################
#####################################################################################

echo "Prüfe, ob das Verzeichnis export exisiert, erstelle dieses bei Bedarf..."
mkdir -p "$BACKUP_DIR"

echo "Generiere den Dateinamen für die aktuelle Sicherung..."
BACKUP_FILE="${BACKUP_DIR}/$(date +\%Y-\%m-\%d).zip"

echo "Initiiere den Prozess document_exporter in Paperless..."
docker exec "$CONTAINER_NAME" document_exporter "$BACKUP_DIR" -z

echo "Lösche Sicherungen in $TARGET_DIR, welche älter als $KEEP_COUNT Tage sind..."
ls -t "$TARGET_DIR" | sort | tac | tail -n +$(($KEEP_COUNT + 1)) | xargs -I {} rm -f "$TARGET_DIR/{}" -v

echo "Die Sicherung wurde erfolgreich erstellt."