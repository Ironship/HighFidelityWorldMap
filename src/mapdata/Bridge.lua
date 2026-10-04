-------------------------------------------------------------------------------
-- HFWM-Forever MapData Bridge
--
-- Runtime marker exported only when HighFidelityWorldMap_MapData_Forever is
-- enabled and loaded. The core addon checks for this before using bundled
-- texture paths, so disabling this addon in-game actually disables mapdata.
-------------------------------------------------------------------------------
local ADDON_NAME = "HighFidelityWorldMap_MapData_Forever"
local BUILD_KEY  = "X-HFWM-Data-Build"

local getter = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local build = getter and getter(ADDON_NAME, BUILD_KEY) or ""

HFWMF_MAPDATA_BRIDGE = {
    api   = 1,
    addon = ADDON_NAME,
    build = build or "",
}
