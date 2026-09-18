-------------------------------------------------------------------------------
-- HFWM-Forever Renderer
-- Core tile layout: resolves tile source, lays out textures on the canvas.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Renderer    = ns.Renderer
local Config      = ns.Config
local Pool        = ns.Pool
local BaseArt     = ns.BaseArt
local Exploration = ns.Exploration
local Watchdog    = ns.Watchdog
local P           = ns.P

--- Restore default map art and release HFWM textures.
local function RestoreDefaults()
    Config.overlayActive = false
    BaseArt:SetVisible(true)
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

    -- Skip if nothing changed
    if not force and mapID == Config.lastMapID
       and canvasW == Config.lastCanvasW
       and canvasH == Config.lastCanvasH
       and layerIdx == Config.lastLayerIdx
       and Pool:ActiveCount() > 0 then
        return
    end

    Pool:ReleaseAll()
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

    local FDID_MAP     = Config.FDID_MAP
    local FDID_MAP_SUB = Config.FDID_MAP_SUB
    local FDID_BASE    = Config.FDID_BASE

    local tileSource = {}
    local useBundled = FDID_MAP[fdids[1]] ~= nil

    if trace then
        P(("  fdids=%d  firstFDID=%d  useBundled=%s  FDID_MAP_size=%d"):format(
            #fdids, fdids[1], tostring(useBundled),
            Config._fdidMapSize or -1))
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

    if canvasW == 0 or canvasH == 0 then
        Config.overlayActive = true
        BaseArt:SetVisible(false)
        Exploration:SetVisible(false)
        Watchdog:Start()
        return
    end

    -- Activate overlay
    Config.overlayActive = true
    BaseArt:SetVisible(false)
    Exploration:SetVisible(false)
    Watchdog:Start()

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
    Config.lastMapID     = nil
    Config.lastCanvasW   = 0
    Config.lastCanvasH   = 0
    Config.lastLayerIdx  = nil
    Config.lastSubmerged = nil
    Config.refreshPending = false
    self:Refresh(true)
end
