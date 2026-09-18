-------------------------------------------------------------------------------
-- High Fidelity World Map Forever — Bootstrap
-- Wires up events and hooks after all modules are loaded.
--
-- /hfwmf             – toggle on / off
-- /hfwmf on|off      – explicit enable / disable
-- /hfwmf alpha 0-1   – set overlay opacity
-- /hfwmf debug       – print diagnostic info for current map
-------------------------------------------------------------------------------
local addonName, ns = ...

local Config      = ns.Config
local BaseArt     = ns.BaseArt
local Exploration = ns.Exploration
local Renderer    = ns.Renderer
local Commands    = ns.Commands
local Cave        = ns.Cave
local CaveRenderer = ns.CaveRenderer
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

        -- Cave overlay frame: separate, slightly transparent layer above
        -- the main HFWM overlay. Hidden by default; CaveRenderer shows it
        -- when the player enters a cave / micro dungeon / dungeon instance.
        Config.caveOverlayFrame = CreateFrame(
            "Frame", "HFWMForeverCaveOverlay", canvas)
        Config.caveOverlayFrame:SetAllPoints(canvas)
        Config.caveOverlayFrame:SetFrameLevel(canvas:GetFrameLevel() + 600)
        Config.caveOverlayFrame:EnableMouse(false)
        Config.caveOverlayFrame:Hide()

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

        Config.caveOverlayFrame:SetScript("OnSizeChanged", function()
            if Config.caveOverlayActive and Config.caveCurrentFloorMapID then
                CaveRenderer:ShowCave(Config.caveCurrentFloorMapID)
            end
        end)

        Cave:Start()

        Commands:Register()
        P("loaded — /hfwmf to toggle")
    end
end)
