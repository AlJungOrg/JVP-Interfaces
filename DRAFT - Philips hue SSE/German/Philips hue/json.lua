-------------------------------------------------------------------------------
-- json.lua
-- @module json
--
-- Minimal, dependency-free JSON encoder/decoder for Lua 5.1 (JVP runtime).
-- Not shipped by the jvp-lua-interface skill template, written here because
-- the Philips Hue local API (v1 and v2) exchanges JSON bodies.
--
-- Supported: objects, arrays, strings (with escapes/unicode \uXXXX), numbers,
-- true/false/null. Arrays are Lua tables with contiguous integer keys 1..n;
-- everything else encodes as a JSON object. An empty Lua table encodes as
-- the empty JSON object "{}" (Hue never requires an empty array as a body).
-------------------------------------------------------------------------------

local json = {}

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local escapeMap = {
	["\\"] = "\\\\", ["\""] = "\\\"", ["\n"] = "\\n", ["\r"] = "\\r",
	["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}

local function encodeString( s )
	local out = s:gsub( "[\\\"\n\r\t\b\f]", escapeMap )
	out = out:gsub( "%c", function( c ) return string.format( "\\u%04x", c:byte() ) end )
	return "\"" .. out .. "\""
end

local function isArray( t )
	local n = 0
	for k, _ in pairs( t ) do
		if (type(k) ~= "number") or (k < 1) or (math.floor(k) ~= k) then return false end
		n = n + 1
	end
	for i = 1, n do
		if (t[i] == nil) then return false end
	end
	return true, n
end

local encodeValue -- fwd decl

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
	local tv = type(v)
	if (tv == "string") then return encodeString( v ) end
	if (tv == "number") then
		if (v ~= v) or (v == math.huge) or (v == -math.huge) then return "0" end
		return tostring(v)
	end
	if (tv == "boolean") then return v and "true" or "false" end
	if (tv == "table") then
		local ok, n = isArray( v )
		if (ok) then
			if (n == 0) then return "{}" end
			return encodeArray( v, n )
		end
		return encodeObject( v )
	end
	return "null"
end

--- Encode a Lua value (table/string/number/boolean/nil) as a JSON string.
-- @param v any
-- @return string
function json.encode( v )
	if (v == nil) then return "null" end
	return encodeValue( v )
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local function skipWhitespace( s, i )
	local _, j = s:find( "^%s*", i )
	return (j or (i - 1)) + 1
end

local decodeValue -- fwd decl

local function decodeError( msg, s, i )
	error( "json.decode: " .. msg .. " at position " .. tostring(i) .. " (" .. tostring( s:sub(i, i + 10) ) .. ")" )
end

local function decodeString( s, i )
	-- s:sub(i,i) == '"'
	local j = i + 1
	local out = {}
	while true do
		local c = s:sub( j, j )
		if (c == "") then decodeError( "unterminated string", s, i ) end
		if (c == "\"") then
			return table.concat( out ), j + 1
		elseif (c == "\\") then
			local e = s:sub( j + 1, j + 1 )
			if (e == "u") then
				local hex = s:sub( j + 2, j + 5 )
				local code = tonumber( hex, 16 ) or 63
				if (code < 0x80) then
					out[#out + 1] = string.char( code )
				elseif (code < 0x800) then
					out[#out + 1] = string.char( 0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40) )
				else
					out[#out + 1] = string.char(
						0xE0 + math.floor(code / 0x1000),
						0x80 + (math.floor(code / 0x40) % 0x40),
						0x80 + (code % 0x40) )
				end
				j = j + 6
			else
				local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["\""] = "\"", ["\\"] = "\\", ["/"] = "/" }
				out[#out + 1] = map[e] or e
				j = j + 2
			end
		else
			out[#out + 1] = c
			j = j + 1
		end
	end
end

local function decodeNumber( s, i )
	local _, j, num = s:find( "^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)", i )
	if (num == nil) then decodeError( "invalid number", s, i ) end
	return tonumber( num ), j + 1
end

local function decodeArray( s, i )
	local t = {}
	local n = 0
	i = skipWhitespace( s, i + 1 )
	if (s:sub( i, i ) == "]") then return t, i + 1 end
	while true do
		local v
		v, i = decodeValue( s, i )
		n = n + 1
		t[n] = v
		i = skipWhitespace( s, i )
		local c = s:sub( i, i )
		if (c == ",") then
			i = skipWhitespace( s, i + 1 )
		elseif (c == "]") then
			return t, i + 1
		else
			decodeError( "expected ',' or ']' in array", s, i )
		end
	end
end

local function decodeObject( s, i )
	local t = {}
	i = skipWhitespace( s, i + 1 )
	if (s:sub( i, i ) == "}") then return t, i + 1 end
	while true do
		i = skipWhitespace( s, i )
		if (s:sub( i, i ) ~= "\"") then decodeError( "expected string key", s, i ) end
		local key
		key, i = decodeString( s, i )
		i = skipWhitespace( s, i )
		if (s:sub( i, i ) ~= ":") then decodeError( "expected ':'", s, i ) end
		i = skipWhitespace( s, i + 1 )
		local v
		v, i = decodeValue( s, i )
		t[key] = v
		i = skipWhitespace( s, i )
		local c = s:sub( i, i )
		if (c == ",") then
			i = skipWhitespace( s, i + 1 )
		elseif (c == "}") then
			return t, i + 1
		else
			decodeError( "expected ',' or '}' in object", s, i )
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
	if (s:sub( i, i + 3 ) == "null") then return nil, i + 4 end
	if (c == "-") or (c:match( "%d" ) ~= nil) then return decodeNumber( s, i ) end
	decodeError( "unexpected token", s, i )
end

--- Decode a JSON string into a Lua value (table/string/number/boolean/nil).
-- Raises a Lua error() on malformed input - wrap calls in pcall().
-- @param s string
-- @return any
function json.decode( s )
	if (s == nil) or (s == "") then return nil end
	local v = decodeValue( s, 1 )
	return v
end

return json
