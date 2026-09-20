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

        Commands:Register()
        -- After Commands, so a Lua error while probing the client's options
        -- APIs still leaves the slash commands working.
        Options:Init()
        P("loaded — /hfwm to toggle, /hfwm options for settings")
    end
end)
