-------------------------------------------------------------------------------
-- HFWM-Forever Renderer
-- Core tile layout: resolves tile source, lays out textures on the canvas.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Renderer    = ns.Renderer
local Config      = ns.Config
local Pool        = ns.Pool
local MaskPool    = ns.MaskPool
local BaseArt     = ns.BaseArt
local MapFrameBg  = ns.MapFrameBg
local Exploration = ns.Exploration
local Watchdog    = ns.Watchdog
local P           = ns.P

-------------------------------------------------------------------------------
-- Backdrop
--
-- The bundled BLPs ship with their sea and their uncovered cells
-- transparent (pipeline art pass "alpha-sea"), so *something* has to be
-- behind them. What that something is, is the map-background setting:
--
--   Ocean Blue   a flat colour drawn here, Blizzard's art hidden
--   Hybrid       no backdrop at all, Blizzard's art left visible so it
--                shows through the transparent sea
--   Transparent  no backdrop, no Blizzard's art, and the map frame's own
--                backing hidden too (MapFrameBg) so the holes go through the
--                UI and onto the world rather than onto a panel. Without
--                that last layer it differs from Hybrid only in whether
--                Blizzard's art shows, which is not much of a choice.
--   Original     a separate, opaque tile set; nothing could show through
--                it, so again no backdrop
--
-- One texture on the overlay frame, at the BACKGROUND draw layer so it sits
-- under the tiles (TexturePool creates those at ARTWORK sublevel 2). It
-- covers the whole frame, which is exactly the tile grid: the frame is
-- SetAllPoints to the canvas, and the grid is laid out at
-- layerW*scaleX x layerH*scaleY == canvasW x canvasH.
-------------------------------------------------------------------------------
-- Created once and kept. Refresh() can re-parent the overlay frame when the
-- client swaps the canvas out from under it, but the frame object itself is
-- never replaced, so the texture on it stays good.
local function GetBackdrop()
    if not Config.overlayFrame then return nil end
    if not Config.backdropTexture then
        local tex = Config.overlayFrame:CreateTexture(nil, "BACKGROUND")
        tex:SetAllPoints(Config.overlayFrame)
        Config.backdropTexture = tex
    end
    return Config.backdropTexture
end

--- Apply the chosen background: colour the backdrop, stand aside for
--- Blizzard's art, or need nothing behind the tiles at all. Returns the
--- entry applied.
---@param bg table entry from Config.BACKGROUNDS
local function ApplyBackground(bg)
    local tex = GetBackdrop()
    if bg.rgb then
        if tex then
            tex:SetColorTexture(bg.rgb[1], bg.rgb[2], bg.rgb[3], 1)
            tex:Show()
        end
        BaseArt:SetVisible(false)
    elseif bg.blizzardArt then
        if tex then tex:Hide() end
        BaseArt:SetVisible(true)
    else
        -- Transparent and Original: nothing of ours behind the tiles, and
        -- nothing of Blizzard's either.
        if tex then tex:Hide() end
        BaseArt:SetVisible(false)
    end
    -- Orthogonal to the three branches above, and only Transparent wants it:
    -- the other entries all put something opaque in front of the frame's own
    -- backing, so hiding it would change nothing but could still be seen at
    -- the map's edges.
    MapFrameBg:SetVisible(not bg.seeThrough)
    return bg
end

--- Restore default map art and release HFWM textures.
local function RestoreDefaults()
    Config.overlayActive = false
    if Config.backdropTexture then Config.backdropTexture:Hide() end
    BaseArt:SetVisible(true)
    MapFrameBg:SetVisible(true)
    Exploration:SetVisible(true)
end

--- Fog of War: draw the slice of this addon's own tile grid that falls
--- under one of Blizzard's own, currently-active exploration reveal
--- textures (Exploration:EnumerateOverlayTextures), cropped to that exact
--- texture's own alpha shape — the same torn, feathered edge Blizzard's
--- own map uses right now — instead of a hard rectangle.
---
--- The whole point of this over recomputing the same shape from
--- C_MapExplorationInfo (the previous approach here, which placed pieces
--- wrong on this client): *blizTex* is a live Texture object Blizzard's
--- own client already positioned, sized, textured and cropped correctly
--- this very frame — HidePins only set its alpha to 0, it is still doing
--- everything else a normal, undisturbed exploration overlay does — so
--- its geometry is read directly off it (GetLeft/Top/Right/Bottom,
--- GetTexture, GetTexCoord) rather than rebuilt from raw offsets and an
--- assumed tile size / file-padding scheme this addon has no way to
--- verify holds on every client.
---
--- *blizTex*'s own screen rect only rarely lines up with this addon's own
--- tile grid, so it is usually split across more than one of this
--- addon's own tiles; each such split gets its own texture, masked with
--- the matching slice of *blizTex*'s own mask shape, so the pieces still
--- line up into that one true shape once drawn.
---@param blizTex table live Texture from Exploration:EnumerateOverlayTextures
---@param frameLeft number Config.overlayFrame:GetLeft(), screen space
---@param frameTop number Config.overlayFrame:GetTop(), screen space
---@param layerW number
---@param layerH number
---@param tilePxW number
---@param tilePxH number
---@param cols number
---@param rows number
---@param tileSource table
---@param scaleX number
---@param scaleY number
---@param trace boolean|nil
---@return number piecesDrawn
local function DrawExploredPiece(
    blizTex, frameLeft, frameTop,
    layerW, layerH, tilePxW, tilePxH, cols, rows, tileSource, scaleX, scaleY,
    trace)

    -- isShownByMouseOver pieces (Blizzard's own RefreshOverlays) start
    -- Hidden and only Blizzard's own mouse-over handling ever Shows them
    -- — nothing this addon does touches that — so an unshown texture here
    -- means Blizzard itself is not currently revealing anything with it,
    -- same as if it were not in the list at all.
    if not blizTex:IsShown() then
        if trace then P("  fog piece SKIPPED: not shown") end
        return 0
    end

    local texLeft, texTop = blizTex:GetLeft(), blizTex:GetTop()
    local texRight, texBottom = blizTex:GetRight(), blizTex:GetBottom()
    if not (texLeft and texTop and texRight and texBottom
        and frameLeft and frameTop) then
        -- GetLeft/Top/Right/Bottom return nil until a region has actually
        -- been laid out on screen at least once -- shown is not the same
        -- as laid out. The very first time this addon ever lets
        -- Blizzard's own exploration provider populate on a given map
        -- (previously always suppressed via RemoveAllData before it could
        -- draw anything), that first frame's freshly (re)acquired chunk
        -- textures can still read nil here even though IsShown() is
        -- already true; see the retry in the caller.
        if trace then
            P(("  fog piece SKIPPED: not laid out yet (left=%s top=%s "
               .. "right=%s bottom=%s frameLeft=%s frameTop=%s)"):format(
                tostring(texLeft), tostring(texTop), tostring(texRight),
                tostring(texBottom), tostring(frameLeft), tostring(frameTop)))
        end
        return 0
    end

    -- Blizzard's screen-space rect, remapped into this addon's own
    -- layer-pixel space by the same scale this refresh already uses for
    -- its own tiles. GetTop/GetBottom count up from the bottom of the
    -- screen (WoW's usual convention), so frameTop - texTop is the
    -- distance *down* from the frame's own top edge, matching the sign
    -- the ordinary tile-layout loop already uses for cellY.
    local chunkX0 = (texLeft - frameLeft) / scaleX
    local chunkX1 = (texRight - frameLeft) / scaleX
    local chunkY0 = (frameTop - texTop) / scaleY
    local chunkY1 = (frameTop - texBottom) / scaleY

    local chunkW = chunkX1 - chunkX0
    local chunkH = chunkY1 - chunkY0
    if chunkW <= 0 or chunkH <= 0 then
        if trace then
            P(("  fog piece SKIPPED: degenerate chunk %.2fx%.2f"):format(
                chunkW, chunkH))
        end
        return 0
    end

    local maskFile = blizTex:GetTexture()
    if not maskFile then
        if trace then P("  fog piece SKIPPED: no texture file") end
        return 0
    end

    -- Every reveal piece Blizzard draws is an unrotated, unflipped crop
    -- (its own RefreshOverlays only ever calls the plain 4-argument
    -- SetTexCoord(left, right, top, bottom)), so the 8-value getter's
    -- four corners reduce to one rectangle: upper-left and upper-right
    -- share their top, upper-left and lower-left share their left, and
    -- so on.
    local ulX, ulY, llX, llY, urX, urY = blizTex:GetTexCoord()
    local maskLeft, maskRight = ulX, urX
    local maskTop, maskBottom = ulY, llY

    if trace then
        P(("  fog piece: screen=[%.1f,%.1f]-[%.1f,%.1f]  chunk(layerpx)="
           .. "[%.1f,%.1f]-[%.1f,%.1f] (%.1fx%.1f)  mask=%s  "
           .. "maskTexCoord=%.4f,%.4f,%.4f,%.4f"):format(
            texLeft, texTop, texRight, texBottom,
            chunkX0, chunkY0, chunkX1, chunkY1, chunkW, chunkH,
            tostring(maskFile), maskLeft, maskRight, maskTop, maskBottom))
    end

    local colStart = math.max(0, math.floor(chunkX0 / tilePxW))
    local colEnd   = math.min(cols - 1, math.ceil(chunkX1 / tilePxW) - 1)
    local rowStart = math.max(0, math.floor(chunkY0 / tilePxH))
    local rowEnd   = math.min(rows - 1, math.ceil(chunkY1 / tilePxH) - 1)

    if trace then
        P(("    tiles touched: cols=%d rows=%d tilePx=%dx%d  colStart=%d "
           .. "colEnd=%d rowStart=%d rowEnd=%d (%d cell(s))"):format(
            cols, rows, tilePxW, tilePxH, colStart, colEnd, rowStart, rowEnd,
            (colEnd - colStart + 1) * (rowEnd - rowStart + 1)))
    end

    local piecesDrawn, nilSrcSkipped, degenerateSkipped = 0, 0, 0
    for row = rowStart, rowEnd do
        for col = colStart, colEnd do
            local src = tileSource[row * cols + col + 1]
            if not src then nilSrcSkipped = nilSrcSkipped + 1 end
            if src then
                local tileX0 = col * tilePxW
                local tileY0 = row * tilePxH
                local tileX1 = tileX0 + math.min(tilePxW, layerW - tileX0)
                local tileY1 = tileY0 + math.min(tilePxH, layerH - tileY0)

                local ix0 = math.max(tileX0, chunkX0)
                local ix1 = math.min(tileX1, chunkX1)
                local iy0 = math.max(tileY0, chunkY0)
                local iy1 = math.min(tileY1, chunkY1)

                if not (ix1 > ix0 and iy1 > iy0) then
                    degenerateSkipped = degenerateSkipped + 1
                end
                if ix1 > ix0 and iy1 > iy0 then
                    local screenW = (ix1 - ix0) * scaleX
                    local screenH = (iy1 - iy0) * scaleY
                    local screenX = ix0 * scaleX
                    local screenY = iy0 * scaleY

                    local tex = Pool:Acquire()
                    tex:SetSize(screenW, screenH)
                    tex:SetPoint("TOPLEFT", Config.overlayFrame, "TOPLEFT",
                        screenX, -screenY)
                    tex:SetTexCoord(
                        (ix0 - tileX0) / tilePxW, (ix1 - tileX0) / tilePxW,
                        (iy0 - tileY0) / tilePxH, (iy1 - tileY0) / tilePxH)
                    tex:SetTexture(src)

                    -- Same screen rect as the tile piece above so the two
                    -- register pixel-for-pixel, cropped to the fraction of
                    -- *blizTex*'s own rect this piece occupies, then
                    -- placed within blizTex's own texture-coordinate
                    -- rectangle (rather than assumed to start at 0,0 —
                    -- Blizzard's own crop can itself start anywhere).
                    local fracLeft   = (ix0 - chunkX0) / chunkW
                    local fracRight  = (ix1 - chunkX0) / chunkW
                    local fracTop    = (iy0 - chunkY0) / chunkH
                    local fracBottom = (iy1 - chunkY0) / chunkH

                    local mask = MaskPool:Acquire()
                    mask:SetSize(screenW, screenH)
                    mask:SetPoint("TOPLEFT", Config.overlayFrame, "TOPLEFT",
                        screenX, -screenY)
                    mask:SetTexture(maskFile,
                        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                    mask:SetTexCoord(
                        maskLeft + fracLeft   * (maskRight  - maskLeft),
                        maskLeft + fracRight  * (maskRight  - maskLeft),
                        maskTop  + fracTop    * (maskBottom - maskTop),
                        maskTop  + fracBottom * (maskBottom - maskTop))
                    tex:AddMaskTexture(mask)
                    piecesDrawn = piecesDrawn + 1
                end
            end
        end
    end

    if trace then
        P(("    -> %d piece(s) drawn  (%d skipped: no tileSource entry  "
           .. "%d skipped: degenerate intersection)"):format(
            piecesDrawn, nilSrcSkipped, degenerateSkipped))
    end
    return piecesDrawn
end

--- Main overlay refresh.
---@param force boolean|nil
function Renderer:Refresh(force)
    if not Config.overlayFrame then return end

    local mapID = WorldMapFrame:GetMapID()
    if not mapID then
        Config.overlayActive = false
        Pool:ReleaseAll()
        MaskPool:ReleaseAll()
        Config.lastMapID = nil
        return
    end

    local canvas = WorldMapFrame.ScrollContainer
        and WorldMapFrame.ScrollContainer.Child
    if not canvas then return end

    -- Re-parent overlay frame if canvas was replaced (WoW 12.0+)
    if Config.overlayFrame:GetParent() ~= canvas then
        Config.overlayFrame:SetParent(canvas)
        Config.overlayFrame:ClearAllPoints()
        Config.overlayFrame:SetAllPoints(canvas)
        Config.overlayFrame:SetFrameLevel(canvas:GetFrameLevel() + 500)
        Config.overlayFrame:EnableMouse(false)
    end

    -- A replaced canvas doesn't just need re-parenting: MapFrameBg's
    -- Transparent-mode concealment (and BaseArt's) is keyed off specific
    -- region objects it found and hid — WorldMapFrame.ScrollContainer.Child
    -- .TiledBackground among them, the wood-grain placeholder the canvas
    -- itself paints behind everything else. A *new* canvas object means a
    -- brand new TiledBackground region that was never found, hidden or
    -- hooked, and it stays visible until something forces a fresh
    -- concealment pass. Without this, "canvasChanged" was silently absorbed
    -- by the "skip if nothing changed" check below whenever the swap didn't
    -- also change mapID/size/layerIdx — which is the ordinary case — so
    -- Transparent could come back from a canvas swap permanently showing
    -- Blizzard's wood backing with no further Refresh ever re-checking it.
    local canvasChanged = (canvas ~= Config.lastCanvas)

    local canvasW, canvasH = canvas:GetSize()

    -- Determine art layer (surface vs. underwater)
    local allLayers = C_Map.GetMapArtLayers(mapID)
    local numLayers = allLayers and #allLayers or 0
    local submerged = IsSubmerged() and true or false
    local layerIdx  = 1
    if numLayers >= 2 and submerged then
        layerIdx = 2
    end

    -- Trace logging during forced refresh
    local trace = force and Config.tracing
    if trace then
        P(("Refresh: mapID=%s  canvas=%dx%d  layers=%d  sub=%s  layerIdx=%d"):format(
            tostring(mapID), canvasW, canvasH, numLayers,
            tostring(submerged), layerIdx))
        P(("  parent match=%s  overlayFrame parent=%s"):format(
            tostring(Config.overlayFrame:GetParent() == canvas),
            tostring(Config.overlayFrame:GetParent())))
    end

    -- Skip if nothing changed. canvasChanged is deliberately its own term
    -- here rather than folded into a change to canvasW/canvasH: a replaced
    -- canvas at the *same* size would otherwise still look unchanged to
    -- this check (see the canvasChanged comment above) and skip the
    -- MapFrameBg/BaseArt re-application a swap requires.
    if not force and not canvasChanged and mapID == Config.lastMapID
       and canvasW == Config.lastCanvasW
       and canvasH == Config.lastCanvasH
       and layerIdx == Config.lastLayerIdx
       and Pool:ActiveCount() > 0 then
        return
    end

    Pool:ReleaseAll()
    MaskPool:ReleaseAll()
    Config.lastCanvas    = canvas
    Config.lastMapID     = mapID
    Config.lastCanvasW   = canvasW
    Config.lastCanvasH   = canvasH
    Config.lastLayerIdx  = layerIdx
    Config.lastSubmerged = submerged

    if not Config.db or not Config.db.enabled then
        if trace then P("  BAIL: disabled") end
        RestoreDefaults()
        return
    end
    if not mapID then
        if trace then P("  BAIL: no mapID") end
        return
    end

    if numLayers == 0 then
        if trace then P("  BAIL: numLayers=0") end
        RestoreDefaults()
        return
    end

    local layer   = allLayers[layerIdx]
    local layerW  = layer.layerWidth
    local layerH  = layer.layerHeight
    local tilePxW = layer.tileWidth  or 256
    local tilePxH = layer.tileHeight or 256
    local cols    = math.ceil(layerW / tilePxW)
    local rows    = math.ceil(layerH / tilePxH)

    -- Hoisted above Activate() (which used to compute this itself) because
    -- the tile-layout section below needs it too, to decide whether to draw
    -- the ordinary unconditional grid or Fog of War's explored-only subset.
    local fogOfWar = Config:FogOfWarEnabled()

    -- The background decides which tile set to draw, not just what goes
    -- behind it: Original has its own raw dump under WorldMap/Original/ and
    -- therefore its own lookup table. Everything else draws the bundled
    -- transparent art. Resolved before ApplyBackground so both see the same
    -- entry.
    local background   = Config:GetBackground()
    local FDID_MAP     = Config:GetTileMap(background)
    local FDID_MAP_SUB = Config.FDID_MAP_SUB
    local FDID_BASE    = Config.FDID_BASE

    local tileSource = {}
    local useBundled = false
    local useNative  = false

    -- Higher-resolution maps (see hfwm/db2.py's _hires_geometry) bypass
    -- Blizzard's fixed art-layer geometry entirely: every Type=Zone map,
    -- uncapped, plus Kalimdor/Eastern Kingdoms/the top-level Azeroth map,
    -- capped (see HIRES_CONTINENT_MAPS). Our own bundled grid is finer
    -- than anything a Classic-era UiMapArtStyleLayer can describe for
    -- these, so cols/rows/tile size/layer size all come from the
    -- pipeline's own output instead of C_Map.GetMapArtLayers, and the
    -- tile source is built straight from a path prefix rather than
    -- looked up per Blizzard FileDataID.
    local nativeZone = Config:GetNativeZone(mapID, background)
    if nativeZone then
        layerW, layerH = nativeZone.layerW, nativeZone.layerH
        tilePxW, tilePxH = nativeZone.tileW, nativeZone.tileH
        cols, rows = nativeZone.cols, nativeZone.rows
        for i = 1, cols * rows do
            tileSource[i] = FDID_BASE .. nativeZone.path .. i
        end
        useBundled, useNative = true, true
    end

    -- Resolve tile source (legacy path: only when this map has no native
    -- geometry above — continent/world maps, or a native zone whose art
    -- wasn't actually built, in which case this safely falls back to
    -- Blizzard's own client art rather than erroring).
    local fdids
    if not useNative then
        fdids = C_Map.GetMapArtLayerTextures(mapID, layerIdx)
        if not fdids or #fdids == 0 then
            if trace then P("  BAIL: no FDIDs from C_Map") end
            RestoreDefaults()
            return
        end
        useBundled = FDID_MAP[fdids[1]] ~= nil
    end

    if trace then
        P(("  useNative=%s  fdids=%s  useBundled=%s  background=%s  "
           .. "tileMap_size=%d"):format(
            tostring(useNative), fdids and #fdids or "n/a",
            tostring(useBundled), background.key,
            background.tiles == "original"
                and (Config._fdidMapOriginalSize or -1)
                or (Config._fdidMapSize or -1)))
    end
    local useSubmerged = false

    if useNative then
        -- tileSource already built above.
    elseif useBundled and FDID_MAP_SUB[fdids[1]] then
        local playerMap = C_Map.GetBestMapForUnit("player")
        local inVashjir = playerMap and Config.VASHJIR_MAPS[playerMap]
        if not (inVashjir and not submerged) then
            useSubmerged = true
        end
    elseif useBundled and layerIdx >= 2 then
        useBundled = false
    end

    if not useNative then
        if useBundled then
            local lookup = useSubmerged and FDID_MAP_SUB or FDID_MAP
            for i, fdid in ipairs(fdids) do
                local rel = lookup[fdid]
                tileSource[i] = rel and (FDID_BASE .. rel) or fdid
            end
        else
            tileSource = fdids
        end
    end

    if trace then
        P(("  tileSource[1]=%s"):format(tostring(tileSource[1])))
        if type(tileSource[1]) == "string" then
            P(("  tileSource[1] type=string (bundled path)"))
        else
            P(("  tileSource[1] type=%s (raw FDID)"):format(type(tileSource[1])))
        end
    end

    --- Switch the overlay on, and return the background entry in force.
    ---
    --- The *tile* half of the background setting only means anything where
    --- we are drawing our own transparent tiles: on a map with no bundled
    --- BLPs the tiles are the client's own opaque art regardless of which
    --- background is selected, so this skips ApplyBackground's tile/backdrop
    --- branches and behaves exactly as before — hide the detail layer, draw
    --- no backdrop of our own, return nil to say that half of the setting
    --- does not apply here.
    ---
    --- The map-frame-backing half is a different question, and this used to
    --- get it wrong: it called MapFrameBg:SetVisible(true) unconditionally,
    --- regardless of which background was actually selected. Nothing here
    --- draws over that backing on this kind of map (no bundled tiles, no
    --- backdrop texture), so Transparent still needs it hidden for the same
    --- reason ApplyBackground hides it — otherwise Transparent shows
    --- Blizzard's own wood-grain map-frame backing on every map this addon
    --- has no replacement art for, no matter what the user picked.
    local function Activate()
        Config.overlayActive = true
        local bg
        if useBundled then
            bg = ApplyBackground(background)
            if fogOfWar then
                -- Fog of War wants Blizzard's own detail-layer art
                -- underneath this addon's tiles regardless of which
                -- background is chosen: that grayscale-until-explored art
                -- is what shows through wherever the tile-layout section
                -- below does not draw one of this addon's own tiles over
                -- it, which on purpose is now wherever the player has not
                -- actually explored. Overrides ApplyBackground's own
                -- BaseArt choice above on purpose.
                BaseArt:SetVisible(true)
            end
        else
            if Config.backdropTexture then Config.backdropTexture:Hide() end
            BaseArt:SetVisible(false)
            MapFrameBg:SetVisible(not background.seeThrough)
        end
        if fogOfWar and useBundled then
            -- Fog of War's own tiles below are drawn FROM Blizzard's live
            -- exploration textures (Exploration:EnumerateOverlayTextures /
            -- DrawExploredPiece), so unlike the plain-suppression case,
            -- that data has to stay populated and enumerable rather than
            -- released -- HidePins only zeroes alpha on the originals,
            -- which has no bearing on the separate MaskTexture objects
            -- DrawExploredPiece points at the same underlying files.
            Exploration:HidePins()
        else
            -- No Fog of War reveal to build from here (feature off, or
            -- this map has no bundled art of ours to selectively show), so
            -- Blizzard's own reveal pins would only ever redundantly
            -- restate what this addon's own tiles (or their absence)
            -- already show -- suppressed the ordinary, full way.
            Exploration:SetVisible(false)
        end
        Watchdog:Start()
        return bg
    end

    if canvasW == 0 or canvasH == 0 then
        Activate()
        return
    end

    -- Activate overlay
    local bg = Activate()

    if trace then
        P(("  background=%s  baseArtVisible=%s"):format(
            bg and bg.key or "n/a", tostring(BaseArt.visible)))
    end

    local currentLevel = canvas:GetFrameLevel()
    Config.overlayFrame:SetFrameLevel(currentLevel + 500)
    Config.overlayFrame:SetAlpha(Config.db.alpha)

    -- Tile layout
    local scaleX = canvasW / layerW
    local scaleY = canvasH / layerH

    -- Fog of War: swap the ordinary unconditional grid for just the tiles
    -- (or slices of tiles) that fall under one of Blizzard's own, live
    -- exploration reveal textures. `fogActive` is deliberately the gate
    -- for which loop below runs, not a separate flag next to it, so every
    -- way this can end up unusable — the feature off, or this map having
    -- no bundled art of ours to selectively show — falls back to exactly
    -- the ordinary full grid rather than needing its own case.
    local fogActive = fogOfWar and useBundled
    local blizExploredTextures = fogActive
        and Exploration:EnumerateOverlayTextures()
    local fogPiecesDrawn = 0

    if fogActive then
        local frameLeft = Config.overlayFrame:GetLeft()
        local frameTop  = Config.overlayFrame:GetTop()
        if trace then
            P(("  fog: %d live Blizzard texture(s) found  frameLeft=%s "
               .. "frameTop=%s"):format(
                #blizExploredTextures, tostring(frameLeft), tostring(frameTop)))
        end
        for _, blizTex in ipairs(blizExploredTextures) do
            fogPiecesDrawn = fogPiecesDrawn
                + DrawExploredPiece(
                    blizTex, frameLeft, frameTop,
                    layerW, layerH, tilePxW, tilePxH, cols, rows, tileSource,
                    scaleX, scaleY, trace)
        end

        -- GetLeft/Top/Right/Bottom on a region only resolve once it has
        -- actually rendered at least one frame after being (re)shown or
        -- repositioned. The very first time this addon lets Blizzard's own
        -- exploration provider populate on a given map -- previously
        -- always pre-empted by RemoveAllData before it ever got to lay
        -- anything out -- its freshly (re)acquired chunk textures can
        -- still be mid-layout this same tick even though EnumerateOverlay
        -- Textures() just forced them to exist. That shows up here as
        -- real entries but zero usable geometry: not Fog of War's
        -- legitimate "nothing explored yet" (which wouldn't have produced
        -- any entries in the first place), so retry exactly once next
        -- frame, by which point the layout pass has caught up, rather than
        -- leaving the map looking blank until something else happens to
        -- trigger another refresh.
        if fogPiecesDrawn == 0 and #blizExploredTextures > 0
            and not Config._fogRetryPending then
            if trace then P("  fog: 0 pieces from real entries -- retrying next frame") end
            Config._fogRetryPending = true
            C_Timer.After(0, function()
                Config._fogRetryPending = false
                if Config.overlayActive and Config:FogOfWarEnabled() then
                    Renderer:ForceRefresh()
                end
            end)
        end
    else
        local tileIdx = 1
        for row = 0, rows - 1 do
            for col = 0, cols - 1 do
                local src = tileSource[tileIdx]
                if not src then break end

                local artTileW = math.min(tilePxW, layerW - col * tilePxW)
                local artTileH = math.min(tilePxH, layerH - row * tilePxH)

                local cellW = artTileW * scaleX
                local cellH = artTileH * scaleY
                local cellX = col * tilePxW * scaleX
                local cellY = row * tilePxH * scaleY

                local texRight  = artTileW / tilePxW
                local texBottom = artTileH / tilePxH

                local tex = Pool:Acquire()
                tex:SetSize(cellW, cellH)
                tex:SetPoint(
                    "TOPLEFT", Config.overlayFrame, "TOPLEFT", cellX, -cellY)
                tex:SetTexCoord(0, texRight, 0, texBottom)
                tex:SetTexture(src)
                tileIdx = tileIdx + 1
            end
        end
    end

    -- Fog of War genuinely can mean zero tiles here — a map the player has
    -- not explored any of yet, or has no live reveal textures to read this
    -- particular refresh — which is not the failure this is meant to
    -- catch: fogActive being true at all already means this is Fog of
    -- War's own intentionally-partial grid, not a lookup that came back
    -- empty by mistake, so there is nothing to fall back from.
    if Pool:ActiveCount() == 0 and not fogActive then
        P("No textures created for mapID " .. mapID .. " — restoring default art")
        RestoreDefaults()
    end
end

--- Debounced refresh for OnSizeChanged thrashing.
function Renderer:ScheduleRefresh()
    if Config.refreshPending then return end
    Config.refreshPending = true
    C_Timer.After(0.05, function()
        Config.refreshPending = false
        self:Refresh()
    end)
end

--- Force a full refresh (clears all cached state).
function Renderer:ForceRefresh()
    Config.lastCanvas    = nil
    Config.lastMapID     = nil
    Config.lastCanvasW   = 0
    Config.lastCanvasH   = 0
    Config.lastLayerIdx  = nil
    Config.lastSubmerged = nil
    Config.refreshPending = false
    self:Refresh(true)
end
