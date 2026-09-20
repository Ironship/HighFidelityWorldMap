-------------------------------------------------------------------------------
-- HFWM-Forever Config
-- Defaults, SavedVariables init, and overlay state tracking.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config = ns.Config

-- Defaults (persisted in HighFidelityWorldMapForeverDB)
Config.DEFAULTS = {
    enabled       = true,
    alpha         = 1.0,
    mapBackground = "ocean",  -- see Config.BACKGROUNDS below

    -- Cave map: the window that opens over the world map when the player is
    -- inside a cave / micro dungeon the map above has nothing to say about.
    -- Enabled by default: the whole point of this addon is a map that keeps
    -- working underground, and a feature nobody knows exists (short of
    -- reading Options or `/hfwm cave on`) may as well be missing. Anyone who
    -- doesn't want the extra panel can turn it off from Options or with
    -- `/hfwm cave off`.
    caveEnabled = true,
    caveAlpha   = 0.95,

    -- Cave map (beta): how the window decides to show itself, as opposed to
    -- whether the feature exists at all (caveEnabled above).
    --
    -- caveAutoOpen: the plain rule when Remember State (below) is off —
    -- show the window the instant a tracked cave is entered, same as this
    -- addon has always done. Off means it waits at the reopen icon instead,
    -- every time, until clicked.
    --
    -- caveRememberState: instead of the fixed rule above, reproduce
    -- whichever of open/closed the player left it as last time — set
    -- automatically as caveLastVisible below, never through Options
    -- directly. Wins over caveAutoOpen when both would otherwise apply,
    -- since "what I did last time" is the more specific instruction.
    --
    -- caveLastVisible: true means the last thing to happen to the window
    -- was it being shown (auto-opened, Remember-State-opened, or the
    -- reopen icon/ForceShow); false means the player explicitly closed it
    -- (the X button, or /hfwm cave hide). Only read when caveRememberState
    -- is on, but tracked unconditionally so turning Remember State on for
    -- the first time already has something real to go on.
    caveAutoOpen      = true,
    caveRememberState = false,
    caveLastVisible   = true,

    -- Cave map height window: the real-world elevation range that stays
    -- visible as a per-piece place's rooms (currently just Fargodeep Mine)
    -- are drawn, expressed as two fractions of that place's own aggregate
    -- [zMin, zMax] span (0 = the bottom of the span, 1 = the top). The user
    -- drags this directly as a rectangle on the cave map's own depth
    -- slider (see CaveRenderer's height-window widget) rather than through
    -- a separate Options control. Defaulting to the full 0..1 span means a
    -- first-time user sees every piece at once, which is the loosest
    -- setting asked for.
    caveHeightWindowTop    = 1.0,
    caveHeightWindowBottom = 0.0,
}
-- The db also carries `caveWindowPoint` — { point, relPoint, x, y, toMap } —
-- written by CaveRenderer when the window is dragged. It is deliberately not
-- in DEFAULTS: absent means "wherever the window opens by default", and a nil
-- entry in a defaults table would not survive the pairs() copy in InitDB
-- anyway. /hfwm cave reset clears it.

--- Cave window opacity, clamped, with a floor: a cave map faded to nothing is
--- indistinguishable from the feature being broken, and the window has a
--- close button for the case where it is genuinely not wanted.
---@return number
function Config:CaveAlpha()
    local a = self.db and self.db.caveAlpha or self.DEFAULTS.caveAlpha
    if type(a) ~= "number" then a = self.DEFAULTS.caveAlpha end
    return math.max(0.2, math.min(1, a))
end

-------------------------------------------------------------------------------
-- Cave height window
--
-- The rectangle CaveRenderer's height-window widget drags directly on the
-- cave map's own depth slider: not a single point, but a top and bottom
-- fraction (each 0..1 against the currently-shown place's aggregate
-- [zMin, zMax]) bounding the real-world elevation range a per-piece
-- place's rooms stay visible within. Dragging an edge resizes the window
-- (narrows or widens the range); dragging the body moves it as a unit.
-------------------------------------------------------------------------------

--- The smallest gap kept between the top and bottom fractions, so the
--- window can never collapse to nothing and become ungrabbable.
Config.HEIGHT_WINDOW_MIN_SPAN = 0.04

--- Current window bounds, clamped to 0..1 and ordered (top >= bottom).
---@return number top, number bottom
function Config:CaveHeightWindow()
    local top    = self.db and self.db.caveHeightWindowTop
    local bottom = self.db and self.db.caveHeightWindowBottom
    if type(top) ~= "number" then top = self.DEFAULTS.caveHeightWindowTop end
    if type(bottom) ~= "number" then
        bottom = self.DEFAULTS.caveHeightWindowBottom
    end
    top    = math.max(0, math.min(1, top))
    bottom = math.max(0, math.min(1, bottom))
    if top < bottom then top, bottom = bottom, top end
    return top, bottom
end

--- Persist new window bounds. Order-independent (swapped if `top < bottom`)
--- and enforces HEIGHT_WINDOW_MIN_SPAN by pushing out whichever edge the
--- caller did *not* just move — e.g. dragging the top handle down onto the
--- bottom one stops at the minimum span rather than dragging the bottom
--- edge down with it. Callers still need to push the change out to
--- anything already on screen — see CaveRenderer's height-window widget.
---@param top number
---@param bottom number
function Config:SetCaveHeightWindow(top, bottom)
    top    = math.max(0, math.min(1, top or 1))
    bottom = math.max(0, math.min(1, bottom or 0))
    if top < bottom then top, bottom = bottom, top end
    if top - bottom < self.HEIGHT_WINDOW_MIN_SPAN then
        if bottom + self.HEIGHT_WINDOW_MIN_SPAN <= 1 then
            top = bottom + self.HEIGHT_WINDOW_MIN_SPAN
        else
            bottom = top - self.HEIGHT_WINDOW_MIN_SPAN
        end
    end
    if not self.db then return end
    self.db.caveHeightWindowTop    = top
    self.db.caveHeightWindowBottom = bottom
end

-------------------------------------------------------------------------------
-- Map background
--
-- The bundled BLPs are generated by the pipeline's default "alpha-sea" art
-- pass, which leaves the sea and every cell the terrain grid does not cover
-- *transparent* rather than baking a colour or Blizzard's art underneath.
-- That is what makes the backdrop a runtime choice instead of a 175 MB
-- regenerate: three of the four backgrounds draw the same tiles and differ
-- only in what sits behind them.
--
-- Two independent fields decide how an entry is drawn. What goes behind the
-- tiles:
--
--   rgb ~= nil       -> fill the canvas with this colour.
--   blizzardArt      -> nothing of ours; leave the client's own detail-layer
--                       art on screen so it shows through the transparent
--                       sea.
--   neither          -> nothing at all. Either the tiles are opaque and a
--                       backdrop could never be seen, or the holes are the
--                       point.
--   seeThrough       -> and, on top of that, hide the map frame's own backing
--                       so the holes really do go through the UI. Without it
--                       "nothing behind the tiles" only reaches as far as the
--                       frame's panel art, one layer down, and the result is
--                       near enough indistinguishable from Hybrid. See
--                       MapFrameBg.lua.
--
-- and which tiles to draw:
--
--   tiles == nil     -> the bundled transparent art, FDID_MAP.
--   tiles            -> an alternate lookup table. Only "original" exists: a
--                       separate, raw dump of the stitch that the pipeline
--                       writes under WorldMap/Original/ when --original is
--                       on. Unlike the other three entries this one really
--                       is a second set of BLPs, because the raw stitch
--                       cannot be recovered from the transparent art at draw
--                       time — an earlier attempt to do that with
--                       SetBlendMode("DISABLE") turned out not to work on
--                       this client, which honours the alpha channel
--                       regardless of blend mode. Config:BackgroundAvailable
--                       below hides the entry when that art is not installed.
--
-- Ordered: Options.lua builds its dropdown straight from this list, so
-- adding a background here is all it takes to offer it in game.
-------------------------------------------------------------------------------
Config.BACKGROUNDS = {
    {
        key   = "ocean",
        label = "Ocean Blue",
        -- The game's own coastal water, #1A3245 — the same colour the
        -- pipeline's --ocean pass bakes in (DEFAULT_OCEAN_COLOR).
        desc  = "One flat sea colour, measured from the game's own water.",
        rgb   = { 26 / 255, 50 / 255, 69 / 255 },
    },
    {
        key         = "hybrid",
        label       = "Hybrid",
        desc        = "Blizzard's hand-painted ocean, coast and border "
                   .. "underneath.",
        blizzardArt = true,
    },
    {
        key   = "original",
        label = "Original",
        desc  = "The raw stitch in all its ugly glory — the sea exactly as "
             .. "the game's own tiles render it, blocky seams and all.",
        tiles = "original",
    },
    {
        key        = "transparent",
        label      = "Transparent",
        desc       = "No backdrop at all — the sea is a hole straight through "
                  .. "the map frame onto the world behind it.",
        seeThrough = true,
    },
}

--- Is this background's art actually installed?
---
--- Only ever false for an entry with its own tile set: WorldMap/ is a build
--- artifact, so a user who built without --original has the transparent art
--- and nothing else. Offering the entry anyway would draw the client's own
--- FDIDs and quietly look like Hybrid.
---@param bg table entry from Config.BACKGROUNDS
---@return boolean
function Config:BackgroundAvailable(bg)
    if bg.tiles == "original" then
        return next(self.FDID_MAP_ORIGINAL) ~= nil
    end
    return true
end

--- The FileDataID -> relative path table a background draws its tiles from.
--- Always returns a table; an entry with no `tiles` field gets the bundled
--- transparent art.
---@param bg table entry from Config.BACKGROUNDS
---@return table
function Config:GetTileMap(bg)
    if bg and bg.tiles == "original" then
        return self.FDID_MAP_ORIGINAL
    end
    return self.FDID_MAP
end

--- The backgrounds this install can actually draw, in Config.BACKGROUNDS
--- order. Options.lua and Commands.lua both build from this rather than the
--- full list.
---@return table[]
function Config:AvailableBackgrounds()
    local out = {}
    for _, bg in ipairs(self.BACKGROUNDS) do
        if self:BackgroundAvailable(bg) then
            out[#out + 1] = bg
        end
    end
    return out
end

--- Look up the active background, falling back to the default on garbage or
--- on a saved choice whose art is not installed.
---@return table entry from Config.BACKGROUNDS
function Config:GetBackground()
    local want = self.db and self.db.mapBackground
    local available = self:AvailableBackgrounds()
    for _, bg in ipairs(available) do
        if bg.key == want then return bg end
    end
    for _, bg in ipairs(available) do
        if bg.key == self.DEFAULTS.mapBackground then return bg end
    end
    return available[1] or self.BACKGROUNDS[1]
end

--- Set the active background and redraw. Returns the entry, or nil if the
--- key is not one this install offers.
---@param key string
function Config:SetBackground(key)
    for _, bg in ipairs(self:AvailableBackgrounds()) do
        if bg.key == key then
            if self.db then self.db.mapBackground = key end
            ns.Renderer:ForceRefresh()
            return bg
        end
    end
    return nil
end

-- FileDataID lookup tables (populated from FDIDMap.lua)
Config.FDID_MAP          = HFWMF_FDID_MAP          or {}
Config.FDID_MAP_SUB      = HFWMF_FDID_MAP_SUB      or {}
-- The raw second dump, written only when the pipeline ran with --original.
-- Its paths carry their own "Original\\" prefix, so FDID_BASE serves both.
Config.FDID_MAP_ORIGINAL = HFWMF_FDID_MAP_ORIGINAL or {}
Config.FDID_BASE    = "Interface\\AddOns\\HighFidelityWorldMapForever\\WorldMap\\"

-- Vashj'ir UiMapIDs — retail-only (Cataclysm). WoW Forever has no Vashj'ir,
-- so this is intentionally empty. Kept so that Renderer.lua stays
-- structurally identical to the retail addon.
Config.VASHJIR_MAPS = {}

-- Runtime state (shared mutable, referenced by all modules)
Config.db              = nil   -- ref to HighFidelityWorldMapForeverDB after ADDON_LOADED
Config.overlayFrame    = nil   -- Frame parented to the map canvas
Config.backdropTexture = nil   -- flat colour drawn under the tiles (Renderer)
Config.overlayActive   = false
Config.refreshPending  = false
Config.lastCanvas      = nil   -- WorldMapFrame.ScrollContainer.Child identity
Config.lastCanvasW     = 0
Config.lastCanvasH     = 0
Config.lastMapID       = nil
Config.lastLayerIdx    = nil
Config.lastSubmerged   = nil
Config.tracing         = false

-- Cave map runtime state (the window itself is built by CaveRenderer)
Config.caveOverlayFrame      = nil   -- the cave window frame
Config.caveContentFrame      = nil   -- clipping frame the cave tiles live in
Config.caveOverlayActive     = false
Config.caveCurrentFloorMapID = nil   -- floor on screen right now
Config.caveAllFloors         = nil   -- [{mapID, name, relativeHeightIndex}, ...]
Config.caveFloorPinned       = false -- user drove the depth slider; stop following them
-- The floor dropdown's own state (see CaveRenderer's floor-picker section):
-- true (the default) layers every floor together exactly as before this
-- control existed; false scopes both the rendered art and the depth
-- slider's range to Config.caveCurrentFloorMapID alone. Reset to true
-- whenever the window closes, same as caveFloorPinned, so re-entering a
-- cave is always a clean "All" slate.
Config.caveFloorFilterAll    = true
Config.caveSuppressedKey     = nil   -- map group the user closed; don't reopen it
-- Map group Cave:UpdateState has already run the Open Automatically /
-- Remember State decision for, this visit. Deliberately its own flag
-- rather than reusing "does caveAllFloors already cover this floor" —
-- that stays populated (and so looks like "already handled") even after
-- leaving a cave the settings kept closed, since HideCave (which clears
-- it) is only ever called on a cave that was actually shown. Cleared
-- unconditionally on every "player is not in a cave" tick, same moment as
-- caveSuppressedKey, so a stale value can never survive to the next visit.
Config.caveDecidedKey        = nil
Config.caveDisplayedMapID    = nil   -- world-map UiMapID displayed (change detection)
Config.lastPlayerMapID       = nil   -- GetBestMapForUnit cache (change detection)

-- Cache lookup-table sizes for diagnostics
do
    local function count(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    Config._fdidMapSize         = count(Config.FDID_MAP)
    Config._fdidMapOriginalSize = count(Config.FDID_MAP_ORIGINAL)
end

-- Saved background keys that have been renamed. "default" was the original
-- name for what turned out to be simply a transparent map: it was meant to
-- redraw the raw stitch by disabling blending, which this client does not
-- honour. The raw stitch now lives in its own tile set under the "original"
-- key, so anyone carrying the old value wants "transparent" rather than a
-- silent fall back to Ocean Blue.
local BACKGROUND_RENAMES = {
    default = "transparent",
}

--- Initialise SavedVariables after ADDON_LOADED.
function Config:InitDB()
    if type(HighFidelityWorldMapForeverDB) ~= "table" then
        HighFidelityWorldMapForeverDB = {}
    end
    local renamed = BACKGROUND_RENAMES[HighFidelityWorldMapForeverDB.mapBackground]
    if renamed then
        HighFidelityWorldMapForeverDB.mapBackground = renamed
    end
    for k, v in pairs(self.DEFAULTS) do
        if HighFidelityWorldMapForeverDB[k] == nil then
            HighFidelityWorldMapForeverDB[k] = v
        end
    end
    self.db = HighFidelityWorldMapForeverDB
end
