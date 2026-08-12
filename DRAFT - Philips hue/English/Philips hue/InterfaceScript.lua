-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script PhilipsHueInterface
--
-- JUNG Visu Pro (JVP) process connection for a Philips Hue Bridge (local
-- network, CLIP v1 REST API for lights/groups/scenes/sensors/rules,
-- optional CLIP v2 for presence status/geofencing).
--
-- IMPORTANT NOTE ON THE HTTP RESOURCE:
-- Per the JVP documentation "Process interface HTTP commands", the HTTP
-- request type is NUMERIC: 0=GET, 1=POST, 2=PUT, 3=DELETE. These numbers are
-- passed directly as "method" to SendRequest() (not a string, no global
-- constant - either of those previously caused the bridge to fall back to GET).
--
-- All datapoint SCRIPTNAMEs are unique across the entire interface (prefixed
-- per instance type: LIGHT_/GROUP_/SCENE_/SENSOR_/AUTOMATION_), since JVP
-- requires SCRIPTNAME to be globally unique, not just unique per folder.
--
-- SEND/RECEIVE DATAPOINTS: Every controllable value (on/off, brightness,
-- color, ...) is split into two datapoints: a "*_CMD" (Write, send datapoint -
-- from the operator/visualization towards the bridge) and the base name
-- without suffix (Read, receive datapoint/feedback - from the bridge back).
-- Every incoming write is immediately acknowledged in OnValueChange() with
-- constWriteAck; the apply*/refreshSingle* functions write feedback values
-- using constValueChange instead (see setVal()).
--
-- POLLING: States are generally only queried once at Init() or manually via
-- CONFIGURATION.REFRESH_STATES (the installation rarely changes). Exception:
-- every light has its own LIGHT_POLL_INTERVAL (seconds, 0=off); if set, that
-- light is queried automatically on the configured cadence (see
-- pollLightsIfDue(), called from Poll() every mg_nPollSeconds).
-- Additionally: when a light is switched via a *_CMD datapoint (on/off,
-- brightness, hue, saturation, color temperature), triggerLightPollBoost()
-- starts a boost window of LIGHT_POLL_BOOST_DURATION_SECONDS seconds during
-- which that light is queried at the LIGHT_POLL_BOOST_INTERVAL_SECONDS
-- cadence - regardless of the configured LIGHT_POLL_INTERVAL (even at 0=off).
-- Once the boost window ends, only the configured LIGHT_POLL_INTERVAL applies
-- again.
--
-- LOGGING (commercial deployment): traceMsg() replaces E:trace() and also
-- writes every message (timestamped) into the rolling STATUS.DEBUG_LOG
-- datapoint (PVSTRING) - the content can be copied directly from the JVP
-- editor. Deliberately NOT logged: individual HTTP requests, switching
-- commands, or successful reload/poll operations - that would be too much
-- noise for continuous operation. Logged are only: start/stop (Init/Exit),
-- the pairing flow, connection/presence changes, and error messages (HTTP,
-- JSON, configuration errors, etc.).
-- CONFIGURATION.CLEAR_DEBUG_LOG (write 1) clears the log again.
--
-- Target runtime: Lua 5.1.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"
json = require "json"

mg_nPollSeconds = 1                -- keep in sync with INFO POLLTIME (1000 ms)
local MAX_DEBUG_LOG_LEN = 4000     -- character budget for STATUS.DEBUG_LOG

-- Boost polling: while a light's boost is active (see
-- triggerLightPollBoost()), that light is queried once per second instead of
-- at the configured LIGHT_POLL_INTERVAL. Requires INFO POLLTIME <= 1000 ms so
-- Poll() is actually invoked often enough.
local LIGHT_POLL_BOOST_INTERVAL_SECONDS = 1
local LIGHT_POLL_BOOST_DURATION_SECONDS = 30

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
g_lightBoostUntil = {}             -- Hue light id -> os.time() until which the poll boost is active

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
-- tolerant of comma decimals ("100,000000" - some JVP locales use a comma as
-- the decimal separator) and unit suffixes. Plain tonumber() returns nil for
-- comma decimals, which previously made every *_CMD handler silently fall
-- back to its "or 0"/"or 2700" default (e.g. Brightness=100,000000% was sent
-- to the bridge as bri=1).
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

--- Count entries in a hash-style table (Hue id -> instance folder).
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

--- Convert a UTF-8 Hue name (e.g. containing accented characters) to something
-- JVP's PVSTRING displays correctly. Falls back to the raw string if the HTTP
-- resource's ConvertUTF8ToASCII() is unavailable or errors.
local function fixName( raw )
	if (raw == nil) then return "" end
	if (HTTP_RQ == nil) then return raw end
	local ok, converted = pcall( function() return HTTP_RQ:ConvertUTF8ToASCII( raw ) end )
	if (ok and (converted ~= nil)) then return converted end
	return raw
end

-------------------------------------------------------------------------------
-- Value conversions: JVP datapoints (%, Kelvin, degrees) <-> Hue API values
-------------------------------------------------------------------------------

local function percentToBri( p )  return clamp( round( (p or 0) / 100 * 254 ), 1, 254 ) end
-- Hue's "bri" runs from 1 (minimum, light is on) to 254 - 0 means "off" in the
-- API and never occurs for a reachable/on light. Plain linear rounding
-- (1/254*100 = 0.39%) would round bri=1 down to 0% - the Hue app, however,
-- shows "1%" in that case, never "0%", as long as the light is on. So any
-- bri > 0 is raised to at least 1%, keeping the JVP display consistent with
-- the Hue app.
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
-- HTTP / Hue API
-------------------------------------------------------------------------------

--- Perform one HTTP request against the bridge and JSON-decode the response.
-- Every single sub-step (SetURL/Headers/Open/SendRequest/GetRxData/Close) is
-- wrapped in pcall(), but only actual FAILURES are traced (commercial
-- deployment: STATUS.DEBUG_LOG/E:trace should only contain startup behavior
-- and error messages, not a recording of every single HTTP step).
-- @param method       number  HTTP method, numeric: 0=GET, 1=POST, 2=PUT, 3=DELETE.
-- @param path          string  URL path, e.g. "/api/<key>/lights".
-- @param bodyTable     table|nil  Lua table to JSON-encode as the request body.
-- @param useHttps      boolean  true for the CLIP v2 (HTTPS) API, false for CLIP v1 (HTTP).
-- @param useAppKeyHeader boolean  true to send the "hue-application-key" header (CLIP v2).
-- @return table|nil decoded response, string|nil error
local function httpRequest( method, path, bodyTable, useHttps, useAppKeyHeader )
	if (HTTP_RQ == nil) then
		traceMsg( "ERROR - E.ResourceTable[\"HTTP\"] is nil" )
		return nil, "HTTP resource not initialized"
	end
	local host = getStr( CFG, "BRIDGE_IP" )
	if (host == "") then
		traceMsg( "ERROR - No Bridge IP configured" )
		return nil, "No Bridge IP configured"
	end

	local url = (useHttps and "https://" or "http://") .. host .. path
	local body = ""
	if (bodyTable ~= nil) then body = json.encode( bodyTable ) end

	-- Order: SetURL() MUST be called before Open() - Open() appears to connect
	-- using the URL set at that point. Open()/Close() are deliberately called
	-- per request rather than once in Init()/Exit(), since the resource would
	-- otherwise connect to a default target ("GET /").
	local pOk, pErr

	pOk, pErr = pcall( function() HTTP_RQ:SetURL( url ) end )
	if (not pOk) then
		traceMsg( "ERROR SetURL (" .. path .. "): " .. tostring(pErr) )
		return nil, "SetURL failed: " .. tostring(pErr)
	end

	pcall( function() HTTP_RQ:RemoveHeaders() end )
	pcall( function() HTTP_RQ:AddHeader( "Content-Type: application/json" ) end )
	if (useAppKeyHeader) then
		pcall( function() HTTP_RQ:AddHeader( "hue-application-key: " .. getStr( CFG, "API_KEY" ) ) end )
	end

	pOk, pErr = pcall( function() HTTP_RQ:Open() end )
	if (not pOk) then
		traceMsg( "ERROR Open (" .. path .. "): " .. tostring(pErr) )
		return nil, "Open failed: " .. tostring(pErr)
	end

	pOk, pErr = pcall( function() HTTP_RQ:SendRequest( method, body ) end )
	if (not pOk) then
		traceMsg( "ERROR SendRequest (" .. path .. "): " .. tostring(pErr) )
		pcall( function() HTTP_RQ:Close() end )
		return nil, "SendRequest failed: " .. tostring(pErr)
	end

	local rxOk, returnCode, err, httpStatus, data = pcall( function() return HTTP_RQ:GetRxData() end )
	if (not rxOk) then
		traceMsg( "ERROR GetRxData (" .. path .. "): " .. tostring(returnCode) )
		pcall( function() HTTP_RQ:Close() end )
		return nil, "GetRxData failed: " .. tostring(returnCode)
	end

	pcall( function() HTTP_RQ:Close() end )

	if ((err ~= nil) and (tostring(err) ~= "")) then
		traceMsg( "HTTP error at " .. path .. ": " .. tostring(err) )
		return nil, tostring(err)
	end
	local hs = tonumber( httpStatus )
	if ((hs ~= nil) and ((hs < 200) or (hs >= 300))) then
		traceMsg( "HTTP " .. tostring(hs) .. " at " .. path )
		return nil, "HTTP " .. tostring(hs)
	end
	if ((data == nil) or (data == "")) then
		traceMsg( "Empty response at " .. path )
		return nil, "Empty response"
	end

	local jOk, decoded = pcall( json.decode, data )
	if (not jOk) then
		traceMsg( "JSON error at " .. path .. ": " .. tostring(decoded) )
		return nil, "JSON error: " .. tostring(decoded)
	end
	return decoded, nil
end

-------------------------------------------------------------------------------
-- Automatic bridge discovery (fallback for a changed bridge IP)
-------------------------------------------------------------------------------

local DISCOVERY_URL              = "https://discovery.meethue.com/"
local AUTO_DISCOVER_MIN_INTERVAL = 300  -- seconds between two discovery attempts (rate limit for discovery.meethue.com)
g_lastAutoDiscoverAttempt = 0

--- Queries Philips' cloud discovery service for the internal IP address the
-- bridge is currently using and adopts it into CONFIGURATION.BRIDGE_IP if it
-- differs from the currently configured one. Only ever called as a fallback
-- once a connection loss has already been detected (see
-- RefreshStates()/pollLightsIfDue()), not on every single HTTP failure, and
-- even then at most every AUTO_DISCOVER_MIN_INTERVAL seconds, so as not to
-- put unnecessary load on the cloud service. Only active if the installer has
-- enabled CONFIGURATION.AUTO_DISCOVER_IP.
-- @return boolean true if a new IP was adopted
local function tryAutoDiscoverBridgeIp()
	if (HTTP_RQ == nil) then return false end
	local now = os.time()
	if ((now - g_lastAutoDiscoverAttempt) < AUTO_DISCOVER_MIN_INTERVAL) then return false end
	g_lastAutoDiscoverAttempt = now

	traceMsg( "Attempting automatic bridge discovery via discovery.meethue.com" )

	local pOk, pErr
	pOk, pErr = pcall( function() HTTP_RQ:SetURL( DISCOVERY_URL ) end )
	if (not pOk) then
		traceMsg( "ERROR auto-discovery SetURL: " .. tostring(pErr) )
		return false
	end
	pcall( function() HTTP_RQ:RemoveHeaders() end )
	pOk, pErr = pcall( function() HTTP_RQ:Open() end )
	if (not pOk) then
		traceMsg( "ERROR auto-discovery Open: " .. tostring(pErr) )
		return false
	end
	pOk, pErr = pcall( function() HTTP_RQ:SendRequest( 0, "" ) end )
	if (not pOk) then
		traceMsg( "ERROR auto-discovery SendRequest: " .. tostring(pErr) )
		pcall( function() HTTP_RQ:Close() end )
		return false
	end
	local rxOk, returnCode, err, httpStatus, data = pcall( function() return HTTP_RQ:GetRxData() end )
	pcall( function() HTTP_RQ:Close() end )
	if ((not rxOk) or (data == nil) or (data == "")) then
		traceMsg( "Automatic bridge discovery failed - no response from discovery.meethue.com" )
		return false
	end

	local jOk, decoded = pcall( json.decode, data )
	if ((not jOk) or (type(decoded) ~= "table") or (decoded[1] == nil)) then
		traceMsg( "Automatic bridge discovery failed - no bridge reported" )
		return false
	end

	local newIp = decoded[1]["internalipaddress"]
	if ((newIp == nil) or (newIp == "")) then
		traceMsg( "Automatic bridge discovery failed - no IP in response" )
		return false
	end

	local oldIp = getStr( CFG, "BRIDGE_IP" )
	if (newIp == oldIp) then
		traceMsg( "Automatic bridge discovery: IP unchanged (" .. newIp .. ")" )
		return false
	end

	traceMsg( "Automatic bridge discovery: bridge IP changed from " .. tostring(oldIp) .. " to " .. newIp )
	setVal( CFG, "BRIDGE_IP", newIp )
	return true
end

-------------------------------------------------------------------------------
-- Instance tables (Multiple folder -> Hue ID)
-------------------------------------------------------------------------------

--- @param rootScriptName string  SCRIPTNAME of the Unique parent folder ("Lights"/"Scenes"/...)
--   the Multiple folder now lives under (tree-structure requirement: one main
--   folder per category, in which the installer creates the instances).
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
-- Map bridge responses onto instances
-------------------------------------------------------------------------------

--- Write a single light's values onto its instance. LIGHT_REACHABLE is only
-- set if the bridge supplies the field - newer Hue firmwares/third-party
-- Zigbee devices often omit "reachable" entirely; a hard false->0 would leave
-- the datapoint permanently stuck on "unreachable".
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

--- Write a single scene's values onto its instance. `groupName` (if known) is
-- written to SCENE_GROUP_NAME, so identically named scenes in different rooms
-- (e.g. "Nightlight" in every room) can be told apart. The target group ID is
-- only taken from the bridge for room scenes (sc.group present); roomless
-- light scenes keep the manually entered value.
local function applyOneScene( oInst, sc, groupName )
	setVal( oInst, "SCENE_NAME", fixName(sc.name) )
	if ((sc.group ~= nil) and (tostring(sc.group) ~= "")) then
		setVal( oInst, "SCENE_TARGET_GROUP_ID", sc.group )
	end
	setVal( oInst, "SCENE_GROUP_NAME", groupName or "" )
end

--- @param groupsData table|nil  Raw data from GET /groups (id -> {name=...}), used
--   to resolve the room name per scene without needing a JVP instance for the room.
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
		return (p and "Motion detected" or "No motion"), (p and 1 or 0)
	elseif (t == "ZLLTemperature") or (t == "CLIPTemperature") then
		local c = (tonumber(state.temperature) or 0) / 100
		return string.format( "%.1f C", c ), c
	elseif (t == "ZLLLightLevel") or (t == "CLIPLightLevel") then
		local ll = tonumber( state.lightlevel )
		local lux = 0
		if ((ll ~= nil) and (ll > 0)) then lux = 10 ^ ((ll - 1) / 10000) end
		return string.format( "%.0f lx", lux ), lux
	elseif (t == "ZLLSwitch") or (t == "ZGPSwitch") or (t == "CLIPSwitch") or (t == "ZHASwitch") then
		-- Buttons/remotes AND Zigbee doorbells (Friends of Hue) both appear on
		-- the bridge as a ZHASwitch sensor with buttonevent - there is no
		-- dedicated Hue API type "Doorbell".
		local be = tonumber( state.buttonevent ) or 0
		return tostring( be ), be
	elseif (t == "ZHAOpenClose") or (t == "CLIPOpenClose") then
		-- Window/door contacts (Friends of Hue, e.g. Aqara/Busch-Jaeger)
		local o = (state.open == true)
		return (o and "open" or "closed"), (o and 1 or 0)
	elseif (t == "Daylight") then
		local d = (state.daylight == true)
		return (d and "Day" or "Night"), (d and 1 or 0)
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
		traceMsg( "Presence changed - " .. (anyHome and "someone home" or "no one home") )
		g_lastPresent = anyHome
	end
	setVal( STATUS, "ANY_PRESENT", anyHome and 1 or 0 )
end

-------------------------------------------------------------------------------
-- Single-instance refresh (when a *_HUE_ID is newly entered/changed)
-------------------------------------------------------------------------------

--- Reload exactly one light/group/scene/sensor/automation from the bridge and
-- write it onto the given instance. Triggered from OnValueChange() as soon as
-- a *_HUE_ID field changes, so the name/status of a newly entered ID doesn't
-- have to wait for the next manual CONFIGURATION.REFRESH_STATES.
-- @return boolean true on success (or if there was nothing to do), false on HTTP failure
local function refreshSingleLight( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return true end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/lights/" .. id, nil, false, false )
	if (data ~= nil) then
		applyOneLight( oInst, data )
		return true
	else
		traceMsg( "Light " .. id .. " could not be reloaded: " .. tostring(err) )
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
		traceMsg( "Group " .. id .. " could not be reloaded: " .. tostring(err) )
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
		traceMsg( "Scene " .. id .. " could not be reloaded: " .. tostring(err) )
	end
end

local function refreshSingleSensor( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/sensors/" .. id, nil, false, false )
	if (data ~= nil) then
		applyOneSensor( oInst, data )
	else
		traceMsg( "Sensor " .. id .. " could not be reloaded: " .. tostring(err) )
	end
end

local function refreshSingleAutomation( oInst, id )
	local apiKey = getStr( CFG, "API_KEY" )
	if ((id == "") or (apiKey == "")) then return end
	local data, err = httpRequest( 0, "/api/" .. apiKey .. "/rules/" .. id, nil, false, false )
	if (data ~= nil) then
		applyOneAutomation( oInst, data, id )
	else
		traceMsg( "Automation " .. id .. " could not be reloaded: " .. tostring(err) )
	end
end

-------------------------------------------------------------------------------
-- Status refresh (once at Init(), then only on request)
-------------------------------------------------------------------------------

--- Query the states of all configured lights/groups/sensors/scenes/automations
-- (and presence, if enabled) once from the bridge, in full, and write them
-- onto the instances. Does NOT run automatically on every Poll() cycle
-- anymore - the installation rarely changes. Instead: once at the end of
-- Init(), and afterwards only on request via the CONFIGURATION.REFRESH_STATES
-- datapoint. Write commands (OnValueChange) are independent of this and
-- continue to take effect immediately.
-- @param isRetryAfterDiscovery boolean|nil  set internally when this is the one-time
--        retry after an automatic bridge discovery (prevents an infinite loop
--        if the connection keeps failing)
function RefreshStates( isRetryAfterDiscovery )
	local apiKey   = getStr( CFG, "API_KEY" )
	local bridgeIp = getStr( CFG, "BRIDGE_IP" )
	if ((bridgeIp == "") or (apiKey == "")) then
		setVal( STATUS, "CONNECTED", 0 )
		traceMsg( "Status refresh skipped - Bridge IP or API key missing" )
		return
	end

	traceMsg( "Status refresh started" )
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
		traceMsg( "Connection " .. (allOk and "restored" or "lost") )
		g_lastConnected = allOk
	end

	setVal( STATUS, "CONNECTED", allOk and 1 or 0 )
	setVal( STATUS, "LAST_UPDATE", nowStr() )
	traceMsg( "Status refresh completed" )

	if ((not allOk) and (not isRetryAfterDiscovery) and (getStr( CFG, "AUTO_DISCOVER_IP" ) == "1")) then
		if (tryAutoDiscoverBridgeIp()) then
			RefreshStates( true )
		end
	end
end

-------------------------------------------------------------------------------
-- Inventory (Hue IDs -> names, to transfer into JVP instances)
-------------------------------------------------------------------------------

local MAX_INVENTORY_LEN = 6000  -- character budget PER category (own field per category, see below)

--- Return the IDs (Lua table keys) sorted numerically, for a readable order.
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

--- Build a tab-separated line list from `lines` and write it (truncated if
-- necessary) into the given STATUS field. Each category has its own field, so
-- a long scene list doesn't crowd out the following categories.
local function writeInventoryField( fieldName, lines, label )
	local full = table.concat( lines, "\n" )
	if (#full > MAX_INVENTORY_LEN) then
		full = full:sub( 1, MAX_INVENTORY_LEN ) .. "\n... (truncated - " .. tostring(#lines) .. " lines total)"
	end
	setVal( STATUS, fieldName, full )
end

--- Query lights/groups/scenes/sensors/rules from the bridge in full and write
-- a tab-separated list (Hue ID / name / extra info) per category to
-- STATUS.INVENTORY_* - independent of already-created JVP instances, so the
-- available IDs are known before creating the instances.
local function dumpInventory()
	local apiKey = getStr( CFG, "API_KEY" )
	if (apiKey == "") then
		traceMsg( "Inventory: no API key - pair first" )
		return
	end
	local base = "/api/" .. apiKey

	local lights = httpRequest( 0, base .. "/lights", nil, false, false )
	if (type(lights) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(lights) ) do
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( lights[id].name )
		end
		writeInventoryField( "INVENTORY_LIGHTS", lines, "Lights" )
	end

	local groups = httpRequest( 0, base .. "/groups", nil, false, false )
	if (type(groups) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(groups) ) do
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( groups[id].name )
		end
		writeInventoryField( "INVENTORY_GROUPS", lines, "Groups" )
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
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( sc.name ) .. "\tGroup " .. groupLabel
		end
		writeInventoryField( "INVENTORY_SCENES", lines, "Scenes" )
	end

	local sensors = httpRequest( 0, base .. "/sensors", nil, false, false )
	if (type(sensors) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(sensors) ) do
			local s = sensors[id]
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( s.name ) .. "\t" .. tostring( s.type )
		end
		writeInventoryField( "INVENTORY_SENSORS", lines, "Sensors" )
	end

	local rules = httpRequest( 0, base .. "/rules", nil, false, false )
	if (type(rules) == "table") then
		local lines = {}
		for _, id in ipairs( sortedIds(rules) ) do
			lines[#lines + 1] = tostring(id) .. "\t" .. fixName( rules[id].name )
		end
		writeInventoryField( "INVENTORY_AUTOMATIONS", lines, "Automations" )
	end

	traceMsg( "Inventory complete" )
end

-------------------------------------------------------------------------------
-- Automatic ID assignment (IDs found on the bridge -> created JVP instances)
-------------------------------------------------------------------------------

--- Collect the IDs already present in the existing instances of `list` under
-- `idField` (so they are not assigned twice during automatic assignment).
local function collectUsedIds( list, idField )
	local used = {}
	for _, tbl in pairs( list or {} ) do
		local id = getStr( tbl, idField )
		if (id ~= "") then used[id] = true end
	end
	return used
end

--- Assign the IDs from `sortedIdList` found on the bridge to the instances of
-- a category, in creation order (1st, 2nd, 3rd, ...) - instance 1 gets the
-- first ID found, instance 2 the second, etc. Instances that already have an
-- ID are skipped (not overwritten), and already-used IDs are skipped when
-- assigning.
-- @param rootScriptName string  SCRIPTNAME of the main folder ("LIGHTS_ROOT", ...)
-- @param scriptName string  SCRIPTNAME of the Multiple folder ("Light", ...)
-- @param idField string  SCRIPTNAME of the ID field ("LIGHT_HUE_ID", ...)
-- @param sortedIdList table  numerically sorted list of IDs found on the bridge
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
		traceMsg( scriptName .. ": " .. assigned .. " ID(s) automatically assigned" )
	end
end

--- Query lights/groups/scenes/sensors/rules from the bridge and assign the
-- IDs found to the instances already created in the JVP editor - each in
-- creation order (instance 1 = first ID found, etc.). Only instances with an
-- empty ID field are filled in; existing assignments are left untouched.
-- Triggered via CONFIGURATION.ASSIGN_IDS.
function AssignInventoryIds()
	local apiKey = getStr( CFG, "API_KEY" )
	if (apiKey == "") then
		traceMsg( "ID assignment: no API key - pair first" )
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

	traceMsg( "ID assignment completed" )
	RebuildInstanceTables()
	RefreshStates()
end

-------------------------------------------------------------------------------
-- Pairing (link-button flow, CLIP v1 "POST /api")
-------------------------------------------------------------------------------

local function doPairingAttempt()
	local resp, err = httpRequest( 1, "/api", { devicetype = "jvp#hue-interface" }, false, false )
	if (resp == nil) then return false, err or "No response" end
	local first = resp[1]
	if (type(first) ~= "table") then return false, "Unexpected response" end
	if ((first.success ~= nil) and (first.success.username ~= nil)) then
		return true, first.success.username
	end
	if (first.error ~= nil) then
		return false, tostring( first.error.description or first.error.type or "Error" )
	end
	return false, "Unexpected response"
end

local function startPairing()
	g_pairing = true
	g_pairingDeadline = os.time() + 300  -- 5-minute window to press the link button
	traceMsg( "Pairing started - press the link button within 5 minutes" )
	setVal( STATUS, "PAIRING_STATE", "Waiting for button press on the bridge..." )
end

local function pollPairing()
	if (not g_pairing) then return end
	if (os.time() > g_pairingDeadline) then
		g_pairing = false
		traceMsg( "Pairing window expired" )
		setVal( STATUS, "PAIRING_STATE", "Timeout - please try again" )
		return
	end
	local ok, result = doPairingAttempt()
	if (ok) then
		setVal( CFG, "API_KEY", result )
		g_pairing = false
		traceMsg( "Pairing successful - API key received" )
		setVal( STATUS, "PAIRING_STATE", "Paired" )
		setVal( STATUS, "LAST_ERROR", "" )
	else
		traceMsg( "Pairing attempt failed: " .. tostring(result) )
		local remaining = math.max( 0, g_pairingDeadline - os.time() )
		setVal( STATUS, "PAIRING_STATE", "Waiting for button press... (" .. tostring(remaining) .. "s)" )
		setVal( STATUS, "LAST_ERROR", tostring(result) )
	end
end

-- ===========================================================================
-- JVP lifecycle
-- ===========================================================================

local DEFAULT_LIGHT_POLL_INTERVAL = 10  -- seconds; only applies to instances whose field was never written

--- Set LIGHT_POLL_INTERVAL to DEFAULT_LIGHT_POLL_INTERVAL, but only for light
-- instances whose field is still empty (freshly created, never written).
-- Values that have already been set - including 0, if the installer
-- deliberately disables polling - are never overwritten. Checks all instances
-- directly (not just LIGHTTABLE), so lights without a LIGHT_HUE_ID already get
-- their default value too.
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
	traceMsg( "HTTP_RQ=" .. tostring(HTTP_RQ) .. " (methods numeric: 0=GET 1=POST 2=PUT 3=DELETE)" )
	-- No HTTP_RQ:Open() here: without a URL set beforehand, Open() connects to
	-- a default target ("GET /"). Open() happens per request in httpRequest()
	-- right after SetURL().
	RebuildInstanceTables()
	applyDefaultPollIntervals()
	g_pairing = false
	g_pairingDeadline = 0
	g_pollCount = 0
	g_lastConnected = nil
	g_lastPresent = nil
	g_lastLightPoll = {}
	g_lightBoostUntil = {}
	traceMsg( "Instances loaded - Lights=" .. tblCount(LIGHTTABLE) ..
		" Groups=" .. tblCount(GROUPTABLE) .. " Scenes=" .. tblCount(SCENETABLE) ..
		" Sensors=" .. tblCount(SENSORTABLE) .. " Automations=" .. tblCount(AUTOMATIONTABLE) )
	setVal( STATUS, "PAIRING_STATE", "Ready" )
	RefreshStates()  -- one-time status query at startup; only on request afterwards
end

function Exit()
	traceMsg( "---- PhilipsHue: Exit ----" )
	if (HTTP_RQ ~= nil) then pcall( function() HTTP_RQ:Close() end ) end
end

--- Starts a boost polling window for a light: for
-- LIGHT_POLL_BOOST_DURATION_SECONDS seconds it is queried at the
-- LIGHT_POLL_BOOST_INTERVAL_SECONDS cadence instead of the configured
-- LIGHT_POLL_INTERVAL. Called from OnValueChange() as soon as a light's
-- *_CMD datapoint has been written (i.e. the light was switched via JVP) -
-- this closely tracks any transition/aftereffect of the switching command
-- for a short while. Once the window ends, only the configured
-- LIGHT_POLL_INTERVAL applies again (see pollLightsIfDue()).
-- @param id string  Hue light id
local function triggerLightPollBoost( id )
	if ((id == nil) or (id == "")) then return end
	g_lightBoostUntil[id] = os.time() + LIGHT_POLL_BOOST_DURATION_SECONDS
end

--- Optional automatic polling per light: LIGHT_POLL_INTERVAL (seconds, 0=off)
-- determines how often exactly that light is queried automatically. Called
-- from Poll() (every mg_nPollSeconds); checks per light whether enough time
-- has passed since the last automatic query. Without a set interval, behavior
-- is unchanged (only once at Init() or manually via CONFIGURATION.REFRESH_STATES).
-- If a boost window is currently active for a light (see
-- triggerLightPollBoost()), it is queried at the
-- LIGHT_POLL_BOOST_INTERVAL_SECONDS cadence instead - even if
-- LIGHT_POLL_INTERVAL is 0 (off). Once the window ends, only the configured
-- LIGHT_POLL_INTERVAL applies again.
local function pollLightsIfDue()
	local now = os.time()
	local anyFailed = false
	for id, oInst in pairs( LIGHTTABLE ) do
		local interval = getNum( oInst, "LIGHT_POLL_INTERVAL" )
		local boostUntil = g_lightBoostUntil[id]
		if (boostUntil ~= nil) then
			if (now < boostUntil) then
				interval = LIGHT_POLL_BOOST_INTERVAL_SECONDS
			else
				g_lightBoostUntil[id] = nil  -- boost window expired, back to LIGHT_POLL_INTERVAL
			end
		end
		if (interval > 0) then
			local last = g_lastLightPoll[id] or 0
			if ((now - last) >= interval) then
				g_lastLightPoll[id] = now
				if (not refreshSingleLight( oInst, id )) then anyFailed = true end
			end
		end
	end
	-- Automatic polling is the only path that can notice a bridge IP that
	-- changed while the interface was already running (not just at startup) -
	-- so it also triggers automatic bridge discovery, in addition to RefreshStates().
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
	-- Groups/sensors/scenes/rules are still NOT queried automatically on an
	-- ongoing basis - only once in Init() and on request via
	-- CONFIGURATION.REFRESH_STATES (see RefreshStates()). Write commands from
	-- OnValueChange() are independent of this and continue to take effect
	-- immediately. Lights can additionally be switched to automatic polling
	-- individually via LIGHT_POLL_INTERVAL (0 = off, default).
	pollLightsIfDue()
end

--- On nReason == constWriteReadCmd (an explicit "Read" from the JVP editor, as
-- opposed to constValueRead/constGetUpdate), reload the affected instance
-- live from the bridge first, instead of just returning the possibly stale
-- cached value - otherwise a manual "Read" has no effect if the bridge state
-- has changed since the last refresh.
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
			traceMsg( "ERROR during explicit read (" .. tostring(v:GetScriptName()) .. "): " .. tostring(pErr) )
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

	-- Acknowledge every incoming write immediately, otherwise JVP does not
	-- accept the value into its process model/visualization (see JVP docs).
	-- Values the script sets itself (e.g. feedback from applyOne*) continue to
	-- use constValueChange, not constWriteAck.
	v:SetValue( strValue, constWriteAck )

	local name = v:GetScriptName()

	-- Configuration level (no instance parent folder)
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
		traceMsg( "Bridge IP changed to " .. tostring(strValue) )
		setVal( STATUS, "PAIRING_STATE", "Ready" )
		return
	end
	if (name == "API_KEY") then
		traceMsg( "API key changed manually" )
		setVal( STATUS, "PAIRING_STATE", "Ready" )
		return
	end

	-- Light
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
		else
			return
		end
		-- Switched via JVP (one of the *_CMD datapoints above) -> poll this
		-- light more closely for a while (see triggerLightPollBoost()). Editing
		-- only LIGHT_POLL_INTERVAL, for example, hits the "else" above and
		-- never reaches this point.
		triggerLightPollBoost( id )
		return
	end

	-- Group/Room
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

	-- Scene
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

	-- Automation (Hue rule)
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
