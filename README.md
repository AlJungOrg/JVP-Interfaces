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

## Verfügbare Interfaces

*(wird laufend ergänzt)*

| Name | Beschreibung | Status |
|---|---|---|
| — | — | — |

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
