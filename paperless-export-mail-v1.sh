#!/bin/bash
# ==========================================================================
# Aufruf z.B. mit:
# Aufruf im Terminal // sudo /volume1/tools/scripts/paperlessngx/export.sh
# Aufruf im Crontab jeden Tag um 02:10 // 10 02 * * * sudo /volume1/tools/scripts/paperlessngx/export.sh
# ==========================================================================
# Anleitung um über SSH ohne Passwort zuzugreifen:
# https://github.com/toafez/Tutorials/blob/main/SSH-Key_Linux_Kommandozeile.md
# ==========================================================================
# Versionen
# v1.0 - Grundversion von https://github.com/deltapapa01 auf Basis von diesem Script: https://ugreen-forum.de/forum/thread/1692-tut-cronicle-aufgabenplaner-f%C3%BCr-cronjobs/?postID=27149#post27149
# v2.0 - Logfile hinzugefügt -> Credit: Tommes from https://github.com/toafez
# v3.0 - Mail-Funktion hinzugefügt
# v4.0 - Mail-Funktion ergänzt + robustere Export-Logik
# ==========================================================================
# Mit Unterstützung von:
# https://ugreen-forum.de/
# https://www.facebook.com/groups/ugreennasyncdebenutzergruppe/
# https://deltapapa.de/
# Roman Glos for Ugreen NAS Community
# ==========================================================================

set -Eeuo pipefail

# =========================
# Konfiguration
# =========================
CONTAINER_NAME="PaperlessNgx"                              	# ggf. anpassen (docker ps --format '{{.Names}}')
HOST_BACKUP_DIR="/volume1/docker/paperlessngx-mdb/export"   # HIER ändern (Host-Pfad)
KEEP_FILES=7												# wie viele ZIPs behalten

# Export-Ziel IM CONTAINER (NICHT Host!)
EXPORT_ROOT_CANDIDATES=( "/export" "/usr/src/paperless/export" )

# =========================
# Mail-Benachrichtigung (optional)
# =========================
MAIL_ENABLED=1          									# 1 = Mail senden, 0 = deaktiviert
MAIL_ON_SUCCESS=1											# 1 = auch bei Erfolg senden
MAIL_ON_FAILURE=1											# 1 = bei Fehler senden

# SMTP Settings (curl)
SMTP_HOST="server.com"					# SMTP Server
TLS_ENABLED=1            				# 1 = TLS an (STARTTLS/SMTPS), 0 = TLS aus
SMTP_PORT="465"             			# leer = auto (TLS->587, ohne TLS->25). Für SMTPS: 465 eintragen
SMTP_USER="user"						# Benutzername des Mail - Konto
SMTP_PASS="pw"   						# Passwort des Mail Konto
MAIL_FROM="user@mail.de"				# Mail Adresse des Absenders
MAIL_FROM_NAME="Paperless Backup"		# Beschreibung im Betreff
MAIL_TO="user@mail.de"					# Mail Adresse des Empfängers

# Unicode-Icons in Mail (✅/❌) können je nach Mail-Client/Server falsch dargestellt werden,
# wenn der Mail kein UTF-8 Charset mitgegeben wird. Wir setzen daher MIME-Header auf UTF-8.
# Optional kannst du die Icons auch komplett auf ASCII umstellen.
MAIL_ASCII_ICONS=0						# 1 = [OK]/[FAIL] statt ✅/❌


ICON_OK="✅"
ICON_FAIL="❌"
if [[ "${MAIL_ASCII_ICONS}" == "1" ]]; then ICON_OK="[OK]"; ICON_FAIL="[FAIL]"; fi

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

absolute_path=$(dirname -- "$(readlink -fn -- "$0")")
logfile="${absolute_path}/exporter.log"
: >"$logfile"
chmod 664 "$logfile" || true

pick_port() {
  if [[ -n "${SMTP_PORT}" ]]; then echo "${SMTP_PORT}"; return; fi
  [[ "${TLS_ENABLED}" == "1" ]] && echo "587" || echo "25"
}

send_mail() {
  [[ "${MAIL_ENABLED}" != "1" ]] && return 0
  command -v curl >/dev/null 2>&1 || { echo "WARN: curl not found -> no mail." | tee -a "$logfile"; return 0; }

  local subject="$1" body="$2" port url
  port="$(pick_port)"

  local now_rfc2822 msg_id tmp
  now_rfc2822="$(LC_ALL=C date -R)"
  msg_id="<$(date +%s).$$.$(hostname)@${MAIL_FROM#*@}>"

  local subject_hdr="$subject"
  if LC_ALL=C printf '%s' "$subject" | grep -q '[^ -~]'; then
    if command -v base64 >/dev/null 2>&1; then
      subject_hdr="=?UTF-8?B?$(printf '%s' "$subject" | base64 | tr -d '\r\n')?="
    else
      subject_hdr="$(printf '%s' "$subject" | tr -cd '[:print:]')"
    fi
  fi

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
    echo
    printf "%b\n" "$body"
  } >"$tmp"

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

  curl --silent --show-error --fail \
    --connect-timeout 15 --max-time 60 \
    --url "$url" \
    --user "${SMTP_USER}:${SMTP_PASS}" \
    --mail-from "$MAIL_FROM" \
    --mail-rcpt "$MAIL_TO" \
    --upload-file "$tmp" \
    "${tls_args[@]}" \
    | tee -a "$logfile" || true

  rm -f "$tmp"
}

fail() {
  local rc=$1; shift || true
  echo "$(timestamp) - FEHLER (rc=$rc): $*" | tee -a "$logfile"
  if [[ "${MAIL_ON_FAILURE}" == "1" ]]; then
    send_mail "Paperless Export FEHLER (rc=$rc)" \
"${ICON_FAIL} Paperless Export fehlgeschlagen: $(timestamp)
Host: $(hostname)
Container: ${CONTAINER_NAME}
Host-Backup-Dir: ${HOST_BACKUP_DIR}
Log: ${logfile}

Letzte Zeilen:
$(tail -n 200 "$logfile" 2>/dev/null)"
  fi
  exit "$rc"
}

run_exporter() {
  # A) document_exporter wrapper needs /command in PATH
  echo "$(timestamp) - Export-Methode A: document_exporter (PATH=/command)" | tee -a "$logfile"
  if docker exec "$CONTAINER_NAME" sh -lc "export PATH=/command:\$PATH; document_exporter '$CONTAINER_TMP_DIR' -z" >>"$logfile" 2>&1; then
    return 0
  fi

  # B) Fallback: manage.py direct
  echo "$(timestamp) - Export-Methode B (Fallback): python manage.py document_exporter" | tee -a "$logfile"
  docker exec "$CONTAINER_NAME" sh -lc "
    set -e
    PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
    for P in /usr/src/paperless/src/manage.py /usr/src/paperless/manage.py; do
      if [ -f \"\$P\" ]; then
        \"\$PY\" \"\$P\" document_exporter '$CONTAINER_TMP_DIR' -z
        exit 0
      fi
    done
    echo 'manage.py nicht gefunden (Fallback gescheitert)' >&2
    exit 1
  " >>"$logfile" 2>&1
}

# =========================
# Start
# =========================
echo "$(timestamp) - starte PaperlessNGX-Exporter" | tee -a "$logfile"

mkdir -p "$HOST_BACKUP_DIR" || fail 2 "Kann Host Backup Dir nicht anlegen: $HOST_BACKUP_DIR"

if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | tee -a "$logfile" || true
  fail 3 "Container nicht gefunden: $CONTAINER_NAME"
fi

# --- Auto-detect export root in container
CONTAINER_EXPORT_ROOT=""
for cand in "${EXPORT_ROOT_CANDIDATES[@]}"; do
  if docker exec "$CONTAINER_NAME" sh -lc "[ -d '$cand' ]" >/dev/null 2>&1; then
    CONTAINER_EXPORT_ROOT="$cand"
    break
  fi
done
[[ -z "$CONTAINER_EXPORT_ROOT" ]] && fail 4 "Kein Export-Root gefunden (geprüft: ${EXPORT_ROOT_CANDIDATES[*]})"

CONTAINER_TMP_DIR="${CONTAINER_EXPORT_ROOT%/}/_tmp"

# Prepare tmp (never remove mountpoint, only subdir)
if ! docker exec "$CONTAINER_NAME" sh -lc "rm -rf '$CONTAINER_TMP_DIR' && mkdir -p '$CONTAINER_TMP_DIR'" >>"$logfile" 2>&1; then
  fail 4 "Kann Export-Tmp im Container nicht vorbereiten: $CONTAINER_TMP_DIR"
fi

ARCHIVE_NAME="paperless_export_$(date +%Y%m%d_%H%M%S).zip"
HOST_ARCHIVE_PATH="${HOST_BACKUP_DIR%/}/${ARCHIVE_NAME}"

echo "$(timestamp) - Starte Export im Container..." | tee -a "$logfile"
run_exporter || fail 5 "document_exporter fehlgeschlagen"

# --- Find newest ZIP in tmp (name may be export-YYYY-MM-DD.zip etc.)
CONTAINER_ZIP="$(docker exec "$CONTAINER_NAME" sh -lc "ls -1t '$CONTAINER_TMP_DIR'/*.zip 2>/dev/null | head -n1" | tr -d '\r')"
[[ -z "$CONTAINER_ZIP" ]] && fail 6 "Keine ZIP im Container gefunden in: $CONTAINER_TMP_DIR"

ZIP_BASENAME="$(basename "$CONTAINER_ZIP")"
HOST_TMP_ZIP="${HOST_BACKUP_DIR%/}/_tmp/${ZIP_BASENAME}"

# Prefer host-move if bind mount is present and file exists on host
if [[ -f "$HOST_TMP_ZIP" ]]; then
  mv -f "$HOST_TMP_ZIP" "$HOST_ARCHIVE_PATH" >>"$logfile" 2>&1 || fail 6 "Host-move fehlgeschlagen: $HOST_TMP_ZIP -> $HOST_ARCHIVE_PATH"
else
  docker cp "${CONTAINER_NAME}:${CONTAINER_ZIP}" "$HOST_ARCHIVE_PATH" >>"$logfile" 2>&1 || fail 6 "docker cp fehlgeschlagen: ${CONTAINER_ZIP}"
fi

echo "$(timestamp) - Export erstellt: $HOST_ARCHIVE_PATH" | tee -a "$logfile"

# Cleanup tmp
docker exec "$CONTAINER_NAME" sh -lc "rm -rf '$CONTAINER_TMP_DIR'" >>"$logfile" 2>&1 || true
rm -rf "${HOST_BACKUP_DIR%/}/_tmp" >>"$logfile" 2>&1 || true

# Retention
mapfile -t files < <(ls -1t "${HOST_BACKUP_DIR%/}"/paperless_export_*.zip 2>/dev/null || true)
if (( ${#files[@]} > KEEP_FILES )); then
  echo "$(timestamp) - Retention: behalte $KEEP_FILES ZIPs, lösche ${#files[@]}-${KEEP_FILES}" | tee -a "$logfile"
  for ((i=KEEP_FILES; i<${#files[@]}; i++)); do
    rm -f "${files[$i]}" && echo "$(timestamp) - gelöscht: ${files[$i]}" | tee -a "$logfile"
  done
fi

echo "$(timestamp) - PaperlessNGX-Exporter abgeschlossen." | tee -a "$logfile"
if [[ "${MAIL_ON_SUCCESS}" == "1" ]]; then
  send_mail "Paperless Export OK" \
"${ICON_OK} Paperless Export erfolgreich: $(timestamp)
Host: $(hostname)
Container: ${CONTAINER_NAME}
Backup: ${HOST_ARCHIVE_PATH}
Log: ${logfile}

Letzte Zeilen:
$(tail -n 80 "$logfile" 2>/dev/null)"
fi

exit 0