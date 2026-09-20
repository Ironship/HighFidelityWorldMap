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
--- The border's two dimensions, and the reason they are separate.
---
--- ApplyNineSliceBorder builds this window's frame out of copies of
--- WorldMapFrame's own NineSlice pieces, and it used to draw each corner at
--- `src:GetWidth(), src:GetHeight()` — the piece's *native* size. That is
--- where this window's whole layout came apart: WorldMapFrame is a ~1000px
--- frame and its corner art is authored to match, so a native-size copy put a
--- 100px+ slab of trim on a 600px panel. Everything downstream was then
--- hand-tuned around that slab rather than around the border — which is how
--- TITLE_H ended up at 112 (a number with no relationship to the title font,
--- only to how far down the oversized top corners reached) and how the
--- background fill ended up inset far enough to read as a second, offset
--- panel sitting behind the header.
---
--- So the art is now drawn at a size this window chooses, not at whatever
--- size the map frame happens to want:
---   BORDER_ART   - the square the corner pieces are drawn in, and the
---                  thickness of the four edges that span between them.
---   BORDER_INSET - window edge -> interior (title bar, content, footer).
--- Both are deliberately the same numbers DIALOG_BACKDROP below already
--- declares for the game's own dialog border art (edgeSize 32, insets 11/12),
--- so the NineSlice-copy path and the DIALOG_BACKDROP fallback path put their
--- interior in the same place instead of each needing its own tuning.
local BORDER_ART   = 32   -- corner square / edge thickness
local BORDER_INSET = 12   -- window edge -> interior
-- Frame levels above the window the border art is painted at. Has to clear
-- every other child of the window: the title bar (+1), the close button
-- (+2), and the height-window handles (+4 at the deepest).
local BORDER_LEVEL = 10
local PAD          = 8    -- text inset inside the interior
--- Fallback height of the title bar, used only when the real map's title
--- strip cannot be measured (see CloneTitleStrip). Four numbers have been
--- hand-picked here across as many rounds — 112, 26, BORDER_ART, then
--- math.max(BORDER_ART, font + 2*PAD) — and every one of them was a guess at
--- a quantity the client already knows. The header now takes its height from
--- the strip it cloned, so this is a floor to fall back on, not a layout
--- decision. It still has to clear BORDER_ART, or the content would start
--- underneath the border's own top edge.
local TITLE_FONT_H = 22   -- GameFontNormal line height + padding above/below
local TITLE_H      = math.max(BORDER_ART, TITLE_FONT_H + PAD * 2)
--- The measured header height, once known: the bottom of the cloned title
--- strip, floored at TITLE_H. Everything that has to sit below the header
--- (the content frame, the window's own height) reads this rather than the
--- constant, so a client whose title bar is taller or shorter than the
--- fallback still gets a window that fits it.
local titleH       = TITLE_H
local CLOSE_BTN    = TITLE_H - 8  -- close button, sized to sit in the bar
local FOOT_H       = 16   -- floor readout under the content
local SLIDER_COL_W = 30   -- depth slider gutter, only when there are floors
local SLIDER_W     = 14   -- the track itself
local NOTCH_W      = 18   -- tick mark width
-- The thumb never reaches the very ends of a vertical Slider's track — half
-- its height is always inside it — so anything else meant to line up with
-- floor notches or a fraction of the track (LayoutNotches, the height-window
-- rectangle) has to live inside the same inset range, or it will not agree
-- with where the thumb itself can land.
local SLIDER_INSET = 10
-- cave-satellite-v2 Phase 2's height-window rectangle: how wide, past the
-- window's exact edges, the widget's drag handles reach — a purely cosmetic
-- amount of extra grab room, not part of the elevation math.
local HEIGHT_WINDOW_HANDLE_H = 8
-- Fixed cosmetic smoothing for a piece just outside the height window: fades
-- to invisible over this many yards rather than popping, the same way the
-- old fixed per-piece margin used to. Not user-adjustable — the window
-- rectangle itself is the adjustable control now.
local EDGE_FADE_YARDS = 2
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

-- Floor picker (dropdown) — see the "Floor picker" section below. Passed to
-- UIDropDownMenu_SetWidth, which sizes the *visible* text/button area; the
-- template's own frame ends up wider than this (see EnsureFloorPicker's
-- -40 note).
local FLOOR_PICKER_W = 120

--- Blizzard's own colour for a Battle.net-linked friend's name (Friends
--- List, whispers) — the closest thing the client already defines to an
--- official "Blizzard cyan", reused here for the "All" entry's text rather
--- than a colour this addon picked itself. Falls back to the literal hex on
--- a client build that doesn't expose the constant as a global.
local BLIZZARD_CYAN_HEX = FRIENDS_BNET_NAME_COLOR_CODE or "|cff82c5ff"

-------------------------------------------------------------------------------
-- Widget handles, all created lazily on first show
-------------------------------------------------------------------------------
local window        -- the frame the user sees and drags
local titleBar      -- header band; its .hfwmStrip is the cloned map title art
local closeBtn      -- the x, in the top-right corner
local titleText     -- area name
local floorText     -- "Level 2 of 4 — The Deadmines"
local content       -- clipping frame the tiles and the pin live in
local backdropTex   -- flat dark fill behind the tiles
local playerPin
local sliderCol     -- gutter frame, hidden on single-floor caves
local sliderTrack   -- the notched track (a Slider, for real drag behaviour)
local notches       -- { {tick=Texture, hit=Button}, ... }

-- Floor picker (dropdown), top-right of the content frame — see the "Floor
-- picker" section below. A real UIDropDownMenuTemplate frame, built lazily;
-- `floorPickerUnavailable` is set once and for all if that template turns
-- out not to exist on this client, so EnsureFloorPicker stops retrying.
local floorPicker
local floorPickerUnavailable

-- cave-satellite-v2 Phase 2's height-window rectangle: a draggable/resizable
-- overlay on the depth slider itself (see EnsureHeightWindow), replacing a
-- single slider point with a range the user can both move and resize.
-- `windowBody` is the whole rectangle (drag to move); `windowTopHandle`/
-- `windowBottomHandle` are grab strips at its edges (drag to resize).
-- `heightWindowDrag`, when non-nil, is `{ kind = "top"|"bottom"|"body",
-- startFrac, startTop, startBottom }` for whichever of the three is
-- currently being dragged.
local windowBody
local windowTopHandle, windowBottomHandle
local heightWindowDrag

-- Reopen icon: shown in place of the window when Cave.lua has a cave to
-- display but the window is closed (the player clicked the close button, or
-- it hasn't been opened yet this visit). See EnsureReopenButton and
-- CaveRenderer:SetReopenAvailable below.
local reopenBtn

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

-- Continuous-depth crossfade state (see the "Depth slider" section below for
-- the alpha math). `continuousActive` is true only while the currently
-- shown place has ns.Cave:HasContinuousDepth() for its floors (currently
-- just Fargodeep Mine) *and* has more than one floor; every other cave keeps
-- the original hard-swap behaviour. `continuousTileGroups` holds every
-- floor's tiles simultaneously in that mode — index i is floor i of
-- Config.caveAllFloors — so their alpha can be pushed independently as the
-- slider moves, rather than the single floor's worth `activeCaveTiles` holds
-- the rest of the time.
local continuousActive     = false
local continuousTileGroups = {}

-- cave-satellite-v2 Phase 2: per-piece continuous fade state. `piecesActive`
-- is true only while the currently shown place has ns.Cave:GetPieces() for
-- its floors (currently just Fargodeep Mine) — a finer-grained replacement
-- for `continuousActive`'s whole-floor crossfade, not an addition to it, so
-- the two are mutually exclusive (see ShowCave). `continuousPieceGroups`
-- holds every piece's texture and its own {zMin, zMax} simultaneously, so
-- each can fade independently by real elevation as the slider moves.
-- `piecesZMin`/`piecesZMax` are the aggregate real-world-Z range spanned by
-- every piece currently rendered (not any one floor's own zMin/zMax), which
-- is what lets a 2-notch floor slider sweep continuously through every
-- piece's height in between rather than just the two floor labels the
-- notches are drawn at — see ElevationForValue.
local piecesActive         = false
local continuousPieceGroups = {}
local piecesZMin, piecesZMax

-- Snapshot of the most recent RenderTiles call, for /hfwm debug. Not used
-- for rendering itself — purely so Commands.lua can report, per tile,
-- whether the FDID_MAP lookup hit (real baked art) or fell through to a
-- raw client FDID, without recomputing any of RenderTiles's own state. In
-- continuous mode RenderTiles runs once per floor, so this ends up holding
-- whichever floor rendered last (the deepest); Commands.lua reports
-- per-floor alpha separately via CaveRenderer:DebugContinuous().
local lastRenderInfo = nil

--- `group`, when given, also collects the acquired texture so its caller can
--- drive its alpha independently later (the continuous crossfade path).
local function PoolAcquire(group)
    local tex = tremove(cavePool)
    if not tex then
        tex = content:CreateTexture(nil, "ARTWORK", nil, 3)
    end
    tex:SetVertexColor(1, 1, 1, 1)
    tex:Show()
    activeCaveTiles[#activeCaveTiles + 1] = tex
    if group then group[#group + 1] = tex end
    return tex
end

local function PoolReleaseAll()
    for i = #activeCaveTiles, 1, -1 do
        local tex = activeCaveTiles[i]
        tex:Hide()
        tex:ClearAllPoints()
        -- Reset to the default sublevel so a tile last used in a continuous
        -- fade (see RenderContinuousFloors) doesn't carry that draw order
        -- into whatever reuses it next.
        tex:SetDrawLayer("ARTWORK", 3)
        activeCaveTiles[i] = nil
        cavePool[#cavePool + 1] = tex
    end
    for i = #continuousTileGroups, 1, -1 do
        continuousTileGroups[i] = nil
    end
    for i = #continuousPieceGroups, 1, -1 do
        continuousPieceGroups[i] = nil
    end
end

-------------------------------------------------------------------------------
-- Small widget helpers
-------------------------------------------------------------------------------

--- The game's own dialog-box border: the thick ornate gold-scroll frame
--- used on every popup dialog, the Game Menu, and confirmation windows —
--- the "metal border" look, not the thin tooltip hairline this used to
--- point at. Same two file names FrameXML has used since vanilla:
--- Interface\DialogFrame\UI-DialogBox-Border (edge) and
--- Interface\DialogFrame\UI-DialogBox-Background (tiled backing). Built
--- from those exact file paths rather than an assumed global, since unlike
--- the tooltip backdrop this one isn't reliably exposed as a ready-made
--- global table on every client.
local DIALOG_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile     = true,
    tileSize = 32,
    edgeSize = 32,
    insets   = { left = 11, right = 12, top = 12, bottom = 11 },
}

--- Bronze/gold hand-drawn fallback for a client old enough to lack
--- BackdropTemplate entirely (pre-8.0) — kept only so nothing goes fully
--- borderless on such a client, not the default treatment any more.
local BORDER_BRONZE = { 0.45, 0.34, 0.16, 1 }
local BORDER_GOLD    = { 0.80, 0.64, 0.32, 1 }

local function StyleBoxFallback(frame, r, g, b, a)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(r or 0.07, g or 0.055, b or 0.03, a or 0.94)

    for _, edge in ipairs({
        -- side1, side2, width, height, inward-x, inward-y (for the inner
        -- hairline, one pixel toward the frame's centre from the outer line)
        { "TOPLEFT", "TOPRIGHT", nil, 1, 0, -1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1, 0, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil, 1, 0 },
        { "TOPRIGHT", "BOTTOMRIGHT", 1, nil, -1, 0 },
    }) do
        local outer = frame:CreateTexture(nil, "BORDER", nil, 0)
        outer:SetColorTexture(unpack(BORDER_BRONZE))
        outer:SetPoint(edge[1], frame, edge[1])
        outer:SetPoint(edge[2], frame, edge[2])
        if edge[3] then outer:SetWidth(edge[3]) end
        if edge[4] then outer:SetHeight(edge[4]) end

        local inner = frame:CreateTexture(nil, "BORDER", nil, 1)
        inner:SetColorTexture(unpack(BORDER_GOLD))
        inner:SetPoint(edge[1], frame, edge[1], edge[5], edge[6])
        inner:SetPoint(edge[2], frame, edge[2], edge[5], edge[6])
        if edge[3] then inner:SetWidth(edge[3]) end
        if edge[4] then inner:SetHeight(edge[4]) end
    end
    return bg
end

--- Copy one live region's art (atlas or texture, plus its tint) onto
--- another. Used by ApplyNineSliceBorder to rebuild this window's frame out
--- of WorldMapFrame's own border pieces.
---
--- The other consumer is CloneTitleStrip, which copies the map's title bar the
--- same way. A note that used to sit here claimed, on the strength of an
--- /fstack dump, that "TitleContainer holds nothing but WorldMapFrameTitleText
--- — no art at all", and concluded the map has no header graphic because its
--- header *is* the top edge of its border. That was wrong, and believing it
--- cost three rounds of invented title bars: the map plainly does draw a title
--- band behind "Map & Quest Log". Whether the art hangs off TitleContainer or
--- off BorderFrame is exactly the sort of thing that differs between clients
--- and that an /fstack read once should not be generalised from, which is why
--- CollectTitleStrip now walks both and cares about neither.
---
--- useAtlasSize is deliberately *false*. Every caller here sizes the copy
--- itself (the border to BORDER_ART, each title piece to its measured size), so
--- taking the atlas's authored size is at best redundant — and at worst it is
--- the thing that wins: a copy whose anchoring step fails part-way is left
--- holding an atlas-native size and no points at all, which renders it centred
--- on its parent at whatever size the artist drew it. That is a stray plaque
--- floating in the middle of the frame, not a band, and it is indistinguishable
--- on screen from "the title bar is the wrong size".
local function CopyRegionArt(src, dst)
    local atlas = src.GetAtlas and src:GetAtlas()
    if atlas then
        dst:SetAtlas(atlas, false)
    elseif src.GetTexture and src:GetTexture() then
        dst:SetTexture(src:GetTexture())
        if src.GetTexCoord then dst:SetTexCoord(src:GetTexCoord()) end
    else
        return false
    end
    if src.GetVertexColor then dst:SetVertexColor(src:GetVertexColor()) end
    return true
end

local function IsTexture(region)
    return region and region.GetObjectType and region:GetObjectType() == "Texture"
end

--- The eight border pieces this window rebuilds its own frame out of. Named
--- once, up here, because two places need the list: ApplyNineSliceBorder,
--- which clones them, and CollectTitleStrip, which has to *skip* them.
local NINE_SLICE_PIECES = {
    "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
    "TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
}

--- Neutralise a texture we decided not to keep. Textures cannot be destroyed,
--- and an abandoned half-built one is not harmless (see CopyRegionArt): art
--- set, anchors never applied, so it renders centred on its parent at native
--- size. Every step is its own pcall — one refusing must not skip the rest.
local function DiscardTexture(tex)
    if not tex then return end
    pcall(tex.ClearAllPoints, tex)
    pcall(tex.SetTexture, tex, nil)
    pcall(tex.SetAlpha, tex, 0)
    pcall(tex.Hide, tex)
end

-------------------------------------------------------------------------------
-- Title bar: cloned off the live map, not composed here
-------------------------------------------------------------------------------

--- Three rounds of this file tried to *compose* a title bar out of art chosen
--- here — first the border's own NineSlice.TopEdge, then a hardcoded
--- UI-DialogBox-Gold-Header path, then a hand-drawn fill with a gold hairline
--- — and each was wrong in its own way. They were all wrong for the same
--- reason, though, which is the only part worth keeping: "what art is the
--- map's title bar made of, and where exactly does it sit" is a question about
--- the running client, and it cannot be answered by picking assets in an addon
--- file. Every attempt to answer it from here was a guess dressed up as a
--- fallback chain.
---
--- So nothing below chooses any art. It measures the real map frame's title
--- strip at runtime and replays it: the same textures, at the same heights, at
--- the same offset below the frame's top, with the same horizontal insets. If
--- the map's title bar is a centred plaque, this window gets that plaque at
--- that width; if it is a full-width band, this window gets that band inset
--- the same amount at each end. The title text is placed by measuring the
--- map's own title FontString the same way, so the text sits on the band
--- exactly as far down as it does on the real thing.

--- How far below a frame's top edge a texture can start and still belong to
--- that frame's title strip rather than to its body. Generous enough for a
--- title bar with trim above and below it, tight enough to exclude the map's
--- backdrop and canvas.
local TITLE_STRIP_DEPTH = 64

--- Shortest a texture is allowed to be and still count as title *art*
--- rather than an incidental hairline/rule. The map draws a 1-2px divider
--- under its own title text as ordinary chrome, the same category of thing
--- as the NineSlice border pieces this window already rebuilds itself and
--- deliberately excludes (see NINE_SLICE_PIECES/skip below) rather than
--- clones. A divider like that is also exactly what a mis-measured band
--- reads as on screen: a long, thin, otherwise-unexplained bar, since a
--- texture this thin has no visible shape of its own to look "wrong" by —
--- only its position and length do, and both are the two things CloneTitleStrip
--- is most at risk of getting wrong for a piece with no readable content to
--- sanity-check the math against. Filtering it out here, rather than fixing
--- its placement, means there's nothing left to mis-place.
local TITLE_STRIP_MIN_HEIGHT = 4

--- A region's screen rect, or nil if it has none yet. A frame that has never
--- been laid out answers nil for all four, which is the normal state early in
--- login and is why every caller here treats nil as "ask again later" rather
--- than as "no title bar".
local function RectOf(o)
    if not (o and o.GetLeft and o.GetRight and o.GetTop and o.GetBottom) then
        return nil
    end
    local l, r, t, b = o:GetLeft(), o:GetRight(), o:GetTop(), o:GetBottom()
    if not (l and r and t and b) then return nil end
    if r <= l or t <= b then return nil end
    return l, r, t, b
end

--- The map's own title FontString, wherever this client keeps it.
local function MapTitleFontString()
    local borderFrame = WorldMapFrame and WorldMapFrame.BorderFrame
    local container   = borderFrame and borderFrame.TitleContainer
    for _, host in ipairs({ container, borderFrame }) do
        if host and host.GetRegions then
            for _, r in ipairs({ host:GetRegions() }) do
                if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                    return r
                end
            end
        end
    end
    return (container and container.TitleText) or WorldMapFrameTitleText
end

--- Every texture in the map frame's title strip, measured relative to the
--- frame itself so the numbers can be replayed onto a window of a different
--- size. Returns the pieces plus the reference frame's top edge and horizontal
--- centre.
---
--- nil means one specific thing: the map frame has no rect yet, so the answer
--- is unknown and worth asking for again. An *empty* list is a different and
--- final answer — the frame was measured and has no title art — and the two
--- must not be conflated, or a client whose map genuinely has no title band
--- would be re-measured on every single layout, forever, waiting for an answer
--- that already arrived.
---
--- The eight NineSlice pieces are excluded by *identity*, not by name or by
--- position: this window already rebuilds those as its own border, so cloning
--- them here too would paint the top trim twice — which is exactly the "two
--- stacked bars at the top" this dialog shipped with two rounds ago.
local function CollectTitleStrip()
    local borderFrame = WorldMapFrame and WorldMapFrame.BorderFrame
    if not borderFrame then return nil end

    local fl, fr, ft = RectOf(borderFrame)
    if not fl then return nil end

    local skip      = {}
    local nineSlice = borderFrame.NineSlice
    if nineSlice then
        for _, key in ipairs(NINE_SLICE_PIECES) do
            if nineSlice[key] then skip[nineSlice[key]] = true end
        end
    end

    local frameCX, frameW = (fl + fr) / 2, fr - fl
    local pieces = {}

    local function consider(region)
        if not IsTexture(region) or skip[region] then return end
        if region.IsShown and not region:IsShown() then return end
        local l, r, t, b = RectOf(region)
        if not l then return end
        local topInset, height = ft - t, t - b
        -- Inside the strip: starts at or below the frame's top, no deeper than
        -- the strip, and not tall enough to be the map's body art.
        if topInset < -0.5 or topInset > TITLE_STRIP_DEPTH then return end
        if height > TITLE_STRIP_DEPTH then return end
        -- Nor thin enough to be a hairline/rule rather than art — see
        -- TITLE_STRIP_MIN_HEIGHT.
        if height < TITLE_STRIP_MIN_HEIGHT then return end
        local layer, sublevel = "ARTWORK", 0
        if region.GetDrawLayer then layer, sublevel = region:GetDrawLayer() end
        pieces[#pieces + 1] = {
            region     = region,
            topInset   = topInset,
            height     = height,
            leftInset  = l - fl,
            rightInset = fr - r,
            width      = r - l,
            centerDX   = (l + r) / 2 - frameCX,
            layer      = layer,
            sublevel   = sublevel or 0,
        }
    end

    -- TitleContainer first so its pieces keep their relative order, then the
    -- border frame itself, since which of the two holds the band differs
    -- between clients and there is no reason to care which one it was.
    for _, host in ipairs({ borderFrame.TitleContainer, borderFrame }) do
        if host and host.GetRegions then
            for _, region in ipairs({ host:GetRegions() }) do consider(region) end
        end
    end

    return pieces, ft, frameCX, frameW
end

--- Reproduce the collected strip on `bar`, which must be anchored flush to the
--- cave window's own top-left and top-right.
---
--- Each piece is replayed as either stretched or fixed-width, decided by what
--- it *is* on the real frame rather than by preference: a piece that reaches
--- both of the frame's edges is a band, and is re-anchored to both of the
--- bar's ends so it spans this window too; anything that stops short of them
--- is a plaque, and keeps its authored width, centred at the same offset from
--- centre it has on the map. Stretching a plaque to full width, or centring a
--- band at its native width, are the two ways this can look wrong.
---
--- Getting that test scale-free took three tries, and the two rejected ones
--- are worth recording because both look obviously right:
---   width >= frameW - k   - reads correctly only while the frame is wide. A
---                           400px plaque is clearly not a band on a 1000px
---                           frame; the same test calls it one at 500px.
---   insets <= k           - same failure from the other side. A plaque on a
---                           narrow frame has small absolute margins.
--- Both compare the piece against the *frame*, which is the wrong reference:
--- whether something is trim or a plaque is a fact about the piece. Trim hugs
--- the edge it belongs to, so its inset is of the same order as its own
--- thickness; a plaque's margins are large multiples of its height. Comparing
--- the inset to the piece's own height is therefore scale-free in the way the
--- other two only appear to be. BORDER_INSET is a floor for the degenerate
--- case of art only a pixel or two tall.
local function IsBand(p)
    local slack = math.max(p.height, BORDER_INSET)
    return p.leftInset <= slack and p.rightInset <= slack
end

--- Replay the strip onto `bar`.
---
--- Returns the bottom of the strip (as a distance below the window's top edge)
--- and the number of pieces cloned. On failure returns nil plus which kind of
--- failure it was: "unmeasurable" is worth retrying, "noart" is final.
local function CloneTitleStrip(bar)
    local pieces, frameTop, frameCX = CollectTitleStrip()
    if not pieces then return nil, "unmeasurable" end

    -- The frame of reference every cloned offset below is measured against:
    -- the map frame's top edge and horizontal centre. PlaceTitleText needs it
    -- too, to put the title where the map puts its own -- but only when art
    -- was actually cloned, for the reason recorded there.
    bar.hfwmFrameTop, bar.hfwmFrameCX = frameTop, frameCX

    local kept, bottom = {}, 0
    for _, p in ipairs(pieces) do
        local copy = bar:CreateTexture(nil, p.layer, nil, p.sublevel)
        local ok = pcall(function()
            if not CopyRegionArt(p.region, copy) then error("no art") end
            copy:ClearAllPoints()
            if IsBand(p) then
                copy:SetPoint("TOPLEFT", bar, "TOPLEFT",
                    p.leftInset, -p.topInset)
                copy:SetPoint("TOPRIGHT", bar, "TOPRIGHT",
                    -p.rightInset, -p.topInset)
                copy:SetHeight(p.height)
            else
                copy:SetSize(p.width, p.height)
                copy:SetPoint("TOP", bar, "TOP", p.centerDX, -p.topInset)
                -- Remembered so ClampTitleStripPlaques (below) can shrink
                -- this back down once the cave window's own, much smaller,
                -- width is known — see that function for why a plaque needs
                -- this and a band does not.
                copy.hfwmPlaqueNativeWidth = p.width
            end
        end)
        if ok then
            kept[#kept + 1] = copy
            bottom = math.max(bottom, p.topInset + p.height)
        else
            DiscardTexture(copy)
        end
    end

    if #kept == 0 then return nil, "noart" end
    bar.hfwmStrip = kept
    return bottom, #kept
end

--- Place the cave window's title text where the map puts its own: the same
--- distance below the frame's top edge, and the same offset from the frame's
--- horizontal centre.
---
--- `cloned` says whether the art the map aligns that text to actually made it
--- onto the bar, and it decides which of those two placements is faithful.
--- Replaying the map's absolute vertical offset only means anything when the
--- band is there to be aligned to; with no art the header is the fallback
--- height instead, and copying an offset measured against the map's much
--- taller title area drops the text straight through the bottom of it. That is
--- the "title is underneath the header" this window has already shipped once,
--- so this path centres the text in the header it actually has. The font is
--- copied either way — that part is faithful regardless.
---@return number|nil  the text's bottom, as a distance below the window top
local function PlaceTitleText(text, bar, barHeight, cloned)
    text:ClearAllPoints()
    local src = MapTitleFontString()
    if src and src.GetFontObject and src:GetFontObject() then
        pcall(text.SetFontObject, text, src:GetFontObject())
    end

    local l, r, t, b = RectOf(src)
    if cloned and l and bar.hfwmFrameTop and bar.hfwmFrameCX then
        local cy = (t + b) / 2
        text:SetPoint("CENTER", bar, "TOP",
            (l + r) / 2 - bar.hfwmFrameCX, -(bar.hfwmFrameTop - cy))
        return (bar.hfwmFrameTop - b)
    end
    text:SetPoint("CENTER", bar, "TOP", 0, -(barHeight / 2))
    return barHeight
end

--- Give the cave window its header: clone the map's title strip onto `bar`,
--- take the header's height from what was cloned, and put the title text where
--- the map puts its own.
---
--- Deliberately safe to call more than once. The map frame has no rect to
--- measure until it has been laid out at least once, and this runs while the
--- cave window is first built, which can be earlier than that — so a failure
--- here is not final and LayoutWindow calls it again until it takes. Retrying
--- is also why the previous clone is cleared first: a second strip layered over
--- the first would double every piece, which is the same "two bars at the top"
--- this window has already shipped once.
---
--- On failure the header is left unpainted rather than filled in with
--- something invented. An unpainted header is a visible, reversible state that
--- the retry fixes; a hand-drawn stand-in is neither, and drawing one is how
--- three rounds of guessed art got into this file in the first place.
local function ApplyTitleStrip(bar)
    if not bar then return false end

    if bar.hfwmStrip then
        for _, tex in ipairs(bar.hfwmStrip) do DiscardTexture(tex) end
        bar.hfwmStrip = nil
    end

    local bottom, countOrWhy = CloneTitleStrip(bar)
    if bottom then
        local textBottom = PlaceTitleText(titleText, bar, bottom, true)
            or bottom
        -- The header clears whichever reaches further down, art or text, and
        -- can never be thinner than the border's own top edge — otherwise the
        -- content below would begin underneath the trim.
        titleH = math.max(BORDER_ART,
            math.ceil(math.max(bottom, textBottom)) + 1)
        bar.hfwmCloned  = true
        bar.hfwmSettled = true
        Config.caveTitleBannerSource = ("cloned %d piece%s off the map's "
            .. "title strip; header %dpx"):format(
                countOrWhy, countOrWhy == 1 and "" or "s", titleH)
    else
        titleH = TITLE_H
        bar.hfwmCloned = false
        PlaceTitleText(titleText, bar, titleH, false)
        -- "noart" is an answer, not a delay: this client's map has no title
        -- band, so there will never be one to clone and retrying every layout
        -- would be a permanent no-op. "unmeasurable" means the map frame has
        -- not been laid out yet, which the next layout may well fix.
        bar.hfwmSettled = (countOrWhy == "noart")
        Config.caveTitleBannerSource = bar.hfwmSettled
            and "the map has no title art to clone; plain header"
            or  "pending: map frame not measurable yet"
    end

    bar:SetHeight(titleH)
    return bar.hfwmSettled
end

--- Re-apply a header height that ApplyTitleStrip has just changed to the two
--- things sized against it. Separate from ApplyTitleStrip because that runs
--- once during EnsureWindow, before either of these exists, and again later
--- from LayoutWindow, when both do.
local function ApplyTitleHeight()
    if content and window then
        content:ClearAllPoints()
        content:SetPoint("TOPLEFT", window, "TOPLEFT", BORDER_INSET, -titleH)
    end
    if closeBtn then
        -- Never taller than the band it sits in, so it cannot straddle the
        -- header the way the template's native 32px did.
        local size = math.max(12, math.min(CLOSE_BTN, titleH - 6))
        closeBtn:SetSize(size, size)
    end
end

--- Shrink any cloned "plaque" piece (see IsBand) back down to fit this
--- window, once this window's own width is actually known.
---
--- A band scales for free: it is anchored to `bar`'s own TOPLEFT/TOPRIGHT,
--- so whatever width `bar` ends up at, the band matches it. A plaque is not
--- anchored that way — CloneTitleStrip gives it a literal SetSize(p.width,
--- p.height), copied from WorldMapFrame, a frame this window is deliberately
--- a fraction the size of (MAP_FRACTION_W/H, clamped by MIN_CONTENT/
--- MAX_CONTENT) — and that size is never revisited. A plaque modest enough
--- to sit quietly on the full map can easily be wider than this window's
--- entire header, and CloneTitleStrip runs once, during EnsureWindow,
--- *before* LayoutWindow has set this window's real size at all (see the
--- comment on StyleBox about the window having no size yet at that point) —
--- so there was never a moment where the plaque's width could have been
--- checked against anything meaningful. Left alone, that piece renders at
--- full native width and sticks out past both edges of the header: the
--- unexplained long bar an /fstack click on the title bar landed on.
---
--- This does not re-decide what counts as a band vs. a plaque (see the
--- three-tries comment above IsBand — that heuristic is proven, fragile
--- ground). It only ever shrinks a plaque that no longer fits, and leaves
--- one that already fits untouched.
local function ClampTitleStripPlaques(bar, maxWidth)
    if not (bar and bar.hfwmStrip and maxWidth and maxWidth > 0) then return end
    for _, tex in ipairs(bar.hfwmStrip) do
        local native = tex.hfwmPlaqueNativeWidth
        if native and native > maxWidth then
            tex:SetWidth(maxWidth)
        end
    end
end

--- Builds `frame`'s entire box border out of the same eight live
--- WorldMapFrame.BorderFrame.NineSlice pieces the real map frames itself
--- with — the four corners placed at their real corners,
--- the four edges stretched to span between them — instead of the tinted
--- DIALOG_BACKDROP guess. CopyRegionArt keeps each piece's own native
--- vertex colour (no BORDER_GOLD tint applied here at all), so this is
--- built from the identical asset family as the title bar and the two
--- meet at exactly the same trim, seamlessly, rather than two different
--- border styles butted up against each other. All-or-nothing: if any of
--- the eight pieces isn't live/real, this bails out so StyleBox can fall
--- back to the legacy backdrop instead of drawing half a border.
local function ApplyNineSliceBorder(frame, r, g, b, a)
    local wmf = WorldMapFrame
    local nineSlice = wmf and wmf.BorderFrame and wmf.BorderFrame.NineSlice
    if not nineSlice then return false end

    for _, key in ipairs(NINE_SLICE_PIECES) do
        if not IsTexture(nineSlice[key]) then return false end
    end

    local ok = pcall(function()
        -- The eight pieces go on their own child frame, held well above
        -- every other child (title bar, content, slider), rather than on
        -- `frame` itself. A border is the one thing in a panel that should
        -- always win at the edges: with the art on `frame`, the content
        -- frame — a sibling at the same frame level, created later — drew
        -- over it, which is what made the cave art read as overlapping its
        -- own frame instead of sitting inside it. Now the trim is painted
        -- last, so the interior can butt right up against it and the worst
        -- case is the border clipping a pixel of art rather than the art
        -- swallowing the border.
        local art = CreateFrame("Frame", nil, frame)
        art:SetAllPoints(frame)
        art:SetFrameLevel(frame:GetFrameLevel() + BORDER_LEVEL)
        -- Purely decorative: must never eat a click meant for the window
        -- underneath it (dragging the window, the close button, the slider).
        art:EnableMouse(false)
        frame.hfwmBorderArt = art

        -- BORDER_ART, not src:GetWidth()/GetHeight(). The source pieces are
        -- authored for WorldMapFrame's own size; copying them at native size
        -- is what made this window's trim absurdly thick and pushed the
        -- interior around (see the BORDER_ART comment up top).
        local function corner(key, point)
            local src = nineSlice[key]
            local copy = art:CreateTexture(nil, "OVERLAY")
            if not CopyRegionArt(src, copy) then error("no " .. key .. " art") end
            local topSkew = (point == "TOPLEFT" or point == "TOPRIGHT") and TITLE_H or BORDER_ART
            copy:SetSize(BORDER_ART, topSkew)
            copy:SetPoint(point, art, point, 0, 0)
            return copy
        end

        local tl = corner("TopLeftCorner", "TOPLEFT")
        local tr = corner("TopRightCorner", "TOPRIGHT")
        local bl = corner("BottomLeftCorner", "BOTTOMLEFT")
        local br = corner("BottomRightCorner", "BOTTOMRIGHT")

        local function edge(key, fromA, aPoint, fromB, bPoint)
            local src = nineSlice[key]
            local mid = art:CreateTexture(nil, "OVERLAY")
            if not CopyRegionArt(src, mid) then error("no " .. key .. " art") end
            mid:SetPoint("TOPLEFT", fromA, aPoint, 0, 0)
            mid:SetPoint("BOTTOMRIGHT", fromB, bPoint, 0, 0)
            return mid
        end

        edge("TopEdge", tl, "TOPRIGHT", tr, "BOTTOMLEFT")
        edge("BottomEdge", bl, "TOPRIGHT", br, "BOTTOMLEFT")
        edge("LeftEdge", tl, "BOTTOMLEFT", bl, "TOPRIGHT")
        edge("RightEdge", tr, "BOTTOMLEFT", br, "TOPRIGHT")

        -- Plain fill behind all of it, in this call's colour (StyleBox's
        -- r/g/b/a) rather than any fixed shade, since the border art itself
        -- now carries no tint.
        --
        -- SetAllPoints, *not* inset to the corners' inner edges the way this
        -- used to be. Anchoring it tl:BOTTOMRIGHT -> br:TOPLEFT made the fill
        -- a rectangle held one whole corner's width in from every side, and
        -- with the corners at their native (map-frame-sized) dimensions that
        -- rectangle was inset far enough to be plainly visible as its own
        -- shape — a dark panel, narrower than the window and offset from the
        -- content below it, showing through the gap between the header and
        -- the top of the cave art. That is the "second overlapping top
        -- section". It was never a second frame; it was this one texture
        -- mis-anchored. A background has no business being inset at all: it
        -- covers the frame, and the border art draws on top of its margin.
        local fill = frame:CreateTexture(nil, "BACKGROUND")
        fill:SetColorTexture(r or 0.05, g or 0.05, b or 0.05, a or 0.9)
        fill:SetAllPoints(frame)
    end)
    return ok
end

--- Give `frame` the game's own border, preferring the live NineSlice-copy
--- technique above (real border, real colour, guaranteed to match the
--- title bar) and only falling back to the legacy tinted DIALOG_BACKDROP
--- table — or, lacking BackdropTemplate entirely, the hand-drawn
--- StyleBoxFallback — when this client build doesn't actually expose
--- WorldMapFrame.BorderFrame.NineSlice.
---
--- Both the ornate paths (NineSlice corners and DIALOG_BACKDROP's edgeSize)
--- are art sized for a whole window — BORDER_ART (32px) per corner at
--- minimum. On a frame smaller than roughly twice that in either
--- dimension, opposite corners cross over each other and there is nothing
--- left for a straight edge to span (this is exactly what the reopen
--- icon's border hit before this guard existed). Below that floor, this
--- skips straight to StyleBoxFallback's hairline, which has no minimum
--- size and is still the same BORDER_GOLD used everywhere else here — so a
--- small widget gets a thinner but genuinely matching border instead of a
--- clipped, overlapping one.
---
--- The window itself is sized after StyleBox runs (see EnsureWindow), so it
--- has no width/height yet here; treat "no size yet" as "plenty of room",
--- which preserves this function's original behaviour for that caller
--- exactly.
local function StyleBox(frame, r, g, b, a)
    local w, h = frame:GetWidth(), frame:GetHeight()
    local sizeKnown = w and w > 0 and h and h > 0
    local roomForOrnateBorder = (not sizeKnown)
        or (w >= BORDER_ART * 2 and h >= BORDER_ART * 2)

    if roomForOrnateBorder then
        if ApplyNineSliceBorder(frame, r, g, b, a) then
            return frame
        end

        if not frame.SetBackdrop and BackdropTemplateMixin then
            Mixin(frame, BackdropTemplateMixin)
        end
        if frame.SetBackdrop then
            local backdrop, borderColor = DIALOG_BACKDROP, BORDER_GOLD
            if WorldMapFrame and WorldMapFrame.GetBackdrop then
                local ok, live = pcall(WorldMapFrame.GetBackdrop, WorldMapFrame)
                if ok and live then
                    backdrop = live
                    local okColor, br, bgc, bb, ba =
                        pcall(WorldMapFrame.GetBackdropBorderColor, WorldMapFrame)
                    borderColor = (okColor and br) and { br, bgc, bb, ba } or { 1, 1, 1, 1 }
                end
            end
            frame:SetBackdrop(backdrop)
            frame:SetBackdropColor(r or 0.05, g or 0.05, b or 0.05, a or 0.9)
            frame:SetBackdropBorderColor(unpack(borderColor))
            return frame
        end
    end
    return StyleBoxFallback(frame, r, g, b, a)
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

--- Like ValueToIndex, but without the rounding: "floor 2.3" for a value
--- three-tenths of the way from floor 2 towards floor 3. This is what the
--- continuous crossfade drags along; ValueToIndex's rounding is exactly the
--- snap-to-nearest-floor behaviour a hard-swap cave wants instead.
local function ValueToFractionalIndex(value)
    return FloorCount() - value + 1
end

--- The native Slider widget always renders its minimum at the TOP of a
--- VERTICAL track and its maximum at the BOTTOM (confirmed via
--- https://warcraft.wiki.gg/wiki/API_Slider_SetOrientation: "Slider thumb
--- moves from top to bottom as the slider's value increases") — the
--- opposite of the "value" scale the rest of this section uses, which puts
--- the minimum at the bottom of the track (deepest) and the maximum at the
--- top (topmost), to match ElevationForValue, ValueToFractionalIndex,
--- IndexToValue and ValueToIndex above. This converts between the two; it's
--- its own inverse (same mirror-around-the-range shape as IndexToValue), so
--- it is used both to translate the raw value OnValueChanged receives, and
--- to translate the value SyncSlider hands to SetValue.
local function MirrorSliderValue(v)
    return FloorCount() - v + 1
end

--- Triangular falloff around a fractional floor position: 1 at that floor's
--- own index, fading linearly to 0 by the time the slider reaches either
--- neighbour, and 0 beyond that. At most two floors are ever partially
--- visible at once — the same as a real crossfade dissolve.
local function ContinuousAlpha(index, fractionalIndex)
    return math.max(0, 1 - math.abs(index - fractionalIndex))
end

--- cave-satellite-v2 Phase 2: real-world elevation the slider's raw value
--- corresponds to, spanning the aggregate zMin/zMax of every piece currently
--- rendered (piecesZMin/piecesZMax — set by RenderContinuousPieces, not any
--- one floor's own range) so that dragging between the two floor notches
--- sweeps continuously through every piece's real height in between, which
--- is the whole point of the per-piece rework (see the module-state comment
--- above continuousPieceGroups). Runs the same direction as the floor index:
--- 1 (the bottom of the track, the deepest floor) is the lowest elevation,
--- FloorCount() (the top, the topmost floor) is the highest.
local function ElevationForValue(value)
    if not piecesZMin or not piecesZMax then return 0 end
    local n = FloorCount()
    if n <= 1 then return piecesZMax end
    local frac = (value - 1) / (n - 1)
    return piecesZMin + frac * (piecesZMax - piecesZMin)
end

--- The height-window rectangle's own real-world elevation bounds: its two
--- 0..1 fractions (Config:CaveHeightWindow) scaled against the aggregate
--- zMin/zMax of every piece currently rendered (piecesZMin/piecesZMax — set
--- by RenderContinuousPieces), the same span ElevationForValue scales
--- against. Returns nil, nil before any piece has been rendered.
---@return number|nil windowBottomZ, number|nil windowTopZ
local function HeightWindowElevationBounds()
    if not piecesZMin or not piecesZMax then return nil, nil end
    local top, bottom = Config:CaveHeightWindow()
    local span = piecesZMax - piecesZMin
    return piecesZMin + bottom * span, piecesZMin + top * span
end

--- Overlap-based alpha for a piece against the height-window rectangle's
--- real elevation bounds: 1 if any part of the piece's own [zMin, zMax]
--- falls inside [windowBottomZ, windowTopZ], fading linearly to 0 over
--- EDGE_FADE_YARDS beyond whichever edge is nearer, and 0 past that. Unlike
--- a single-point falloff, any number of pieces can be simultaneously fully
--- visible, partially faded, or invisible at once — there is no fixed
--- neighbour count once "floors" stop being the unit the fade is keyed on.
local function PieceWindowAlpha(zMin, zMax, windowBottomZ, windowTopZ)
    if not windowBottomZ then return 1 end
    if zMax >= windowBottomZ and zMin <= windowTopZ then return 1 end
    local d = (zMin > windowTopZ) and (zMin - windowTopZ)
        or (windowBottomZ - zMax)
    return math.max(0, 1 - d / EDGE_FADE_YARDS)
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

    -- Track groove: this track is only SLIDER_W (14px) wide, far too
    -- narrow for DIALOG_BACKDROP's 32px ornate corners to tile correctly
    -- (StyleBox's dialog border is sized for whole windows, not a thin
    -- groove). Instead this uses the exact resource the real game uses for
    -- every slider groove — Interface\Buttons\UI-SliderBar-Background and
    -- UI-SliderBar-Border, the same pair FrameXML's OptionsSliderTemplate
    -- draws under its thumb for the volume/camera-distance sliders and
    -- every other vertical slider in the default UI. Plain textures, not a
    -- backdrop, matching how the template itself builds it; created at
    -- BACKGROUND/BORDER draw layers so the thumb texture (set below) still
    -- draws above them without any extra layering work.
    local grooveBg = sliderTrack:CreateTexture(nil, "BACKGROUND")
    grooveBg:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
    grooveBg:SetPoint("TOPLEFT", sliderTrack, "TOPLEFT", 3, -3)
    grooveBg:SetPoint("BOTTOMRIGHT", sliderTrack, "BOTTOMRIGHT", -3, 3)

    local grooveBorder = sliderTrack:CreateTexture(nil, "BORDER")
    grooveBorder:SetTexture("Interface\\Buttons\\UI-SliderBar-Border")
    grooveBorder:SetAllPoints(sliderTrack)

    sliderTrack:SetScript("OnValueChanged", function(self, rawValue)
        if self._syncing then return end
        -- rawValue is the native widget's own value (min at the top of the
        -- track, max at the bottom); mirror it onto this file's value scale
        -- (min at the bottom, max at the top) before any of the math below,
        -- which all assumes the latter. See MirrorSliderValue.
        local value = MirrorSliderValue(rawValue)
        if piecesActive then
            -- The height-window rectangle (EnsureHeightWindow) replaces the
            -- plain thumb-drag entirely for a per-piece place; the track's
            -- own mouse and wheel are disabled to match (see
            -- SyncHeightWindow), so this never actually fires from user
            -- input, but stays a safe no-op rather than falling through to
            -- the floor-select branch below with a value that has no floor
            -- meaning here.
            return
        end
        if continuousActive then
            -- A shared-canvas cave: drag freely between floors, fading
            -- their art and the pin as the value moves, without tearing
            -- down and rebuilding the window on every pixel of drag.
            CaveRenderer:UpdateContinuousAlphas(ValueToFractionalIndex(value))
            return
        end
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
            -- Gold for the current floor, plain light gray otherwise — the
            -- same selected-vs-normal convention Blizzard's own list UIs
            -- (spellbook, quest log, dropdown menus) use throughout.
            GameTooltip:AddLine(
                ("%s %s"):format(on and "»" or " ", f.name or ("Level " .. i)),
                on and 1 or 0.8, on and 0.82 or 0.8, on and 0 or 0.8)
        end
        if continuousActive then
            GameTooltip:AddLine("Drag to fade between levels, scroll to jump",
                0.5, 0.5, 0.5)
        else
            GameTooltip:AddLine("Drag, click or scroll to change level",
                0.5, 0.5, 0.5)
        end
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

    local inset  = SLIDER_INSET
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
        -- Gold for the active floor, dim tan/bronze for the rest — matches
        -- the same gold-for-selected convention as the depth tooltip above.
        notch:SetColorTexture(
            active and 1.00 or 0.55,
            active and 0.82 or 0.45,
            active and 0.00 or 0.28,
            active and 1.00 or 0.85)
        notch:Show()
    end

    for i = n + 1, #notches do
        notches[i]:Hide()
    end
end

--- Pull the slider's displayed position back from the active floor.
---@param continuous boolean  true for a shared-canvas place: free-drag
--- between floors rather than snapping to each one in turn.
local function SyncSlider(floors, currentMapID, continuous)
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
    -- Mirror the same way OnValueChanged does, so the thumb lands where the
    -- hand-drawn notches (LayoutNotches, below) already place the active
    -- floor: index 1 (topmost) at the top of the track, index n (deepest)
    -- at the bottom.
    sliderTrack:SetValue(MirrorSliderValue(IndexToValue(idx)))
    -- Discrete caves snap to whole floors; a shared-canvas cave drags
    -- smoothly between them so the opacity crossfade has something
    -- fractional to work with.
    sliderTrack:SetValueStep(continuous and 0.01 or 1)
    if sliderTrack.SetObeyStepOnDrag then
        sliderTrack:SetObeyStepOnDrag(not continuous)
    end
    sliderTrack._syncing = false

    LayoutNotches(floors, currentMapID)
    sliderCol:Show()
end

-------------------------------------------------------------------------------
-- Height-window widget (cave-satellite-v2 Phase 2)
--
-- A rectangle dragged directly on the depth slider, replacing a single
-- slider point with a range: dragging the body moves the whole window up
-- or down the track (which elevation range is shown); dragging either edge
-- resizes it (how wide a range is shown). At the loosest setting (the
-- rectangle spanning the whole track) every piece is visible at once; at
-- the tightest (Config.HEIGHT_WINDOW_MIN_SPAN) only a narrow band around
-- wherever the user left it is.
--
-- Built as one Button (`windowBody`, the whole rectangle, for the move
-- drag) with two child Buttons (`windowTopHandle`/`windowBottomHandle`,
-- thin grab strips overlapping its top and bottom edges, for the resize
-- drags) — the handles sit at a higher frame level than the body so a
-- click on the edge strip reaches the handle first, and a click anywhere
-- else in the rectangle falls through to the body.
--
-- Dragging is hand-polled (OnMouseDown to start, OnUpdate + a live
-- IsMouseButtonDown check to follow, release detected the same way rather
-- than from an OnMouseUp) instead of the frame's own StartSizing/
-- StartMoving: this is a custom two-edge range, not a single movable/
-- resizable frame, and polling behaves the same across client flavours.
-------------------------------------------------------------------------------

--- Cursor's current position along the track, as the same 0..1 fraction
--- LayoutNotches/HeightWindowElevationBounds use (0 at the bottom of the
--- track's usable range, 1 at the top), clamped to stay on the track even
--- if the cursor has strayed outside it.
local function CursorTrackFrac()
    if not sliderTrack then return 0 end
    local trackH = contentH
    if trackH <= 0 then return 0 end
    local usable = trackH - SLIDER_INSET * 2
    if usable <= 0 then return 0 end

    local scale = sliderTrack:GetEffectiveScale()
    local _, cursorY = GetCursorPosition()
    cursorY = cursorY / scale

    local bottom = sliderTrack:GetBottom() or 0
    local frac = (cursorY - bottom - SLIDER_INSET) / usable
    return math.max(0, math.min(1, frac))
end

--- Place the rectangle from Config's current window fractions.
local function LayoutHeightWindow()
    if not windowBody then return end
    local trackH = contentH
    local usable = trackH - SLIDER_INSET * 2
    if usable <= 0 then
        windowBody:Hide()
        return
    end

    local top, bottom = Config:CaveHeightWindow()
    local topOffset    = SLIDER_INSET + usable * top
    local bottomOffset = SLIDER_INSET + usable * bottom

    windowBody:ClearAllPoints()
    windowBody:SetPoint("BOTTOM", sliderTrack, "BOTTOM", 0, bottomOffset)
    windowBody:SetHeight(math.max(1, topOffset - bottomOffset))
    windowBody:Show()
end

--- Recompute and redraw every piece's alpha from the window's current
--- elevation bounds. The whole of what dragging the rectangle does; it
--- never tears down or re-renders the pieces themselves.
function CaveRenderer:UpdatePieceWindowAlphas()
    local windowBottomZ, windowTopZ = HeightWindowElevationBounds()
    for _, grp in ipairs(continuousPieceGroups) do
        local alpha = PieceWindowAlpha(grp.zMin, grp.zMax, windowBottomZ, windowTopZ)
        grp.alpha = alpha
        grp.texture:SetAlpha(alpha)
    end
end

--- Start tracking a drag of one of the three controls.
---@param kind "top"|"bottom"|"body"
local function BeginHeightWindowDrag(kind)
    local top, bottom = Config:CaveHeightWindow()
    heightWindowDrag = {
        kind        = kind,
        startFrac   = CursorTrackFrac(),
        startTop    = top,
        startBottom = bottom,
    }
end

--- Polled every frame windowBody is shown; a no-op unless a drag is live,
--- and self-stops the instant the mouse button is no longer down (rather
--- than relying on an OnMouseUp, which a fast drag can carry the cursor
--- right off of the handle before firing).
local function HeightWindowDragUpdate()
    if not heightWindowDrag then return end
    if not IsMouseButtonDown("LeftButton") then
        heightWindowDrag = nil
        return
    end

    local frac = CursorTrackFrac()
    if heightWindowDrag.kind == "top" then
        Config:SetCaveHeightWindow(frac, heightWindowDrag.startBottom)
    elseif heightWindowDrag.kind == "bottom" then
        Config:SetCaveHeightWindow(heightWindowDrag.startTop, frac)
    else -- "body": both edges move together, preserving the span
        local span  = heightWindowDrag.startTop - heightWindowDrag.startBottom
        local delta = frac - heightWindowDrag.startFrac
        local top, bottom = heightWindowDrag.startTop + delta,
            heightWindowDrag.startBottom + delta
        if top > 1 then top, bottom = 1, 1 - span end
        if bottom < 0 then top, bottom = span, 0 end
        Config:SetCaveHeightWindow(top, bottom)
    end

    LayoutHeightWindow()
    CaveRenderer:UpdatePieceWindowAlphas()
end

--- Build the rectangle and its two resize handles, lazily on first use —
--- same pattern as EnsureSlider, which this calls first since the widget
--- is anchored to the slider track it overlays.
local function EnsureHeightWindow()
    if windowBody then return end
    EnsureSlider()

    -- A little wider than the groove so the rectangle reads as its own
    -- control rather than a fatter version of the track, and gives the
    -- drag targets more room than the bare SLIDER_W would.
    local widgetW = SLIDER_W + 10

    windowBody = CreateFrame("Button", nil, sliderCol)
    windowBody:SetWidth(widgetW)
    windowBody:SetPoint("TOP", sliderTrack, "TOP", 0, 0)
    windowBody:EnableMouse(true)
    windowBody:SetScript("OnMouseDown", function()
        BeginHeightWindowDrag("body")
    end)
    windowBody:SetScript("OnUpdate", HeightWindowDragUpdate)
    windowBody:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Height window", 1, 1, 1)
        GameTooltip:AddLine("Drag to move the visible range up or down",
            0.5, 0.5, 0.5)
        GameTooltip:AddLine("Drag an edge to widen or narrow it",
            0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    windowBody:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local fill = windowBody:CreateTexture(nil, "ARTWORK", nil, 1)
    fill:SetAllPoints(windowBody)
    fill:SetColorTexture(1.00, 0.82, 0.00, 0.22)

    local edgeTop = windowBody:CreateTexture(nil, "ARTWORK", nil, 2)
    edgeTop:SetColorTexture(1.00, 0.85, 0.35, 0.9)
    edgeTop:SetHeight(2)
    edgeTop:SetPoint("TOPLEFT", windowBody, "TOPLEFT", 0, 0)
    edgeTop:SetPoint("TOPRIGHT", windowBody, "TOPRIGHT", 0, 0)

    local edgeBottom = windowBody:CreateTexture(nil, "ARTWORK", nil, 2)
    edgeBottom:SetColorTexture(1.00, 0.85, 0.35, 0.9)
    edgeBottom:SetHeight(2)
    edgeBottom:SetPoint("BOTTOMLEFT", windowBody, "BOTTOMLEFT", 0, 0)
    edgeBottom:SetPoint("BOTTOMRIGHT", windowBody, "BOTTOMRIGHT", 0, 0)

    -- Handles overlap a little past the body's own edge (rather than
    -- sitting flush inside it) so there is always a grabbable strip even
    -- when the window has been resized down near its minimum span.
    windowTopHandle = CreateFrame("Button", nil, windowBody)
    windowTopHandle:SetHeight(HEIGHT_WINDOW_HANDLE_H)
    windowTopHandle:SetPoint("TOPLEFT", windowBody, "TOPLEFT",
        0, HEIGHT_WINDOW_HANDLE_H / 2)
    windowTopHandle:SetPoint("TOPRIGHT", windowBody, "TOPRIGHT",
        0, HEIGHT_WINDOW_HANDLE_H / 2)
    windowTopHandle:SetFrameLevel(windowBody:GetFrameLevel() + 2)
    windowTopHandle:EnableMouse(true)
    windowTopHandle:SetScript("OnMouseDown", function()
        BeginHeightWindowDrag("top")
    end)
    windowTopHandle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Drag to widen or narrow the top of the "
            .. "visible range", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    windowTopHandle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    windowBottomHandle = CreateFrame("Button", nil, windowBody)
    windowBottomHandle:SetHeight(HEIGHT_WINDOW_HANDLE_H)
    windowBottomHandle:SetPoint("BOTTOMLEFT", windowBody, "BOTTOMLEFT",
        0, -HEIGHT_WINDOW_HANDLE_H / 2)
    windowBottomHandle:SetPoint("BOTTOMRIGHT", windowBody, "BOTTOMRIGHT",
        0, -HEIGHT_WINDOW_HANDLE_H / 2)
    windowBottomHandle:SetFrameLevel(windowBody:GetFrameLevel() + 2)
    windowBottomHandle:EnableMouse(true)
    windowBottomHandle:SetScript("OnMouseDown", function()
        BeginHeightWindowDrag("bottom")
    end)
    windowBottomHandle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Drag to widen or narrow the bottom of the "
            .. "visible range", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    windowBottomHandle:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Show/position the rectangle for a per-piece place, or hide it (and give
--- the plain thumb back its usual mouse/wheel interaction) for anything
--- else. Called from ShowCave right after SyncSlider.
---@param active boolean  CaveRenderer:IsPiecesActive()'s value for the
--- place just shown.
local function SyncHeightWindow(active)
    if not active then
        heightWindowDrag = nil
        if windowBody then windowBody:Hide() end
        if sliderTrack then
            local thumb = sliderTrack:GetThumbTexture()
            if thumb then thumb:SetShown(true) end
            sliderTrack:EnableMouse(true)
            sliderTrack:EnableMouseWheel(true)
        end
        return
    end

    EnsureHeightWindow()
    -- The rectangle fully replaces the thumb's role while active: showing
    -- both would be two controls claiming to do the same job.
    local thumb = sliderTrack:GetThumbTexture()
    if thumb then thumb:SetShown(false) end
    sliderTrack:EnableMouse(false)
    sliderTrack:EnableMouseWheel(false)
    LayoutHeightWindow()
    windowBody:Show()
end

-------------------------------------------------------------------------------
-- Floor picker (dropdown)
--
-- Top-right of the content frame — floating over the art itself rather than
-- in the title bar (already carrying the area name and the close button) or
-- the footer (already carrying the "Level X of Y" readout).
--
-- Built from the client's own UIDropDownMenuTemplate — the same "long-lived"
-- dropdown Options.lua's TryLegacyDropdown reaches for, and reliably present
-- on every flavour from vanilla through Dragonflight per that file's own
-- comment — rather than a hand-built button and popup list. Reading and
-- behaving exactly like every other dropdown in the default UI is the point:
-- the native checkmark marks the active entry, the native highlight and
-- click sound come for free, and there is no bespoke popup-list/click-away
-- plumbing here to keep in sync with the real thing.
--
-- InitFloorPickerMenu reads Config.caveAllFloors / Config.caveFloorFilterAll
-- / Config.caveCurrentFloorMapID live, each time the menu opens —
-- UIDropDownMenu_Initialize already means "call this again whenever the
-- list needs to be current," so unlike the depth slider's hand-drawn
-- notches there is nothing here that needs rebuilding ahead of time by a
-- Sync function; SyncFloorPicker below only has the closed-state text left
-- to do.
-------------------------------------------------------------------------------

--- The menu list: "All" first, in Blizzard's own cyan (see
--- BLIZZARD_CYAN_HEX), then every floor, topmost first, in plain default
--- text — the native checkmark (info.checked) is what marks whichever one
--- is active, the same as every other Blizzard dropdown, so neither entry
--- needs its own hand-picked highlight colour on top of that. Selecting
--- either hands straight off to CaveRenderer:SelectAllFloors/
--- SelectFloorFilter, which is also what the depth slider and the
--- mouse-wheel step already call, so none of the three can ever disagree
--- about which floor is current.
local function InitFloorPickerMenu(_, level)
    local floors = Config.caveAllFloors
    if not floors then return end

    local allInfo = UIDropDownMenu_CreateInfo()
    allInfo.text            = BLIZZARD_CYAN_HEX .. "All|r"
    allInfo.checked         = Config.caveFloorFilterAll and true or false
    allInfo.tooltipTitle    = "All"
    allInfo.tooltipText     = "Layer every floor together, exactly as "
        .. "before this control existed."
    allInfo.tooltipOnButton = true
    allInfo.func = function() CaveRenderer:SelectAllFloors() end
    UIDropDownMenu_AddButton(allInfo, level)

    for i, floor in ipairs(floors) do
        local name = floor.name or ("Level " .. i)
        local info = UIDropDownMenu_CreateInfo()
        info.text            = name
        info.checked         = (not Config.caveFloorFilterAll)
            and floor.mapID == Config.caveCurrentFloorMapID
        info.tooltipTitle    = name
        info.tooltipText     = "Show only this floor, and scope the depth "
            .. "slider to its own range."
        info.tooltipOnButton = true
        info.func = function() CaveRenderer:SelectFloorFilter(floor.mapID) end
        UIDropDownMenu_AddButton(info, level)
    end
end

--- Build the dropdown, lazily on first use — same pattern as EnsureSlider/
--- EnsureHeightWindow. `floorPickerUnavailable` is set once and for all if
--- this client turns out not to expose the UIDropDownMenuTemplate API —
--- vanishingly unlikely (see the section comment above) but checked anyway,
--- matching every other template lookup in this addon. There is
--- deliberately no hand-built fallback this time: going without a floor
--- picker is a smaller gap than shipping a second, differently-styled
--- widget for the same job on the rare client that lacks it.
local function EnsureFloorPicker()
    if floorPicker or floorPickerUnavailable then return end

    if not (UIDropDownMenu_Initialize and UIDropDownMenu_CreateInfo
            and UIDropDownMenu_AddButton and UIDropDownMenu_SetText) then
        floorPickerUnavailable = true
        return
    end

    local ok, dd = pcall(CreateFrame, "Frame", "HFWMForeverCaveFloorDropdown",
        window, "UIDropDownMenuTemplate")
    if not ok or not dd then
        floorPickerUnavailable = true
        return
    end

    local built = pcall(UIDropDownMenu_Initialize, dd, InitFloorPickerMenu)
    if not built then
        dd:Hide()
        floorPickerUnavailable = true
        return
    end

    if UIDropDownMenu_SetWidth then
        -- -40: the template's own frame is wider than its visible
        -- text/button area on both ends (see Options.lua's identical -40
        -- on its own background dropdown's DROPDOWN_WIDTH), so this keeps
        -- the *visible* widget close to FLOOR_PICKER_W rather than that
        -- much wider again.
        pcall(UIDropDownMenu_SetWidth, dd, FLOOR_PICKER_W - 40)
    end

    dd:ClearAllPoints()
    -- +14, not flush: the template's own end-cap art sits inset from the
    -- frame's true edges, so anchoring flush would leave the *visible*
    -- widget floating short of content's own right edge. This is a
    -- by-eye nudge, not a measured one — worth another look in-game.
    dd:SetPoint("TOPRIGHT", content, "TOPRIGHT", 14, -2)
    -- Above content's own tiles: both are plain children of `window` and
    -- would otherwise share its default child level, which draw-order
    -- ties in creation order rather than anything this file controls.
    dd:SetFrameLevel(content:GetFrameLevel() + 5)

    floorPicker = dd
end

--- Pull the closed dropdown's own text back from the current filter/floor,
--- and hide the whole control for a single-floor place — same gate the
--- depth slider itself uses (FloorCount() <= 1): a picker with only "All"
--- and one floor to choose between has nothing to offer that showing the
--- floor already didn't.
---@param floors table[]|nil  Config.caveAllFloors
---@param currentMapID number|nil
local function SyncFloorPicker(floors, currentMapID)
    local n = floors and #floors or 0
    if n <= 1 then
        if floorPicker then
            floorPicker:Hide()
            if CloseDropDownMenus then pcall(CloseDropDownMenus) end
        end
        return
    end

    EnsureFloorPicker()
    if not floorPicker then return end

    if Config.caveFloorFilterAll then
        UIDropDownMenu_SetText(floorPicker, BLIZZARD_CYAN_HEX .. "All|r")
    else
        local cur
        for _, f in ipairs(floors) do
            if f.mapID == currentMapID then cur = f break end
        end
        UIDropDownMenu_SetText(floorPicker, cur and cur.name or "Floor")
    end

    floorPicker:Show()
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

-------------------------------------------------------------------------------
-- Reopen icon
--
-- The window's own close button (see EnsureWindow) hides the cave map for
-- the rest of the visit; without this, there is then no way back into it
-- short of the /hfwm slash command. This is a small icon button that sits
-- in the bottom-right of the map, above the side-panel toggle's open
-- button, and reappears whenever Cave.lua has a cave available but closed.
-------------------------------------------------------------------------------
local REOPEN_BTN_SIZE = 28
-- How far the icon art sits inside the button's edge, so StyleBox's border
-- (drawn on the button itself, behind the icon) actually shows instead of
-- being covered edge-to-edge by the icon texture.
local REOPEN_ICON_INSET = 4

local function EnsureReopenButton()
    if reopenBtn then return end

    local btn = CreateFrame("Button", "HFWMForeverCaveReopenButton", WorldMapFrame)
    btn:SetSize(REOPEN_BTN_SIZE, REOPEN_BTN_SIZE)
    btn:EnableMouse(true)

    -- Anchored the same way the cave window itself is layered: the map's own
    -- strata, well above its children, so it isn't a click behind the map's
    -- own furniture.
    btn:SetFrameStrata(WorldMapFrame:GetFrameStrata())
    btn:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 800)

    -- Bottom of this icon sits on top of the side panel toggle's open
    -- button, so the two never overlap. If a client build doesn't have that
    -- button (name changed, or the side panel doesn't exist here), fall
    -- back to a fixed corner inset rather than leave the icon unanchored.
    local sidePanelToggle = WorldMapFrame.SidePanelToggle
    local openButton = sidePanelToggle and sidePanelToggle.OpenButton
    if openButton then
        btn:SetPoint("BOTTOMRIGHT", openButton, "TOPRIGHT", 0, 4)
    else
        btn:SetPoint("BOTTOMRIGHT", WorldMapFrame, "BOTTOMRIGHT", -8, 40)
    end

    -- Same trim the cave window itself gets (StyleBox), sized down: at this
    -- button's fixed 28x28, StyleBox's own size guard steers it to the
    -- hairline variant rather than the full corner art, so it comes out as
    -- a clean thin gold edge instead of overlapping corner pieces. Same
    -- colour and same function as the window, just the size-appropriate
    -- path through it.
    StyleBox(btn, 0.06, 0.05, 0.03, 0.95)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", REOPEN_ICON_INSET, -REOPEN_ICON_INSET)
    icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -REOPEN_ICON_INSET, REOPEN_ICON_INSET)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Map02")
    -- Trim the icon's own baked-in border padding slightly so it reads as a
    -- button rather than a bare inventory icon.
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(btn)
    hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    hl:SetBlendMode("ADD")

    btn:SetScript("OnClick", function()
        ns.Cave:ForceShow()
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Open cave map")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:Hide()
    reopenBtn = btn
end

--- Show or hide the reopen icon. Cave.lua drives this: true when the player
--- is somewhere with a cave map but has closed it (or hasn't opened it yet
--- this visit); false whenever the cave window itself is showing, or there
--- is nothing to reopen.
---@param available boolean
function CaveRenderer:SetReopenAvailable(available)
    if available then
        EnsureReopenButton()
        reopenBtn:Show()
    elseif reopenBtn then
        reopenBtn:Hide()
    end
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
    StyleBox(window, 0.06, 0.05, 0.03, 0.95)

    -- Above the border art rather than above the window. ApplyNineSliceBorder
    -- paints the trim on its own child frame at +BORDER_LEVEL so the border
    -- always wins at the edges (that is what stopped the cave art overlapping
    -- its frame) — but the window's *text* has to beat the trim in turn, or
    -- it gets painted over by the very band it is meant to label. Both the
    -- title and the floor readout live on this one chrome frame above it: the
    -- readout sits inside the bottom border band exactly as the title sits
    -- inside the top one, so both need the same treatment.
    local chrome = CreateFrame("Frame", nil, window)
    chrome:SetAllPoints(window)
    chrome:SetFrameLevel(window:GetFrameLevel() + BORDER_LEVEL + 1)
    -- Text only; must not swallow a drag of the window or a slider click.
    chrome:EnableMouse(false)

    -- Flush to the window's own top-left and top-right corners, with no inset
    -- at all. That is what makes the cloned strip's measurements mean the same
    -- thing here as they do on the map: CollectTitleStrip records each piece's
    -- offset from the *frame's* top and edges, so the bar it is replayed onto
    -- has to start at this frame's top and edges too. Insetting the bar by
    -- BORDER_ART (to dodge the corner ornaments) or by BORDER_INSET would
    -- silently shift every cloned piece by that much.
    local bar = CreateFrame("Frame", nil, chrome)
    bar:SetFrameLevel(chrome:GetFrameLevel())
    bar:SetPoint("TOPLEFT", window, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", window, "TOPRIGHT", 0, 0)
    -- Hard backstop for CloneTitleStrip below: whatever a cloned piece's own
    -- insets/width work out to, nothing it draws is allowed to render
    -- outside this bar's own rect. IsBand's leftInset/rightInset math (and
    -- ClampTitleStripPlaques' width clamp) are both best-efforts at getting
    -- a cloned piece's *placement* right; this is the unconditional fallback
    -- for when one of them is wrong anyway — e.g. a piece whose measured
    -- inset comes out sharply negative still passes IsBand's `<= slack`
    -- check (a negative number is always <= a positive one), so it gets
    -- anchored hundreds of pixels to the left of bar's own edge instead of
    -- inside it. That is the long horizontal bar that showed up bleeding out
    -- across the world map to the left of the cave window in practice.
    -- Clipping here does not fix the mis-measurement, but it does guarantee
    -- the symptom — art escaping this window's own header — can't happen,
    -- the same way `content` below already clips the cave art itself.
    if bar.SetClipsChildren then bar:SetClipsChildren(true) end
    titleBar = bar

    -- The header's art and its height both come from the live map here. What
    -- the clone found is recorded because it is the one thing about this window
    -- that cannot be worked out by reading the code, and it is what /hfwm cave
    -- titledump prints in full when the header still looks wrong.
    titleText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetJustifyH("CENTER")
    titleText:SetWordWrap(false)
    ApplyTitleStrip(bar)

    local close = CreateFrameTry("Button", nil, window, "UIPanelCloseButton")
    close:SetFrameLevel(bar:GetFrameLevel() + 1)
    -- UIPanelCloseButton's template size is 32px square, which can be taller
    -- than the header band — left at its native size it would stick out above
    -- and below it. ApplyTitleHeight sizes it against the measured band; this
    -- is only the value it starts at.
    close:SetSize(CLOSE_BTN, CLOSE_BTN)
    -- In the corner, which is where a close button belongs and where this one
    -- was before being inset past BORDER_ART to keep it clear of the corner
    -- ornament. The inset is half BORDER_INSET: enough to tuck it inside the
    -- frame's outer trim while still reading as cornered.
    local closeInset = BORDER_INSET / 2
    close:SetPoint("TOPRIGHT", window, "TOPRIGHT", -closeInset, -closeInset)
    closeBtn = close
    if not close:GetNormalTexture() then
        -- No close-button template on this client: draw an x of our own
        -- rather than leave an invisible hit area.
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
        -- Bring the reopen icon in immediately rather than waiting up to
        -- POLL_INTERVAL for the poller to notice the suppression.
        ns.Cave:UpdateState()
    end)

    -- Content: clips its children, so a tile grid that does not divide evenly
    -- into the computed size cannot bleed over the window's border.
    --
    -- BORDER_INSET, not PAD. PAD (8) was smaller than the border art's own
    -- thickness, so the cave art's left/bottom perimeter ran *underneath* the
    -- trim and the map read as slightly overlapping its own frame. Inset to
    -- the same interior rect as the title bar, the art's edge lands flush
    -- against the border's inner edge instead. Directly under the bar with no
    -- PAD/2 gap, so there is no strip of bare fill between header and art for
    -- anything to show through.
    -- titleH alone, with no BORDER_INSET added: the title bar starts at the
    -- window's own top edge, not BORDER_INSET below it, so the bottom of the
    -- header band is titleH from the top and the art begins right there. It is
    -- the *measured* header height, not the TITLE_H fallback, so the art still
    -- meets the header exactly on a client whose title bar is a different
    -- height from the one this addon guessed at.
    content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", window, "TOPLEFT", BORDER_INSET, -titleH)
    if content.SetClipsChildren then content:SetClipsChildren(true) end

    backdropTex = content:CreateTexture(nil, "BACKGROUND")
    backdropTex:SetAllPoints(content)
    backdropTex:SetColorTexture(0.05, 0.04, 0.03, 1)

    playerPin = content:CreateTexture(nil, "OVERLAY", nil, 7)
    playerPin:SetTexture(PIN_TEXTURE)
    playerPin:SetSize(PIN_SIZE, PIN_SIZE)
    playerPin:Hide()

    -- On `chrome`, not `window`: see the chrome comment above — on window it
    -- sat below the border art frame and the bottom trim drew over it.
    floorText = chrome:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    -- Inside the bottom border, not on it: at PAD/4 the readout was hanging
    -- off the window's bottom edge, below the frame entirely.
    floorText:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT",
        BORDER_INSET + PAD, BORDER_INSET)
    floorText:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT",
        -(BORDER_INSET + PAD), BORDER_INSET)
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
    -- +2 for the gap sliderCol is anchored with below, so the gutter is wide
    -- enough to hold the whole column instead of letting it overhang the
    -- right border by that gap.
    local gutter    = hasSlider and (SLIDER_COL_W + 2) or 0

    -- Before anything is sized against titleH. EnsureWindow may have run
    -- while WorldMapFrame still had no rect to measure — during login, or
    -- before the map has ever been opened — in which case the header is
    -- unpainted and titleH is still the fallback. This is the retry, and it
    -- has to come first: it is what settles titleH, which the window's own
    -- height is computed from two statements below.
    if titleBar and not titleBar.hfwmSettled then
        if ApplyTitleStrip(titleBar) then ApplyTitleHeight() end
    end

    -- Derived from the same BORDER_INSET the title bar, content and footer
    -- are anchored with, so the window is exactly as big as its contents
    -- need. This used to mix PAD and PAD/2 terms that matched none of the
    -- anchors, which is what let the interior drift out past the border.
    contentW, contentH = w, h
    content:SetSize(w, h)
    -- Height: the header band (titleH, measured off the map's own title strip),
    -- the art, the footer readout, then the bottom border inset. Only *one*
    -- BORDER_INSET — the top one is subsumed by the header band, since the bar
    -- is flush to the frame's top edge rather than inset below it.
    window:SetSize(w + BORDER_INSET * 2 + gutter,
        h + titleH + FOOT_H + BORDER_INSET)
    -- Now that the window (and therefore titleBar, flush to its top edges)
    -- has a real width, shrink any cloned title-strip plaque that no longer
    -- fits it — see ClampTitleStripPlaques for why one can be wider than
    -- this window even after a "successful" clone.
    ClampTitleStripPlaques(titleBar, w + BORDER_INSET * 2 + gutter)

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
--- Always shown at the player's real position on whichever floor
--- ns.Cave:GetCurrentFloorMapID() resolves as current, regardless of which
--- floor the depth slider currently has on screen. It used to hide or fade
--- when the displayed floor didn't match the player's — the idea being that
--- a pin on a floor the player isn't on would be a lie — but for places like
--- Fargodeep Mine that floor-matching itself depends on real player
--- elevation, and UnitPosition's Z is a documented, permanent placeholder
--- that is always 0 on every version of the game (see PlayerWorldXY in
--- CaveTable.lua): there is no working signal to fade or hide by. Showing
--- the pin unconditionally is simpler and, for a cave where floor detection
--- can't be trusted, more honest than a hide/fade rule that was only ever
--- as good as data that doesn't exist.
local function UpdatePlayerPin()
    if not playerPin then return end

    local playerFloorMapID = ns.Cave:GetCurrentFloorMapID()
    if not playerFloorMapID then playerPin:Hide() return end

    local x, y = ns.Cave:GetPlayerMapXY(playerFloorMapID)
    if not x or not y or (x == 0 and y == 0) then
        -- (0,0) is the API's way of saying "no fix in this map's space".
        playerPin:Hide()
        return
    end

    local w, h = content:GetSize()
    if w <= 0 or h <= 0 then playerPin:Hide() return end

    playerPin:ClearAllPoints()
    playerPin:SetPoint("CENTER", content, "TOPLEFT", x * w, -(y * h))
    -- WoW facing and Texture:SetRotation both turn counter-clockwise for
    -- positive values, so facing is used as-is. Negating it, as this used
    -- to, was the bug an in-game check caught: north/south are their own
    -- negatives mod 2*pi, so facing 0 and pi rotate the same way under
    -- either sign and looked fine, while east/west landed mirrored — turn
    -- left and the arrow swung right, turn right and it swung left.
    --
    -- Nil while the camera is mid-transition (taxi, cinematic) — point the
    -- arrow north rather than erroring in an OnUpdate.
    local facing = GetPlayerFacing()
    playerPin:SetRotation(facing or 0)
    playerPin:SetAlpha(1)
    playerPin:Show()
end

local pinAccum = 0
local function OnWindowUpdate(_, elapsed)
    if not Config.caveOverlayActive then return end
    pinAccum = pinAccum + elapsed
    if pinAccum < PIN_UPDATE_INTERVAL then return end
    pinAccum = 0
    UpdatePlayerPin()
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
---@param floorMapID number
---@param sublevel number|nil  ARTWORK draw sublevel (-8..7); defaults to 3.
--- Only ever varied by RenderContinuousFloors, so that a shallower floor's
--- tiles paint over a deeper floor's while both are partially visible in a
--- crossfade — a single floor's tiles never need to stack against anything.
---@param group table|nil  when given, also collects each acquired texture
--- here so the caller can drive this floor's alpha independently
--- (the continuous crossfade path); omitted for the ordinary single-floor
--- render, which drives every tile via `activeCaveTiles` as a whole.
function CaveRenderer:RenderTiles(floorMapID, sublevel, group)
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

            local tex = PoolAcquire(group)
            tex:SetDrawLayer("ARTWORK", sublevel or 3)
            tex:SetSize(artTileW * scaleX, artTileH * scaleY)
            tex:SetPoint("TOPLEFT", content, "TOPLEFT",
                col * tilePxW * scaleX, -(row * tilePxH * scaleY))
            tex:SetTexCoord(0, artTileW / tilePxW, 0, artTileH / tilePxH)
            tex:SetTexture(src)
            tileIdx = tileIdx + 1
        end
    end

    if group then return #group > 0 end
    return #activeCaveTiles > 0
end

--- Render every floor of a shared-canvas place at once — as opposed to
--- RenderTiles's usual one-floor-at-a-time — so UpdateContinuousAlphas has
--- something to crossfade between as the depth slider moves. Only called
--- when ns.Cave:HasContinuousDepth(floorMapID) is true (currently just
--- Fargodeep Mine); every other multi-floor cave keeps the plain
--- RenderTiles hard-swap.
---@param floors table[]  Config.caveAllFloors, topmost first
---@return boolean anyDrew
function CaveRenderer:RenderContinuousFloors(floors)
    local n = #floors
    local anyDrew = false
    for i, floor in ipairs(floors) do
        local group = {}
        -- ARTWORK sublevels run -8..7. Shallower floors (low i) get the
        -- higher sublevel so they always paint over deeper ones for as long
        -- as both are partially visible during a fade.
        local sublevel = math.max(-8, math.min(7, 3 + (n - i)))
        local drew = self:RenderTiles(floor.mapID, sublevel, group)
        if drew then anyDrew = true end
        continuousTileGroups[i] = { mapID = floor.mapID, textures = group, alpha = 1 }
    end
    return anyDrew
end

--- Push per-floor alpha out to every continuous tile group, from a
--- fractional floor index (1 = topmost, matching FloorIndex — see
--- ValueToFractionalIndex). This is the whole of what dragging the slider
--- does while continuousActive; it never tears down or re-renders the tiles
--- themselves. The player pin no longer fades with the displayed floor —
--- see UpdatePlayerPin — so it isn't touched here.
function CaveRenderer:UpdateContinuousAlphas(fractionalIndex)
    for i, grp in ipairs(continuousTileGroups) do
        local alpha = ContinuousAlpha(i, fractionalIndex)
        grp.alpha = alpha
        for _, tex in ipairs(grp.textures) do
            tex:SetAlpha(alpha)
        end
    end
end

--- Per-floor alpha from the most recent continuous render, for /hfwm debug.
--- Returns nil outside continuous mode.
function CaveRenderer:DebugContinuous()
    if not continuousActive then return nil end
    return continuousTileGroups
end

--- Float slop for PieceInFloor's containment test — comfortably smaller
--- than the gap between Fargodeep's two floors' ranges at their nearest
--- point (Lower Mines tops out at 23.50, Upper's own floor starts at
--- 14.27, sharing that whole band — see PieceInFloor) while still forgiving
--- a hand-typed CaveData.lua value that is a hair off its source.
local PIECE_FLOOR_EPSILON = 0.1

--- Does `piece`'s own real-world-Z range (its baked zMin/zMax — see
--- CaveData.lua's Fargodeep `pieces` entries) sit entirely inside `floor`'s?
---
--- This is an exact test today, not a heuristic: a floor's own zMin/zMax is
--- *defined* as the min/max spanned by exactly the WMO groups baked into
--- that floor (hfwm/cave_minimap.py's world_z_range_for_groups, run once
--- over `upper_idx`/`lower_idx` for the floors and again per-group for the
--- pieces — see split_floors_by_height), so every one of Fargodeep's 21
--- pieces lands fully inside exactly one floor's range and never straddles
--- both. Checked by hand against every piece in CaveData.lua before this
--- was trusted (see the code review that added this function): none is
--- ambiguous.
---
--- Returns true (include, don't filter out) when either side has nothing to
--- compare — a future place with pieces but no per-floor zMin/zMax baked yet
--- degrades to showing extra art rather than silently losing a room.
---@param piece table  { zMin, zMax, ... } from ns.Cave:GetPieces
---@param floor table  an entry from Config.caveAllFloors
---@return boolean
local function PieceInFloor(piece, floor)
    if not (floor and floor.zMin and floor.zMax) then return true end
    if not (piece.zMin and piece.zMax) then return true end
    return piece.zMin >= floor.zMin - PIECE_FLOOR_EPSILON
       and piece.zMax <= floor.zMax + PIECE_FLOOR_EPSILON
end

--- Restrict a place's whole per-piece art list (every room, every floor) to
--- just the one floor's worth the floor picker (see the "Floor picker"
--- section below) currently has selected — or hand the list back untouched
--- when the picker is set to "All", which is today's default and the only
--- behaviour this place had before the picker existed.
---
--- Called from ShowCave before RenderContinuousPieces, so piecesZMin/
--- piecesZMax (set from whatever list actually gets drawn) come out scoped
--- to one floor too — which is what makes the depth slider's own range
--- independent per floor rather than always spanning the whole place: see
--- ElevationForValue and HeightWindowElevationBounds, neither of which
--- needed to change, because both already just read piecesZMin/piecesZMax.
---@param pieces table[]|nil  ns.Cave:GetPieces's full list for the place
---@param floors table[]|nil  Config.caveAllFloors
---@param floorMapID number|nil  the floor currently on screen
---@return table[]|nil
local function FilterPiecesByFloor(pieces, floors, floorMapID)
    if Config.caveFloorFilterAll or not floors or not pieces then
        return pieces
    end

    local floor
    for _, f in ipairs(floors) do
        if f.mapID == floorMapID then floor = f break end
    end
    if not floor or not floor.zMin or not floor.zMax then return pieces end

    local out = {}
    for _, piece in ipairs(pieces) do
        if PieceInFloor(piece, floor) then
            out[#out + 1] = piece
        end
    end
    -- An empty result means the containment test above didn't recognise
    -- anything as belonging to this floor (a future place's data doesn't
    -- cleanly partition the way Fargodeep's does) — showing everything is
    -- a better failure than showing nothing.
    return #out > 0 and out or pieces
end

--- cave-satellite-v2 Phase 2: draw every piece of a per-piece place at once —
--- each as its own full-canvas texture, baked to the exact same shared
--- canvas as the old floor composites (see cave_minimap.py's
--- generate_fargodeep_pieces) — so UpdatePieceWindowAlphas has something to
--- fade independently as the height-window rectangle moves or resizes. Only
--- called when ns.Cave:GetPieces(floorMapID) returns a non-empty list
--- (currently just Fargodeep Mine).
---@param pieces table[]  from ns.Cave:GetPieces, each {fdid, zMin, zMax, ...}
---@param pieceCanvasW number|nil  the canvas the pieces were baked to; only
--- used to sanity-check that there is one to draw, since the content frame
--- is already sized to this same canvas's aspect ratio via LayoutWindow's
--- ArtAspect (pieces share the floor art layer's dimensions by design).
---@param pieceCanvasH number|nil
---@return boolean anyDrew
function CaveRenderer:RenderContinuousPieces(pieces, pieceCanvasW, pieceCanvasH)
    if not content then return false end
    if not pieceCanvasW or pieceCanvasW <= 0
       or not pieceCanvasH or pieceCanvasH <= 0 then
        return false
    end

    local canvasW, canvasH = content:GetSize()
    if canvasW <= 0 or canvasH <= 0 then return false end

    local FDID_MAP  = Config:GetTileMap(Config:GetBackground())
    local FDID_BASE = Config.FDID_BASE
    local n         = #pieces

    piecesZMin, piecesZMax = nil, nil
    local anyDrew = false

    for order, piece in ipairs(pieces) do
        local rel = FDID_MAP[piece.fdid]
        local src = rel and (FDID_BASE .. rel) or piece.fdid

        -- Paint order: a piece with a higher ceiling paints over one with a
        -- lower ceiling for as long as both are partially visible, spread
        -- across every ARTWORK sublevel (-8..7) rather than one per piece —
        -- there can be (and with Fargodeep, are) more pieces than sublevels.
        local sublevel = 3
        if n > 1 then
            sublevel = math.floor(-8 + (order - 1) / (n - 1) * 15 + 0.5)
            sublevel = math.max(-8, math.min(7, sublevel))
        end

        local tex = PoolAcquire()
        tex:SetDrawLayer("ARTWORK", sublevel)
        tex:SetSize(canvasW, canvasH)
        tex:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        tex:SetTexture(src)

        continuousPieceGroups[order] = {
            texture = tex, zMin = piece.zMin, zMax = piece.zMax, alpha = 1,
        }
        anyDrew = true

        piecesZMin = piecesZMin and math.min(piecesZMin, piece.zMin) or piece.zMin
        piecesZMax = piecesZMax and math.max(piecesZMax, piece.zMax) or piece.zMax
    end

    return anyDrew
end

--- Per-piece alpha from the most recent piece render, for /hfwm debug.
--- Returns nil outside piece mode.
function CaveRenderer:DebugPieces()
    if not piecesActive then return nil end
    return continuousPieceGroups
end

--- Snapshot of the most recent RenderTiles call (layer dims + per-tile FDID
--- lookup results), for /hfwm debug. Returns nil if no floor has been
--- rendered yet this session. In continuous mode this is whichever floor
--- RenderContinuousFloors rendered last (the deepest) — see
--- CaveRenderer:DebugContinuous for the other floors' state.
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

    local floors = Config.caveAllFloors
    local n = floors and #floors or 0

    -- cave-satellite-v2 Phase 2: per-piece fading, when the place has piece
    -- data, supersedes the whole-floor crossfade below — it is the
    -- finer-grained replacement for it, not an addition to it, so the two
    -- are mutually exclusive (see the module-state comment above
    -- continuousPieceGroups). Both need more than one floor to have
    -- anything to fade between; a single-floor place is just RenderTiles.
    local pieces, pieceCanvasW, pieceCanvasH
    if n > 1 then
        pieces = ns.Cave:GetPieces(floorMapID)
        -- Floor picker (see FilterPiecesByFloor): scoped to one floor's own
        -- pieces when the picker isn't set to "All", which is also what
        -- narrows piecesZMin/piecesZMax — and therefore the depth slider's
        -- whole range — to that floor alone.
        pieces = FilterPiecesByFloor(pieces, floors, floorMapID)
        pieceCanvasW, pieceCanvasH = ns.Cave:GetPieceCanvasSize(floorMapID)
    end
    piecesActive = (pieces ~= nil and #pieces > 0)
    continuousActive = (not piecesActive) and n > 1
        and ns.Cave:HasContinuousDepth(floorMapID)

    PoolReleaseAll()
    LayoutWindow(floorMapID)

    local drew
    if piecesActive then
        drew = self:RenderContinuousPieces(pieces, pieceCanvasW, pieceCanvasH)
    elseif continuousActive then
        drew = self:RenderContinuousFloors(floors)
    else
        drew = self:RenderTiles(floorMapID)
    end
    titleText:SetText(ns.Cave:GetAreaTitle(floorMapID))

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

    SyncSlider(floors, floorMapID, continuousActive or piecesActive)
    SyncHeightWindow(piecesActive)
    SyncFloorPicker(floors, floorMapID)
    if piecesActive then
        self:UpdatePieceWindowAlphas()
    elseif continuousActive then
        self:UpdateContinuousAlphas(IndexToValue(FloorIndex(floorMapID) or 1))
    end
    UpdatePlayerPin()

    window:SetAlpha(Config:CaveAlpha())
    window:Show()

    Config.caveOverlayActive     = true
    Config.caveCurrentFloorMapID = floorMapID
    window:SetScript("OnUpdate", OnWindowUpdate)

    if Config.tracing then
        P(("CaveRenderer:ShowCave mapID=%s tiles=%d floors=%d continuous=%s pieces=%s"):format(
            tostring(floorMapID), #activeCaveTiles, n,
            tostring(continuousActive), tostring(piecesActive)))
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

--- Floor picker: scope the cave map to one floor's own pieces rather than
--- every floor layered together. Hands straight off to SelectFloor, which
--- already does everything a floor change needs (pin, rerender) — the
--- picker only adds the filter flag on top of it, so it and the depth
--- slider/mouse-wheel step can never disagree about which floor is current.
---@param floorMapID number
function CaveRenderer:SelectFloorFilter(floorMapID)
    Config.caveFloorFilterAll = false
    self:SelectFloor(floorMapID)
end

--- Floor picker: go back to every floor layered together (the default, and
--- this place's only behaviour before the picker existed). Doesn't change
--- which floor is "current" — only the filter does, so there is nothing
--- here for SelectFloor's pin logic to get involved in.
function CaveRenderer:SelectAllFloors()
    if Config.caveFloorFilterAll then return end
    Config.caveFloorFilterAll = true
    if Config.caveOverlayActive and Config.caveCurrentFloorMapID then
        self:ShowCave(Config.caveCurrentFloorMapID)
    end
end

function CaveRenderer:HideCave()
    Config.caveOverlayActive     = false
    Config.caveCurrentFloorMapID = nil
    Config.caveAllFloors         = nil
    Config.caveFloorPinned       = false
    Config.caveFloorFilterAll    = true
    continuousActive             = false
    piecesActive                 = false
    piecesZMin, piecesZMax       = nil, nil
    heightWindowDrag             = nil
    if windowBody then windowBody:Hide() end
    if floorPicker then floorPicker:Hide() end
    if CloseDropDownMenus then pcall(CloseDropDownMenus) end
    if not window then return end
    PoolReleaseAll()  -- also wipes continuousTileGroups and continuousPieceGroups
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

--- Current height-window rectangle state, for /hfwm debug. Returns nil
--- outside piece mode.
function CaveRenderer:DebugHeightWindow()
    if not piecesActive then return nil end
    local top, bottom = Config:CaveHeightWindow()
    local windowBottomZ, windowTopZ = HeightWindowElevationBounds()
    return { top = top, bottom = bottom, zMin = windowBottomZ, zMax = windowTopZ }
end

--- The header's *measured* geometry, for /hfwm debug.
---
--- This exists because three rounds of header fixes were diagnosed by reading
--- pixels off a screenshot, and the readings kept pointing at the wrong cause:
--- a band that is the wrong height, a band that draws nothing and lets the
--- border show through, and one stray unanchored texture centred on the frame
--- all look about the same at screenshot resolution. The rects below settle
--- which it is in one line each. Anything derived (does the banner actually
--- cover the bar, is the title inside the band) is reported as the comparison,
--- not left to the reader to do by eye.
---
--- Returns nil when the window has never been built, since every number here
--- would otherwise be a guess about a frame that does not exist.
function CaveRenderer:HeaderReport()
    if not window or not titleBar then return nil end

    local function rect(f)
        if not f or not f.GetLeft or not f:GetLeft() then return nil end
        return {
            left = f:GetLeft(), right = f:GetRight(),
            top = f:GetTop(), bottom = f:GetBottom(),
            w = f:GetWidth(), h = f:GetHeight(),
        }
    end

    local strip = {}
    for _, tex in ipairs(titleBar.hfwmStrip or {}) do
        strip[#strip + 1] = {
            art  = (tex.GetAtlas and tex:GetAtlas())
                or (tex.GetTexture and tex:GetTexture()) or "?",
            rect = rect(tex),
        }
    end

    return {
        source    = Config.caveTitleBannerSource,
        cloned    = titleBar.hfwmCloned and true or false,
        -- False after a layout means the map frame still could not be
        -- measured, so the header is unpainted and a retry is still pending.
        settled   = titleBar.hfwmSettled and true or false,
        titleH    = titleH,
        fallbackH = TITLE_H,
        borderArt = BORDER_ART,
        window    = rect(window),
        bar       = rect(titleBar),
        strip     = strip,
        title     = rect(titleText),
        close     = rect(closeBtn),
        content   = rect(content),
    }
end

--- What the live map's title strip actually is: every texture CollectTitleStrip
--- would clone, with its asset name and its measured offsets, plus the map's
--- own title FontString.
---
--- This is the tool that should have existed three rounds ago. Every wrong
--- header in this file's history came from *deciding* what the map's title bar
--- is made of instead of asking, and a screenshot cannot answer the question —
--- an atlas name and a set of offsets can.
function CaveRenderer:TitleStripReport()
    local pieces, frameTop, frameCX, frameW = CollectTitleStrip()
    local out = {
        frameTop = frameTop, frameCX = frameCX, frameW = frameW,
        pieces   = {},
    }
    for _, p in ipairs(pieces or {}) do
        out.pieces[#out.pieces + 1] = {
            art      = (p.region.GetAtlas and p.region:GetAtlas())
                or (p.region.GetTexture and p.region:GetTexture())
                or "colour fill",
            topInset = p.topInset, height = p.height,
            leftInset = p.leftInset, rightInset = p.rightInset,
            width = p.width, centerDX = p.centerDX,
            layer = p.layer, sublevel = p.sublevel,
            -- How CloneTitleStrip will treat it, reported rather than
            -- re-derived by the reader: this single decision is the difference
            -- between a stretched band and a centred plaque.
            asBand = IsBand(p),
        }
    end

    local src = MapTitleFontString()
    local l, r, t, b = RectOf(src)
    if l then
        out.title = {
            font      = src.GetFontObject and src:GetFontObject()
                and src:GetFontObject():GetName() or nil,
            text      = src.GetText and src:GetText() or nil,
            topInset  = frameTop and (frameTop - t) or nil,
            height    = t - b,
            centerDX  = frameCX and ((l + r) / 2 - frameCX) or nil,
        }
    end
    return out
end

function CaveRenderer:IsShown()
    return window and window:IsShown() and true or false
end

--- Every tile currently drawn, discrete or continuous: RenderContinuousFloors
--- still acquires each floor's tiles through the same PoolAcquire as
--- RenderTiles, so `activeCaveTiles` already spans all of them and needs no
--- separate continuous-mode count.
function CaveRenderer:ActiveTileCount()
    return #activeCaveTiles
end

function CaveRenderer:IsContinuousActive()
    return continuousActive
end

--- cave-satellite-v2 Phase 2: true while the currently shown place is
--- fading individual pieces by real elevation rather than crossfading whole
--- floors — see the module-state comment above continuousPieceGroups for
--- why the two are mutually exclusive.
function CaveRenderer:IsPiecesActive()
    return piecesActive
end
