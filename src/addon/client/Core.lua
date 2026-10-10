-------------------------------------------------------------------------------
-- High Fidelity World Map -- Bootstrap
-- Wires up events and hooks once Ace3 initializes the addon.
--
-- /hfwm             - toggle on / off
-- /hfwm on|off      - explicit enable / disable
-- /hfwm bg NAME     - map background: default | ocean | hybrid
-- /hfwm options     - open the options panel
-- /hfwm cave        - the cave map window (on|off|show|hide|reset|alpha N)
-- /hfwm remember    - remember world map zoom+pan across close/reopen
-- /hfwm zoom        - additional (closer) world map zoom levels
-- /hfwm clarity     - higher-detail Kalimdor/Eastern Kingdoms/Azeroth maps
--                     (off by default; may render slower)
-- /hfwm debug       - print diagnostic info for current map
-------------------------------------------------------------------------------
local addonName, ns = ...
local addon = ns.addon

local Config       = ns.Config
local Renderer      = ns.Renderer
local Commands      = ns.Commands
local Options       = ns.Options
local Cave          = ns.Cave
local CaveRenderer  = ns.CaveRenderer
local MapMemory     = ns.MapMemory
local ZoomLevels    = ns.ZoomLevels
local ResetView     = ns.ResetView
local ToggleButton  = ns.ToggleButton
local P             = ns.P

--- Fires once, right after SavedVariables load. Same timing ADDON_LOADED
--- used to mark.
function addon:OnInitialize()
    Config:InitDB()
end

--- Fires at PLAYER_LOGIN, once every addon has initialized. Same timing
--- PLAYER_LOGIN used to mark.
function addon:OnEnable()
    self:RegisterEvent("MAP_EXPLORATION_UPDATED")

    local canvas = WorldMapFrame.ScrollContainer.Child
    Config.overlayFrame = CreateFrame(
        "Frame", "HFWMForeverOverlay", canvas)
    Config.overlayFrame:SetAllPoints(canvas)
    Config.overlayFrame:SetFrameLevel(canvas:GetFrameLevel() + 500)
    Config.overlayFrame:EnableMouse(false)

    -- The cave map window is built lazily by CaveRenderer the first time a
    -- cave is entered, parented to WorldMapFrame rather than the canvas so
    -- it doesn't pan or zoom with the map under it.

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

    -- The cave window is sized as a fraction of the map frame, so it needs
    -- relayout whenever the map is maximised or restored.
    WorldMapFrame:HookScript("OnSizeChanged", function()
        CaveRenderer:Relayout()
    end)

    Cave:Start()
    MapMemory:Start()
    ZoomLevels:Start()
    ResetView:Start()
    ToggleButton:Start()

    Commands:Register()
    -- After Commands, so a Lua error while probing the client's options
    -- APIs still leaves the slash commands working.
    Options:Init()
    P("Loaded. /hfwm to toggle, /hfwm options for settings.")
end

--- Fog of War's own reveal (Renderer's DrawExploredPiece) needs to hear
--- about newly-explored ground while the map is open. Only meaningful
--- while Fog of War is on and the map is shown; both checks avoid a full
--- Refresh on every step the player takes.
function addon:MAP_EXPLORATION_UPDATED()
    if Config:FogOfWarEnabled() and WorldMapFrame:IsShown() then
        Renderer:Refresh(true)
    end
end
