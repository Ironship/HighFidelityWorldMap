-------------------------------------------------------------------------------
-- HFWM-Forever Keep Centered
--
-- While the world map is open and showing the zone the player is standing
-- in, re-pans it every time the player's map position changes so the arrow
-- stays in the middle of the view and the map scrolls under it instead.
-- Zone-type maps only (not continent, world, or dungeon maps).
-- Zoom is left alone. Off by default (Config.DEFAULTS.keepCentered).
--
-- Only reacts to the player *moving*: standing still leaves the map free to
-- be dragged. Near a map edge the client clamps the pan, so the arrow
-- drifts off-center there rather than showing void.
--
-- ScrollContainer:InstantPanAndZoom takes a normalized (0..1) canvas
-- position, the same unit ResetView.lua centers with (0.5, 0.5) and
-- MapMemory.lua restores with, and the unit C_Map.GetPlayerMapPosition
-- returns.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config       = ns.Config
local KeepCentered = ns.KeepCentered

local WorldMapFrame = _G.WorldMapFrame
local C_Map         = _G.C_Map

local lastX, lastY
local checkedMapID, isZone
local targetX, targetY
local snap = true

-- Exponential ease toward the player: ~95% of the way in 3*TAU (~100ms).
local TAU = 0.035
local EPSILON = 1e-4

local function OnUpdate(_, elapsed)
    if not Config.db.keepCentered then return end

    local sc = WorldMapFrame.ScrollContainer
    local mapID = WorldMapFrame:GetMapID()
    if not (sc and sc.InstantPanAndZoom and mapID) then return end

    -- Zone maps only; classified once per map, not per frame.
    if mapID ~= checkedMapID then
        checkedMapID, isZone = mapID, Config:ClassifyMapID(mapID) == "zone"
    end
    if not isZone then return end

    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    local x, y
    if pos then x, y = pos:GetXY() end
    if not x then
        lastX, lastY, targetX, targetY = nil, nil, nil, nil
        return
    end
    if x ~= lastX or y ~= lastY then
        lastX, lastY = x, y
        targetX, targetY = x, y
    end
    if not targetX then return end

    local scale, curX, curY = sc.currentScale, sc.currentScrollX, sc.currentScrollY
    if not scale then return end

    local nx, ny = targetX, targetY
    if snap or not (curX and curY) then
        snap = false
    else
        local dx, dy = targetX - curX, targetY - curY
        if dx * dx + dy * dy < EPSILON * EPSILON then
            targetX, targetY = nil, nil
            return
        end
        local a = 1 - math.exp(-elapsed / TAU)
        nx, ny = curX + dx * a, curY + dy * a
    end
    pcall(sc.InstantPanAndZoom, sc, scale, nx, ny, true)

    -- The client clamps the pan near map edges; if the step didn't move
    -- the view, the target is unreachable, so stop chasing it.
    if sc.currentScrollX == curX and sc.currentScrollY == curY then
        targetX, targetY = nil, nil
    end
end

--- Wire up the per-frame check. Called once from Core.lua. The frame is a
--- child of the map, so OnUpdate only runs while the map is shown.
function KeepCentered:Start()
    local f = CreateFrame("Frame", nil, WorldMapFrame)
    f:SetScript("OnUpdate", OnUpdate)
    -- Snap (no glide) to the player on reopen.
    f:SetScript("OnShow", function() lastX, lastY, snap = nil, nil, true end)
end

--- Forget the last position so the next frame glides to the player.
function KeepCentered:Refresh()
    lastX, lastY = nil, nil
end
