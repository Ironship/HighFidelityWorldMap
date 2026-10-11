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
-- If the user pans/zooms the map themselves, re-centering is suspended for a
-- time of PAN_RESUME_BASE plus a part proportional to the distance between
-- the view center and the player (PAN_RESUME_MAX at the far corner); if the
-- player is still moving after
-- that, the map glides back to center.
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

-- After the user pans (the delay counts from letting go of the mouse, not
-- from the last movement), the map waits before re-centering on the player (if
-- they're still moving): PAN_RESUME_BASE seconds, plus up to PAN_RESUME_MAX
-- more when the view is a full zone diagonal away (proportionally less when
-- closer).
local PAN_RESUME_BASE = 2
local PAN_RESUME_MAX = 3
local DIAGONAL = math.sqrt(2)
local lastPanAt = -math.huge
local expX, expY -- scroll we left the view at; a mismatch means the user moved it

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
        expX, expY = nil, nil
    end
    if not isZone then return end

    local scale, curX, curY = sc.currentScale, sc.currentScrollX, sc.currentScrollY
    if not scale then return end

    -- The user has the view: dragging (button held, even if the cursor is
    -- still) or zooming/inertia moved it without us. Stop chasing the player;
    -- the delay below counts from the release / last such change.
    if (sc.IsPanning and sc:IsPanning())
       or (expX and (curX ~= expX or curY ~= expY)) then
        lastPanAt = GetTime()
        targetX, targetY = nil, nil
    end
    expX, expY = curX, curY

    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    local x, y
    if pos then x, y = pos:GetXY() end
    if not x then
        lastX, lastY, targetX, targetY = nil, nil, nil, nil
        return
    end
    if x ~= lastX or y ~= lastY then
        lastX, lastY = x, y
        -- Resume delay: a flat base plus a part that scales with how far the
        -- view is from the player.
        local wait = PAN_RESUME_BASE
        if curX and curY then
            wait = wait + PAN_RESUME_MAX * math.sqrt((x - curX) ^ 2 + (y - curY) ^ 2) / DIAGONAL
        end
        if GetTime() - lastPanAt >= wait then targetX, targetY = x, y end
    end
    if not targetX then return end

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
    expX, expY = sc.currentScrollX, sc.currentScrollY

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
    f:SetScript("OnShow", function() lastX, lastY, snap, expX, expY, lastPanAt = nil, nil, true, nil, nil, -math.huge end)
end

--- Forget the last position so the next frame glides to the player.
function KeepCentered:Refresh()
    lastX, lastY = nil, nil
end
