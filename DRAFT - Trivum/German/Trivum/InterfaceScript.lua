-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script InterfaceScript
--
-- JUNG Visu Pro (JVP) process connection for trivum multiroom audio systems.
-- Talks to the trivum "mcenter" HTTP/XML API documented at
-- https://www.trivum.com/trivum/docs/en/mcenter-api.html
--
-- Controls, per zone: power, mute, volume, source
-- selection and transport (play/pause/stop/next/previous), plus a generic
-- numeric command point for any trivum multi command code. Polls zone and
-- source status (power, volume, artist/album/track/imageURL) round robin,
-- one zone per Poll() tick, to avoid blocking the runtime on many zones.
--
-- Feedback / Rueckmeldung: every persistent-value command datapoint (POWER,
-- MUTE, VOLUME) has a separate read-only *_RM sibling,
-- populated only from the polled device status - decoupled from the write/
-- ack side of the original point (KNX-style Sollwert/Rueckmeldung split).
-- Momentary command telegrams (POWER/MUTE/PLAY/PAUSE/STOP/PLAYPAUSE/NEXT/
-- PREVIOUS/JOIN/UNJOIN/COMMAND) additionally report through LASTCOMMAND /
-- LASTCOMMAND_TIME, set directly when the telegram is sent (no poll needed
-- for a momentary action). ALL_OFF reports through STATUS.LAST_ALLOFF_TIME.
--
-- Target runtime: Lua 5.1.
--
-- Changelog 2026-08-20 (Erkenntnisse aus anderen JVP-Interfaces in diesem
-- Projektordner uebernommen, siehe JVP-JUNGHOME und JVP-Hue V2):
--   * OnValueRead beruecksichtigt jetzt nReason: ein explizites "Lesen" im
--     JVP-Geraete-Editor (constWriteReadCmd) laedt die betroffene Zone /
--     die Favoritenliste sofort live nach, statt nur den ggf. veralteten
--     Cache-Wert zurueckzugeben (im JUNGHOME-Interface als Luecke gefunden:
--     "OnValueRead hat nReason bisher komplett ignoriert").
--   * CONFIGURATION/STATUS/FAVORITES werden einmal in Init() in die globalen
--     Variablen CONFIG/STATUS/FAV gecached, statt sie ueber E.PVTable[...]
--     verstreut in jeder Funktion neu nachzuschlagen.
--   * Neue Komfortfunktion "Zonen auflisten" (CONFIGURATION.LIST_ZONES ->
--     STATUS.ZONES_LIST), analog zur "Inventar auflisten"-Funktion des
--     Hue-V2-Interfaces bzw. STATUS.FUNCTIONS_JSON im JUNGHOME-Interface:
--     zeigt ID + Name aller trivum Zonen an, damit ZONE_ID beim Anlegen
--     einer Zonen-Instanz nicht mehr manuell im trivum Webinterface
--     nachgeschlagen werden muss.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"

local mg_bDebug = false            -- set true for verbose per-poll / per-request tracing
mg_nPollSeconds = 2                -- keep in sync with INFO POLLTIME (2000 ms)

INSTANCETABLE = {}                 -- zone instance name -> folder table
ZONELIST      = {}                 -- ordered array of zone folder tables (round robin)
g_nPollIndex  = 1                  -- round robin pointer into ZONELIST
HTTP_RQ       = nil
g_bLastConnected = nil              -- last reported CONNECTED state, for edge-triggered tracing

CONFIG = nil                       -- E.PVTable["CONFIGURATION"], cached in Init()
STATUS = nil                       -- E.PVTable["STATUS"], cached in Init()
FAV    = nil                       -- E.PVTable["FAVORITES"], cached in Init()

-- trivum multi command numbers, see trivum mcenter API doc, section "ZoneCommand"
local CMD_POWER_OFF   = 1
local CMD_ALL_OFF     = 15
local CMD_POWER_ON    = 7
local CMD_JOIN        = 30
local CMD_UNJOIN      = 31
local CMD_NEXT        = 400
local CMD_PREVIOUS    = 401
local CMD_PLAYPAUSE   = 406
local CMD_PLAY        = 431
local CMD_PAUSE       = 432
local CMD_STOP        = 433
local CMD_MUTE_ON     = 680
local CMD_MUTE_OFF    = 681

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function parseNum( s )
	if (s == nil) then return nil end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	return tonumber( (s:match( "[-+]?%d+%.?%d*" )) )
end

--- Read a datapoint as a number, tolerant of German comma / unit suffixes.
-- @param oNode table  folder holding the datapoint
-- @param strName string  SCRIPTNAME of the datapoint
-- @param default number  fallback if missing/unparsable
-- @return number
local function getNum( oNode, strName, default )
	default = default or 0
	if ((oNode == nil) or (oNode[strName] == nil)) then return default end
	local n = parseNum( oNode[strName]:GetValue() )
	if (n ~= nil) then return n end
	return default
end

--- Read a datapoint as text ("" if missing).
-- @param oNode table
-- @param strName string
-- @return string
local function getStr( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return "" end
	return oNode[strName]:GetValue() or ""
end

--- Write a datapoint (guarded), reason constValueChange (script driven output).
-- @param oNode table
-- @param strName string
-- @param value any
local function setVal( oNode, strName, value )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		oNode[strName]:SetValue( tostring(value), constValueChange )
	end
end

--- Current time as text in the project format.
-- @return string
local function nowStr()
	return os.date( "%d.%m.%Y %H:%M:%S", os.time() )
end

--- Verbose trace, only emitted when mg_bDebug is true (per-poll / per-request detail).
-- @param strMsg string
local function traceDebug( strMsg )
	if (mg_bDebug) then E:trace( strMsg ) end
end

--- Very small XML helper: first <tag>...</tag> content in strData (non greedy).
-- @param strData string
-- @param strTag string
-- @return string|nil
local function xmlTag( strData, strTag )
	if (strData == nil) then return nil end
	return strData:match( "<" .. strTag .. ">(.-)</" .. strTag .. ">" )
end

--- Decode XML entities and trivum's own "_XX" hex escape for special
-- characters (e.g. a space is sent as "_20"), see trivum API doc section
-- "Interactive Music Selection": "_20 means a character with Ascii Code 0x20".
-- trivum applies this scheme broadly across returned text, not just menus.
-- @param s string|nil
-- @return string
local function xmlDecode( s )
	if (s == nil) then return "" end
	s = s:gsub( "&amp;", "&" )
	s = s:gsub( "&lt;", "<" )
	s = s:gsub( "&gt;", ">" )
	s = s:gsub( "&quot;", "\"" )
	s = s:gsub( "&apos;", "'" )
	s = s:gsub( "_(%x%x)", function( hex ) return string.char( tonumber( hex, 16 ) ) end )
	return s
end

--- Parse a loose boolean-ish tag value ("1"/"true"/"on" -> 1, "0"/"false"/"off" -> 0).
-- @param s string|nil
-- @return number|nil
local function parseBoolish( s )
	if (s == nil) then return nil end
	s = s:lower()
	if ((s == "1") or (s == "true") or (s == "on")) then return 1 end
	if ((s == "0") or (s == "false") or (s == "off")) then return 0 end
	return nil
end

--- Decode percent-encoding ("%20" -> space, etc.), as used by the trivum
-- favorites/playlists API (/api/v1/...) - a different scheme than the "_XX"
-- hex escape used in zone status text (see xmlDecode above).
-- @param s string|nil
-- @return string
local function urlDecode( s )
	if (s == nil) then return "" end
	return (s:gsub( "%%(%x%x)", function( hex ) return string.char( tonumber( hex, 16 ) ) end ))
end

-------------------------------------------------------------------------------
-- trivum HTTP access
-------------------------------------------------------------------------------

--- Build "http://host[:port]" from the CONFIGURATION folder.
-- @return string|nil
local function baseURL()
	local host = getStr( CONFIG, "HOST" )
	local port = getNum( CONFIG, "PORT", 80 )
	if (host == "") then return nil end
	if (port == 80) then return "http://" .. host end
	return "http://" .. host .. ":" .. tostring( math.floor(port) )
end

--- Normalize a trivum imageURL to always be a fully qualified http(s) URL.
-- Per trivum API doc "Get current image URL": absolute URLs (http:// or
-- https://, e.g. a TuneIn CDN cover) are used as-is; relative URLs (e.g.
-- "/imgs/sourceTrivumTv_400px.png") get the trivum host prepended.
-- @param url string
-- @return string
local function normalizeImageUrl( url )
	if ((url == nil) or (url == "")) then return "" end
	if (url:match( "^https?://" )) then return url end
	local base = baseURL()
	if (base == nil) then return url end
	if (url:sub(1,1) ~= "/") then url = "/" .. url end
	return base .. url
end

--- Run a trivum HTTP GET call and update the connection status.
-- @param strPath string  e.g. "/xml/zone/runCommand.xml"
-- @param strQuery string  e.g. "zone=@0&command=7"
-- @return boolean ok, string|nil data
local function trivumGet( strPath, strQuery )
	local base = baseURL()
	if ((base == nil) or (HTTP_RQ == nil)) then
		setVal( STATUS, "CONNECTED", 0 )
		setVal( STATUS, "LASTERROR", "HOST nicht konfiguriert oder HTTP Ressource fehlt" )
		if (g_bLastConnected ~= false) then
			E:trace( "trivum: kein Aufruf moeglich - HOST nicht konfiguriert oder HTTP Ressource fehlt" )
			g_bLastConnected = false
		end
		return false, nil
	end

	local url = base .. strPath
	if ((strQuery ~= nil) and (strQuery ~= "")) then
		url = url .. "?" .. strQuery
	end

	traceDebug( "trivum: sende GET " .. url )

	HTTP_RQ:RemoveHeaders()
	HTTP_RQ:SetURL( url )
	HTTP_RQ:SendRequest( HTTP_GET, "" )
	local rc, err, httpStatus, data = HTTP_RQ:GetRxData()

	if ((rc == 0) and (httpStatus == 200)) then
		setVal( STATUS, "CONNECTED", 1 )
		setVal( STATUS, "LASTPOLL", nowStr() )
		-- edge-triggered: nur beim Wechsel von getrennt -> verbunden protokollieren
		if (g_bLastConnected ~= true) then
			E:trace( "trivum: Verbindung hergestellt (" .. base .. ")" )
			g_bLastConnected = true
		end
		traceDebug( "trivum: Antwort ok, " .. tostring(data and #data or 0) .. " Bytes" )
		return true, data
	end

	setVal( STATUS, "CONNECTED", 0 )
	setVal( STATUS, "LASTERROR", tostring(err or httpStatus or "trivum Anfrage fehlgeschlagen") )
	-- edge-triggered: nur beim Wechsel von verbunden -> getrennt protokollieren
	if (g_bLastConnected ~= false) then
		E:trace( "trivum: Verbindung fehlgeschlagen bei " .. url .. " -> " .. tostring(err or httpStatus) )
		g_bLastConnected = false
	end
	return false, nil
end

--- Run a numeric trivum multi command on a zone, and mirror it into the
-- LASTCOMMAND / LASTCOMMAND_TIME feedback points (immediate, no poll needed
-- since these are momentary actions rather than persistent values).
-- @param oZone table|nil  zone_t folder, or nil for global (non zone-bound) commands
-- @param nZoneId number  trivum zone id (0 based)
-- @param nCommand number  trivum ZONECMD_* / MULTIKEY_* code
local function trivumCommand( oZone, nZoneId, nCommand )
	E:trace( "trivum: Kommando " .. tostring(math.floor(nCommand)) .. " an Zone " .. tostring(math.floor(nZoneId)) )
	trivumGet( "/xml/zone/runCommand.xml",
		"zone=@" .. tostring(math.floor(nZoneId)) .. "&command=" .. tostring(math.floor(nCommand)) )
	if (oZone ~= nil) then
		setVal( oZone, "LASTCOMMAND", math.floor(nCommand) )
		setVal( oZone, "LASTCOMMAND_TIME", nowStr() )
	end
end

--- Set a zone attribute (currently only volume). Feedback arrives through
-- the *_RM points on the next poll, not through this call.
-- @param nZoneId number
-- @param strParam string  "volume"
-- @param value number
local function trivumSet( nZoneId, strParam, value )
	E:trace( "trivum: setze " .. strParam .. "=" .. tostring(value) .. " an Zone " .. tostring(math.floor(nZoneId)) )
	trivumGet( "/xml/zone/set.xml",
		"zone=@" .. tostring(math.floor(nZoneId)) .. "&" .. strParam .. "=" .. tostring(value) )
end

--- Select a zone source by trivum short source name, e.g. "a1", "f2", "s", "t".
-- Feedback arrives through SOURCE_DESC / SERVICE on the next poll.
-- @param nZoneId number
-- @param strSource string
local function trivumSetSource( nZoneId, strSource )
	if ((strSource == nil) or (strSource == "")) then return end
	if (strSource:sub(1,1) ~= "@") then strSource = "@" .. strSource end
	E:trace( "trivum: waehle Quelle " .. strSource .. " an Zone " .. tostring(math.floor(nZoneId)) )
	trivumGet( "/xml/zone/set.xml", "zone=@" .. tostring(math.floor(nZoneId)) .. "&source=" .. strSource )
end

-------------------------------------------------------------------------------
-- Multiroom / group management (trivum createGroup.xml)
-------------------------------------------------------------------------------
--
-- trivum groups are addressed as: /xml/zone/createGroup.xml?zone=A&oldgroup=B&members=+-+-
--   zone     = reference zone for this call
--   oldgroup = zone whose currently playing content the resulting group keeps
--   members  = one +/- character per trivum zone id 0..(ZONE_COUNT-1), marking
--              which zones end up in the group
--
-- ASSUMPTION (not fully spelled out in the trivum API doc): a zone's
-- <groupmaster> field is 255 when it is not following another zone (i.e. it
-- is standalone or itself the group's anchor), and equals another zone's id
-- when it is currently following that zone. This lets us rebuild "members"
-- from a fresh /xml/zone/getAll.xml snapshot without disturbing OTHER,
-- unrelated groups among the remaining zones. Please verify this holds for
-- your system when testing - if not, tell me what you observe and I will
-- adjust.

--- Fetch /xml/zone/getAll.xml once and return { [zoneId] = groupmasterId }.
-- @return table, boolean ok
local function trivumFetchGroups()
	local groups = {}
	local ok, data = trivumGet( "/xml/zone/getAll.xml", "" )
	if ((not ok) or (data == nil)) then return groups, false end
	for zoneBlock in data:gmatch( "<zone>(.-)</zone>" ) do
		local id = tonumber( xmlTag( zoneBlock, "id" ) )
		if (id ~= nil) then
			groups[id] = tonumber( xmlTag( zoneBlock, "groupmaster" ) ) or 255
		end
	end
	return groups, true
end

--- Fetch /xml/zone/getAll.xml and build a tab separated "ID<TAB>Name" list
-- (one zone per line, sorted by id) into STATUS.ZONES_LIST - a discovery
-- convenience so ZONE_ID/description can be looked up from within JVP
-- instead of the trivum web configuration, analogous to the "list inventory"
-- feature of the Hue V2 interface / STATUS.FUNCTIONS_JSON of the JUNGHOME
-- interface elsewhere in this project folder.
-- Uses only /xml/zone/getAll.xml (its <zone> blocks carry <id> and
-- <description> directly, no nested <source> block), so this cannot collide
-- with the per-zone <source><description> (currently playing title) handled
-- separately in pollZone().
local function trivumListZones()
	local ok, data = trivumGet( "/xml/zone/getAll.xml", "" )
	if ((not ok) or (data == nil)) then
		E:trace( "trivum: Zonenliste konnte nicht abgerufen werden" )
		return
	end

	local zones = {}
	for zoneBlock in data:gmatch( "<zone>(.-)</zone>" ) do
		local id = tonumber( xmlTag( zoneBlock, "id" ) )
		if (id ~= nil) then
			table.insert( zones, { id = id, description = xmlDecode( xmlTag( zoneBlock, "description" ) or "" ) } )
		end
	end
	table.sort( zones, function( a, b ) return a.id < b.id end )

	local lines = {}
	for _, z in ipairs( zones ) do
		lines[#lines + 1] = tostring(math.floor(z.id)) .. "\t" .. z.description
	end
	setVal( STATUS, "ZONES_LIST", table.concat( lines, "\n" ) )
	setVal( STATUS, "ZONES_LASTUPDATE", nowStr() )
	E:trace( "trivum: Zonenliste aktualisiert (" .. tostring(#zones) .. " Zone(n) gefunden)" )
end

--- Build the "members" bitmask for createGroup.xml across zone ids 0..(nZoneCount-1).
-- Zones already sharing nMasterId's group (or nMasterId itself) keep their
-- membership; nAddId (if given) is added, nRemoveId (if given) is removed.
-- @param groups table  result of trivumFetchGroups()
-- @param nZoneCount number
-- @param nMasterId number  the zone whose group is being modified
-- @param nAddId number|nil
-- @param nRemoveId number|nil
-- @return string
local function buildGroupMembers( groups, nZoneCount, nMasterId, nAddId, nRemoveId )
	local parts = {}
	for i = 0, nZoneCount - 1 do
		local inGroup = (i == nMasterId) or (groups[i] == nMasterId)
		if ((nAddId ~= nil) and (i == nAddId)) then inGroup = true end
		if ((nRemoveId ~= nil) and (i == nRemoveId)) then inGroup = false end
		parts[#parts + 1] = inGroup and "+" or "-"
	end
	return table.concat( parts )
end

--- Run createGroup.xml, preserving unrelated zones' existing grouping.
-- @param nCallZoneId number  "zone" parameter
-- @param nOldGroupId number  "oldgroup" parameter (whose content persists)
-- @param nAddId number|nil  zone to add to nOldGroupId's group
-- @param nRemoveId number|nil  zone to remove from nOldGroupId's group
local function trivumCreateGroup( nCallZoneId, nOldGroupId, nAddId, nRemoveId )
	local nZoneCount = math.floor( getNum( CONFIG, "ZONE_COUNT", 4 ) )
	local groups = trivumFetchGroups()
	local members = buildGroupMembers( groups, nZoneCount, nOldGroupId, nAddId, nRemoveId )
	E:trace( "trivum: Gruppierung zone=" .. tostring(math.floor(nCallZoneId)) ..
		" oldgroup=" .. tostring(math.floor(nOldGroupId)) .. " members=" .. members )
	trivumGet( "/xml/zone/createGroup.xml",
		"zone=" .. tostring(math.floor(nCallZoneId)) .. "&oldgroup=" .. tostring(math.floor(nOldGroupId)) ..
		"&members=" .. members )
end

--- Poll one zone's status and mirror it into the zone's datapoints, both the
-- combined Read/Write points and the dedicated *_RM feedback points.
-- Uses /xml/zone/get.xml (no Control Unit / visuid registration needed),
-- see trivum API doc "4.2 Single zone status".
-- @param oZone table  zone_t folder
local function pollZone( oZone )
	local zoneId = getNum( oZone, "ZONE_ID", -1 )
	if (zoneId < 0) then
		traceDebug( "trivum: Zonen-Instanz ohne gueltige ZONE_ID uebersprungen" )
		return
	end

	traceDebug( "trivum: Poll Zone " .. tostring(math.floor(zoneId)) )
	local ok, data = trivumGet( "/xml/zone/get.xml",
		"zone=@" .. tostring(math.floor(zoneId)) .. "&addSourceBasicData&addSourceStatusData" )
	if ((not ok) or (data == nil)) then return end

	-- zone power: the outer <status> holds only the literal text "on" / "off";
	-- the nested <source><status>...</status></source> block contains further
	-- tags, so a literal match here cannot collide with it.
	-- Nur die _RM Rueckmeldepunkte werden vom Poll aktualisiert. POWER/VOLUME
	-- (Sendetelegramm/Sollwert) werden ausschliesslich durch OnValueChange
	-- (eigene Bedienung + Ack) gesetzt, damit eine externe Aenderung (z.B. an
	-- der trivum Weboberflaeche) nicht den zuletzt gesendeten Sollwert ueberschreibt.
	if (data:find( "<status>on</status>", 1, true )) then
		setVal( oZone, "POWER_RM", 1 )
	elseif (data:find( "<status>off</status>", 1, true )) then
		setVal( oZone, "POWER_RM", 0 )
	end

	local volume = xmlTag( data, "volume" )
	if (volume ~= nil) then
		setVal( oZone, "VOLUME_RM", parseNum(volume) or 0 )
	end

	-- best-effort: mute is not shown in the documented get.xml example, so
	-- this stays unset unless trivum actually returns it.
	local mute = parseBoolish( xmlTag( data, "mute" ) )
	if (mute ~= nil) then setVal( oZone, "MUTE_RM", mute ) end

	-- best-effort: groupmaster is documented for getAll.xml, not explicitly
	-- for this per-zone get.xml call - fill it in if trivum returns it here too.
	local groupmaster = xmlTag( data, "groupmaster" )
	if (groupmaster ~= nil) then setVal( oZone, "GROUP_RM", parseNum(groupmaster) or 255 ) end

	-- scope description/artist/album/track/service/imageURL to the <source> block
	local sourceBlock = data:match( "<source>(.-)</source>" )
	if (sourceBlock ~= nil) then
		setVal( oZone, "SOURCE_DESC", xmlDecode( xmlTag( sourceBlock, "description" ) ) )
		setVal( oZone, "ARTIST",      xmlDecode( xmlTag( sourceBlock, "artist" ) ) )
		setVal( oZone, "ALBUM",       xmlDecode( xmlTag( sourceBlock, "album" ) ) )
		setVal( oZone, "TRACK",       xmlDecode( xmlTag( sourceBlock, "track" ) ) )
		setVal( oZone, "SERVICE",     xmlDecode( xmlTag( sourceBlock, "service" ) ) )
		setVal( oZone, "IMAGEURL",    normalizeImageUrl( xmlDecode( xmlTag( sourceBlock, "imageURL" ) ) ) )
	end

	traceDebug( "trivum: Zone " .. tostring(math.floor(zoneId)) .. " Status aktualisiert (Power=" ..
		getStr(oZone,"POWER_RM") .. ", Volume=" .. getStr(oZone,"VOLUME_RM") .. ", Quelle=" .. getStr(oZone,"SOURCE_DESC") .. ")" )
end

-------------------------------------------------------------------------------
-- Instance handling
-------------------------------------------------------------------------------

--- Build INSTANCETABLE / ZONELIST from all zone_t folders.
function CreateInstanceTable()
	INSTANCETABLE = {}
	ZONELIST = {}
	local list = E.PVTable["Zone"]
	if (list == nil) then return end
	for i, tbl in pairs( list ) do
		if (type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == "zone_t") then
			local name = getStr( tbl, "INSTANCE_NAME" )
			if (name == "") then name = "Zone " .. tostring(i) end
			INSTANCETABLE[name] = tbl
			table.insert( ZONELIST, tbl )
		end
	end
	g_nPollIndex = 1
	E:trace( "trivum: " .. tostring(#ZONELIST) .. " Zone(n) in der Konfiguration gefunden" )
end

-------------------------------------------------------------------------------
-- trivum Favorites
-------------------------------------------------------------------------------

local FAVORITES_MAX_SLOTS = 20   -- number of individual FAVORITE_<n> datapoints

--- Fetch the trivum favorites list, split by @f index into individual
-- FAVORITE_1 .. FAVORITE_20 datapoints, and also build the combined
-- FAVORITES_LIST text (kept for convenience/debug).
-- Confirmed reply format (2026-07-09, trivum V10.16 build 18261):
--   <rows><head>...<totalRecords>N</totalRecords>...</head>
--     <row><object>favorite</object><number>i</number><type>...</type>
--          <info1>Name (percent-encoded)</info1><info2>...</info2>
--          <coverart>...</coverart><service>...</service><source>Dienst</source>
--          <action>/xml/zone/set.xml?source=@fN</action></row>
--     ... <userdata name="rc">0</userdata> ...
--   </rows>
-- info1/info2/coverart use percent-encoding ("%20" = space), decoded via
-- urlDecode() - a different scheme than the zone status "_XX" escape.
local function trivumFetchFavorites()
	local ok, data = trivumGet( "/api/v1/trivum/favorite.xml", "" )
	if ((not ok) or (data == nil)) then
		E:trace( "trivum: Favoritenliste konnte nicht abgerufen werden" )
		return
	end

	setVal( FAV, "FAVORITES_RAW", data )
	setVal( FAV, "FAVORITES_LASTUPDATE", nowStr() )

	local lines = {}
	local slots = {}   -- [index] = "Name [Source]"
	for rowBlock in data:gmatch( "<row>(.-)</row>" ) do
		local action = xmlTag( rowBlock, "action" ) or ""
		local idxStr = action:match( "source=@f(%d+)" )
		if (idxStr ~= nil) then
			local name = urlDecode( xmlTag( rowBlock, "info1" ) or "" )
			local source = urlDecode( xmlTag( rowBlock, "source" ) or "" )
			local text = name
			if (source ~= "") then text = text .. " [" .. source .. "]" end
			lines[#lines + 1] = "@f" .. idxStr .. ": " .. text

			local idx = tonumber( idxStr )
			if ((idx ~= nil) and (idx >= 1) and (idx <= FAVORITES_MAX_SLOTS)) then
				slots[idx] = text
			end
		end
	end

	for i = 1, FAVORITES_MAX_SLOTS do
		setVal( FAV, "FAVORITE_" .. tostring(i), slots[i] or "" )
	end

	setVal( FAV, "FAVORITES_LIST", table.concat( lines, "\n" ) )
	setVal( FAV, "FAVORITES_COUNT", #lines )
	E:trace( "trivum: Favoritenliste aktualisiert (" .. tostring(#lines) .. " Favoriten, " ..
		tostring(FAVORITES_MAX_SLOTS) .. " Slots)" )
end

-------------------------------------------------------------------------------
-- JVP lifecycle
-------------------------------------------------------------------------------

function Init()
	E:trace( "---- trivum interface: Init ----" )
	CONFIG = E.PVTable["CONFIGURATION"]
	STATUS = E.PVTable["STATUS"]
	FAV    = E.PVTable["FAVORITES"]
	if (CONFIG == nil) then E:trace( "trivum: FEHLER - CONFIGURATION-Ordner nicht gefunden (InterfaceDescription.xml pruefen)" ) end
	if (STATUS == nil) then E:trace( "trivum: FEHLER - STATUS-Ordner nicht gefunden (InterfaceDescription.xml pruefen)" ) end
	if (FAV == nil) then E:trace( "trivum: FEHLER - FAVORITES-Ordner nicht gefunden (InterfaceDescription.xml pruefen)" ) end

	CreateInstanceTable()
	HTTP_RQ = E.ResourceTable["HTTP"]
	if (HTTP_RQ ~= nil) then
		HTTP_RQ:Open()
		E:trace( "trivum: HTTP Ressource geoeffnet" )
	else
		E:trace( "trivum: HTTP Ressource 'HTTP' nicht gefunden - RESOURCES in InterfaceDescription.xml pruefen" )
	end

	local host = getStr( CONFIG, "HOST" )
	if (host == "") then
		E:trace( "trivum: HOST ist nicht konfiguriert - bitte IP-Adresse in der Konfiguration eintragen" )
	else
		E:trace( "trivum: konfigurierter Host ist " .. host )
		trivumFetchFavorites()
	end
end

function Exit()
	E:trace( "---- trivum interface: Exit ----" )
	if (HTTP_RQ ~= nil) then HTTP_RQ:Close() end
end

function Poll()
	-- round robin: poll exactly one zone's status per tick, so the runtime is
	-- never blocked for (zone count * http timeout) within a single cycle.
	if (#ZONELIST == 0) then return end
	if (g_nPollIndex > #ZONELIST) then g_nPollIndex = 1 end
	pollZone( ZONELIST[g_nPollIndex] )
	g_nPollIndex = g_nPollIndex + 1
end

function OnValueRead( oVarPath, nReason )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessRead) and (a ~= constAccessReadWrite)) then return end

	-- Explizites "Lesen" im JVP-Geraete-Editor (nReason == constWriteReadCmd) zuerst
	-- live nachladen, statt nur den moeglicherweise veralteten Cache-Wert
	-- zurueckzugeben - sonst wirkt ein manuelles "Lesen" wirkungslos, wenn sich der
	-- Wert seit dem letzten Poll geaendert hat (Erkenntnis aus einem anderen
	-- JVP-Interface in diesem Projektordner: OnValueRead hatte nReason bisher
	-- komplett ignoriert).
	if (nReason == constWriteReadCmd) then
		local oZone = oVarPath:_findParentFromUserType( "zone_t" )
		if (oZone ~= nil) then
			pollZone( oZone )
		elseif (oVarPath:_findParentFromUserType( "favorites_t" ) ~= nil) then
			trivumFetchFavorites()
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

	-- Jede vom JVP eingehende Wertaenderung wird sofort bestaetigt (constWriteAck),
	-- bevor irgendeine weitere Pruefung erfolgt - so wird der Wert immer ins
	-- Prozessmodell/die Visualisierung uebernommen, unabhaengig von den
	-- Zugriffsrechten oder vom weiteren Verlauf dieser Funktion.
	if (strValue ~= nil) then
		v:SetValue( strValue, constWriteAck )
	end

	local a = v:GetAccessRights()
	if ((a ~= constAccessReadWrite) and (a ~= constAccessWrite)) then return end

	local name = v:GetScriptName()
	traceDebug( "trivum: OnValueChange " .. name .. " = " .. tostring(strValue) )

	-- global commands living in the STATUS folder (no zone_t parent)
	if (name == "ALL_OFF") then
		if (strValue == "1") then
			E:trace( "trivum: ALL_OFF ausgeloest" )
			trivumCommand( nil, 0, CMD_ALL_OFF )
			setVal( STATUS, "LAST_ALLOFF_TIME", nowStr() )
		end
		return
	end

	-- global command living in the CONFIGURATION folder (no zone_t parent)
	if (name == "LIST_ZONES") then
		if (strValue == "1") then trivumListZones() end
		return
	end

	-- global command living in the FAVORITES folder (no zone_t parent)
	if (name == "FAVORITES_REFRESH") then
		if (strValue == "1") then trivumFetchFavorites() end
		return
	end

	local oZone = oVarPath:_findParentFromUserType( "zone_t" )
	if (nil == oZone) then
		traceDebug( "trivum: " .. name .. " gehoert zu keiner Zonen-Instanz, ignoriert" )
		return
	end
	local zoneId = getNum( oZone, "ZONE_ID", -1 )
	if (zoneId < 0) then
		E:trace( "trivum: Zone ohne gueltige ZONE_ID - Schreibvorgang " .. name .. " ignoriert" )
		return
	end

	if (name == "POWER") then
		trivumCommand( oZone, zoneId, (strValue == "1") and CMD_POWER_ON or CMD_POWER_OFF )
	elseif (name == "MUTE") then
		trivumCommand( oZone, zoneId, (strValue == "1") and CMD_MUTE_ON or CMD_MUTE_OFF )
	elseif (name == "VOLUME") then
		local n = parseNum(strValue)
		if (n ~= nil) then trivumSet( zoneId, "volume", math.floor(n) ) end
	elseif (name == "SOURCE") then
		trivumSetSource( zoneId, strValue )
	elseif (name == "COMMAND") then
		local n = parseNum(strValue)
		if (n ~= nil) then trivumCommand( oZone, zoneId, math.floor(n) ) end
	elseif (name == "PLAY") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_PLAY ) end
	elseif (name == "PAUSE") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_PAUSE ) end
	elseif (name == "STOP") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_STOP ) end
	elseif (name == "PLAYPAUSE") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_PLAYPAUSE ) end
	elseif (name == "NEXT") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_NEXT ) end
	elseif (name == "PREVIOUS") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_PREVIOUS ) end
	elseif (name == "JOIN") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_JOIN ) end
	elseif (name == "UNJOIN") then
		if (strValue == "1") then trivumCommand( oZone, zoneId, CMD_UNJOIN ) end
	elseif (name == "GROUP_TAKE_FROM") then
		-- "Hole dir die Musik aus Kanal X": diese Zone tritt der Gruppe von
		-- Zone X bei, X's Musik bleibt massgeblich.
		local n = parseNum(strValue)
		if (n ~= nil) then
			local targetId = math.floor(n)
			trivumCreateGroup( zoneId, targetId, zoneId, nil )
		end
	elseif (name == "GROUP_SEND_TO") then
		-- "Uebertrage die Musik auch auf Kanal X": Zone X tritt der Gruppe
		-- dieser Zone bei, diese Zone's Musik bleibt massgeblich.
		local n = parseNum(strValue)
		if (n ~= nil) then
			local targetId = math.floor(n)
			trivumCreateGroup( targetId, zoneId, targetId, nil )
		end
	elseif (name == "GROUP_LEAVE") then
		if (strValue == "1") then
			-- diese Zone aus ihrer aktuellen Gruppe entfernen; falls sie
			-- gerade eigenstaendig ist (kein Master bekannt), ist das ein No-Op.
			local groups = trivumFetchGroups()
			local master = groups[zoneId]
			if ((master ~= nil) and (master ~= 255) and (master ~= zoneId)) then
				trivumCreateGroup( zoneId, master, nil, zoneId )
			else
				trivumCreateGroup( zoneId, zoneId, nil, zoneId )
			end
		end
	end
end
