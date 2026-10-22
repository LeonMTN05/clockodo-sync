#!/usr/bin/env bash
# Baut die Ein-Datei-Version: Setup-Script + eingebettetes Python-Programm
set -e
cd "$(dirname "$0")"
python3 -m py_compile clockodo_sync.py && rm -rf __pycache__
bash -n setup.sh
mkdir -p dist
{ cat setup.sh; echo; echo "__PYTHON_PAYLOAD_BELOW__"; cat clockodo_sync.py; } > dist/clockodo-sync-installer.sh
chmod 755 dist/clockodo-sync-installer.sh
echo "OK: dist/clockodo-sync-installer.sh ($(wc -c < dist/clockodo-sync-installer.sh) Bytes)"
