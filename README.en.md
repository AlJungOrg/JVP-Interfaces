# JVP-Interfaces

A collection of free **JUNG Visu Pro (JVP)** interfaces (process connections) — Lua scripts that connect JVP to external devices, protocols, and services.

🇩🇪 [Auf Deutsch lesen](README.md)

## About this project

JUNG Visu Pro is the visualization software by JUNG GmbH & Co. KG for smart home and building automation. An **interface** (also called "process connection" or "SDV interface") is a plugin written in Lua that runs inside the JVP runtime, exposes datapoints to the visualization, and synchronizes them with an external system — for example via an HTTP API, a KNX bridge, or scheduled logic.

This repository collects such interfaces and makes them publicly available so other JVP users can use, adapt, and extend them.

**Note:** This is a private, community-driven project and is not officially affiliated with JUNG GmbH & Co. KG.

## Anatomy of an interface

Each interface lives in its own subfolder and typically consists of the following files:

| File | Description |
|---|---|
| `InterfaceScript.lua` | Main logic, including the lifecycle callbacks (`Init`, `Exit`, `Poll`, `OnValueRead`, `OnValueChange`) |
| `InterfaceScriptCommonLibrary.lua` | Shared helper library for navigating the datapoint tree |
| `InterfaceDescription.xml` | Defines the datapoint model (`SDVINTERFACE`) with datapoints such as `PVSTRING`, `PVBINARY`, `PVANALOG`, `PVTIME`, and `PVFOLDER` |
| `json.lua` | Optional, for interfaces using JSON-based HTTP communication |

Inside JVP, each interface lives in its own subfolder under:

```
C:\Users\Public\Documents\JUNG Visu Pro\App\EsfSdvEditor\Interfaces\<interface-name>\
```

The folder name shows up in the device editor under "File / Create process interface". A new interface only becomes visible after restarting the device editor.

### Lifecycle callbacks (`InterfaceScript.lua`)

The device editor calls the following functions in every interface script:

| Function | Called … |
|---|---|
| `Init()` | once at startup — initialize values and open resources |
| `OnValueChange(oVarPath, strValue)` | whenever a datapoint's value changes in the process model |
| `Poll()` | cyclically, at the `POLLTIME` interval (ms) defined in `InterfaceDescription.xml` |
| `OnValueRead(oVarPath, nReason)` | whenever the process model wants to read a datapoint's value |
| `Exit()` | once when the interface is closed — close resources |

The helper functions `oVarPath:_findParentFromUserType("...")` (containing folder) and `oVarPath:_getLeaf()` (the changed/read datapoint itself), together with `varLeaf:GetAccessRights()`, `varLeaf:GetValue()`, and `varLeaf:SetValue(strValue, nReason)`, let a script identify and act on the relevant datapoint.

### Resources (external communication)

`InterfaceDescription.xml` can declare the following resources, each with its own Lua API (`Open`, `Close`, `GetRxData(Available)`, `PutTxData`, …):

| Resource | Communication |
|---|---|
| `UDPPORT` | UDP |
| `COMPORT` | Serial interface (RS232 etc.) |
| `TCPSRV` | Internal TCP server |
| `TCPCLIENT` | Internal TCP client |
| `HTTP` | HTTP requests (GET/POST/PUT/DELETE) |

### Datapoints in `InterfaceDescription.xml`

Rough file structure: `<SDVINTERFACE>` → `<INFO>` (name, author, description, version, `APIVERSION`, `POLLTIME` in ms) → `<PVITEMS>` holding the actual datapoints.

| Element | Type |
|---|---|
| `PVANALOG` | Analog value |
| `PVBINARY` | Binary value (`UNIT0`/`UNIT1` = labels for 0/1) |
| `PVSTRING` | Text |
| `PVTIME` | Date/time |
| `PVFOLDER` | Folder, can contain further datapoints/folders |

Common attributes: `SCRIPTNAME` (name used in the Lua script), `DEFAULTNAME` (name shown in the editor), `EXPORT` (whether it's passed to the visualization), `SAVE` (whether the value is persisted when the editor closes), `ACCESS` (`None`/`Read`/`Write`/`Read/Write`), `DESCRIPTION`.

For `PVFOLDER`, `CREATIONTYPE` additionally controls whether the folder can be created (repeatedly) by the user (`Multiple`) or is created once by the editor (`Unique`); `USERTYPE` is a freely chosen identifier the script can use to find matching folders.

### Accessing datapoints from Lua

- `E.PVTable` — global table containing all datapoints/folders defined in the XML; access `Unique` folders directly via `E.PVTable["<SCRIPTNAME>"]`, iterate `Multiple` folders and check `E_UserType`.
- `E.ResourceTable["<SCRIPTNAME>"]` — access a resource declared under `RESOURCES` (e.g. `HTTP_RQ = E.ResourceTable["HTTP"]`).
- Inside `OnValueChange`/`OnValueRead`, `oVarPath:_findParentFromUserType("...")` returns the containing folder ("Parent") and `oVarPath:_getLeaf()` returns the datapoint itself ("Leaf").
- `varLeaf:GetAccessRights()` returns `constAccessNone` / `constAccessRead` / `constAccessWrite` / `constAccessReadWrite` — check before reading/writing.
- `varLeaf:GetValue()` reads the current value (always as text), `varLeaf:SetValue(strValue, nReason)` writes it; `nReason` is typically `constValueChange` (also used to acknowledge a value back to the process model) or `constValueResponse`.

### Developing & testing

- The easiest way to create a new interface is to copy an existing folder and adapt the XML/Lua; after renaming it in the XML, the interface only appears under "File / Create process interface" after **restarting the device editor**.
- Notepad++ (with Lua syntax highlighting) works well for editing the `.lua` files.
- After making changes: save the file, then restart the interface via right-click in the device editor. The **message window** shows Lua errors (e.g. syntax mistakes) with line numbers.
- For HTTP interfaces, helper functions are available: `ConvertASCIIToUTF8`, `ConvertUTF8ToASCII`, `ConvertToURLEncoding` (percent-encoding for URLs).

## Available interfaces

*(continuously updated)*

| Name | Description | Status |
|---|---|---|
| [Dynamic power rate](<DRAFT - Dynamic power rate>) | Day-ahead electricity prices for today and tomorrow: DE/AT (aWATTar), FR/NL (Energy-Charts.info), KR (Elecz.com, current price only). Configurable surcharge/VAT, detection of the cheapest time window, hourly prices exposed as datapoints. | Draft |
| [Philips Hue V2](<DRAFT - Philips hue SSE>) | Connects a Philips Hue bridge via the CLIP v2 API: lights, rooms/zones, scenes, sensors (motion/temperature/contact/battery) and automations. State changes arrive in real time via Server-Sent Events (eventstream) from the bridge, no continuous polling required. | Draft |

Each interface folder currently ships two functionally identical language variants in `English/` and `German/` subfolders (different `DEFAULTNAME` values in the XML, same logic).

## Requirements

- JUNG Visu Pro (latest version recommended)
- Lua 5.1 (JVP runtime; no `goto`, no bitwise operators)
- Access to the target API/protocol used by the given interface (e.g. API credentials), where applicable

## Installation

1. Download the desired interface folder, or clone the repository:
   ```bash
   git clone https://github.com/AlJungOrg/JVP-Interfaces.git
   ```
2. Import the interface folder into the JVP interface editor, or integrate its files according to the JVP documentation.
3. Set the configuration datapoints (e.g. credentials, poll interval) in your project.
4. Enable the interface and link its datapoints in the visualization.

For a detailed guide on building your own interfaces, see the official JVP documentation.

## Further resources

- Official "JUNG Visu Pro software – Lua scripting" tutorial (Albrecht Jung GmbH & Co. KG) — the basis for the interface architecture, XML structure, and Lua API described here.
- [lua.org](https://www.lua.org) — official Lua documentation and language reference.
- Lua scripts can be tested outside JVP too: place `InterfaceScript.lua`, `InterfaceScriptCommonLibrary.lua`, and optionally `json.lua` in a folder alongside a Lua 5.1 runtime and run `lua InterfaceScript.lua` from the command line (syntax check only — JVP-specific globals like `E.PVTable` won't be available).

## Contributing

Contributions are welcome:

1. Fork the repository
2. Create a new folder for the interface (name it after the interface/device)
3. Add `InterfaceScript.lua`, `InterfaceDescription.xml`, and any other required files
4. Include a short description (a README in the subfolder) covering functionality, requirements, and configuration
5. Open a pull request

Please make sure the code is valid Lua 5.1, includes proper error handling, and contains no hardcoded credentials.

## Disclaimer

All interfaces are provided as-is, without warranty. Use at your own risk — especially when connecting to production building automation systems. Changes to third-party APIs may cause interfaces to stop working as expected.

## License

Unless stated otherwise, the code in this repository is licensed under the [MIT License](LICENSE).

## Contact

Please submit questions, suggestions, or bug reports via [Issues](../../issues).
