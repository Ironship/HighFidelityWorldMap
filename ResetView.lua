-------------------------------------------------------------------------------
-- HFWM-Forever Reset View
--
-- Shift+right-click anywhere on the world map snaps the view back to the
-- zone the player is actually standing in, fully zoomed out and centered --
-- the same view you'd get from freshly opening the map, undoing any
-- drilling into subzones/dungeons or panning/zooming elsewhere. A plain
-- right-click is left alone (whatever Blizzard's own OnMouseUp on the
-- ScrollContainer already does with it); this only adds a second script
-- onto that same event, gated on the shift modifier so it can never fire
-- by accident, via HookScript rather than SetScript so nothing already
-- wired up there is replaced.
-------------------------------------------------------------------------------
local addonName, ns = ...
local ResetView = ns.ResetView

local WorldMapFrame  = _G.WorldMapFrame
local IsShiftKeyDown = _G.IsShiftKeyDown
local C_Map          = _G.C_Map

--- Snap the map back to the player's current zone, fully zoomed out and
--- centered.
local function ResetToCurrentZone()
    local bestMapID = C_Map.GetBestMapForUnit("player")
    if not bestMapID then return end

    if WorldMapFrame:GetMapID() ~= bestMapID then
        pcall(WorldMapFrame.SetMapID, WorldMapFrame, bestMapID)
    end

    local sc = WorldMapFrame.ScrollContainer
    if not sc then return end

    -- zoomLevels[1] is always the loosest (fit-to-frame) step on the
    -- ladder -- see ZoomLevels.lua's own read of the *last* entry for the
    -- opposite, tightest end of the same table.
    local levels = sc.zoomLevels
    local baseScale = levels and levels[1] and levels[1].scale
    if not baseScale then return end

    if sc.InstantPanAndZoom then
        pcall(sc.InstantPanAndZoom, sc, baseScale, 0.5, 0.5, true)
    end
end

local function OnMouseUp(_, button)
    if button ~= "RightButton" or not IsShiftKeyDown() then return end
    ResetToCurrentZone()
end

--- Wire up the hook. Called once from Core.lua's PLAYER_LOGIN handler, same
--- timing every other module here waits for.
function ResetView:Start()
    local sc = WorldMapFrame.ScrollContainer
    if not sc then return end
    sc:HookScript("OnMouseUp", OnMouseUp)
end
