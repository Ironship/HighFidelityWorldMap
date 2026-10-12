-------------------------------------------------------------------------------
-- HFWM-Forever Reset View
--
-- Shift+right-click on the world map snaps back to the zone the player is
-- actually standing in, fully zoomed out and centered -- the view of freshly
-- opening the map, undoing any drilling into subzones/dungeons or panning/
-- zooming. When already viewing the current zone's map it just resets that
-- view. Blizzard's own right-click on the ScrollContainer navigates up one
-- level (zone -> continent) before this hooked script can cancel it, so the
-- snap is deferred a frame to land after it. The cave window has its own
-- shift+right-click that only resets its zoom/pan (CaveRenderer). A plain
-- right-click is left alone (whatever Blizzard's own OnMouseUp on the
-- ScrollContainer already does with it); this only adds a second script onto
-- the same event, gated on the shift modifier, via HookScript rather than
-- SetScript so nothing already wired up there is replaced.
-------------------------------------------------------------------------------
local addonName, ns = ...
local ResetView = ns.ResetView

local WorldMapFrame  = _G.WorldMapFrame
local IsShiftKeyDown = _G.IsShiftKeyDown
local C_Map          = _G.C_Map

--- Reset the world map's zoom/pan to the fitted view of the map currently shown.
local function ResetMapView()
    local sc = WorldMapFrame.ScrollContainer
    if not sc or ns.Config:IsGamepadUI() then return end  -- see MapMemory's Enabled

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

--- The zone map the player stands in. GetBestMapForUnit can answer with the
--- continent (seen on Classic: Westfall -> Eastern Kingdoms), so when the
--- answer isn't a zone, look through the zone maps beneath it for the one
--- the player has a position on, falling back to matching the zone name.
local function PlayerZoneMapID()
    local best = C_Map.GetBestMapForUnit("player")
    if not best then return end
    local info = C_Map.GetMapInfo(best)
    if info and info.mapType == Enum.UIMapType.Zone then return best end
    local zoneName = GetZoneText()
    local byName
    for _, kid in ipairs(C_Map.GetMapChildrenInfo(best, Enum.UIMapType.Zone, true) or {}) do
        if C_Map.GetPlayerMapPosition(kid.mapID, "player") then return kid.mapID end
        if kid.name == zoneName then byName = kid.mapID end
    end
    return byName or best
end

local function SnapToCurrentZone()
    if ns.Config:IsGamepadUI() then return end  -- SetMapID from addon code; see MapMemory's Enabled
    local mapID = PlayerZoneMapID()
    if mapID and WorldMapFrame:GetMapID() ~= mapID then
        pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID)
    end
    ResetMapView()
end

local function OnMouseUp(_, button)
    if button ~= "RightButton" or not IsShiftKeyDown() then return end
    -- Deferred a frame: Blizzard's own right-click (navigate up one level,
    -- zone -> continent) has to have run first, or it would land on top of
    -- the snap. Wherever they were looking, end up on the player's zone.
    C_Timer.After(0, SnapToCurrentZone)
end

function ResetView:HookFrame(frame, handler, recursive)
    if not frame or frame._hfwmResetHook then return end

    local callback = handler or OnMouseUp
    frame:HookScript("OnMouseUp", callback)
    frame._hfwmResetHook = true

    if recursive and frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            self:HookFrame(child, handler, true)
        end
    end
end

--- Wire up the hook. Called once from Core.lua's PLAYER_LOGIN handler, same
--- timing every other module here waits for.
function ResetView:Start()
    local sc = WorldMapFrame.ScrollContainer
    if not sc then return end
    self:HookFrame(sc, OnMouseUp, false)
end
