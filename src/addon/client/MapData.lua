-------------------------------------------------------------------------------
-- HFWM-Forever MapData
--
-- The continent and world map art is not part of this addon. It ships as the
-- separate HighFidelityWorldMap_MapData_Forever addon (see Config.FDID_BASE),
-- so a UI or settings update does not mean re-downloading gigabytes of tiles,
-- and the art can be released on its own schedule. Zone and cave maps are not
-- shipped as art at all: the data addon only says where the client's own
-- minimap tiles go (MinimapTiles.lua, CaveTiles.lua).
--
-- The lookup tables (FDIDMap.lua: the HFWMF_FDID_MAP* and HFWMF_NATIVE_ZONES*
-- globals that Config.lua reads, plus the two placement files above) ship in
-- the data addon too, so tables and tiles always come from the same build.
-- What can still go wrong is the data addon being missing (continent maps show
-- a green placeholder, zones nothing), disabled, or not exporting its runtime
-- bridge. This module turns those into one chat line at login.
--
-- The data addon's build is the `X-HFWM-Data-Build` line in its TOC, and
-- HFWMF_DATA_BUILD in its FDIDMap.lua is stamped with the same generator
-- hash. Either one missing means a local/dev build, where there is nothing
-- meaningful to compare, so that check is skipped.
-------------------------------------------------------------------------------
local addonName, ns = ...
local MapData = ns.MapData
local P       = ns.P

local DATA_ADDON = "HighFidelityWorldMap_MapData_Forever"
local BUILD_KEY  = "X-HFWM-Data-Build"
local BRIDGE_KEY = "HFWMF_MAPDATA_BRIDGE"
local BRIDGE_API = 1

MapData.ADDON_NAME = DATA_ADDON

local function GetMetadata(name, field)
    local getter = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if not getter then return nil end
    return getter(name, field)
end

local function IsAddOnLoaded_(name)
    local fn = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    return fn and fn(name) and true or false
end

--- Whether the data addon is installed (enabled or not). A TOC the client
--- has read always has a Title, so that is the probe: it answers for a
--- disabled addon too, which a loaded check would not.
function MapData:IsInstalled()
    local exists = C_AddOns and C_AddOns.DoesAddOnExist
    if exists then return exists(DATA_ADDON) and true or false end
    return GetMetadata(DATA_ADDON, "Title") ~= nil
end

function MapData:IsLoaded()
    return IsAddOnLoaded_(DATA_ADDON)
end

--- Runtime handshake table exported by the data addon when it is loaded.
---@return table|nil
function MapData:GetBridge()
    local bridge = _G and _G[BRIDGE_KEY]
    if type(bridge) ~= "table" then return nil end
    if bridge.api ~= BRIDGE_API then return nil end
    if bridge.addon ~= DATA_ADDON then return nil end
    return bridge
end

--- Whether mapdata is usable right now for bundled texture replacement.
--- Requires the addon to be loaded (enabled), plus a matching bridge.
---@return boolean
function MapData:IsRuntimeReady()
    return self:IsLoaded() and self:GetBridge() ~= nil
end

--- The generator build the installed data addon was made from, or nil when
--- it is not installed or carries no stamp (a dev build).
function MapData:GetBuild()
    local build = GetMetadata(DATA_ADDON, BUILD_KEY)
    if build == nil or build == "" then return nil end
    return build
end

--- The generator build the loaded FDIDMap.lua (from the data addon) was made
--- from, or nil for a dev build.
function MapData:GetExpectedBuild()
    local build = HFWMF_DATA_BUILD
    if build == nil or build == "" then return nil end
    return build
end

--- A short human description for /hfwm debug.
function MapData:Describe()
    if not self:IsInstalled() then
        return "NOT INSTALLED (" .. DATA_ADDON .. ")"
    end
    local have, want = self:GetBuild(), self:GetExpectedBuild()
    local bridge = self:GetBridge()
    local state
    if not self:IsLoaded() then
        state = "installed, not loaded"
    elseif not bridge then
        state = "loaded, bridge missing"
    else
        state = "loaded, bridge ok"
    end
    local match
    if not have or not want then
        match = "build not stamped (dev build), check skipped"
    elseif have == want then
        match = "build " .. have .. " matches"
    else
        match = ("build %s <-- this addon expects %s"):format(have, want)
    end
    return state .. ", " .. match
end

--- One-time chat warning. Called from Core.lua's OnEnable, which fires once
--- per session, so no extra bookkeeping is needed to keep it to one line.
---@return boolean ok  false when a warning was printed
function MapData:Check()
    if not self:IsInstalled() then
        P("|cffff8800Map Data addon not found.|r The world map will show "
            .. "missing textures until " .. DATA_ADDON .. " is installed.")
        return false
    end

    if not self:IsLoaded() then
        P("|cffff8800Map Data addon is installed but disabled.|r Enable "
            .. DATA_ADDON .. " to use High Fidelity World Map textures.")
        return false
    end

    if not self:GetBridge() then
        P("|cffff8800Map Data runtime bridge missing.|r "
            .. DATA_ADDON .. " is loaded but did not export " .. BRIDGE_KEY
            .. "; bundled textures are disabled.")
        return false
    end

    local have, want = self:GetBuild(), self:GetExpectedBuild()
    if have and want and have ~= want then
        P("|cffff8800Map Data is out of date or ahead of this addon|r (data "
            .. have .. ", expected " .. want .. "). Update High Fidelity "
            .. "World Map and " .. DATA_ADDON .. " to the latest versions; "
            .. "some map tiles may be missing until you do.")
        return false
    end
    return true
end
