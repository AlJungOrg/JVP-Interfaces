-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script PhilipsHueV2Interface
--
-- JUNG Visu Pro (JVP) Prozessanschluss fuer eine Philips Hue Bridge ueber die
-- CLIP v2 API (Lampen/Raeume&Zonen/Szenen/Sensoren/Automationen sowie optional
-- Anwesenheit/Geofencing). Ersetzt den aelteren CLIP-v1-Anschluss ("Philips
-- Hue"/"PhilipsHue") und nutzt drei neue JVP-Plattformfunktionen:
--
--  1. SSE-EVENTSTREAM (HTTP-Ressource StartStream/ReadStream/StopStream/
--     IsStreaming/GetStreamResult): Anstelle von wiederholtem Polling meldet
--     die Bridge Zustandsaenderungen in Echtzeit ueber einen dauerhaften
--     Server-Sent-Events-Stream (https://<Bridge-IP>/eventstream/clip/v2).
--     Es gibt daher - anders als beim CLIP-v1-Anschluss - KEIN eigenes
--     Polling-Intervall je Lampe mehr; alle Instanzen werden ueber genau
--     diesen einen Stream aktuell gehalten (siehe driveEventStream()).
--  2. EIN SCRIPT FUER DEUTSCH UND ENGLISCH: InterfaceDescription.xml haelt
--     alle sichtbaren Texte zweisprachig (Attribute mit _DE/_EN-Suffix) in
--     EINER Datei - dieses Lua-Script ist sprachunabhaengig und muss (anders
--     als beim v1-Anschluss mit zwei getrennten Ordnern "HueInterface" und
--     "philips hue") nur noch einmal gepflegt werden.
--  3. E:SetFolderName(folderGuid, strName): Der von der Bridge gemeldete Name
--     (Lampe/Raum/Zone/Szene/Automation, bzw. bei Sensoren der Name des
--     zugehoerigen Geraets) wird nicht mehr nur in einen Text-Datenpunkt
--     geschrieben, sondern zusaetzlich direkt in den Ordnernamen der
--     jeweiligen Instanz uebernommen (siehe renameFolderIfNeeded()) - die
--     Baumstruktur im Editor zeigt dadurch von selbst sprechende Namen statt
--     "Lampe 1", "Lampe 2", ... E:SaveProject() wird dabei bewusst nur
--     gesammelt EINMAL je Sync-Durchgang aufgerufen (g_dirtyNames), nicht pro
--     einzelner Umbenennung.
--
-- CLIP v2 lauft ausschliesslich ueber HTTPS mit einem selbstsignierten
-- Bridge-Zertifikat (anders als CLIP v1, das auch reines HTTP erlaubte) - das
-- betrifft jetzt saemtliche Anfragen dieses Anschlusses, nicht nur die
-- optionale Anwesenheitsabfrage wie beim v1-Anschluss. Falls die JVP-HTTP-
-- Ressource das Zertifikat nicht akzeptiert, siehe Fehlerbehebung in der
-- Anleitung.
--
-- WICHTIGER HINWEIS ZUR HTTP-RESSOURCE:
-- Der HTTP-Request-Typ ist NUMERISCH kodiert: 0=GET, 1=POST, 2=PUT, 3=DELETE.
-- Diese Zahlen werden direkt als "method" an SendRequest() uebergeben.
--
-- Alle Datenpunkt-SCRIPTNAMEs sind ueber das gesamte Interface hinweg
-- eindeutig (Praefix pro Instanztyp: LIGHT_/GROUP_/SCENE_/SENSOR_/AUTOMATION_).
--
-- SENDE-/EMPFANGSDATENPUNKTE: Steuerbare Werte (Ein/Aus, Helligkeit, Farbe, ...)
-- sind in je zwei Datenpunkte aufgeteilt: "*_CMD" (Write, Sendedatenpunkt) und
-- der Basisname ohne Suffix (Read, Empfangsdatenpunkt/Rueckmeldung). Jeder
-- eingehende Schreibzugriff wird in OnValueChange() sofort mit constWriteAck
-- quittiert; die apply*-Funktionen schreiben Rueckmeldungen dagegen mit
-- constValueChange (siehe setVal()).
--
-- RESSOURCEN-CACHE: RES_BY_ID haelt den zuletzt bekannten Zustand JEDER
-- Bridge-Ressource (Lampen, Geraete, Raeume/Zonen, grouped_light-Services,
-- Szenen, Sensor-Services, device_power, zigbee_connectivity,
-- behavior_instance, geofence_client, ...) - gefuellt einmalig durch FullSync()
-- (ein einziger Bulk-GET auf /clip/v2/resource, siehe unten) und danach
-- laufend per Eventstream aktualisiert (applySseFragment() mischt nur die
-- geaenderten Felder eines Events in den bestehenden Cache-Eintrag). Die
-- apply*-Funktionen fuer eine JVP-Instanz lesen ausschliesslich aus diesem
-- Cache - derselbe Code-Pfad wird sowohl fuer den initialen Vollabgleich als
-- auch fuer jedes einzelne Eventstream-Update verwendet.
--
-- LOGGING (kommerzieller Betrieb): traceMsg() ersetzt E:trace() und schreibt
-- jede Meldung zusaetzlich (mit Uhrzeit) in den rollierenden STATUS.DEBUG_LOG
-- Datenpunkt. Bewusst NICHT protokolliert werden einzelne HTTP-Anfragen oder
-- einzelne Eventstream-Events - das waere im Dauerbetrieb zu viel Rauschen.
-- CONFIGURATION.CLEAR_DEBUG_LOG (auf 1 setzen) leert das Log wieder.
--
-- Target runtime: Lua 5.1.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"
json = require "json"

mg_nPollSeconds = 0.2              -- keep in sync with INFO POLLTIME (200 ms)
local MAX_DEBUG_LOG_LEN  = 4000    -- Zeichen-Budget fuer STATUS.DEBUG_LOG
local MAX_INVENTORY_LEN  = 6000    -- Zeichen-Budget PRO Inventar-Kategorie
local SSE_RETRY_SECONDS  = 5       -- Wartezeit vor einem erneuten StartStream-Versuch

CFG     = nil                      -- CONFIGURATION-Ordner (gesetzt in Init)
STATUS  = nil                      -- STATUS-Ordner (gesetzt in Init)
HTTP_RQ = nil                      -- HTTP-Ressource fuer normale Requests (GET/PUT/POST), gesetzt in Init
HTTP_EVENTS = nil                  -- EIGENE HTTP-Ressource nur fuer den SSE-Eventstream, gesetzt in Init
                                    -- (bewusst getrennt von HTTP_RQ: Open()/SendRequest()/Close() eines
                                    -- normalen Requests auf DERSELBEN HTTP-Ressource wuerde eine dort
                                    -- gleichzeitig offene Streaming-Verbindung stoeren/abbrechen - siehe
                                    -- INTERFACEDESCRIPTION.XML, RESOURCES, zweite HTTP-Ressource "HTTP_EVENTS")

LIGHTTABLE      = {}               -- Hue Light-ID (v2)              -> Light-Instanzordner
GROUPTABLE      = {}               -- Hue Room/Zone-ID (v2)          -> Group-Instanzordner
SCENETABLE      = {}               -- Hue Scene-ID (v2)              -> Scene-Instanzordner
SENSORTABLE     = {}               -- Hue Sensor-Service-ID (v2)     -> Sensor-Instanzordner
AUTOMATIONTABLE = {}               -- Hue behavior_instance-ID (v2)  -> Automation-Instanzordner

RES_BY_ID              = {}        -- v2-Ressourcen-ID -> Ressourcen-Tabelle (Live-Cache)
GROUPEDLIGHT_OF_GROUP   = {}        -- Room/Zone-ID -> zugehoerige grouped_light-ID
NAME_OF_DEVICE          = {}        -- Device-ID -> metadata.name
BATTERY_OF_DEVICE       = {}        -- Device-ID -> device_power-Ressourcen-ID
ZIGBEE_OF_DEVICE        = {}        -- Device-ID -> zigbee_connectivity-Ressourcen-ID
GROUP_INST_BY_GROUPEDLIGHT = {}     -- grouped_light-ID -> Group-Instanzordner
BATTERY_WATCHERS        = {}        -- Device-ID -> Liste von Sensor-Instanzordnern
ZIGBEE_WATCHERS         = {}        -- Device-ID -> Liste von Light-Instanzordnern
DEVICENAME_WATCHERS     = {}        -- Device-ID -> Liste von Sensor-Instanzordnern

g_pairing               = false     -- true waehrend eines offenen Pairing-Zeitfensters
g_pairingDeadline       = 0         -- os.time(), bis zu dem das Pairing-Fenster offen ist
g_lastPairingAttempt    = 0         -- os.time() des letzten Pairing-POSTs (Drosselung)
g_lastPresent           = nil       -- vorheriger ANY_PRESENT-Zustand, fuer Wechsel-Tracing
g_lastAutoDiscoverAttempt = 0       -- os.time() des letzten discovery.meethue.com-Versuchs
g_sseBuffer             = ""        -- Zwischenspeicher fuer unvollstaendige SSE-Events
g_lastEventId           = nil       -- letzte per "id:" gemeldete Event-ID (fuer Last-Event-ID)
g_streamRetryAt         = 0         -- os.time(), ab dem der naechste StartStream-Versuch erlaubt ist
g_streamGotData         = false     -- true, sobald der aktuelle Stream mind. 1x Daten lieferte
g_streamConnectedLogged = false     -- true, sobald fuer die aktuelle Verbindung schon die
                                     -- "Eventstream verbunden"-Meldung geloggt wurde
g_dirtyNames            = false     -- true, wenn seit dem letzten SaveProject() umbenannt wurde
g_lastFolderName        = {}        -- e_guid -> zuletzt per SetFolderName gesetzter Name (nur RAM)

-------------------------------------------------------------------------------
-- Allgemeine Hilfsfunktionen
-------------------------------------------------------------------------------

local function round( x )
	return math.floor( x + 0.5 )
end

local function clamp( x, lo, hi )
	if (x < lo) then return lo end
	if (x > hi) then return hi end
	return x
end

--- Datenpunkt als Zahl lesen, tolerant gegenueber deutschem Komma.
local function getNum( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return 0 end
	local s = oNode[strName]:GetValue()
	if (s == nil) then return 0 end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	return tonumber( (s:match( "[-+]?%d+%.?%d*" )) ) or 0
end

--- Rohtext (z.B. strValue aus OnValueChange) tolerant als Zahl parsen.
local function parseNum( s )
	if (s == nil) then return nil end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	return tonumber( (s:match( "[-+]?%d+%.?%d*" )) )
end

--- Datenpunkt als Text lesen ("" falls nicht vorhanden).
local function getStr( oNode, strName )
	if ((oNode == nil) or (oNode[strName] == nil)) then return "" end
	return oNode[strName]:GetValue() or ""
end

--- Datenpunkt schreiben (gegen fehlende Knoten abgesichert).
local function setVal( oNode, strName, value )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		oNode[strName]:SetValue( tostring(value), constValueChange )
	end
end

--- Aktuelle Zeit als Text im Projektformat.
local function nowStr()
	return os.date( "%d.%m.%Y %H:%M:%S", os.time() )
end

--- Eintraege einer Hash-Tabelle (Hue-ID -> Instanzordner) zaehlen.
local function tblCount( t )
	local n = 0
	for _ in pairs( t ) do n = n + 1 end
	return n
end

--- Ins JVP-Log UND zusaetzlich in den rollierenden STATUS.DEBUG_LOG
-- Datenpunkt schreiben (zeitgestempelt, aelteste Zeilen werden ab
-- MAX_DEBUG_LOG_LEN verworfen).
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

--- UTF-8-Namen von der Bridge (z.B. mit Umlauten) fuer JVP-PVSTRINGs
-- entschaerfen. Faellt auf den Rohtext zurueck, falls ConvertUTF8ToASCII()
-- nicht verfuegbar ist oder einen Fehler wirft.
local function fixName( raw )
	if (raw == nil) then return "" end
	if (HTTP_RQ == nil) then return raw end
	local ok, converted = pcall( function() return HTTP_RQ:ConvertUTF8ToASCII( raw ) end )
	if (ok and (converted ~= nil)) then return converted end
	return raw
end

--- Ordnernamen einer Instanz auf `newName` setzen - aber nur, wenn er sich
-- gegenueber dem zuletzt (in dieser Laufzeit) gesetzten Namen aendert, und
-- ohne selbst SaveProject() aufzurufen (siehe g_dirtyNames / FullSync() /
-- applySseFragment(), die das gesammelt am Ende eines Sync-Durchgangs tun -
-- "trigger it after a meaningful, persistent change... never on every Poll").
local function renameFolderIfNeeded( oInst, newName )
	if (oInst == nil) or (newName == nil) or (newName == "") then return end
	local guid = oInst.e_guid
	if (guid == nil) then return end
	if (g_lastFolderName[guid] == newName) then return end
	local ok = pcall( function() E:SetFolderName( guid, newName ) end )
	if (ok) then
		g_lastFolderName[guid] = newName
		g_dirtyNames = true
	end
end

-------------------------------------------------------------------------------
-- Werteumrechnung: JVP-Datenpunkte (%, Kelvin, Grad) <-> Hue CLIP v2
-------------------------------------------------------------------------------

local function kelvinToMirek( k )
	k = clamp( k or 2700, 2000, 6500 )
	return clamp( round( 1000000 / k ), 153, 500 )
end

local function mirekToKelvin( m )
	m = clamp( m or 366, 153, 500 )
	return round( 1000000 / m )
end

-- Standard-Farbraum "Gamut C" (die meisten aktuellen Hue-Vollfarbenlampen).
-- Fuer die Umrechnung Farbton/Saettigung <-> xy wird bewusst dieser feste
-- Farbraum verwendet statt des individuellen Gamuts jeder einzelnen Lampe
-- (color.gamut aus der Bridge-Antwort) - der Unterschied ist fuer eine
-- Hausautomation praktisch nicht wahrnehmbar, macht die Umrechnung aber
-- deutlich einfacher.
local GAMUT_C_R = { 0.6915, 0.3038 }
local GAMUT_C_G = { 0.1700, 0.7000 }
local GAMUT_C_B = { 0.1532, 0.0475 }

local function closestPointOnSegment( ax, ay, bx, by, px, py )
	local abx, aby = bx - ax, by - ay
	local t = ((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby)
	t = clamp( t, 0, 1 )
	return ax + t * abx, ay + t * aby
end

local function crossSign( ax, ay, bx, by, px, py )
	return (bx - ax) * (py - ay) - (by - ay) * (px - ax)
end

--- Einen xy-Punkt in das Gamut-C-Dreieck projizieren, falls er ausserhalb liegt.
local function clampToGamutC( x, y )
	local R, G, B = GAMUT_C_R, GAMUT_C_G, GAMUT_C_B
	local d1 = crossSign( R[1], R[2], G[1], G[2], x, y )
	local d2 = crossSign( G[1], G[2], B[1], B[2], x, y )
	local d3 = crossSign( B[1], B[2], R[1], R[2], x, y )
	local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
	local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
	if (not (hasNeg and hasPos)) then return x, y end -- bereits innerhalb

	local cx1, cy1 = closestPointOnSegment( R[1], R[2], G[1], G[2], x, y )
	local cx2, cy2 = closestPointOnSegment( G[1], G[2], B[1], B[2], x, y )
	local cx3, cy3 = closestPointOnSegment( B[1], B[2], R[1], R[2], x, y )
	local function dist2( px, py ) return (px - x) ^ 2 + (py - y) ^ 2 end
	local bestX, bestY, best = cx1, cy1, dist2( cx1, cy1 )
	local d = dist2( cx2, cy2 ); if (d < best) then bestX, bestY, best = cx2, cy2, d end
	d = dist2( cx3, cy3 ); if (d < best) then bestX, bestY, best = cx3, cy3, d end
	return bestX, bestY
end

--- Helligkeit/Farbton/Saettigung (h in Grad, s in %, v=1) -> CIE-xy-Koordinaten.
local function hsvToXy( h, s )
	h = (h or 0) % 360
	s = clamp( s or 0, 0, 100 ) / 100

	local c = s
	local xComp = c * (1 - math.abs( ((h / 60) % 2) - 1 ))
	local m = 1 - c
	local r, g, b
	if (h < 60) then r, g, b = c, xComp, 0
	elseif (h < 120) then r, g, b = xComp, c, 0
	elseif (h < 180) then r, g, b = 0, c, xComp
	elseif (h < 240) then r, g, b = 0, xComp, c
	elseif (h < 300) then r, g, b = xComp, 0, c
	else r, g, b = c, 0, xComp end
	r, g, b = r + m, g + m, b + m

	local function gamma( v )
		if (v > 0.04045) then return ((v + 0.055) / 1.055) ^ 2.4 end
		return v / 12.92
	end
	r, g, b = gamma(r), gamma(g), gamma(b)

	local X = r * 0.664511 + g * 0.154324 + b * 0.162028
	local Y = r * 0.283881 + g * 0.668433 + b * 0.047685
	local Z = r * 0.000088 + g * 0.072310 + b * 0.986039
	local sum = X + Y + Z
	if (sum <= 0) then return 0.3127, 0.3290 end -- D65-Weisspunkt als Fallback
	return clampToGamutC( X / sum, Y / sum )
end

--- CIE-xy-Koordinaten -> Farbton (Grad) / Saettigung (%). Helligkeit wird
-- ignoriert (v=1) - die Helligkeit hat in JVP einen eigenen Datenpunkt.
local function xyToHs( x, y )
	x = x or 0.3127
	y = y or 0.3290
	if (y <= 0) then y = 0.0001 end

	local X = x / y
	local Z = (1 - x - y) / y
	local r =  X * 1.656492 - 1 * 0.354851 - Z * 0.255038
	local g = -X * 0.707196 + 1 * 1.655397 + Z * 0.036152
	local b =  X * 0.051713 - 1 * 0.121364 + Z * 1.011530

	local function degamma( v )
		if (v <= 0.0031308) then return 12.92 * v end
		return 1.055 * (v ^ (1 / 2.4)) - 0.055
	end
	r, g, b = degamma(r), degamma(g), degamma(b)

	local maxc = math.max( r, g, b, 0.0001 )
	r, g, b = clamp( r / maxc, 0, 1 ), clamp( g / maxc, 0, 1 ), clamp( b / maxc, 0, 1 )

	local mx, mn = math.max( r, g, b ), math.min( r, g, b )
	local delta = mx - mn
	local h = 0
	if (delta > 0.00001) then
		if (mx == r) then h = 60 * (((g - b) / delta) % 6)
		elseif (mx == g) then h = 60 * (((b - r) / delta) + 2)
		else h = 60 * (((r - g) / delta) + 4) end
	end
	if (h < 0) then h = h + 360 end
	local s = 0
	if (mx > 0) then s = delta / mx end
	return h, s * 100
end

-------------------------------------------------------------------------------
-- HTTP / Hue CLIP v2 API (ausschliesslich HTTPS)
-------------------------------------------------------------------------------

--- Eine HTTP-Anfrage an die Bridge ausfuehren und die JSON-Antwort dekodieren.
-- @param method number  0=GET, 1=POST, 2=PUT, 3=DELETE
-- @param path string  URL-Pfad, z.B. "/clip/v2/resource/light/<id>"
-- @param bodyTable table|nil  Lua-Tabelle, die als JSON-Body kodiert wird
-- @param useAppKeyHeader boolean  true, um den "hue-application-key"-Header zu senden
-- @return table|nil dekodierte Antwort, string|nil Fehler
local function httpRequest( method, path, bodyTable, useAppKeyHeader )
	if (HTTP_RQ == nil) then
		traceMsg( "FEHLER - E.ResourceTable[\"HTTP\"] ist nil" )
		return nil, "HTTP-Ressource nicht initialisiert"
	end
	local host = getStr( CFG, "BRIDGE_IP" )
	if (host == "") then
		return nil, "Keine Bridge-IP konfiguriert"
	end

	local url = "https://" .. host .. path
	local body = ""
	if (bodyTable ~= nil) then body = json.encode( bodyTable ) end

	local pOk, pErr
	pOk, pErr = pcall( function() HTTP_RQ:SetURL( url ) end )
	if (not pOk) then
		traceMsg( "FEHLER SetURL (" .. path .. "): " .. tostring(pErr) )
		return nil, "SetURL fehlgeschlagen"
	end

	pcall( function() HTTP_RQ:RemoveHeaders() end )
	pcall( function() HTTP_RQ:AddHeader( "Content-Type: application/json" ) end )
	if (useAppKeyHeader) then
		pcall( function() HTTP_RQ:AddHeader( "hue-application-key: " .. getStr( CFG, "API_KEY" ) ) end )
	end

	pOk, pErr = pcall( function() HTTP_RQ:Open() end )
	if (not pOk) then
		traceMsg( "FEHLER Open (" .. path .. "): " .. tostring(pErr) )
		return nil, "Open fehlgeschlagen"
	end

	pOk, pErr = pcall( function() HTTP_RQ:SendRequest( method, body ) end )
	if (not pOk) then
		traceMsg( "FEHLER SendRequest (" .. path .. "): " .. tostring(pErr) )
		pcall( function() HTTP_RQ:Close() end )
		return nil, "SendRequest fehlgeschlagen"
	end

	local rxOk, returnCode, err, httpStatus, data = pcall( function() return HTTP_RQ:GetRxData() end )
	if (not rxOk) then
		traceMsg( "FEHLER GetRxData (" .. path .. "): " .. tostring(returnCode) )
		pcall( function() HTTP_RQ:Close() end )
		return nil, "GetRxData fehlgeschlagen"
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
		return nil, "Leere Antwort"
	end

	local jOk, decoded = pcall( json.decode, data )
	if (not jOk) then
		traceMsg( "JSON-Fehler bei " .. path .. ": " .. tostring(decoded) )
		return nil, "JSON-Fehler"
	end
	return decoded, nil
end

--- CLIP v2 GET: entpackt die {"errors":[...],"data":[...]}-Huelle.
-- @return table|nil data-Array, string|nil Fehler
local function clipGet( path )
	local resp, err = httpRequest( 0, path, nil, true )
	if (resp == nil) then return nil, err end
	if (type(resp.errors) == "table") and (resp.errors[1] ~= nil) then
		local e = resp.errors[1]
		return nil, tostring( (type(e) == "table") and e.description or e )
	end
	return resp.data, nil
end

--- CLIP v2 PUT: Kommando senden, {"errors":...}-Huelle auswerten.
-- @return boolean Erfolg, string|nil Fehler
local function clipPut( path, bodyTable )
	local resp, err = httpRequest( 2, path, bodyTable, true )
	if (resp == nil) then return false, err end
	if (type(resp.errors) == "table") and (resp.errors[1] ~= nil) then
		local e = resp.errors[1]
		traceMsg( "Hue-Fehler bei " .. path .. ": " .. tostring( (type(e) == "table") and e.description or e ) )
		return false, tostring( (type(e) == "table") and e.description or e )
	end
	return true, nil
end

-------------------------------------------------------------------------------
-- Automatische Bridge-Erkennung (Fallback bei geaenderter Bridge-IP)
-------------------------------------------------------------------------------

local DISCOVERY_URL              = "https://discovery.meethue.com/"
local AUTO_DISCOVER_MIN_INTERVAL = 300  -- Sekunden zwischen zwei Erkennungsversuchen

--- Fragt Philips' Cloud-Discovery-Dienst nach der aktuellen Bridge-IP und
-- uebernimmt sie in CONFIGURATION.BRIDGE_IP, falls sie sich geaendert hat.
-- Nur aktiv, wenn CONFIGURATION.AUTO_DISCOVER_IP eingeschaltet ist.
-- @return boolean true, wenn eine neue IP uebernommen wurde
local function tryAutoDiscoverBridgeIp()
	if (getStr( CFG, "AUTO_DISCOVER_IP" ) ~= "1") then return false end
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
		traceMsg( "Automatische Bridge-Erkennung fehlgeschlagen - keine Antwort" )
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
	g_streamRetryAt = 0
	if (HTTP_EVENTS ~= nil) then pcall( function() HTTP_EVENTS:StopStream() end ) end
	return true
end

-------------------------------------------------------------------------------
-- Instanztabellen (Multiple-Ordner -> Hue-ID)
-------------------------------------------------------------------------------

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

--- Alle Hue-ID -> Instanzordner-Tabellen neu aufbauen. Guenstig; wird bei
-- jedem Poll() aufgerufen, damit neu eingetragene *_HUE_ID-Werte sofort wirken.
function RebuildInstanceTables()
	LIGHTTABLE      = buildTable( "LIGHTS_ROOT",      "Light",      "light_t",      "LIGHT_HUE_ID" )
	GROUPTABLE      = buildTable( "GROUPS_ROOT",      "Group",      "group_t",      "GROUP_HUE_ID" )
	SCENETABLE      = buildTable( "SCENES_ROOT",      "Scene",      "scene_t",      "SCENE_HUE_ID" )
	SENSORTABLE     = buildTable( "SENSORS_ROOT",     "Sensor",     "sensor_t",     "SENSOR_HUE_ID" )
	AUTOMATIONTABLE = buildTable( "AUTOMATIONS_ROOT", "Automation", "automation_t", "AUTOMATION_HUE_ID" )
end

-------------------------------------------------------------------------------
-- Ressourcen-Cache: /clip/v2/resource -> RES_BY_ID + abgeleitete Zuordnungen
-------------------------------------------------------------------------------

--- Baut RES_BY_ID (ID -> Ressource) und die abgeleiteten Zuordnungen
-- (Device-Name, Battery-/Zigbee-Service je Device, grouped_light je Room/Zone)
-- komplett neu auf, aus dem data-Array eines GET /clip/v2/resource.
local function rebuildDerivedMaps( dataList )
	RES_BY_ID            = {}
	GROUPEDLIGHT_OF_GROUP = {}
	NAME_OF_DEVICE        = {}
	BATTERY_OF_DEVICE     = {}
	ZIGBEE_OF_DEVICE      = {}

	for _, res in pairs( dataList ) do
		if (type(res) == "table") and (res.id ~= nil) then
			RES_BY_ID[res.id] = res
		end
	end

	for id, res in pairs( RES_BY_ID ) do
		local t = res.type
		if (t == "device") then
			local md = res.metadata or {}
			NAME_OF_DEVICE[id] = fixName( md.name or "" )
		elseif ((t == "room") or (t == "zone")) then
			for _, svc in pairs( res.services or {} ) do
				if (type(svc) == "table") and (svc.rtype == "grouped_light") and (svc.rid ~= nil) then
					GROUPEDLIGHT_OF_GROUP[id] = svc.rid
				end
			end
		elseif (t == "device_power") then
			if (type(res.owner) == "table") and (res.owner.rid ~= nil) then
				BATTERY_OF_DEVICE[res.owner.rid] = id
			end
		elseif (t == "zigbee_connectivity") then
			if (type(res.owner) == "table") and (res.owner.rid ~= nil) then
				ZIGBEE_OF_DEVICE[res.owner.rid] = id
			end
		end
	end
end

--- Reverse-Lookup-Tabellen fuer Eventstream-Updates aufbauen: welche
-- JVP-Instanz(en) haengen an welchem Device (fuer Battery-/Zigbee-/
-- Umbenennungs-Events) bzw. an welchem grouped_light-Service.
local function rebuildWatchers()
	BATTERY_WATCHERS           = {}
	ZIGBEE_WATCHERS            = {}
	DEVICENAME_WATCHERS        = {}
	GROUP_INST_BY_GROUPEDLIGHT = {}

	for id, oInst in pairs( LIGHTTABLE ) do
		local res = RES_BY_ID[id]
		if (res ~= nil) and (type(res.owner) == "table") and (res.owner.rid ~= nil) then
			local devId = res.owner.rid
			ZIGBEE_WATCHERS[devId] = ZIGBEE_WATCHERS[devId] or {}
			table.insert( ZIGBEE_WATCHERS[devId], oInst )
		end
	end
	for id, oInst in pairs( SENSORTABLE ) do
		local res = RES_BY_ID[id]
		if (res ~= nil) and (type(res.owner) == "table") and (res.owner.rid ~= nil) then
			local devId = res.owner.rid
			BATTERY_WATCHERS[devId] = BATTERY_WATCHERS[devId] or {}
			table.insert( BATTERY_WATCHERS[devId], oInst )
			DEVICENAME_WATCHERS[devId] = DEVICENAME_WATCHERS[devId] or {}
			table.insert( DEVICENAME_WATCHERS[devId], oInst )
		end
	end
	for id, oInst in pairs( GROUPTABLE ) do
		local glId = GROUPEDLIGHT_OF_GROUP[id]
		if (glId ~= nil) then
			GROUP_INST_BY_GROUPEDLIGHT[glId] = oInst
		end
	end
end

-------------------------------------------------------------------------------
-- Cache -> JVP-Instanz ("apply*"). Wird sowohl von FullSync() als auch von
-- applySseFragment() (fuer einzelne Eventstream-Updates) verwendet - EIN
-- Code-Pfad fuer Vollabgleich und Live-Update.
-------------------------------------------------------------------------------

local function applyOneLight( oInst )
	local id = getStr( oInst, "LIGHT_HUE_ID" )
	if (id == "") then return end
	local res = RES_BY_ID[id]
	if (res == nil) then return end

	local name = fixName( (res.metadata or {}).name or "" )
	setVal( oInst, "LIGHT_NAME", name )
	renameFolderIfNeeded( oInst, name )

	setVal( oInst, "LIGHT_ON", ((res.on or {}).on == true) and 1 or 0 )

	local dim = res.dimming
	if (type(dim) == "table") and (dim.brightness ~= nil) then
		setVal( oInst, "LIGHT_BRIGHTNESS", clamp( round(dim.brightness), 0, 100 ) )
	end

	local ct = res.color_temperature
	if (type(ct) == "table") and (ct.mirek ~= nil) then
		setVal( oInst, "LIGHT_COLORTEMP", mirekToKelvin(ct.mirek) )
	end

	local col = res.color
	if (type(col) == "table") and (type(col.xy) == "table") then
		local h, s = xyToHs( col.xy.x, col.xy.y )
		setVal( oInst, "LIGHT_HUEANGLE", round(h) )
		setVal( oInst, "LIGHT_SATURATION", round(s) )
	end

	if (type(res.owner) == "table") then
		local zigId = ZIGBEE_OF_DEVICE[res.owner.rid]
		local zigRes = (zigId ~= nil) and RES_BY_ID[zigId] or nil
		if (zigRes ~= nil) and (zigRes.status ~= nil) then
			setVal( oInst, "LIGHT_REACHABLE", (zigRes.status == "connected") and 1 or 0 )
		end
	end

	setVal( oInst, "LIGHT_LASTUPDATE", nowStr() )
end

local function applyOneGroup( oInst )
	local id = getStr( oInst, "GROUP_HUE_ID" )
	if (id == "") then return end
	local res = RES_BY_ID[id]
	if (res == nil) then return end

	local name = fixName( (res.metadata or {}).name or "" )
	setVal( oInst, "GROUP_NAME", name )
	renameFolderIfNeeded( oInst, name )

	local glId = GROUPEDLIGHT_OF_GROUP[id]
	if (glId ~= nil) then
		setVal( oInst, "GROUP_GROUPEDLIGHT_ID", glId )
		local glRes = RES_BY_ID[glId]
		if (glRes ~= nil) then
			setVal( oInst, "GROUP_ON", ((glRes.on or {}).on == true) and 1 or 0 )
			local dim = glRes.dimming
			if (type(dim) == "table") and (dim.brightness ~= nil) then
				setVal( oInst, "GROUP_BRIGHTNESS", clamp( round(dim.brightness), 0, 100 ) )
			end
		end
	end
end

local function applyOneScene( oInst )
	local id = getStr( oInst, "SCENE_HUE_ID" )
	if (id == "") then return end
	local res = RES_BY_ID[id]
	if (res == nil) then return end

	local name = fixName( (res.metadata or {}).name or "" )
	setVal( oInst, "SCENE_NAME", name )
	renameFolderIfNeeded( oInst, name )

	local groupName = ""
	if (type(res.group) == "table") and (res.group.rid ~= nil) then
		local groupRes = RES_BY_ID[res.group.rid]
		if (groupRes ~= nil) and (type(groupRes.metadata) == "table") then
			groupName = fixName( groupRes.metadata.name or "" )
		end
	end
	setVal( oInst, "SCENE_GROUP_NAME", groupName )
end

--- Interpretiert eine v2-Sensor-Service-Ressource abhaengig von ihrem "type".
-- @return string valueText, number numericValue
local function classifySensorV2( res )
	local t = res.type or ""
	if (t == "motion") then
		local p = ((res.motion or {}).motion == true)
		return (p and "motion detected" or "no motion"), (p and 1 or 0)
	elseif (t == "temperature") then
		local c = tonumber( (res.temperature or {}).temperature ) or 0
		return string.format( "%.1f C", c ), c
	elseif (t == "light_level") then
		local raw = tonumber( (res.light or {}).light_level )
		local lux = 0
		if (raw ~= nil) then lux = 10 ^ ((raw - 1) / 10000) end
		return string.format( "%.0f lx", lux ), lux
	elseif (t == "button") then
		local ev = tostring( (res.button or {}).last_event or "" )
		return ev, 0
	elseif (t == "contact") then
		local isOpen = ((res.contact_report or {}).state == "no_contact")
		return (isOpen and "open" or "closed"), (isOpen and 1 or 0)
	end
	return "-", 0
end

--- Sensor-Instanz aktualisieren. Der Name und die Batterie kommen (anders als
-- bei Lampen) nicht von der Sensor-Ressource selbst, sondern vom zugehoerigen
-- Geraet (owner) - Motion-/Temperature-/Light-Level-/Contact-/Button-
-- Ressourcen haben in CLIP v2 kein eigenes "metadata.name"-Feld.
local function applyOneSensor( oInst )
	local id = getStr( oInst, "SENSOR_HUE_ID" )
	if (id == "") then return end
	local res = RES_BY_ID[id]
	if (res == nil) then return end

	setVal( oInst, "SENSOR_TYPE", res.type or "" )
	local valueText, numericValue = classifySensorV2( res )
	setVal( oInst, "SENSOR_VALUE", valueText )
	setVal( oInst, "SENSOR_NUMERICVALUE", numericValue )
	if (res.type == "contact") then
		setVal( oInst, "SENSOR_CONTACT", ((res.contact_report or {}).state == "no_contact") and 1 or 0 )
	end

	if (type(res.owner) == "table") and (res.owner.rid ~= nil) then
		local devId = res.owner.rid
		local name = NAME_OF_DEVICE[devId] or ""
		setVal( oInst, "SENSOR_NAME", name )
		renameFolderIfNeeded( oInst, name )

		local battId = BATTERY_OF_DEVICE[devId]
		local battRes = (battId ~= nil) and RES_BY_ID[battId] or nil
		if (battRes ~= nil) and (type(battRes.power_state) == "table") and (battRes.power_state.battery_level ~= nil) then
			setVal( oInst, "SENSOR_BATTERY", battRes.power_state.battery_level )
		end
	end

	setVal( oInst, "SENSOR_LASTUPDATED", nowStr() )
end

local function applyOneAutomation( oInst )
	local id = getStr( oInst, "AUTOMATION_HUE_ID" )
	if (id == "") then return end
	local res = RES_BY_ID[id]
	if (res == nil) then return end

	local name = fixName( (res.metadata or {}).name or "" )
	setVal( oInst, "AUTOMATION_NAME", name )
	renameFolderIfNeeded( oInst, name )
	setVal( oInst, "AUTOMATION_ENABLED", (res.enabled == true) and 1 or 0 )
end

--- CLIP v2 geofence_client-Ressourcen im Cache auswerten: true, wenn mind.
-- ein registriertes Telefon "zuhause" meldet. Tracing nur bei Wechsel.
local function applyGeofenceFromCache()
	if (STATUS == nil) then return end
	if (getStr( CFG, "GEOFENCE_ENABLED" ) ~= "1") then return end
	local anyHome = false
	for _, res in pairs( RES_BY_ID ) do
		if (type(res) == "table") and (res.type == "geofence_client") and (res.is_at_home == true) then
			anyHome = true
		end
	end
	if (g_lastPresent ~= anyHome) then
		traceMsg( "Anwesenheit geaendert - " .. (anyHome and "jemand zuhause" or "niemand zuhause") )
		g_lastPresent = anyHome
	end
	setVal( STATUS, "ANY_PRESENT", anyHome and 1 or 0 )
end

-------------------------------------------------------------------------------
-- Vollsynchronisation (einmalig bei Init(), danach nur auf Anfrage - die
-- laufende Aktualisierung uebernimmt ab dann der Eventstream)
-------------------------------------------------------------------------------

--- Fragt ALLE Bridge-Ressourcen in EINER Anfrage ab (GET /clip/v2/resource),
-- baut Cache und Zuordnungen neu auf und schreibt den Zustand auf alle
-- konfigurierten Instanzen. Sammelt anschliessend faellige Umbenennungen in
-- EINEM SaveProject()-Aufruf (siehe renameFolderIfNeeded()).
-- @param isRetryAfterDiscovery boolean|nil intern gesetzt, um eine Endlosschleife
--        bei weiterhin fehlschlagender Verbindung zu verhindern
function FullSync( isRetryAfterDiscovery )
	if (STATUS == nil) then return end
	local bridgeIp = getStr( CFG, "BRIDGE_IP" )
	local apiKey   = getStr( CFG, "API_KEY" )
	if ((bridgeIp == "") or (apiKey == "")) then
		traceMsg( "Vollsynchronisation uebersprungen - Bridge-IP oder API-Key fehlt" )
		return
	end

	traceMsg( "Vollsynchronisation gestartet" )
	local data, err = clipGet( "/clip/v2/resource" )
	if (data == nil) then
		setVal( STATUS, "LAST_ERROR", "Vollsynchronisation: " .. tostring(err) )
		traceMsg( "Vollsynchronisation fehlgeschlagen: " .. tostring(err) )
		if ((not isRetryAfterDiscovery) and tryAutoDiscoverBridgeIp()) then
			FullSync( true )
		end
		return
	end

	rebuildDerivedMaps( data )
	RebuildInstanceTables()
	rebuildWatchers()

	for _, oInst in pairs( LIGHTTABLE )      do applyOneLight( oInst ) end
	for _, oInst in pairs( GROUPTABLE )      do applyOneGroup( oInst ) end
	for _, oInst in pairs( SCENETABLE )      do applyOneScene( oInst ) end
	for _, oInst in pairs( SENSORTABLE )     do applyOneSensor( oInst ) end
	for _, oInst in pairs( AUTOMATIONTABLE ) do applyOneAutomation( oInst ) end
	applyGeofenceFromCache()

	setVal( STATUS, "LAST_UPDATE", nowStr() )
	setVal( STATUS, "LAST_ERROR", "" )
	traceMsg( "Vollsynchronisation abgeschlossen - " .. tblCount(RES_BY_ID) .. " Ressourcen" )

	if (g_dirtyNames) then
		pcall( function() E:SaveProject() end )
		g_dirtyNames = false
	end
end

-------------------------------------------------------------------------------
-- Inventar (Hue-IDs -> Namen, zum Uebertragen in JVP-Instanzen)
-------------------------------------------------------------------------------

local function writeInventoryField( fieldName, lines )
	local full = table.concat( lines, "\n" )
	if (#full > MAX_INVENTORY_LEN) then
		full = full:sub( 1, MAX_INVENTORY_LEN ) .. "\n... (gekuerzt - " .. tostring(#lines) .. " Zeilen gesamt)"
	end
	setVal( STATUS, fieldName, full )
end

local function nameForAssignment( id, res )
	if (type(res.metadata) == "table") then return res.metadata.name or "" end
	local t = res.type
	if ((t == "motion") or (t == "temperature") or (t == "light_level") or (t == "contact") or (t == "button")) then
		local devId = (type(res.owner) == "table") and res.owner.rid or nil
		return (devId ~= nil) and (NAME_OF_DEVICE[devId] or "") or ""
	end
	return ""
end

--- Fragt einmalig alle Bridge-Ressourcen ab (FullSync) und schreibt je
-- Kategorie eine eigene Tab-getrennte, nach Name sortierte Liste (v2-ID /
-- Name / Zusatzinfo) nach STATUS.INVENTORY_* - unabhaengig von bereits
-- angelegten JVP-Instanzen.
function DumpInventory()
	local apiKey = getStr( CFG, "API_KEY" )
	if (apiKey == "") then
		traceMsg( "Inventar: kein API-Key - erst Pairing durchfuehren" )
		return
	end
	FullSync()

	local lights, groups, scenes, sensors, autos = {}, {}, {}, {}, {}
	for id, res in pairs( RES_BY_ID ) do
		local t = res.type
		if (t == "light") then
			lights[#lights + 1] = { id = id, name = fixName( nameForAssignment(id, res) ) }
		elseif ((t == "room") or (t == "zone")) then
			groups[#groups + 1] = { id = id, name = fixName( nameForAssignment(id, res) ), extra = t }
		elseif (t == "scene") then
			local groupLabel = "-"
			if (type(res.group) == "table") and (res.group.rid ~= nil) then
				local gr = RES_BY_ID[res.group.rid]
				if (gr ~= nil) and (type(gr.metadata) == "table") then groupLabel = fixName( gr.metadata.name or "" ) end
			end
			scenes[#scenes + 1] = { id = id, name = fixName( nameForAssignment(id, res) ), extra = groupLabel }
		elseif ((t == "motion") or (t == "temperature") or (t == "light_level") or (t == "contact") or (t == "button")) then
			sensors[#sensors + 1] = { id = id, name = fixName( nameForAssignment(id, res) ), extra = t }
		elseif (t == "behavior_instance") then
			autos[#autos + 1] = { id = id, name = fixName( nameForAssignment(id, res) ) }
		end
	end

	local function byName( a, b ) return (a.name or "") < (b.name or "") end
	table.sort( lights, byName ); table.sort( groups, byName ); table.sort( scenes, byName )
	table.sort( sensors, byName ); table.sort( autos, byName )

	local lines

	lines = {}
	for _, e in ipairs(lights) do lines[#lines + 1] = e.id .. "\t" .. e.name end
	writeInventoryField( "INVENTORY_LIGHTS", lines )

	lines = {}
	for _, e in ipairs(groups) do lines[#lines + 1] = e.id .. "\t" .. e.name .. "\t" .. tostring(e.extra) end
	writeInventoryField( "INVENTORY_GROUPS", lines )

	lines = {}
	for _, e in ipairs(scenes) do lines[#lines + 1] = e.id .. "\t" .. e.name .. "\t" .. tostring(e.extra) end
	writeInventoryField( "INVENTORY_SCENES", lines )

	lines = {}
	for _, e in ipairs(sensors) do lines[#lines + 1] = e.id .. "\t" .. e.name .. "\t" .. tostring(e.extra) end
	writeInventoryField( "INVENTORY_SENSORS", lines )

	lines = {}
	for _, e in ipairs(autos) do lines[#lines + 1] = e.id .. "\t" .. e.name end
	writeInventoryField( "INVENTORY_AUTOMATIONS", lines )

	traceMsg( "Inventar komplett erstellt" )
end

-------------------------------------------------------------------------------
-- Automatische ID-Zuordnung (gefundene Hue-IDs -> angelegte JVP-Instanzen)
-------------------------------------------------------------------------------

local function collectUsedIds( list, idField )
	local used = {}
	for _, tbl in pairs( list or {} ) do
		local id = getStr( tbl, idField )
		if (id ~= "") then used[id] = true end
	end
	return used
end

--- Ordnet den Instanzen einer Kategorie (in Anlage-Reihenfolge) der Reihe
-- nach die gefundenen Hue-IDs aus `sortedIdList` zu. Instanzen mit bereits
-- gesetzter ID werden uebersprungen; bereits verwendete IDs werden ausgelassen.
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

--- Nach Name sortierte ID-Liste aller Cache-Ressourcen eines (oder mehrerer)
-- v2-Typs/-Typen.
local function idsByTypeSortedByName( matchTypes )
	if (type(matchTypes) ~= "table") then matchTypes = { matchTypes } end
	local wanted = {}
	for _, mt in ipairs( matchTypes ) do wanted[mt] = true end

	local arr = {}
	for id, res in pairs( RES_BY_ID ) do
		if (wanted[res.type]) then
			arr[#arr + 1] = { id = id, name = fixName( nameForAssignment(id, res) ) }
		end
	end
	table.sort( arr, function( a, b ) return (a.name or "") < (b.name or "") end )

	local ids = {}
	for _, e in ipairs(arr) do ids[#ids + 1] = e.id end
	return ids
end

--- Fragt einmalig alle Bridge-Ressourcen ab (FullSync) und ordnet die
-- gefundenen IDs den bereits im JVP-Editor angelegten Instanzen zu.
-- Ausgeloest ueber CONFIGURATION.ASSIGN_IDS.
function AssignInventoryIds()
	local apiKey = getStr( CFG, "API_KEY" )
	if (apiKey == "") then
		traceMsg( "ID-Zuordnung: kein API-Key - erst Pairing durchfuehren" )
		return
	end
	FullSync()

	assignCategoryIds( "LIGHTS_ROOT",      "Light",      "LIGHT_HUE_ID",      idsByTypeSortedByName("light") )
	assignCategoryIds( "GROUPS_ROOT",      "Group",      "GROUP_HUE_ID",      idsByTypeSortedByName({"room","zone"}) )
	assignCategoryIds( "SCENES_ROOT",      "Scene",      "SCENE_HUE_ID",      idsByTypeSortedByName("scene") )
	assignCategoryIds( "SENSORS_ROOT",     "Sensor",     "SENSOR_HUE_ID",     idsByTypeSortedByName({"motion","temperature","light_level","contact","button"}) )
	assignCategoryIds( "AUTOMATIONS_ROOT", "Automation", "AUTOMATION_HUE_ID", idsByTypeSortedByName("behavior_instance") )

	traceMsg( "ID-Zuordnung abgeschlossen" )
	FullSync()
end

-------------------------------------------------------------------------------
-- Pairing (Link-Button-Ablauf, "POST /api" - ueber HTTPS wie der Rest der v2-API)
-------------------------------------------------------------------------------

local function doPairingAttempt()
	local resp, err = httpRequest( 1, "/api", { devicetype = "jvp#hue-v2", generateclientkey = true }, false )
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
	g_lastPairingAttempt = 0
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
	if ((os.time() - g_lastPairingAttempt) < 1) then return end -- max. 1x/Sekunde versuchen
	g_lastPairingAttempt = os.time()

	local ok, result = doPairingAttempt()
	if (ok) then
		setVal( CFG, "API_KEY", result )
		g_pairing = false
		traceMsg( "Pairing erfolgreich - API-Key erhalten" )
		setVal( STATUS, "PAIRING_STATE", "Gekoppelt" )
		setVal( STATUS, "LAST_ERROR", "" )
		g_streamRetryAt = 0
		FullSync()
	else
		local remaining = math.max( 0, g_pairingDeadline - os.time() )
		setVal( STATUS, "PAIRING_STATE", "Warte auf Tastendruck... (" .. tostring(remaining) .. "s)" )
		setVal( STATUS, "LAST_ERROR", tostring(result) )
	end
end

-------------------------------------------------------------------------------
-- SSE-Eventstream (Server-Sent Events, CLIP v2 Live-Updates)
-------------------------------------------------------------------------------

--- Ein geaendertes Ressourcen-Fragment (aus einem Event) in RES_BY_ID
-- einmischen - nur die im Fragment enthaltenen Top-Level-Felder werden
-- ueberschrieben, der Rest (z.B. "owner", "metadata") bleibt vom letzten
-- FullSync() erhalten.
-- @return table|nil die zusammengefuehrte Ressource
local function mergeResourceFragment( frag )
	if (type(frag) ~= "table") or (frag.id == nil) then return nil end
	local existing = RES_BY_ID[frag.id]
	if (existing == nil) then
		RES_BY_ID[frag.id] = frag
		return frag
	end
	for k, v in pairs( frag ) do existing[k] = v end
	return existing
end

--- Ein einzelnes Event-Fragment verarbeiten: in den Cache einmischen und die
-- betroffene(n) JVP-Instanz(en) ueber denselben apply*-Code-Pfad wie
-- FullSync() aktualisieren.
local function applySseFragment( frag )
	local merged = mergeResourceFragment( frag )
	if (merged == nil) then return end
	local t = merged.type

	if (t == "light") then
		local inst = LIGHTTABLE[merged.id]
		if (inst ~= nil) then applyOneLight( inst ) end
	elseif (t == "grouped_light") then
		local inst = GROUP_INST_BY_GROUPEDLIGHT[merged.id]
		if (inst ~= nil) then applyOneGroup( inst ) end
	elseif ((t == "room") or (t == "zone")) then
		local inst = GROUPTABLE[merged.id]
		if (inst ~= nil) then applyOneGroup( inst ) end
	elseif ((t == "motion") or (t == "temperature") or (t == "light_level") or (t == "contact") or (t == "button")) then
		local inst = SENSORTABLE[merged.id]
		if (inst ~= nil) then applyOneSensor( inst ) end
	elseif (t == "scene") then
		local inst = SCENETABLE[merged.id]
		if (inst ~= nil) then applyOneScene( inst ) end
	elseif (t == "behavior_instance") then
		local inst = AUTOMATIONTABLE[merged.id]
		if (inst ~= nil) then applyOneAutomation( inst ) end
	elseif (t == "device_power") then
		local devId = (type(merged.owner) == "table") and merged.owner.rid or nil
		if (devId ~= nil) then
			for _, inst in ipairs( BATTERY_WATCHERS[devId] or {} ) do applyOneSensor( inst ) end
		end
	elseif (t == "zigbee_connectivity") then
		local devId = (type(merged.owner) == "table") and merged.owner.rid or nil
		if (devId ~= nil) then
			for _, inst in ipairs( ZIGBEE_WATCHERS[devId] or {} ) do applyOneLight( inst ) end
		end
	elseif (t == "device") then
		if (type(merged.metadata) == "table") and (merged.metadata.name ~= nil) then
			NAME_OF_DEVICE[merged.id] = fixName( merged.metadata.name )
			for _, inst in ipairs( DEVICENAME_WATCHERS[merged.id] or {} ) do applyOneSensor( inst ) end
		end
	elseif (t == "geofence_client") then
		applyGeofenceFromCache()
	end

	if (g_dirtyNames) then
		pcall( function() E:SaveProject() end )
		g_dirtyNames = false
	end
end

--- Einen vollstaendigen SSE-Event-Block (alle Zeilen bis zur Leerzeile)
-- auswerten: "data:"-Zeilen sammeln (mehrzeilig moeglich), "id:" merken,
-- Kommentar-/Keepalive-Zeilen (":"...) ignorieren.
local function processSseBlock( block )
	if (block == nil) or (block == "") then return end
	local dataLines = {}
	for line in (block .. "\n"):gmatch( "(.-)\n" ) do
		if (line:sub(1, 1) == ":") then
			-- Kommentar/Keepalive der Bridge, ignorieren
		elseif (line:sub(1, 5) == "data:") then
			local d = line:sub(6)
			if (d:sub(1, 1) == " ") then d = d:sub(2) end
			dataLines[#dataLines + 1] = d
		elseif (line:sub(1, 3) == "id:") then
			local idv = line:sub(4)
			if (idv:sub(1, 1) == " ") then idv = idv:sub(2) end
			if (idv ~= "") then g_lastEventId = idv end
		end
	end
	if (#dataLines == 0) then return end

	local payload = table.concat( dataLines, "\n" )
	local ok, events = pcall( json.decode, payload )
	if ((not ok) or (type(events) ~= "table")) then return end

	g_streamGotData = true
	setVal( STATUS, "CONNECTED", 1 )
	setVal( STATUS, "LAST_EVENT", nowStr() )

	for _, evt in pairs( events ) do
		if (type(evt) == "table") and (type(evt.data) == "table") then
			for _, frag in pairs( evt.data ) do
				local pOk, pErr = pcall( applySseFragment, frag )
				if (not pOk) then traceMsg( "FEHLER beim Verarbeiten eines Events: " .. tostring(pErr) ) end
			end
		end
	end
end

--- Empfangenen Chunk an den Puffer anhaengen und alle vollstaendigen Events
-- (getrennt durch eine Leerzeile) herausloesen und verarbeiten.
local function handleStreamChunk( chunk )
	chunk = chunk:gsub( "\r\n", "\n" )
	g_sseBuffer = g_sseBuffer .. chunk
	while true do
		local sep = g_sseBuffer:find( "\n\n", 1, true )
		if (sep == nil) then break end
		local block = g_sseBuffer:sub( 1, sep - 1 )
		g_sseBuffer = g_sseBuffer:sub( sep + 2 )
		processSseBlock( block )
	end
	-- Sicherheitsnetz: sollte der Puffer trotz laufendem Stream unplausibel
	-- gross werden, verwerfen statt unbegrenzt wachsen zu lassen.
	if (#g_sseBuffer > 200000) then
		traceMsg( "Eventstream-Puffer zu gross - wird verworfen" )
		g_sseBuffer = ""
	end
end

--- Startet (bzw. startet neu) den Eventstream. URL und Header muessen laut
-- JVP-Dokumentation vor StartStream() gesetzt werden; fuer SSE: Request-Typ 0
-- (GET) mit leerem Body und "Accept: text/event-stream".
--
-- WICHTIG: laeuft ueber die EIGENE Ressource HTTP_EVENTS, nicht ueber HTTP_RQ.
-- Wuerde man dieselbe HTTP-Ressource sowohl fuer die dauerhafte Streaming-
-- Verbindung als auch fuer normale Open()/SendRequest()/Close()-Zyklen (Schalt-
-- befehle, FullSync) verwenden, wuerde jeder normale Request die laufende
-- Streaming-Verbindung unterbrechen - Symptom: Schaltbefehle funktionieren
-- (normale Requests), aber es kommen nie/kaum Rueckmeldungen ueber den
-- Eventstream an, weil er staendig neu verbindet.
local function startEventStream()
	if (HTTP_EVENTS == nil) then return end
	local host = getStr( CFG, "BRIDGE_IP" )
	local key  = getStr( CFG, "API_KEY" )
	if ((host == "") or (key == "")) then return end

	pcall( function() HTTP_EVENTS:SetURL( "https://" .. host .. "/eventstream/clip/v2" ) end )
	pcall( function() HTTP_EVENTS:RemoveHeaders() end )
	pcall( function() HTTP_EVENTS:AddHeader( "Accept: text/event-stream" ) end )
	pcall( function() HTTP_EVENTS:AddHeader( "hue-application-key: " .. key ) end )
	if (g_lastEventId ~= nil) then
		pcall( function() HTTP_EVENTS:AddHeader( "Last-Event-ID: " .. g_lastEventId ) end )
	end
	g_sseBuffer = ""
	g_streamGotData = false
	g_streamConnectedLogged = false
	local ok = pcall( function() HTTP_EVENTS:StartStream( 0, "" ) end )
	if (ok) then traceMsg( "Eventstream verbindet..." ) end
end

--- Wird aus Poll() bei jedem Zyklus aufgerufen: haelt den Eventstream am
-- Laufen (Neuverbindung bei Bedarf), pumpt anstehende Daten (ReadStream()
-- MUSS laut Dokumentation in jedem Poll() aufgerufen werden) und wertet sie aus.
-- Nutzt ausschliesslich HTTP_EVENTS (siehe startEventStream()).
local function driveEventStream()
	if (HTTP_EVENTS == nil) then return end
	local bridgeIp = getStr( CFG, "BRIDGE_IP" )
	local apiKey   = getStr( CFG, "API_KEY" )
	if ((bridgeIp == "") or (apiKey == "")) then
		setVal( STATUS, "CONNECTED", 0 )
		return
	end

	local streaming = false
	pcall( function() streaming = (HTTP_EVENTS:IsStreaming() == 1) end )

	if (not streaming) then
		local now = os.time()
		if (now < g_streamRetryAt) then return end
		g_streamRetryAt = now + SSE_RETRY_SECONDS
		startEventStream()
		return
	end

	local body, active
	local ok = pcall( function() body, active = HTTP_EVENTS:ReadStream() end )
	if (not ok) then return end
	if ((body ~= nil) and (body ~= "")) then
		-- Erste tatsaechlich empfangenen Bytes sind der fruehestmoegliche Beweis,
		-- dass die Verbindung steht (auch Kommentar-/Keepalive-Zeilen der Bridge
		-- zaehlen dafuer) - einmalig pro Verbindung in der Nachrichtenbox loggen.
		if (not g_streamConnectedLogged) then
			g_streamConnectedLogged = true
			traceMsg( "Eventstream verbunden - empfange Daten" )
		end
		handleStreamChunk( body )
	end
	if (active == 0) then
		local rc, errText, httpStatus
		pcall( function() rc, errText, httpStatus = HTTP_EVENTS:GetStreamResult() end )
		traceMsg( "Eventstream beendet (curl=" .. tostring(rc) .. ", http=" .. tostring(httpStatus) ..
			", " .. tostring(errText) .. ") - Neuverbindung in " .. SSE_RETRY_SECONDS .. "s" )
		setVal( STATUS, "CONNECTED", 0 )
		g_streamRetryAt = os.time() + SSE_RETRY_SECONDS
		tryAutoDiscoverBridgeIp()
	end
end

-- ===========================================================================
-- JVP lifecycle
-- ===========================================================================

function Init()
	CFG     = E.PVTable["CONFIGURATION"]
	STATUS  = E.PVTable["STATUS"]
	HTTP_RQ = E.ResourceTable["HTTP"]
	HTTP_EVENTS = E.ResourceTable["HTTP_EVENTS"]
	-- WICHTIG: Open() erzeugt den HTTP-Requester im Device Editor erst. Ohne
	-- diesen Aufruf bleiben SetURL()/AddHeader()/StartStream() auf HTTP_EVENTS
	-- wirkungslos, weil die Ressource nie angelegt wurde (siehe JVP-Doku,
	-- Kapitel "Resources": "Open() - Creates a HTTP requester in the device
	-- editor."). HTTP_RQ braucht das hier nicht, weil httpRequest() vor jedem
	-- SendRequest() selbst Open() aufruft.
	if (HTTP_EVENTS ~= nil) then
		pcall( function() HTTP_EVENTS:Open() end )
	end
	traceMsg( "---- PhilipsHueV2: Init ----" )

	RebuildInstanceTables()
	g_pairing              = false
	g_pairingDeadline      = 0
	g_lastPairingAttempt   = 0
	g_lastPresent          = nil
	g_lastAutoDiscoverAttempt = 0
	g_sseBuffer            = ""
	g_lastEventId          = nil
	g_streamRetryAt        = 0
	g_streamGotData        = false
	g_streamConnectedLogged = false
	g_dirtyNames           = false
	g_lastFolderName       = {}

	setVal( STATUS, "PAIRING_STATE", "Bereit" )
	setVal( STATUS, "CONNECTED", 0 )
	traceMsg( "Instanzen geladen - Lights=" .. tblCount(LIGHTTABLE) ..
		" Groups=" .. tblCount(GROUPTABLE) .. " Scenes=" .. tblCount(SCENETABLE) ..
		" Sensors=" .. tblCount(SENSORTABLE) .. " Automations=" .. tblCount(AUTOMATIONTABLE) )

	FullSync()          -- einmaliger Vollabgleich beim Start
	startEventStream()  -- danach uebernimmt der Eventstream die laufende Aktualisierung
end

function Exit()
	traceMsg( "---- PhilipsHueV2: Exit ----" )
	if (HTTP_EVENTS ~= nil) then
		pcall( function() HTTP_EVENTS:StopStream() end )
		pcall( function() HTTP_EVENTS:Close() end )
	end
	if (HTTP_RQ ~= nil) then
		pcall( function() HTTP_RQ:Close() end )
	end
end

function Poll()
	RebuildInstanceTables()
	if (g_pairing) then pollPairing() end
	driveEventStream()
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

	-- Jeden eingehenden Schreibzugriff sofort quittieren, sonst uebernimmt JVP
	-- den Wert nicht in sein Prozessmodell/die Visualisierung.
	v:SetValue( strValue, constWriteAck )

	local name = v:GetScriptName()

	-- Konfigurationsebene (kein Instanz-Elternordner)
	if (name == "PAIR_REQUEST") then
		if (parseNum(strValue) == 1) then startPairing() end
		return
	end
	if (name == "CLEAR_DEBUG_LOG") then
		if (parseNum(strValue) == 1) then setVal( STATUS, "DEBUG_LOG", "" ) end
		return
	end
	if (name == "DUMP_INVENTORY") then
		if (parseNum(strValue) == 1) then DumpInventory() end
		return
	end
	if (name == "ASSIGN_IDS") then
		if (parseNum(strValue) == 1) then AssignInventoryIds() end
		return
	end
	if (name == "REFRESH_STATES") then
		if (parseNum(strValue) == 1) then FullSync() end
		return
	end
	if (name == "GEOFENCE_ENABLED") then
		applyGeofenceFromCache()
		return
	end
	if (name == "BRIDGE_IP") then
		traceMsg( "Bridge-IP geaendert auf " .. tostring(strValue) )
		setVal( STATUS, "PAIRING_STATE", "Bereit" )
		g_streamRetryAt = 0
		if (HTTP_EVENTS ~= nil) then pcall( function() HTTP_EVENTS:StopStream() end ) end
		return
	end
	if (name == "API_KEY") then
		traceMsg( "API-Key manuell geaendert" )
		setVal( STATUS, "PAIRING_STATE", "Bereit" )
		g_streamRetryAt = 0
		if (HTTP_EVENTS ~= nil) then pcall( function() HTTP_EVENTS:StopStream() end ) end
		return
	end

	-- Lampe
	local oLight = oVarPath:_findParentFromUserType( "light_t" )
	if (oLight ~= nil) then
		if (name == "LIGHT_HUE_ID") then
			FullSync()
			return
		end
		local id = getStr( oLight, "LIGHT_HUE_ID" )
		if (id == "") then return end
		local path = "/clip/v2/resource/light/" .. id
		if (name == "LIGHT_ON_CMD") then
			clipPut( path, { on = { on = (parseNum(strValue) == 1) } } )
		elseif (name == "LIGHT_BRIGHTNESS_CMD") then
			clipPut( path, { on = { on = true }, dimming = { brightness = clamp(parseNum(strValue) or 0, 0, 100) } } )
		elseif (name == "LIGHT_COLORTEMP_CMD") then
			clipPut( path, { on = { on = true }, color_temperature = { mirek = kelvinToMirek(parseNum(strValue) or 2700) } } )
		elseif (name == "LIGHT_HUEANGLE_CMD") then
			local h = parseNum(strValue) or 0
			local s = getNum( oLight, "LIGHT_SATURATION" )
			local x, y = hsvToXy( h, s )
			clipPut( path, { on = { on = true }, color = { xy = { x = x, y = y } } } )
		elseif (name == "LIGHT_SATURATION_CMD") then
			local s = parseNum(strValue) or 0
			local h = getNum( oLight, "LIGHT_HUEANGLE" )
			local x, y = hsvToXy( h, s )
			clipPut( path, { on = { on = true }, color = { xy = { x = x, y = y } } } )
		end
		return
	end

	-- Raum/Zone
	local oGroup = oVarPath:_findParentFromUserType( "group_t" )
	if (oGroup ~= nil) then
		if (name == "GROUP_HUE_ID") then
			FullSync()
			return
		end
		local glId = getStr( oGroup, "GROUP_GROUPEDLIGHT_ID" )
		if (glId == "") then return end
		local path = "/clip/v2/resource/grouped_light/" .. glId
		if (name == "GROUP_ON_CMD") then
			clipPut( path, { on = { on = (parseNum(strValue) == 1) } } )
		elseif (name == "GROUP_BRIGHTNESS_CMD") then
			clipPut( path, { on = { on = true }, dimming = { brightness = clamp(parseNum(strValue) or 0, 0, 100) } } )
		end
		return
	end

	-- Szene
	local oScene = oVarPath:_findParentFromUserType( "scene_t" )
	if (oScene ~= nil) then
		if (name == "SCENE_HUE_ID") then
			FullSync()
			return
		end
		if ((name == "SCENE_ACTIVATE") and (parseNum(strValue) == 1)) then
			local id = getStr( oScene, "SCENE_HUE_ID" )
			if (id ~= "") then
				clipPut( "/clip/v2/resource/scene/" .. id, { recall = { action = "active" } } )
			end
		end
		return
	end

	-- Sensor
	local oSensor = oVarPath:_findParentFromUserType( "sensor_t" )
	if (oSensor ~= nil) then
		if (name == "SENSOR_HUE_ID") then
			FullSync()
		end
		return
	end

	-- Automation (behavior_instance)
	local oAuto = oVarPath:_findParentFromUserType( "automation_t" )
	if (oAuto ~= nil) then
		if (name == "AUTOMATION_HUE_ID") then
			FullSync()
			return
		end
		if (name == "AUTOMATION_ENABLED_CMD") then
			local id = getStr( oAuto, "AUTOMATION_HUE_ID" )
			if (id ~= "") then
				clipPut( "/clip/v2/resource/behavior_instance/" .. id, { enabled = (parseNum(strValue) == 1) } )
			end
		end
		return
	end
end
