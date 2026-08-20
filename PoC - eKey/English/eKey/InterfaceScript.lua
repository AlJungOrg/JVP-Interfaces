-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script InterfaceScript
--
-- JUNG Visu Pro (JVP) process connection for eKey fingerprint access systems.
--
-- Supports two independent, simultaneously usable input channels:
--
--   1) ekey net / Home / Multi + Converter UDP/LAN
--      The converter sends a UDP datagram to this interface's UDPPORT
--      resource whenever a finger is scanned ('home' or 'multi' protocol,
--      configurable field separator). See RESOURCES/UDPPORT (LOCALPORT) in
--      InterfaceDescription.xml and CONFIGURATION.UDP_PROTOCOL /
--      CONFIGURATION.UDP_SEPARATOR.
--
--   2) ekey bionyx (cloud) function webhooks
--      ekey bionyx calls a "function webhook" (an HTTP request the installer
--      defines in the ekey app) against this interface's embedded HTTPSERVER
--      resource whenever a configured biometric function fires. See
--      RESOURCES/HTTPSERVER (LOCALPORT) and CONFIGURATION.BIONYX_TOKEN.
--      The exact JSON body of the webhook is freely configurable in the ekey
--      app; this script expects (and the accompanying README documents how
--      to configure the ekey app to send) a flat JSON object with the keys
--      "function", "user", "finger", "terminal".
--
-- Both channels update the STATUS folder with the last received event and
-- can trigger one or more "Function" instances (Multiple folder) that the
-- installer creates and maps via MATCH_* datapoints. Each triggered Function
-- pulses its TRIGGERED output for PULSE_MS milliseconds.
--
-- Target runtime: Lua 5.1.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"

local mg_bDebug = false

INSTANCETABLE = {}          -- Function instance name -> folder table
PULSETIMERS   = {}          -- Function folder table -> os.time() the pulse started

UDP_RQ   = nil              -- E.ResourceTable["UDP_EKEY"]
HTTP_SRV = nil              -- E.ResourceTable["HTTP_SRV"]

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

--- Read a datapoint as text ("" if missing/empty).
local function getStr( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return "" end
	return oNode[strName]:GetValue() or ""
end

--- Read a datapoint as a number, tolerant of German comma / unit suffixes.
local function getNum( oNode, strName, nDefault )
	nDefault = nDefault or 0
	if ((oNode == nil) or (oNode[strName] == nil)) then return nDefault end
	local s = oNode[strName]:GetValue()
	if (s == nil) then return nDefault end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	n = tonumber( (s:match( "[-+]?%d+%.?%d*" )) )
	if (n ~= nil) then return n end
	return nDefault
end

--- Write a datapoint the script itself drives (constValueChange).
local function setVal( oNode, strName, value )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		oNode[strName]:SetValue( tostring(value), constValueChange )
	end
end

--- Write a CONFIGURATION default only if the datapoint is currently empty.
local function setDefault( oNode, strName, value )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		local cur = oNode[strName]:GetValue()
		if ((cur == nil) or (cur == "")) then
			oNode[strName]:SetValue( tostring(value), constValueChange )
		end
	end
end

--- Current time as text in the project convention.
local function nowStr()
	return os.date( "%d.%m.%Y %H:%M:%S", os.time() )
end

--- Split strData on a literal (non-pattern) separator string.
-- Uses plain-find so separator characters that are Lua-pattern magic
-- characters (e.g. the ekey default '?') do not need escaping.
local function splitFields( strData, strSep )
	local fields = {}
	if ((strSep == nil) or (strSep == "")) then strSep = "?" end
	local nSepLen  = #strSep
	local nStart   = 1
	while true do
		local i = string.find( strData, strSep, nStart, true )
		if (i == nil) then
			table.insert( fields, string.sub( strData, nStart ) )
			break
		end
		table.insert( fields, string.sub( strData, nStart, i - 1 ) )
		nStart = i + nSepLen
	end
	return fields
end

--- Minimal parser for a FLAT JSON object, e.g. {"function":"Front","user":"Peter"}.
-- Intentionally simple: no nested objects/arrays, no escaped quotes inside
-- string values. Sufficient for the small, self-defined webhook body this
-- interface expects from the ekey bionyx "function webhook" configuration.
local function parseFlatJson( strBody )
	local t = {}
	if (strBody == nil) then return t end
	for k, v in string.gmatch( strBody, '"([%w_%-%. ]+)"%s*:%s*"([^"]*)"' ) do
		t[k] = v
	end
	for k, v in string.gmatch( strBody, '"([%w_%-%. ]+)"%s*:%s*(%-?%d+%.?%d*)' ) do
		if (t[k] == nil) then t[k] = v end
	end
	return t
end

--- Case-insensitive lookup in the HTTPSERVER request.headers table.
local function getHeader( tblHeaders, strName )
	if (tblHeaders == nil) then return nil end
	strName = strName:lower()
	for k, v in pairs( tblHeaders ) do
		if (type(k) == "string") and (k:lower() == strName) then
			return v
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Instance table / dispatch
-------------------------------------------------------------------------------

--- Build INSTANCETABLE from all "function_t" folders under "Function".
function CreateInstanceTable()
	INSTANCETABLE = {}
	local list = E.PVTable["Function"]
	if (list == nil) then return end
	for i, tbl in pairs( list ) do
		if (type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == "function_t") then
			INSTANCETABLE[tbl.e_guid or i] = tbl
			setDefault( tbl, "PULSE_MS", 1000 )
		end
	end
end

--- Pulse a Function instance's TRIGGERED output.
local function triggerFunction( oInst )
	setVal( oInst, "TRIGGERED", 1 )
	setVal( oInst, "LAST_TRIGGERED", nowStr() )
	PULSETIMERS[oInst] = os.time()
end

--- Reset TRIGGERED outputs whose pulse duration has elapsed.
local function updatePulses()
	local nNow = os.time()
	for oInst, nStarted in pairs( PULSETIMERS ) do
		local nPulseSeconds = math.ceil( getNum( oInst, "PULSE_MS", 1000 ) / 1000 )
		if (nPulseSeconds < 1) then nPulseSeconds = 1 end
		if ((nNow - nStarted) >= nPulseSeconds) then
			setVal( oInst, "TRIGGERED", 0 )
			PULSETIMERS[oInst] = nil
		end
	end
end

-------------------------------------------------------------------------------
-- ekey Converter UDP (home / multi protocol)
-------------------------------------------------------------------------------

--- Parse and dispatch one UDP datagram from the ekey Converter.
local function processUdpPacket( strSender, strData )
	local oConfig = E.PVTable["CONFIGURATION"]
	local oStatus = E.PVTable["STATUS"]
	local strProtocol = getStr( oConfig, "UDP_PROTOCOL" )
	if (strProtocol == "") then strProtocol = "home" end
	local strSep = getStr( oConfig, "UDP_SEPARATOR" )
	if (strSep == "") then strSep = "?" end

	local fields = splitFields( strData, strSep )

	local strUserId, strUserName, strFingerId, strSerial, strScannerName, strActionCode, strRelayId

	if (strProtocol == "multi") then
		-- Packet type, User ID, User name, User status, Finger ID, Key ID,
		-- Scanner serial number, Scanner name, Action code, Input ID
		if (#fields < 10) then
			E:trace( "eKey: UDP packet (multi) from " .. tostring(strSender) .. " has only " .. #fields .. " fields, expected 10: " .. tostring(strData) )
			setVal( oStatus, "ERROR", 1 )
			return
		end
		strUserId      = fields[2]
		strUserName    = fields[3]
		strFingerId    = fields[5]
		strSerial      = fields[7]
		strScannerName = fields[8]
		strActionCode  = fields[9]
		strRelayId     = fields[10]
	else
		-- home protocol: Packet type, User ID, Finger ID, Scanner serial
		-- number, Action code, Relay ID
		if (#fields < 6) then
			E:trace( "eKey: UDP packet (home) from " .. tostring(strSender) .. " has only " .. #fields .. " fields, expected 6: " .. tostring(strData) )
			setVal( oStatus, "ERROR", 1 )
			return
		end
		strUserId      = fields[2]
		strUserName    = ""
		strFingerId    = fields[3]
		strSerial      = fields[4]
		strScannerName = ""
		strActionCode  = fields[5]
		strRelayId     = fields[6]
	end

	setVal( oStatus, "ERROR", 0 )
	setVal( oStatus, "LAST_SOURCE", "UDP" )
	setVal( oStatus, "LAST_USER_ID", strUserId )
	setVal( oStatus, "LAST_USER_NAME", strUserName )
	setVal( oStatus, "LAST_FINGER_ID", strFingerId )
	setVal( oStatus, "LAST_SERIAL", strSerial )
	setVal( oStatus, "LAST_SCANNER_NAME", strScannerName )
	setVal( oStatus, "LAST_FUNCTION", "" )
	setVal( oStatus, "LAST_ACTION_CODE", strActionCode )
	setVal( oStatus, "LAST_RELAY_ID", strRelayId )
	setVal( oStatus, "LAST_RAW", strData )
	setVal( oStatus, "LAST_TIMESTAMP", nowStr() )

	for _, oInst in pairs( INSTANCETABLE ) do
		local strMatchUser   = getStr( oInst, "MATCH_USERID" )
		local strMatchFinger = getStr( oInst, "MATCH_FINGERID" )
		local strMatchAction = getStr( oInst, "MATCH_ACTIONCODE" )
		if (strMatchUser ~= "") and (strMatchUser == strUserId) then
			if ((strMatchFinger == "") or (strMatchFinger == strFingerId)) then
				if ((strMatchAction == "") or (strMatchAction == strActionCode)) then
					triggerFunction( oInst )
				end
			end
		end
	end
end

--- Drain all UDP datagrams currently queued on the resource (bounded per Poll).
local function pollUdp()
	if (UDP_RQ == nil) then return end
	local nLoopCount = 0
	while (UDP_RQ:GetRxDataAvailable() ~= 0) and (nLoopCount < 20) do
		local nPort, strSender, strData = UDP_RQ:GetRxData()
		if (strData ~= nil) and (strData ~= "") then
			processUdpPacket( strSender, strData )
		end
		nLoopCount = nLoopCount + 1
	end
end

-------------------------------------------------------------------------------
-- ekey bionyx function webhook (embedded HTTP server)
-------------------------------------------------------------------------------

--- Called by the device editor for every request on the HTTPSERVER resource.
-- @param request table  .method .uri .query .body .headers
-- @return nStatus, strBody, strContentType
function HTTPRequestReceived( request )
	local oConfig = E.PVTable["CONFIGURATION"]
	local oStatus = E.PVTable["STATUS"]

	if (request.method ~= "POST") then
		return 405, "Method not allowed", "text/plain"
	end
	if (request.uri ~= "/ekeybionyx") then
		return 404, "Not found", "text/plain"
	end

	local strToken = getStr( oConfig, "BIONYX_TOKEN" )
	if (strToken ~= "") then
		local strAuth = getHeader( request.headers, "Authorization" )
		if (strAuth ~= ("Bearer " .. strToken)) then
			E:trace( "eKey: bionyx webhook rejected, bad/missing bearer token" )
			return 401, "Unauthorized", "text/plain"
		end
	end

	local data = parseFlatJson( request.body )
	local strFunction = data["function"] or ""
	local strUser     = data["user"] or ""
	local strFinger   = data["finger"] or ""
	local strTerminal = data["terminal"] or ""

	setVal( oStatus, "ERROR", 0 )
	setVal( oStatus, "LAST_SOURCE", "BIONYX" )
	setVal( oStatus, "LAST_USER_ID", strUser )
	setVal( oStatus, "LAST_USER_NAME", strUser )
	setVal( oStatus, "LAST_FINGER_ID", strFinger )
	setVal( oStatus, "LAST_SERIAL", "" )
	setVal( oStatus, "LAST_SCANNER_NAME", strTerminal )
	setVal( oStatus, "LAST_FUNCTION", strFunction )
	setVal( oStatus, "LAST_ACTION_CODE", "" )
	setVal( oStatus, "LAST_RELAY_ID", "" )
	setVal( oStatus, "LAST_RAW", request.body or "" )
	setVal( oStatus, "LAST_TIMESTAMP", nowStr() )

	if (strFunction ~= "") then
		for _, oInst in pairs( INSTANCETABLE ) do
			local strMatchFunction = getStr( oInst, "MATCH_BIONYX_FUNCTION" )
			if (strMatchFunction ~= "") and (strMatchFunction == strFunction) then
				triggerFunction( oInst )
			end
		end
	end

	return 200, '{"status":"ok"}', "application/json"
end

-------------------------------------------------------------------------------
-- JVP lifecycle
-------------------------------------------------------------------------------

function Init()
	E:trace( "---- eKey: Init ----" )

	local oConfig = E.PVTable["CONFIGURATION"]
	setDefault( oConfig, "UDP_PROTOCOL", "home" )
	setDefault( oConfig, "UDP_SEPARATOR", "?" )

	CreateInstanceTable()

	local oStatus = E.PVTable["STATUS"]
	setVal( oStatus, "ERROR", 0 )

	UDP_RQ = E.ResourceTable["UDP_EKEY"]
	if (UDP_RQ ~= nil) then
		UDP_RQ:Open()
		setVal( oStatus, "UDP_RUNNING", 1 )
		E:trace( "eKey: UDP receiver for the ekey Converter opened" )
	else
		setVal( oStatus, "UDP_RUNNING", 0 )
	end

	HTTP_SRV = E.ResourceTable["HTTP_SRV"]
	if (HTTP_SRV ~= nil) then
		local nResult, strError = HTTP_SRV:Open()
		if (nResult == 1) then
			setVal( oStatus, "HTTP_RUNNING", 1 )
			E:trace( "eKey: bionyx webhook HTTP server opened" )
		else
			setVal( oStatus, "HTTP_RUNNING", 0 )
			setVal( oStatus, "ERROR", 1 )
			E:trace( "eKey: bionyx webhook HTTP server NOT started: " .. tostring(strError) )
		end
	else
		setVal( oStatus, "HTTP_RUNNING", 0 )
	end
end

function Exit()
	E:trace( "---- eKey: Exit ----" )
	if (UDP_RQ ~= nil) then UDP_RQ:Close() end
	if (HTTP_SRV ~= nil) then HTTP_SRV:Close() end
end

function Poll()
	pollUdp()
	updatePulses()
end

function OnValueRead( oVarPath, nReason )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessRead) and (a ~= constAccessReadWrite)) then return end
	local val = v:GetValue()
	if (nil ~= val) then v:SetValue( val, constResponseFromCache ) end
end

function OnValueChange( oVarPath, strValue )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessReadWrite) and (a ~= constAccessWrite)) then return end

	-- Acknowledge every write from JVP so the process model / visualization
	-- picks up the new value. Required for every writable datapoint.
	if (strValue ~= nil) then
		v:SetValue( strValue, constWriteAck )
	end

	-- Nothing else to react to: CONFIGURATION and MATCH_*/PULSE_MS are read
	-- back live from E.PVTable on every event, no cached copies to refresh.
	-- Exception: a newly created Function instance is not yet in
	-- INSTANCETABLE, so rebuild it whenever a Function-folder datapoint is
	-- written (cheap: only happens on configuration edits, not on events).
	local oInst = oVarPath:_findParentFromUserType( "function_t" )
	if (oInst ~= nil) then
		CreateInstanceTable()
	end
end
