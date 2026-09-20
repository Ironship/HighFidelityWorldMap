-------------------------------------------------------------------------------
-- HFWM-Forever Renderer
-- Core tile layout: resolves tile source, lays out textures on the canvas.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Renderer    = ns.Renderer
local Config      = ns.Config
local Pool        = ns.Pool
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

--- Main overlay refresh.
---@param force boolean|nil
function Renderer:Refresh(force)
    if not Config.overlayFrame then return end

    local mapID = WorldMapFrame:GetMapID()
    if not mapID then
        Config.overlayActive = false
        Pool:ReleaseAll()
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

    -- Resolve tile source
    local fdids = C_Map.GetMapArtLayerTextures(mapID, layerIdx)
    if not fdids or #fdids == 0 then
        if trace then P("  BAIL: no FDIDs from C_Map") end
        RestoreDefaults()
        return
    end

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
    local useBundled = FDID_MAP[fdids[1]] ~= nil

    if trace then
        P(("  fdids=%d  firstFDID=%d  useBundled=%s  background=%s  "
           .. "tileMap_size=%d"):format(
            #fdids, fdids[1], tostring(useBundled), background.key,
            background.tiles == "original"
                and (Config._fdidMapOriginalSize or -1)
                or (Config._fdidMapSize or -1)))
    end
    local useSubmerged = false

    if useBundled and FDID_MAP_SUB[fdids[1]] then
        local playerMap = C_Map.GetBestMapForUnit("player")
        local inVashjir = playerMap and Config.VASHJIR_MAPS[playerMap]
        if not (inVashjir and not submerged) then
            useSubmerged = true
        end
    elseif useBundled and layerIdx >= 2 then
        useBundled = false
    end

    if useBundled then
        local lookup = useSubmerged and FDID_MAP_SUB or FDID_MAP
        for i, fdid in ipairs(fdids) do
            local rel = lookup[fdid]
            tileSource[i] = rel and (FDID_BASE .. rel) or fdid
        end
    else
        tileSource = fdids
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
        else
            if Config.backdropTexture then Config.backdropTexture:Hide() end
            BaseArt:SetVisible(false)
            MapFrameBg:SetVisible(not background.seeThrough)
        end
        Exploration:SetVisible(false)
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
            tex:SetPoint("TOPLEFT", Config.overlayFrame, "TOPLEFT", cellX, -cellY)
            tex:SetTexCoord(0, texRight, 0, texBottom)
            tex:SetTexture(src)
            tileIdx = tileIdx + 1
        end
    end

    if Pool:ActiveCount() == 0 then
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
