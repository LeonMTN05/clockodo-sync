# clockodo-sync

Liest deine Arbeitszeiten aus Clockodo (Kommen, Gehen, Pausen), schreibt sie in eine Excel-Datei
(ein Blatt pro Monat, z. B. `2026-10`) und lädt sie auf deine Nextcloud. Läuft als Cronjob auf
jeder Debian/Ubuntu-VM oder jedem Container (LXC, Docker).

## Installation

Nur **eine Datei** herunterladen und ausführen:

```bash
curl -fsSLO https://raw.githubusercontent.com/LeonMTN05/clockodo-sync/main/dist/clockodo-sync-installer.sh
sudo bash clockodo-sync-installer.sh
```

Ohne `curl` (z. B. in schlanken Containern) geht es auch mit `wget`:

```bash
wget https://raw.githubusercontent.com/LeonMTN05/clockodo-sync/main/dist/clockodo-sync-installer.sh
sudo bash clockodo-sync-installer.sh
```

Ein Update später: dieselbe Datei neu herunterladen und `sudo bash clockodo-sync-installer.sh --update`
ausführen. Konfiguration und Daten bleiben erhalten.

Der Assistent fragt nacheinander:

1. **Clockodo**: Login-E-Mail + API-Schlüssel (Clockodo → Persönliche Daten → API-Schlüssel)
2. **Startdatum** für den Erstimport (Standard: dein Eintrittsdatum laut Clockodo)
3. **Erkennung von Chef/HR-Änderungen** (siehe unten)
4. **Zeitplan**: alle 15, 30 oder 60 Minuten (Standard 60)
5. **Nextcloud**: Adresse, Benutzer, App-Passwort (Nextcloud → Einstellungen → Sicherheit), Zielpfad
6. **E-Mail**: SMTP-Server für Benachrichtigungen bei Fremdänderungen und API-Problemen

Danach: Verbindungstest, Import aller bisherigen Zeiten, Cronjob einrichten.

Später jederzeit das Verwaltungsmenü öffnen:

```bash
sudo clockodo-sync-setup
```

Menü: Status, jetzt abgleichen, Verbindungen testen, offene Änderungen, Änderung bestätigen,
Einstellungen ändern, Log, Sicherung, Datenbank neu aufbauen, Update, Deinstallation.

## Die Excel-Datei

| Blatt | Inhalt |
|---|---|
| **Info** | Wo der Cronjob läuft (Host, IP, VM/Container), wann zuletzt/als nächstes, Status von Clockodo-API, Nextcloud und E-Mail, letzte Probleme, letzte Läufe, Legende |
| **Änderungen** | Alle erkannten Änderungen: was, vorher → nachher, wann, von wem |
| **2026-10**, **2026-09**, … | Ein Blatt pro Monat (neuester zuerst): Datum, Kommen, Gehen, Pausen, Pausendauer, Arbeitszeit, Soll, Ist, Saldo, Abwesenheit, Quelle, Änderung, Geändert von, Eigene Änderung (x), Notiz |

Farben: **Rot** = Änderung durch Chef/HR · **Gelb** = unklar, bitte prüfen · Grün = gerade eingestempelt ·
Blau = Urlaub/Krank/Feiertag · Grau = Wochenende.

Die Spalten **Notiz** und **Eigene Änderung (x)** kannst du direkt in der Nextcloud-Datei ausfüllen.
Sie werden beim nächsten Lauf übernommen und bleiben erhalten.

## Wie werden Änderungen durch Chef/HR erkannt?

Die Clockodo-API sagt **nicht**, wer eine Zeit geändert hat. Das Script nutzt deshalb deine
**Bearbeitungssperre** aus Clockodo:

- Wurde ein Tag geändert, der für dich schon gesperrt war → **kann nur Chef/HR gewesen sein** → rot + E-Mail.
  Als Name steht dein Vorgesetzter aus Clockodo dabei („vermutlich …“), da HR genauso möglich ist.
- Änderung am selben Tag (z. B. vergessen auszustempeln) → gilt als deine eigene, keine Markierung.
- Änderung innerhalb deiner Frist → **gelb** + E-Mail, denn das kannst du oder Chef/HR gewesen sein.
  Wenn du es warst: in der Excel ein `x` in „Eigene Änderung (x)“ setzen oder
  `sudo clockodo-sync confirm 2026-10-20` ausführen. Danach ist die Markierung weg.
  Alternativ im Setup einstellen, dass solche Änderungen automatisch als deine gelten.

Ist in Clockodo für dich **keine Bearbeitungssperre** hinterlegt, kannst du im Setup selbst angeben,
wie viele Tage rückwirkend du Zeiten ändern darfst. Ohne diese Angabe lässt sich nichts sicher zuordnen,
dann werden alle nachträglichen Änderungen gelb markiert.

Normales Ein- und Ausstempeln wird nie als Änderung gemeldet.

## Befehle

```bash
sudo clockodo-sync status              # Status, letzte Läufe, Fehler
sudo clockodo-sync run                 # jetzt abgleichen
sudo clockodo-sync run --full          # alle Daten seit Startdatum abgleichen
sudo clockodo-sync test --mail         # Clockodo, Nextcloud und E-Mail testen
sudo clockodo-sync changes --open      # unbestätigte Änderungen
sudo clockodo-sync confirm 2026-10-20  # Änderungen dieses Tages als eigene bestätigen (--undo)
sudo clockodo-sync excel               # Excel nur neu erzeugen + hochladen
```

## Ablauf eines Laufs

1. Clockodo abfragen: heute + die letzten 35 Tage, einmal täglich (ab 3 Uhr) der komplette Zeitraum
2. Mit dem letzten Stand vergleichen, Änderungen erkennen und einstufen
3. Notizen und x-Markierungen aus der aktuellen Nextcloud-Datei übernehmen
4. Excel neu schreiben, lokale Tagessicherung anlegen, auf Nextcloud hochladen
5. Bei Bedarf E-Mail: neue Fremd-/unklare Änderungen, API- oder Upload-Fehler
   (ab 2 Fehlschlägen in Folge, dann höchstens alle 24 h, plus Entwarnung bei Behebung)

Fällt die Clockodo-API aus, bleiben die vorhandenen Daten erhalten. Der Fehler steht im Info-Blatt
und kommt per E-Mail. Ist die Datei in Nextcloud gerade geöffnet (gesperrt), klappt der Upload beim nächsten Lauf.

## Dateien auf dem Server

| Pfad | Inhalt |
|---|---|
| `/opt/clockodo-sync/` | Programm + Setup |
| `/etc/clockodo-sync/config.ini` | Konfiguration (nur root + Dienstbenutzer lesbar) |
| `/var/lib/clockodo-sync/` | Datenbank, lokale Excel, `backups/` (30 Tage) |
| `/var/log/clockodo-sync/sync.log` | Log |
| `/etc/cron.d/clockodo-sync` | Cronjob (läuft als Systembenutzer `clockodo-sync`) |

**Docker-Container** ohne Init-System: Cron muss beim Containerstart mitgestartet werden
(z. B. `cron -f` als Hauptprozess oder `cron && …` im Entrypoint). Das Setup weist darauf hin.

## Entwicklung

- `clockodo_sync.py`: das Programm (Python 3.9+, `requests`, `openpyxl`)
- `setup.sh`: Setup/Menü
- `./build.sh` erzeugt daraus `dist/clockodo-sync-installer.sh` (Setup mit eingebettetem Programm)
- `beispiel/Clockodo-Zeiten-Beispiel.xlsx`: Beispielausgabe mit Testdaten
