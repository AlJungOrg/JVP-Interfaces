-------------------------------------------------------------------------------
-- InterfaceScriptCommonLibrary.lua
--
-- Shared helpers for JUNG Visu Pro (JVP) interface scripts:
--   * CPathObject - navigate the process-model tree (E.PVTable) by a path and
--     locate nodes, the leaf datapoint, or the nearest parent of a USERTYPE.
--   * GetPathObject(path) - convenience constructor for a CPathObject.
--   * Global constants for value-change reasons and access rights.
--
-- Target runtime: Lua 5.1 (JVP). Keep this file 5.1-compatible.
-------------------------------------------------------------------------------

-- @module InterfaceScriptCommonLibrary

CPathObject = {}

--- Create a new path object.
-- @return CPathObject
function CPathObject:new()
	local tblInstance = { m_nCurrentLevel = 0, m_nLevels = 0, m_aVarLevel = {} }
	setmetatable( tblInstance, self )
	self.__index = self
	return tblInstance
end

--- Parse a variable path into per-level nodes, starting at E.PVTable.
-- @param strPath string  Whitespace/word path, e.g. "Channel 1 FAN".
function CPathObject:_setPath( strPath )
	local i = 0
	self.m_aVarLevel[0] = E.PVTable
	for w in string.gmatch( strPath, "[%w_%s]+" ) do
		i = i + 1
		local wNumber = tonumber( w, 10 )
		if (nil == wNumber) then
			self.m_aVarLevel[i] = self.m_aVarLevel[i-1][w]
		else
			self.m_aVarLevel[i] = self.m_aVarLevel[i-1][wNumber]
		end
	end
	self.m_nLevels = i
	self.m_nCurrentLevel = i
end

--- @return number  Number of levels in the parsed path.
function CPathObject:_getLevels()
	return self.m_nLevels
end

--- Move to the leaf level and return the leaf node.
-- @return table|nil
function CPathObject:_toLeaf()
	self.m_nCurrentLevel = self.m_nLevels
	return self.m_aVarLevel[self.m_nCurrentLevel]
end

--- @return table|nil  The leaf node (the addressed datapoint).
function CPathObject:_getLeaf()
	return self.m_aVarLevel[self.m_nLevels]
end

--- Move one level up (towards the root) and return that node.
-- @return table|nil
function CPathObject:_levelUp()
	if (self.m_nCurrentLevel > 0) then
		self.m_nCurrentLevel = self.m_nCurrentLevel - 1
		return self.m_aVarLevel[self.m_nCurrentLevel]
	end
	return nil
end

--- Walk up from the leaf to the nearest folder of the given USERTYPE.
-- @param usertype string  E_UserType to look for (e.g. "channel_t").
-- @return table|nil  The matching folder, or nil.
function CPathObject:_findParentFromUserType( usertype )
	local oNode = self:_toLeaf()
	if (nil == oNode) then
		return nil
	end
	repeat
		if (type(oNode) == "table") and (oNode.E_Type == "e_pvFolder") and (usertype == oNode.E_UserType) then
			return oNode
		end
		oNode = self:_levelUp()
	until (nil == oNode)
	return nil
end

--- Convenience: build a CPathObject for a variable path.
-- @param strVarPath string
-- @return CPathObject
function GetPathObject( strVarPath )
	local oVarPath = CPathObject:new()
	oVarPath:_setPath( strVarPath )
	return oVarPath
end

-------------------------------------------------------------------------------
-- Global constants
-------------------------------------------------------------------------------

-- Reasons for a value report to the process model
constValueChange         = 1   -- report a value change
constResponse            = 2   -- response to a query
constResponseFromCache   = 3   -- response to a query, value taken from cache
constWriteAck            = 4   -- acknowledge for a write command

-- Reasons for a value request from the process model
constValueRead           = 1   -- generic value query
constWriteReadCmd        = 2   -- explicit read command to the process
constGetUpdate           = 3   -- variable initialization after process-model start

-- Access rights configured by the user in the device editor
constAccessNone          = 0   -- none
constAccessRead          = 1   -- read only
constAccessWrite         = 2   -- write only
constAccessReadWrite     = 3   -- read and write
