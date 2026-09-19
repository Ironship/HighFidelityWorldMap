-------------------------------------------------------------------------------
-- HFWM-Forever CaveRenderer
--
-- The cave map: a small window that floats over the world map and draws the
-- art for the cave / micro dungeon / indoor area the player is actually
-- standing in, for the very common case where the world map is showing the
-- zone above and has nothing to say about the hole you walked into.
--
-- It is a *window*, not a full-canvas overlay, and that distinction drives
-- most of what follows:
--
--   * Parented to WorldMapFrame rather than to the scroll container's child,
--     so it neither pans nor zooms with the map underneath it — a cave map
--     that slid off screen when you dragged the zone would be useless — and
--     so it hides and shows with the map for free.
--   * Its own title bar carrying the area name, and a close button, because
--     anything drawn on top of the map has to be dismissable without being
--     told which slash command to type.
--   * Sized from the cave art's own aspect ratio, clamped to something that
--     leaves the world map visible around it. A cave stretched to the shape
--     of the canvas is unreadable.
--   * Draggable, with the position remembered across sessions.
--
-- Multi-level caves get a vertical depth slider down the right-hand side,
-- one notch per floor, top floor at the top. The slider is the only widget
-- here that is hand-built rather than borrowed from FrameXML: the stock
-- slider templates are dressed for horizontal use and carry no notion of
-- discrete stops, and the depth of a dungeon is the one axis where "between
-- two floors" is a meaningless value to be able to drag to.
-------------------------------------------------------------------------------
local addonName, ns = ...
local CaveRenderer = ns.CaveRenderer
local Config       = ns.Config
local P            = ns.P

-------------------------------------------------------------------------------
-- Geometry
-------------------------------------------------------------------------------
local PAD          = 8    -- window edge -> content
local TITLE_H      = 24   -- title bar
local FOOT_H       = 16   -- floor readout under the content
local SLIDER_COL_W = 30   -- depth slider gutter, only when there are floors
local SLIDER_W     = 14   -- the track itself
local NOTCH_W      = 18   -- tick mark width
-- Fraction of the map frame the content is allowed to eat. A cave map that
-- covers the zone it is a hole in defeats the point of being a window, and
-- this is the control that is meant to do the governing: the window grows and
-- shrinks with the map, so it looks the same whether the map is windowed or
-- maximised on a 4K display.
local MAP_FRACTION_W = 0.46
local MAP_FRACTION_H = 0.58

-- Floor and ceiling on top of that fraction. The floor is legibility: below
-- about 200px a cave's corridors are a smudge. The ceiling is for the case
-- the fraction cannot reason about — a map stretched across an ultrawide,
-- where 46% is still more window than anyone wants — so it is set well clear
-- of ordinary resolutions rather than at a size that would quietly override
-- MAP_FRACTION on every normal one. At 460 it did exactly that: a 1024-wide
-- map already wants 471, so every map from a default-sized one upwards got
-- the identical window and maximising did nothing.
local MIN_CONTENT  = 200
local MAX_CONTENT  = 640

local PIN_TEXTURE = "Interface\\Minimap\\MinimapArrow"
local PIN_SIZE    = 26

local PIN_UPDATE_INTERVAL = 0.05  -- 20fps is plenty for a map pin

-------------------------------------------------------------------------------
-- Widget handles, all created lazily on first show
-------------------------------------------------------------------------------
local window        -- the frame the user sees and drags
local titleText     -- area name
local floorText     -- "Level 2 of 4 — The Deadmines"
local content       -- clipping frame the tiles and the pin live in
local backdropTex   -- flat dark fill behind the tiles
local playerPin
local sliderCol     -- gutter frame, hidden on single-floor caves
local sliderTrack   -- the notched track (a Slider, for real drag behaviour)
local notches       -- { {tick=Texture, hit=Button}, ... }

-- Content dimensions from the last layout pass. Kept rather than read back
-- with GetHeight(): a frame sized purely by its anchors does not always have
-- a resolved height in the same frame it was anchored, and the notch
-- positions have to line up with the slider thumb exactly or the widget
-- looks broken.
local contentW, contentH = 0, 0

-------------------------------------------------------------------------------
-- Inline texture pool (owned by the content frame)
--
-- Separate from the main HFWM Pool on purpose: those textures belong to the
-- world-map canvas and are released wholesale on every zone change, which is
-- exactly the wrong lifecycle for a window that outlives the map underneath
-- it changing.
-------------------------------------------------------------------------------
local cavePool        = {}
local activeCaveTiles = {}

-- Snapshot of the most recent RenderTiles call, for /hfwm debug. Not used
-- for rendering itself — purely so Commands.lua can report, per tile,
-- whether the FDID_MAP lookup hit (real baked art) or fell through to a
-- raw client FDID, without recomputing any of RenderTiles's own state.
local lastRenderInfo = nil

local function PoolAcquire()
    local tex = tremove(cavePool)
    if not tex then
        tex = content:CreateTexture(nil, "ARTWORK", nil, 3)
    end
    tex:SetVertexColor(1, 1, 1, 1)
    tex:Show()
    activeCaveTiles[#activeCaveTiles + 1] = tex
    return tex
end

local function PoolReleaseAll()
    for i = #activeCaveTiles, 1, -1 do
        local tex = activeCaveTiles[i]
        tex:Hide()
        tex:ClearAllPoints()
        activeCaveTiles[i] = nil
        cavePool[#cavePool + 1] = tex
    end
end

-------------------------------------------------------------------------------
-- Small widget helpers
-------------------------------------------------------------------------------

--- Flat dark panel with a 1px border. Deliberately the same treatment the
--- options window uses, so the two look like they came from the same addon.
local function StyleBox(frame, r, g, b, a)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(r or 0.05, g or 0.05, b or 0.07, a or 0.94)

    for _, edge in ipairs({
        { "TOPLEFT", "TOPRIGHT", nil, 1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil },
        { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }) do
        local line = frame:CreateTexture(nil, "BORDER")
        line:SetColorTexture(0.35, 0.35, 0.38, 1)
        line:SetPoint(edge[1], frame, edge[1])
        line:SetPoint(edge[2], frame, edge[2])
        if edge[3] then line:SetWidth(edge[3]) end
        if edge[4] then line:SetHeight(edge[4]) end
    end
    return bg
end

--- CreateFrame against the first template that actually exists. Same reason
--- as in Options.lua: CreateFrame *errors* on an unknown template rather than
--- returning nil, and which FrameXML templates this beta client ships is not
--- something the addon can ask about.
local function CreateFrameTry(kind, name, parent, ...)
    for i = 1, select("#", ...) do
        local ok, frame = pcall(CreateFrame, kind, name, parent, (select(i, ...)))
        if ok and frame then return frame end
    end
    return CreateFrame(kind, name, parent)
end

-------------------------------------------------------------------------------
-- Floor helpers
-------------------------------------------------------------------------------

--- Index into Config.caveAllFloors of a given mapID.
local function FloorIndex(mapID)
    local floors = Config.caveAllFloors
    if not floors then return nil end
    for i, f in ipairs(floors) do
        if f.mapID == mapID then return i end
    end
    return nil
end

local function FloorCount()
    return Config.caveAllFloors and #Config.caveAllFloors or 0
end

--- Step the active floor by `delta` indices, clamped. Index 1 is the topmost
--- floor, so a positive delta goes *down* into the cave.
local function StepFloor(delta)
    local n = FloorCount()
    if n <= 1 then return end
    local idx = FloorIndex(Config.caveCurrentFloorMapID) or 1
    local want = math.max(1, math.min(n, idx + delta))
    if want == idx then return end
    CaveRenderer:SelectFloor(Config.caveAllFloors[want].mapID)
end

-------------------------------------------------------------------------------
-- Depth slider
--
-- Slider value is the *notch number counted from the bottom*, so that the
-- deepest floor sits at the bottom of the track and the surface at the top,
-- which is the way a vertical WoW slider runs and also the way a cave does.
-- Floor indices run the other way (1 = topmost), hence the two conversions.
-------------------------------------------------------------------------------

local function ValueToIndex(value)
    return FloorCount() - math.floor(value + 0.5) + 1
end

local function IndexToValue(index)
    return FloorCount() - index + 1
end

local function EnsureSlider()
    if sliderCol then return end

    sliderCol = CreateFrame("Frame", nil, window)
    sliderCol:SetWidth(SLIDER_COL_W)

    -- The track. A real Slider rather than a texture moved by hand, so that
    -- thumb dragging, click-on-track and the step snapping all come from the
    -- widget rather than from this file.
    sliderTrack = CreateFrame("Slider", nil, sliderCol)
    sliderTrack:SetOrientation("VERTICAL")
    sliderTrack:SetWidth(SLIDER_W)
    -- Anchored at the top only, with the height set explicitly by
    -- LayoutWindow: anchoring both ends would make the height anchor-derived
    -- and therefore not reliably readable when the notches are placed.
    sliderTrack:SetPoint("TOP", sliderCol, "TOP", 0, 0)
    sliderTrack:SetValueStep(1)
    if sliderTrack.SetObeyStepOnDrag then
        sliderTrack:SetObeyStepOnDrag(true)
    end
    sliderTrack:SetThumbTexture(
        "Interface\\Buttons\\UI-SliderBar-Button-Vertical")
    local thumb = sliderTrack:GetThumbTexture()
    if thumb then thumb:SetSize(16, 20) end

    -- Track groove, drawn rather than borrowed: the stock slider backdrop is
    -- a horizontal bar texture and looks wrong stood on end. Explicit
    -- sublevels because the border has to go *under* the fill — a 1px-larger
    -- rectangle drawn on top of it would swallow the groove whole.
    local grooveEdge = sliderTrack:CreateTexture(nil, "BACKGROUND", nil, 0)
    grooveEdge:SetColorTexture(0.35, 0.35, 0.38, 1)
    local groove = sliderTrack:CreateTexture(nil, "BACKGROUND", nil, 1)
    groove:SetColorTexture(0.10, 0.10, 0.13, 1)
    groove:SetPoint("TOP", sliderTrack, "TOP", 0, -2)
    groove:SetPoint("BOTTOM", sliderTrack, "BOTTOM", 0, 2)
    groove:SetWidth(5)
    grooveEdge:SetPoint("TOPLEFT", groove, "TOPLEFT", -1, 1)
    grooveEdge:SetPoint("BOTTOMRIGHT", groove, "BOTTOMRIGHT", 1, -1)

    sliderTrack:SetScript("OnValueChanged", function(self, value)
        if self._syncing then return end
        local floors = Config.caveAllFloors
        if not floors then return end
        local floor = floors[ValueToIndex(value)]
        if floor and floor.mapID ~= Config.caveCurrentFloorMapID then
            CaveRenderer:SelectFloor(floor.mapID)
        end
    end)

    sliderTrack:EnableMouseWheel(true)
    sliderTrack:SetScript("OnMouseWheel", function(_, dir)
        -- Wheel up = up a floor = towards index 1.
        StepFloor(-dir)
    end)

    sliderTrack:SetScript("OnEnter", function(self)
        local floors = Config.caveAllFloors
        if not floors then return end
        local idx = FloorIndex(Config.caveCurrentFloorMapID) or 1
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Depth", 1, 1, 1)
        for i, f in ipairs(floors) do
            local on = (i == idx)
            GameTooltip:AddLine(
                ("%s %s"):format(on and "»" or " ", f.name or ("Level " .. i)),
                on and 0.35 or 0.7, on and 0.8 or 0.7, on and 1 or 0.7)
        end
        GameTooltip:AddLine("Drag, click or scroll to change level",
            0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    sliderTrack:SetScript("OnLeave", function() GameTooltip:Hide() end)

    notches = {}

    -- For /hfwm debug and the test harness; built lazily, so it cannot be
    -- published alongside the window itself.
    Config.caveSliderCol   = sliderCol
    Config.caveSliderTrack = sliderTrack
    Config.caveNotches     = notches
end

--- One tick mark per floor, drawn across the groove so the track reads as a
--- notched ruler. Parented to the slider at a low sublevel on purpose: the
--- thumb has to pass over the ticks, and nothing may sit *above* the track as
--- a click target or it would steal the mousedown that starts a drag.
local function GetOrCreateNotch(i)
    local notch = notches[i]
    if notch then return notch end
    notch = sliderTrack:CreateTexture(nil, "BACKGROUND", nil, 2)
    notch:SetHeight(1)
    notches[i] = notch
    return notch
end

--- Place the ticks along the track and highlight the active one.
local function LayoutNotches(floors, currentMapID)
    local n = #floors
    local trackH = contentH
    if trackH <= 0 then return end

    -- The thumb never reaches the very ends of the track — half its height is
    -- always inside it — so the ticks have to live in the same inset range or
    -- they will not line up with the thumb that is supposed to land on them.
    local inset  = 10
    local usable = trackH - inset * 2

    for i, floor in ipairs(floors) do
        local notch  = GetOrCreateNotch(i)
        local frac   = (n > 1) and ((IndexToValue(i) - 1) / (n - 1)) or 0.5
        local offset = inset + usable * frac   -- measured up from the bottom
        local active = (floor.mapID == currentMapID)

        notch:ClearAllPoints()
        notch:SetPoint("BOTTOM", sliderTrack, "BOTTOM", 0, offset)
        notch:SetWidth(active and NOTCH_W or NOTCH_W - 4)
        notch:SetHeight(active and 3 or 1)
        notch:SetColorTexture(
            active and 0.35 or 0.60,
            active and 0.80 or 0.60,
            active and 1.00 or 0.65,
            active and 1.00 or 0.80)
        notch:Show()
    end

    for i = n + 1, #notches do
        notches[i]:Hide()
    end
end

--- Pull the slider's displayed position back from the active floor.
local function SyncSlider(floors, currentMapID)
    local n = floors and #floors or 0
    if n <= 1 then
        if sliderCol then sliderCol:Hide() end
        return
    end

    EnsureSlider()

    local idx = FloorIndex(currentMapID) or 1
    -- Both calls are guarded: narrowing the range clamps the current value,
    -- which fires OnValueChanged just as surely as setting it does, and a
    -- cave with fewer floors than the last one would otherwise reselect a
    -- floor behind the user's back.
    sliderTrack._syncing = true
    sliderTrack:SetMinMaxValues(1, n)
    sliderTrack:SetValue(IndexToValue(idx))
    sliderTrack._syncing = false

    LayoutNotches(floors, currentMapID)
    sliderCol:Show()
end

-------------------------------------------------------------------------------
-- Window construction
-------------------------------------------------------------------------------

--- Remember where the user put the window.
---
--- StartMoving re-anchors the frame to the screen rather than to its parent,
--- so the anchor this reads back is usually UIParent-relative even though the
--- default one is map-relative. Which of the two it was has to be recorded
--- or the offsets get reapplied against the wrong frame and the window
--- teleports on the next login.
local function SavePosition()
    if not (Config.db and window) then return end
    local point, relTo, relPoint, x, y = window:GetPoint()
    if not point then return end
    Config.db.caveWindowPoint = {
        point    = point,
        relPoint = relPoint,
        x        = x,
        y        = y,
        toMap    = (relTo == nil or relTo == WorldMapFrame),
    }
end

local function RestorePosition()
    window:ClearAllPoints()
    local saved = Config.db and Config.db.caveWindowPoint
    if saved and saved.point then
        local anchor = saved.toMap and WorldMapFrame or UIParent
        local ok = pcall(window.SetPoint, window, saved.point, anchor,
            saved.relPoint or saved.point, saved.x or 0, saved.y or 0)
        if ok then return end
        -- A saved anchor can be invalid if the client changed the map frame
        -- out from under it; fall through to the default rather than leave
        -- an unanchored frame.
        window:ClearAllPoints()
    end
    -- Top right of the map, clear of the zone dropdown and the map's own
    -- title bar.
    window:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", -24, -72)
end

local function EnsureWindow()
    if window then return end

    window = CreateFrame("Frame", "HFWMForeverCaveWindow", WorldMapFrame)
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:EnableMouseWheel(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    window:SetScript("OnMouseWheel", function(_, dir) StepFloor(-dir) end)
    window:Hide()
    StyleBox(window, 0.03, 0.03, 0.05, 0.95)

    -- Title bar
    local bar = window:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", window, "TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", window, "TOPRIGHT", -1, -1)
    bar:SetHeight(TITLE_H)
    bar:SetColorTexture(0.10, 0.12, 0.16, 0.95)

    titleText = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", window, "TOPLEFT", PAD, -TITLE_H / 2 - 1)
    -- Right inset clears the close button, which is a 32px square hung off
    -- the corner on clients that have the template.
    titleText:SetPoint("RIGHT", window, "TOPRIGHT", -34, -TITLE_H / 2 - 1)
    titleText:SetJustifyH("LEFT")
    titleText:SetWordWrap(false)

    local close = CreateFrameTry("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", window, "TOPRIGHT", 1, 1)
    if not close:GetNormalTexture() then
        -- No close-button template on this client: draw an x of our own
        -- rather than leave an invisible hit area.
        close:SetSize(20, 20)
        local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        x:SetPoint("CENTER")
        x:SetText("x")
        close:SetScript("OnEnter", function() x:SetTextColor(1, 0.4, 0.4) end)
        close:SetScript("OnLeave", function() x:SetTextColor(1, 0.82, 0) end)
    end
    close:SetScript("OnClick", function()
        -- A close is a statement about *this* cave, not about the feature:
        -- suppress it until the player leaves, and leave the setting alone.
        ns.Cave:SuppressCurrent()
        CaveRenderer:HideCave()
    end)

    -- Content: clips its children, so a tile grid that does not divide evenly
    -- into the computed size cannot bleed over the window's border.
    content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", window, "TOPLEFT", PAD, -(TITLE_H + PAD / 2))
    if content.SetClipsChildren then content:SetClipsChildren(true) end

    backdropTex = content:CreateTexture(nil, "BACKGROUND")
    backdropTex:SetAllPoints(content)
    backdropTex:SetColorTexture(0.04, 0.04, 0.08, 1)

    playerPin = content:CreateTexture(nil, "OVERLAY", nil, 7)
    playerPin:SetTexture(PIN_TEXTURE)
    playerPin:SetSize(PIN_SIZE, PIN_SIZE)
    playerPin:Hide()

    floorText = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    floorText:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", PAD, 4)
    floorText:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -PAD, 4)
    floorText:SetJustifyH("LEFT")
    floorText:SetWordWrap(false)

    -- Kept for /hfwm debug and for the test harness, which asserts on what is
    -- actually on the window rather than on what it recomputes.
    Config.caveOverlayFrame  = window
    Config.caveContentFrame  = content
    Config.caveTitleText     = titleText
    Config.caveFloorText     = floorText
    Config.cavePlayerPin     = playerPin
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

--- Which art layer the cave window draws, as index and descriptor.
---
--- Asked of ns.Cave rather than C_Map, because on this build C_Map has no
--- answer: its UiMap table carries no interior rows at all, and the layer
--- comes from the table CaveData.lua ships instead. Cave picks the source;
--- everything here needs is that the descriptor has the same four fields
--- either way.
---
--- Only the base layer is ever used. Where C_Map does answer it can return
--- more than one layer, and the extra ones are *zoom detail* levels: the same
--- map extent re-cut at a higher tile resolution, each carrying the canvas
--- scale range it applies to. The world map canvas swaps between them as it
--- zooms. This window does not zoom — it is a small fixed panel — so layer 1,
--- the full-extent base layer, is the one it wants. A detail layer would cost
--- several times the textures to draw the same picture at a size that cannot
--- show the difference.
---
--- Renderer.lua's IsSubmerged() swap to layer 2 is a separate mechanism:
--- Vashj'ir's paired surface and underwater art, which is Cataclysm-only and
--- which Config.VASHJIR_MAPS is deliberately empty of on this client. Caves
--- have no such pairs, so keying the cave window's layer off IsSubmerged()
--- only ever picked a detail layer by accident — and did it in RenderTiles
--- while the aspect ratio was still being read from layer 1, which stretched
--- the art whenever the two layers were not cut to the same proportions.
---
--- One function, so the shape of the box and the tiles that go in it can
--- never again come from different layers.
---@param floorMapID number|nil
---@return number|nil layerIdx, table|nil layer
local function ArtLayer(floorMapID)
    return ns.Cave:GetArtLayer(floorMapID)
end

--- The cave art's own proportions, so the window is the shape of the cave
--- rather than the shape of the canvas.
local function ArtAspect(floorMapID)
    local _, layer = ArtLayer(floorMapID)
    if not layer or not layer.layerWidth or not layer.layerHeight
       or layer.layerHeight == 0 then
        return 1
    end
    return layer.layerWidth / layer.layerHeight
end

--- Size the window from the art's aspect ratio, clamped so it always leaves
--- the world map visible around it. Returns content width and height.
local function LayoutWindow(floorMapID)
    local aspect = ArtAspect(floorMapID)
    local mapW, mapH = WorldMapFrame:GetSize()
    if not mapW or mapW <= 0 then mapW, mapH = 1024, 768 end

    local maxW = math.max(MIN_CONTENT,
        math.min(MAX_CONTENT, mapW * MAP_FRACTION_W))
    local maxH = math.max(MIN_CONTENT,
        math.min(MAX_CONTENT, mapH * MAP_FRACTION_H))

    -- Fit inside the box, preserving aspect.
    local w, h = maxW, maxW / aspect
    if h > maxH then
        h = maxH
        w = maxH * aspect
    end

    local hasSlider = FloorCount() > 1
    local gutter    = hasSlider and SLIDER_COL_W or 0

    contentW, contentH = w, h
    content:SetSize(w, h)
    window:SetSize(w + PAD * 2 + gutter,
        h + TITLE_H + PAD / 2 + FOOT_H + PAD / 2)

    if hasSlider then
        EnsureSlider()
        sliderCol:ClearAllPoints()
        sliderCol:SetPoint("TOPLEFT", content, "TOPRIGHT", 2, 0)
        -- Height set outright as well as anchored: LayoutNotches needs the
        -- number this frame, and an anchor-derived size is not guaranteed to
        -- be readable yet.
        sliderCol:SetSize(SLIDER_COL_W, h)
        sliderTrack:SetHeight(h)
    elseif sliderCol then
        sliderCol:Hide()
    end

    return w, h
end

-------------------------------------------------------------------------------
-- Player pin
-------------------------------------------------------------------------------
local function UpdatePlayerPin(floorMapID)
    if not playerPin then return end
    if not floorMapID then playerPin:Hide() return end

    -- Only the floor the player is physically on gets a pin. Showing one on
    -- every floor while the user browses the depth slider would be a lie.
    if floorMapID ~= ns.Cave:GetCurrentFloorMapID() then
        playerPin:Hide()
        return
    end

    local x, y = ns.Cave:GetPlayerMapXY(floorMapID)
    if not x or not y or (x == 0 and y == 0) then
        -- (0,0) is the API's way of saying "no fix in this map's space".
        playerPin:Hide()
        return
    end

    local w, h = content:GetSize()
    if w <= 0 or h <= 0 then playerPin:Hide() return end

    playerPin:ClearAllPoints()
    playerPin:SetPoint("CENTER", content, "TOPLEFT", x * w, -(y * h))
    -- WoW facing: 0 = north, increasing counter-clockwise. SetRotation turns
    -- clockwise for positive values, so negate. Nil while the camera is
    -- mid-transition (taxi, cinematic) — point the arrow north rather than
    -- erroring in an OnUpdate.
    local facing = GetPlayerFacing()
    playerPin:SetRotation(facing and -facing or 0)
    playerPin:Show()
end

local pinAccum = 0
local function OnWindowUpdate(_, elapsed)
    if not Config.caveOverlayActive then return end
    pinAccum = pinAccum + elapsed
    if pinAccum < PIN_UPDATE_INTERVAL then return end
    pinAccum = 0
    UpdatePlayerPin(Config.caveCurrentFloorMapID)
end

-------------------------------------------------------------------------------
-- Tile rendering
--
-- Mirrors Renderer.lua's layout maths, against the content frame rather than
-- the map canvas. Cave and dungeon art is not in the bundled tile set — the
-- pipeline stitches outdoor zones — so in practice every lookup below misses
-- and the client's own FileDataIDs are drawn. The lookup is done anyway so
-- that a future art pass covering interiors needs no change here.
-------------------------------------------------------------------------------
function CaveRenderer:RenderTiles(floorMapID)
    if not content then return end

    local canvasW, canvasH = content:GetSize()
    if canvasW <= 0 or canvasH <= 0 then return end

    local layerIdx, layer = ArtLayer(floorMapID)
    if not layer then
        if Config.tracing then
            P("CaveRenderer: no art layers for mapID " .. tostring(floorMapID))
        end
        return false
    end

    local layerW   = layer.layerWidth
    local layerH   = layer.layerHeight
    local tilePxW  = layer.tileWidth  or 256
    local tilePxH  = layer.tileHeight or 256
    local cols     = math.ceil(layerW / tilePxW)
    local rows     = math.ceil(layerH / tilePxH)

    local fdids = ns.Cave:GetArtTextures(floorMapID, layerIdx)
    if not fdids or #fdids == 0 then
        if Config.tracing then
            P("CaveRenderer: no FDIDs for mapID " .. tostring(floorMapID))
        end
        return false
    end

    local FDID_MAP  = Config:GetTileMap(Config:GetBackground())
    local FDID_BASE = Config.FDID_BASE

    local scaleX = canvasW / layerW
    local scaleY = canvasH / layerH
    local tileIdx = 1

    lastRenderInfo = {
        floorMapID = floorMapID,
        layerW = layerW, layerH = layerH,
        tileW = tilePxW, tileH = tilePxH,
        cols = cols, rows = rows,
        tiles = {},
    }

    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local fdid = fdids[tileIdx]
            if not fdid then break end

            local rel = FDID_MAP[fdid]
            local src = rel and (FDID_BASE .. rel) or fdid

            lastRenderInfo.tiles[tileIdx] = {
                fdid = fdid, bundled = (rel ~= nil), rel = rel, src = src,
            }

            local artTileW = math.min(tilePxW, layerW - col * tilePxW)
            local artTileH = math.min(tilePxH, layerH - row * tilePxH)

            local tex = PoolAcquire()
            tex:SetSize(artTileW * scaleX, artTileH * scaleY)
            tex:SetPoint("TOPLEFT", content, "TOPLEFT",
                col * tilePxW * scaleX, -(row * tilePxH * scaleY))
            tex:SetTexCoord(0, artTileW / tilePxW, 0, artTileH / tilePxH)
            tex:SetTexture(src)
            tileIdx = tileIdx + 1
        end
    end

    return #activeCaveTiles > 0
end

--- Snapshot of the most recent RenderTiles call (layer dims + per-tile FDID
--- lookup results), for /hfwm debug. Returns nil if no floor has been
--- rendered yet this session.
function CaveRenderer:DebugTiles()
    return lastRenderInfo
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Show (or re-render) the cave window on a given floor.
---@param floorMapID number UiMapID of the floor to draw
function CaveRenderer:ShowCave(floorMapID)
    if not floorMapID then return end
    EnsureWindow()

    -- Above every part of the map, including its border frame and pins. The
    -- map's own strata is used rather than a fixed one so the window rides
    -- along when the client moves the map between strata (windowed vs.
    -- maximised), and a large level offset puts it over the map's children.
    if window:GetParent() ~= WorldMapFrame then
        window:SetParent(WorldMapFrame)
    end
    window:SetFrameStrata(WorldMapFrame:GetFrameStrata())
    window:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 800)
    if not window:GetPoint() then RestorePosition() end

    -- Normally Cave:UpdateState has already built this, but ShowCave is also
    -- reachable from Relayout and from the slash commands, so it does not
    -- assume.
    if not Config.caveAllFloors then
        Config.caveAllFloors = ns.Cave:BuildFloorList(floorMapID)
    end

    PoolReleaseAll()
    LayoutWindow(floorMapID)

    local drew = self:RenderTiles(floorMapID)
    titleText:SetText(ns.Cave:GetAreaTitle(floorMapID))

    local floors = Config.caveAllFloors
    local n = floors and #floors or 0
    if n > 1 then
        local idx = FloorIndex(floorMapID) or 1
        local name = floors[idx] and floors[idx].name
        floorText:SetText(("Level %d of %d%s"):format(
            idx, n, name and ("  |cff777777" .. name .. "|r") or ""))
    elseif drew then
        floorText:SetText("|cff777777Single level|r")
    else
        floorText:SetText("|cffff7777No map art for this area|r")
    end

    SyncSlider(floors, floorMapID)
    UpdatePlayerPin(floorMapID)

    window:SetAlpha(Config:CaveAlpha())
    window:Show()

    Config.caveOverlayActive     = true
    Config.caveCurrentFloorMapID = floorMapID
    window:SetScript("OnUpdate", OnWindowUpdate)

    if Config.tracing then
        P(("CaveRenderer:ShowCave mapID=%s tiles=%d floors=%d"):format(
            tostring(floorMapID), #activeCaveTiles, n))
    end
end

--- Switch floors without tearing the window down, so the user's scroll
--- through the depth slider does not flicker.
---@param floorMapID number
function CaveRenderer:SelectFloor(floorMapID)
    if not floorMapID then return end
    if not Config.caveOverlayActive then
        self:ShowCave(floorMapID)
        return
    end
    -- Remember that the user drove: Cave:UpdateState must not yank them back
    -- to the floor they are standing on a moment later.
    Config.caveFloorPinned = (floorMapID ~= ns.Cave:GetCurrentFloorMapID())
    self:ShowCave(floorMapID)
end

function CaveRenderer:HideCave()
    Config.caveOverlayActive     = false
    Config.caveCurrentFloorMapID = nil
    Config.caveAllFloors         = nil
    Config.caveFloorPinned       = false
    if not window then return end
    PoolReleaseAll()
    if playerPin then playerPin:Hide() end
    window:SetScript("OnUpdate", nil)
    window:Hide()
end

--- Re-run the layout against the current map-frame size. Debounced, because
--- OnSizeChanged fires every frame of a maximise animation and each pass
--- re-renders the whole tile grid.
local relayoutPending = false
function CaveRenderer:Relayout()
    if relayoutPending then return end
    if not (Config.caveOverlayActive and Config.caveCurrentFloorMapID) then
        return
    end
    relayoutPending = true
    C_Timer.After(0.05, function()
        relayoutPending = false
        if Config.caveOverlayActive and Config.caveCurrentFloorMapID then
            self:ShowCave(Config.caveCurrentFloorMapID)
        end
    end)
end

--- Apply the opacity setting to an already-open window.
function CaveRenderer:ApplyAlpha()
    if window then window:SetAlpha(Config:CaveAlpha()) end
end

function CaveRenderer:IsShown()
    return window and window:IsShown() and true or false
end

function CaveRenderer:ActiveTileCount()
    return #activeCaveTiles
end
