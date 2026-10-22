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
