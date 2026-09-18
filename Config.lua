-------------------------------------------------------------------------------
-- HFWM-Forever Config
-- Defaults, SavedVariables init, and overlay state tracking.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config = ns.Config

-- Defaults (persisted in HighFidelityWorldMapForeverDB)
Config.DEFAULTS = {
    enabled     = true,
    alpha       = 1.0,
    caveEnabled = false,  -- cave overlay is opt-in; enable with /hfwm cave on
}

-- FileDataID lookup tables (populated from FDIDMap.lua)
Config.FDID_MAP     = HFWMF_FDID_MAP     or {}
Config.FDID_MAP_SUB = HFWMF_FDID_MAP_SUB or {}
Config.FDID_BASE    = "Interface\\AddOns\\HighFidelityWorldMapForever\\WorldMap\\"

-- Vashj'ir UiMapIDs — retail-only (Cataclysm). WoW Forever has no Vashj'ir,
-- so this is intentionally empty. Kept so that Renderer.lua stays
-- structurally identical to the retail addon.
Config.VASHJIR_MAPS = {}

-- Runtime state (shared mutable, referenced by all modules)
Config.db              = nil   -- ref to HighFidelityWorldMapForeverDB after ADDON_LOADED
Config.overlayFrame    = nil   -- Frame parented to the map canvas
Config.overlayActive   = false
Config.refreshPending  = false
Config.lastCanvasW     = 0
Config.lastCanvasH     = 0
Config.lastMapID       = nil
Config.lastLayerIdx    = nil
Config.lastSubmerged   = nil
Config.tracing         = false

-- Cave overlay state
Config.caveOverlayFrame    = nil   -- separate Frame parented to map canvas
Config.caveOverlayActive   = false
Config.caveCurrentFloorMapID = nil
Config.caveAllFloors       = nil   -- [{mapID, name, relativeHeightIndex}, ...]
Config.caveDisplayedMapID  = nil   -- the world-map UiMapID currently displayed (for change detection)
Config.lastPlayerMapID     = nil   -- C_Map.GetBestMapForUnit("player") cache for change detection
Config.caveAlpha           = 0.92  -- transparency of the whole cave overlay frame

-- Cache FDID_MAP size for diagnostics
do
    local n = 0
    for _ in pairs(Config.FDID_MAP) do n = n + 1 end
    Config._fdidMapSize = n
end

--- Initialise SavedVariables after ADDON_LOADED.
function Config:InitDB()
    if type(HighFidelityWorldMapForeverDB) ~= "table" then
        HighFidelityWorldMapForeverDB = {}
    end
    for k, v in pairs(self.DEFAULTS) do
        if HighFidelityWorldMapForeverDB[k] == nil then
            HighFidelityWorldMapForeverDB[k] = v
        end
    end
    self.db = HighFidelityWorldMapForeverDB
end
