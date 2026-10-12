-------------------------------------------------------------------------------
-- HFWM-Forever Zoom Levels
--
-- Optional "Additional Zoom Levels" feature (on by default): appends extra,
-- closer zoom steps onto the world map's own zoom ladder, so the higher-
-- resolution art this addon ships (see hfwm/gamedata/db2.py's _hires_geometry: every
-- Type=Zone map uncapped, plus Kalimdor/Eastern Kingdoms/Azeroth capped) can
-- be zoomed into past whatever ceiling Blizzard's own map data allows,
-- instead of that extra detail going to waste once the built-in max zoom is
-- reached.
--
-- WorldMapFrame.ScrollContainer (MapCanvasScrollControllerMixin) keeps its
-- own zoom ladder in self.zoomLevels, a plain array of { scale, layerIndex }
-- rebuilt by :CreateZoomLevels() from C_Map.GetMapArtLayers() every time the
-- shown map or the canvas size changes. Zoom-in/out (buttons, mouse wheel,
-- and the clamp inside :SetZoomTarget) all read the *last* entry through
-- :GetScaleForMaxZoom(), which is nothing more than
-- self.zoomLevels[#self.zoomLevels].scale, so appending further, larger-
-- scale entries to that table right after Blizzard finishes building it
-- raises the ceiling for every normal zoom path at once, with no need to
-- touch OnMouseWheel or SetZoomTarget directly. This is a plain post-hook
-- (hooksecurefunc), so a client that ships something incompatible here just
-- leaves the ladder as Blizzard built it; the option quietly does nothing
-- rather than erroring.
--
-- Each extra level keeps the *last* real level's layerIndex: there is no
-- further Blizzard art layer to switch to (Classic-era zones have exactly
-- one), so every extra step is purely a bigger on-screen scale of the same
-- bundled tiles Renderer.lua already draws. Renderer only ever reads
-- canvas:GetSize() (see its Refresh), so it needs no changes to benefit
-- from this.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config     = ns.Config
local ZoomLevels = ns.ZoomLevels

local WorldMapFrame = _G.WorldMapFrame

-- How many extra steps to append.
local EXTRA_STEPS = 8

-- How much closer each extra step gets versus the one before it. Continues
-- Blizzard's own last-step ratio when there is one to read, so the extra
-- steps feel like a natural continuation of the existing ladder rather than
-- an arbitrary jump; this is only the fallback for a map whose own ladder is
-- a single level (no zoom range at all, e.g. a 1x1 city map) and so has no
-- ratio of its own to continue.
local FALLBACK_STEP_RATIO = 1.5

local function Enabled()
    return Config.db and Config.db.additionalZoomLevels
end

--- Blizzard's last zoom level and the step ratio to continue it with, or
--- nil when extra levels don't apply to the map being shown.
---@param sc table the ScrollContainer
---@return table|nil lastLevel, number|nil ratio
local function LadderTail(sc)
    if not Enabled() then return end

    -- Continent and world maps only have art worth zooming into when High
    -- Resolution (which needs the Art addon) is in effect.
    local mapType = Config:ClassifyMapID(WorldMapFrame:GetMapID())
    if (mapType == "world" or mapType == "continent")
       and not Config:MapClarityEnabled(mapType) then
        return
    end
    local levels = sc.zoomLevels
    if not levels or #levels == 0 then return end

    local lastIdx   = #levels
    local lastLevel = levels[lastIdx]
    local ratio = FALLBACK_STEP_RATIO
    if lastIdx >= 2 and levels[lastIdx - 1].scale > 0 then
        local r = lastLevel.scale / levels[lastIdx - 1].scale
        if r > 1 then ratio = r end
    end
    return lastLevel, ratio
end

--- Post-hook target for ScrollContainer:CreateZoomLevels(). Appends
--- EXTRA_STEPS further levels onto whatever ladder Blizzard just rebuilt,
--- each further zoomed in than the last, all pointing at the same layer
--- index Blizzard's own final level used.
---@param sc table the ScrollContainer instance (its own `self`)
local function ExtendZoomLevels(sc)
    -- Off under the gamepad UI: any entry added to Blizzard's zoomLevels is
    -- tainted, the map's own focus/binding flows then read it (via
    -- GetScaleForMaxZoom) and run tainted, and the stick-zoom binding stops
    -- firing. Verified with /hfwm padzoom: gamepadZoom stays 0. The stick
    -- gets its extra range from PadZoom below instead.
    if Config:IsGamepadUI() then return end
    local lastLevel, ratio = LadderTail(sc)
    if not lastLevel then return end

    local levels = sc.zoomLevels
    local scale = lastLevel.scale
    for _ = 1, EXTRA_STEPS do
        scale = scale * ratio
        levels[#levels + 1] = {
            scale = scale,
            layerIndex = lastLevel.layerIndex,
        }
    end
end

-------------------------------------------------------------------------------
-- Gamepad (native Gamepad UI) zoom past Blizzard's last step
--
-- Blizzard's stick zoom (ScrollContainer:OnUpdate) is continuous and clamps
-- at the ladder's last entry. The ladder can't be extended under the Gamepad
-- UI (see ExtendZoomLevels), so the ladder is left alone and this takes the
-- zoom over only while it is beyond that last step: once the stick pushes at
-- the top, Blizzard's own zoom velocity is parked here and applied with
-- InstantPanAndZoom (the same call Blizzard's OnUpdate makes, zoom centred on
-- the map cursor), up to the ceiling the mouse ladder would reach. Coming
-- back down, control returns to Blizzard the moment the scale is back at its
-- last step. Below that point nothing here runs, so Blizzard's own zoom is
-- untouched.
-------------------------------------------------------------------------------
local EPS = 1e-4
local padVel = 0  -- stick zoom velocity (scale units / s) while this owns the zoom

--- Park Blizzard's zoom velocity here when it is pushing at, or past, the
--- last step.
local function PadTakeOver(sc)
    if not Config:IsGamepadUI() then return end
    local v, scale = sc.gamepadZoom, sc.currentScale
    if not v or v == 0 or not scale then return end
    local last = LadderTail(sc)
    if not last then return end
    if scale > last.scale + EPS or (v > 0 and scale >= last.scale - EPS) then
        padVel = v
        sc.gamepadZoom = 0
    end
end

--- After every stick callback (SetGamepadZoom / GamepadZoom, the latter also
--- from ClearBindings): a release (0) ends our zoom too.
local function PadOnStick(sc)
    if sc.gamepadZoom == 0 then padVel = 0 end
    PadTakeOver(sc)
end

local function PadUpdate(_, elapsed)
    local sc = WorldMapFrame.ScrollContainer
    if not Config:IsGamepadUI() then padVel = 0 return end
    PadTakeOver(sc)
    if padVel == 0 then return end

    local scale = sc.currentScale
    local last, ratio = LadderTail(sc)
    if not (scale and last) then return end

    local ceiling = last.scale * ratio ^ EXTRA_STEPS
    -- Blizzard's velocity is linear in scale, so over this much longer range
    -- it would crawl. Make it proportional to the current scale instead
    -- (constant relative speed), with gain 1 exactly at Blizzard's last step
    -- so the speed carries on from where Blizzard's own zoom left off with
    -- no jump. Raise/lower the multiplier to taste.
    local gain = scale / last.scale
    local new = math.min(ceiling, scale + padVel * gain * elapsed)
    local release = new <= last.scale + EPS
    if release then new = last.scale end

    -- Same cursor-centred pan Blizzard's OnUpdate computes for its zoom.
    local ok = pcall(function()
        local cx, cy = sc:GetGamepadCursorPosition()
        local nx = sc:NormalizeHorizontalSize(cx / scale - sc.Child:GetLeft())
        local ny = sc:NormalizeVerticalSize(sc.Child:GetTop() - cy / scale)
        sc:InstantPanAndZoom(new, nx, ny)
    end)
    if release or not ok then
        -- Back at Blizzard's last step (or something went wrong): hand the
        -- stick's velocity back so its own zoom carries on from here.
        sc.gamepadZoom = ok and padVel or 0
        padVel = 0
    end
end

--- Force the ladder to rebuild right now, so toggling the option in Options
--- (or via /hfwm zoom, or switching world map resolution) takes effect
--- immediately rather than waiting for the next map change or canvas
--- resize. CreateZoomLevels only recomputes self.baseScale/self.zoomLevels;
--- it does not itself move the current view, so if the ladder just got
--- shorter the view is left zoomed past the new maximum: snap it back.
function ZoomLevels:Refresh()
    local sc = WorldMapFrame.ScrollContainer
    if not (sc and sc.CreateZoomLevels) or Config:IsGamepadUI() then return end
    pcall(sc.CreateZoomLevels, sc)

    local levels = sc.zoomLevels
    local maxScale = levels and levels[#levels] and levels[#levels].scale
    local scale, x, y = sc.currentScale, sc.currentScrollX, sc.currentScrollY
    if maxScale and scale and x and y and scale > maxScale
       and sc.InstantPanAndZoom then
        pcall(sc.InstantPanAndZoom, sc, maxScale, x, y, true)
    end
end

--- Wire up the hook. Called once from Core.lua's PLAYER_LOGIN handler, same
--- timing every other module here waits for.
function ZoomLevels:Start()
    local sc = WorldMapFrame.ScrollContainer
    if not sc or not sc.CreateZoomLevels then
        return  -- no zoom-ladder API on this client at all; nothing to extend
    end
    hooksecurefunc(sc, "CreateZoomLevels", ExtendZoomLevels)

    if sc.SetGamepadZoom and sc.GamepadZoom then
        hooksecurefunc(sc, "SetGamepadZoom", PadOnStick)
        hooksecurefunc(sc, "GamepadZoom", PadOnStick)
        local f = CreateFrame("Frame", nil, WorldMapFrame)
        f:SetScript("OnUpdate", PadUpdate)
        f:SetScript("OnHide", function() padVel = 0 end)
    end
end
