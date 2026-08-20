-------------------------------------------------------------------------------
-- json.lua
-- @module json
--
-- Minimal, dependency-free JSON encoder/decoder for Lua 5.1 (JVP runtime).
-- Supports objects, arrays, strings, numbers, booleans and null. Written for
-- the JUNGHOME_Gateway interface to talk to the api-junghome REST API.
-- Target runtime: Lua 5.1. Keep this file 5.1-compatible.
-------------------------------------------------------------------------------

local json = {}

--- Sentinel value representing JSON null (decode only; encode treats Lua nil
-- inside arrays/objects the same way).
json.null = setmetatable( {}, { __tostring = function() return "null" end } )

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local escapeMap = {
	[ "\\" ] = "\\\\", [ "\"" ] = "\\\"", [ "\b" ] = "\\b", [ "\f" ] = "\\f",
	[ "\n" ] = "\\n",  [ "\r" ] = "\\r",  [ "\t" ] = "\\t",
}

local function encodeString( s )
	local out = s:gsub( "[%z\1-\31\\\"]", function( c )
		return escapeMap[ c ] or string.format( "\\u%04x", string.byte( c ) )
	end )
	return "\"" .. out .. "\""
end

--- Test whether a table is a JSON-array (dense 1..n numeric keys).
local function isArray( t )
	local n = 0
	for k, _ in pairs( t ) do
		if (type(k) ~= "number") then return false, 0 end
		n = n + 1
	end
	for i = 1, n do
		if (t[i] == nil) then return false, 0 end
	end
	return true, n
end

local encodeValue -- forward declaration

local function encodeArray( t, n )
	local parts = {}
	for i = 1, n do
		parts[i] = encodeValue( t[i] )
	end
	return "[" .. table.concat( parts, "," ) .. "]"
end

local function encodeObject( t )
	local parts = {}
	local i = 0
	for k, v in pairs( t ) do
		i = i + 1
		parts[i] = encodeString( tostring(k) ) .. ":" .. encodeValue( v )
	end
	return "{" .. table.concat( parts, "," ) .. "}"
end

encodeValue = function( v )
	if (v == json.null) then return "null" end
	local tv = type( v )
	if (tv == "nil") then return "null" end
	if (tv == "boolean") then return tostring( v ) end
	if (tv == "number") then return tostring( v ) end
	if (tv == "string") then return encodeString( v ) end
	if (tv == "table") then
		local bArr, n = isArray( v )
		if (bArr) then
			if (n == 0) then return "{}" end -- empty table -> empty object (JVP config style)
			return encodeArray( v, n )
		end
		return encodeObject( v )
	end
	return "null"
end

--- Encode a Lua value as a JSON string.
-- @param value any
-- @return string
function json.encode( value )
	return encodeValue( value )
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local decodeValue -- forward declaration

local function skipWhitespace( s, i )
	local _, j = s:find( "^[ \t\r\n]*", i )
	return j + 1
end

local function decodeError( s, i, msg )
	error( "json.lua: " .. msg .. " at position " .. tostring(i) )
end

local unescapeMap = {
	[ "\\" ] = "\\", [ "\"" ] = "\"", [ "/" ] = "/", [ "b" ] = "\b",
	[ "f" ] = "\f",  [ "n" ] = "\n",  [ "r" ] = "\r", [ "t" ] = "\t",
}

local function decodeString( s, i )
	local j = i + 1
	local out = {}
	while true do
		local c = s:sub( j, j )
		if (c == "") then decodeError( s, j, "unterminated string" ) end
		if (c == "\"") then return table.concat( out ), j + 1 end
		if (c == "\\") then
			local nc = s:sub( j + 1, j + 1 )
			if (nc == "u") then
				local hex = s:sub( j + 2, j + 5 )
				local code = tonumber( hex, 16 ) or 63
				if (code < 128) then
					out[ #out + 1 ] = string.char( code )
				else
					out[ #out + 1 ] = "?" -- Lua 5.1 has no native utf8 lib; ASCII fallback
				end
				j = j + 6
			else
				out[ #out + 1 ] = unescapeMap[ nc ] or nc
				j = j + 2
			end
		else
			out[ #out + 1 ] = c
			j = j + 1
		end
	end
end

local function decodeNumber( s, i )
	local numStr = s:match( "^-?%d+%.?%d*[eE]?[-+]?%d*", i )
	if ((numStr == nil) or (numStr == "")) then decodeError( s, i, "invalid number" ) end
	return tonumber( numStr ), i + #numStr
end

local function decodeArray( s, i )
	local out = {}
	local n = 0
	i = skipWhitespace( s, i + 1 )
	if (s:sub( i, i ) == "]") then return out, i + 1 end
	while true do
		local v
		v, i = decodeValue( s, i )
		n = n + 1
		out[ n ] = v
		i = skipWhitespace( s, i )
		local c = s:sub( i, i )
		if (c == ",") then
			i = skipWhitespace( s, i + 1 )
		elseif (c == "]") then
			return out, i + 1
		else
			decodeError( s, i, "expected ',' or ']'" )
		end
	end
end

local function decodeObject( s, i )
	local out = {}
	i = skipWhitespace( s, i + 1 )
	if (s:sub( i, i ) == "}") then return out, i + 1 end
	while true do
		if (s:sub( i, i ) ~= "\"") then decodeError( s, i, "expected string key" ) end
		local k
		k, i = decodeString( s, i )
		i = skipWhitespace( s, i )
		if (s:sub( i, i ) ~= ":") then decodeError( s, i, "expected ':'" ) end
		i = skipWhitespace( s, i + 1 )
		local v
		v, i = decodeValue( s, i )
		out[ k ] = v
		i = skipWhitespace( s, i )
		local c = s:sub( i, i )
		if (c == ",") then
			i = skipWhitespace( s, i + 1 )
		elseif (c == "}") then
			return out, i + 1
		else
			decodeError( s, i, "expected ',' or '}'" )
		end
	end
end

decodeValue = function( s, i )
	i = skipWhitespace( s, i )
	local c = s:sub( i, i )
	if (c == "\"") then return decodeString( s, i ) end
	if (c == "{") then return decodeObject( s, i ) end
	if (c == "[") then return decodeArray( s, i ) end
	if (s:sub( i, i + 3 ) == "true") then return true, i + 4 end
	if (s:sub( i, i + 4 ) == "false") then return false, i + 5 end
	if (s:sub( i, i + 3 ) == "null") then return json.null, i + 4 end
	if (c:match( "[%-%d]" )) then return decodeNumber( s, i ) end
	decodeError( s, i, "unexpected character '" .. c .. "'" )
end

--- Decode a JSON string into a Lua value.
-- @param str string
-- @return any value (nil on failure), string|nil error
function json.decode( str )
	if ((str == nil) or (str == "")) then return nil, "empty input" end
	local ok, value = pcall( function()
		local v = decodeValue( str, 1 )
		return v
	end )
	if (not ok) then return nil, tostring( value ) end
	return value, nil
end

return json
