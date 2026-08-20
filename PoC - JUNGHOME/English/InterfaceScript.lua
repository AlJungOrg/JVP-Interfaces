-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script InterfaceScript
--
-- JUNG Visu Pro (JVP) process connection for the JUNG HOME Gateway REST API
-- ("api-junghome", v1.5.0). Talks to the gateway over HTTPS and exposes its
-- Functions/Datapoints and Scenes as JVP datapoints; Groups are read-only info.
--
-- Pairing: the gateway is paired the same way as most local BT-Mesh gateways:
-- press the physical button on the JUNG HOME Gateway, then set
-- CONFIGURATION.START_PAIRING to 1 within the button's active window. The
-- script calls POST /api/junghome/register and retries every Poll() tick
-- (see MAX_PAIRING_ATTEMPTS) until the gateway accepts the request and
-- returns an API token, which is then stored in CONFIGURATION.TOKEN and used
-- as the "token" header on every subsequent request.
--
-- Function/Datapoint/Scene instances are added manually in the JVP device
-- editor (CREATIONTYPE="Multiple"); this script does not create them.
-- "Function" is added once per physical device (fill in FUNCTION_ID). Below
-- a Function instance, add one nested "Datapoint" instance per datapoint of
-- that function you want to read/write (fill in DATAPOINT_ID) -- e.g. a
-- DimmerLight has separate switch and brightness datapoints, so add two
-- Datapoint instances under the same Function. Look IDs up in
-- STATUS.FUNCTIONS_JSON / STATUS.SCENES_JSON (also written to the trace log)
-- after a successful pairing or a manual STATUS.RESYNC.
--
-- Diagnose: JEDE HTTP-Anfrage (Request und Antwort/Fehler), der Init-Status,
-- Pairing-Versuche, Resync-Schritte, uebersprungene Instanzen und jede
-- eingehende Wertaenderung werden per E:trace() protokolliert. Damit laesst
-- sich im JVP-Trace-Log genau nachvollziehen, an welcher Stelle der Ablauf
-- stehen bleibt (z.B. falscher Host, fehlender Token, leere FUNCTION_ID/
-- DATAPOINT_ID, HTTP-Fehlercode).
--
-- Target runtime: Lua 5.1. Towards the JUNG HOME Gateway, HTTP is client-only
-- (no push callbacks), so state changes on the gateway are picked up by polling.
--
-- HTTP-Bridge: zusaetzlich stellt dieses Skript ueber die HTTPSERVER-Ressource
-- "HTTPBRIDGE" (siehe RESOURCES in InterfaceDescription.xml, Standardport 8151)
-- einen eigenen lokalen REST-Server bereit, der die bereits synchronisierten
-- Function-/Datapoint-/Scene-Instanzen im selben JSON-Format wie api-junghome
-- spiegelt (GET/POST unter /api/junghome/...). Damit koennen Drittsysteme im
-- lokalen Netz (z.B. Home Assistant) direkt gegen JVP sprechen, ohne eigenes
-- Gateway-Pairing und ohne Cloud-Umweg; Schreibzugriffe werden von hier aus per
-- WriteDatapointValue() an das eigentliche Gateway weitergereicht. Optional per
-- BRIDGE.TOKEN gegen unbefugten Zugriff im lokalen Netz absichern.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"
json = require "json"

local mg_bDebug = false
mg_nPollSeconds = 1                -- keep in sync with INFO POLLTIME (1000 ms)

MAX_VALUE_SLOTS      = 6           -- VALUE1..VALUE6 per Datapoint instance; raise here + in XML if a type needs more
MAX_PAIRING_ATTEMPTS = 60          -- ~60s of retries (1 Poll/s) after START_PAIRING before giving up

-- HTTP-Methoden fuer die JVP HTTP-Ressource. Der "HTTP Request Typ" ist numerisch:
-- 0=GET, 1=POST, 2=PUT, 3=DELETE, 4=PATCH (bestaetigt - undokumentiert, aber die
-- Ressource kennt PATCH als eigenen numerischen Code, kein String-Methodenname noetig).
HTTP_METHOD_GET    = 0
HTTP_METHOD_POST   = 1
HTTP_METHOD_PUT    = 2
HTTP_METHOD_DELETE = 3
HTTP_METHOD_PATCH  = 4

CONFIG         = nil               -- E.PVTable["CONFIGURATION"]
STATUS         = nil               -- E.PVTable["STATUS"]
BRIDGE         = nil               -- E.PVTable["BRIDGE"]
HTTP_RQ        = nil               -- E.ResourceTable["HTTP"]
HTTP_SRV       = nil               -- E.ResourceTable["HTTPBRIDGE"]
FUNCTIONTABLE  = {}                -- array of Function instance folder tables
DATAPOINTTABLE = {}                -- flat array of { fn = <Function instance>, dp = <nested Datapoint instance> }
SCENETABLE     = {}                -- array of Scene instance folder tables

local nPairingAttempts   = 0
local g_resyncQueue      = {}
local g_nDatapointPollIdx = 0
local g_nIdleTicks       = 0       -- throttles the "waiting for token" trace
local g_nFunctionRefreshCounter = 0
local g_nBridgeRequestCount = 0
local g_dirtyNames       = false   -- true, wenn seit dem letzten E:SaveProject() umbenannt wurde
local g_lastFolderName   = {}      -- e_guid -> zuletzt per E:SetFolderName gesetzter Name (nur RAM)
FUNCTION_REFRESH_INTERVAL_S = 60   -- Sekunden zwischen automatischen Ist-Wert-Abfragen
                                    -- pro Datapoint-Instanz (round-robin ueber alle
                                    -- konfigurierten Datapoints). Vorher wurde jede
                                    -- Sekunde neu gelesen und ueberschrieb dabei laufende
                                    -- Eingaben in der Visualisierung/im Geraete-Editor,
                                    -- bevor der Benutzer fertig tippen konnte.

-------------------------------------------------------------------------------
-- Generic datapoint helpers
-------------------------------------------------------------------------------

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

--- Read a datapoint as text ("" if missing).
local function getStr( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return "" end
	return oNode[strName]:GetValue() or ""
end

--- Write a datapoint (guarded, reason = constValueChange).
local function setVal( oNode, strName, value )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		oNode[strName]:SetValue( tostring(value), constValueChange )
	end
end

--- Current time as text in the project format.
local function nowStr()
	return os.date( "%d.%m.%Y %H:%M:%S", os.time() )
end

--- Sanitize a UTF-8 name from the gateway (e.g. containing umlauts) for JVP
-- PVSTRINGs / folder names. Falls back to the raw text if ConvertUTF8ToASCII()
-- is unavailable or errors.
local function fixName( raw )
	if (raw == nil) then return "" end
	if (HTTP_RQ == nil) then return raw end
	local ok, converted = pcall( function() return HTTP_RQ:ConvertUTF8ToASCII( raw ) end )
	if (ok and (converted ~= nil)) then return converted end
	return raw
end

--- Set an instance's own folder name to newName - but only if it changed since
-- the last call in this runtime, and without calling E:SaveProject() itself
-- (the caller batches that once per sync pass, see DoFetchFunctions/
-- DoFetchScenes/RefreshFunctionInstance/RefreshScene - never call SaveProject
-- per Poll()/per instance).
local function renameFolderIfNeeded( oInst, newName )
	if ((oInst == nil) or (newName == nil) or (newName == "")) then return end
	local guid = oInst.e_guid
	if (guid == nil) then return end
	if (g_lastFolderName[guid] == newName) then return end
	local ok = pcall( function() E:SetFolderName( guid, newName ) end )
	if (ok) then
		g_lastFolderName[guid] = newName
		g_dirtyNames = true
	end
end

--- Flush a pending rename batch to disk (call once after a sync pass, not per instance).
local function flushFolderNamesIfDirty()
	if (g_dirtyNames) then
		pcall( function() E:SaveProject() end )
		g_dirtyNames = false
	end
end

--- Percent-encode a single URL path segment (ids may contain spaces etc.).
local function urlEncode( s )
	s = tostring( s or "" )
	s = s:gsub( "([^%w%-%_%.%~])", function( c )
		return string.format( "%%%02X", string.byte( c ) )
	end )
	return s
end

--- URL-decode a query/path segment ("%XX" -> Byte, "+" -> Space).
local function urlDecode( s )
	s = tostring( s or "" )
	s = s:gsub( "%+", " " )
	s = s:gsub( "%%(%x%x)", function( h ) return string.char( tonumber( h, 16 ) ) end )
	return s
end

--- Strip leading/trailing slashes ("/a/b/" -> "a/b").
local function normalizePath( p )
	p = tostring( p or "" )
	p = p:gsub( "^/+", "" )
	p = p:gsub( "/+$", "" )
	return p
end

--- Split a request URI into path segments ("/api/junghome/scenes" -> {"api","junghome","scenes"}).
local function splitPath( uri )
	local segments = {}
	for seg in string.gmatch( normalizePath(uri), "[^/]+" ) do
		table.insert( segments, seg )
	end
	return segments
end

--- Set a STATUS datapoint by SCRIPTNAME.
local function setStatus( strName, value )
	setVal( STATUS, strName, value )
end

--- Flag an error on the STATUS folder and write it to the trace log.
local function setError( strMsg )
	setStatus( "ERROR", 1 )
	setStatus( "LAST_ERROR", strMsg )
	E:trace( "JUNGHOME_Gateway: FEHLER - " .. tostring(strMsg) )
end

--- Clear the STATUS error flag.
local function clearError()
	setStatus( "ERROR", 0 )
	setStatus( "LAST_ERROR", "" )
end

--- Find an item with item.id == strId in a JSON-decoded array (nil-safe).
local function FindById( list, strId )
	if ((list == nil) or (strId == nil) or (strId == "")) then return nil end
	for _, item in ipairs( list ) do
		if (type(item) == "table") and (tostring(item.id) == strId) then return item end
	end
	return nil
end

-------------------------------------------------------------------------------
-- HTTP transport
-------------------------------------------------------------------------------

--- Build the gateway's base URL from CONFIGURATION (scheme://host:port).
local function buildBaseUrl()
	local scheme = (getNum( CONFIG, "USE_HTTPS" ) ~= 0) and "https" or "http"
	local host = getStr( CONFIG, "HOST" )
	local port = getNum( CONFIG, "PORT" )
	if (port == 0) then port = 443 end
	return scheme .. "://" .. host .. ":" .. tostring( math.floor(port) )
end

--- Perform an HTTP request against the api-junghome REST API. Traces the
-- request and its outcome so a stuck/failing step is visible in the JVP
-- trace log (wrong host, no token, HTTP error code, transport error, ...).
-- Assumes the HTTP resource exposes SetURL/RemoveHeaders/AddHeader/
-- SendRequest(method, body)/GetRxData() -> returnCode, error, httpStatus, data.
-- "method" is one of the numeric HTTP_METHOD_* constants above (0=GET, 1=POST, 2=PUT,
-- 3=DELETE, 4=PATCH - PATCH undocumented by the resource but confirmed working;
-- needed since api-junghome requires PATCH for writing datapoint values).
-- @param strMethodName  human-readable method for the trace log, e.g. "GET"
-- @param strMethod      HTTP_METHOD_GET / HTTP_METHOD_POST / HTTP_METHOD_PUT / HTTP_METHOD_DELETE / HTTP_METHOD_PATCH
-- @param strPath        API path, e.g. "/api/junghome/functions/"
-- @param tblBody        optional Lua table, sent as JSON body
-- @param bAuth          true to send the "token" auth header
-- @return boolean bOk, number nStatus, table|nil tblData, string strRaw
local function httpRequest( strMethodName, strMethod, strPath, tblBody, bAuth )
	if (HTTP_RQ == nil) then
		E:trace( "JUNGHOME_Gateway: HTTP-Ressource nicht verfuegbar (Init nicht gelaufen oder RESOURCES fehlt in InterfaceDescription.xml)" )
		return false, 0, nil, ""
	end

	local url = buildBaseUrl() .. strPath
	E:trace( "JUNGHOME_Gateway: -> " .. strMethodName .. " " .. url )

	HTTP_RQ:SetURL( url )
	HTTP_RQ:RemoveHeaders()
	HTTP_RQ:AddHeader( "Accept: application/json" )
	if (bAuth) then
		local token = getStr( CONFIG, "TOKEN" )
		if (token ~= "") then
			HTTP_RQ:AddHeader( "token: " .. token )
		else
			E:trace( "JUNGHOME_Gateway: WARNUNG - Anfrage benoetigt Token, CONFIGURATION.TOKEN ist aber leer" )
		end
	end

	local strBody = ""
	if (tblBody ~= nil) then
		strBody = json.encode( tblBody )
		HTTP_RQ:AddHeader( "Content-Type: application/json" )
		E:trace( "JUNGHOME_Gateway:    Body -> " .. strBody )
	end

	HTTP_RQ:SendRequest( strMethod, strBody )
	local nRet, strErr, nStatus, strData = HTTP_RQ:GetRxData()

	if ((nRet == nil) or (nRet ~= 0)) then
		E:trace( "JUNGHOME_Gateway: <- " .. strMethodName .. " " .. strPath ..
			" TRANSPORTFEHLER ret=" .. tostring(nRet) .. " err=" .. tostring(strErr) ..
			" (Host/Port/Zertifikat pruefen)" )
		return false, nStatus or 0, nil, tostring( strErr or "" )
	end
	if ((nStatus == nil) or (nStatus < 200) or (nStatus >= 300)) then
		E:trace( "JUNGHOME_Gateway: <- " .. strMethodName .. " " .. strPath ..
			" HTTP " .. tostring(nStatus) .. " " .. tostring(strData) )
		return false, nStatus or 0, nil, strData or ""
	end

	E:trace( "JUNGHOME_Gateway: <- " .. strMethodName .. " " .. strPath .. " HTTP " .. tostring(nStatus) .. " OK" )
	if ((strData ~= nil) and (strData ~= "")) then
		-- Antwort-Body auch bei Erfolg zeigen (max. 500 Zeichen), um stille Diskrepanzen
		-- zwischen "HTTP 200" und tatsaechlich uebernommenem Wert sichtbar zu machen.
		E:trace( "JUNGHOME_Gateway:    Antwort <- " .. string.sub( strData, 1, 500 ) )
	end

	local tblData = nil
	if ((strData ~= nil) and (strData ~= "")) then
		tblData = json.decode( strData )
		if (tblData == nil) then
			E:trace( "JUNGHOME_Gateway: WARNUNG - Antwort auf " .. strPath .. " konnte nicht als JSON dekodiert werden" )
		end
	end
	return true, nStatus, tblData, strData or ""
end

-------------------------------------------------------------------------------
-- Instance tables
-------------------------------------------------------------------------------

--- Return the nested "Datapoint" (Multiple) child instances of a Function instance.
local function GetDatapointChildren( oFn )
	local children = {}
	if (oFn == nil) then return children end
	local list = oFn["Datapoint"]
	if (list ~= nil) then
		for _, tbl in pairs( list ) do
			if (type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == "datapoint_t") then
				table.insert( children, tbl )
			end
		end
	end
	return children
end

--- Rebuild FUNCTIONTABLE/DATAPOINTTABLE/SCENETABLE from all Multiple-instance folders.
function CreateInstanceTable()
	FUNCTIONTABLE = {}
	DATAPOINTTABLE = {}
	local list = E.PVTable["Function"]
	if (list ~= nil) then
		for _, tbl in pairs( list ) do
			if (type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == "function_t") then
				table.insert( FUNCTIONTABLE, tbl )
				for _, oDp in ipairs( GetDatapointChildren( tbl ) ) do
					table.insert( DATAPOINTTABLE, { fn = tbl, dp = oDp } )
				end
			end
		end
	end

	SCENETABLE = {}
	local slist = E.PVTable["Scene"]
	if (slist ~= nil) then
		for _, tbl in pairs( slist ) do
			if (type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == "scene_t") then
				table.insert( SCENETABLE, tbl )
			end
		end
	end

	E:trace( "JUNGHOME_Gateway: " .. #FUNCTIONTABLE .. " Function-Instanz(en) mit zusammen " ..
		#DATAPOINTTABLE .. " Datapoint-Instanz(en) und " .. #SCENETABLE .. " Scene-Instanz(en) im Projekt gefunden" )
end

-------------------------------------------------------------------------------
-- Function / datapoint handling
-------------------------------------------------------------------------------

--- Copy a JungDatapoint's "values" (array of {key,value}) into VALUE1..N.
local function ApplyDatapointValues( oDp, tblDatapoint )
	setVal( oDp, "DATAPOINT_TYPE", tblDatapoint.type or "" )
	local values = tblDatapoint.values or {}
	for i = 1, MAX_VALUE_SLOTS do
		local kv = values[i]
		if (kv ~= nil) then
			setVal( oDp, "VALUE" .. i .. "_KEY", kv.key or "" )
			setVal( oDp, "VALUE" .. i, kv.value or "" )
		else
			setVal( oDp, "VALUE" .. i .. "_KEY", "" )
		end
	end
end

--- Match a Function instance's nested Datapoint instances against a JungFunction's
-- "datapoints" array, filling in DATAPOINT_TYPE/DATAPOINT_VALID and VALUE1..N.
local function MatchFunctionDatapoints( oFn, tblDatapoints )
	local fid = getStr( oFn, "FUNCTION_ID" )
	for _, oDp in ipairs( GetDatapointChildren( oFn ) ) do
		local did = getStr( oDp, "DATAPOINT_ID" )
		local dp = FindById( tblDatapoints, did )
		if (dp == nil) then
			if (did ~= "") then
				E:trace( "JUNGHOME_Gateway: DATAPOINT_ID '" .. did .. "' in Function '" .. fid .. "' nicht gefunden" )
			end
			setVal( oDp, "DATAPOINT_VALID", 0 )
		else
			setVal( oDp, "DATAPOINT_VALID", 1 )
			ApplyDatapointValues( oDp, dp )
		end
	end
end

--- Re-fetch a single Function instance (label/type + all of its nested Datapoint
-- instances) from the gateway. Called when FUNCTION_ID changes.
function RefreshFunctionInstance( oFn )
	local fid = getStr( oFn, "FUNCTION_ID" )
	if (fid == "") then
		E:trace( "JUNGHOME_Gateway: Function-Instanz uebersprungen - FUNCTION_ID leer" )
		setVal( oFn, "FUNCTION_VALID", 0 )
		return
	end
	local path = "/api/junghome/functions/" .. urlEncode(fid)
	local ok, status, data = httpRequest( "GET", HTTP_METHOD_GET, path, nil, true )
	if (not ok or data == nil) then
		E:trace( "JUNGHOME_Gateway: Function " .. fid .. " nicht lesbar (HTTP " .. tostring(status) .. ")" )
		setVal( oFn, "FUNCTION_VALID", 0 )
		return
	end
	local strLabel = fixName( data.label )
	setVal( oFn, "FUNCTION_LABEL", strLabel )
	setVal( oFn, "FUNCTION_TYPE", data.type or "" )
	setVal( oFn, "FUNCTION_VALID", 1 )
	renameFolderIfNeeded( oFn, strLabel )
	flushFolderNamesIfDirty()
	MatchFunctionDatapoints( oFn, data.datapoints or {} )
end

--- Re-fetch a single Datapoint instance's current value from the gateway
-- (round-robin polling target, see PollNextDatapoint()).
function RefreshDatapointInstance( oFn, oDp )
	local fid = getStr( oFn, "FUNCTION_ID" )
	local did = getStr( oDp, "DATAPOINT_ID" )
	if ((fid == "") or (did == "")) then
		E:trace( "JUNGHOME_Gateway: Datapoint-Instanz uebersprungen - FUNCTION_ID oder DATAPOINT_ID leer" )
		setVal( oDp, "DATAPOINT_VALID", 0 )
		return
	end
	local path = "/api/junghome/functions/" .. urlEncode(fid) .. "/datapoints/" .. urlEncode(did)
	local ok, status, data = httpRequest( "GET", HTTP_METHOD_GET, path, nil, true )
	if (not ok or data == nil) then
		E:trace( "JUNGHOME_Gateway: Datapoint " .. fid .. "/" .. did .. " nicht lesbar (HTTP " .. tostring(status) .. ")" )
		setVal( oDp, "DATAPOINT_VALID", 0 )
		return
	end
	setVal( oDp, "DATAPOINT_VALID", 1 )
	ApplyDatapointValues( oDp, data )
end

--- Match all configured Function instances (and their nested Datapoint instances)
-- against a bulk /functions/ list.
local function MatchFunctionInstances( tblFunctions )
	for _, oFn in ipairs( FUNCTIONTABLE ) do
		local fid = getStr( oFn, "FUNCTION_ID" )
		local fn = FindById( tblFunctions, fid )
		if (fn == nil) then
			if (fid ~= "") then
				E:trace( "JUNGHOME_Gateway: FUNCTION_ID '" .. fid .. "' beim Gateway nicht gefunden" )
			end
			setVal( oFn, "FUNCTION_VALID", 0 )
		else
			local strLabel = fixName( fn.label )
			setVal( oFn, "FUNCTION_LABEL", strLabel )
			setVal( oFn, "FUNCTION_TYPE", fn.type or "" )
			setVal( oFn, "FUNCTION_VALID", 1 )
			renameFolderIfNeeded( oFn, strLabel )
			MatchFunctionDatapoints( oFn, fn.datapoints or {} )
		end
	end
end

--- Write a single VALUEn of one Datapoint instance back to the gateway via
-- PATCH .../functions/{fid}/datapoints/{did}.
function WriteDatapointValue( oFn, oDp, nSlot, strValue )
	local fid = getStr( oFn, "FUNCTION_ID" )
	local did = getStr( oDp, "DATAPOINT_ID" )
	local key = getStr( oDp, "VALUE" .. nSlot .. "_KEY" )
	if ((fid == "") or (did == "") or (key == "")) then
		setError( "Schreiben nicht moeglich: FUNCTION_ID/DATAPOINT_ID/Key unbekannt (Instanz zuerst per RESYNC aktualisieren)" )
		return
	end
	-- Fuehrende/nachgestellte Leerzeichen entfernen: aus der Visualisierung/JVP-Eingabe
	-- koennen versehentlich Leerzeichen mitkommen (z.B. "true "), die das Gateway bei
	-- Boolean-artigen Werten (true/false) nicht mehr erkennt, obwohl die Anfrage mit
	-- HTTP 200 quittiert wird.
	strValue = tostring(strValue or ""):match( "^%s*(.-)%s*$" )
	local path = "/api/junghome/functions/" .. urlEncode(fid) .. "/datapoints/" .. urlEncode(did)
	local body = { data = { { key = key, value = strValue } } }
	-- api-junghome verlangt fuer das Schreiben eines Datapoint-Werts ein echtes HTTP
	-- PATCH (bestaetigt) - kein POST, kein PUT, kein "?_method=PATCH"-Override (frueherer
	-- Versuch, ergab HTTP 404 - verworfen). Die HTTP-Ressource kennt PATCH als eigenen
	-- numerischen Code: HTTP_METHOD_PATCH = 4 (bestaetigt, undokumentiert).
	local ok, status = httpRequest( "PATCH", HTTP_METHOD_PATCH, path, body, true )
	if (not ok) then
		setError( "Schreiben fehlgeschlagen (HTTP " .. tostring(status) .. ") fuer " .. fid .. "/" .. did .. " Key=" .. key )
	else
		clearError()
	end
end

--- Poll exactly one configured Datapoint instance per call (round-robin over
-- all Datapoint instances of all Function instances).
local function PollNextDatapoint()
	local n = #DATAPOINTTABLE
	if (n == 0) then return end
	g_nDatapointPollIdx = g_nDatapointPollIdx + 1
	if (g_nDatapointPollIdx > n) then g_nDatapointPollIdx = 1 end
	local entry = DATAPOINTTABLE[g_nDatapointPollIdx]
	RefreshDatapointInstance( entry.fn, entry.dp )
end

-------------------------------------------------------------------------------
-- Scene handling
-------------------------------------------------------------------------------

--- Re-fetch a single Scene instance's label from the gateway.
function RefreshScene( oInst )
	local sid = getStr( oInst, "SCENE_ID" )
	if (sid == "") then
		E:trace( "JUNGHOME_Gateway: Scene-Instanz uebersprungen - SCENE_ID leer" )
		setVal( oInst, "SCENE_VALID", 0 )
		return
	end
	local path = "/api/junghome/scenes/" .. urlEncode(sid)
	local ok, status, data = httpRequest( "GET", HTTP_METHOD_GET, path, nil, true )
	if (ok and data ~= nil) then
		local strLabel = fixName( data.label )
		setVal( oInst, "SCENE_LABEL", strLabel )
		setVal( oInst, "SCENE_VALID", 1 )
		renameFolderIfNeeded( oInst, strLabel )
		flushFolderNamesIfDirty()
	else
		E:trace( "JUNGHOME_Gateway: Scene '" .. sid .. "' nicht lesbar (HTTP " .. tostring(status) .. ")" )
		setVal( oInst, "SCENE_VALID", 0 )
	end
end

--- Match all configured Scene instances against a bulk /scenes/ list.
local function MatchSceneInstances( tblScenes )
	for _, oInst in ipairs( SCENETABLE ) do
		local sid = getStr( oInst, "SCENE_ID" )
		local sc = FindById( tblScenes, sid )
		if (sc == nil) then
			if (sid ~= "") then
				E:trace( "JUNGHOME_Gateway: SCENE_ID '" .. sid .. "' beim Gateway nicht gefunden" )
			end
			setVal( oInst, "SCENE_VALID", 0 )
		else
			local strLabel = fixName( sc.label )
			setVal( oInst, "SCENE_LABEL", strLabel )
			setVal( oInst, "SCENE_VALID", 1 )
			renameFolderIfNeeded( oInst, strLabel )
		end
	end
end

--- Activate a scene via POST /api/junghome/scenes/{scene_id}.
function ActivateScene( oInst )
	local sid = getStr( oInst, "SCENE_ID" )
	if (sid == "") then
		E:trace( "JUNGHOME_Gateway: Szene kann nicht aktiviert werden - SCENE_ID leer" )
		return
	end
	local path = "/api/junghome/scenes/" .. urlEncode(sid)
	local ok, status = httpRequest( "POST", HTTP_METHOD_POST, path, {}, true )
	if (not ok) then
		setError( "Szene aktivieren fehlgeschlagen (HTTP " .. tostring(status) .. ") fuer " .. sid )
	else
		clearError()
	end
end

-------------------------------------------------------------------------------
-- Resync (Version / Functions / Scenes / Groups)
-------------------------------------------------------------------------------

local function DoFetchVersion()
	local ok, status, data = httpRequest( "GET", HTTP_METHOD_GET, "/api/junghome/version/", nil, false )
	if (ok and data ~= nil) then
		setVal( STATUS, "API_VERSION", data.api_version or "" )
		setVal( STATUS, "GATEWAY_VERSION", data.version_release or "" )
	end
end

local function DoFetchFunctions()
	local ok, status, data = httpRequest( "GET", HTTP_METHOD_GET, "/api/junghome/functions/", nil, true )
	if (not ok or data == nil) then
		setError( "Functions konnten nicht geladen werden (HTTP " .. tostring(status) .. ")" )
		return
	end
	setVal( STATUS, "FUNCTION_COUNT", #data )
	setVal( STATUS, "FUNCTIONS_JSON", json.encode(data) )
	for _, fn in ipairs( data ) do
		E:trace( string.format( "JUNGHOME_Gateway: Function id=%s type=%s label=%s",
			tostring(fn.id), tostring(fn.type), tostring(fn.label) ) )
		for _, dp in ipairs( fn.datapoints or {} ) do
			local keys = {}
			for _, kv in ipairs( dp.values or {} ) do keys[#keys+1] = tostring(kv.key) end
			E:trace( string.format( "JUNGHOME_Gateway:   Datapoint id=%s type=%s keys=[%s]",
				tostring(dp.id), tostring(dp.type), table.concat(keys, ", ") ) )
		end
	end
	MatchFunctionInstances( data )
	flushFolderNamesIfDirty()
end

local function DoFetchScenes()
	local ok, status, data = httpRequest( "GET", HTTP_METHOD_GET, "/api/junghome/scenes/", nil, true )
	if (not ok or data == nil) then
		setError( "Scenes konnten nicht geladen werden (HTTP " .. tostring(status) .. ")" )
		return
	end
	setVal( STATUS, "SCENES_JSON", json.encode(data) )
	for _, sc in ipairs( data ) do
		E:trace( string.format( "JUNGHOME_Gateway: Scene id=%s label=%s", tostring(sc.id), tostring(sc.label) ) )
	end
	MatchSceneInstances( data )
	flushFolderNamesIfDirty()
end

local function DoFetchGroups()
	local ok, status, data = httpRequest( "GET", HTTP_METHOD_GET, "/api/junghome/groups/", nil, true )
	if (not ok or data == nil) then
		setError( "Groups konnten nicht geladen werden (HTTP " .. tostring(status) .. ")" )
		return
	end
	setVal( STATUS, "GROUPS_JSON", json.encode(data) )
end

--- Queue a full resync; one step is executed per Poll() tick so a single
-- Poll() call never blocks on more than one HTTP round trip.
function EnqueueResync()
	g_resyncQueue = { DoFetchVersion, DoFetchFunctions, DoFetchScenes, DoFetchGroups }
	-- WICHTIG: STATUS.RESYNC muss hier gesetzt werden, sonst prueft Poll() nie auf
	-- die Warteschlange (Poll() entscheidet anhand dieses Datenpunkts, nicht anhand
	-- der Lua-Variable g_resyncQueue). Betrifft vor allem den Aufruf aus DoRegister()/
	-- Init() heraus, wo kein Datenpunkt-Schreibvorgang (mit automatischem Ack) passiert.
	setVal( STATUS, "RESYNC", 1 )
	E:trace( "JUNGHOME_Gateway: Resync eingereiht (Version, Functions, Scenes, Groups)" )
end

local function DoResyncStep()
	if (#g_resyncQueue == 0) then
		setVal( STATUS, "RESYNC", 0 )
		setVal( STATUS, "LAST_SYNC", nowStr() )
		E:trace( "JUNGHOME_Gateway: Resync abgeschlossen" )
		return
	end
	local step = table.remove( g_resyncQueue, 1 )
	local ok, err = pcall( step )
	if (not ok) then setError( "Resync-Schritt fehlgeschlagen: " .. tostring(err) ) end
end

-------------------------------------------------------------------------------
-- Pairing / registration
-------------------------------------------------------------------------------

--- POST /api/junghome/register (button-press pairing). Called once
-- immediately on START_PAIRING, then retried from Poll() while
-- STATUS.PAIRING == 1, up to MAX_PAIRING_ATTEMPTS.
function DoRegister()
	local userName = getStr( CONFIG, "USER_NAME" )
	if (userName == "") then userName = "JVP" end

	E:trace( "JUNGHOME_Gateway: Registrierungsversuch " .. tostring(nPairingAttempts + 1) .. "/" .. MAX_PAIRING_ATTEMPTS ..
		" als '" .. userName .. "' - Taste am Gateway muss gedrueckt sein/werden" )

	local ok, status, data = httpRequest( "POST", HTTP_METHOD_POST, "/api/junghome/register", { user_name = userName }, false )
	if (ok and data ~= nil and data.token ~= nil and data.token ~= "") then
		setVal( CONFIG, "TOKEN", data.token )
		setStatus( "PAIRING", 0 )
		setStatus( "CONNECTED", 1 )
		clearError()
		nPairingAttempts = 0
		E:trace( "JUNGHOME_Gateway: Registrierung erfolgreich, Token gespeichert" )
		EnqueueResync()
		return true
	end

	nPairingAttempts = nPairingAttempts + 1
	E:trace( "JUNGHOME_Gateway: Registrierung noch nicht erfolgreich (HTTP " .. tostring(status) .. ") - Versuch " ..
		tostring(nPairingAttempts) .. "/" .. MAX_PAIRING_ATTEMPTS )
	if (nPairingAttempts >= MAX_PAIRING_ATTEMPTS) then
		setStatus( "PAIRING", 0 )
		setError( "Registrierung fehlgeschlagen (HTTP " .. tostring(status) ..
			") - Taste am Gateway nicht rechtzeitig gedrueckt? Bitte Taste erneut druecken und START_PAIRING neu starten." )
		nPairingAttempts = 0
	end
	return false
end

-------------------------------------------------------------------------------
-- HTTP Bridge (eingehender lokaler REST-Server, siehe HTTPRequestReceived())
-------------------------------------------------------------------------------

--- Uniform success/error responses (immer JSON, wie die HttpServer-Referenz).
local function bridgeOk( payload )
	return 200, json.encode( payload ), "application/json"
end

local function bridgeError( status, msg )
	return status, json.encode( { error = msg } ), "application/json"
end

--- Optionale Token-Pruefung. BRIDGE.TOKEN leer -> keine Pruefung (offen im
-- lokalen Netz). Sonst muss "Authorization: Bearer <TOKEN>" oder "token: <TOKEN>"
-- passen.
local function checkBridgeAuth( request )
	local token = getStr( BRIDGE, "BRIDGE_TOKEN" )
	if (token == "") then return true end
	local headers = request.headers or {}
	local auth = headers["Authorization"] or headers["authorization"] or ""
	local bearer = tostring(auth):match( "^Bearer%s+(.+)$" )
	local hdrToken = headers["token"] or headers["Token"] or ""
	return ((bearer == token) or (hdrToken == token))
end

--- Find a configured Function instance by FUNCTION_ID.
local function findFunctionInstance( fid )
	for _, oFn in ipairs( FUNCTIONTABLE ) do
		if (getStr( oFn, "FUNCTION_ID" ) == fid) then return oFn end
	end
	return nil
end

--- Find a configured Datapoint instance (nested under oFn) by DATAPOINT_ID.
local function findDatapointInstanceIn( oFn, did )
	for _, oDp in ipairs( GetDatapointChildren( oFn ) ) do
		if (getStr( oDp, "DATAPOINT_ID" ) == did) then return oDp end
	end
	return nil
end

--- Find a configured Scene instance by SCENE_ID.
local function findSceneInstance( sid )
	for _, oInst in ipairs( SCENETABLE ) do
		if (getStr( oInst, "SCENE_ID" ) == sid) then return oInst end
	end
	return nil
end

--- Find the VALUEn slot (1..MAX_VALUE_SLOTS) whose VALUEn_KEY matches key.
local function findSlotByKey( oDp, key )
	for i = 1, MAX_VALUE_SLOTS do
		if (getStr( oDp, "VALUE" .. i .. "_KEY" ) == key) then return i end
	end
	return nil
end

--- Same JSON shape as the api-junghome gateway: { id, type, values:[{key,value},...] }.
local function bridgeDatapointJson( oDp )
	local values = {}
	for i = 1, MAX_VALUE_SLOTS do
		local key = getStr( oDp, "VALUE" .. i .. "_KEY" )
		if (key ~= "") then
			table.insert( values, { key = key, value = getStr( oDp, "VALUE" .. i ) } )
		end
	end
	return { id = getStr( oDp, "DATAPOINT_ID" ), type = getStr( oDp, "DATAPOINT_TYPE" ), values = values }
end

--- Same JSON shape as the api-junghome gateway: { id, type, label, datapoints:[...] }.
local function bridgeFunctionJson( oFn )
	local dps = {}
	for _, oDp in ipairs( GetDatapointChildren( oFn ) ) do
		table.insert( dps, bridgeDatapointJson( oDp ) )
	end
	return { id = getStr( oFn, "FUNCTION_ID" ), type = getStr( oFn, "FUNCTION_TYPE" ),
		label = getStr( oFn, "FUNCTION_LABEL" ), datapoints = dps }
end

--- GET-Handler: spiegelt /api/junghome/functions[/...] und /api/junghome/scenes[/...]
-- aus den bereits synchronisierten Instanzen (kein zusaetzlicher Gateway-Roundtrip).
local function handleBridgeGet( segments )
	if (#segments == 0) then
		return bridgeOk( { name = "JUNGHOME_Gateway Bridge", function_count = #FUNCTIONTABLE, scene_count = #SCENETABLE } )
	end
	if ((segments[1] == "api") and (segments[2] == "junghome")) then
		if (segments[3] == "functions") then
			if (segments[4] == nil) then
				local list = {}
				for _, oFn in ipairs( FUNCTIONTABLE ) do table.insert( list, bridgeFunctionJson( oFn ) ) end
				return bridgeOk( list )
			end
			local oFn = findFunctionInstance( urlDecode( segments[4] ) )
			if (oFn == nil) then return bridgeError( 404, "function not found" ) end
			if ((segments[5] == "datapoints") and (segments[6] ~= nil)) then
				local oDp = findDatapointInstanceIn( oFn, urlDecode( segments[6] ) )
				if (oDp == nil) then return bridgeError( 404, "datapoint not found" ) end
				return bridgeOk( bridgeDatapointJson( oDp ) )
			end
			return bridgeOk( bridgeFunctionJson( oFn ) )
		elseif (segments[3] == "scenes") then
			if (segments[4] == nil) then
				local list = {}
				for _, oInst in ipairs( SCENETABLE ) do
					table.insert( list, { id = getStr( oInst, "SCENE_ID" ), label = getStr( oInst, "SCENE_LABEL" ) } )
				end
				return bridgeOk( list )
			end
			local oInst = findSceneInstance( urlDecode( segments[4] ) )
			if (oInst == nil) then return bridgeError( 404, "scene not found" ) end
			return bridgeOk( { id = getStr( oInst, "SCENE_ID" ), label = getStr( oInst, "SCENE_LABEL" ) } )
		end
	end
	return bridgeError( 404, "path not found" )
end

--- POST-Handler: Datapoint-Werte schreiben (Body wie beim echten Gateway:
-- {"data":[{"key":...,"value":...}, ...]}), forwarded per WriteDatapointValue()
-- an das Gateway; Szenen aktivieren.
local function handleBridgePost( segments, strBody )
	if ((segments[1] == "api") and (segments[2] == "junghome")) then
		if ((segments[3] == "functions") and (segments[4] ~= nil) and
			(segments[5] == "datapoints") and (segments[6] ~= nil)) then
			local oFn = findFunctionInstance( urlDecode( segments[4] ) )
			if (oFn == nil) then return bridgeError( 404, "function not found" ) end
			local oDp = findDatapointInstanceIn( oFn, urlDecode( segments[6] ) )
			if (oDp == nil) then return bridgeError( 404, "datapoint not found" ) end

			local tbl = json.decode( strBody or "" )
			local entries = (tbl ~= nil) and tbl.data or nil
			if ((entries == nil) or (#entries == 0)) then
				return bridgeError( 400, "expected body {\"data\":[{\"key\":..,\"value\":..}]}" )
			end
			for _, kv in ipairs( entries ) do
				local slot = findSlotByKey( oDp, tostring( kv.key or "" ) )
				if (slot == nil) then
					return bridgeError( 400, "unknown key '" .. tostring(kv.key) .. "' for this datapoint" )
				end
				WriteDatapointValue( oFn, oDp, slot, tostring( kv.value or "" ) )
			end
			return bridgeOk( { id = getStr( oDp, "DATAPOINT_ID" ), status = "queued" } )

		elseif ((segments[3] == "scenes") and (segments[4] ~= nil)) then
			local oInst = findSceneInstance( urlDecode( segments[4] ) )
			if (oInst == nil) then return bridgeError( 404, "scene not found" ) end
			ActivateScene( oInst )
			return bridgeOk( { id = getStr( oInst, "SCENE_ID" ), status = "activated" } )
		end
	end
	return bridgeError( 404, "path not found" )
end

--- Ereignisfunktion der HTTPSERVER-Ressource: wird bei jedem eingehenden Request
-- aufgerufen. request = { method, uri, query, body, headers }.
-- Rueckgabe: Statuscode [, Body [, ContentType]].
function HTTPRequestReceived( request )
	g_nBridgeRequestCount = g_nBridgeRequestCount + 1
	setVal( BRIDGE, "BRIDGE_REQUEST_COUNT", g_nBridgeRequestCount )
	setVal( BRIDGE, "BRIDGE_LAST_REQUEST", nowStr() )
	E:trace( "JUNGHOME_Gateway: Bridge <- " .. tostring(request.method) .. " " .. tostring(request.uri) )

	if (not checkBridgeAuth( request )) then
		E:trace( "JUNGHOME_Gateway: Bridge -> 401 (Token fehlt/falsch)" )
		return bridgeError( 401, "unauthorized" )
	end

	local segments = splitPath( request.uri )
	if (request.method == "GET") then
		return handleBridgeGet( segments )
	elseif (request.method == "POST") then
		return handleBridgePost( segments, request.body )
	end
	return bridgeError( 405, "method not allowed" )
end

-------------------------------------------------------------------------------
-- JVP lifecycle
-------------------------------------------------------------------------------

function Init()
	E:trace( "---- JUNGHOME_Gateway: Init ----" )
	CONFIG = E.PVTable["CONFIGURATION"]
	STATUS = E.PVTable["STATUS"]
	BRIDGE = E.PVTable["BRIDGE"]
	g_dirtyNames = false
	g_lastFolderName = {}

	if (CONFIG == nil) then E:trace( "JUNGHOME_Gateway: FEHLER - CONFIGURATION-Ordner nicht gefunden (InterfaceDescription.xml pruefen)" ) end
	if (STATUS == nil) then E:trace( "JUNGHOME_Gateway: FEHLER - STATUS-Ordner nicht gefunden (InterfaceDescription.xml pruefen)" ) end
	if (BRIDGE == nil) then E:trace( "JUNGHOME_Gateway: FEHLER - BRIDGE-Ordner nicht gefunden (InterfaceDescription.xml pruefen)" ) end

	CreateInstanceTable()

	HTTP_RQ = E.ResourceTable["HTTP"]
	if (HTTP_RQ ~= nil) then
		HTTP_RQ:Open()
	else
		E:trace( "JUNGHOME_Gateway: FEHLER - HTTP-Ressource 'HTTP' nicht gefunden (RESOURCES in InterfaceDescription.xml pruefen)" )
	end

	HTTP_SRV = E.ResourceTable["HTTPBRIDGE"]
	if (HTTP_SRV ~= nil) then
		local ok, err = HTTP_SRV:Open()
		if (1 ~= ok) then
			E:trace( "JUNGHOME_Gateway: FEHLER - HTTP-Bridge konnte nicht gestartet werden: " .. tostring(err) )
		else
			setVal( BRIDGE, "BRIDGE_PORT", 8151 )
			E:trace( "JUNGHOME_Gateway: HTTP-Bridge gestartet auf Port 8151 (siehe RESOURCES/HTTPSERVER LOCALPORT)" )
		end
	else
		E:trace( "JUNGHOME_Gateway: FEHLER - HTTPSERVER-Ressource 'HTTPBRIDGE' nicht gefunden (RESOURCES in InterfaceDescription.xml pruefen)" )
	end

	if (getNum( CONFIG, "PORT" ) == 0) then setVal( CONFIG, "PORT", 443 ) end

	-- Einmalige Standardwerte setzen (nur beim allerersten Init, danach nie wieder,
	-- damit eine spaetere bewusste Aenderung durch den Benutzer nicht ueberschrieben wird).
	if (getNum( CONFIG, "DEFAULTS_SET" ) == 0) then
		setVal( CONFIG, "USE_HTTPS", 1 )
		setVal( CONFIG, "DEFAULTS_SET", 1 )
		E:trace( "JUNGHOME_Gateway: Standardwerte einmalig gesetzt (USE_HTTPS=1)" )
	end

	E:trace( "JUNGHOME_Gateway: Konfiguration Host='" .. getStr(CONFIG,"HOST") .. "' Port=" ..
		tostring(getNum(CONFIG,"PORT")) .. " HTTPS=" .. tostring(getNum(CONFIG,"USE_HTTPS")) )
	if (getStr( CONFIG, "HOST" ) == "") then
		E:trace( "JUNGHOME_Gateway: WARNUNG - CONFIGURATION.HOST ist leer, es koennen keine Anfragen gesendet werden" )
	end

	setStatus( "PAIRING", 0 )
	if (getStr( CONFIG, "TOKEN" ) ~= "") then
		E:trace( "JUNGHOME_Gateway: Token vorhanden, starte Resync" )
		setStatus( "CONNECTED", 1 )
		EnqueueResync()
	else
		E:trace( "JUNGHOME_Gateway: kein Token vorhanden - CONFIGURATION.START_PAIRING auf 1 setzen (nach Tastendruck am Gateway)" )
		setStatus( "CONNECTED", 0 )
	end
end

function Exit()
	E:trace( "---- JUNGHOME_Gateway: Exit ----" )
	if (HTTP_RQ ~= nil) then HTTP_RQ:Close() end
	if (HTTP_SRV ~= nil) then HTTP_SRV:Close() end
end

function Poll()
	if (CONFIG == nil) then
		E:trace( "JUNGHOME_Gateway: Poll uebersprungen - CONFIG ist nil (Init nicht erfolgreich gelaufen)" )
		return
	end

	if (getNum( STATUS, "PAIRING" ) ~= 0) then
		DoRegister()
		return
	end

	if (getStr( CONFIG, "TOKEN" ) == "") then
		g_nIdleTicks = g_nIdleTicks + 1
		if ((g_nIdleTicks % 15) == 1) then
			E:trace( "JUNGHOME_Gateway: warte auf Kopplung - kein Token (CONFIGURATION.START_PAIRING setzen)" )
		end
		return
	end

	if (getNum( STATUS, "RESYNC" ) ~= 0) then
		DoResyncStep()
		return
	end

	g_nFunctionRefreshCounter = g_nFunctionRefreshCounter + 1
	if (g_nFunctionRefreshCounter >= FUNCTION_REFRESH_INTERVAL_S) then
		g_nFunctionRefreshCounter = 0
		PollNextDatapoint()
	end
end

function OnValueRead( oVarPath, nReason )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessRead) and (a ~= constAccessReadWrite)) then return end

	-- Explizites "Lesen" im JVP-Geraete-Editor (nReason == constWriteReadCmd) zuerst
	-- live vom Gateway nachladen, statt nur den (evtl. veralteten) Cache-Wert
	-- zurueckzugeben. Ohne diese Unterscheidung wirkt ein manuelles "Lesen" wirkungslos,
	-- wenn sich der Wert seit dem letzten Poll/Resync geaendert hat - OnValueRead hat
	-- nReason bisher komplett ignoriert (Erkenntnis aus einem anderen JVP-Interface).
	if (nReason == constWriteReadCmd) then
		local oDp = oVarPath:_findParentFromUserType( "datapoint_t" )
		if (oDp ~= nil) then
			local oFn = oVarPath:_findParentFromUserType( "function_t" )
			if (oFn ~= nil) then RefreshDatapointInstance( oFn, oDp ) end
		else
			local oFn = oVarPath:_findParentFromUserType( "function_t" )
			if (oFn ~= nil) then
				RefreshFunctionInstance( oFn )
			else
				local oSc = oVarPath:_findParentFromUserType( "scene_t" )
				if (oSc ~= nil) then RefreshScene( oSc ) end
			end
		end
	end

	local val = v:GetValue()
	if (nil ~= val) then
		v:SetValue( val, (nReason == constWriteReadCmd) and constResponse or constResponseFromCache )
	end
end

function OnValueChange( oVarPath, strValue )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessReadWrite) and (a ~= constAccessWrite)) then return end

	-- Schreibbefehl gegenueber JVP bestaetigen: uebernimmt den Wert ins
	-- Prozessmodell und in die Visualisierung. Muss bei JEDER Wertaenderung
	-- durch JVP erfolgen. NICHT fuer selbst gesetzte Ausgaenge (dort constValueChange).
	if (strValue ~= nil) then
		v:SetValue( strValue, constWriteAck )
	end

	local name = v:GetScriptName()
	E:trace( "JUNGHOME_Gateway: OnValueChange " .. tostring(name) .. " = " .. tostring(strValue) )

	-- STATUS-Ebene ------------------------------------------------------
	if (name == "RESYNC") then
		if (strValue == "1") then EnqueueResync() end
		return
	end

	-- CONFIGURATION-Ebene -------------------------------------------------
	if (name == "START_PAIRING") then
		if (strValue == "1") then
			nPairingAttempts = 0
			setStatus( "PAIRING", 1 )
			clearError()
			DoRegister()
		end
		return
	end

	-- Datapoint-Instanz (verschachtelt unter Function) ---------------------
	-- _findParentFromUserType() sucht bei jedem Aufruf frisch vom geaenderten
	-- Datenpunkt (Leaf) nach oben; ein zweiter Aufruf mit "function_t" findet
	-- daher zuverlaessig den umschliessenden Function-Ordner, auch ueber den
	-- bereits gefundenen Datapoint-Ordner hinweg.
	local oDp = oVarPath:_findParentFromUserType( "datapoint_t" )
	if (oDp ~= nil) then
		local oFn = oVarPath:_findParentFromUserType( "function_t" )
		if (oFn == nil) then
			E:trace( "JUNGHOME_Gateway: FEHLER - Datapoint-Instanz ohne umschliessende Function-Instanz gefunden" )
			return
		end
		if (name == "DATAPOINT_ID") then
			RefreshDatapointInstance( oFn, oDp )
			return
		end
		local slot = tostring(name):match( "^VALUE(%d)$" )
		if (slot ~= nil) then
			WriteDatapointValue( oFn, oDp, tonumber(slot), strValue )
			return
		end
		return
	end

	-- Function-Instanz (oberste Ebene, z.B. FUNCTION_ID) --------------------
	local oFn = oVarPath:_findParentFromUserType( "function_t" )
	if (oFn ~= nil) then
		if (name == "FUNCTION_ID") then
			RefreshFunctionInstance( oFn )
			return
		end
		return
	end

	-- Scene-Instanz ---------------------------------------------------------
	local oSc = oVarPath:_findParentFromUserType( "scene_t" )
	if (oSc ~= nil) then
		if (name == "SCENE_ID") then
			RefreshScene( oSc )
			return
		end
		if (name == "ACTIVATE") then
			if (strValue == "1") then ActivateScene( oSc ) end
			return
		end
	end
end
