#!/usr/bin/env bash
# =============================================================================
#  clockodo-sync – Setup & Verwaltung
#  Clockodo-Arbeitszeiten (Kommen/Gehen/Pausen) -> Excel (1 Blatt pro Monat)
#  -> Nextcloud, als Cronjob. Für Debian/Ubuntu (VM, LXC, Docker).
#
#  Aufruf:  sudo bash clockodo-sync-installer.sh            (Menü / Ersteinrichtung)
#           sudo bash clockodo-sync-installer.sh --install  (Einrichtungsassistent)
#           sudo bash clockodo-sync-installer.sh --update   (nur Programm aktualisieren)
#           sudo bash clockodo-sync-installer.sh --uninstall
#  Nach der Installation jederzeit:  sudo clockodo-sync-setup
# =============================================================================
set -u

APP=clockodo-sync
SVC_USER=clockodo-sync
OPT_DIR=/opt/clockodo-sync
CONF_DIR=/etc/clockodo-sync
CONF=$CONF_DIR/config.ini
DATA_DIR=/var/lib/clockodo-sync
LOG_DIR=/var/log/clockodo-sync
CRON_FILE=/etc/cron.d/clockodo-sync
WRAPPER=/usr/local/bin/clockodo-sync
SETUP_LINK=/usr/local/sbin/clockodo-sync-setup
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------- Ausgabe ----
if [ -t 1 ]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi
info()  { echo "${C}➜${N} $*"; }
ok()    { echo "${G}✔${N} $*"; }
warn()  { echo "${Y}⚠${N} $*"; }
err()   { echo "${R}✘${N} $*" >&2; }
head1() { echo; echo "${B}━━━ $* ━━━${N}"; }
pause() { read -r -p "Weiter mit [Enter] …" _ </dev/tty; }

# ------------------------------------------------------------ Eingaben -------
# ask VAR "Frage" "Standard"
ask() {
  local __v="$1" __q="$2" __d="${3:-}" __a
  if [ -n "$__d" ]; then read -r -p "$__q [${__d}]: " __a </dev/tty; else read -r -p "$__q: " __a </dev/tty; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}
# ask_secret VAR "Frage" "vorhandener Wert"  (leer lassen = behalten)
ask_secret() {
  local __v="$1" __q="$2" __d="${3:-}" __a hint=""
  [ -n "$__d" ] && hint=" [Enter = unverändert lassen]"
  read -r -s -p "$__q$hint: " __a </dev/tty; echo
  printf -v "$__v" '%s' "${__a:-$__d}"
}
# ask_yn VAR "Frage" j|n
ask_yn() {
  local __v="$1" __q="$2" __d="${3:-j}" __a __p="[J/n]"
  [ "$__d" = "n" ] && __p="[j/N]"
  while true; do
    read -r -p "$__q $__p: " __a </dev/tty
    __a="${__a:-$__d}"
    case "${__a,,}" in
      j|ja|y|yes) printf -v "$__v" yes; return;;
      n|nein|no)  printf -v "$__v" no;  return;;
    esac
  done
}
# ask_required VAR "Frage" "Standard"
ask_required() {
  while true; do ask "$@"; [ -n "${!1}" ] && return; warn "Eingabe erforderlich."; done
}

# ------------------------------------------------------- Konfig lesen --------
cfg_get() { # cfg_get section key
  [ -f "$CONF" ] || return 0
  awk -v s="[$1]" -v k="$2" '
    /^\[/ {sec=$0; next}
    sec==s { line=$0; sub(/^[ \t]+/,"",line); if (index(line,k)==1) { rest=substr(line,length(k)+1); if (rest ~ /^[ \t]*=/) { sub(/^[ \t]*=[ \t]?/,"",rest); print rest; exit } } }
  ' "$CONF"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then err "Bitte als root ausführen (sudo bash $0)."; exit 1; fi
}
is_installed() { [ -f "$OPT_DIR/clockodo_sync.py" ] && [ -f "$CONF" ]; }
run_app() { "$WRAPPER" "$@"; }

# --------------------------------------------------------- Umgebung ----------
detect_env() {
  ENV_TYPE="unbekannt"; IN_DOCKER=no; HAS_SYSTEMD=no
  [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && HAS_SYSTEMD=yes
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local c v; c=$(systemd-detect-virt -c 2>/dev/null); v=$(systemd-detect-virt 2>/dev/null)
    if [ -n "$c" ] && [ "$c" != "none" ]; then ENV_TYPE="Container ($c)"; [ "$c" = "docker" ] && IN_DOCKER=yes
    elif [ -n "$v" ] && [ "$v" != "none" ]; then ENV_TYPE="VM ($v)"
    else ENV_TYPE="Physischer Server"; fi
  fi
  if [ -f /.dockerenv ]; then ENV_TYPE="Container (docker)"; IN_DOCKER=yes; fi
  grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && ENV_TYPE="Container (lxc)"
}

check_os() {
  if [ ! -r /etc/os-release ]; then err "Unbekanntes Betriebssystem."; exit 1; fi
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-$ID}"
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) ;;
    *) warn "Getestet für Debian/Ubuntu – erkannt: $OS_NAME. Fortfahren auf eigene Gefahr.";
       ask_yn c "Trotzdem fortfahren?" n; [ "$c" = yes ] || exit 1;;
  esac
  command -v apt-get >/dev/null || { err "apt-get nicht gefunden."; exit 1; }
}

# ------------------------------------------------------ Pakete ---------------
install_packages() {
  head1 "Pakete installieren"
  export DEBIAN_FRONTEND=noninteractive
  info "apt-get update …"
  apt-get update -qq || { err "apt-get update fehlgeschlagen (Internet/DNS prüfen)."; exit 1; }
  local pkgs="python3 python3-requests python3-openpyxl cron tzdata ca-certificates util-linux procps curl"
  info "Installiere: $pkgs"
  apt-get install -y -qq --no-install-recommends $pkgs >/dev/null || { err "Paketinstallation fehlgeschlagen."; exit 1; }
  local pyok
  pyok=$(python3 -c 'import sys; print(1 if sys.version_info >= (3,9) else 0)' 2>/dev/null)
  if [ "$pyok" != "1" ]; then err "Python 3.9+ wird benötigt (gefunden: $(python3 -V 2>&1)). Bitte OS aktualisieren."; exit 1; fi
  if ! python3 -c 'import openpyxl, requests, zoneinfo; zoneinfo.ZoneInfo("Europe/Berlin")' 2>/dev/null; then
    warn "Systempakete unvollständig – richte eigene Python-Umgebung ein (venv) …"
    apt-get install -y -qq --no-install-recommends python3-venv python3-pip >/dev/null
    python3 -m venv "$OPT_DIR/venv" && "$OPT_DIR/venv/bin/pip" install -q --upgrade openpyxl requests tzdata \
      || { err "Python-Bibliotheken konnten nicht installiert werden."; exit 1; }
  fi
  ok "Pakete bereit ($(python3 -V 2>&1))"
}

# ---------------------------------------------------- Dateien/Rechte ---------
extract_program() {
  # Programm liegt entweder neben dem Script oder ist unten eingebettet
  local dir; dir="$(dirname "$SELF")"
  mkdir -p "$OPT_DIR"
  if grep -q '^__PYTHON_PAYLOAD_BELOW__$' "$SELF"; then
    sed -n '/^__PYTHON_PAYLOAD_BELOW__$/,$p' "$SELF" | tail -n +2 > "$OPT_DIR/clockodo_sync.py.new"
  elif [ -f "$dir/clockodo_sync.py" ]; then
    cp "$dir/clockodo_sync.py" "$OPT_DIR/clockodo_sync.py.new"
  else
    err "Programmdatei clockodo_sync.py nicht gefunden."; exit 1
  fi
  python3 -m py_compile "$OPT_DIR/clockodo_sync.py.new" 2>/dev/null || { err "Programmdatei ist beschädigt."; rm -f "$OPT_DIR/clockodo_sync.py.new"; exit 1; }
  mv "$OPT_DIR/clockodo_sync.py.new" "$OPT_DIR/clockodo_sync.py"
  rm -rf "$OPT_DIR/__pycache__"
  chmod 755 "$OPT_DIR/clockodo_sync.py"
  # Setup selbst mit ablegen -> später "clockodo-sync-setup"
  if [ "$SELF" != "$OPT_DIR/setup.sh" ]; then cp "$SELF" "$OPT_DIR/setup.sh"; fi
  chmod 700 "$OPT_DIR/setup.sh"
  ln -sf "$OPT_DIR/setup.sh" "$SETUP_LINK"

  cat > "$WRAPPER" <<EOF
#!/bin/sh
# clockodo-sync Aufruf-Wrapper (läuft immer als Benutzer $SVC_USER)
PY=/usr/bin/python3
[ -x $OPT_DIR/venv/bin/python ] && PY=$OPT_DIR/venv/bin/python
if [ "\$(id -u)" = 0 ]; then
  exec runuser -u $SVC_USER -- "\$PY" $OPT_DIR/clockodo_sync.py "\$@"
fi
exec "\$PY" $OPT_DIR/clockodo_sync.py "\$@"
EOF
  chmod 755 "$WRAPPER"
  ok "Programm installiert: $OPT_DIR/clockodo_sync.py ($(grep -m1 '^VERSION' "$OPT_DIR/clockodo_sync.py" | cut -d'"' -f2))"
}

create_user_dirs() {
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
    ok "Systembenutzer $SVC_USER angelegt"
  fi
  mkdir -p "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
  chown root:"$SVC_USER" "$CONF_DIR"; chmod 750 "$CONF_DIR"
  chown -R "$SVC_USER":"$SVC_USER" "$DATA_DIR" "$LOG_DIR"; chmod 750 "$DATA_DIR" "$LOG_DIR"
}

# ------------------------------------------------------ Konfiguration --------
load_current() {
  C_EMAIL=$(cfg_get clockodo email);           C_KEY=$(cfg_get clockodo api_key)
  C_CONTACT=$(cfg_get clockodo contact_email); C_START=$(cfg_get clockodo start_date)
  C_TZ=$(cfg_get clockodo timezone)
  S_LOOKBACK=$(cfg_get sync lookback_days);    S_FULLH=$(cfg_get sync full_sync_hour)
  S_OWNDAYS=$(cfg_get sync own_edit_days);     S_UNCLEAR=$(cfg_get sync unclear_changes)
  S_SAMEDAY=$(cfg_get sync same_day_own);      S_INTERVAL=$(cfg_get sync interval_minutes)
  X_FILE=$(cfg_get excel filename);            X_KEEP=$(cfg_get excel backups_keep)
  NC_ON=$(cfg_get nextcloud enabled);          NC_URL=$(cfg_get nextcloud url)
  NC_USER=$(cfg_get nextcloud user);           NC_PW=$(cfg_get nextcloud app_password)
  NC_PATH=$(cfg_get nextcloud remote_path)
  M_ON=$(cfg_get mail enabled);   M_HOST=$(cfg_get mail host);  M_PORT=$(cfg_get mail port)
  M_SEC=$(cfg_get mail security); M_USER=$(cfg_get mail user);  M_PW=$(cfg_get mail password)
  M_FROM=$(cfg_get mail from);    M_TO=$(cfg_get mail to)
  M_CHG=$(cfg_get mail notify_changes); M_ERR=$(cfg_get mail notify_errors)
  M_THR=$(cfg_get mail error_threshold); M_REP=$(cfg_get mail error_repeat_hours)
  : "${S_LOOKBACK:=35}" "${S_FULLH:=3}" "${S_UNCLEAR:=mark}" "${S_SAMEDAY:=yes}" "${S_INTERVAL:=60}"
  : "${X_FILE:=Clockodo-Zeiten.xlsx}" "${X_KEEP:=30}" "${NC_ON:=yes}" "${NC_PATH:=/Zeiterfassung/Clockodo-Zeiten.xlsx}"
  : "${M_ON:=yes}" "${M_PORT:=587}" "${M_SEC:=starttls}" "${M_CHG:=yes}" "${M_ERR:=yes}" "${M_THR:=2}" "${M_REP:=24}"
}

write_config() {
  umask 027
  cat > "$CONF.tmp" <<EOF
# clockodo-sync Konfiguration – erstellt/geändert am $(date '+%d.%m.%Y %H:%M') durch das Setup
# Ändern am einfachsten mit:  sudo clockodo-sync-setup

[clockodo]
email = $C_EMAIL
api_key = $C_KEY
# Kontakt für den Pflicht-Header X-Clockodo-External-Application
contact_email = $C_CONTACT
app_name = clockodo-sync
base_url = https://my.clockodo.com/api
# Ab wann importieren (JJJJ-MM-TT). Leer = Eintrittsdatum aus Clockodo
start_date = $C_START
# Leer = Zeitzone aus deinem Clockodo-Profil
timezone = $C_TZ

[sync]
# Stündlicher Lauf prüft heute + so viele Tage zurück (für nachträgliche Änderungen)
lookback_days = $S_LOOKBACK
# Ab dieser Uhrzeit wird 1x täglich der komplette Zeitraum abgeglichen
full_sync_hour = $S_FULLH
# Eigene Bearbeitungsfrist in Tagen. Leer = aus Clockodo (Bearbeitungssperre)
own_edit_days = $S_OWNDAYS
# Änderungen innerhalb der Frist: mark = gelb markieren + melden, own = als eigene werten
unclear_changes = $S_UNCLEAR
# Änderungen am selben Tag als eigene Korrektur werten (yes/no)
same_day_own = $S_SAMEDAY
# nur zur Info, der Zeitplan steht in $CRON_FILE
interval_minutes = $S_INTERVAL

[excel]
filename = $X_FILE
# Anzahl täglicher lokaler Sicherungen in $DATA_DIR/backups
backups_keep = $X_KEEP

[nextcloud]
enabled = $NC_ON
url = $NC_URL
user = $NC_USER
app_password = $NC_PW
remote_path = $NC_PATH

[mail]
enabled = $M_ON
host = $M_HOST
port = $M_PORT
# starttls | ssl | none
security = $M_SEC
user = $M_USER
password = $M_PW
from = $M_FROM
to = $M_TO
notify_changes = $M_CHG
notify_errors = $M_ERR
# Fehler-Mail erst nach so vielen Fehlversuchen in Folge, dann höchstens alle X Stunden
error_threshold = $M_THR
error_repeat_hours = $M_REP

[paths]
data_dir = $DATA_DIR
log_dir = $LOG_DIR
EOF
  mv "$CONF.tmp" "$CONF"
  chown root:"$SVC_USER" "$CONF"; chmod 640 "$CONF"
  umask 022
}

json_field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=d.get(sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null; }

configure_clockodo() {
  head1 "Clockodo-Zugang"
  echo "Den API-Schlüssel findest du in Clockodo unter: Persönliche Daten → API-Schlüssel."
  echo "${Y}Hinweis:${N} Bei einer Passwortänderung in Clockodo wird der API-Schlüssel ungültig."
  while true; do
    ask_required C_EMAIL "Clockodo-Login (E-Mail)" "$C_EMAIL"
    ask_secret C_KEY "API-Schlüssel" "$C_KEY"
    [ -z "$C_KEY" ] && { warn "API-Schlüssel erforderlich."; continue; }
    ask C_CONTACT "Kontakt-E-Mail für die API-Kennung" "${C_CONTACT:-$C_EMAIL}"
    write_config
    info "Prüfe Anmeldung bei Clockodo …"
    ME=$(run_app whoami 2>/dev/null)
    if [ -n "$(json_field "$ME" id)" ]; then
      ok "Angemeldet als ${B}$(json_field "$ME" name)${N} (ID $(json_field "$ME" id), Rolle $(json_field "$ME" role))"
      break
    fi
    err "Anmeldung fehlgeschlagen: $(json_field "$ME" error)"
    ask_yn again "Nochmal eingeben?" j; [ "$again" = yes ] || break
  done
  local api_start api_tz
  api_start=$(json_field "${ME:-}" start_date); api_tz=$(json_field "${ME:-}" timezone)
  echo
  echo "Beim ersten Start werden ${B}alle bisherigen Zeiten${N} importiert."
  [ -n "$api_start" ] && echo "Dein Eintrittsdatum laut Clockodo: $api_start"
  while true; do
    ask C_START "Import ab Datum (JJJJ-MM-TT, leer = Eintrittsdatum)" "$C_START"
    [ -z "$C_START" ] || date -d "$C_START" >/dev/null 2>&1 && break
    warn "Ungültiges Datum."
  done
  if [ -z "$C_START" ] && [ -z "$api_start" ]; then
    C_START="$(( $(date +%Y) - 2 ))-01-01"; warn "Kein Eintrittsdatum in Clockodo – verwende $C_START."
  fi
  ask C_TZ "Zeitzone (leer = aus Clockodo: ${api_tz:-Europe/Berlin})" "$C_TZ"
}

configure_detection() {
  head1 "Erkennung von Änderungen durch Chef/HR"
  cat <<EOF
Clockodo verrät über die API leider nicht, ${B}wer${N} eine Zeit geändert hat. Das Script
erkennt Fremdänderungen deshalb über deine ${B}Bearbeitungsfrist${N}: Wurde ein Tag geändert,
der für dich schon gesperrt war, kann das nur Chef/HR gewesen sein → ${R}rot markiert${N}.
Änderungen innerhalb deiner Frist können von dir ODER Chef/HR sein.
EOF
  local wt dyn el
  wt=$(json_field "${ME:-}" work_time_edit_lock_days); dyn=$(json_field "${ME:-}" edit_lock_dyn); el=$(json_field "${ME:-}" edit_lock)
  echo
  echo "Deine Bearbeitungssperre laut Clockodo: Arbeitszeit=${wt:-–} Tage, allgemein=${dyn:-–} Tage, fest bis=${el:-–}"
  if [ -z "$wt$dyn$el" ]; then
    warn "In Clockodo ist für dich keine Bearbeitungssperre hinterlegt. Fremdänderungen lassen sich dann"
    warn "nur sicher erkennen, wenn du hier angibst, wie viele Tage rückwirkend DU Zeiten ändern darfst."
  fi
  ask S_OWNDAYS "Eigene Bearbeitungsfrist in Tagen überschreiben (leer = aus Clockodo)" "$S_OWNDAYS"
  echo
  echo "Was soll mit Änderungen INNERHALB deiner Frist passieren?"
  echo "  1) ${Y}gelb markieren${N} + per E-Mail melden – du bestätigst eigene mit einem x in der Excel (empfohlen)"
  echo "  2) automatisch als eigene Änderung werten (nur sichere Fremdänderungen werden markiert)"
  local d=1; [ "$S_UNCLEAR" = own ] && d=2
  ask ch "Auswahl" "$d"; [ "$ch" = 2 ] && S_UNCLEAR=own || S_UNCLEAR=mark
  local sd=j; [ "$S_SAMEDAY" = no ] && sd=n
  ask_yn S_SAMEDAY "Änderungen am selben Tag (z. B. vergessen auszustempeln) als eigene werten?" "$sd"
}

configure_sync() {
  head1 "Zeitplan"
  echo "Wie oft soll Clockodo abgefragt werden?  15 / 30 / 60 Minuten (Standard: 60)"
  while true; do
    ask S_INTERVAL "Intervall in Minuten" "$S_INTERVAL"
    case "$S_INTERVAL" in 15|30|60) break;; *) warn "Bitte 15, 30 oder 60 eingeben.";; esac
  done
  ask S_LOOKBACK "Bei jedem Lauf so viele Tage rückwirkend prüfen" "$S_LOOKBACK"
  ask S_FULLH "Täglicher Komplett-Abgleich ab Uhrzeit (0–23)" "$S_FULLH"
}

configure_nextcloud() {
  head1 "Nextcloud-Upload"
  local d=j; [ "$NC_ON" = no ] && d=n
  ask_yn NC_ON "Excel-Datei auf Nextcloud hochladen?" "$d"
  [ "$NC_ON" = yes ] || return 0
  echo "Tipp: Lege in Nextcloud ein ${B}App-Passwort${N} an: Einstellungen → Sicherheit → 'Neues App-Passwort erstellen'."
  while true; do
    ask_required NC_URL "Nextcloud-Adresse (z. B. https://cloud.example.de)" "$NC_URL"
    NC_URL="${NC_URL%/}"; [[ "$NC_URL" =~ ^https?:// ]] || NC_URL="https://$NC_URL"
    ask_required NC_USER "Nextcloud-Benutzername (Login-Name, nicht E-Mail falls abweichend)" "$NC_USER"
    ask_secret NC_PW "App-Passwort" "$NC_PW"
    ask NC_PATH "Zielpfad der Excel in Nextcloud" "$NC_PATH"
    [[ "$NC_PATH" == /* ]] || NC_PATH="/$NC_PATH"
    [[ "$NC_PATH" == *.xlsx ]] || NC_PATH="${NC_PATH%/}/$X_FILE"
    info "Prüfe Nextcloud-Zugang …"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NC_USER:$NC_PW" -X PROPFIND -H 'Depth: 0' \
           "$NC_URL/remote.php/dav/files/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$NC_USER")/" 2>/dev/null)
    case "$code" in
      207) ok "Nextcloud-Zugang funktioniert"; break;;
      401) err "Anmeldung abgelehnt (Benutzer/App-Passwort prüfen).";;
      000) err "Server nicht erreichbar (Adresse/DNS/Firewall prüfen).";;
      *)   err "Unerwartete Antwort: HTTP $code";;
    esac
    ask_yn again "Nochmal eingeben?" j; [ "$again" = yes ] || break
  done
}

configure_mail() {
  head1 "E-Mail-Benachrichtigung"
  echo "Du bekommst eine E-Mail bei Änderungen durch Chef/HR (bzw. unklaren Änderungen) und bei API-Problemen."
  local d=j; [ "$M_ON" = no ] && d=n
  ask_yn M_ON "E-Mail-Benachrichtigung aktivieren?" "$d"
  [ "$M_ON" = yes ] || return 0
  ask_required M_HOST "SMTP-Server (z. B. smtp.example.de)" "$M_HOST"
  echo "Verschlüsselung: 1) STARTTLS (Port 587)  2) SSL/TLS (Port 465)  3) keine (Port 25)"
  local d2=1; [ "$M_SEC" = ssl ] && d2=2; [ "$M_SEC" = none ] && d2=3
  ask ch "Auswahl" "$d2"
  case "$ch" in 2) M_SEC=ssl; dp=465;; 3) M_SEC=none; dp=25;; *) M_SEC=starttls; dp=587;; esac
  [ "$M_PORT" = 587 ] || [ "$M_PORT" = 465 ] || [ "$M_PORT" = 25 ] && M_PORT=$dp
  ask M_PORT "SMTP-Port" "$M_PORT"
  ask M_USER "SMTP-Benutzer (leer = ohne Anmeldung)" "$M_USER"
  [ -n "$M_USER" ] && ask_secret M_PW "SMTP-Passwort" "$M_PW"
  ask_required M_FROM "Absender-Adresse" "${M_FROM:-$M_USER}"
  ask_required M_TO "Empfänger (mehrere mit Komma)" "${M_TO:-$C_EMAIL}"
  local a=j b=j; [ "$M_CHG" = no ] && a=n; [ "$M_ERR" = no ] && b=n
  ask_yn M_CHG "Bei Änderungen durch Chef/HR benachrichtigen?" "$a"
  ask_yn M_ERR "Bei API-/Upload-Problemen benachrichtigen?" "$b"
  write_config
  ask_yn t "Jetzt Test-E-Mail senden?" j
  [ "$t" = yes ] && run_app testmail
}

# --------------------------------------------------------- Cronjob -----------
install_cron() {
  head1 "Cronjob einrichten"
  local minute sched
  case "$S_INTERVAL" in
    15) sched="*/15 * * * *";;
    30) minute=$(( RANDOM % 30 )); sched="$minute,$(( minute + 30 )) * * * *";;
    *)  minute=$(( RANDOM % 55 + 2 )); sched="$minute * * * *";;
  esac
  # bestehende Minute bei gleichem Intervall beibehalten
  if [ -f "$CRON_FILE" ] && [ "${KEEP_CRON:-no}" = yes ]; then
    sched=$(awk '!/^#/ && /clockodo-sync run/ {print $1,$2,$3,$4,$5; exit}' "$CRON_FILE")
  fi
  cat > "$CRON_FILE" <<EOF
# clockodo-sync – Abgleich Clockodo -> Excel -> Nextcloud (erstellt durch Setup am $(date '+%d.%m.%Y %H:%M'))
# Ändern mit: sudo clockodo-sync-setup
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$sched $SVC_USER /usr/bin/flock -n $DATA_DIR/.cron.lock $WRAPPER run >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"
  ok "Cronjob: $CRON_FILE  (Zeitplan: $sched, Benutzer: $SVC_USER)"
  ensure_cron_running
}

ensure_cron_running() {
  detect_env
  if pgrep -x cron >/dev/null 2>&1; then ok "Cron-Dienst läuft"; return; fi
  if [ "$HAS_SYSTEMD" = yes ]; then
    systemctl enable --now cron >/dev/null 2>&1 && ok "Cron-Dienst gestartet (systemd)" && return
  fi
  if command -v service >/dev/null && service cron start >/dev/null 2>&1; then ok "Cron-Dienst gestartet"
  else /usr/sbin/cron 2>/dev/null && ok "Cron-Dienst gestartet"; fi
  if [ "$IN_DOCKER" = yes ]; then
    warn "Docker-Container ohne Init-System: Cron läuft nur, solange er gestartet ist."
    warn "Nach einem Container-Neustart musst du cron erneut starten, z. B. im Entrypoint/CMD:"
    warn "    cron && <dein-dienst>     oder als Hauptprozess:   cron -f"
  fi
  pgrep -x cron >/dev/null 2>&1 || warn "Cron-Dienst läuft NICHT – bitte manuell starten (service cron start)."
}

# ------------------------------------------------------ Hauptabläufe ---------
do_install() {
  need_root; check_os; detect_env
  head1 "clockodo-sync – Einrichtung"
  echo "System: $OS_NAME · Umgebung: $ENV_TYPE · Host: $(hostname)"
  echo "Was passiert: Pakete installieren, Benutzer '$SVC_USER' anlegen, Zugänge abfragen,"
  echo "alle bisherigen Zeiten importieren und einen Cronjob einrichten."
  ask_yn go "Starten?" j; [ "$go" = yes ] || exit 0
  install_packages
  create_user_dirs
  extract_program
  load_current
  configure_clockodo
  configure_detection
  configure_sync
  configure_nextcloud
  write_config
  configure_mail
  write_config
  head1 "Verbindungstest"
  run_app test
  head1 "Erstimport aller bisherigen Daten"
  info "Das kann je nach Zeitraum ein bis zwei Minuten dauern …"
  if run_app -v run --full; then ok "Erstimport abgeschlossen"; else warn "Erstimport mit Problemen – Details siehe oben bzw. 'clockodo-sync status'"; fi
  install_cron
  summary
}

summary() {
  head1 "Fertig"
  echo "Excel lokal:      $DATA_DIR/$(cfg_get excel filename)"
  [ "$(cfg_get nextcloud enabled)" = yes ] && echo "Excel Nextcloud:  $(cfg_get nextcloud url) → $(cfg_get nextcloud remote_path)"
  echo "Konfiguration:    $CONF"
  echo "Log:              $LOG_DIR/sync.log"
  echo
  echo "Nützliche Befehle:"
  echo "  sudo clockodo-sync-setup         Menü (Einstellungen, Test, Status, Deinstallation …)"
  echo "  sudo clockodo-sync status        Status & letzte Läufe"
  echo "  sudo clockodo-sync run           Jetzt abgleichen"
  echo "  sudo clockodo-sync changes       Erkannte Änderungen anzeigen"
  echo "  sudo clockodo-sync confirm 2026-10-22   Änderung eines Tages als eigene bestätigen"
}

do_update() {
  need_root
  is_installed || { err "Noch nicht installiert – starte Einrichtung."; do_install; return; }
  extract_program
  load_current; write_config  # ergänzt ggf. neue Einstellungen mit Standardwerten
  ok "Aktualisiert. Konfiguration und Daten wurden übernommen."
  run_app test
}

do_uninstall() {
  need_root
  head1 "Deinstallieren"
  ask_yn s "clockodo-sync wirklich entfernen?" n; [ "$s" = yes ] || return
  rm -f "$CRON_FILE" "$WRAPPER" "$SETUP_LINK"
  local keep
  ask_yn keep "Konfiguration, Datenbank und Excel-Sicherungen behalten?" j
  if [ "$keep" = no ]; then
    rm -rf "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
    id "$SVC_USER" >/dev/null 2>&1 && userdel "$SVC_USER" 2>/dev/null
    ok "Alles entfernt (die Datei auf Nextcloud bleibt bestehen)."
  else
    ok "Programm entfernt. Erhalten: $CONF_DIR, $DATA_DIR, $LOG_DIR"
  fi
  rm -rf "$OPT_DIR"
  exit 0
}

do_backup() {
  local f="/root/clockodo-sync-backup-$(date +%Y%m%d-%H%M).tar.gz"
  tar czf "$f" "$CONF_DIR" "$DATA_DIR" 2>/dev/null && chmod 600 "$f" && ok "Sicherung erstellt: $f" || err "Sicherung fehlgeschlagen"
}

do_reset() {
  warn "Die lokale Datenbank wird gelöscht und alles neu aus Clockodo importiert."
  warn "Bereits erkannte Änderungen und deine Bestätigungen gehen dabei verloren (Notizen werden aus der Excel neu eingelesen)."
  ask_yn s "Fortfahren?" n; [ "$s" = yes ] || return
  do_backup
  rm -f "$DATA_DIR/state.db"
  run_app -v run --full
}

settings_menu() {
  load_current
  while true; do
    head1 "Einstellungen ändern"
    echo " 1) Clockodo-Zugang / Startdatum / Zeitzone"
    echo " 2) Erkennung von Fremdänderungen"
    echo " 3) Zeitplan (Intervall, Rückblick)"
    echo " 4) Nextcloud"
    echo " 5) E-Mail"
    echo " 0) Zurück"
    ask c "Auswahl" 0
    case "$c" in
      1) ME=$(run_app whoami 2>/dev/null); configure_clockodo; write_config;;
      2) ME=$(run_app whoami 2>/dev/null); configure_detection; write_config;;
      3) configure_sync; write_config; install_cron;;
      4) configure_nextcloud; write_config;;
      5) configure_mail; write_config;;
      0) return;;
    esac
    ok "Gespeichert."
  done
}

menu() {
  need_root
  while true; do
    head1 "clockodo-sync – Verwaltung ($(hostname))"
    local sched; sched=$(awk '!/^#/ && /clockodo-sync run/ {print $1,$2,$3,$4,$5; exit}' "$CRON_FILE" 2>/dev/null)
    echo "Cronjob: ${sched:-${R}nicht eingerichtet${N}}   ·   Konfiguration: $CONF"
    echo
    echo "  1) Status anzeigen                 8) Test-E-Mail senden"
    echo "  2) Jetzt abgleichen                9) Log anzeigen"
    echo "  3) Verbindungen testen            10) Cronjob neu einrichten / Cron starten"
    echo "  4) Offene Änderungen anzeigen     11) Sicherung erstellen (Config + Daten)"
    echo "  5) Änderung als eigene bestätigen 12) Datenbank zurücksetzen + neu importieren"
    echo "  6) Einstellungen ändern           13) Programm aktualisieren (aus diesem Setup)"
    echo "  7) Komplett-Abgleich aller Daten  14) Einrichtungsassistent komplett neu"
    echo "                                    15) Deinstallieren"
    echo "  0) Beenden"
    ask c "Auswahl" 1
    case "$c" in
      1) run_app status; pause;;
      2) run_app -v run; pause;;
      3) run_app test --mail; pause;;
      4) run_app changes --open; pause;;
      5) ask dd "Datum (JJJJ-MM-TT)" "$(date +%F)"; run_app -v confirm "$dd"; pause;;
      6) settings_menu;;
      7) run_app -v run --full; pause;;
      8) run_app testmail; pause;;
      9) tail -n 60 "$LOG_DIR/sync.log" 2>/dev/null || warn "Noch kein Log vorhanden"; pause;;
      10) load_current; KEEP_CRON=no install_cron; pause;;
      11) do_backup; pause;;
      12) do_reset; pause;;
      13) do_update; pause;;
      14) do_install; pause;;
      15) do_uninstall;;
      0) exit 0;;
    esac
  done
}

# ------------------------------------------------------------- Start ---------
case "${1:-}" in
  --install)   do_install ;;
  --update)    do_update ;;
  --uninstall) do_uninstall ;;
  --status)    run_app status ;;
  -h|--help)   sed -n '2,13p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  "")          need_root; if is_installed; then menu; else do_install; fi ;;
  *)           err "Unbekannte Option: $1 (--help)"; exit 1 ;;
esac
exit 0

__PYTHON_PAYLOAD_BELOW__
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
clockodo-sync – liest deine Arbeitszeiten (Kommen, Gehen, Pausen) aus Clockodo,
pflegt sie in eine Excel-Datei (ein Blatt pro Monat) und lädt sie auf Nextcloud hoch.

Befehle:
  clockodo-sync run            Normaler Lauf (Cronjob): heute + Rückblick-Tage
  clockodo-sync run --full     Kompletter Abgleich aller Daten seit Startdatum
  clockodo-sync test [--mail]  Verbindungen prüfen (Clockodo, Nextcloud, optional E-Mail)
  clockodo-sync status         Status, letzte Läufe, offene Änderungen
  clockodo-sync changes        Erkannte Änderungen auflisten
  clockodo-sync confirm DATUM  Änderungen eines Tages als "von mir" bestätigen (--undo zum Zurücknehmen)
  clockodo-sync excel          Excel nur neu erzeugen + hochladen (ohne API-Abruf)
  clockodo-sync testmail       Test-E-Mail senden
"""

import argparse
import configparser
import datetime as dt
import fcntl
import json
import logging
import os
import re
import shutil
import smtplib
import socket
import sqlite3
import ssl
import subprocess
import sys
import time
from email.message import EmailMessage
from logging.handlers import RotatingFileHandler
from urllib.parse import quote

try:
    from zoneinfo import ZoneInfo
except ImportError:  # Python < 3.9
    sys.exit("Python 3.9 oder neuer wird benötigt.")

import requests
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

VERSION = "1.0.0"
APP_NAME = "clockodo-sync"
DEFAULT_CONFIG = os.environ.get("CLOCKODO_SYNC_CONFIG", "/etc/clockodo-sync/config.ini")
CRON_FILE = "/etc/cron.d/clockodo-sync"
UTC = dt.timezone.utc
TOLERANCE_SEC = 300          # 5 Min.: Abstand, ab dem ein gestempelter Eintrag als "nachträglich bearbeitet" gilt
WEEKDAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
ABSENCE_NAMES = {
    "regular_holidays": "Urlaub",
    "sick_self": "Krank",
    "sick_child": "Kind krank",
    "special_leaves": "Sonderurlaub",
    "school": "Schule/Weiterbildung",
    "maternity_protection": "Mutterschutz",
    "home_office": "Homeoffice",
    "out_of_office": "Außer Haus",
    "quarantine": "Quarantäne",
    "military_service": "Wehrdienst",
}

log = logging.getLogger(APP_NAME)


# --------------------------------------------------------------------------- #
# Konfiguration
# --------------------------------------------------------------------------- #
DEFAULTS = {
    "clockodo": {
        "email": "", "api_key": "", "contact_email": "", "app_name": "clockodo-sync",
        "base_url": "https://my.clockodo.com/api", "start_date": "", "timezone": "",
    },
    "sync": {
        "lookback_days": "35", "full_sync_hour": "3", "own_edit_days": "",
        "unclear_changes": "mark", "same_day_own": "yes",
    },
    "excel": {"filename": "Clockodo-Zeiten.xlsx", "backups_keep": "30"},
    "nextcloud": {"enabled": "no", "url": "", "user": "", "app_password": "",
                  "remote_path": "/Zeiterfassung/Clockodo-Zeiten.xlsx"},
    "mail": {"enabled": "no", "host": "", "port": "587", "security": "starttls", "user": "",
             "password": "", "from": "", "to": "", "notify_changes": "yes", "notify_errors": "yes",
             "error_threshold": "2", "error_repeat_hours": "24"},
    "paths": {"data_dir": "/var/lib/clockodo-sync", "log_dir": "/var/log/clockodo-sync"},
}


class Config:
    def __init__(self, path):
        self.path = path
        self.cp = configparser.ConfigParser(interpolation=None)
        self.cp.read_dict(DEFAULTS)
        if not os.path.exists(path):
            raise SystemExit(f"Konfiguration nicht gefunden: {path} – bitte zuerst das Setup ausführen.")
        self.cp.read(path, encoding="utf-8")

    def get(self, sec, key):
        return self.cp.get(sec, key, fallback="").strip()

    def getint(self, sec, key, default=0):
        v = self.get(sec, key)
        try:
            return int(v)
        except ValueError:
            return default

    def getbool(self, sec, key):
        return self.get(sec, key).lower() in ("1", "yes", "ja", "true", "on")

    @property
    def data_dir(self):
        return self.get("paths", "data_dir")

    @property
    def excel_path(self):
        return os.path.join(self.data_dir, self.get("excel", "filename") or "Clockodo-Zeiten.xlsx")


# --------------------------------------------------------------------------- #
# Hilfsfunktionen
# --------------------------------------------------------------------------- #
def parse_ts(s):
    if not s:
        return None
    return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00"))


def iso_utc(d):
    return d.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_utc():
    return dt.datetime.now(UTC).replace(microsecond=0)


def d_parse(s):
    return dt.date.fromisoformat(s)


def daterange(a, b):
    d = a
    while d <= b:
        yield d
        d += dt.timedelta(days=1)


def fmt_hm(ts, tz):
    return ts.astimezone(tz).strftime("%H:%M") if ts else ""


def fmt_dt(ts, tz):
    return ts.astimezone(tz).strftime("%d.%m.%Y %H:%M") if ts else ""


def fmt_span(since, until, tz):
    s, u = parse_ts(since), parse_ts(until)
    return f"{fmt_hm(s, tz)}–{fmt_hm(u, tz) if u else 'läuft'}"


def fmt_hours(sec):
    sec = int(round(sec))
    return f"{sec // 3600}:{(sec % 3600) // 60:02d}"


def short_err(e):
    msg = str(e).strip().replace("\n", " ")
    return msg[:400]


# --------------------------------------------------------------------------- #
# Datenbank (Zustand zwischen den Läufen)
# --------------------------------------------------------------------------- #
SCHEMA = """
CREATE TABLE IF NOT EXISTS days(date TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, date TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS changes(
    id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, entry_id INTEGER,
    detected_at TEXT NOT NULL, changed_at TEXT, kind TEXT NOT NULL, before TEXT, after TEXT,
    classification TEXT NOT NULL, reason TEXT, historical INTEGER DEFAULT 0,
    confirmed INTEGER DEFAULT 0, confirmed_gen INTEGER, seen_gen INTEGER, notified INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS notes(date TEXT PRIMARY KEY, note TEXT);
CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY AUTOINCREMENT, started TEXT, finished TEXT,
    mode TEXT, status TEXT, message TEXT, duration REAL);
CREATE TABLE IF NOT EXISTS errors(id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, area TEXT, message TEXT);
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX IF NOT EXISTS idx_entries_date ON entries(date);
CREATE INDEX IF NOT EXISTS idx_changes_date ON changes(date);
"""


class DB:
    def __init__(self, path):
        self.con = sqlite3.connect(path, timeout=30)
        self.con.row_factory = sqlite3.Row
        self.con.executescript(SCHEMA)
        self.con.commit()

    def meta(self, key, default=None):
        r = self.con.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return r["value"] if r else default

    def set_meta(self, key, value):
        self.con.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
                         (key, None if value is None else str(value)))

    def commit(self):
        self.con.commit()

    def add_error(self, area, message):
        self.con.execute("INSERT INTO errors(ts,area,message) VALUES(?,?,?)",
                         (iso_utc(now_utc()), area, message))
        # nur die letzten 500 Fehler behalten
        self.con.execute("DELETE FROM errors WHERE id NOT IN (SELECT id FROM errors ORDER BY id DESC LIMIT 500)")
        self.commit()


# --------------------------------------------------------------------------- #
# Clockodo-API
# --------------------------------------------------------------------------- #
class ClockodoError(Exception):
    pass


class Clockodo:
    def __init__(self, cfg):
        self.base = cfg.get("clockodo", "base_url").rstrip("/")
        email = cfg.get("clockodo", "email")
        key = cfg.get("clockodo", "api_key")
        if not email or not key:
            raise ClockodoError("Clockodo-E-Mail oder API-Key fehlt in der Konfiguration.")
        contact = cfg.get("clockodo", "contact_email") or email
        self.s = requests.Session()
        self.s.headers.update({
            "X-ClockodoApiUser": email,
            "X-ClockodoApiKey": key,
            "X-Clockodo-External-Application": f"{cfg.get('clockodo', 'app_name') or APP_NAME};{contact}",
            "Accept-Language": "de",
            "Accept": "application/json",
            "User-Agent": f"{APP_NAME}/{VERSION}",
        })

    def get(self, path, params=None):
        url = f"{self.base}/{path.lstrip('/')}"
        last = None
        for attempt in range(5):
            try:
                r = self.s.get(url, params=params, timeout=40)
            except requests.RequestException as e:
                last = f"Verbindung zu Clockodo fehlgeschlagen: {e}"
                time.sleep(2 ** attempt)
                continue
            if r.status_code == 200:
                try:
                    return r.json()
                except ValueError:
                    raise ClockodoError(f"Ungültige Antwort von Clockodo ({path})")
            if r.status_code == 429 or r.status_code >= 500:
                wait = int(r.headers.get("Retry-After", 0) or 0) or 2 ** (attempt + 1)
                last = f"HTTP {r.status_code} von Clockodo ({path})"
                time.sleep(min(wait, 60))
                continue
            detail = ""
            try:
                j = r.json()
                detail = (j.get("error") or {}).get("message", "") if isinstance(j.get("error"), dict) else str(j.get("error", ""))
                detail = detail or j.get("message", "")
            except ValueError:
                detail = r.text[:200]
            hint = {401: "Anmeldung fehlgeschlagen – E-Mail/API-Key prüfen (API-Key wird bei Passwortänderung ungültig!)",
                    403: "Keine Berechtigung für diese Daten",
                    404: "Endpunkt nicht gefunden"}.get(r.status_code, "")
            raise ClockodoError(f"HTTP {r.status_code} bei {path}: {hint} {detail}".strip())
        raise ClockodoError(last or f"Clockodo nicht erreichbar ({path})")

    def me(self):
        j = self.get("v4/users/me")
        return j.get("data") or j.get("user") or j

    def user(self, uid):
        j = self.get(f"v3/users/{uid}")
        return j.get("data") or j.get("user") or j

    def work_times(self, uid, d_from, d_to):
        out = []
        cur = d_from
        while cur <= d_to:
            end = min(cur + dt.timedelta(days=89), d_to)
            j = self.get("v2/workTimes", {"users_id": uid, "date_since": cur.isoformat(), "date_until": end.isoformat()})
            out.extend(j.get("work_time_days") or [])
            cur = end + dt.timedelta(days=1)
        return out

    def entries(self, uid, t_from, t_to):
        out = []
        cur = t_from
        while cur < t_to:
            end = min(cur + dt.timedelta(days=31), t_to)
            page = 1
            while True:
                j = self.get("v2/entries", {"time_since": iso_utc(cur), "time_until": iso_utc(end),
                                            "filter[users_id]": uid, "items_per_page": 1000, "page": page})
                out.extend(j.get("entries") or [])
                paging = j.get("paging") or {}
                if page >= int(paging.get("count_pages") or 1):
                    break
                page += 1
            cur = end
        return out

    def user_report(self, uid, year):
        j = self.get(f"userreports/{uid}", {"year": year, "type": 4})
        return j.get("userreport") or {}


# --------------------------------------------------------------------------- #
# Nextcloud (WebDAV)
# --------------------------------------------------------------------------- #
class NextcloudError(Exception):
    pass


class Nextcloud:
    def __init__(self, cfg):
        self.url = cfg.get("nextcloud", "url").rstrip("/")
        self.user = cfg.get("nextcloud", "user")
        self.remote = "/" + cfg.get("nextcloud", "remote_path").lstrip("/")
        self.auth = (self.user, cfg.get("nextcloud", "app_password"))
        self.dav = f"{self.url}/remote.php/dav/files/{quote(self.user)}"

    def _u(self, path):
        return self.dav + quote(path)

    def _req(self, method, path, **kw):
        try:
            return requests.request(method, self._u(path), auth=self.auth, timeout=60, **kw)
        except requests.RequestException as e:
            raise NextcloudError(f"Nextcloud nicht erreichbar: {e}")

    @staticmethod
    def _check(r, what):
        if r.status_code == 401:
            raise NextcloudError(f"{what}: Anmeldung fehlgeschlagen (Benutzer/App-Passwort prüfen)")
        if r.status_code == 423:
            raise NextcloudError(f"{what}: Datei ist gesperrt (gerade in Nextcloud Office geöffnet?) – nächster Versuch beim nächsten Lauf")
        if r.status_code == 507:
            raise NextcloudError(f"{what}: Speicherplatz auf Nextcloud voll")
        if r.status_code >= 400:
            raise NextcloudError(f"{what}: HTTP {r.status_code} {r.reason}")

    def test(self):
        r = self._req("PROPFIND", "/", headers={"Depth": "0"})
        self._check(r, "Nextcloud-Test")

    def ensure_dirs(self):
        parts = [p for p in self.remote.split("/")[:-1] if p]
        cur = ""
        for p in parts:
            cur += "/" + p
            r = self._req("MKCOL", cur)
            if r.status_code not in (201, 405):  # 405 = existiert bereits
                self._check(r, f"Ordner {cur} anlegen")

    def download(self, local):
        r = self._req("GET", self.remote)
        if r.status_code == 404:
            return False
        self._check(r, "Download")
        with open(local, "wb") as f:
            f.write(r.content)
        return True

    def upload(self, local, remote=None):
        self.ensure_dirs()
        with open(local, "rb") as f:
            r = self._req("PUT", remote or self.remote, data=f,
                          headers={"Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"})
        self._check(r, "Upload")

    def delete(self, remote):
        self._req("DELETE", remote)


# --------------------------------------------------------------------------- #
# E-Mail
# --------------------------------------------------------------------------- #
def send_mail(cfg, subject, body):
    host = cfg.get("mail", "host")
    port = cfg.getint("mail", "port", 587)
    sec = (cfg.get("mail", "security") or "starttls").lower()
    sender = cfg.get("mail", "from") or cfg.get("mail", "user")
    rcpts = [a.strip() for a in re.split(r"[,;\s]+", cfg.get("mail", "to")) if a.strip()]
    if not host or not rcpts or not sender:
        raise RuntimeError("E-Mail ist nicht vollständig konfiguriert (Server/Absender/Empfänger).")
    msg = EmailMessage()
    msg["Subject"] = f"[Clockodo-Sync] {subject}"
    msg["From"] = sender
    msg["To"] = ", ".join(rcpts)
    msg["Date"] = dt.datetime.now().astimezone().strftime("%a, %d %b %Y %H:%M:%S %z")
    msg.set_content(body + f"\n\n--\nclockodo-sync {VERSION} auf {socket.gethostname()}\n")
    ctx = ssl.create_default_context()
    if sec == "ssl":
        srv = smtplib.SMTP_SSL(host, port, timeout=30, context=ctx)
    else:
        srv = smtplib.SMTP(host, port, timeout=30)
        if sec == "starttls":
            srv.starttls(context=ctx)
    try:
        if cfg.get("mail", "user"):
            srv.login(cfg.get("mail", "user"), cfg.get("mail", "password"))
        srv.send_message(msg, from_addr=sender, to_addrs=rcpts)
    finally:
        try:
            srv.quit()
        except Exception:
            pass


# --------------------------------------------------------------------------- #
# System-Infos für die Info-Seite
# --------------------------------------------------------------------------- #
def host_info():
    info = {"hostname": socket.gethostname(), "os": platform_name(), "env": virt_type(), "ips": ""}
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout.split()
        info["ips"] = ", ".join(i for i in out if ":" not in i) or ", ".join(out)
    except Exception:
        pass
    return info


def platform_name():
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return sys.platform


def virt_type():
    try:
        r = subprocess.run(["systemd-detect-virt"], capture_output=True, text=True, timeout=5)
        v = r.stdout.strip()
        if v and v != "none":
            c = subprocess.run(["systemd-detect-virt", "-c"], capture_output=True, text=True, timeout=5).stdout.strip()
            return f"Container ({v})" if c and c != "none" else f"VM ({v})"
        if v == "none":
            return "Physischer Server / unbekannt"
    except Exception:
        pass
    if os.path.exists("/.dockerenv"):
        return "Container (docker)"
    if os.path.exists("/run/.containerenv"):
        return "Container (podman)"
    try:
        with open("/proc/1/environ", "rb") as f:
            if b"container=lxc" in f.read():
                return "Container (lxc)"
    except OSError:
        pass
    return "unbekannt"


def cron_schedule():
    try:
        with open(CRON_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "clockodo-sync" in line and not "=" in line.split()[0]:
                    return " ".join(line.split()[:5])
    except OSError:
        pass
    return ""


def next_cron_run(sched, now_local):
    """Berechnet den nächsten Lauf für einfache Muster wie '7 * * * *' oder '*/15 * * * *'."""
    try:
        minute, hour, dom, mon, dow = sched.split()
        if hour != "*" or dom != "*" or mon != "*" or dow != "*":
            return None
        if minute.startswith("*/"):
            mins = list(range(0, 60, int(minute[2:])))
        else:
            mins = sorted(int(m) for m in minute.split(","))
        t = now_local.replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
        for _ in range(60 * 25):
            if t.minute in mins:
                return t
            t += dt.timedelta(minutes=1)
    except Exception:
        return None
    return None


# --------------------------------------------------------------------------- #
# Kernlogik: Abruf, Änderungserkennung, Speicherung
# --------------------------------------------------------------------------- #
class Sync:
    def __init__(self, cfg, verbose=False):
        self.cfg = cfg
        os.makedirs(cfg.data_dir, exist_ok=True)
        self.db = DB(os.path.join(cfg.data_dir, "state.db"))
        self.now = now_utc()
        me_cached = self.db.meta("me")
        self.me = json.loads(me_cached) if me_cached else {}
        self.tz = self._tz()
        self.problems = []  # (area, message) dieses Laufs

    # ----- Grunddaten -----
    def _tz(self):
        name = self.cfg.get("clockodo", "timezone") or self.me.get("timezone") or "Europe/Berlin"
        try:
            return ZoneInfo(name)
        except Exception:
            return ZoneInfo("Europe/Berlin")

    def today(self):
        return self.now.astimezone(self.tz).date()

    def start_date(self):
        s = self.cfg.get("clockodo", "start_date") or self.me.get("start_date") or ""
        try:
            return d_parse(s[:10])
        except ValueError:
            return dt.date(self.today().year - 2, 1, 1)

    def lock_info(self):
        """Eigene Bearbeitungsfrist: Änderungen an Tagen, die älter sind, kann nur Chef/HR gemacht haben."""
        own = self.cfg.get("sync", "own_edit_days")
        if own != "":
            try:
                return {"days": int(own), "abs": None, "source": "manuell in der Konfiguration"}
            except ValueError:
                pass
        me = self.me
        days, source = None, ""
        if me.get("work_time_edit_lock_days") is not None:
            days, source = int(me["work_time_edit_lock_days"]), "Clockodo (Arbeitszeit-Bearbeitungssperre)"
        elif me.get("edit_lock_dyn") is not None:
            days, source = int(me["edit_lock_dyn"]), "Clockodo (Bearbeitungssperre)"
        abs_lock = None
        if me.get("edit_lock"):
            try:
                abs_lock = d_parse(str(me["edit_lock"])[:10])
                source = source or "Clockodo (feste Bearbeitungssperre)"
            except ValueError:
                pass
        if me.get("role") == "owner" and own == "":
            # Administratoren dürfen alles bearbeiten -> keine sichere Erkennung möglich
            return {"days": None, "abs": None, "source": "keine (du bist Administrator)"}
        return {"days": days, "abs": abs_lock, "source": source or "keine Sperre hinterlegt"}

    def lock_text(self):
        li = self.lock_info()
        parts = []
        if li["days"] is not None:
            parts.append(f"{li['days']} Tage")
        if li["abs"]:
            parts.append(f"Tage vor {li['abs'].strftime('%d.%m.%Y')} gesperrt")
        return (", ".join(parts) or "keine") + f" – Quelle: {li['source']}"

    def boss_name(self):
        return self.db.meta("boss_name") or ""

    def next_gen(self):
        """Versionsnummer der nächsten Excel-Datei (steht im Info-Blatt, für das Wiedereinlesen)."""
        return int(self.db.meta("excel_gen", 0) or 0) + 1

    # ----- Klassifizierung -----
    def classify(self, day, changed_at, live):
        """-> (classification, reason). classification: foreign | unclear | own"""
        li = self.lock_info()
        ch_date = (changed_at or self.now).astimezone(self.tz).date()
        age = (ch_date - day).days
        if li["days"] is not None and age > li["days"] + 1:
            return "foreign", f"{age} Tage nach dem Arbeitstag geändert – außerhalb deiner Bearbeitungsfrist ({li['days']} Tage)"
        if live and li["abs"] and day < li["abs"]:
            return "foreign", f"Tag liegt vor deiner Bearbeitungssperre ({li['abs'].strftime('%d.%m.%Y')})"
        if self.cfg.getbool("sync", "same_day_own") and age == 0:
            return "own", "am selben Tag geändert – als eigene Korrektur gewertet"
        if (self.cfg.get("sync", "unclear_changes") or "mark") == "own":
            return "own", "innerhalb deiner Bearbeitungsfrist – laut Einstellung als eigene Änderung gewertet"
        return "unclear", "innerhalb deiner Bearbeitungsfrist – kann von dir oder Chef/HR sein"

    def who_text(self, cls, confirmed):
        if confirmed or cls == "own":
            return "ich"
        if cls == "foreign":
            b = self.boss_name()
            return f"Chef/HR (vermutlich {b})" if b else "Chef/HR"
        return "unklar – bitte prüfen"

    # ----- Abruf -----
    def fetch(self, full=False):
        api = Clockodo(self.cfg)
        self.me = api.me()
        self.db.set_meta("me", json.dumps(self.me))
        self.tz = self._tz()
        uid = self.me["id"]

        # Name des Vorgesetzten (einmal täglich aktualisieren, Fehler ignorieren)
        if self.me.get("boss") and self.db.meta("boss_checked") != self.today().isoformat():
            try:
                self.db.set_meta("boss_name", api.user(self.me["boss"]).get("name", ""))
            except ClockodoError as e:
                log.info("Name des Vorgesetzten nicht abrufbar (%s)", e)
            self.db.set_meta("boss_checked", self.today().isoformat())

        today = self.today()
        first_import = self.db.meta("initial_import_done") != "1"
        last_full = self.db.meta("last_full_sync", "")
        full_hour = self.cfg.getint("sync", "full_sync_hour", 3)
        now_local = self.now.astimezone(self.tz)
        if not full and last_full[:10] != today.isoformat() and now_local.hour >= full_hour:
            full = True
            log.info("Täglicher Komplett-Abgleich")
        if first_import:
            full = True
        if full:
            d_from = self.start_date()
        else:
            d_from = max(today - dt.timedelta(days=self.cfg.getint("sync", "lookback_days", 35)), self.start_date())
        d_to = today
        log.info("Abruf %s bis %s (%s)", d_from, d_to, "komplett" if full else "inkrementell")

        wt = api.work_times(uid, d_from, d_to)
        t_from = dt.datetime.combine(d_from, dt.time(0), self.tz)
        t_to = dt.datetime.combine(d_to + dt.timedelta(days=1), dt.time(0), self.tz)
        entries = [e for e in api.entries(uid, t_from, t_to) if int(e.get("type", 1)) == 1]

        reports = {}
        report_ok = True
        for year in range(d_from.year, d_to.year + 1):
            try:
                rep = api.user_report(uid, year)
                for m in rep.get("month_details") or []:
                    for w in m.get("week_details") or []:
                        for d in w.get("day_details") or []:
                            reports[d["date"]] = d
            except ClockodoError as e:
                report_ok = False
                log.warning("Soll/Saldo (userreports) %s nicht abrufbar: %s", year, e)
                self.problems.append(("clockodo-report", f"Soll/Saldo {year} nicht abrufbar: {short_err(e)}"))
        self.db.set_meta("report_ok", "1" if report_ok else "0")

        stats = self.store(d_from, d_to, wt, entries, reports, first_import)
        if full:
            self.db.set_meta("last_full_sync", now_local.strftime("%Y-%m-%dT%H:%M:%S"))
        if first_import:
            self.db.set_meta("initial_import_done", "1")
            self.db.set_meta("initial_import_at", iso_utc(self.now))
        self.db.set_meta("last_api_ok", iso_utc(self.now))
        self.db.commit()
        return full, stats

    @staticmethod
    def _entry_snapshot(e, tz):
        since = e.get("time_since")
        return {
            "id": int(e["id"]),
            "date": parse_ts(since).astimezone(tz).date().isoformat(),
            "since": since, "until": e.get("time_until"),
            "clocked": bool(e.get("clocked", e.get("time_clocked_since") is not None)),
            "offline": bool(e.get("clocked_offline")),
            "insert": e.get("time_insert"), "lchange": e.get("time_last_change"),
            "lchange_wt": e.get("time_last_change_work_time") or e.get("time_last_change"),
        }

    @staticmethod
    def _edited_after(e):
        """Wurde ein Eintrag nach dem Ausstempeln/Anlegen noch an den Zeiten bearbeitet?"""
        lw = parse_ts(e.get("lchange_wt"))
        if not lw:
            return None
        if e["clocked"]:
            if e["offline"] or not e["until"]:
                return None
            ref = parse_ts(e["until"])
        else:
            ref = parse_ts(e["insert"])
        if ref and (lw - ref).total_seconds() > TOLERANCE_SEC:
            return lw
        return None

    def store(self, d_from, d_to, work_times, entries, reports, first_import):
        tz = self.tz
        con = self.db.con
        stats = {"days": 0, "changes": 0}
        nowiso = iso_utc(self.now)

        # --- Tage (Kommen/Gehen/Pausen aus den Arbeitszeit-Intervallen) ---
        wt_by_date = {w["date"]: w for w in work_times}
        for d in daterange(d_from, d_to):
            ds = d.isoformat()
            w = wt_by_date.get(ds, {})
            rep = reports.get(ds, {})
            absence = []
            for k, v in (rep.get("count_absence") or {}).items():
                try:
                    if v and float(v) > 0:
                        name = ABSENCE_NAMES.get(k, k)
                        absence.append(name if float(v) == 1 else f"{name} ({float(v):g})")
                except (TypeError, ValueError):
                    pass
            data = {
                "intervals": [[i.get("time_since"), i.get("time_until")] for i in (w.get("intervals") or [])],
                "offset": w.get("offset") or 0,
                "target": rep.get("target"), "hours": rep.get("hours"), "diff": rep.get("diff"),
                "nonbusiness": bool(rep.get("nonbusiness")), "absence": ", ".join(absence),
            }
            old = con.execute("SELECT data FROM days WHERE date=?", (ds,)).fetchone()
            new_json = json.dumps(data, sort_keys=True)
            if not old or old["data"] != new_json:
                con.execute("INSERT OR REPLACE INTO days(date,data,updated_at) VALUES(?,?,?)", (ds, new_json, nowiso))
                stats["days"] += 1

        # --- Einträge vergleichen (Änderungserkennung) ---
        new_entries = {}
        for e in entries:
            snap = self._entry_snapshot(e, tz)
            if d_from.isoformat() <= snap["date"] <= d_to.isoformat():
                new_entries[snap["id"]] = snap
        old_entries = {r["id"]: json.loads(r["data"]) for r in con.execute(
            "SELECT id,data FROM entries WHERE date BETWEEN ? AND ?", (d_from.isoformat(), d_to.isoformat()))}
        known_ids = {r["id"] for r in con.execute("SELECT id FROM entries")}

        changes = []
        for eid, n in new_entries.items():
            day = d_parse(n["date"])
            o = old_entries.get(eid)
            if o is None and eid in known_ids:
                # Eintrag wurde auf einen anderen Tag verschoben
                prev = json.loads(con.execute("SELECT data FROM entries WHERE id=?", (eid,)).fetchone()["data"])
                changes.append((n, "Eintrag auf anderen Tag verschoben",
                                f"{prev['date']} {fmt_span(prev['since'], prev['until'], tz)}",
                                fmt_span(n["since"], n["until"], tz), parse_ts(n["lchange_wt"]), False))
            elif o is None:
                historical = first_import
                if not n["clocked"]:
                    changes.append((n, "Eintrag manuell nachgetragen", "—", fmt_span(n["since"], n["until"], tz),
                                    parse_ts(n["insert"]), historical))
                    ed = self._edited_after(n)
                    if ed:
                        changes.append((n, "Nachgetragenen Eintrag später bearbeitet", "unbekannt",
                                        fmt_span(n["since"], n["until"], tz), ed, historical))
                else:
                    ed = self._edited_after(n)
                    if ed:
                        changes.append((n, "Gestempelte Zeit nachträglich bearbeitet",
                                        "unbekannt" + (" (vor Aufzeichnungsbeginn)" if historical else ""),
                                        fmt_span(n["since"], n["until"], tz), ed, historical))
            else:
                ch_at = parse_ts(n["lchange_wt"]) or self.now
                if o["since"] != n["since"]:
                    changes.append((n, "Beginn geändert", fmt_hm(parse_ts(o["since"]), tz),
                                    fmt_hm(parse_ts(n["since"]), tz), ch_at, False))
                if o["until"] and o["until"] != n["until"]:
                    changes.append((n, "Ende geändert", fmt_hm(parse_ts(o["until"]), tz),
                                    fmt_hm(parse_ts(n["until"]), tz) if n["until"] else "läuft wieder", ch_at, False))
                elif not o["until"] and n["until"]:
                    ed = self._edited_after(n)
                    if ed:
                        changes.append((n, "Ende nachträglich eingetragen", "läuft",
                                        fmt_hm(parse_ts(n["until"]), tz), ed, False))
        for eid, o in old_entries.items():
            if eid not in new_entries:
                # gelöscht (oder auf einen Tag außerhalb des Abrufzeitraums verschoben)
                changes.append((o, "Eintrag gelöscht", fmt_span(o["since"], o["until"], tz), "—", None, False))
                con.execute("DELETE FROM entries WHERE id=?", (eid,))

        next_gen = self.next_gen()
        for snap, kind, before, after, ch_at, historical in changes:
            day = d_parse(snap["date"])
            cls, reason = self.classify(day, ch_at, live=not historical)
            con.execute(
                "INSERT INTO changes(date,entry_id,detected_at,changed_at,kind,before,after,classification,reason,"
                "historical,notified,seen_gen) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                (snap["date"], snap["id"], nowiso, iso_utc(ch_at) if ch_at else None, kind, before, after, cls, reason,
                 1 if historical else 0, 1 if historical else 0, next_gen))
            stats["changes"] += 1
            log.info("Änderung %s: %s (%s → %s) – %s", snap["date"], kind, before, after, cls)

        for eid, n in new_entries.items():
            con.execute("INSERT OR REPLACE INTO entries(id,date,data) VALUES(?,?,?)", (eid, n["date"], json.dumps(n)))
        self.db.commit()
        return stats

    # ----- Excel einlesen (Bestätigungen + Notizen aus der Datei übernehmen) -----
    def read_back(self, path):
        try:
            wb = load_workbook(path, data_only=True, read_only=True)
        except Exception as e:
            log.warning("Excel konnte nicht gelesen werden (%s) – Notizen/Bestätigungen werden diesmal nicht übernommen", e)
            return
        con = self.db.con
        n_notes = n_conf = 0
        # Welche Version der Datei liegt vor? (nur dann sind x-Markierungen eindeutig zuordenbar)
        file_gen = None
        if "Info" in wb.sheetnames:
            for row in wb["Info"].iter_rows(values_only=True):
                if row and row[0] == "Datei-Version (intern)":
                    try:
                        file_gen = int(row[1])
                    except (TypeError, ValueError):
                        pass
                    break
        if file_gen is None:
            log.info("Excel ohne Versionsnummer – x-Markierungen werden diesmal nicht übernommen")
        next_gen = self.next_gen()
        for ws in wb.worksheets:
            if not re.fullmatch(r"\d{4}-\d{2}", ws.title):
                continue
            header, col = None, {}
            for row in ws.iter_rows(min_row=1, max_row=8, values_only=True):
                if row and row[0] == "Datum":
                    header = row
                    break
            if not header:
                continue
            col = {str(h): i for i, h in enumerate(header) if h}
            i_note = col.get("Notiz")
            i_own = next((i for h, i in col.items() if h.startswith("Eigene Änderung")), None)
            for row in ws.iter_rows(min_row=1, values_only=True):
                v = row[0] if row else None
                if isinstance(v, dt.datetime):
                    v = v.date()
                if not isinstance(v, dt.date):
                    continue
                ds = v.isoformat()
                if i_note is not None and i_note < len(row):
                    note = row[i_note]
                    note = "" if note is None else str(note).strip()
                    old = con.execute("SELECT note FROM notes WHERE date=?", (ds,)).fetchone()
                    if (old["note"] if old else "") != note:
                        con.execute("INSERT OR REPLACE INTO notes(date,note) VALUES(?,?)", (ds, note))
                        n_notes += 1
                if file_gen is not None and i_own is not None and i_own < len(row):
                    mark = row[i_own]
                    marked = mark is not None and str(mark).strip() != ""
                    if marked:
                        # nur Änderungen bestätigen, die in dieser Datei-Version schon drinstanden
                        c = con.execute("UPDATE changes SET confirmed=1, confirmed_gen=? WHERE date=? AND confirmed=0 "
                                        "AND classification!='own' AND COALESCE(seen_gen,0)<=? AND COALESCE(confirmed_gen,0)<=?",
                                        (next_gen, ds, file_gen, file_gen)).rowcount
                    else:
                        # x entfernt -> Bestätigung zurücknehmen (nicht, wenn erst nach dieser Datei-Version bestätigt)
                        c = con.execute("UPDATE changes SET confirmed=0, confirmed_gen=NULL WHERE date=? AND confirmed=1 "
                                        "AND COALESCE(confirmed_gen,0)<=?", (ds, file_gen)).rowcount
                    n_conf += c
        self.db.commit()
        if n_notes or n_conf:
            log.info("Aus Excel übernommen: %d Notiz(en), %d Bestätigung(en)", n_notes, n_conf)

    # ----- Fehlerstatus pro Bereich -----
    def set_state(self, area, ok, message=""):
        key = f"state_{area}"
        prev = self.db.meta(key, "ok")
        if ok:
            self.db.set_meta(key, "ok")
            self.db.set_meta(f"fails_{area}", 0)
            self.db.set_meta(f"ok_at_{area}", iso_utc(self.now))
            if prev == "error":
                log.info("%s wieder OK", area)
                if self.db.meta(f"mailed_{area}"):
                    self.db.set_meta(f"recovered_{area}", "1")
        else:
            fails = int(self.db.meta(f"fails_{area}", 0) or 0) + 1
            self.db.set_meta(key, "error")
            self.db.set_meta(f"fails_{area}", fails)
            self.db.set_meta(f"error_msg_{area}", message)
            if prev != "error":
                self.db.set_meta(f"error_since_{area}", iso_utc(self.now))
            self.db.add_error(area, message)
            self.problems.append((area, message))
        self.db.commit()

    # ----- Excel schreiben -----
    def write_excel(self, run_info):
        tz = self.tz
        con = self.db.con
        today = self.today()
        days = {r["date"]: json.loads(r["data"]) for r in con.execute("SELECT date,data FROM days")}
        ents = {}
        for r in con.execute("SELECT date,data FROM entries"):
            ents.setdefault(r["date"], []).append(json.loads(r["data"]))
        chg = {}
        for r in con.execute("SELECT * FROM changes ORDER BY id"):
            chg.setdefault(r["date"], []).append(dict(r))
        notes = {r["date"]: r["note"] for r in con.execute("SELECT date,note FROM notes")}

        wb = Workbook()
        ws_info = wb.active
        ws_info.title = "Info"
        ws_chg = wb.create_sheet("Änderungen")

        # Stile
        thin = Side(style="thin", color="BFBFBF")
        border = Border(left=thin, right=thin, top=thin, bottom=thin)
        hdr_fill = PatternFill("solid", fgColor="305496")
        hdr_font = Font(bold=True, color="FFFFFF")
        F = {
            "foreign": PatternFill("solid", fgColor="FFC7CE"),
            "unclear": PatternFill("solid", fgColor="FFEB9C"),
            "weekend": PatternFill("solid", fgColor="F2F2F2"),
            "absence": PatternFill("solid", fgColor="DDEBF7"),
            "running": PatternFill("solid", fgColor="E2EFDA"),
            "sum": PatternFill("solid", fgColor="D9E1F2"),
            "ok": PatternFill("solid", fgColor="C6EFCE"),
            "err": PatternFill("solid", fgColor="FFC7CE"),
        }
        font_foreign = Font(color="9C0006", bold=True)
        font_unclear = Font(color="7F6000")

        # ---------- Monatsblätter ----------
        all_dates = sorted(set(days) | set(ents))
        first = min([d_parse(d) for d in all_dates] + [self.start_date()]) if all_dates else self.start_date()
        months = []
        y, m = first.year, first.month
        while (y, m) <= (today.year, today.month):
            months.append((y, m))
            y, m = (y + 1, 1) if m == 12 else (y, m + 1)

        headers = ["Datum", "Tag", "Kommen", "Gehen", "Pausen", "Pausendauer", "Arbeitszeit (gestempelt)",
                   "Soll (h)", "Ist lt. Clockodo (h)", "Saldo (h)", "Abwesenheit / Feiertag", "Quelle",
                   "Änderung / Hinweis", "Geändert von", "Eigene Änderung (x)", "Notiz"]
        widths = [11, 5, 8, 12, 24, 11, 12, 9, 10, 9, 18, 22, 60, 26, 12, 30]

        open_changes = 0
        for (y, m) in reversed(months):
            ws = wb.create_sheet(f"{y:04d}-{m:02d}")
            ws.append([f"Arbeitszeiten {m:02d}/{y} – {self.me.get('name', '')}"])
            ws["A1"].font = Font(bold=True, size=14)
            ws.append([f"Stand: {fmt_dt(self.now, tz)} · Zeiten in {tz.key}"])
            ws["A2"].font = Font(italic=True, color="666666")
            ws.append([])
            ws.append(headers)
            hr = 4
            for c in range(1, len(headers) + 1):
                cell = ws.cell(row=hr, column=c)
                cell.fill, cell.font, cell.border = hdr_fill, hdr_font, border
                cell.alignment = Alignment(wrap_text=True, vertical="center")
            ws.row_dimensions[hr].height = 32
            first_row = hr + 1
            month_end = (dt.date(y + 1, 1, 1) if m == 12 else dt.date(y, m + 1, 1)) - dt.timedelta(days=1)
            for d in daterange(dt.date(y, m, 1), min(month_end, today)):
                ds = d.isoformat()
                day = days.get(ds, {})
                ivs = [(parse_ts(a), parse_ts(b)) for a, b in day.get("intervals", []) if a]
                ivs.sort(key=lambda x: x[0])
                running = any(b is None for _, b in ivs)
                kommen = ivs[0][0].astimezone(tz) if ivs else None
                gehen = ivs[-1][1].astimezone(tz) if ivs and ivs[-1][1] else None
                breaks, break_sec, net_sec = [], 0, 0
                for i, (a, b) in enumerate(ivs):
                    net_sec += ((b or self.now) - a).total_seconds()
                    if i > 0 and ivs[i - 1][1]:
                        gap = (a - ivs[i - 1][1]).total_seconds()
                        if gap > 0:
                            break_sec += gap
                            breaks.append(f"{fmt_hm(ivs[i - 1][1], tz)}–{fmt_hm(a, tz)}")
                net_sec += day.get("offset") or 0

                # Quelle
                de = ents.get(ds, [])
                src = ""
                if de:
                    if any(not e["clocked"] for e in de):
                        src = "Manuell nachgetragen" if all(not e["clocked"] for e in de) else "Stempeluhr + manuell"
                    else:
                        src = "Stempeluhr"
                    if any(self._edited_after(e) for e in de if e["clocked"]):
                        src += " (bearbeitet)"
                    if any(e["offline"] for e in de):
                        src += " (offline)"

                # Änderungen
                cl = chg.get(ds, [])
                texts, worst = [], None
                for c in cl:
                    when = fmt_dt(parse_ts(c["changed_at"]), tz) if c["changed_at"] else fmt_dt(parse_ts(c["detected_at"]), tz) + " (erkannt)"
                    t = f"{c['kind']}: {c['before']} → {c['after']} (am {when})"
                    texts.append(t)
                    if not c["confirmed"] and c["classification"] in ("foreign", "unclear"):
                        open_changes += 1
                        if c["classification"] == "foreign" or worst is None:
                            worst = c["classification"]
                if worst:
                    who = self.who_text(worst, False)
                elif cl:
                    who = "ich"
                else:
                    who = ""
                relevant = [c for c in cl if c["classification"] != "own"]
                own_mark = "x" if relevant and all(c["confirmed"] for c in relevant) else ""

                absence = day.get("absence", "")
                if day.get("nonbusiness") and d.weekday() < 5:
                    absence = (absence + ", " if absence else "") + "Feiertag"

                gehen_val = gehen.replace(tzinfo=None).time() if gehen else ("läuft" if running else None)
                if gehen and kommen and gehen.date() != kommen.date():
                    gehen_val = gehen.strftime("%H:%M") + " (+1 Tag)"
                row = [
                    d, WEEKDAYS[d.weekday()],
                    kommen.replace(tzinfo=None).time() if kommen else None,
                    gehen_val,
                    ", ".join(breaks),
                    dt.timedelta(seconds=int(break_sec)) if ivs else None,
                    dt.timedelta(seconds=int(net_sec)) if ivs or net_sec else None,
                    day.get("target"), day.get("hours"), day.get("diff"),
                    absence, src, "\n".join(texts), who, own_mark, notes.get(ds, ""),
                ]
                ws.append(row)
                r = ws.max_row
                fill = None
                if d.weekday() >= 5:
                    fill = F["weekend"]
                if absence:
                    fill = F["absence"]
                if running and d == today:
                    fill = F["running"]
                if worst:
                    fill = F[worst]
                for c in range(1, len(headers) + 1):
                    cell = ws.cell(row=r, column=c)
                    cell.border = border
                    cell.alignment = Alignment(vertical="top", wrap_text=(c in (5, 13, 16)))
                    if fill:
                        cell.fill = fill
                if worst == "foreign":
                    for c in (13, 14):
                        ws.cell(row=r, column=c).font = font_foreign
                elif worst == "unclear":
                    for c in (13, 14):
                        ws.cell(row=r, column=c).font = font_unclear
                ws.cell(row=r, column=1).number_format = "DD.MM.YYYY"
                ws.cell(row=r, column=3).number_format = "HH:MM"
                ws.cell(row=r, column=4).number_format = "HH:MM"
                ws.cell(row=r, column=6).number_format = "[H]:MM"
                ws.cell(row=r, column=7).number_format = "[H]:MM"
                for c in (8, 9):
                    ws.cell(row=r, column=c).number_format = "0.00"
                ws.cell(row=r, column=10).number_format = "+0.00;-0.00;0.00"
                ws.cell(row=r, column=15).alignment = Alignment(horizontal="center", vertical="top")
            last_row = ws.max_row
            # Summenzeile
            ws.append([])
            sr = ws.max_row + 1
            ws.cell(row=sr, column=1, value="Summe")
            for c, fmt in ((6, "[H]:MM"), (7, "[H]:MM"), (8, "0.00"), (9, "0.00"), (10, "+0.00;-0.00;0.00")):
                L = get_column_letter(c)
                cell = ws.cell(row=sr, column=c, value=f"=SUM({L}{first_row}:{L}{last_row})")
                cell.number_format = fmt
            ws.cell(row=sr, column=2, value=f'=COUNT(C{first_row}:C{last_row})&" Tage"')
            for c in range(1, len(headers) + 1):
                cell = ws.cell(row=sr, column=c)
                cell.fill, cell.font, cell.border = F["sum"], Font(bold=True), border
            for i, w in enumerate(widths, start=1):
                ws.column_dimensions[get_column_letter(i)].width = w
            ws.freeze_panes = ws.cell(row=hr + 1, column=3)
            ws.auto_filter.ref = f"A{hr}:{get_column_letter(len(headers))}{last_row}"
            ws.page_setup.orientation = "landscape"
            ws.page_setup.fitToWidth = 1
            ws.sheet_properties.pageSetUpPr.fitToPage = True
            ws.page_setup.fitToHeight = 0
            ws.print_title_rows = f"{hr}:{hr}"

        # ---------- Blatt "Änderungen" ----------
        ch_headers = ["Arbeitstag", "Art der Änderung", "Vorher", "Nachher", "Geändert am (Clockodo)",
                      "Erkannt am", "Geändert von", "Begründung der Einstufung", "Bestätigt als eigene", "Hinweis"]
        ws_chg.append(["Erkannte Änderungen an deinen Arbeitszeiten (neueste zuerst)"])
        ws_chg["A1"].font = Font(bold=True, size=14)
        ws_chg.append(["Rot = Chef/HR (sicher, außerhalb deiner Bearbeitungsfrist) · Gelb = unklar, bitte prüfen · "
                       "Eigene Änderung bestätigen: im Monatsblatt in Spalte 'Eigene Änderung (x)' ein x setzen."])
        ws_chg.append([])
        ws_chg.append(ch_headers)
        for c in range(1, len(ch_headers) + 1):
            cell = ws_chg.cell(row=4, column=c)
            cell.fill, cell.font, cell.border = hdr_fill, hdr_font, border
        for r in con.execute("SELECT * FROM changes ORDER BY date DESC, id DESC"):
            r = dict(r)
            ws_chg.append([
                d_parse(r["date"]), r["kind"], r["before"], r["after"],
                fmt_dt(parse_ts(r["changed_at"]), tz) if r["changed_at"] else "unbekannt",
                fmt_dt(parse_ts(r["detected_at"]), tz) + (" (Erstimport)" if r["historical"] else ""),
                self.who_text(r["classification"], r["confirmed"]), r["reason"] or "",
                "ja" if r["confirmed"] else "", "",
            ])
            rr = ws_chg.max_row
            ws_chg.cell(row=rr, column=1).number_format = "DD.MM.YYYY"
            fill = None if r["confirmed"] or r["classification"] == "own" else F.get(r["classification"])
            for c in range(1, len(ch_headers) + 1):
                cell = ws_chg.cell(row=rr, column=c)
                cell.border = border
                cell.alignment = Alignment(vertical="top", wrap_text=c in (2, 8))
                if fill:
                    cell.fill = fill
        for i, w in enumerate([12, 34, 18, 18, 18, 22, 26, 60, 12, 20], start=1):
            ws_chg.column_dimensions[get_column_letter(i)].width = w
        ws_chg.freeze_panes = "A5"
        if ws_chg.max_row > 4:
            ws_chg.auto_filter.ref = f"A4:{get_column_letter(len(ch_headers))}{ws_chg.max_row}"

        # ---------- Info-Blatt ----------
        self._write_info(ws_info, run_info, open_changes, len(all_dates), months, F, hdr_fill, hdr_font, border)

        gen = self.next_gen()
        ws_info.append([])
        ws_info.append(["Datei-Version (intern)", gen])
        ws_info.cell(row=ws_info.max_row, column=1).font = Font(color="999999", size=8)
        ws_info.cell(row=ws_info.max_row, column=2).font = Font(color="999999", size=8)
        ws_info.cell(row=ws_info.max_row, column=2).alignment = Alignment(horizontal="left")

        tmp = self.cfg.excel_path + ".tmp"
        wb.save(tmp)
        os.replace(tmp, self.cfg.excel_path)
        os.chmod(self.cfg.excel_path, 0o640)
        self.db.set_meta("excel_gen", gen)
        self.db.set_meta("excel_written_at", iso_utc(self.now))
        self.db.commit()
        self._backup()
        log.info("Excel geschrieben: %s (%d Monate)", self.cfg.excel_path, len(months))

    def _write_info(self, ws, run_info, open_changes, n_days, months, F, hdr_fill, hdr_font, border):
        tz = self.tz
        hi = host_info()
        sched = cron_schedule()
        nxt = next_cron_run(sched, self.now.astimezone(tz)) if sched else None
        ws.column_dimensions["A"].width = 32
        ws.column_dimensions["B"].width = 70
        ws.column_dimensions["C"].width = 60

        def title(text):
            ws.append([])
            ws.append([text])
            c = ws.cell(row=ws.max_row, column=1)
            c.font = Font(bold=True, size=12, color="FFFFFF")
            for col in (1, 2, 3):
                ws.cell(row=ws.max_row, column=col).fill = hdr_fill

        def kv(k, v, fill=None):
            ws.append([k, v])
            ws.cell(row=ws.max_row, column=1).font = Font(bold=True)
            ws.cell(row=ws.max_row, column=2).alignment = Alignment(wrap_text=True, vertical="top")
            if fill:
                ws.cell(row=ws.max_row, column=2).fill = fill

        ws.append(["Clockodo Arbeitszeit-Sync"])
        ws["A1"].font = Font(bold=True, size=16)
        api_state = self.db.meta("state_clockodo", "ok")
        nc_state = self.db.meta("state_nextcloud", "ok") if self.cfg.getbool("nextcloud", "enabled") else "aus"
        overall_ok = api_state == "ok" and nc_state in ("ok", "aus") and not self.problems
        ws.append(["Gesamtstatus", "✅ Alles OK" if overall_ok else "⚠️ Es gibt Probleme – siehe unten"])
        ws["B2"].fill = F["ok"] if overall_ok else F["err"]
        ws["A2"].font = Font(bold=True)

        title("Letzter Lauf")
        kv("Zeitpunkt", f"{fmt_dt(self.now, tz)} ({tz.key})")
        kv("Art", run_info.get("mode", ""))
        kv("Ergebnis", run_info.get("result", ""))
        kv("Letzter erfolgreicher API-Abruf", fmt_dt(parse_ts(self.db.meta("last_api_ok")), tz) or "noch nie")
        kv("Letzter Komplett-Abgleich", (self.db.meta("last_full_sync") or "noch nie").replace("T", " "))
        kv("Nächster geplanter Lauf", nxt.strftime("%d.%m.%Y %H:%M") if nxt else (sched and f"laut Cron: {sched}") or "kein Cronjob gefunden")

        title("Wo läuft der Cronjob?")
        kv("Host", hi["hostname"])
        kv("IP-Adresse(n)", hi["ips"] or "unbekannt")
        kv("Betriebssystem", hi["os"])
        kv("Umgebung", hi["env"])
        kv("Cronjob", f"{CRON_FILE} → Zeitplan „{sched}“" if sched else "nicht eingerichtet")
        kv("Programm", f"{os.path.abspath(__file__)} (Version {VERSION})")
        kv("Konfiguration", self.cfg.path)
        kv("Daten / lokale Excel", f"{self.cfg.data_dir} / {self.cfg.excel_path}")
        kv("Logdatei", os.path.join(self.cfg.get("paths", "log_dir"), "sync.log"))

        title("Clockodo & Daten")
        kv("Clockodo-Benutzer", f"{self.me.get('name', '?')} (ID {self.me.get('id', '?')}, {self.cfg.get('clockodo', 'email')})")
        kv("Zeitzone", tz.key)
        kv("Daten ab", self.start_date().strftime("%d.%m.%Y"))
        kv("Erfasste Tage / Monate", f"{n_days} Tage mit Daten · {len(months)} Monatsblätter")
        kv("Rückblick bei stündlichem Lauf", f"{self.cfg.getint('sync', 'lookback_days', 35)} Tage (+ täglicher Komplett-Abgleich ab {self.cfg.getint('sync', 'full_sync_hour', 3)}:00 Uhr)")
        kv("Deine Bearbeitungsfrist", self.lock_text())
        kv("Vorgesetzte(r) laut Clockodo", self.boss_name() or "unbekannt")
        kv("Offene (unbestätigte) Änderungen", str(open_changes), F["unclear"] if open_changes else None)
        if self.db.meta("report_ok") == "0":
            kv("Soll/Saldo", "Konnte nicht abgerufen werden (fehlende Berechtigung?) – Spalten bleiben leer", F["unclear"])

        title("Nextcloud & E-Mail")
        if self.cfg.getbool("nextcloud", "enabled"):
            kv("Nextcloud-Ziel", f"{self.cfg.get('nextcloud', 'url')} → {self.cfg.get('nextcloud', 'remote_path')} (Benutzer {self.cfg.get('nextcloud', 'user')})")
            kv("Vorheriger erfolgreicher Upload", fmt_dt(parse_ts(self.db.meta("ok_at_nextcloud")), tz) or "– (erster Upload)")
        else:
            kv("Nextcloud", "deaktiviert")
        kv("E-Mail-Benachrichtigung", f"aktiv → {self.cfg.get('mail', 'to')}" if self.cfg.getbool("mail", "enabled") else "deaktiviert")

        title("API- und Verbindungsstatus")
        ws.append(["Bereich", "Status", "Letzte Meldung"])
        for c in (1, 2, 3):
            ws.cell(row=ws.max_row, column=c).font = Font(bold=True)
        for area, label in (("clockodo", "Clockodo-API"), ("nextcloud", "Nextcloud-Upload"), ("mail", "E-Mail-Versand")):
            st = self.db.meta(f"state_{area}", "ok")
            if area == "nextcloud" and not self.cfg.getbool("nextcloud", "enabled"):
                txt, fill, msg = "deaktiviert", None, ""
            elif area == "mail" and not self.cfg.getbool("mail", "enabled"):
                txt, fill, msg = "deaktiviert", None, ""
            elif st == "error":
                since = fmt_dt(parse_ts(self.db.meta(f"error_since_{area}")), tz)
                txt = f"❌ FEHLER seit {since} ({self.db.meta(f'fails_{area}', 1)}× in Folge)"
                fill, msg = F["err"], self.db.meta(f"error_msg_{area}", "")
            else:
                ok_at = fmt_dt(parse_ts(self.db.meta(f"ok_at_{area}")), tz)
                txt, fill, msg = f"✅ OK{(' (zuletzt ' + ok_at + ')') if ok_at else ''}", F["ok"], ""
            ws.append([label, txt, msg])
            if fill:
                ws.cell(row=ws.max_row, column=2).fill = fill
            ws.cell(row=ws.max_row, column=3).alignment = Alignment(wrap_text=True)
        for area, msg in self.problems:
            if area == "clockodo-report":
                ws.append(["Clockodo-Berichte", "⚠️ Warnung", msg])
                ws.cell(row=ws.max_row, column=2).fill = F["unclear"]

        title("Letzte Probleme (max. 20)")
        rows = list(self.db.con.execute("SELECT ts,area,message FROM errors ORDER BY id DESC LIMIT 20"))
        if not rows:
            ws.append(["–", "Keine Probleme aufgetreten"])
        for r in rows:
            ws.append([fmt_dt(parse_ts(r["ts"]), tz), r["area"], r["message"]])
            ws.cell(row=ws.max_row, column=3).alignment = Alignment(wrap_text=True)

        title("Letzte Läufe")
        ws.append(["Zeitpunkt", "Art / Ergebnis", "Meldung"])
        for c in (1, 2, 3):
            ws.cell(row=ws.max_row, column=c).font = Font(bold=True)
        for r in self.db.con.execute("SELECT * FROM runs WHERE finished IS NOT NULL ORDER BY id DESC LIMIT 10"):
            ws.append([fmt_dt(parse_ts(r["started"]), tz), f"{r['mode']} – {r['status']} ({(r['duration'] or 0):.1f} s)", r["message"]])

        title("Legende & Bedienung")
        for k, v, f in (
            ("Rot", "Änderung durch Chef/HR – sicher erkannt (außerhalb deiner Bearbeitungsfrist)", F["foreign"]),
            ("Gelb", "Änderung, die von dir oder Chef/HR sein kann – bitte prüfen", F["unclear"]),
            ("Grün", "Heute, du bist gerade eingestempelt", F["running"]),
            ("Blau", "Abwesenheit (Urlaub, Krank, …) oder Feiertag", F["absence"]),
            ("Grau", "Wochenende", F["weekend"]),
        ):
            kv(k, v, f)
        kv("Eigene Änderung bestätigen", "Im Monatsblatt in Spalte „Eigene Änderung (x)“ ein x eintragen und speichern. "
           "Beim nächsten Lauf wird die Markierung entfernt. Alternativ auf dem Server: clockodo-sync confirm JJJJ-MM-TT")
        kv("Notizen", "Spalte „Notiz“ im Monatsblatt wird beim nächsten Lauf übernommen und bleibt erhalten.")
        kv("Hinweis", "Clockodo liefert über die API nicht, WER eine Zeit geändert hat. Die Einstufung erfolgt "
           "über deine Bearbeitungsfrist: Was nach Ablauf der Frist geändert wurde, kann nur Chef/HR gewesen sein.")

    def _backup(self):
        keep = self.cfg.getint("excel", "backups_keep", 30)
        if keep <= 0:
            return
        bdir = os.path.join(self.cfg.data_dir, "backups")
        os.makedirs(bdir, exist_ok=True)
        base = os.path.splitext(os.path.basename(self.cfg.excel_path))[0]
        target = os.path.join(bdir, f"{base}_{self.today().isoformat()}.xlsx")
        shutil.copy2(self.cfg.excel_path, target)
        files = sorted(f for f in os.listdir(bdir) if f.startswith(base + "_") and f.endswith(".xlsx"))
        for f in files[:-keep]:
            os.remove(os.path.join(bdir, f))

    # ----- Benachrichtigungen -----
    def notify(self):
        if not self.cfg.getbool("mail", "enabled"):
            # ohne E-Mail nichts aufstauen (sonst Flut beim späteren Aktivieren)
            self.db.con.execute("UPDATE changes SET notified=1 WHERE notified=0")
            self.db.commit()
            return
        tz = self.tz
        con = self.db.con
        try:
            if self.cfg.getbool("mail", "notify_changes"):
                rows = [dict(r) for r in con.execute(
                    "SELECT * FROM changes WHERE notified=0 AND confirmed=0 AND classification IN ('foreign','unclear') ORDER BY date, id")]
                if rows:
                    n_f = sum(1 for r in rows if r["classification"] == "foreign")
                    n_u = len(rows) - n_f
                    parts = []
                    if n_f:
                        parts.append(f"{n_f} Änderung(en) durch Chef/HR")
                    if n_u:
                        parts.append(f"{n_u} unklare Änderung(en)")
                    subj = " + ".join(parts) + " an deinen Arbeitszeiten"
                    lines = ["Folgende Änderungen an deinen Arbeitszeiten in Clockodo wurden erkannt:", ""]
                    for r in rows:
                        d = d_parse(r["date"])
                        lines.append(f"• {WEEKDAYS[d.weekday()]} {d.strftime('%d.%m.%Y')}: {r['kind']}: {r['before']} → {r['after']}")
                        lines.append(f"    geändert am: {fmt_dt(parse_ts(r['changed_at']), tz) or 'unbekannt'}")
                        lines.append(f"    von: {self.who_text(r['classification'], False)}")
                        lines.append(f"    Grund der Einstufung: {r['reason']}")
                        lines.append("")
                    lines.append("War eine Änderung von dir? Dann im Monatsblatt der Excel in Spalte 'Eigene Änderung (x)' ein x setzen")
                    lines.append("oder auf dem Server ausführen: clockodo-sync confirm JJJJ-MM-TT")
                    send_mail(self.cfg, subj, "\n".join(lines))
                    con.execute("UPDATE changes SET notified=1 WHERE id IN (%s)" % ",".join(str(r["id"]) for r in rows))
                    self.db.commit()
                    log.info("E-Mail zu %d Änderung(en) versendet", len(rows))

            if self.cfg.getbool("mail", "notify_errors"):
                threshold = max(1, self.cfg.getint("mail", "error_threshold", 2))
                repeat_h = self.cfg.getint("mail", "error_repeat_hours", 24)
                for area, label in (("clockodo", "Clockodo-API"), ("nextcloud", "Nextcloud-Upload")):
                    if self.db.meta(f"state_{area}") == "error":
                        fails = int(self.db.meta(f"fails_{area}", 0) or 0)
                        last = parse_ts(self.db.meta(f"mailed_{area}"))
                        due = last is None or (repeat_h > 0 and (self.now - last).total_seconds() > repeat_h * 3600)
                        if fails >= threshold and due:
                            since = fmt_dt(parse_ts(self.db.meta(f"error_since_{area}")), tz)
                            send_mail(self.cfg, f"Problem mit {label}",
                                      f"Seit {since} schlägt der Zugriff auf {label} fehl ({fails}× in Folge).\n\n"
                                      f"Letzte Meldung:\n{self.db.meta(f'error_msg_{area}')}\n\n"
                                      f"Details: Info-Blatt der Excel oder 'clockodo-sync status' auf {socket.gethostname()}.")
                            self.db.set_meta(f"mailed_{area}", iso_utc(self.now))
                    elif self.db.meta(f"recovered_{area}") == "1":
                        send_mail(self.cfg, f"{label} funktioniert wieder", f"{label} ist seit {fmt_dt(self.now, tz)} wieder erreichbar.")
                        self.db.set_meta(f"recovered_{area}", None)
                        self.db.set_meta(f"mailed_{area}", None)
                self.db.commit()
            self.set_state("mail", True)
        except Exception as e:
            log.error("E-Mail-Versand fehlgeschlagen: %s", e)
            self.set_state("mail", False, f"E-Mail-Versand fehlgeschlagen: {short_err(e)}")


# --------------------------------------------------------------------------- #
# Befehle
# --------------------------------------------------------------------------- #
def setup_logging(cfg, verbose):
    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")
    log_dir = cfg.get("paths", "log_dir") if cfg else ""
    if log_dir:
        try:
            os.makedirs(log_dir, exist_ok=True)
            fh = RotatingFileHandler(os.path.join(log_dir, "sync.log"), maxBytes=2_000_000, backupCount=5, encoding="utf-8")
            fh.setFormatter(fmt)
            log.addHandler(fh)
        except OSError as e:
            print(f"Warnung: Logdatei nicht schreibbar ({e})", file=sys.stderr)
    if verbose or sys.stderr.isatty():
        sh = logging.StreamHandler()
        sh.setFormatter(fmt)
        log.addHandler(sh)


def acquire_lock(cfg):
    os.makedirs(cfg.data_dir, exist_ok=True)
    fh = open(os.path.join(cfg.data_dir, ".lock"), "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return fh


def cmd_run(cfg, args, api=True):
    lock = acquire_lock(cfg)
    if not lock:
        log.info("Ein anderer Lauf ist noch aktiv – übersprungen.")
        return 0
    t0 = time.time()
    s = Sync(cfg)
    run_id = s.db.con.execute("INSERT INTO runs(started,mode,status) VALUES(?,?,?)",
                              (iso_utc(s.now), "", "läuft")).lastrowid
    s.db.commit()
    mode, result = "nur Excel", []
    nc = Nextcloud(cfg) if cfg.getbool("nextcloud", "enabled") else None

    # 1) Clockodo abrufen
    if api:
        try:
            full, st = s.fetch(full=getattr(args, "full", False))
            mode = "Komplett-Abgleich" if full else "Stündlicher Abgleich"
            s.set_state("clockodo", True)
            result.append(f"{st['days']} Tag(e) aktualisiert, {st['changes']} Änderung(en) erkannt")
        except (ClockodoError, requests.RequestException, KeyError, ValueError) as e:
            mode = "Abgleich"
            log.error("Clockodo-Abruf fehlgeschlagen: %s", e)
            s.set_state("clockodo", False, short_err(e))
            result.append("Clockodo-Abruf FEHLGESCHLAGEN – vorhandene Daten bleiben erhalten")

    # 2) Bestätigungen/Notizen aus der aktuellen Excel übernehmen
    readback = os.path.join(cfg.data_dir, "readback.xlsx")
    try:
        got = False
        if nc:
            got = nc.download(readback)
        if not got and os.path.exists(cfg.excel_path):
            shutil.copy2(cfg.excel_path, readback)
            got = True
        if got:
            s.read_back(readback)
    except NextcloudError as e:
        log.warning("Excel von Nextcloud nicht ladbar: %s", e)
        if os.path.exists(cfg.excel_path):
            s.read_back(cfg.excel_path)

    # 3) Excel schreiben + hochladen
    status = "OK" if not s.problems else "Warnung"
    try:
        s.write_excel({"mode": mode, "result": "; ".join(result) or "OK"})
    except Exception as e:
        log.exception("Excel konnte nicht geschrieben werden")
        s.db.add_error("excel", f"Excel konnte nicht geschrieben werden: {short_err(e)}")
        s.problems.append(("excel", str(e)))
    if nc and os.path.exists(cfg.excel_path):
        try:
            nc.upload(cfg.excel_path)
            was_error = s.db.meta("state_nextcloud") == "error"
            s.set_state("nextcloud", True)
            if was_error:
                # Info-Blatt würde sonst noch den alten Upload-Fehler zeigen -> neu schreiben und nochmal hochladen
                s.write_excel({"mode": mode, "result": "; ".join(result + ["Upload OK"])})
                nc.upload(cfg.excel_path)
            log.info("Nach Nextcloud hochgeladen: %s", cfg.get("nextcloud", "remote_path"))
            result.append("Upload OK")
        except NextcloudError as e:
            log.error("%s", e)
            s.set_state("nextcloud", False, short_err(e))
            result.append("Upload FEHLGESCHLAGEN")

    # 4) Benachrichtigen
    s.notify()

    if s.problems:
        status = "Fehler" if any(a in ("clockodo", "nextcloud", "excel") for a, _ in s.problems) else "Warnung"
    dur = time.time() - t0
    s.db.con.execute("UPDATE runs SET finished=?, mode=?, status=?, message=?, duration=? WHERE id=?",
                     (iso_utc(now_utc()), mode, status, "; ".join(result), dur, run_id))
    s.db.con.execute("DELETE FROM runs WHERE id NOT IN (SELECT id FROM runs ORDER BY id DESC LIMIT 1000)")
    s.db.commit()
    log.info("Fertig (%s) in %.1f s: %s", status, dur, "; ".join(result))
    return 0 if status != "Fehler" else 2


def cmd_test(cfg, args):
    ok = True
    print("Clockodo …", end=" ", flush=True)
    try:
        api = Clockodo(cfg)
        me = api.me()
        print(f"OK – angemeldet als {me.get('name')} (ID {me.get('id')}, Zeitzone {me.get('timezone')}, "
              f"Eintritt {me.get('start_date') or 'unbekannt'})")
        lock = []
        for k in ("work_time_edit_lock_days", "edit_lock_dyn", "edit_lock", "edit_lock_period"):
            if me.get(k) is not None:
                lock.append(f"{k}={me.get(k)}")
        print(f"   Bearbeitungssperre: {', '.join(lock) or 'keine hinterlegt'} · Rolle: {me.get('role')}")
        today = dt.date.today()
        wt = api.work_times(me["id"], today - dt.timedelta(days=7), today)
        print(f"   Arbeitszeiten letzte 7 Tage: {sum(1 for w in wt if w.get('intervals'))} Tag(e) mit Daten")
        try:
            api.user_report(me["id"], today.year)
            print("   Soll/Saldo-Bericht: OK")
        except ClockodoError as e:
            print(f"   Soll/Saldo-Bericht: nicht verfügbar ({e}) – Spalten bleiben leer")
    except Exception as e:
        ok = False
        print(f"FEHLER: {e}")
    if cfg.getbool("nextcloud", "enabled"):
        print("Nextcloud …", end=" ", flush=True)
        try:
            nc = Nextcloud(cfg)
            nc.test()
            nc.ensure_dirs()
            probe = os.path.join(cfg.data_dir, ".nc-test")
            os.makedirs(cfg.data_dir, exist_ok=True)
            with open(probe, "w") as f:
                f.write("clockodo-sync test")
            target = nc.remote + ".schreibtest.txt"
            nc.upload(probe, target)
            nc.delete(target)
            os.remove(probe)
            print(f"OK – Schreibzugriff auf {os.path.dirname(nc.remote) or '/'} funktioniert")
        except Exception as e:
            ok = False
            print(f"FEHLER: {e}")
    else:
        print("Nextcloud: deaktiviert")
    if getattr(args, "mail", False):
        ok = cmd_testmail(cfg, args) == 0 and ok
    return 0 if ok else 1


def cmd_testmail(cfg, args):
    print("E-Mail …", end=" ", flush=True)
    try:
        send_mail(cfg, "Test-E-Mail", "Diese Test-E-Mail bestätigt, dass die Benachrichtigungen von clockodo-sync funktionieren.")
        print(f"OK – gesendet an {cfg.get('mail', 'to')}")
        return 0
    except Exception as e:
        print(f"FEHLER: {e}")
        return 1


def cmd_status(cfg, args):
    s = Sync(cfg)
    tz = s.tz
    print(f"clockodo-sync {VERSION} · Konfiguration: {cfg.path}")
    print(f"Clockodo-Benutzer: {s.me.get('name', '?')} · Zeitzone {tz.key} · Daten ab {s.start_date():%d.%m.%Y}")
    print(f"Erstimport: {'erledigt' if s.db.meta('initial_import_done') == '1' else 'noch nicht'} · "
          f"Letzter Komplett-Abgleich: {(s.db.meta('last_full_sync') or 'nie').replace('T', ' ')}")
    print(f"Bearbeitungsfrist: {s.lock_text()}")
    sched = cron_schedule()
    print(f"Cronjob: {sched or 'NICHT eingerichtet'}")
    print()
    for area in ("clockodo", "nextcloud", "mail"):
        st = s.db.meta(f"state_{area}", "ok")
        extra = f" seit {fmt_dt(parse_ts(s.db.meta(f'error_since_{area}')), tz)}: {s.db.meta(f'error_msg_{area}')}" if st == "error" else ""
        print(f"  {area:10s} {st.upper()}{extra}")
    print("\nLetzte Läufe:")
    for r in s.db.con.execute("SELECT * FROM runs ORDER BY id DESC LIMIT 8"):
        print(f"  {fmt_dt(parse_ts(r['started']), tz)}  {r['status']:8s} {r['mode'] or '':22s} {r['message'] or ''}")
    n = s.db.con.execute("SELECT COUNT(*) c FROM changes WHERE confirmed=0 AND classification IN ('foreign','unclear')").fetchone()["c"]
    print(f"\nOffene (unbestätigte) Änderungen: {n}" + (" → 'clockodo-sync changes --open'" if n else ""))
    return 0


def cmd_changes(cfg, args):
    s = Sync(cfg)
    q = "SELECT * FROM changes"
    if args.open:
        q += " WHERE confirmed=0 AND classification IN ('foreign','unclear')"
    q += " ORDER BY date DESC, id DESC LIMIT ?"
    rows = list(s.db.con.execute(q, (args.limit,)))
    if not rows:
        print("Keine Änderungen gefunden.")
    for r in rows:
        print(f"{r['date']}  {r['kind']}: {r['before']} → {r['after']}  | von: {s.who_text(r['classification'], r['confirmed'])}"
              f"{'  [bestätigt]' if r['confirmed'] else ''}{'  [Erstimport]' if r['historical'] else ''}")
    return 0


def cmd_confirm(cfg, args):
    s = Sync(cfg)
    try:
        d_parse(args.date)
    except ValueError:
        print("Datum bitte als JJJJ-MM-TT angeben, z. B. 2026-10-22")
        return 1
    n = s.db.con.execute("UPDATE changes SET confirmed=?, confirmed_gen=? WHERE date=? AND classification!='own'",
                         (0 if args.undo else 1, s.next_gen(), args.date)).rowcount
    s.db.commit()
    print(f"{n} Änderung(en) am {args.date} {'wieder als offen markiert' if args.undo else 'als eigene bestätigt'}.")
    if n and not args.no_upload:
        print("Excel wird aktualisiert …")
        return cmd_run(cfg, args, api=False)
    return 0


def cmd_whoami(cfg, args):
    """Für das Setup: Clockodo-Profil als JSON ausgeben."""
    try:
        me = Clockodo(cfg).me()
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        return 1
    keys = ("id", "name", "email", "timezone", "start_date", "role", "boss",
            "work_time_edit_lock_days", "edit_lock_dyn", "edit_lock", "edit_lock_period")
    print(json.dumps({k: me.get(k) for k in keys}))
    return 0


def main():
    p = argparse.ArgumentParser(prog=APP_NAME, description="Clockodo-Arbeitszeiten → Excel → Nextcloud")
    p.add_argument("-c", "--config", default=DEFAULT_CONFIG)
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    sub = p.add_subparsers(dest="cmd")
    r = sub.add_parser("run", help="Abgleich durchführen (Standard)")
    r.add_argument("--full", action="store_true", help="kompletter Abgleich aller Daten")
    t = sub.add_parser("test", help="Verbindungen prüfen")
    t.add_argument("--mail", action="store_true", help="zusätzlich Test-E-Mail senden")
    sub.add_parser("testmail", help="Test-E-Mail senden")
    sub.add_parser("status", help="Status anzeigen")
    ch = sub.add_parser("changes", help="erkannte Änderungen auflisten")
    ch.add_argument("--open", action="store_true", help="nur unbestätigte")
    ch.add_argument("--limit", type=int, default=50)
    co = sub.add_parser("confirm", help="Änderungen eines Tages als eigene bestätigen")
    co.add_argument("date", help="JJJJ-MM-TT")
    co.add_argument("--undo", action="store_true")
    co.add_argument("--no-upload", action="store_true")
    sub.add_parser("excel", help="Excel neu erzeugen und hochladen (ohne API-Abruf)")
    sub.add_parser("whoami", help="Clockodo-Profil als JSON (für das Setup)")
    args = p.parse_args()
    cmd = args.cmd or "run"

    cfg = Config(args.config)
    if cmd == "whoami":
        return cmd_whoami(cfg, args)
    setup_logging(cfg, args.verbose or cmd in ("run", "excel") and sys.stdout.isatty())
    if cmd == "run":
        return cmd_run(cfg, args)
    if cmd == "excel":
        return cmd_run(cfg, args, api=False)
    return {"test": cmd_test, "testmail": cmd_testmail, "status": cmd_status,
            "changes": cmd_changes, "confirm": cmd_confirm}[cmd](cfg, args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
