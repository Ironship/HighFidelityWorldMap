-------------------------------------------------------------------------------
-- High Fidelity World Map Forever — Bootstrap
-- Wires up events and hooks after all modules are loaded.
--
-- /hfwm             – toggle on / off
-- /hfwm on|off      – explicit enable / disable
-- /hfwm bg NAME     – map background: default | ocean | hybrid
-- /hfwm options     – open the options panel
-- /hfwm alpha 0-1   – set overlay opacity
-- /hfwm cave        – the cave map window (on|off|show|hide|reset|alpha N)
-- /hfwm remember    – remember world map zoom+pan across close/reopen
-- /hfwm zoom        – additional (closer) world map zoom levels
-- /hfwm clarity     – higher-detail Kalimdor/Eastern Kingdoms/Azeroth maps
--                     (off by default; may render slower)
-- /hfwm debug       – print diagnostic info for current map
-------------------------------------------------------------------------------
local addonName, ns = ...

local Config      = ns.Config
local BaseArt     = ns.BaseArt
local Exploration = ns.Exploration
local Renderer    = ns.Renderer
local Commands    = ns.Commands
local Options     = ns.Options
local Cave        = ns.Cave
local CaveRenderer = ns.CaveRenderer
local MapMemory   = ns.MapMemory
local ZoomLevels  = ns.ZoomLevels
local P           = ns.P

-------------------------------------------------------------------------------
-- Bootstrap
-------------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")

loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        Config:InitDB()

    elseif event == "PLAYER_LOGIN" then
        self:UnregisterAllEvents()
        -- Fog of War's own reveal (see Renderer's DrawExploredPiece) needs
        -- to hear about newly-explored ground while the map is already
        -- open, not just whenever something else happens to trigger a
        -- refresh — registered unconditionally rather than only while the
        -- feature is on, since the handler below is what actually checks
        -- that, and toggling a single event registration on and off with
        -- it would be no cheaper.
        self:RegisterEvent("MAP_EXPLORATION_UPDATED")

        local canvas = WorldMapFrame.ScrollContainer.Child
        Config.overlayFrame = CreateFrame(
            "Frame", "HFWMForeverOverlay", canvas)
        Config.overlayFrame:SetAllPoints(canvas)
        Config.overlayFrame:SetFrameLevel(canvas:GetFrameLevel() + 500)
        Config.overlayFrame:EnableMouse(false)

        -- The cave map window is built lazily by CaveRenderer the first time
        -- a cave is entered, and is parented to WorldMapFrame rather than to
        -- the canvas so that it does not pan or zoom with the map under it.

        hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
            Config.lastMapID = nil
            Renderer:Refresh(true)
            Cave:UpdateState()
        end)

        if MapCanvasDetailLayerMixin
           and MapCanvasDetailLayerMixin.RefreshDetailTiles then
            hooksecurefunc(
                MapCanvasDetailLayerMixin, "RefreshDetailTiles", function()
                    Cave:UpdateState()
                end)
        end

        WorldMapFrame:HookScript("OnShow", function()
            Config.lastMapID = nil
            Renderer:Refresh(true)
            Cave:UpdateState()
        end)

        Config.overlayFrame:SetScript("OnSizeChanged", function()
            Renderer:ScheduleRefresh()
        end)

        -- The cave window is sized as a fraction of the map frame, so it has
        -- to be re-laid-out when the map is maximised or restored.
        WorldMapFrame:HookScript("OnSizeChanged", function()
            CaveRenderer:Relayout()
        end)

        Cave:Start()
        MapMemory:Start()
        ZoomLevels:Start()

        Commands:Register()
        -- After Commands, so a Lua error while probing the client's options
        -- APIs still leaves the slash commands working.
        Options:Init()
        P("loaded — /hfwm to toggle, /hfwm options for settings")

    elseif event == "MAP_EXPLORATION_UPDATED" then
        -- Only meaningful while Fog of War is on and the map is actually
        -- open: exploration state is the only thing Renderer draws that
        -- depends on it at all, so without both checks this would be a
        -- full Refresh on every step the player takes, map open or not,
        -- for no visible reason.
        if Config:FogOfWarEnabled() and WorldMapFrame:IsShown() then
            Renderer:Refresh(true)
        end
    end
end)
