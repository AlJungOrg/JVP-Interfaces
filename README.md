# JVP-Interfaces

Sammlung freier **JUNG Visu Pro (JVP)** Interfaces (Prozessanschlüsse) — Lua-Skripte, die JVP an externe Geräte, Protokolle und Dienste anbinden.

🇬🇧 [Read this in English](README.en.md)

## Über dieses Projekt

JUNG Visu Pro ist die Visualisierungssoftware der JUNG GmbH & Co. KG für Smart-Home- und Gebäudeautomation. Ein **Interface** (auch „Prozessanschluss" oder „SDV-Interface" genannt) ist ein in Lua geschriebenes Plugin, das innerhalb der JVP-Runtime läuft, Datenpunkte für die Visualisierung bereitstellt und diese mit einem externen System synchronisiert — etwa per HTTP-API, KNX-Bridge oder Zeitsteuerung.

Dieses Repository sammelt solche Interfaces und stellt sie öffentlich zur Verfügung, damit andere JVP-Anwender sie nutzen, anpassen und erweitern können.

**Hinweis:** Dieses Projekt ist ein privates, community-getragenes Vorhaben und steht in keiner offiziellen Verbindung zur JUNG GmbH & Co. KG.

## Aufbau eines Interfaces

Jedes Interface liegt in einem eigenen Unterordner und besteht typischerweise aus folgenden Dateien:

| Datei | Beschreibung |
|---|---|
| `InterfaceScript.lua` | Hauptlogik inkl. Lifecycle-Funktionen (`Init`, `Exit`, `Poll`, `OnValueRead`, `OnValueChange`) |
| `InterfaceScriptCommonLibrary.lua` | Gemeinsame Hilfsbibliothek zur Navigation im Datenpunktbaum |
| `InterfaceDescription.xml` | Definiert das Datenpunktmodell (`SDVINTERFACE`) mit Datenpunkten wie `PVSTRING`, `PVBINARY`, `PVANALOG`, `PVTIME` und `PVFOLDER` |
| `json.lua` | Optional, für Interfaces mit JSON-basierter HTTP-Kommunikation |

In JVP selbst liegt jedes Interface in einem eigenen Unterordner unter:

```
C:\Users\Public\Documents\JUNG Visu Pro\App\EsfSdvEditor\Interfaces\<Interface-Name>\
```

Der Ordnername erscheint im Geräteeditor unter „Datei / Prozessanschluss erstellen“. Ein neues Interface wird erst nach einem Neustart des Geräteeditors angezeigt.

### Lifecycle-Funktionen (`InterfaceScript.lua`)

Der Geräteeditor ruft in jedem Interface-Skript folgende Funktionen auf:

| Funktion | Wird aufgerufen … |
|---|---|
| `Init()` | einmalig beim Start des Interfaces – zum Initialisieren von Werten und Öffnen von Ressourcen |
| `OnValueChange(oVarPath, strValue)` | wenn sich der Wert eines Datenpunkts im Prozessmodell ändert |
| `Poll()` | zyklisch, im Intervall `POLLTIME` (ms) aus `InterfaceDescription.xml` |
| `OnValueRead(oVarPath, nReason)` | wenn das Prozessmodell einen Datenpunktwert lesen möchte |
| `Exit()` | einmalig beim Beenden des Interfaces – zum Schließen von Ressourcen |

Mit den Hilfsfunktionen `oVarPath:_findParentFromUserType("...")` (übergeordneter Ordner) und `oVarPath:_getLeaf()` (der geänderte/gelesene Datenpunkt selbst) sowie `varLeaf:GetAccessRights()`, `varLeaf:GetValue()` und `varLeaf:SetValue(strValue, nReason)` lassen sich Datenpunkte gezielt auswerten und beschreiben.

### Ressourcen (Kommunikation nach außen)

In `InterfaceDescription.xml` können folgende Ressourcen eingebunden werden, jede mit eigener Lua-API (`Open`, `Close`, `GetRxData(Available)`, `PutTxData`, …):

| Ressource | Kommunikationsweg |
|---|---|
| `UDPPORT` | UDP |
| `COMPORT` | Serielle Schnittstelle (RS232 etc.) |
| `TCPSRV` | interner TCP-Server |
| `TCPCLIENT` | interner TCP-Client |
| `HTTP` | HTTP-Requests (GET/POST/PUT/DELETE) |

### Datenpunkte in `InterfaceDescription.xml`

Grobe Struktur der Datei: `<SDVINTERFACE>` → `<INFO>` (Name, Autor, Beschreibung, Version, `APIVERSION`, `POLLTIME` in ms) → `<PVITEMS>` mit den eigentlichen Datenpunkten.

| Element | Typ |
|---|---|
| `PVANALOG` | Analogwert |
| `PVBINARY` | Binärwert (`UNIT0`/`UNIT1` = Beschriftung für 0/1) |
| `PVSTRING` | Text |
| `PVTIME` | Zeit/Datum |
| `PVFOLDER` | Ordner, kann weitere Datenpunkte/Ordner enthalten |

Gemeinsame Attribute: `SCRIPTNAME` (Name im Lua-Skript), `DEFAULTNAME` (im Editor sichtbarer Name), `EXPORT` (an die Visualisierung übergeben ja/nein), `SAVE` (Wert beim Schließen speichern ja/nein), `ACCESS` (`None`/`Read`/`Write`/`Read/Write`), `DESCRIPTION`.

Bei `PVFOLDER` steuert `CREATIONTYPE` zusätzlich, ob der Ordner vom Anwender (mehrfach) angelegt werden kann (`Multiple`) oder vom Editor einmalig fest vorgegeben ist (`Unique`); `USERTYPE` ist ein frei wählbarer Bezeichner, über den das Skript passende Ordner wiederfindet.

### Datenpunkte in Lua ansprechen

- `E.PVTable` — globale Tabelle mit allen in der XML definierten Datenpunkten/Ordnern; `Unique`-Ordner direkt per `E.PVTable["<SCRIPTNAME>"]`, `Multiple`-Ordner per Iteration und Prüfung von `E_UserType`.
- `E.ResourceTable["<SCRIPTNAME>"]` — Zugriff auf eine in `RESOURCES` definierte Ressource (z. B. `HTTP_RQ = E.ResourceTable["HTTP"]`).
- In `OnValueChange`/`OnValueRead` liefert `oVarPath:_findParentFromUserType("...")` den übergeordneten Ordner ("Parent") und `oVarPath:_getLeaf()` den betroffenen Datenpunkt selbst ("Leaf").
- `varLeaf:GetAccessRights()` liefert `constAccessNone` / `constAccessRead` / `constAccessWrite` / `constAccessReadWrite` — vor Schreib-/Lesezugriffen prüfen.
- `varLeaf:GetValue()` liest den aktuellen Wert (immer als Text), `varLeaf:SetValue(strValue, nReason)` schreibt ihn; `nReason` ist üblicherweise `constValueChange` (auch für Bestätigungen an das Prozessmodell) oder `constValueResponse`.

### Entwickeln & Testen

- Neue Interfaces am einfachsten durch Kopieren eines bestehenden Ordners erstellen und XML/Lua anpassen; nach Namensänderung in der XML erscheint das Interface erst nach einem **Neustart des Geräteeditors** in „Datei / Prozessanschluss erstellen“.
- Zum Bearbeiten der `.lua`-Dateien eignet sich z. B. Notepad++ (Syntax-Highlighting).
- Nach Änderungen: Datei speichern, Interface im Geräteeditor per Rechtsklick neu starten. Das **Meldungsfenster** zeigt Lua-Fehler (z. B. Syntaxfehler) mit Zeilennummer an.
- Für HTTP-Interfaces stehen Hilfsfunktionen zur Verfügung: `ConvertASCIIToUTF8`, `ConvertUTF8ToASCII`, `ConvertToURLEncoding` (Percent-Encoding für URLs).

## Verfügbare Interfaces

*(wird laufend ergänzt)*

Der Ordner-Präfix zeigt den Reifegrad: **DRAFT** = Entwurf, noch nicht durchgängig getestet. **PoC** = Proof of Concept, kurz funktional getestet, aber nicht für den Produktiveinsatz freigegeben.

| Name | Beschreibung | Status |
|---|---|---|
| [Dynamische Strompreise](<DRAFT - Dynamic power rate>) | Day-Ahead-Strompreise für heute und morgen: DE/AT (aWATTar), FR/NL (Energy-Charts.info), KR (Elecz.com, nur aktueller Preis). Konfigurierbarer Aufschlag/MwSt, Erkennung des günstigsten Zeitfensters, stündliche Preise als Datenpunkte. | Entwurf |
| [Philips Hue V2](<DRAFT - Philips hue SSE>) | Anbindung einer Philips-Hue-Bridge über die CLIP-v2-API: Lampen, Räume/Zonen, Szenen, Sensoren (Bewegung/Temperatur/Kontakt/Batterie) und Automationen. Zustandsänderungen kommen per Server-Sent-Events (Eventstream) in Echtzeit von der Bridge, kein Dauerpolling nötig. | Entwurf |
| [trivum Multiroom-Audio](<DRAFT - Trivum>) | Anbindung eines trivum-Systems (z. B. MusicCenter) über die mcenter HTTP/XML-API: Zonen schalten/steuern (Ein/Aus, Lautstärke, Stumm, Play/Pause/Stop/Titelwechsel), Quellenwahl, Multiroom-Gruppierung sowie Favoriten und Titelinfos (Interpret/Album/Titel/Cover) je Zone. | Entwurf |
| [ekey Fingerprint-Zutritt](<PoC - eKey>) | Empfängt Zutrittsereignisse vom ekey Converter UDP/LAN (Protokoll `home` oder `multi`) und/oder von ekey-bionyx-Function-Webhooks über einen eingebetteten HTTP-Server (Bearer-Token-Prüfung). Beliebig viele „Funktionen" lassen sich auf Benutzer-ID, Finger-ID, Aktionscode bzw. bionyx-Funktionsnamen filtern und geben einen konfigurierbaren Impuls aus; letzter Benutzer, Finger, Scanner und Rohdaten stehen als Statusdatenpunkte bereit. | PoC |
| [JUNG HOME](<PoC - JUNGHOME>) | Anbindung des JUNG HOME Systems zum Steuern und Auslesen von JUNG-HOME-Geräten aus der Visualisierung. | PoC |
| [Anwesenheitssimulation](<PoC - Presence simulation>) | Anwesenheitssimulation: zeichnet Schaltvorgänge auf bzw. spielt zeitgesteuerte Muster ab, um bei Abwesenheit Bewohneraktivität zu simulieren. | PoC |

## Voraussetzungen

- JUNG Visu Pro (aktuelle Version empfohlen)
- Lua 5.1 (JVP-Runtime; keine `goto`, keine Bitoperatoren)
- Ggf. Zugriff auf die jeweilige Ziel-API/das Zielprotokoll des Interfaces (z. B. API-Zugangsdaten)

## Installation

1. Gewünschten Interface-Ordner herunterladen bzw. den Repo-Inhalt klonen:
   ```bash
   git clone https://github.com/AlJungOrg/JVP-Interfaces.git
   ```
2. Den Ordner des Interfaces in den JVP-Interface-Editor importieren bzw. dessen Dateien gemäß JVP-Dokumentation einbinden.
3. Konfigurationsdatenpunkte (z. B. Zugangsdaten, Poll-Intervall) im Projekt setzen.
4. Interface aktivieren und Datenpunkte in der Visualisierung verknüpfen.

Eine ausführliche Anleitung zum Anlegen eigener Interfaces findet sich in der offiziellen JVP-Dokumentation.

## Weiterführende Ressourcen

- Offizielles Tutorial „JUNG Visu Pro software – Lua scripting“ (Albrecht Jung GmbH & Co. KG) — Grundlage für die Interface-Architektur, XML-Struktur und Lua-API in diesem Repo.
- [lua.org](https://www.lua.org) — offizielle Lua-Dokumentation und Referenz für die Sprache selbst.
- Lua-Skripte lassen sich auch ohne JVP testen: `InterfaceScript.lua`, `InterfaceScriptCommonLibrary.lua` und ggf. `json.lua` in einen Ordner mit einer Lua-5.1-Runtime legen und per `lua InterfaceScript.lua` in der Kommandozeile ausführen (Syntaxcheck; JVP-spezifische Funktionen wie `E.PVTable` stehen dabei natürlich nicht zur Verfügung).

## Mitwirken

Beiträge sind willkommen:

1. Repository forken
2. Neuen Ordner für das Interface anlegen (Name = Interface-/Gerätename)
3. `InterfaceScript.lua`, `InterfaceDescription.xml` und ggf. weitere Dateien hinzufügen
4. Kurze Beschreibung (README im Unterordner) mit Funktionsumfang, Voraussetzungen und Konfiguration beilegen
5. Pull Request erstellen

Bitte auf gültiges Lua 5.1, saubere Fehlerbehandlung und keine hartkodierten Zugangsdaten achten.

## Haftungsausschluss

Alle Interfaces werden ohne Gewähr bereitgestellt. Nutzung auf eigene Verantwortung — insbesondere bei Anbindung an produktive Gebäudeautomation. Änderungen an Drittanbieter-APIs können dazu führen, dass Interfaces nicht mehr wie erwartet funktionieren.

## Lizenz

Sofern nicht anders angegeben, steht der Code in diesem Repository unter der [MIT-Lizenz](LICENSE).

## Kontakt

Fragen, Vorschläge oder Fehlermeldungen bitte über [Issues](../../issues) einreichen.
