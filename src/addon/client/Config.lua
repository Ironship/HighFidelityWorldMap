-------------------------------------------------------------------------------
-- HFWM-Forever Config
-- Defaults, AceDB-3.0 profile database, and overlay state tracking.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config = ns.Config

-- Defaults (persisted per-profile in HighFidelityWorldMapDB)
Config.DEFAULTS = {
    enabled       = true,
    alpha         = 1.0,
    mapBackground = "ocean",  -- see Config.BACKGROUNDS below

    -- Per-map-type overrides of mapBackground above (now labelled "Global
    -- Background" in Options, since these three exist). "global" (the
    -- default for all three) means "inherit whatever mapBackground says";
    -- anything else must be one of Config.BACKGROUNDS' own keys. See the
    -- "Map background" section below for how these resolve at draw time.
    zoneMapBackground       = "global",
    continentMapBackground  = "global",
    worldMapBackground      = "global",

    -- Cave map: a window that opens over the world map when the player is
    -- somewhere the map above it has nothing to show (caves, mines, micro
    -- dungeons). On by default; turn it off from Options or /hfwm cave off.
    caveEnabled = true,
    caveAlpha   = 0.95,

    -- How the cave window decides to show itself, as opposed to whether
    -- the feature exists at all (caveEnabled above).
    --
    -- caveAutoOpen: show the window the instant a tracked cave is entered.
    -- Off means it waits at the reopen icon instead, until clicked.
    --
    -- caveRememberState: reproduce whichever of open/closed the window was
    -- left as last time, instead of the fixed rule above. Wins over
    -- caveAutoOpen when both apply.
    --
    -- caveLastVisible: true if the window's last state change was being
    -- shown; false if the player closed it. Only read when
    -- caveRememberState is on, but tracked unconditionally.
    caveAutoOpen      = true,
    caveRememberState = false,
    caveLastVisible   = true,

    -- Cave map depth window: the real-world elevation range a per-piece
    -- place's rooms (currently just Fargodeep Mine) stay visible within,
    -- as two fractions (0..1) of that place's own [zMin, zMax] span.
    -- Dragged directly on the cave map's own depth slider rather than
    -- through Options; see CaveRenderer's height-window widget.
    caveHeightWindowTop    = 1.0,
    caveHeightWindowBottom = 0.0,

    -- Keep the world map at whatever zoom and pan it was left at, instead
    -- of resetting to the current zone every time it reopens -- the same
    -- job the separate PersistentWorldMap addon does. See MapMemory.lua.
    rememberMapZoomPan = true,

    -- Appends 8 extra, closer zoom steps onto the world map so the
    -- native-resolution zone art this addon ships can be zoomed into past
    -- Blizzard's own ceiling. Off by default: it changes how far the
    -- built-in zoom control reaches. See ZoomLevels.lua.
    additionalZoomLevels = false,

    -- Draws the three continent/world maps (Kalimdor, Eastern Kingdoms,
    -- Azeroth) from this addon's own capped hi-res tile grid instead of
    -- Blizzard's stock art. Off by default: a continent map is many more
    -- tiles than any single zone, and could slow down a weaker machine.
    -- See HFWMF_NATIVE_ZONES' `continent` flag and GetNativeZone below.
    worldMapClarity = false,

    -- Restores the original grayscale-until-explored look instead of this
    -- addon's usual full hi-res coverage. Off by default since it works
    -- against the addon's whole point. With it on, ground stays grayscale
    -- until C_MapExplorationInfo says the player has explored it, then
    -- switches to this addon's tiles cropped to Blizzard's own reveal
    -- shape. See Renderer's Activate() and DrawExploredPiece.
    fogOfWarEnabled = false,

    -- The "sd"/"hd" button ToggleButton.lua docks in the world map's
    -- top-right corner, for flipping the HD/SD blend (`alpha` above)
    -- between all-SD and all-HD, without touching `enabled` above. On by
    -- default; turn off here for a cleaner map with one less button.
    toggleButtonEnabled = true,
}
-- The db also carries `caveWindowPoint` -- { point, relPoint, x, y, toMap }
-- -- written by CaveRenderer when the window is dragged. Deliberately not
-- in DEFAULTS: absent means "wherever the window opens by default".
-- /hfwm cave reset clears it.

--- Cave window opacity, clamped with a floor so it can never fade to
--- invisible (the window has a close button for that).
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
-- cave map's depth slider: a top and bottom fraction (each 0..1 against
-- the shown place's aggregate [zMin, zMax]) bounding which elevation range
-- stays visible. Dragging an edge resizes the window; dragging the body
-- moves it as a unit.
-------------------------------------------------------------------------------

--- Smallest gap kept between top and bottom, so the window can never
--- collapse to nothing and become ungrabbable.
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
--- caller did *not* just move. Callers still need to push the change out to
--- anything already on screen -- see CaveRenderer's height-window widget.
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
-- The bundled BLPs leave the sea and every cell the terrain grid doesn't
-- cover transparent rather than baking in a colour or Blizzard's art, so
-- the backdrop is a runtime choice instead of a 175 MB regenerate.
--
-- What goes behind the tiles:
--   rgb          -> fill the canvas with this colour.
--   blizzardArt  -> leave the client's own detail-layer art showing through.
--   seeThrough   -> hide the map frame's own backing too, so the holes go
--                   all the way through the UI. See MapFrameBg.lua.
--   (none of the above) -> nothing behind the tiles.
--
-- Which tiles to draw:
--   tiles == nil  -> the bundled transparent art, FDID_MAP.
--   tiles         -> an alternate lookup table. Only "original" exists: a
--                     raw, un-alpha'd dump written under WorldMap/Original/
--                     when the pipeline runs with --original. Hidden by
--                     Config:BackgroundAvailable when that art isn't built.
--                     Labelled "Raw" everywhere a person sees it (Options,
--                     chat commands); `tiles = "original"` itself is left
--                     alone since it names the pipeline's own on-disk
--                     folder and generated lookup tables
--                     (HFWMF_FDID_MAP_ORIGINAL / HFWMF_NATIVE_ZONES_ORIGINAL,
--                     see FDIDMap.lua), not something this file controls.
--
-- Ordered: Options.lua builds its dropdown straight from this list.
--
-- One global choice ("mapBackground", labelled "Global Background" in
-- Options once the per-map-type overrides below exist) plus three optional
-- overrides -- zoneMapBackground/continentMapBackground/worldMapBackground
-- -- that each either name one of these same keys or "global", meaning
-- "follow mapBackground". See GetEffectiveMapTypeBackground/
-- GetBackgroundForMap below for how a map's actual background is resolved,
-- and Options.lua's "Map Background" section for the UI.
-------------------------------------------------------------------------------
Config.BACKGROUNDS = {
    {
        key   = "ocean",
        label = "Ocean Blue",
        -- The game's own coastal water colour (DEFAULT_OCEAN_COLOR).
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
        key   = "raw",
        label = "Raw",
        desc  = "The raw stitch, blocky seams and all.",
        tiles = "original",
    },
    {
        key        = "transparent",
        label      = "Transparent",
        desc       = "No backdrop at all: the sea is a hole through the "
                  .. "map frame.",
        seeThrough = true,
    },
}

--- Is this background's art actually installed?
--- Only ever false for an entry with its own tile set: a build without
--- --original never wrote WorldMap/Original/.
---@param bg table entry from Config.BACKGROUNDS
---@return boolean
function Config:BackgroundAvailable(bg)
    if bg.tiles == "original" then
        return next(self.FDID_MAP_ORIGINAL) ~= nil
    end
    return true
end

--- The FileDataID -> relative path table a background draws its tiles
--- from. Always returns a table.
---@param bg table entry from Config.BACKGROUNDS
---@return table
function Config:GetTileMap(bg)
    if bg and bg.tiles == "original" then
        return self.FDID_MAP_ORIGINAL
    end
    return self.FDID_MAP
end

--- The backgrounds this install can actually draw, in Config.BACKGROUNDS
--- order. Options.lua and Commands.lua both build from this.
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

--- Active background, falling back to the default on garbage or a saved
--- choice whose art isn't installed.
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
--- key isn't one this install offers.
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

-------------------------------------------------------------------------------
-- Per-map-type background overrides
--
-- Zone Map, Continent Map and World Map (Config.MAP_TYPES) can each draw a
-- different background from the Global Background above -- e.g. Hybrid on
-- zones for its Fog of War support, Ocean Blue on the continent/world maps
-- where nothing needs to show through. Each is stored as either "global"
-- (the default: follow mapBackground) or one of Config.BACKGROUNDS' keys.
-------------------------------------------------------------------------------

--- {key, label} for the three map kinds that can each override the Global
--- Background. Options.lua builds its three indented dropdowns straight
--- from this list.
Config.MAP_TYPES = {
    { key = "zone",      label = "Zone Map" },
    { key = "continent", label = "Continent Map" },
    { key = "world",     label = "World Map" },
}

--- The AceDB field one map type's override lives in.
---@param mapType string one of Config.MAP_TYPES' keys
---@return string
local function MapTypeField(mapType)
    return mapType .. "MapBackground"
end

--- Saved override for one map type: "global" (inherit the Global
--- Background), or one of Config.BACKGROUNDS' keys. Falls back to "global"
--- on garbage, nil, or a background this install can no longer draw, same
--- spirit as GetBackground's own fallback.
---@param mapType string
---@return string
function Config:GetMapTypeBackgroundKey(mapType)
    local want = self.db and self.db[MapTypeField(mapType)]
    if want == nil or want == "global" then return "global" end
    for _, bg in ipairs(self:AvailableBackgrounds()) do
        if bg.key == want then return want end
    end
    return "global"
end

--- Set one map type's override ("global" to inherit, or one of
--- Config.BACKGROUNDS' keys) and redraw.
---@param mapType string
---@param key string
---@return string|nil the key actually applied, or nil if unrecognised
function Config:SetMapTypeBackground(mapType, key)
    if key == "global" then
        if self.db then self.db[MapTypeField(mapType)] = "global" end
        ns.Renderer:ForceRefresh()
        return "global"
    end
    for _, bg in ipairs(self:AvailableBackgrounds()) do
        if bg.key == key then
            if self.db then self.db[MapTypeField(mapType)] = key end
            ns.Renderer:ForceRefresh()
            return key
        end
    end
    return nil
end

--- The background actually in force for one map type: its own override, or
--- the Global Background while that override is "global" (the default) or
--- names a background this install can no longer draw.
---@param mapType string
---@return table entry from Config.BACKGROUNDS
function Config:GetEffectiveMapTypeBackground(mapType)
    local key = self:GetMapTypeBackgroundKey(mapType)
    if key ~= "global" then
        for _, bg in ipairs(self:AvailableBackgrounds()) do
            if bg.key == key then return bg end
        end
    end
    return self:GetBackground()
end

-- Enum.UiMapType is Cosmic=0, World=1, Continent=2, Zone=3, Dungeon=4,
-- Micro=5, Orphan=6 (same convention Cave.lua reads it under). Only these
-- three get their own override; every other kind (caves, dungeons,
-- transport/scenario orphans) draws the Global Background, same as before
-- this setting existed.
local UI_MAP_TYPE = (Enum and Enum.UiMapType) or {}
local MAP_TYPE_BY_UI_TYPE = {
    [UI_MAP_TYPE.World     or 1] = "world",
    [UI_MAP_TYPE.Continent or 2] = "continent",
    [UI_MAP_TYPE.Zone      or 3] = "zone",
}

--- Which of Config.MAP_TYPES *mapID* is, or nil if it's some other kind
--- that doesn't get its own override.
---@param mapID number|nil
---@return string|nil
function Config:ClassifyMapID(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and MAP_TYPE_BY_UI_TYPE[info.mapType] or nil
end

--- The background Renderer should actually draw *mapID* with: that map's
--- own type override if it has one and it's set, otherwise the Global
--- Background. This is the one entry point Renderer.lua calls; everything
--- above exists to support it and the Options UI.
---@param mapID number|nil
---@return table entry from Config.BACKGROUNDS
function Config:GetBackgroundForMap(mapID)
    local mapType = self:ClassifyMapID(mapID)
    if not mapType then return self:GetBackground() end
    return self:GetEffectiveMapTypeBackground(mapType)
end

-- FileDataID lookup tables (populated from FDIDMap.lua)
Config.FDID_MAP          = HFWMF_FDID_MAP          or {}
Config.FDID_MAP_SUB      = HFWMF_FDID_MAP_SUB      or {}
-- The raw second dump, written only when the pipeline ran with --original.
-- Its paths carry their own "Original\\" prefix, so FDID_BASE serves both.
Config.FDID_MAP_ORIGINAL = HFWMF_FDID_MAP_ORIGINAL or {}
-- The art ships in this addon's own WorldMap folder.
Config.FDID_BASE    = "Interface\\AddOns\\HighFidelityWorldMap\\WorldMap\\"

-- Higher-resolution continent/world maps (see hfwm/gamedata/db2.py's
-- _hires_geometry and hfwm/lua/fdid_map.py): Kalimdor/Eastern Kingdoms/the
-- top-level Azeroth map, capped -- see HIRES_CONTINENT_MAPS.
-- Keyed by UiMapID: Renderer.lua uses this geometry and path prefix
-- directly instead of C_Map.GetMapArtLayers/GetMapArtLayerTextures.
Config.NATIVE_ZONES          = HFWMF_NATIVE_ZONES          or {}
Config.NATIVE_ZONES_ORIGINAL = HFWMF_NATIVE_ZONES_ORIGINAL or {}

-- Zone maps are not shipped as art: they are placements of the client's own
-- minimap tiles (MinimapTiles.lua), keyed by UiMapID.
Config.MINIMAP_ZONES = HFWMF_MINIMAP_ZONES or {}

---@param mapID number
---@return table|nil
function Config:GetClientZone(mapID)
    return self.MINIMAP_ZONES[mapID]
end

-- Baked cave floors/pieces as placements of the client's own WMO minimap
-- tiles (CaveTiles.lua), keyed by the synthetic FDIDs CaveData.lua uses.
Config.CAVE_TILES = HFWMF_CAVE_TILES or {}

---@param fdid number
---@return table|nil
function Config:GetCaveComposite(fdid)
    return self.CAVE_TILES[fdid]
end

--- Higher-resolution geometry for *mapID* under the given background, or
--- nil if this map has no such art, the specific dump the background
--- wants wasn't built, or (for the three capped continent maps) "Increase
--- world map clarity" is off. Renderer.lua falls back to the ordinary
--- FDID path whenever this returns nil.
---@param mapID number
---@param bg table entry from Config.BACKGROUNDS
---@return table|nil
function Config:GetNativeZone(mapID, bg)
    local t = (bg and bg.tiles == "original")
        and self.NATIVE_ZONES_ORIGINAL or self.NATIVE_ZONES
    local entry = t[mapID]
    if entry and entry.continent and not self:WorldMapClarityEnabled() then
        return nil
    end
    return entry
end

--- Whether the capped continent maps (Kalimdor/Eastern Kingdoms/Azeroth)
--- draw from this addon's hi-res tile grid. Zone maps always draw at
--- native resolution regardless.
---@return boolean
function Config:WorldMapClarityEnabled()
    return self.db and self.db.worldMapClarity or false
end

--- Whether this addon's tiles draw only over ground the player has
--- actually explored, with Blizzard's original grayscale art left visible
--- elsewhere.
---
--- Only ever true while the Zone Map background is actually Hybrid --
--- directly, or by inheriting a Hybrid Global Background -- since the
--- grayscale-until-explored look this reproduces IS Blizzard's own detail
--- layer, which only Hybrid leaves showing through underneath. Options.lua
--- greys the toggle out under the same condition; the saved value itself is
--- left alone so it picks back up automatically once Zone Map is Hybrid
--- again, rather than being silently cleared.
---@return boolean
function Config:FogOfWarEnabled()
    if not (self.db and self.db.fogOfWarEnabled) then return false end
    local zoneBg = self:GetEffectiveMapTypeBackground("zone")
    return zoneBg ~= nil and zoneBg.key == "hybrid"
end

--- Is the HD/SD slider (ToggleButton's right-click popup) below 100%? Then
--- the overlay is drawn at that alpha over Blizzard's own stock map, left
--- visible underneath, so the result is an exact HD/SD mix. Renderer's
--- Activate and Exploration's pin re-hiding both key off this. The
--- threshold absorbs slider step rounding near the top.
---@return boolean
function Config:IsMixing()
    return self.db ~= nil and self.db.alpha < 0.995
end

-- Vashj'ir UiMapIDs -- retail-only (Cataclysm). WoW Forever has no
-- Vashj'ir, so this is intentionally empty. Kept so Renderer.lua stays
-- structurally identical to the retail addon.
Config.VASHJIR_MAPS = {}

-- Runtime state (shared mutable, referenced by all modules)
Config.db              = nil   -- ref to the active AceDB profile
Config.dbObj           = nil   -- the AceDB-3.0 database object
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
-- The floor dropdown's own state (see CaveRenderer's floor-picker
-- section): true (the default) layers every floor together; false scopes
-- both the rendered art and the depth slider to Config.caveCurrentFloorMapID
-- alone. Reset to true whenever the window closes, same as caveFloorPinned.
Config.caveFloorFilterAll    = true
Config.caveSuppressedKey     = nil   -- map group the user closed; don't reopen it
-- Map group Cave:UpdateState has already decided Open Automatically /
-- Remember State for, this visit. Cleared unconditionally on every
-- "player is not in a cave" tick, same moment as caveSuppressedKey.
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
    Config._nativeZonesSize         = count(Config.NATIVE_ZONES)
    Config._nativeZonesOriginalSize = count(Config.NATIVE_ZONES_ORIGINAL)
end

-- Saved background keys that have been renamed. "default" was the
-- original name for what turned out to be simply a transparent map.
-- "original" was Options.lua's old name for the raw stitch, replaced by
-- "raw" once the per-map-type overrides made "Original" easy to misread as
-- "the default choice". Applied to every background field on every
-- profile load (see MigrateBackgroundKeys below), not just the legacy
-- flat-file upgrade this table used to serve alone, so nobody's saved
-- choice silently reverts to Ocean Blue just because its key changed under
-- it.
local BACKGROUND_RENAMES = {
    default   = "transparent",
    original  = "raw",
}

-- Every AceDB field a background choice (global or per-map-type) can be
-- stored under. Kept as one list so a future addition only has to happen
-- here and in Config.DEFAULTS/Config.MAP_TYPES.
local BACKGROUND_FIELDS = {
    "mapBackground", "zoneMapBackground", "continentMapBackground",
    "worldMapBackground",
}

--- Apply BACKGROUND_RENAMES to every background field on *profile* (a
--- db.profile-shaped table, or the old flat SavedVariables table, which
--- has the same field names at its top level). Idempotent: safe to call on
--- every profile load, not just once at upgrade time.
---@param profile table
local function MigrateBackgroundKeys(profile)
    if type(profile) ~= "table" then return end
    for _, field in ipairs(BACKGROUND_FIELDS) do
        local renamed = BACKGROUND_RENAMES[profile[field]]
        if renamed then profile[field] = renamed end
    end
end

--- Move an old, pre-AceDB flat SavedVariables table (one profile, no
--- concept of `.profiles`) onto the AceDB profile shape, so upgrading
--- doesn't lose anyone's settings. No-op on a database that's already in
--- the new shape, or has none at all yet.
---@param dbObj table AceDB-3.0 database object
local function MigrateFlatSavedVariables(dbObj)
    local raw = HighFidelityWorldMapDB
    if type(raw) ~= "table" or raw.profiles then return end

    MigrateBackgroundKeys(raw)

    for k in pairs(Config.DEFAULTS) do
        if raw[k] ~= nil then
            dbObj.profile[k] = raw[k]
            raw[k] = nil
        end
    end
    if raw.caveWindowPoint then
        dbObj.profile.caveWindowPoint = raw.caveWindowPoint
        raw.caveWindowPoint = nil
    end
end

--- Re-point Config.db at the active profile and push the change out to
--- everything that caches state derived from it. Bound to AceDB's profile
--- callbacks below, so switching, copying or resetting a profile takes
--- effect immediately.
function Config:RefreshProfile()
    self.db = self.dbObj.profile
    MigrateBackgroundKeys(self.db)
    ns.Renderer:ForceRefresh()
    ns.ZoomLevels:Refresh()
    ns.Cave:UpdateState()
    ns.Options:Refresh()
end

--- Create the AceDB-3.0 database after ADDON_LOADED (see Core.lua's
--- OnInitialize). `true` as the default profile shares one profile across
--- every character by default, matching this addon's behavior before
--- profiles existed; AceDBOptions still lets anyone split off a
--- character-specific profile from Options.
function Config:InitDB()
    local isUpgrade = type(HighFidelityWorldMapDB) == "table"
        and not HighFidelityWorldMapDB.profiles

    self.dbObj = LibStub("AceDB-3.0"):New(
        "HighFidelityWorldMapDB", { profile = self.DEFAULTS }, true)

    if isUpgrade then
        MigrateFlatSavedVariables(self.dbObj)
    end

    self.dbObj.RegisterCallback(self, "OnProfileChanged", "RefreshProfile")
    self.dbObj.RegisterCallback(self, "OnProfileCopied", "RefreshProfile")
    self.dbObj.RegisterCallback(self, "OnProfileReset", "RefreshProfile")

    self.db = self.dbObj.profile
    MigrateBackgroundKeys(self.db)
end
