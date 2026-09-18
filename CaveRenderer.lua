-------------------------------------------------------------------------------
-- HFWM-Forever CaveRenderer
-- Renders cave / dungeon tiles into a separate semi-transparent overlay frame
-- (Config.caveOverlayFrame) that sits on top of the main world map. Includes:
--   * Inline texture pool (separate from main HFWM Pool)
--   * Subtle dark backdrop tint for visual differentiation
--   * Live player position pin with facing-direction rotation
--   * Floor selector strip when a cave has multiple floors
-------------------------------------------------------------------------------
local addonName, ns = ...
local CaveRenderer = ns.CaveRenderer
local Config       = ns.Config
local P            = ns.P

-------------------------------------------------------------------------------
-- Inline texture pool (owned by caveOverlayFrame)
-------------------------------------------------------------------------------
local cavePool         = {}
local activeCaveTiles  = {}

local function PoolAcquire()
    local tex = tremove(cavePool)
    if not tex then
        tex = Config.caveOverlayFrame:CreateTexture(nil, "ARTWORK", nil, 3)
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
-- Backdrop tint, player pin, and floor selector — created lazily
-------------------------------------------------------------------------------
local backdrop          -- BACKGROUND texture covering full frame
local playerPin         -- OVERLAY texture (rotated arrow)
local floorButtonStrip  -- Frame containing per-floor buttons
local floorButtons      -- array of Button objects, recycled

local PIN_TEXTURE  = "Interface\\Minimap\\MinimapArrow"
local PIN_SIZE     = 32
local PIN_LEVEL    = "OVERLAY"
local PIN_SUBLEVEL = 7

local function EnsureBackdrop()
    if backdrop then return end
    backdrop = Config.caveOverlayFrame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints(Config.caveOverlayFrame)
    backdrop:SetColorTexture(0.04, 0.04, 0.08, 0.55)
end

local function EnsurePlayerPin()
    if playerPin then return end
    playerPin = Config.caveOverlayFrame:CreateTexture(
        nil, PIN_LEVEL, nil, PIN_SUBLEVEL)
    playerPin:SetTexture(PIN_TEXTURE)
    playerPin:SetSize(PIN_SIZE, PIN_SIZE)
    playerPin:Hide()
end

local function EnsureFloorStrip()
    if floorButtonStrip then return end
    floorButtonStrip = CreateFrame("Frame", nil, Config.caveOverlayFrame)
    floorButtonStrip:SetHeight(28)
    floorButtonStrip:SetPoint("BOTTOM", Config.caveOverlayFrame, "BOTTOM", 0, 8)
    floorButtonStrip:Hide()
    floorButtons = {}
end

local function GetOrCreateFloorButton(idx)
    local btn = floorButtons[idx]
    if btn then return btn end
    btn = CreateFrame("Button", nil, floorButtonStrip,
        "UIPanelButtonTemplate")
    btn:SetSize(80, 22)
    floorButtons[idx] = btn
    return btn
end

local function LayoutFloorStrip(floors, currentMapID)
    if not floors or #floors <= 1 then
        if floorButtonStrip then floorButtonStrip:Hide() end
        return
    end

    EnsureFloorStrip()

    local spacing = 4
    local btnW = 80
    local total = #floors * btnW + (#floors - 1) * spacing
    floorButtonStrip:SetWidth(total)

    for i, floor in ipairs(floors) do
        local btn = GetOrCreateFloorButton(i)
        btn:ClearAllPoints()
        btn:SetPoint("LEFT", floorButtonStrip, "LEFT",
            (i - 1) * (btnW + spacing), 0)
        btn:SetText(floor.name or ("Floor " .. i))
        btn:SetScript("OnClick", function()
            Config.caveCurrentFloorMapID = floor.mapID
            CaveRenderer:ShowCave(floor.mapID)
        end)
        if floor.mapID == currentMapID then
            btn:SetNormalFontObject("GameFontHighlight")
            btn:LockHighlight()
        else
            btn:SetNormalFontObject("GameFontNormal")
            btn:UnlockHighlight()
        end
        btn:Show()
    end

    -- Hide any leftover buttons from previous renders with more floors
    for i = #floors + 1, #floorButtons do
        floorButtons[i]:Hide()
    end
    floorButtonStrip:Show()
end

-------------------------------------------------------------------------------
-- Pin update (called by OnUpdate while cave is active)
-------------------------------------------------------------------------------
local function UpdatePlayerPin(floorMapID)
    if not playerPin then return end
    local pos = C_Map.GetPlayerMapPosition(floorMapID, "player")
    if not pos then
        playerPin:Hide()
        return
    end
    local x, y = pos:GetXY()
    if not x or not y or x == 0 and y == 0 then
        -- (0,0) usually means "no fix" (player not in this map's space)
        playerPin:Hide()
        return
    end
    local frame = Config.caveOverlayFrame
    local w, h = frame:GetSize()
    if w <= 0 or h <= 0 then
        playerPin:Hide()
        return
    end

    playerPin:ClearAllPoints()
    playerPin:SetPoint("CENTER", frame, "TOPLEFT", x * w, -(y * h))
    -- WoW player facing: 0 = north, increases counter-clockwise (radians)
    -- Texture rotates clockwise when positive, so negate
    playerPin:SetRotation(-GetPlayerFacing())
    playerPin:Show()
end

local pinUpdateAccum = 0
local PIN_UPDATE_INTERVAL = 0.05  -- 20fps is plenty for a map pin

local function OnPinUpdate(self, elapsed)
    if not Config.caveOverlayActive then return end
    pinUpdateAccum = pinUpdateAccum + elapsed
    if pinUpdateAccum < PIN_UPDATE_INTERVAL then return end
    pinUpdateAccum = 0
    UpdatePlayerPin(Config.caveCurrentFloorMapID)
end

-------------------------------------------------------------------------------
-- Tile rendering (mirrors Renderer.lua layout logic)
-------------------------------------------------------------------------------
function CaveRenderer:RenderTiles(floorMapID)
    local frame = Config.caveOverlayFrame
    if not frame then return end

    local canvasW, canvasH = frame:GetSize()
    if canvasW <= 0 or canvasH <= 0 then return end

    local layers = C_Map.GetMapArtLayers(floorMapID)
    if not layers or #layers == 0 then
        if Config.tracing then
            P("CaveRenderer: no art layers for mapID " .. tostring(floorMapID))
        end
        return
    end

    local layer   = layers[1]
    local layerW  = layer.layerWidth
    local layerH  = layer.layerHeight
    local tilePxW = layer.tileWidth  or 256
    local tilePxH = layer.tileHeight or 256
    local cols    = math.ceil(layerW / tilePxW)
    local rows    = math.ceil(layerH / tilePxH)

    local fdids = C_Map.GetMapArtLayerTextures(floorMapID, 1)
    if not fdids or #fdids == 0 then
        if Config.tracing then
            P("CaveRenderer: no FDIDs for mapID " .. tostring(floorMapID))
        end
        return
    end

    local FDID_MAP  = Config.FDID_MAP
    local FDID_BASE = Config.FDID_BASE

    local scaleX = canvasW / layerW
    local scaleY = canvasH / layerH
    local tileIdx = 1

    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local fdid = fdids[tileIdx]
            if not fdid then break end

            local rel = FDID_MAP[fdid]
            local src = rel and (FDID_BASE .. rel) or fdid

            local artTileW = math.min(tilePxW, layerW - col * tilePxW)
            local artTileH = math.min(tilePxH, layerH - row * tilePxH)

            local cellW = artTileW * scaleX
            local cellH = artTileH * scaleY
            local cellX = col * tilePxW * scaleX
            local cellY = row * tilePxH * scaleY

            local texRight  = artTileW / tilePxW
            local texBottom = artTileH / tilePxH

            local tex = PoolAcquire()
            tex:SetSize(cellW, cellH)
            tex:SetPoint("TOPLEFT", frame, "TOPLEFT", cellX, -cellY)
            tex:SetTexCoord(0, texRight, 0, texBottom)
            tex:SetTexture(src)
            tileIdx = tileIdx + 1
        end
    end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function CaveRenderer:ShowCave(floorMapID)
    local frame = Config.caveOverlayFrame
    if not frame then return end

    -- Re-parent guard (canvas may swap on UI reload / some addons)
    local canvas = WorldMapFrame.ScrollContainer
        and WorldMapFrame.ScrollContainer.Child
    if canvas and frame:GetParent() ~= canvas then
        frame:SetParent(canvas)
        frame:ClearAllPoints()
        frame:SetAllPoints(canvas)
        frame:SetFrameLevel(canvas:GetFrameLevel() + 600)
    end

    PoolReleaseAll()
    EnsureBackdrop()
    EnsurePlayerPin()

    frame:SetAlpha(Config.caveAlpha or 0.92)
    frame:Show()

    self:RenderTiles(floorMapID)
    LayoutFloorStrip(Config.caveAllFloors, floorMapID)
    UpdatePlayerPin(floorMapID)

    Config.caveOverlayActive = true
    frame:SetScript("OnUpdate", OnPinUpdate)

    if Config.tracing then
        P(("CaveRenderer:ShowCave mapID=%s tiles=%d floors=%d"):format(
            tostring(floorMapID), #activeCaveTiles,
            Config.caveAllFloors and #Config.caveAllFloors or 0))
    end
end

function CaveRenderer:HideCave()
    local frame = Config.caveOverlayFrame
    if not frame then return end
    PoolReleaseAll()
    if playerPin then playerPin:Hide() end
    if floorButtonStrip then floorButtonStrip:Hide() end
    frame:SetScript("OnUpdate", nil)
    frame:Hide()
    Config.caveOverlayActive = false
    Config.caveCurrentFloorMapID = nil
    Config.caveAllFloors = nil
end

function CaveRenderer:ActiveTileCount()
    return #activeCaveTiles
end
