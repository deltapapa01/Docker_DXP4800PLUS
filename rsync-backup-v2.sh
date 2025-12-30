#!/bin/bash
# Rsync Backup Script: Lokales Verzeichnis auf Remote NAS sichern
# Art: Differenzielles Backup (sichert Änderungen seit dem letzten Voll-Backup, wird mit der Zeit größer)
# ==========================================================================
# Beschreibung:
# Dieses Skript führt ein Rsync-Backup eines lokalen Verzeichnisses auf ein Remote-NAS durch.
# Es verwendet SSH für die sichere Übertragung und erstellt ein Logfile.
# Optional kann eine E-Mail-Benachrichtigung bei Erfolg oder Fehler versendet werden.
# ==========================================================================
# Aufruf z.B. mit:
# Im Terminal: /volume1/tools/scripts/backup/audio-dxp4800+_auf_ds918+.sh
# Im crontab um 02:20 Uhr: 20 02 * * * /volume1/tools/scripts/backup/audio-dxp4800+_auf_ds918+.sh
# ==========================================================================
# Anleitung um über SSH ohne Passwort zuzugreifen:
# https://github.com/toafez/Tutorials/blob/main/SSH-Key_Linux_Kommandozeile.md
# ==========================================================================
# Versionen
# v1.0 - Grundversion von https://github.com/deltapapa01 / https://deltapapa.de
# v2.0 - Logfile hinzugefügt -> Credit: Tommes from https://github.com/toafez
# v3.0 - Mail-Funktion hinzugefügt -> Credit: Roman Glos for Ugreen NAS Community
# v4.0 - Mail-Funktion überarbeitet, TLS-Unterstützung hinzugefügt -> Credit: Roman Glos for Ugreen NAS Community
# ==========================================================================
# Mit Unterstützung von:
# https://ugreen-forum.de/
# https://www.facebook.com/groups/ugreennasyncdebenutzergruppe/
# https://deltapapa.de/

#Fehlerbehandlung aktivieren
set -Eeuo pipefail

# Definition von Quelle (lokal) und Ziel (remote)
BACKUP_NAME="audio rsync from DXP4800+"     # Name des Backups
LOGFILE_NAME="/audio-logfile.log"           # Name des Logfiles
SOURCE_DIR="/volume2/audio/"                # Quellverzeichnis (lokal)
REMOTE_USER="user"                          # Remote-Benutzer
REMOTE_HOST="xxx.xxx.xx.xx"                 # Remote-Host (IP-Adresse oder Domain)
REMOTE_DEST_DIR="/volume1/backup_audio/"    # Zielverzeichnis auf dem Remote-Host

# Funktion: Aktueller Zeitstempel
timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# =========================
# Mail-Benachrichtigung (optional)
# =========================
MAIL_ENABLED=1           # 1 = Mail senden, 0 = deaktiviert
MAIL_ON_SUCCESS=1        # 1 = auch bei Erfolg senden
MAIL_ON_FAILURE=1        # 1 = bei Fehler senden

# SMTP Settings (curl)
SMTP_HOST="xxxxxx.mailserver.com"       # SMTP Server
TLS_ENABLED=1            				# 1 = TLS an (STARTTLS/SMTPS), 0 = TLS aus
SMTP_PORT="465"             			# leer = auto (TLS->587, ohne TLS->25). Für SMTPS: 465 eintragen
SMTP_USER="mail-benutzername"           # Benutzername des Mail - Konto
SMTP_PASS="mail-passwort"             	# Passwort des Mail Konto
MAIL_FROM="from@domain.de"       		# Mail Adresse des Absenders
MAIL_FROM_NAME="Rsync Backup"			# Text im Betreff
MAIL_TO="to@domain.de"      			# Mail Adresse des Empfängers

# Unicode-Icons in Mail (✅/❌) können je nach Mail-Client/Server falsch dargestellt werden,
# wenn der Mail kein UTF-8 Charset mitgegeben wird. Wir setzen daher MIME-Header auf UTF-8.
# Optional kannst du die Icons auch komplett auf ASCII umstellen.
MAIL_ASCII_ICONS=0      # 1 = [OK]/[FAIL] statt ✅/❌

ICON_OK="✅"
ICON_FAIL="❌"
if [[ "${MAIL_ASCII_ICONS}" == "1" ]]; then
  ICON_OK="[OK]"
  ICON_FAIL="[FAIL]"
fi

# Funktion: Wähle SMTP-Port basierend auf TLS-Einstellung
pick_port() {
  if [[ -n "${SMTP_PORT}" ]]; then echo "${SMTP_PORT}"; return; fi
  [[ "${TLS_ENABLED}" == "1" ]] && echo "587" || echo "25"
}

# Funktion: Sende E-Mail mit curl
send_mail() {
  [[ "${MAIL_ENABLED}" != "1" ]] && return 0
  command -v curl >/dev/null 2>&1 || { echo "WARN: curl nicht gefunden -> keine Mail gesendet." >&2; return 0; }
  local subject="$1"
  local body="$2"
  local port url
  port="$(pick_port)"
  local tmp now_rfc2822 msg_id
  now_rfc2822="$(LC_ALL=C date -R)"
  msg_id="<$(date +%s).$$.$(hostname)@${MAIL_FROM#*@}>"

  # Subject korrekt MIME-encoden, falls Nicht-ASCII enthalten ist
  local subject_hdr="$subject"
  if LC_ALL=C printf '%s' "$subject" | grep -q '[^ -~]'; then
    if command -v base64 >/dev/null 2>&1; then
      subject_hdr="=?UTF-8?B?$(printf '%s' "$subject" | base64 | tr -d '\r\n')?="
    else
      # Fallback: wenn base64 fehlt, lieber ASCII erzwingen
      subject_hdr="$(printf '%s' "$subject" | tr -cd '[:print:]')"
    fi
  fi

# Erstelle temporäre Mail-Datei
  tmp="$(mktemp)"
  {
    echo "From: ${MAIL_FROM_NAME} <${MAIL_FROM}>"
    echo "To: ${MAIL_TO}"
    echo "Subject: ${subject_hdr}"
    echo "Date: ${now_rfc2822}"
    echo "Message-ID: ${msg_id}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo "X-Mailer: bash/curl"
    echo
    printf "%b\n" "$body"
  } > "$tmp"

# Baue curl SMTP URL und TLS-Parameter zusammen
  local -a tls_args=()
  if [[ "${TLS_ENABLED}" == "1" ]]; then
    if [[ "${port}" == "465" ]]; then
      url="smtps://${SMTP_HOST}:${port}"
    else
      url="smtp://${SMTP_HOST}:${port}"
      tls_args+=(--ssl-reqd)
    fi
  else
    url="smtp://${SMTP_HOST}:${port}"
  fi

# Sende Mail mit curl
  curl --silent --show-error --fail \
    --connect-timeout 15 --max-time 60 \
    --url "$url" \
    --user "${SMTP_USER}:${SMTP_PASS}" \
    --mail-from "$MAIL_FROM" \
    --mail-rcpt "$MAIL_TO" \
    --upload-file "$tmp" \
    "${tls_args[@]}" || true

  rm -f "$tmp"
}

# Erstelle ein Logfile und speicher es dort, wo das rsync-Skript liegt. 
absolute_path=$(dirname -- $(readlink -fn -- "$0"))
logfile="${absolute_path}${LOGFILE_NAME}"
[ -f "${logfile}" ] && rm -f "${logfile}"
[ ! -f "${logfile}" ] && install -m 777 /dev/null "${logfile}"

echo "$(timestamp) - Starte Remote-Synchronisierung" | tee -a "${logfile}"

# =========================
# Rsync Backup ausführen
# =========================
# Rsync-Befehl über SSH
# -e ssh: Gibt SSH als Remote-Shell an
# -z: Komprimiert die Daten während der Übertragung (nützlich für Netzwerkübertragungen)
# -a: Archivmodus (rekursiv, erhält Berechtigungen, Zeitstempel, Eigentümer etc.)
# -v: Ausführliche Ausgabe (zeigt, was passiert)
# --delete: Löscht Dateien im Ziel, die in der Quelle nicht mehr existieren (Spiegelung)
# --dry-run: (Optional) Simuliert den Vorgang nur, ohne tatsächlich Daten zu kopieren/löschen
if rsync -ah --stats -e ssh "$SOURCE_DIR" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DEST_DIR" > >(tee -a "${logfile}") 2>&1; then
  echo "$(timestamp) - Remote-Synchronisierung abgeschlossen." | tee -a "${logfile}"
  if [[ "${MAIL_ON_SUCCESS}" == "1" ]]; then
    send_mail "Backup OK: $BACKUP_NAME" "${ICON_OK} Rsync Backup erfolgreich: $(timestamp)\nHost: $(hostname)\nQuelle: ${SOURCE_DIR}\nZiel: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST_DIR}\nLog: ${logfile}\n\nLetzte Zeilen:\n$(tail -n 40 "${logfile}" 2>/dev/null)"
  fi
else
  rc=$?
  echo "$(timestamp) - FEHLER: Rsync Backup fehlgeschlagen (rc=$rc)." | tee -a "${logfile}"
  if [[ "${MAIL_ON_FAILURE}" == "1" ]]; then
    send_mail "Backup FEHLER (rc=$rc): $BACKUP_NAME" "${ICON_FAIL} Rsync Backup fehlgeschlagen: $(timestamp)\nHost: $(hostname)\nQuelle: ${SOURCE_DIR}\nZiel: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST_DIR}\nLog: ${logfile}\n\nLetzte Zeilen:\n$(tail -n 120 "${logfile}" 2>/dev/null)"
  fi
  exit "$rc"
fi
