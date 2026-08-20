-------------------------------------------------------------------------------
-- InterfaceScript.lua
-- @script InterfaceScript
--
-- JVP interface "PresenceSimulation"
-- Implements the function described in chapter 4.2.4.11 of the functional
-- description (KNX panel FP 701 CT IP, art. no. FP 701 CT IP, software
-- "...590101"):
--
--   * Recording of up to 32 "functions" (recording objects), created either
--     as binary (DPT 1.001, folder FUNCTION_BINARY) or analog
--     (DPT 5.001...5.004, folder FUNCTION_ANALOG) - the telegram value
--     therefore has the correct datapoint type from the start, no separate
--     data-format setting is needed. Each function has a separate INPUT
--     object (VALUE_IN, tapped for recording) and OUTPUT object (VALUE_OUT,
--     driven during playback), so the recording source and the playback
--     target can be linked to different KNX group addresses if needed,
--   * Selection of up to 32 of these functions (binary+analog combined)
--     for a simulation,
--   * Recording duration 1...7 days (24h periods), max. 2100 telegrams,
--     every incoming telegram is stamped with time and weekday to the
--     second,
--   * Playback accurate to the second, either "Repeating" (time of day
--     only, repeated daily) or "Weekday" (time of day + weekday, repeated
--     weekly, days without a recording are skipped),
--   * optional start delay for playback,
--   * Start/stop of recording and playback via button or via the 1-bit
--     communication object ("Start/stop playback"),
--   * Status communication objects "Recording active" / "Playback active",
--   * Weekday either set directly or synchronized via the weekday field of
--     a DPT 10.001 time telegram.
--
-- IMPORTANT:
--   * This interface provides the datapoints and the simulation logic.
--     Linking FUNCTION_BINARY[n].VALUE_IN/VALUE_OUT resp.
--     FUNCTION_ANALOG[n].VALUE_IN_A/VALUE_OUT_A to the actual KNX group
--     address(es) of each function is done as usual in the JVP project
--     (binding in the visualization resp. via the KNX interface) - this
--     corresponds to assigning a recording object to a group address in
--     the ETS plug-in of the original device. VALUE_IN/VALUE_OUT may be
--     linked to the same group address (typical case) or to two different
--     ones (e.g. a status GA for recording, a control GA for playback).
--   * The channel-selection page, confirmation dialogs ("save back" /
--     "cancel back") and the status-line display are the visualization's
--     responsibility; this interface only provides the datapoints needed
--     for that (SELECTED_COUNT, TELEGRAM_COUNT, PLAYBACK_DELAY_REMAINING, ...).
--   * As with the original device, the recorded telegram sequence lives
--     only in memory (Lua table LOG) and is lost on an interface restart
--     (power loss / programming operation).
--   * Manual time changes during an active recording or playback can -
--     as in the original - cause overlaps or skipped telegrams; the script
--     implements the catch-up/skip logic described at a basic level, but
--     does not claim bit-exact reproduction of the daylight-saving-time
--     edge cases.
--
-- TROUBLESHOOTING: the script emits E:trace() messages at all significant
-- points (Init, building the function list, start/stop of recording and
-- playback, every recorded and every played-back telegram, rejected
-- operations, unknown/unexpected datapoints). These appear in JVP's
-- trace/log window for the interface and help narrow down a reported
-- problem (please attach the relevant trace excerpt when reporting an
-- issue).
--
-- Target runtime: Lua 5.1.
-------------------------------------------------------------------------------

require "InterfaceScriptCommonLibrary"

local MAX_FUNCTIONS = 32     -- max. number of recording objects (binary+analog combined)
local MAX_SELECTED  = 32     -- max. number of functions selected at the same time
local MAX_TELEGRAMS = 2100   -- max. number of recorded telegrams

mg_nPollSeconds = 1          -- matches INFO POLLTIME="1000" in the XML

INSTANCETABLE = {}           -- name -> folder table (function_binary_t / function_analog_t)
FUNCLIST      = {}           -- ordered list of all function folder tables (index = FUNCINDEX)
LOG           = {}           -- recording buffer: { idx, weekday, secOfDay, value, played }

RECORDINGENDEPOCH     = nil  -- os.time() at which an active recording ends at the latest
PLAYBACKPENDING       = false
PLAYBACKPENDINGEPOCH  = nil  -- os.time() at which a delayed playback actually starts
LASTDAYKEY            = nil  -- day key for playback cycle rollover
LASTWEEKDAYCHECK      = nil  -- day key for automatically advancing CURRENT_WEEKDAY

-- ===========================================================================
-- Helper functions
-- ===========================================================================

--- Parse a raw value tolerant of German comma / unit suffixes. JVP can pass
-- OnValueChange's strValue with a decimal comma (e.g. "7,0") or a trailing
-- unit - plain tonumber() then silently returns nil, which is the root
-- cause of bugs like "I enter 7 but 1 arrives" (falling back to a
-- hardcoded default). Always use this instead of tonumber(strValue) for
-- anything that reaches the panel/visualization as text.
-- @param s string|nil
-- @param default number
-- @return number
local function parseNum( s, default )
	default = default or 0
	if (s == nil) then return default end
	s = tostring(s):gsub( ",", "." )
	local n = tonumber( s )
	if (n ~= nil) then return n end
	return tonumber( (s:match( "[-+]?%d+%.?%d*" )) ) or default
end

--- Read a datapoint as a number, tolerant of German comma / unit suffixes
-- (see parseNum()).
-- @param oNode table  Folder table.
-- @param strName string  SCRIPTNAME of the datapoint.
-- @param default number  Value returned if not readable.
-- @return number
local function getNum( oNode, strName, default )
	default = default or 0
	if ((oNode == nil) or (oNode[strName] == nil)) then return default end
	return parseNum( oNode[strName]:GetValue(), default )
end

--- Write a datapoint (guarded).
local function setVal( oNode, strName, value, reason )
	if ((oNode ~= nil) and (oNode[strName] ~= nil)) then
		oNode[strName]:SetValue( tostring(value), reason or constValueChange )
	end
end

--- Clamp a value to a range.
local function clamp( n, lo, hi )
	if (n < lo) then return lo end
	if (n > hi) then return hi end
	return n
end

--- Seconds since midnight of the local system time (second-accurate timestamp).
local function secondsOfDay()
	local t = os.date( "*t" )
	return t.hour * 3600 + t.min * 60 + t.sec
end

--- Convert Lua weekday (1=Sunday...7=Saturday) to KNX/DPT-10.001 numbering
-- (1=Monday...7=Sunday).
local function knxWeekdayFromSystem()
	local wday = os.date( "*t" ).wday
	return ((wday - 2) % 7) + 1
end

--- Day key (calendar day) for day-change detection.
local function dayKey()
	return os.date( "%Y-%m-%d" )
end

--- JVP requires SCRIPTNAME to be unique across the ENTIRE interface, not
-- just within one folder. Since FUNCTION_BINARY and FUNCTION_ANALOG would
-- otherwise have identically named child fields (NAME/SELECTED/VALUE_IN/
-- VALUE_OUT/LASTVALUE_TIME_IN/LASTVALUE_TIME_OUT), the fields of
-- FUNCTION_ANALOG carry the suffix "_A" (see InterfaceDescription.xml).
-- tbl.FUNCSUFFIX is set when an instance is registered
-- (addFunctionsFromFolder); this helper returns the actual field name for
-- a function folder table.
-- @param tbl table  Function folder table (with FUNCSUFFIX set).
-- @param strBase string  Logical field name ("NAME"/"SELECTED"/"VALUE_IN"/"VALUE_OUT"/"LASTVALUE_TIME_IN"/"LASTVALUE_TIME_OUT").
-- @return string
local function ffield( tbl, strBase )
	return strBase .. ((tbl ~= nil and tbl.FUNCSUFFIX) or "")
end

-- ===========================================================================
-- Function list (recording objects)
-- ===========================================================================

--- Register all instances of one function folder (binary or analog) into
-- FUNCLIST (up to the combined limit MAX_FUNCTIONS). Both function folders
-- live nested inside the "FUNCTIONS" folder (SCRIPTNAME="FUNCTIONS") - all
-- functions the user creates end up there, grouped in one place.
-- @param strFolderScriptname string  SCRIPTNAME of the Multiple folder (e.g. "FUNCTION_BINARY").
-- @param strUserType string  E_UserType of the instances (e.g. "function_binary_t").
-- @param strTypeLabel string  Plain-text label for trace messages ("binary"/"analog").
-- @param strFieldSuffix string  Suffix of this folder's child fields ("" for binary, "_A" for analog).
local function addFunctionsFromFolder( strFolderScriptname, strUserType, strTypeLabel, strFieldSuffix )
	local functions = E.PVTable["FUNCTIONS"]
	if (functions == nil) then
		E:trace( "PresenceSimulation: folder 'FUNCTIONS' not found (check InterfaceDescription.xml)." )
		return
	end
	local list = functions[strFolderScriptname]
	if (list == nil) then
		E:trace( "PresenceSimulation: folder 'FUNCTIONS." .. strFolderScriptname .. "' not found (check InterfaceDescription.xml)." )
		return
	end
	for i, tbl in pairs( list ) do
		if (type(tbl) == "table") and (tbl.E_Type == "e_pvFolder") and (tbl.E_UserType == strUserType) then
			if (#FUNCLIST < MAX_FUNCTIONS) then
				FUNCLIST[#FUNCLIST + 1] = tbl
				tbl.FUNCINDEX  = #FUNCLIST
				tbl.FUNCTYPE   = strTypeLabel
				tbl.FUNCSUFFIX = strFieldSuffix
				local name = (tbl[ffield(tbl,"NAME")] ~= nil) and tbl[ffield(tbl,"NAME")]:GetValue() or nil
				if ((name == nil) or (name == "")) then name = strTypeLabel .. " " .. tostring(#FUNCLIST) end
				INSTANCETABLE[name] = tbl
				E:trace( "PresenceSimulation: function #" .. tbl.FUNCINDEX .. " (" .. strTypeLabel .. ") '" .. name .. "' registered." )
			else
				E:trace( "PresenceSimulation: more than " .. MAX_FUNCTIONS .. " functions defined - '" .. strFolderScriptname .. "' instance #" .. tostring(i) .. " is ignored." )
			end
		end
	end
end

--- Build FUNCLIST / INSTANCETABLE from all function_binary_t and
-- function_analog_t folders. Called at start and may be called again if
-- the project defines functions later on.
function CreateInstanceTable()
	INSTANCETABLE = {}
	FUNCLIST = {}
	addFunctionsFromFolder( "FUNCTION_BINARY", "function_binary_t", "binary", "" )
	addFunctionsFromFolder( "FUNCTION_ANALOG", "function_analog_t", "analog", "_A" )
	E:trace( "PresenceSimulation: function list built - " .. #FUNCLIST .. " of max. " .. MAX_FUNCTIONS .. " functions." )
end

--- Determine the number of currently selected functions and update
-- STATUS.SELECTED_COUNT.
-- @return number
local function updateSelectedCount()
	local n = 0
	for _, f in ipairs( FUNCLIST ) do
		if (getNum( f, ffield(f,"SELECTED") ) == 1) then n = n + 1 end
	end
	setVal( E.PVTable["STATUS"], "SELECTED_COUNT", n )
	return n
end

-- ===========================================================================
-- Recording
-- ===========================================================================

--- Start recording. Deletes any previously existing recording (see
-- functional description: "Each time a recording is started, the
-- previous recording is deleted").
function RecordingStart()
	local rec = E.PVTable["RECORDING"]
	if (getNum( rec, "RECORDING_ACTIVE" ) == 1) then return end

	PlaybackStop()   -- an active playback becomes invalid once a new recording starts

	LOG = {}
	local days = clamp( math.floor( getNum( rec, "RECORDING_LENGTH_DAYS", 1 ) ), 1, 7 )
	RECORDINGENDEPOCH = os.time() + (days * 86400)   -- 24h periods, not calendar days

	setVal( rec, "RECORDING_ACTIVE", 1 )
	setVal( rec, "HAS_RECORDING", 0 )
	setVal( rec, "TELEGRAM_COUNT", 0 )

	E:trace( "PresenceSimulation: recording started for " .. tostring(days) .. " day(s)." )
end

--- Stop recording (manually, after the recording duration elapsed, or
-- because the telegram limit was reached).
function RecordingStop()
	local rec = E.PVTable["RECORDING"]
	if (getNum( rec, "RECORDING_ACTIVE" ) == 0) then return end

	setVal( rec, "RECORDING_ACTIVE", 0 )
	setVal( rec, "TELEGRAM_COUNT", #LOG )
	setVal( rec, "HAS_RECORDING", (#LOG > 0) and 1 or 0 )
	RECORDINGENDEPOCH = nil

	E:trace( "PresenceSimulation: recording stopped, " .. tostring(#LOG) .. " telegram(s) saved." )
end

--- Record an incoming telegram of a selected function (with a
-- second-accurate time/weekday stamp).
-- @param funcIdx number  Index into FUNCLIST.
-- @param value number  Telegram value.
local function recordTelegram( funcIdx, value )
	local rec = E.PVTable["RECORDING"]
	if (getNum( rec, "RECORDING_ACTIVE" ) == 0) then return end
	if (#LOG >= MAX_TELEGRAMS) then
		E:trace( "PresenceSimulation: telegram limit (" .. MAX_TELEGRAMS .. ") reached - recording stops automatically." )
		RecordingStop()   -- limit reached -> recording stops automatically
		return
	end
	local wd  = knxWeekdayFromSystem()
	local sod = secondsOfDay()
	LOG[#LOG + 1] = {
		idx      = funcIdx,
		weekday  = wd,
		secOfDay = sod,
		value    = value,
		played   = false,
	}
	setVal( rec, "TELEGRAM_COUNT", #LOG )
	local f = FUNCLIST[funcIdx]
	local fname = (f ~= nil and f[ffield(f,"NAME")] ~= nil) and f[ffield(f,"NAME")]:GetValue() or ("#" .. tostring(funcIdx))
	E:trace( "PresenceSimulation: telegram #" .. #LOG .. " recorded - function '" .. fname .. "', value=" .. tostring(value) .. ", weekday=" .. wd .. ", second=" .. sod .. "." )
end

-- ===========================================================================
-- Playback
-- ===========================================================================

--- Trigger playback; honors a configured start delay.
function PlaybackStart()
	local rec = E.PVTable["RECORDING"]
	local pb  = E.PVTable["PLAYBACK"]
	if (getNum( rec, "HAS_RECORDING" ) == 0) then return end     -- no recording available
	if (getNum( rec, "RECORDING_ACTIVE" ) == 1) then return end  -- no playback while recording
	if (getNum( pb, "PLAYBACK_ACTIVE" ) == 1) then return end    -- already running
	if (PLAYBACKPENDING) then return end                         -- delay already in progress

	local delayHours = clamp( getNum( pb, "PLAYBACK_DELAY_HOURS", 0 ), 0, 99 )

	if (delayHours > 0) then
		PLAYBACKPENDING = true
		PLAYBACKPENDINGEPOCH = os.time() + (delayHours * 3600)
		setVal( pb, "PLAYBACK_DELAY_REMAINING", delayHours * 3600 )
		E:trace( "PresenceSimulation: playback delayed by " .. tostring(delayHours) .. " hour(s)." )
	else
		BeginPlaybackNow()
	end
end

--- Begin playback immediately (after any configured start delay has
-- elapsed). Telegrams of the current day that lie before the start time
-- are only considered in the next cycle (see functional description).
function BeginPlaybackNow()
	local pb = E.PVTable["PLAYBACK"]
	PLAYBACKPENDING = false
	setVal( pb, "PLAYBACK_DELAY_REMAINING", 0 )

	local startSec      = secondsOfDay()
	local todayWeekday   = knxWeekdayFromSystem()
	local playbackType  = getNum( pb, "PLAYBACK_TYPE" )   -- 0=Repeating, 1=Weekday

	for _, e in ipairs( LOG ) do
		if ((playbackType == 0) or (e.weekday == todayWeekday)) then
			e.played = (e.secOfDay < startSec)
		else
			e.played = false   -- belongs to a different weekday, only relevant there
		end
	end
	LASTDAYKEY = dayKey()

	setVal( pb, "PLAYBACK_ACTIVE", 1 )
	E:trace( "PresenceSimulation: playback started." )
end

--- Stop playback (or an in-progress start delay).
function PlaybackStop()
	local pb = E.PVTable["PLAYBACK"]
	PLAYBACKPENDING = false
	PLAYBACKPENDINGEPOCH = nil
	setVal( pb, "PLAYBACK_DELAY_REMAINING", 0 )
	if (getNum( pb, "PLAYBACK_ACTIVE" ) == 1) then
		setVal( pb, "PLAYBACK_ACTIVE", 0 )
		E:trace( "PresenceSimulation: playback stopped." )
	end
end

--- Reset all "played" markers on day change (new daily cycle; for playback
-- type "Weekday" a telegram thereby only becomes due again the following
-- week on the same weekday).
local function rolloverIfNewDay()
	local today = dayKey()
	if (LASTDAYKEY ~= today) then
		LASTDAYKEY = today
		for _, e in ipairs( LOG ) do
			e.played = false
		end
	end
end

--- Send due telegrams of the active playback. Called on every poll;
-- caught-up (previously skipped) telegrams are sent together within one
-- poll cycle once their time has been reached/passed.
local function tickPlayback()
	local pb = E.PVTable["PLAYBACK"]
	if (getNum( pb, "PLAYBACK_ACTIVE" ) == 0) then return end

	rolloverIfNewDay()

	local playbackType = getNum( pb, "PLAYBACK_TYPE" )   -- 0=Repeating, 1=Weekday
	local nowSec  = secondsOfDay()
	local nowWday = knxWeekdayFromSystem()

	for _, e in ipairs( LOG ) do
		if (not e.played) then
			local dueToday = (playbackType == 0) or (e.weekday == nowWday)
			if (dueToday and (nowSec >= e.secOfDay)) then
				local f = FUNCLIST[e.idx]
				if (f ~= nil) then
					setVal( f, ffield(f,"VALUE_OUT"), e.value, constValueChange )
					setVal( f, ffield(f,"LASTVALUE_TIME_OUT"), os.date( "%d.%m.%Y %H:%M:%S", os.time() ) )
					local fname = (f[ffield(f,"NAME")] ~= nil) and f[ffield(f,"NAME")]:GetValue() or ("#" .. tostring(e.idx))
					E:trace( "PresenceSimulation: playback sends function '" .. fname .. "' = " .. tostring(e.value) .. " (due " .. e.secOfDay .. "s, now " .. nowSec .. "s)." )
				else
					E:trace( "PresenceSimulation: WARNING - playback entry references unknown function #" .. tostring(e.idx) .. " (was the function list changed since recording?)." )
				end
				e.played = true
			end
		end
	end
end

-- ===========================================================================
-- JVP lifecycle
-- ===========================================================================

function Init()
	E:trace( "---- PresenceSimulation: Init ----" )
	CreateInstanceTable()

	local status = E.PVTable["STATUS"]
	local rec    = E.PVTable["RECORDING"]
	local pb     = E.PVTable["PLAYBACK"]
	if ((status == nil) or (rec == nil) or (pb == nil)) then
		E:trace( "PresenceSimulation: ERROR - folder 'STATUS'/'RECORDING'/'PLAYBACK' not found, check InterfaceDescription.xml." )
		return
	end
	setVal( rec, "RECORDING_ACTIVE", 0 )
	setVal( pb, "PLAYBACK_ACTIVE", 0 )
	setVal( pb, "PLAYBACK_DELAY_REMAINING", 0 )
	if (getNum( status, "CURRENT_WEEKDAY", 0 ) == 0) then
		setVal( status, "CURRENT_WEEKDAY", knxWeekdayFromSystem() )
		E:trace( "PresenceSimulation: CURRENT_WEEKDAY initialized to " .. knxWeekdayFromSystem() .. " (1=Monday...7=Sunday)." )
	end
	local nSel = updateSelectedCount()
	E:trace( "PresenceSimulation: " .. nSel .. " of max. " .. MAX_SELECTED .. " functions currently selected." )

	LASTDAYKEY = dayKey()
	LASTWEEKDAYCHECK = dayKey()

	-- Note: a telegram sequence "saved" by the original device no longer
	-- exists after an interface restart (RAM buffer only). A stale
	-- HAS_RECORDING="1" (kept only because SAVE="1" persists the last
	-- display value) would let the visualization still show/offer a
	-- playback group that actually has nothing to play - PlaybackStart()
	-- would then "succeed" (PLAYBACK_ACTIVE=1) while silently sending no
	-- telegrams at all, since LOG is empty. To avoid that misleading
	-- state, HAS_RECORDING/TELEGRAM_COUNT are reset together with LOG.
	LOG = {}
	if (getNum( rec, "HAS_RECORDING" ) == 1) then
		setVal( rec, "HAS_RECORDING", 0 )
		setVal( rec, "TELEGRAM_COUNT", 0 )
		E:trace( "PresenceSimulation: NOTE - a previously available recording was lost on restart (telegram buffer only lives in memory) - HAS_RECORDING reset to 0. Please start a new recording." )
	end
	E:trace( "---- PresenceSimulation: Init complete ----" )
end

function Exit()
	E:trace( "---- PresenceSimulation: Exit ----" )
	-- No cleanup needed: LOG lives only in RAM and is lost on restart /
	-- programming operation, as with the original panel.
end

function Poll()
	local status = E.PVTable["STATUS"]
	local rec    = E.PVTable["RECORDING"]
	local pb     = E.PVTable["PLAYBACK"]

	-- Monitor recording duration (automatic stop).
	if ((getNum( rec, "RECORDING_ACTIVE" ) == 1) and (RECORDINGENDEPOCH ~= nil)) then
		if (os.time() >= RECORDINGENDEPOCH) then
			E:trace( "PresenceSimulation: configured recording duration elapsed - recording stops automatically." )
			RecordingStop()
		end
	end

	-- Count down the playback start delay.
	if (PLAYBACKPENDING) then
		local remaining = (PLAYBACKPENDINGEPOCH or os.time()) - os.time()
		if (remaining <= 0) then
			BeginPlaybackNow()
		else
			setVal( pb, "PLAYBACK_DELAY_REMAINING", remaining )
		end
	end

	tickPlayback()

	-- Advance the weekday automatically once a day (unless set differently
	-- in the meantime via bus/operation).
	local today = dayKey()
	if (LASTWEEKDAYCHECK ~= today) then
		LASTWEEKDAYCHECK = today
		setVal( status, "CURRENT_WEEKDAY", knxWeekdayFromSystem() )
	end
end

function OnValueRead( oVarPath, nReason )
	local v = oVarPath:_getLeaf()
	if (nil == v) then return end
	local a = v:GetAccessRights()
	if ((a ~= constAccessRead) and (a ~= constAccessReadWrite)) then return end
	local val = v:GetValue()
	if (nil ~= val) then v:SetValue( val, constResponseFromCache ) end
end

--- Determine the enclosing function folder of a datapoint, regardless of
-- whether it is a binary or analog function.
-- @param oVarPath CPathObject
-- @return table|nil  Function folder
-- @return string|nil  "binary" / "analog"
local function findFunctionParent( oVarPath )
	local oFunc = oVarPath:_findParentFromUserType( "function_binary_t" )
	if (oFunc ~= nil) then return oFunc, "binary" end
	oFunc = oVarPath:_findParentFromUserType( "function_analog_t" )
	if (oFunc ~= nil) then return oFunc, "analog" end
	return nil, nil
end

function OnValueChange( oVarPath, strValue )
	local v = oVarPath:_getLeaf()
	if (nil == v) then
		E:trace( "PresenceSimulation: OnValueChange without a valid datapoint (path issue?), value='" .. tostring(strValue) .. "'." )
		return
	end
	local a = v:GetAccessRights()
	if ((a ~= constAccessReadWrite) and (a ~= constAccessWrite)) then
		E:trace( "PresenceSimulation: write attempt on read-only datapoint '" .. tostring(v:GetScriptName()) .. "' ignored." )
		return
	end

	local name = v:GetScriptName()

	-- -----------------------------------------------------------------
	-- Function / recording object (FUNCTION_BINARY[n] / FUNCTION_ANALOG[n])
	-- -----------------------------------------------------------------
	local oFunc, funcType = findFunctionParent( oVarPath )
	if (oFunc ~= nil) then

		-- 'name' is already the exact SCRIPTNAME of this instance (e.g.
		-- "VALUE_IN" for binary, "VALUE_IN_A" for analog) - so no ffield()
		-- is needed for the datapoint being changed itself, only for the
		-- SIBLING fields (NAME/SELECTED/LASTVALUE_TIME_IN/_OUT) of the
		-- same instance.
		local isValueIn  = (name == "VALUE_IN") or (name == "VALUE_IN_A")
		local isSelected = (name == "SELECTED") or (name == "SELECTED_A")

		if (isValueIn) then
			-- Incoming KNX telegram on the RECORDING INPUT of this function
			-- (linked to the group address to be recorded); the data
			-- format (binary/analog) already follows from the datapoint
			-- type itself - no extra DPTTYPE evaluation needed.
			v:SetValue( strValue, constWriteAck )
			local rec = E.PVTable["RECORDING"]
			local fname = (oFunc[ffield(oFunc,"NAME")] ~= nil) and oFunc[ffield(oFunc,"NAME")]:GetValue() or "?"
			if ((getNum( rec, "RECORDING_ACTIVE" ) == 1) and (getNum( oFunc, ffield(oFunc,"SELECTED") ) == 1)) then
				if (oFunc.FUNCINDEX ~= nil) then
					recordTelegram( oFunc.FUNCINDEX, parseNum(strValue, 0) )
					setVal( oFunc, ffield(oFunc,"LASTVALUE_TIME_IN"), os.date( "%d.%m.%Y %H:%M:%S", os.time() ) )
				else
					E:trace( "PresenceSimulation: WARNING - function '" .. fname .. "' (" .. tostring(funcType) .. ") has no FUNCINDEX, telegram is not recorded. Call CreateInstanceTable() again?" )
				end
			end
			return
		end

		if (isSelected) then
			local rec     = E.PVTable["RECORDING"]
			local wantOn  = (parseNum(strValue, 0) == 1)
			local fname   = (oFunc[ffield(oFunc,"NAME")] ~= nil) and oFunc[ffield(oFunc,"NAME")]:GetValue() or "?"

			if (getNum( rec, "RECORDING_ACTIVE" ) == 1) then
				-- Selection cannot be changed while a recording is active.
				v:SetValue( tostring(getNum(oFunc, name)), constWriteAck )
				E:trace( "PresenceSimulation: selecting '" .. fname .. "' is not possible while recording is active." )
				return
			end

			if (wantOn and (updateSelectedCount() >= MAX_SELECTED) and (getNum(oFunc, name) == 0)) then
				-- Maximum number of simultaneously selectable functions reached -> reject.
				v:SetValue( "0", constWriteAck )
				E:trace( "PresenceSimulation: selecting '" .. fname .. "' rejected - maximum " .. MAX_SELECTED .. " functions selectable at the same time." )
				return
			end

			v:SetValue( strValue, constWriteAck )
			local nSel = updateSelectedCount()
			E:trace( "PresenceSimulation: function '" .. fname .. "' (" .. tostring(funcType) .. ") " .. (wantOn and "selected" or "deselected") .. ", now " .. nSel .. "/" .. MAX_SELECTED .. " selected." )

			-- A changed and saved function selection invalidates an
			-- existing recording (see functional description).
			if (getNum( rec, "HAS_RECORDING" ) == 1) then
				PlaybackStop()
				LOG = {}
				setVal( rec, "HAS_RECORDING", 0 )
				setVal( rec, "TELEGRAM_COUNT", 0 )
				E:trace( "PresenceSimulation: function selection changed - previous recording deleted." )
			end
			return
		end

		-- NAME / NAME_A and VALUE_OUT / VALUE_OUT_A (playback output - the
		-- script itself drives this during playback via tickPlayback();
		-- any externally incoming write, e.g. bus feedback, is just
		-- acknowledged, it does not feed the recording): pass through
		-- unchanged.
		v:SetValue( strValue, constWriteAck )
		return
	end

	-- -----------------------------------------------------------------
	-- Recording folder (recording duration, start/stop buttons)
	-- -----------------------------------------------------------------
	if (oVarPath:_findParentFromUserType( "recording_t" ) ~= nil) then
		if (name == "RECORDING_LENGTH_DAYS") then
			local days = clamp( math.floor( parseNum(strValue, 1) ), 1, 7 )
			v:SetValue( tostring(days), constWriteAck )
			E:trace( "PresenceSimulation: recording length set to " .. days .. " day(s)." )
			return
		end
		if (name == "RECORDING_START_CMD") then
			v:SetValue( strValue, constWriteAck )
			if (parseNum(strValue, 0) == 1) then
				RecordingStart()
				v:SetValue( "0", constValueChange )   -- reset the button
			end
			return
		end
		if (name == "RECORDING_STOP_CMD") then
			v:SetValue( strValue, constWriteAck )
			if (parseNum(strValue, 0) == 1) then
				RecordingStop()
				v:SetValue( "0", constValueChange )   -- reset the button
			end
			return
		end
		v:SetValue( strValue, constWriteAck )
		return
	end

	-- -----------------------------------------------------------------
	-- Playback folder (playback type, start delay, start/stop)
	-- -----------------------------------------------------------------
	if (oVarPath:_findParentFromUserType( "playback_t" ) ~= nil) then
		if (name == "PLAYBACK_DELAY_HOURS") then
			local h = clamp( parseNum(strValue, 0), 0, 99 )
			v:SetValue( tostring(h), constWriteAck )
			E:trace( "PresenceSimulation: start delay set to " .. h .. " hour(s)." )
			return
		end
		if (name == "PLAYBACK_TYPE") then
			v:SetValue( strValue, constWriteAck )
			local isWeekday = (parseNum(strValue, 0) == 1)
			local typeLabel = isWeekday and "Weekday (time of day + weekday)" or "Repeating (time of day only)"
			E:trace( "PresenceSimulation: playback type set to " .. typeLabel .. "." )
			return
		end
		if (name == "PLAYBACK_STARTSTOP") then
			v:SetValue( strValue, constWriteAck )
			E:trace( "PresenceSimulation: PLAYBACK_STARTSTOP=" .. tostring(strValue) .. " received (button or 1-bit communication object)." )
			if (parseNum(strValue, 0) == 1) then PlaybackStart() else PlaybackStop() end
			return
		end
		v:SetValue( strValue, constWriteAck )
		return
	end

	-- -----------------------------------------------------------------
	-- Status / operating commands
	-- -----------------------------------------------------------------
	if (name == "CURRENT_WEEKDAY") then
		local wd = clamp( math.floor( parseNum(strValue, 1) ), 1, 7 )
		v:SetValue( tostring(wd), constWriteAck )
		E:trace( "PresenceSimulation: CURRENT_WEEKDAY manually set to " .. wd .. "." )
		return
	end

	if (name == "WEEKDAY_SYNC") then
		-- DPT 10.001: weekday field of a time telegram (0 = no weekday).
		v:SetValue( strValue, constWriteAck )
		local wd = parseNum(strValue, 0)
		if ((wd >= 1) and (wd <= 7)) then
			setVal( E.PVTable["STATUS"], "CURRENT_WEEKDAY", wd )
			E:trace( "PresenceSimulation: CURRENT_WEEKDAY set to " .. wd .. " via WEEKDAY_SYNC (DPT10.001)." )
		else
			E:trace( "PresenceSimulation: WEEKDAY_SYNC=" .. tostring(strValue) .. " outside 1..7 (0=no weekday) - CURRENT_WEEKDAY unchanged." )
		end
		return
	end

	E:trace( "PresenceSimulation: unknown/unhandled datapoint '" .. tostring(name) .. "' = " .. tostring(strValue) .. " (only acknowledged, no special logic)." )
	v:SetValue( strValue, constWriteAck )
end
