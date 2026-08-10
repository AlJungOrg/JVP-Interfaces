-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script PhilipsHueInterface
--
-- JUNG Visu Pro (JVP) Prozessanschluss fuer eine Philips Hue Bridge (lokales
-- Netzwerk, CLIP v1 REST-API fuer Lampen/Gruppen/Szenen/Sensoren/Regeln,
-- optional CLIP v2 fuer den Anwesenheitsstatus/Geofencing).
--
-- WICHTIGER HINWEIS ZUR HTTP-RESSOURCE:
-- Laut JVP-Dokumentation "Prozessinterface HTTP Befehle" ist der HTTP-Request-
-- Typ NUMERISCH kodiert: 0=GET, 1=POST, 2=PUT, 3=DELETE. Diese Zahlen werden
-- direkt als "method" an SendRequest() uebergeben (kein String, keine globale
-- Konstante - beides hatte zuvor zu einem GET-Fallback der Bridge gefuehrt).
--
-- Alle Datenpunkt-SCRIPTNAMEs sind ueber das gesamte Interface hinweg
-- eindeutig (Praefix pro Instanztyp: LIGHT_/GROUP_/SCENE_/SENSOR_/AUTOMATION_),
-- da JVP SCRIPTNAME nicht nur pro Ordner, sondern global eindeutig verlangt.
--
-- SENDE-/EMPFANGSDATENPUNKTE: Steuerbare Werte (Ein/Aus, Helligkeit, Farbe, ...)
-- sind in je zwei Datenpunkte aufgeteilt: "*_CMD" (Write, Sendedatenpunkt - vom
-- Bediener/der Visualisierung Richtung Bridge) und der Basisname ohne Suffix
-- (Read, Empfangsdatenpunkt/Rueckmeldung - von der Bridge zurueck). Jeder
-- eingehende Schreibzugriff wird in OnValueChange() sofort mit constWriteAck
-- quittiert; die apply*/refreshSingle*-Funktionen schreiben die Rueckmeldung
-- dagegen mit constValueChange (siehe setVal()).
--
-- POLLING: Zustaende werden generell nur einmalig bei Init() bzw. manuell ueber
-- CONFIGURATION.REFRESH_STATES abgefragt (die Anlage aendert sich selten).
-- Ausnahme: jede Lampe hat ein eigenes LIGHT_POLL_INTERVAL (Sekunden, 0=aus);
-- ist es gesetzt, wird genau diese Lampe automatisch im eingestellten
-- Rhythmus nachgefragt (siehe pollLightsIfDue(), aufgerufen aus Poll() alle
-- mg_nPollSeconds).
--
-- LOGGING (kommerzieller Betrieb): traceMsg() ersetzt E:trace() und schreibt
-- jede Meldung zusaetzlich (mit Uhrzeit) in den rollierenden STATUS.DEBUG_LOG
-- Datenpunkt (PVSTRING) - der Inhalt laesst sich direkt aus dem JVP-Editor
-- kopieren. Bewusst NICHT protokolliert werden einzelne HTTP-Anfragen,
-- Schaltbefehle oder erfolgreiche Nachlade-/Poll-Vorgaenge - das waere fuer
-- den Dauerbetrieb zu viel Rauschen. Protokolliert werden nur: Start/Stop
-- (Init/Exit), Pairing-Ablauf, Verbindungs-/Anwesenheitswechsel und
-- Fehlermeldungen (HTTP-, JSON-, Konfigurationsfehler etc.).
-- CONFIGURATION.CLEAR_DEBUG_LOG (auf 1 setzen) leert das Log wieder.
--
-- Target runtime: Lua 5.1.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"
json = require "json"

mg_nPollSeconds = 5                -- keep in sync with INFO POLLTIME (5000 ms)
local MAX_DEBUG_LOG_LEN = 4000     -- character budget for STATUS.DEBUG_LOG

CFG    = nil                       -- CONFIGURATION folder (set in Init)
STATUS = nil                       -- STATUS folder (set in Init)
HTTP_RQ = nil                      -- HTTP resource (set in Init)

LIGHTTABLE      = {}               -- Hue light id      -> Light instance folder
GROUPTABLE      = {}               -- Hue group id       -> Group instance folder
SCENETABLE      = {}               -- Hue scene id       -> Scene instance folder
SENSORTABLE     = {}               -- Hue sensor id      -> Sensor instance folder
AUTOMATIONTABLE = {}               -- Hue rule id        -> Automation instance folder

g_pairing         = false          -- true while a pairing attempt window is open
g_pairingDeadline = 0               -- os.time() at which the pairing window closes
g_pollCount       = 0               -- Poll() invocation counter (staggers slow polls)
g_prevTriggerCount = {}            -- rule id -> last seen "timestriggered" value
g_lastConnected   = nil            -- previous CONNECTED state, for change-only tracing
g_lastPresent     = nil            -- previous ANY_PRESENT state, for change-only tracing
g_lastLightPoll   = {}             -- Hue light id -> os.time() of last automatic refresh

-------------------------------------------------------------------------------
-- Generic helpers
-------------------------------------------------------------------------------

local function round( x )
	return math.floor( x + 0.5 )
end

local function clamp( x, lo, hi )
	if (x < lo) then return lo end
	if (x > hi) then return hi end
	return x
end

--- Read a datapoint as a number, tolerant of German comma / unit suffixes.
local function getNum( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return 0 end
	local s = oNode[strName]:GetValue()
	if (s == nil) then return 0 end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	return tonumber( (s:match( "[-+]?%d+%.?%d*" )) ) or 0
end

--- Parse a raw text value (e.g. strValue from OnValueChange) as a number,
-- tolerant of German comma decimals ("100,000000") and unit suffixes.
-- Plain tonumber() returns nil for comma decimals, which previously made
-- every *_CMD handler silently fall back to its "or 0"/"or 2700" default
-- (e.g. Helligkeit=100,000000% was sent to the bridge as bri=1).
local function parseNum( s )
	if (s == nil) then return nil end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	return tonumber( (s:match( "[-+]?%d+%.?%d*" )) )
end

--- Read a datapoint as text ("" if missing).
local function getStr( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return "" end
	return oNode[strName]:GetValue() or ""
end

--- Write a datapoint (guarded against missing nodes).
local function setVal( oNode, strName, value )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		oNode[strName]:SetValue( tostring(value), constValueChange )
	end
end

--- Current time as text in the project format.
local function nowStr()
	return os.date( "%d.%m.%Y %H:%M:%S", os.time() )
end

--- Count entries in a hash-style table (Hue-id -> instance folder).
local function tblCount( t )
	local n = 0
	for _ in pairs( t ) do n = n + 1 end
	return n
end

--- Trace to the JVP log AND append to the rolling STATUS.DEBUG_LOG datapoint
-- (timestamped, oldest lines dropped once MAX_DEBUG_LOG_LEN is exceeded).
local function traceMsg( msg )
	E:trace( msg )
	if (STATUS == nil) or (STATUS["DEBUG_LOG"] == nil) then return end
	local line = os.date( "%H:%M:%S", os.time() ) .. " " .. tostring(msg)
	local current = getStr( STATUS, "DEBUG_LOG" )
	local updated = (current == "") and line or (current .. "\n" .. line)
	if (#updated > MAX_DEBUG_LOG_LEN) then
		updated = updated:sub( #updated - MAX_DEBUG_LOG_LEN + 1 )
		local nl = updated:find( "\n" )
		if (nl ~= nil) then updated = updated:sub( nl + 1 ) end
	end
	setVal( STATUS, "DEBUG_LOG", updated )
end

--- Convert a UTF-8 Hue name (e.g. containing Umlaute) to something JVP's
-- PVSTRING displays correctly. Falls back to the raw string if the HTTP
-- resource's ConvertUTF8ToASCII() is unavailable or errors.
local function fixName( raw )
	if (raw == nil) then return "" end
	if (HTTP_RQ == nil) then return raw end
	local ok, converted = pcall( function() return HTTP_RQ:ConvertUTF8ToASCII( raw ) end )
	if (ok and (converted ~= nil)) then return converted end
	return raw
end

-------------------------------------------------------------------------------
-- Value conversions: JVP-Datenpunkte (%, Kelvin, Grad) <-> Hue-API-Werte
-------------------------------------------------------------------------------

local function percentToBri( p )  return clamp( round( (p or 0) / 100 * 254 ), 1, 254 ) end
-- Hue's "bri" laeuft von 1 (Minimum, Lampe ist an) bis 254 - 0 bedeutet in der
-- API "aus" und kommt bei einer erreichbaren/eingeschalteten Lampe nicht vor.
-- Reines lineares Runden (1/254*100 = 0.39%) wuerde bei bri=1 auf 0% runden -
-- die Hue-App zeigt in diesem Fall jedoch "1%" an, nie "0%", solange die Lampe
-- an ist. Daher: jeder bri-Wert > 0 wird auf mindestens 1% angehoben, damit die
-- JVP-Anzeige mit der Hue-App uebereinstimmt.
local function briToPercent( b )
	if ((b == nil) or (b <= 0)) then return 0 end
	return clamp( round( b / 254 * 100 ), 1, 100 )
end
local function kelvinToMired( k ) return clamp( round( 1000000 / math.max( k or 2700, 1 ) ), 153, 500 ) end
local function miredToKelvin( m ) return round( 1000000 / math.max( m or 300, 1 ) ) end
local function degToHueVal( d )   return clamp( round( (d or 0) / 360 * 65535 ), 0, 65535 ) end
local function hueValToDeg( h )   return round( (h or 0) / 65535 * 360 ) end
local function percentToSat( p )  return clamp( round( (p or 0) / 100 * 254 ), 0, 254 ) end
local function satToPercent( s )  return clamp( round( (s or 0) / 254 * 100 ), 0, 100 ) end

-------------------------------------------------------------------------------
-- HTTP / Hue-API
-------------------------------------------------------------------------------

--- Perform one HTTP request against the bridge and JSON-decode the response.
-- Every single sub-step (SetURL/Headers/Open/SendRequest/GetRxData/Close) is
-- wrapped in pcall(), but only actual FAILURES are traced (kommerzieller
-- Betrieb: STATUS.DEBUG_LOG/E:trace sollen nur Startverhalten und
-- Fehlermeldungen enthalten, kein Mitschnitt jedes einzelnen HTTP-Schritts).
-- @param method       number  HTTP-Methode numerisch: 0=GET, 1=POST, 2=PUT, 3=DELETE.
-- @param path          string  URL path, e.g. "/api/<key>/lights".
-- @param bodyTable     table|nil  Lua table to JSON-encode as the request body.
-- @param useHttps      boolean  true for the CLIP v2 (HTTPS) API, false for CLIP v1 (HTTP).
-- @param useAppKeyHeader boolean  true to send the "hue-application-key" header (CLIP v2).
-- @return table|nil decoded response, string|nil error
local function httpRequest( method, path, bodyTable, useHttps, useAppKeyHeader )
	if (HTTP_RQ == nil) then
		traceMsg( "FEHLER - E.ResourceTable[\"HTTP\"] ist nil" )
		return nil, "HTTP-Ressource nicht initialisiert"
	end
	local host = getStr( CFG, "BRIDGE_IP" )
	if (host == "") then
		traceMsg( "FEHLER - Keine Bridge-IP konfiguriert" )
		return nil, "Keine Bridge-IP konfiguriert"
	end

	local url = (useHttps and "https://" or "http://") .. host .. path
	local body = ""
	if (bodyTable ~= nil) then body = json.encode( bodyTable ) end

	-- Reihenfolge: SetURL() MUSS vor Open() aufgerufen werden - Open() scheint
	-- mit der zu diesem Zeitpunkt bereits gesetzten URL zu verbinden. Open()/
	-- Close() werden bewusst pro Request aufgerufen, nicht einmalig in Init()/
	-- Exit(), da die Ressource sonst mit einem Default-Ziel ("GET /") verbindet.
	local pOk, pErr

	pOk, pErr = pcall( function() HTTP_RQ:SetURL( url ) end )
	if (not pOk) then
		traceMsg( "FEHLER SetURL (" .. path .. "): " .. tostring(pErr) )
		return nil, "SetURL fehlgeschlagen: " .. tostring(pErr)
	end

	pcall( function() HTTP_RQ:RemoveHeaders() end )
	pcall( function() HTTP_RQ:AddHeader( "Content-Type: application/json" ) end )
	if (useAppKeyHeader) then
		pcall( function() HTTP_RQ:AddHeader( "hue-application-key: " .. getStr( CFG, "API_KEY" ) ) end )
	end

	pOk, pErr = pcall( function() HTTP_RQ:Open() end )
	if (not pOk) then
		traceMsg( "FEHLER Open (" .. path .. "): " .. tostring(pErr) )
		return nil, "Open fehlgeschlagen: " .. tostring(pErr)
	end

	pOk, pErr = pcall( function() HTTP_RQ:SendRequest( method, body ) end )
	if (not pOk) then
		traceMsg( "FEHLER SendRequest (" .. path .. "): " .. tostring(pErr) )
		pcall( function() HTTP_RQ:Close() end )
		return nil, "SendRequest fehlgeschlagen: " .. tostring(pErr)
	end

	local rxOk, returnCode, err, httpStatus, data = pcall( function() return HTTP_RQ:GetRxData() end )
	if (not rxOk) then
		traceMsg( "FEHLER GetRxData (" .. path .. "): " .. tostring(returnCode) )
		pcall( function() HTTP_RQ:Close() end )
		return nil, "GetRxData fehlgeschlagen: " .. tostring(returnCode)
	end

	pcall( function() HTTP_RQ:Close() end )

	if ((err ~= nil) and (tostring(err) ~= "")) then
		traceMsg( "HTTP-Fehler bei " .. path .. ": " .. tostring(err) )
		return nil, tostring(err)
	end
	local hs = tonumber( httpStatus )
	if ((hs ~= nil) and ((hs < 200) or (hs >= 300))) then
		traceMsg( "HTTP " .. tostring(hs) .. " bei " .. path )
		return nil, "HTTP " .. tostring(hs)
	end
	if ((data == nil) or (data == "")) then
		traceMsg( "Leere Antwort bei " .. path )
		return nil, "Leere Antwort"
	end

	local jOk, decoded = pcall( json.decode, data )
	if (not jOk) then
		traceMsg( "JSON-Fehler bei " .. path .. ": " .. tostring(decoded) )
		return nil, "JSON-Fehler: " .. tostring(decoded)
	end
	return decoded, nil
end

-------------------------------------------------------------------------------
-- Automatische Bridge-Erkennung (Fallback bei geaenderter Bridge-IP)
-------------------------------------------------------------------------------

local DISCOVERY_URL              = "https://discovery.meethue.com/"
local AUTO_DISCOVER_MIN_INTERVAL = 300  -- Sekunden zwischen zwei Erkennungsversuchen (Rate-Limit fuer discovery.meethue.com)
g_lastAutoDiscoverAttempt = 0

--- Fragt Philips' Cloud-Discovery-Dienst nach der aktuell von der Bridge
-- verwendeten internen IP-Adresse und uebernimmt sie in CONFIGURATION.BRIDGE_IP,
-- falls sie sich von der bisher konfigurierten unterscheidet. Wird NUR als
-- Fallback bei bereits erkanntem Verbindungsverlust aufgerufen (siehe
-- RefreshStates()/pollLightsIfDue()), nicht bei jedem einzelnen HTTP-Fehler,
-- und selbst dann hoechstens alle AUTO_DISCOVER_MIN_INTERVAL Sekunden, um den
-- Cloud-Dienst nicht unnoetig zu belasten. Nur aktiv, wenn der Installateur
-- CONFIGURATION.AUTO_DISCOVER_IP eingeschaltet hat.
-- @return boolean true, wenn eine neue IP uebernommen wurde
local function tryAutoDiscoverBridgeIp()
	if (HTTP_RQ == nil) then return false end
	local now = os.time()
	if ((now - g_lastAutoDiscoverAttempt) < AUTO_DISCOVER_MIN_INTERVAL) then return false end
	g_lastAutoDiscoverAttempt = now

	traceMsg( "Automatische Bridge-Erkennung ueber discovery.meethue.com wird versucht" )

	local pOk, pErr
	pOk, pErr = pcall( function() HTTP_RQ:SetURL( DISCOVERY_URL ) end )
	if (not pOk) then
		traceMsg( "FEHLER Auto-Erkennung SetURL: " .. tostring(pErr) )
		return false
	end
	pcall( function() HTTP_RQ:RemoveHeaders() end )
	pOk, pErr = pcall( function() HTTP_RQ:Open() end )
	if (not pOk) then
		traceMsg( "FEHLER Auto-Erkennung Open: " .. tostring(pErr) )
		return false
	end
	pOk, pErr = pcall( function() HTTP_RQ:SendRequest( 0, "" ) end )
	if (not pOk) then
		traceMsg( "FEHLER Auto-Erkennung SendRequest: " .. tostring(pErr) )
		pcall( function() HTTP_RQ:Close() end )
		return false
	end
	local rxOk, returnCode, err, httpStatus, data = pcall( function() return HTTP_RQ:GetRxData() end )
	pcall( function() HTTP_RQ:Close() end )
	if ((not rxOk) or (data == nil) or (data == "")) then
		traceMsg( "Automatische Bridge-Erkennung fehlgeschlagen - keine Antwort von discovery.meethue.com" )
		return false
	end

	local jOk, decoded = pcall( json.decode, data )
	if ((not jOk) or (type(decoded) ~= "table") or (decoded[1] == nil)) then
		traceMsg( "Automatische Bridge-Erkennung fehlgeschlagen - keine Bridge gemeldet" )
		return false
	end

	local newIp = decoded[1]["internalipaddress"]
	if ((newIp == nil) or (newIp == "")) then
		traceMsg( "Automatische Bridge-Erkennung fehlgeschlagen - keine IP in der Antwort" )
		return false
	end

	local oldIp = getStr( CFG, "BRIDGE_IP" )
	if (newIp == oldIp) then
		traceMsg( "Automatische Bridge-Erkennung: IP unveraendert (" .. newIp .. ")" )
		return false
	end

	traceMsg( "Automatische Bridge-Erkennung: Bridge-IP geaendert von " .. tostring(oldIp) .. " auf " .. newIp )
	setVal( CFG, "BRIDGE_IP", newIp )
	return true
end

-------------------------------------------------------------------------------
-- Instanztabellen (Multiple-Ordner -> Hue-ID)
-------------------------------------------------------------------------------

--- @param rootScriptName string  SCRIPTNAME of the Unique parent folder ("Lichter"/"Szenen"/...)
--   the Multiple folder now lives under (Baumstruktur-Wunsch: ein Hauptordner
--   pro Kategorie, in dem der Installateur die Instanzen anlegt).
-- @param scriptName string  SCRIPTNAME of the nested Multiple folder itself.
local function buildTable( rootScriptName, scriptName, usertype, idField )
	local out = {}
	local root = E.PVTable[rootScriptName]
	if (root == nil) then return out end
	local list = root[scriptName]
	if (list == nil) then return out end
	for i, tbl in pairs( list ) do
		if (type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == usertype) then
			local id = getStr( tbl, idField )
			if (id ~= "") then out[id] = tbl end
		end
	end
	return out
end

--- Rebuild all Hue-id -> instance-folder lookup tables. Cheap; called every Poll()
-- so that the *_HUE_ID values entered/edited by the installer take effect immediately.
function RebuildInstanceTables()
	LIGHTTABLE      = buildTable( "LIGHTS_ROOT",      "Light",      "light_t",      "LIGHT_HUE_ID" )
	GROUPTABLE      = buildTable( "GROUPS_ROOT",      "Group",      "group_t",      "GROUP_HUE_ID" )
	SCENETABLE      = buildTable( "SCENES_ROOT",      "Scene",      "scene_t",      "SCENE_HUE_ID" )
	SENSORTABLE     = buildTable( "SENSORS_ROOT",     "Sensor",     "sensor_t",     "SENSOR_HUE_ID" )
	AUTOMATIONTABLE = buildTable( "AUTOMATIONS_ROOT", "Automation", "automation_t", "AUTOMATION_HUE_ID" )
end

-------------------------------------------------------------------------------
-- Bridge-Antworten auf Instanzen abbilden
-------------------------------------------------------------------------------

--- Werte einer einzelnen Lampe auf ihre Instanz schreiben. LIGHT_REACHABLE wird
-- nur gesetzt, wenn die Bridge das Feld liefert - neuere Hue-Firmwares/Zigbee-
-- Fremdgeraete liefern "reachable" oft gar nicht mehr, ein hartes false->0 haette
-- den Datenpunkt sonst dauerhaft auf "nicht erreichbar" stehen lassen.
local function applyOneLight( oInst, l )
	local state = l.state or {}
	setVal( oInst, "LIGHT_NAME", fixName(l.name) )
	setVal( oInst, "LIGHT_ON", (state.on == true) and 1 or 0 )
	if (state.bri ~= nil) then setVal( oInst, "LIGHT_BRIGHTNESS", briToPercent(state.bri) ) end
	if (state.ct  ~= nil) then setVal( oInst, "LIGHT_COLORTEMP",  miredToKelvin(state.ct) ) end
	if (state.hue ~= nil) then setVal( oInst, "LIGHT_HUEANGLE",   hueValToDeg(state.hue) ) end
	if (state.sat ~= nil) then setVal( oInst, "LIGHT_SATURATION", satToPercent(state.sat) ) end
	if (state.reachable ~= nil) then setVal( oInst, "LIGHT_REACHABLE", (state.reachable == true) and 1 or 0 ) end
	setVal( oInst, "LIGHT_LASTUPDATE", nowStr() )
end

local function applyLights( data )
	if (type(data) ~= "table") then return end
	for id, oInst in pairs( LIGHTTABLE ) do
		local l = data[id]
		if (type(l) == "table") then applyOneLight( oInst, l ) end
	end
end

local function applyOneGroup( oInst, g )
	local state  = g.state or {}
	local action = g.action or {}
	setVal( oInst, "GROUP_NAME", fixName(g.name) )
	setVal( oInst, "GROUP_ANY_ON", (state.any_on == true) and 1 or 0 )
	setVal( oInst, "GROUP_ALL_ON", (state.all_on == true) and 1 or 0 )
	setVal( oInst, "GROUP_ON", (action.on == true) and 1 or 0 )
	if (action.bri ~= nil) then setVal( oInst, "GROUP_BRIGHTNESS", briToPercent(action.bri) ) end
end

local function applyGroups( data )
	if (type(data) ~= "table") then return end
	for id, oInst in pairs( GROUPTABLE ) do
		local g = data[id]
		if (type(g) == "table") then applyOneGroup( oInst, g ) end
	end
end

--- Werte einer einzelnen Szene auf ihre Instanz schreiben. `groupName` (falls
-- bekannt) wird nach SCENE_GROUP_NAME geschrieben, damit gleichnamige Szenen
-- in verschiedenen Raeumen (z.B. "Nachtlicht" in jedem Zimmer) unterscheidbar
-- sind. Die Ziel-Gruppen-ID wird nur bei Raum-Szenen von der Bridge
-- uebernommen (sc.group vorhanden); raumlose Lampen-Szenen behalten den
-- manuell eingetragenen Wert.
local function applyOneScene( oInst, sc, groupName )
	setVal( oInst, "SCENE_NAME", fixName(sc.name) )
	if ((sc.group ~= nil) and (tostring(sc.group) ~= "")) then
		setVal( oInst, "SCENE_TARGET_GROUP_ID", sc.group )
	end
	setVal( oInst, "SCENE_GROUP_NAME", groupName or "" )
end

--- @param groupsData table|nil  Rohdaten von GET /groups (id -> {name=...}), um
--   den Raumnamen je Szene aufzuloesen, ohne dafuer eine eigene JVP-Instanz
--   des Raums zu benoetigen.
local function applyScenes( data, groupsData )
	if (type(data) ~= "table") then return end
	for id, oInst in pairs( SCENETABLE ) do
		local sc = data[id]
		if (type(sc) == "table") then
			local groupName = ""
			if ((sc.group ~= nil) and (type(groupsData) == "table") and (type(groupsData[sc.group]) == "table")) then
				groupName = fixName( groupsData[sc.group].name )
			end
			applyOneScene( oInst, sc, groupName )
		end
	end
end

--- Interpret a Hue sensor's `state` block depending on its `type`.
-- @return string valueText, number numericValue
local function classifySensor( s )
	local t = s.type or ""
	local state = s.state or {}
	if (t == "ZLLPresence") or (t == "ZGPPresence") or (t == "CLIPPresence") then
		local p = (state.presence == true)
		return (p and "Bewegung erkannt" or "keine Bewegung"), (p and 1 or 0)
	elseif (t == "ZLLTemperature") or (t == "CLIPTemperature") then
		local c = (tonumber(state.temperature) or 0) / 100
		return string.format( "%.1f C", c ), c
	elseif (t == "ZLLLightLevel") or (t == "CLIPLightLevel") then
		local ll = tonumber( state.lightlevel )
		local lux = 0
		if ((ll ~= nil) and (ll > 0)) then lux = 10 ^ ((ll - 1) / 10000) end
		return string.format( "%.0f lx", lux ), lux
	elseif (t == "ZLLSwitch") or (t == "ZGPSwitch") or (t == "CLIPSwitch") or (t == "ZHASwitch") then
		-- Taster/Fernbedienungen UND Zigbee-Türklingeln (Friends of Hue) laufen
		-- ueber die Bridge als ZHASwitch-Sensor mit buttonevent - es gibt keinen
		-- eigenen Hue-API-Typ "Doorbell".
		local be = tonumber( state.buttonevent ) or 0
		return tostring( be ), be
	elseif (t == "ZHAOpenClose") or (t == "CLIPOpenClose") then
		-- Fensterkontakte/Tuerkontakte (Friends of Hue, z.B. Aqara/Busch-Jaeger)
		local o = (state.open == true)
		return (o and "offen" or "geschlossen"), (o and 1 or 0)
	elseif (t == "Daylight") then
		local d = (state.daylight == true)
		return (d and "Tag" or "Nacht"), (d and 1 or 0)
	end
	return "-", 0
end

local function applyOneSensor( oInst, s )
	setVal( oInst, "SENSOR_NAME", fixName(s.name) )
	setVal( oInst, "SENSOR_TYPE", s.type or "" )
	local valueText, numericValue = classifySensor( s )
	setVal( oInst, "SENSOR_VALUE", valueText )
	setVal( oInst, "SENSOR_NUMERICVALUE", numericValue )
	local t = s.type or ""
	if ((t == "ZHAOpenClose") or (t == "CLIPOpenClose")) then
		local state = s.state or {}
		setVal( oInst, "SENSOR_CONTACT", (state.open == true) and 1 or 0 )
	end
	local cfg = s.config or {}
	if (cfg.battery ~= nil) then setVal( oInst, "SENSOR_BATTERY", cfg.battery ) end
	setVal( oInst, "SENSOR_LASTUPDATED", nowStr() )
end

local function applySensors( data )
	if (type(data) ~= "table") then return end
	for id, oInst in pairs( SENSORTABLE ) do
		local s = data[id]
		if (type(s) == "table") then applyOneSensor( oInst, s ) end
	end
end

--- Map one Hue "rule" (v1) onto an Automation instance. `AUTOMATION_LASTTRIGGERED`
-- is stamped with the time JVP observed the trigger count increase - the
-- bridge's own `lasttriggered` timestamp is UTC and is not reproduced exactly.
local function applyOneAutomation( oInst, r, id )
	setVal( oInst, "AUTOMATION_NAME", fixName(r.name) )
	setVal( oInst, "AUTOMATION_ENABLED", (r.status == "enabled") and 1 or 0 )
	local tt = tonumber( r.timestriggered ) or 0
	setVal( oInst, "AUTOMATION_TIMESTRIGGERED", tt )
	if ((g_prevTriggerCount[id] ~= nil) and (tt > g_prevTriggerCount[id])) then
		setVal( oInst, "AUTOMATION_LASTTRIGGERED", nowStr() )
	end
	g_prevTriggerCount[id] = tt
end

local function applyAutomations( data )
	if (type(data) ~= "table") then return end
	for id, oInst in pairs( AUTOMATIONTABLE ) do
		local r = data[id]
		if (type(r) == "table") then applyOneAutomation( oInst, r, id ) end
	end
end

--- CLIP v2 geofence_client resource: true if any registered phone is "at home".
-- Traces only on state change to avoid log spam.
local function applyGeofence( data )
	if (type(data) ~= "table") then return end
	local list = data.data or {}
	local anyHome = false
	for _, client in pairs( list ) do
		if ((type(client) == "table") and (client.is_at_home == true)) then anyHome = true end
	end
	if (g_lastPresent ~= anyHome) then
		traceMsg( "Anwesenheit geaendert - " .. (anyHome and "jemand zuhause" or "niemand zuhause") )
		g_lastPresent = anyHome
	end
	setVal( STATUS, "ANY_PRESENT", anyHome and 1 or 0 )
end

-------------------------------------------------------------------------------
-- Einzel-Instanz-Refresh (wenn eine *_HUE_ID neu eingetragen/geaendert wird)
-------------------------------------------------------------------------------

--- Laedt genau eine Lampe/Gruppe/Szene/Sensor/Automation von der Bridge nach
-- und schreibt sie auf die uebergebene Instanz. Wird aus OnValueChange()
-- ausgeloest, sobald ein *_HUE_ID-Feld geaendert wird, damit Name/Status einer
-- neu eingetragenen ID nicht erst auf den naechsten manuellen
-- CONFIGURATION.REFRESH_STATES warten muessen.
-- @return boolean true bei Erfolg (oder wenn nichts zu tun war), false bei HTTP-Fehler
local function refreshSingleLight( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return true end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/lights/" .. id, nil, false, false )
	if (data ~= nil) then
		applyOneLight( oInst, data )
		return true
	else
		traceMsg( "Lampe " .. id .. " konnte nicht nachgeladen werden: " .. tostring(err) )
		return false
	end
end

local function refreshSingleGroup( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/groups/" .. id, nil, false, false )
	if (data ~= nil) then
		applyOneGroup( oInst, data )
	else
		traceMsg( "Gruppe " .. id .. " konnte nicht nachgeladen werden: " .. tostring(err) )
	end
end

local function refreshSingleScene( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/scenes/" .. id, nil, false, false )
	if (data ~= nil) then
		local groupName = ""
		if ((data.group ~= nil) and (tostring(data.group) ~= "")) then
			local groupData = httpRequest( 0, "/api/" .. apiKey .. "/groups/" .. tostring(data.group), nil, false, false )
			if (type(groupData) == "table") then groupName = fixName( groupData.name ) end
		end
		applyOneScene( oInst, data, groupName )
	else
		traceMsg( "Szene " .. id .. " konnte nicht nachgeladen werden: " .. tostring(err) )
	end
end

local function refreshSingleSensor( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/sensors/" .. id, nil, false, false )
	if (data ~= nil) then
		applyOneSensor( oInst, data )
	else
		traceMsg( "Sensor " .. id .. " konnte nicht nachgeladen werden: " .. tostring(err) )
	end
end

local function refreshSingleAutomation( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/rules/" .. id, nil, false, false )
	if (data ~= nil) then
		applyOneAutomation( oInst, data, id )
	else
		traceMsg( "Automation " .. id .. " konnte nicht nachgeladen werden: " .. tostring(err) )
	end
end

-------------------------------------------------------------------------------
-- Status-Refresh (einmalig bei Init(), danach nur auf Anfrage)
-------------------------------------------------------------------------------

--- Fragt Zustaende aller konfigurierten Lampen/Gruppen/Sensoren/Szenen/
-- Automationen (und ggf. Anwesenheit) einmal komplett von der Bridge ab und
-- schreibt sie auf die Instanzen. Laeuft NICHT mehr automatisch in jedem
-- Poll()-Zyklus - die Anlage aendert sich selten. Stattdessen: einmalig am
-- Ende von Init() und danach nur noch auf Anfrage ueber den Datenpunkt
-- CONFIGURATION.REFRESH_STATES. Schreibbefehle (OnValueChange) sind davon
-- unabhaengig und wirken weiterhin sofort.
-- @param isRetryAfterDiscovery boolean|nil  intern gesetzt, wenn dies der einmalige
--        Wiederholungsversuch nach einer automatischen Bridge-Erkennung ist
--        (verhindert eine Endlosschleife bei weiterhin fehlschlagender Verbindung)
function RefreshStates( isRetryAfterDiscovery )
	local apiKey   = getStr( CFG, "API_KEY" )
	local bridgeIp = getStr( CFG, "BRIDGE_IP" )
	if ((bridgeIp == "") or (apiKey == "")) then
		setVal( STATUS, "CONNECTED", 0 )
		traceMsg( "Status-Refresh uebersprungen - Bridge-IP oder API-Key fehlt" )
		return
	end

	traceMsg( "Status-Refresh gestartet" )
	local base = "/api/" .. apiKey
	local allOk = true

	local lights, errLights = httpRequest( 0, base .. "/lights", nil, false, false )
	if (lights ~= nil) then
		applyLights( lights )
	else
		allOk = false
		setVal( STATUS, "LAST_ERROR", "Lights: " .. tostring(errLights) )
	end

	local groups, errGroups = httpRequest( 0, base .. "/groups", nil, false, false )
	if (groups ~= nil) then
		applyGroups( groups )
	else
		allOk = false
		setVal( STATUS, "LAST_ERROR", "Groups: " .. tostring(errGroups) )
	end

	local sensors, errSensors = httpRequest( 0, base .. "/sensors", nil, false, false )
	if (sensors ~= nil) then
		applySensors( sensors )
	else
		allOk = false
		setVal( STATUS, "LAST_ERROR", "Sensors: " .. tostring(errSensors) )
	end

	local scenes, errScenes = httpRequest( 0, base .. "/scenes", nil, false, false )
	if (scenes ~= nil) then
		applyScenes( scenes, groups )
	else
		setVal( STATUS, "LAST_ERROR", "Scenes: " .. tostring(errScenes) )
	end

	local rules, errRules = httpRequest( 0, base .. "/rules", nil, false, false )
	if (rules ~= nil) then
		applyAutomations( rules )
	else
		setVal( STATUS, "LAST_ERROR", "Rules: " .. tostring(errRules) )
	end

	if (getStr( CFG, "GEOFENCE_ENABLED" ) == "1") then
		local geo, errGeo = httpRequest( 0, "/clip/v2/resource/geofence_client", nil, true, true )
		if (geo ~= nil) then
			applyGeofence( geo )
		else
			setVal( STATUS, "LAST_ERROR", "Geofence: " .. tostring(errGeo) )
		end
	end

	if (g_lastConnected ~= allOk) then
		traceMsg( "Verbindung " .. (allOk and "wiederhergestellt" or "verloren") )
		g_lastConnected = allOk
	end

	setVal( STATUS, "CONNECTED", allOk and 1 or 0 )
	setVal( STATUS, "LAST_UPDATE", nowStr() )
	traceMsg( "Status-Refresh abgeschlossen" )

	if ((not allOk) and (not isRetryAfterDiscovery) and (getStr( CFG, "AUTO_DISCOVER_IP" ) == "1")) then
		if (tryAutoDiscoverBridgeIp()) then
			RefreshStates( true )
		end
	end
end

-------------------------------------------------------------------------------
-- Inventar (Hue-IDs -> Namen, zum Uebertragen in JVP-Instanzen)
-------------------------------------------------------------------------------

local MAX_INVENTORY_LEN = 6000  -- Zeichen-Budget PRO Kategorie (eigenes Feld je Kategorie, siehe unten)

--- IDs (Lua-Table-Keys) numerisch sortiert zurueckgeben, fuer eine lesbare Reihenfolge.
local function sortedIds( tbl )
	local ids = {}
	for id in pairs( tbl ) do ids[#ids + 1] = id end
	table.sort( ids, function( a, b )
		local na, nb = tonumber(a), tonumber(b)
		if ((na ~= nil) and (nb ~= nil)) then return na < nb end
		return tostring(a) < tostring(b)
	end )
	return ids
end

--- Baut eine Tab-getrennte Zeilenliste aus `lines` und schreibt sie (bei Bedarf
-- gekuerzt) in das angegebene STATUS-Feld. Jede Kategorie hat ihr eigenes Feld,
-- damit eine lange Szenenliste nicht die nachfolgenden Kategorien verdraengt.
local function writeInventoryField( fieldName, lines, label )
	local full = table.concat( lines, "\n" )
	if (#full > MAX_INVENTORY_LEN) then
		full = full:sub( 1, MAX_INVENTORY_LEN ) .. "\n... (gekuerzt - " .. tostring(#lines) .. " Zeilen gesamt)"
	end
	setVal( STATUS, fieldName, full )
end

--- Fragt Lampen/Gruppen/Szenen/Sensoren/Regeln komplett von der Bridge ab und
-- schreibt je Kategorie eine eigene Tab-getrennte Liste (Hue-ID / Name /
-- Zusatzinfo) nach STATUS.INVENTORY_* - unabhaengig von bereits angelegten
-- JVP-Instanzen, damit man vor dem Anlegen der Instanzen weiss, welche IDs
-- verfuegbar sind.
local function dumpInventory()
	local apiKey = getStr( CFG, "API_KEY" )
	if (apiKey == "") then
		traceMsg( "Inventar: kein API-Key - erst Pairing durchfuehren" )
		return
	end
	local base = "/api/" .. apiKey

	local lights = httpRequest( 0, base .. "/lights", nil, false, false )
	if (type(lights) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(lights) ) do
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( lights[id].name )
		end
		writeInventoryField( "INVENTORY_LIGHTS", lines, "Lichter" )
	end

	local groups = httpRequest( 0, base .. "/groups", nil, false, false )
	if (type(groups) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(groups) ) do
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( groups[id].name )
		end
		writeInventoryField( "INVENTORY_GROUPS", lines, "Gruppen" )
	end

	local scenes = httpRequest( 0, base .. "/scenes", nil, false, false )
	if (type(scenes) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(scenes) ) do
			local sc = scenes[id]
			local groupLabel = "-"
			if (sc.group ~= nil) then
				groupLabel = tostring( sc.group )
				if ((type(groups) == "table") and (type(groups[sc.group]) == "table")) then
					groupLabel = groupLabel .. " " .. fixName( groups[sc.group].name )
				end
			end
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( sc.name ) .. "\tGruppe " .. groupLabel
		end
		writeInventoryField( "INVENTORY_SCENES", lines, "Szenen" )
	end

	local sensors = httpRequest( 0, base .. "/sensors", nil, false, false )
	if (type(sensors) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(sensors) ) do
			local s = sensors[id]
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( s.name ) .. "\t" .. tostring( s.type )
		end
		writeInventoryField( "INVENTORY_SENSORS", lines, "Sensoren" )
	end

	local rules = httpRequest( 0, base .. "/rules", nil, false, false )
	if (type(rules) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(rules) ) do
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( rules[id].name )
		end
		writeInventoryField( "INVENTORY_AUTOMATIONS", lines, "Automationen" )
	end

	traceMsg( "Inventar komplett erstellt" )
end

-------------------------------------------------------------------------------
-- Automatische ID-Zuordnung (gefundene Hue-IDs -> angelegte JVP-Instanzen)
-------------------------------------------------------------------------------

--- IDs sammeln, die in den bereits vorhandenen Instanzen von `list` unter
-- `idField` stehen (damit sie bei der automatischen Zuordnung nicht doppelt
-- vergeben werden).
local function collectUsedIds( list, idField )
	local used = {}
	for _, tbl in pairs( list or {} ) do
		local id = getStr( tbl, idField )
		if (id ~= "") then used[id] = true end
	end
	return used
end

--- Ordnet den Instanzen einer Kategorie (in Anlage-Reihenfolge, 1., 2., 3., ...)
-- der Reihe nach die gefundenen Hue-IDs aus `sortedIdList` zu - Instanz 1
-- erhaelt die erste gefundene ID, Instanz 2 die zweite usw. Instanzen mit
-- bereits gesetzter ID werden uebersprungen (nicht ueberschrieben), und
-- bereits verwendete IDs werden bei der Vergabe ausgelassen.
-- @param rootScriptName string  SCRIPTNAME des Hauptordners ("LIGHTS_ROOT", ...)
-- @param scriptName string  SCRIPTNAME des Multiple-Ordners ("Light", ...)
-- @param idField string  SCRIPTNAME des ID-Feldes ("LIGHT_HUE_ID", ...)
-- @param sortedIdList table  numerisch sortierte Liste der auf der Bridge gefundenen IDs
local function assignCategoryIds( rootScriptName, scriptName, idField, sortedIdList )
	local root = E.PVTable[rootScriptName]
	if (root == nil) then return end
	local list = root[scriptName]
	if (list == nil) then return end

	local used = collectUsedIds( list, idField )
	local n = 0
	for _ in pairs( list ) do n = n + 1 end

	local nextIdx = 1
	local assigned = 0
	for i = 1, n do
		local tbl = list[i]
		if (tbl ~= nil) then
			local current = getStr( tbl, idField )
			if (current == "") then
				while ((nextIdx <= #sortedIdList) and used[sortedIdList[nextIdx]]) do
					nextIdx = nextIdx + 1
				end
				if (nextIdx <= #sortedIdList) then
					local id = sortedIdList[nextIdx]
					used[id] = true
					nextIdx = nextIdx + 1
					setVal( tbl, idField, id )
					assigned = assigned + 1
				end
			end
		end
	end
	if (assigned > 0) then
		traceMsg( scriptName .. ": " .. assigned .. " ID(s) automatisch zugeordnet" )
	end
end

--- Fragt Lampen/Gruppen/Szenen/Sensoren/Regeln von der Bridge ab und ordnet die
-- gefundenen IDs den bereits im JVP-Editor angelegten Instanzen zu - jeweils in
-- Anlage-Reihenfolge (Instanz 1 = erste gefundene ID, usw.). Nur Instanzen mit
-- leerem ID-Feld werden befuellt; bestehende Zuordnungen bleiben unangetastet.
-- Ausgeloest ueber CONFIGURATION.ASSIGN_IDS.
function AssignInventoryIds()
	local apiKey = getStr( CFG, "API_KEY" )
	if (apiKey == "") then
		traceMsg( "ID-Zuordnung: kein API-Key - erst Pairing durchfuehren" )
		return
	end
	local base = "/api/" .. apiKey

	local lights = httpRequest( 0, base .. "/lights", nil, false, false )
	if (type(lights) == "table") then
		assignCategoryIds( "LIGHTS_ROOT", "Light", "LIGHT_HUE_ID", sortedIds(lights) )
	end

	local groups = httpRequest( 0, base .. "/groups", nil, false, false )
	if (type(groups) == "table") then
		assignCategoryIds( "GROUPS_ROOT", "Group", "GROUP_HUE_ID", sortedIds(groups) )
	end

	local scenes = httpRequest( 0, base .. "/scenes", nil, false, false )
	if (type(scenes) == "table") then
		assignCategoryIds( "SCENES_ROOT", "Scene", "SCENE_HUE_ID", sortedIds(scenes) )
	end

	local sensors = httpRequest( 0, base .. "/sensors", nil, false, false )
	if (type(sensors) == "table") then
		assignCategoryIds( "SENSORS_ROOT", "Sensor", "SENSOR_HUE_ID", sortedIds(sensors) )
	end

	local rules = httpRequest( 0, base .. "/rules", nil, false, false )
	if (type(rules) == "table") then
		assignCategoryIds( "AUTOMATIONS_ROOT", "Automation", "AUTOMATION_HUE_ID", sortedIds(rules) )
	end

	traceMsg( "ID-Zuordnung abgeschlossen" )
	RebuildInstanceTables()
	RefreshStates()
end

-------------------------------------------------------------------------------
-- Pairing (Link-Button-Ablauf, CLIP v1 "POST /api")
-------------------------------------------------------------------------------

local function doPairingAttempt()
	local resp, err = httpRequest( 1, "/api", { devicetype = "jvp#hue-interface" }, false, false )
	if (resp == nil) then return false, err or "Keine Antwort" end
	local first = resp[1]
	if (type(first) ~= "table") then return false, "Unerwartete Antwort" end
	if ((first.success ~= nil) and (first.success.username ~= nil)) then
		return true, first.success.username
	end
	if (first.error ~= nil) then
		return false, tostring( first.error.description or first.error.type or "Fehler" )
	end
	return false, "Unerwartete Antwort"
end

local function startPairing()
	g_pairing = true
	g_pairingDeadline = os.time() + 300  -- 5 Minuten Zeitfenster zum Druecken des Link-Buttons
	traceMsg( "Pairing gestartet - Link-Button innerhalb von 5 Minuten druecken" )
	setVal( STATUS, "PAIRING_STATE", "Warte auf Tastendruck an der Bridge..." )
end

local function pollPairing()
	if (not g_pairing) then return end
	if (os.time() > g_pairingDeadline) then
		g_pairing = false
		traceMsg( "Pairing-Zeitfenster abgelaufen" )
		setVal( STATUS, "PAIRING_STATE", "Zeitueberschreitung - bitte erneut versuchen" )
		return
	end
	local ok, result = doPairingAttempt()
	if (ok) then
		setVal( CFG, "API_KEY", result )
		g_pairing = false
		traceMsg( "Pairing erfolgreich - API-Key erhalten" )
		setVal( STATUS, "PAIRING_STATE", "Gekoppelt" )
		setVal( STATUS, "LAST_ERROR", "" )
	else
		traceMsg( "Pairing-Versuch fehlgeschlagen: " .. tostring(result) )
		local remaining = math.max( 0, g_pairingDeadline - os.time() )
		setVal( STATUS, "PAIRING_STATE", "Warte auf Tastendruck... (" .. tostring(remaining) .. "s)" )
		setVal( STATUS, "LAST_ERROR", tostring(result) )
	end
end

-- ===========================================================================
-- JVP lifecycle
-- ===========================================================================

local DEFAULT_LIGHT_POLL_INTERVAL = 10  -- Sekunden; greift nur bei Instanzen, deren Feld noch nie geschrieben wurde

--- Setzt LIGHT_POLL_INTERVAL auf DEFAULT_LIGHT_POLL_INTERVAL, aber nur bei
-- Lampen-Instanzen, deren Feld noch leer ist (frisch angelegt, nie
-- geschrieben). Einmal gesetzte Werte - auch 0, falls der Installateur das
-- Polling bewusst ausschaltet - werden nie ueberschrieben. Prueft alle
-- Instanzen direkt (nicht nur LIGHTTABLE), damit auch Lampen ohne
-- LIGHT_HUE_ID bereits ihren Standardwert erhalten.
local function applyDefaultPollIntervals()
	local root = E.PVTable["LIGHTS_ROOT"]
	if (root == nil) then return end
	local list = root["Light"]
	if (list == nil) then return end
	for _, tbl in pairs( list ) do
		if ((type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == "light_t")) then
			if (getStr( tbl, "LIGHT_POLL_INTERVAL" ) == "") then
				setVal( tbl, "LIGHT_POLL_INTERVAL", DEFAULT_LIGHT_POLL_INTERVAL )
			end
		end
	end
end

function Init()
	CFG    = E.PVTable["CONFIGURATION"]
	STATUS = E.PVTable["STATUS"]
	HTTP_RQ = E.ResourceTable["HTTP"]
	traceMsg( "---- PhilipsHue: Init ----" )
	traceMsg( "HTTP_RQ=" .. tostring(HTTP_RQ) .. " (Methoden numerisch: 0=GET 1=POST 2=PUT 3=DELETE)" )
	-- Kein HTTP_RQ:Open() hier: ohne vorher gesetzte URL verbindet Open() zu
	-- einem Default-Ziel ("GET /"). Open() erfolgt pro Request in httpRequest()
	-- direkt nach SetURL().
	RebuildInstanceTables()
	applyDefaultPollIntervals()
	g_pairing = false
	g_pairingDeadline = 0
	g_pollCount = 0
	g_lastConnected = nil
	g_lastPresent = nil
	g_lastLightPoll = {}
	traceMsg( "Instanzen geladen - Lights=" .. tblCount(LIGHTTABLE) ..
		" Groups=" .. tblCount(GROUPTABLE) .. " Scenes=" .. tblCount(SCENETABLE) ..
		" Sensors=" .. tblCount(SENSORTABLE) .. " Automations=" .. tblCount(AUTOMATIONTABLE) )
	setVal( STATUS, "PAIRING_STATE", "Bereit" )
	RefreshStates()  -- einmaliger Status-Abruf beim Start; danach nur noch auf Anfrage
end

function Exit()
	traceMsg( "---- PhilipsHue: Exit ----" )
	if (HTTP_RQ ~= nil) then pcall( function() HTTP_RQ:Close() end ) end
end

--- Pro Lampe optionales automatisches Polling: LIGHT_POLL_INTERVAL (Sekunden,
-- 0 = aus) legt fest, wie oft genau diese Lampe automatisch nachgefragt wird.
-- Wird aus Poll() heraus aufgerufen (alle mg_nPollSeconds); prueft pro Lampe,
-- ob seit dem letzten automatischen Abruf genug Zeit vergangen ist. Ohne
-- gesetztes Intervall bleibt es beim bisherigen Verhalten (nur einmalig bei
-- Init() bzw. manuell ueber CONFIGURATION.REFRESH_STATES).
local function pollLightsIfDue()
	local now = os.time()
	local anyFailed = false
	for id, oInst in pairs( LIGHTTABLE ) do
		local interval = getNum( oInst, "LIGHT_POLL_INTERVAL" )
		if (interval > 0) then
			local last = g_lastLightPoll[id] or 0
			if ((now - last) >= interval) then
				g_lastLightPoll[id] = now
				if (not refreshSingleLight( oInst, id )) then anyFailed = true end
			end
		end
	end
	-- Automatisches Polling ist der einzige Pfad, der eine waehrend des
	-- Betriebs (nicht nur beim Start) geaenderte Bridge-IP ueberhaupt
	-- bemerken kann - daher hier zusaetzlich zu RefreshStates() als
	-- Ausloeser fuer die automatische Bridge-Erkennung.
	if (anyFailed and (getStr( CFG, "AUTO_DISCOVER_IP" ) == "1")) then
		if (tryAutoDiscoverBridgeIp()) then
			RefreshStates( true )
		end
	end
end

function Poll()
	g_pollCount = g_pollCount + 1
	RebuildInstanceTables()
	if (g_pairing) then pollPairing() end
	-- Gruppen/Sensoren/Szenen/Regeln werden weiterhin NICHT automatisch
	-- laufend abgefragt - nur einmalig in Init() sowie auf Anfrage ueber
	-- CONFIGURATION.REFRESH_STATES (siehe RefreshStates()). Schreibbefehle aus
	-- OnValueChange() sind davon unabhaengig und wirken weiterhin sofort.
	-- Lampen koennen zusaetzlich individuell per LIGHT_POLL_INTERVAL auf
	-- automatisches Polling umgestellt werden (0 = aus, Standard).
	pollLightsIfDue()
end

--- Bei nReason == constWriteReadCmd (explizites "Lesen" im JVP-Editor, im
-- Unterschied zu constValueRead/constGetUpdate) zuerst die betroffene Instanz
-- live von der Bridge nachladen, statt nur den moeglicherweise veralteten
-- Cache-Wert zurueckzugeben - sonst bleibt ein manuelles "Lesen" wirkungslos,
-- wenn sich der Bridge-Zustand seit dem letzten Refresh geaendert hat.
local function refreshInstanceForRead( oVarPath )
	local oLight = oVarPath:_findParentFromUserType( "light_t" )
	if (oLight ~= nil) then
		refreshSingleLight( oLight, getStr( oLight, "LIGHT_HUE_ID" ) )
		return
	end
	local oGroup = oVarPath:_findParentFromUserType( "group_t" )
	if (oGroup ~= nil) then
		refreshSingleGroup( oGroup, getStr( oGroup, "GROUP_HUE_ID" ) )
		return
	end
	local oScene = oVarPath:_findParentFromUserType( "scene_t" )
	if (oScene ~= nil) then
		refreshSingleScene( oScene, getStr( oScene, "SCENE_HUE_ID" ) )
		return
	end
	local oSensor = oVarPath:_findParentFromUserType( "sensor_t" )
	if (oSensor ~= nil) then
		refreshSingleSensor( oSensor, getStr( oSensor, "SENSOR_HUE_ID" ) )
		return
	end
	local oAuto = oVarPath:_findParentFromUserType( "automation_t" )
	if (oAuto ~= nil) then
		refreshSingleAutomation( oAuto, getStr( oAuto, "AUTOMATION_HUE_ID" ) )
	end
end

function OnValueRead( oVarPath, nReason )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessRead) and (a ~= constAccessReadWrite)) then return end
	if (nReason == constWriteReadCmd) then
		local pOk, pErr = pcall( refreshInstanceForRead, oVarPath )
		if (not pOk) then
			traceMsg( "FEHLER bei explizitem Lesen (" .. tostring(v:GetScriptName()) .. "): " .. tostring(pErr) )
		end
	end
	local val = v:GetValue()
	if (nil ~= val) then v:SetValue( val, constResponseFromCache ) end
end

function OnValueChange( oVarPath, strValue )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessReadWrite) and (a ~= constAccessWrite)) then return end

	-- Jeden eingehenden Schreibzugriff sofort quittieren, sonst uebernimmt JVP
	-- den Wert nicht in sein Prozessmodell/die Visualisierung (siehe JVP-Doku).
	-- Werte, die das Skript selbst setzt (z.B. Rueckmeldungen aus applyOne*),
	-- verwenden weiterhin constValueChange, nicht constWriteAck.
	v:SetValue( strValue, constWriteAck )

	local name = v:GetScriptName()

	-- Konfigurationsebene (kein Instanz-Elternordner)
	if (name == "PAIR_REQUEST") then
		if (parseNum(strValue) == 1) then startPairing() end
		return
	end
	if (name == "CLEAR_DEBUG_LOG") then
		if (parseNum(strValue) == 1) then
			setVal( STATUS, "DEBUG_LOG", "" )
		end
		return
	end
	if (name == "DUMP_INVENTORY") then
		if (parseNum(strValue) == 1) then dumpInventory() end
		return
	end
	if (name == "ASSIGN_IDS") then
		if (parseNum(strValue) == 1) then AssignInventoryIds() end
		return
	end
	if (name == "REFRESH_STATES") then
		if (parseNum(strValue) == 1) then RefreshStates() end
		return
	end
	if (name == "BRIDGE_IP") then
		traceMsg( "Bridge-IP geaendert auf " .. tostring(strValue) )
		setVal( STATUS, "PAIRING_STATE", "Bereit" )
		return
	end
	if (name == "API_KEY") then
		traceMsg( "API-Key manuell geaendert" )
		setVal( STATUS, "PAIRING_STATE", "Bereit" )
		return
	end

	-- Lampe
	local oLight = oVarPath:_findParentFromUserType( "light_t" )
	if (oLight ~= nil) then
		if (name == "LIGHT_HUE_ID") then
			refreshSingleLight( oLight, strValue )
			return
		end
		local id = getStr( oLight, "LIGHT_HUE_ID" )
		if (id == "") then return end
		local base = "/api/" .. getStr( CFG, "API_KEY" ) .. "/lights/" .. id .. "/state"
		if (name == "LIGHT_ON_CMD") then
			httpRequest( 2, base, { on = (parseNum(strValue) == 1) }, false, false )
		elseif (name == "LIGHT_BRIGHTNESS_CMD") then
			httpRequest( 2, base, { on = true, bri = percentToBri(parseNum(strValue) or 0) }, false, false )
		elseif (name == "LIGHT_COLORTEMP_CMD") then
			httpRequest( 2, base, { on = true, ct = kelvinToMired(parseNum(strValue) or 2700) }, false, false )
		elseif (name == "LIGHT_HUEANGLE_CMD") then
			httpRequest( 2, base, { on = true, hue = degToHueVal(parseNum(strValue) or 0) }, false, false )
		elseif (name == "LIGHT_SATURATION_CMD") then
			httpRequest( 2, base, { on = true, sat = percentToSat(parseNum(strValue) or 0) }, false, false )
		end
		return
	end

	-- Gruppe/Raum
	local oGroup = oVarPath:_findParentFromUserType( "group_t" )
	if (oGroup ~= nil) then
		if (name == "GROUP_HUE_ID") then
			refreshSingleGroup( oGroup, strValue )
			return
		end
		local id = getStr( oGroup, "GROUP_HUE_ID" )
		if (id == "") then return end
		local base = "/api/" .. getStr( CFG, "API_KEY" ) .. "/groups/" .. id .. "/action"
		if (name == "GROUP_ON_CMD") then
			httpRequest( 2, base, { on = (parseNum(strValue) == 1) }, false, false )
		elseif (name == "GROUP_BRIGHTNESS_CMD") then
			httpRequest( 2, base, { on = true, bri = percentToBri(parseNum(strValue) or 0) }, false, false )
		end
		return
	end

	-- Szene
	local oScene = oVarPath:_findParentFromUserType( "scene_t" )
	if (oScene ~= nil) then
		if (name == "SCENE_HUE_ID") then
			refreshSingleScene( oScene, strValue )
			return
		end
		if ((name == "SCENE_ACTIVATE") and (parseNum(strValue) == 1)) then
			local sceneId = getStr( oScene, "SCENE_HUE_ID" )
			local groupId = getStr( oScene, "SCENE_TARGET_GROUP_ID" )
			if (groupId == "") then groupId = "0" end
			if (sceneId ~= "") then
				local base = "/api/" .. getStr( CFG, "API_KEY" ) .. "/groups/" .. groupId .. "/action"
				httpRequest( 2, base, { scene = sceneId }, false, false )
			end
		end
		return
	end

	-- Sensor
	local oSensor = oVarPath:_findParentFromUserType( "sensor_t" )
	if (oSensor ~= nil) then
		if (name == "SENSOR_HUE_ID") then
			refreshSingleSensor( oSensor, strValue )
		end
		return
	end

	-- Automation (Hue-Regel)
	local oAuto = oVarPath:_findParentFromUserType( "automation_t" )
	if (oAuto ~= nil) then
		if (name == "AUTOMATION_HUE_ID") then
			refreshSingleAutomation( oAuto, strValue )
			return
		end
		if (name == "AUTOMATION_ENABLED_CMD") then
			local id = getStr( oAuto, "AUTOMATION_HUE_ID" )
			if (id ~= "") then
				local base = "/api/" .. getStr( CFG, "API_KEY" ) .. "/rules/" .. id
				httpRequest( 2, base, { status = (parseNum(strValue) == 1) and "enabled" or "disabled" }, false, false )
			end
		end
		return
	end
end
