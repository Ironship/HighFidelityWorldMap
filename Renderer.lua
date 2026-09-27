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
--- textures (Exploration:EnumerateOverlayTextures) -- as a plain, opaque
--- fill, not cropped to that texture's own alpha shape. It used to be
--- cropped: the assumption was that *blizTex*'s own file carried a torn,
--- feathered "reveal" shape Blizzard itself renders with, and masking our
--- own tile to that shape would borrow it for free. Pulling Blizzard's own
--- client code (MapExplorationPinMixin:RefreshOverlays, in
--- Blizzard_SharedMapDataProviders/MapExplorationDataProvider.lua) proved
--- that assumption wrong: Blizzard draws these with a plain
--- SetTexture/SetPoint per tile and no masking at all --
--- mapCanvas:AddMaskableTexture(texture) only makes the tile ELIGIBLE for
--- some separate, canvas-wide mask elsewhere; it does not crop the tile to
--- its own file's alpha. *blizTex*'s file is just an ordinary Blizzard
--- terrain tile, not a reveal-shape stencil, and whatever real
--- transparency that tile's own art happens to have (sea, edges) has
--- nothing to do with the shape of explored ground -- masking our own art
--- with it was carving each chunk up by Blizzard's unrelated terrain art
--- instead of by the actual explored footprint, which is exactly the
--- fragmentation and disconnected-looking chunks this was chased down
--- for. Blizzard's own edges are just as hard as DrawFillPiece's; there is
--- no organic edge to borrow here at all, on this client or (per the
--- source above) any other.
---
--- The whole point of reading *blizTex* at all, rather than only ever
--- using C_MapExplorationInfo directly (see DrawFillPiece below): it is a
--- live Texture object Blizzard's own client already positioned and sized
--- correctly this very frame — HidePins only set its alpha to 0, it is
--- still doing everything else a normal, undisturbed exploration overlay
--- does — so its geometry is read directly off it (GetLeft/Top/Right/
--- Bottom) rather than rebuilt from raw offsets and an assumed tile size /
--- file-padding scheme this addon has no way to verify holds on every
--- client.
---
--- *blizTex*'s own screen rect only rarely lines up with this addon's own
--- tile grid, so it is usually split across more than one of this
--- addon's own tiles; each such split gets its own texture, so the pieces
--- still line up into that one true shape once drawn.
---
--- Not a complete picture on its own, though: tracing showed real,
--- currently-explored ground with no live reveal texture behind it at
--- all. See DrawFillPiece below (and the *filled* param this writes
--- into) for the pass that plugs exactly that gap.
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
---@param filled table cell (row*cols+col) -> true, shared across every
---                     call this Refresh; lets the C_MapExplorationInfo
---                     gap-filling pass (see Refresh) know which cells
---                     already got an organically-masked piece here, so
---                     it only ever plugs the ones this left uncovered.
---@param pieceTex table cell (row*cols+col) -> the Texture drawn for it,
---                      shared across every call this Refresh; lets
---                      SoftenFogEdges (see Refresh) come back afterwards
---                      and fade whichever of these end up on the outer
---                      boundary of the final, fully-assembled shape,
---                      once every pass has run and that boundary is
---                      actually known.
---@param trace boolean|nil
---@return number piecesDrawn
local function DrawExploredPiece(
    blizTex, frameLeft, frameTop,
    layerW, layerH, tilePxW, tilePxH, cols, rows, tileSource, scaleX, scaleY,
    filled, pieceTex, trace)

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

    if trace then
        P(("  fog piece: screen=[%.1f,%.1f]-[%.1f,%.1f]  chunk(layerpx)="
           .. "[%.1f,%.1f]-[%.1f,%.1f] (%.1fx%.1f)"):format(
            texLeft, texTop, texRight, texBottom,
            chunkX0, chunkY0, chunkX1, chunkY1, chunkW, chunkH))
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
                    -- No mask: see this function's own doc comment --
                    -- Blizzard's own client draws these plain and opaque,
                    -- no cropping to blizTex's own (unrelated) file.
                    piecesDrawn = piecesDrawn + 1
                    if filled then filled[row * cols + col] = true end
                    if pieceTex then pieceTex[row * cols + col] = tex end
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

--- Fade one edge of *tex* from opaque to transparent (or the reverse), on
--- whichever client build still has the API for it.
---
--- `Texture:SetGradientAlpha(orientation, r,g,b,a, r,g,b,a)` is the classic
--- signature every prior client build had; this build (see the
--- ScrollContainer.Child-replacement comment on canvas re-parenting above,
--- also WoW 12.0+) dropped it. There is a replacement, `Texture:SetGradient
--- (orientation, startColor, endColor)`, but calling it here made things
--- WORSE than doing nothing: the exact same 117 pieces DrawExploredPiece/
--- DrawFillPiece always drew came back from a live client as a handful of
--- scattered fragments instead of solid ground, meaning SetGradient's real
--- argument shape on this build (orientation as a plain "VERTICAL"/
--- "HORIZONTAL" string may not even be it any more) does something far
--- more destructive than fading an edge when called the old way, and
--- there is no way to confirm the right shape without a live client to
--- try it against. Erring towards a hard edge that reliably shows
--- everything it should, over a soft edge that might silently eat most of
--- it, is the only safe default here -- so a client missing
--- SetGradientAlpha just skips the fade entirely rather than guessing at
--- SetGradient's call shape.
---@param tex table
---@param orientation "VERTICAL"|"HORIZONTAL"
---@param fadeAtStart boolean true: transparent->opaque; false: opaque->transparent
local function FadeEdge(tex, orientation, fadeAtStart)
    if tex.SetGradientAlpha then
        if fadeAtStart then
            tex:SetGradientAlpha(orientation, 1, 1, 1, 0, 1, 1, 1, 1)
        else
            tex:SetGradientAlpha(orientation, 1, 1, 1, 1, 1, 1, 1, 0)
        end
    end
    -- No SetGradientAlpha and no safe fallback: leave tex at whatever
    -- alpha it already has (full opacity, from Pool:Acquire/SetVertexColor)
    -- rather than risk a wrong SetGradient call.
end

--- Fog of War gap-filler: C_MapExplorationInfo.GetExploredMapTextures'
--- own top-level rects (offsetX, offsetY, textureWidth, textureHeight),
--- used WHOLE rather than split into Blizzard's internal per-chunk
--- pieces. That internal chunking is exactly what an earlier version of
--- this addon tried to recompute from these same rects and got visibly
--- wrong (scattered, misplaced squares) on this client, since it needed
--- assumptions about tile size, file padding and chunk order this addon
--- has no way to verify. The plain rect itself needed none of that, and
--- was already confirmed correctly placed back when this addon only
--- ever drew rects, before any masking was attempted.
---
--- Live Blizzard reveal textures (DrawExploredPiece above) cover most of
--- the explored area with a real, organically-torn mask, borrowed
--- straight off Blizzard's own live objects — but tracing proved they
--- are not a complete raster of it: every one of them drew full,
--- zero-gap coverage of its OWN bounds, yet real gaps still showed up
--- BETWEEN them, meaning some ground C_MapExplorationInfo calls
--- genuinely explored simply has no live reveal-pin object behind it
--- any more (pruned, never created this session, or otherwise not
--- currently live). This plugs exactly those gaps: any tile cell
--- C_MapExplorationInfo says is explored, that DrawExploredPiece did not
--- already mark in *filled*, gets drawn here as a plain, unmasked full
--- tile. Left at a hard edge on purpose -- SoftenFogEdges, once both
--- passes have finished, is what decides which of these cells (and which
--- of DrawExploredPiece's) actually sit on the outer boundary of the
--- final assembled shape and fades only those; on this client Blizzard's
--- own live reveal texture turned out to carry no organic tear of its own
--- at all (tracing showed a plain 0,0-1,1 texture-coordinate crop, mask
--- file notwithstanding), so relying on that mask alone for a soft edge,
--- as this addon used to, left every piece — from both passes — hard
--- rectangular.
---@param offsetX number rect.offsetX, in Blizzard's OWN art-layer pixels
---@param offsetY number rect.offsetY
---@param rectW number rect.textureWidth
---@param rectH number rect.textureHeight
---@param blizzardLayerW number the layer size those offsets are relative
---                             to -- NOT layerW/layerH below, which a
---                             native zone (see Refresh) may have
---                             swapped out for this addon's own finer
---                             grid entirely.
---@param blizzardLayerH number
---@param layerW number this addon's own grid, in its own pixel space
---@param layerH number
---@param tilePxW number
---@param tilePxH number
---@param cols number
---@param rows number
---@param tileSource table
---@param scaleX number
---@param scaleY number
---@param filled table cell (row*cols+col) -> true already drawn; this
---                     both reads it (to skip already-covered cells) and
---                     writes it (so a second, overlapping rect in this
---                     same pass does not double-draw a cell either)
---@param pieceTex table cell (row*cols+col) -> the Texture drawn for it;
---                      see DrawExploredPiece's own @param for why.
---@param trace boolean|nil
---@return number piecesDrawn
local function DrawFillPiece(
    offsetX, offsetY, rectW, rectH, blizzardLayerW, blizzardLayerH,
    layerW, layerH, tilePxW, tilePxH, cols, rows, tileSource, scaleX, scaleY,
    filled, pieceTex, trace)

    if blizzardLayerW <= 0 or blizzardLayerH <= 0 then return 0 end

    -- Fraction-of-map first, then into whichever grid this refresh is
    -- actually using -- identical to blizzardLayerW/H, and so a no-op,
    -- on every map that is not a native zone (see hfwm/db2.py's
    -- _hires_geometry, which keeps the same normalized bounding box
    -- between Blizzard's own layer and this addon's native one).
    local chunkX0 = (offsetX            / blizzardLayerW) * layerW
    local chunkX1 = ((offsetX + rectW)  / blizzardLayerW) * layerW
    local chunkY0 = (offsetY            / blizzardLayerH) * layerH
    local chunkY1 = ((offsetY + rectH)  / blizzardLayerH) * layerH

    local chunkW = chunkX1 - chunkX0
    local chunkH = chunkY1 - chunkY0
    if chunkW <= 0 or chunkH <= 0 then return 0 end

    local colStart = math.max(0, math.floor(chunkX0 / tilePxW))
    local colEnd   = math.min(cols - 1, math.ceil(chunkX1 / tilePxW) - 1)
    local rowStart = math.max(0, math.floor(chunkY0 / tilePxH))
    local rowEnd   = math.min(rows - 1, math.ceil(chunkY1 / tilePxH) - 1)

    -- A hard-edged rectangle is exactly what "very square" meant the first
    -- time this addon tried plain rects, before any masking existed. There
    -- is no per-file organic art to borrow for a cell nothing else covers
    -- (that is the whole reason this pass exists) -- softening the outer
    -- edge is SoftenFogEdges' job now, once every pass (this one included)
    -- has run and the true outer boundary of the whole assembled shape is
    -- known; doing it per-rect here, before that, used to mean a cell on
    -- the border between two adjacent rects got faded on both sides of the
    -- seam, and a cell that just looked like a rect's own edge from here
    -- (but was actually still interior once the full shape was assembled)
    -- got faded for no reason.
    local piecesDrawn = 0
    for row = rowStart, rowEnd do
        for col = colStart, colEnd do
            local idx = row * cols + col
            if not filled[idx] then
                local src = tileSource[idx + 1]
                if src then
                    local tileX0 = col * tilePxW
                    local tileY0 = row * tilePxH
                    local tileX1 = tileX0 + math.min(tilePxW, layerW - tileX0)
                    local tileY1 = tileY0 + math.min(tilePxH, layerH - tileY0)

                    local ix0 = math.max(tileX0, chunkX0)
                    local ix1 = math.min(tileX1, chunkX1)
                    local iy0 = math.max(tileY0, chunkY0)
                    local iy1 = math.min(tileY1, chunkY1)

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

                        -- No mask: nothing softer covers this exact cell,
                        -- so it draws as a plain filled tile instead of
                        -- leaving the gap DrawExploredPiece couldn't reach.
                        -- Left at full alpha regardless of where it sits
                        -- in *this* rect -- see SoftenFogEdges for why.
                        filled[idx] = true
                        if pieceTex then pieceTex[idx] = tex end
                        piecesDrawn = piecesDrawn + 1
                    end
                end
            end
        end
    end

    if trace then
        P(("  fill rect: offset=%d,%d size=%dx%d -> chunk(layerpx)="
           .. "[%.1f,%.1f]-[%.1f,%.1f]  %d piece(s) drawn (gap-filled)"):format(
            offsetX, offsetY, rectW, rectH, chunkX0, chunkY0, chunkX1, chunkY1,
            piecesDrawn))
    end

    return piecesDrawn
end

--- Fog of War's last pass: close one-tile pinholes left after both passes
--- above.
---
--- Both DrawExploredPiece (Blizzard's live per-chunk reveal textures) and
--- DrawFillPiece (C_MapExplorationInfo's own per-parcel rects) chunk the
--- real world at whatever granularity BLIZZARD's exploration data happens
--- to use, which on this client is coarser and raggeder than this addon's
--- own tile grid -- a player who has genuinely, solidly explored a stretch
--- of ground can still come back from both passes with scattered single
--- tiles that never got a piece of their own, because neither pass's
--- source data drew a boundary through THAT tile specifically. Tracing
--- confirmed this: piece counts from both passes together fell well short
--- of every tile inside the plainly-explored footprint, and the shortfall
--- was not clustered at the edges (where an unexplored border would
--- explain it) but scattered as isolated cells throughout it -- a
--- checkerboard of one-tile holes rather than a ragged coastline.
---
--- Filling a hole only when most of ITS OWN immediate neighbours are
--- already filled is what keeps this safe: a real unexplored region
--- borders filled ground on at most one or two sides where the two passes
--- above left off, never on three or four, so this can only ever close
--- pinholes already boxed in by real, already-drawn ground -- it cannot
--- propagate outward into ground nothing above ever marked explored. A
--- single pass suffices (no iterating to a fixed point): every hole this
--- is meant to catch is already fully surrounded by the time this runs,
--- rather than becoming so only after an earlier hole in the same pass
--- gets filled.
---@param cols number
---@param rows number
---@param tileSource table
---@param filled table cell (row*cols+col) -> true; read AND extended here
---@param pieceTex table cell (row*cols+col) -> the Texture drawn for it;
---                      see DrawExploredPiece's own @param for why.
---@param layerW number
---@param layerH number
---@param tilePxW number
---@param tilePxH number
---@param scaleX number
---@param scaleY number
---@param trace boolean|nil
---@return number piecesDrawn
local function CloseFogGaps(cols, rows, tileSource, filled, pieceTex,
    layerW, layerH, tilePxW, tilePxH, scaleX, scaleY, trace)

    -- Collected first, rather than filled in place as they're found: this
    -- pass is only meant to close holes the two passes above left behind,
    -- not to chain off holes it closes itself, which -- for a hole sitting
    -- right next to another hole -- filling in loop order could otherwise
    -- let happen.
    local toFill = {}
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local idx = row * cols + col
            if not filled[idx] and tileSource[idx + 1] then
                local n = 0
                if row > 0          and filled[idx - cols] then n = n + 1 end
                if row < rows - 1   and filled[idx + cols] then n = n + 1 end
                if col > 0          and filled[idx - 1]    then n = n + 1 end
                if col < cols - 1   and filled[idx + 1]    then n = n + 1 end
                if n >= 3 then
                    toFill[#toFill + 1] = idx
                end
            end
        end
    end

    local piecesDrawn = 0
    for _, idx in ipairs(toFill) do
        local row = math.floor(idx / cols)
        local col = idx % cols
        local src = tileSource[idx + 1]

        local artTileW = math.min(tilePxW, layerW - col * tilePxW)
        local artTileH = math.min(tilePxH, layerH - row * tilePxH)

        local tex = Pool:Acquire()
        tex:SetSize(artTileW * scaleX, artTileH * scaleY)
        tex:SetPoint("TOPLEFT", Config.overlayFrame, "TOPLEFT",
            col * tilePxW * scaleX, -(row * tilePxH * scaleY))
        tex:SetTexCoord(0, artTileW / tilePxW, 0, artTileH / tilePxH)
        tex:SetTexture(src)

        filled[idx] = true
        if pieceTex then pieceTex[idx] = tex end
        piecesDrawn = piecesDrawn + 1
    end

    if trace and piecesDrawn > 0 then
        P(("  fog: closed %d one-tile pinhole(s)"):format(piecesDrawn))
    end

    return piecesDrawn
end

--- Fog of War's final pass: fade the outer boundary of the whole,
--- now-fully-assembled explored shape, rather than trusting any one piece
--- above to have already brought its own soft edge.
---
--- Both DrawExploredPiece and DrawFillPiece used to fade their own outer
--- edges as they went, on the assumption that DrawExploredPiece's mask
--- brought a real organic tear the rest of the time. Tracing on this
--- client disproved that assumption (DrawExploredPiece's own mask turned
--- out to be a plain, uncropped 0,0-1,1 rectangle -- see its call site's
--- comment) and exposed the deeper problem with fading per-piece at all:
--- each piece only knows its OWN local rect, not the shape of everything
--- else that ends up next to it, so a cell that is really deep in the
--- interior of the final assembled area -- just sitting at the edge of
--- the one rect or chunk that happened to cover it -- got faded for no
--- reason, and a cell that really is on the true outer boundary but was
--- covered by two overlapping pieces could end up faded once and then
--- redrawn solid by the other, or vice versa depending on draw order.
--- Waiting until every cell this Refresh will fill is already filled, and
--- looking at each one's actual neighbours rather than the bounds of
--- whichever single rect drew it, is the only way to get a boundary that
--- means the whole shape rather than any one piece's contribution to it.
---
--- Same safety property as CloseFogGaps: a cell's own already-drawn
--- neighbours are what decide whether and how it fades, so this can only
--- ever soften the true edge of ground something above already marked
--- explored -- it cannot dim interior cells (all four neighbours filled)
--- and cannot invent a fade along ground nothing above ever drew.
---@param cols number
---@param rows number
---@param filled table cell (row*cols+col) -> true; read only here
---@param pieceTex table cell (row*cols+col) -> the Texture drawn for it
---@param trace boolean|nil
local function SoftenFogEdges(cols, rows, filled, pieceTex, trace)
    local faded = 0
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local idx = row * cols + col
            local tex = filled[idx] and pieceTex[idx]
            if tex then
                -- Same convention as the rect-edge fade this replaces:
                -- there is no fog beyond the map's own edge to fade into,
                -- so a cell at row/col 0 or cols-1/rows-1 is never treated
                -- as a boundary on that side purely for being at the map's
                -- edge -- only an actual unfilled neighbour counts.
                local hasTop    = row > 0         and not filled[idx - cols]
                local hasBottom = row < rows - 1  and not filled[idx + cols]
                local hasLeft   = col > 0         and not filled[idx - 1]
                local hasRight  = col < cols - 1  and not filled[idx + 1]

                -- Same row-wins-column tie-break DrawFillPiece's own fade
                -- used to make, for the cells (rect/chunk corners) that
                -- would otherwise qualify on two sides at once -- a
                -- gradient only ever fades along one axis at a time.
                if hasTop then
                    FadeEdge(tex, "VERTICAL", true)
                    faded = faded + 1
                elseif hasBottom then
                    FadeEdge(tex, "VERTICAL", false)
                    faded = faded + 1
                elseif hasLeft then
                    FadeEdge(tex, "HORIZONTAL", true)
                    faded = faded + 1
                elseif hasRight then
                    FadeEdge(tex, "HORIZONTAL", false)
                    faded = faded + 1
                end
            end
        end
    end

    if trace and faded > 0 then
        P(("  fog: softened %d boundary tile(s)"):format(faded))
    end
end

--- The actual work of a refresh, wrapped and guarded by Renderer:Refresh
--- below against being re-entered while already running.
---@param force boolean|nil
local function DoRefresh(force)
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
    -- Kept alongside layerW/layerH rather than instead of them: Fog of
    -- War's gap-filling pass (DrawFillPiece) reads exploration rects from
    -- C_MapExplorationInfo.GetExploredMapTextures, which are always
    -- expressed in Blizzard's own art-layer pixel space, no matter what
    -- this refresh ends up actually drawing tiles in. That stays true
    -- even when a native zone (below) overwrites layerW/layerH with this
    -- addon's own finer grid, so the two have to be told apart.
    local blizzardLayerW = layerW
    local blizzardLayerH = layerH
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
        -- Shared between both passes below: DrawExploredPiece (live,
        -- organically-masked reveal textures) marks every cell it fills,
        -- and DrawFillPiece (the complete-but-unmasked
        -- C_MapExplorationInfo cross-check) only ever touches cells this
        -- left untouched -- see both functions' own doc comments for why
        -- neither pass alone is both complete and organically-edged.
        local filled = {}
        local pieceTex = {}

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
                    scaleX, scaleY, filled, pieceTex, trace)
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

        -- Gap fill: live reveal textures above cover most of the explored
        -- area with a real organic edge, but tracing proved they are not
        -- a complete raster of it -- every one of them filled its own
        -- bounds with zero internal gaps, yet real gaps still showed up
        -- BETWEEN them, on ground C_MapExplorationInfo still calls
        -- explored. This is the authoritative, always-complete source
        -- for "which ground is explored" (confirmed correctly placed
        -- back when this addon only ever drew plain rects from it,
        -- before any masking was attempted), used here as a WHOLE rect
        -- per entry rather than split into Blizzard's own internal
        -- per-chunk pieces -- that splitting is what went wrong the one
        -- time this addon tried to recompute it. filled already has
        -- every cell the pass above covered, so this only ever plugs
        -- what that pass could not reach.
        local explored = C_MapExplorationInfo
            and C_MapExplorationInfo.GetExploredMapTextures(mapID)
        if explored then
            local fillPieces = 0
            for _, rect in ipairs(explored) do
                fillPieces = fillPieces + DrawFillPiece(
                    rect.offsetX, rect.offsetY,
                    rect.textureWidth, rect.textureHeight,
                    blizzardLayerW, blizzardLayerH,
                    layerW, layerH, tilePxW, tilePxH, cols, rows, tileSource,
                    scaleX, scaleY, filled, pieceTex, trace)
            end
            fogPiecesDrawn = fogPiecesDrawn + fillPieces
            if trace then
                P(("  fog: gap-fill added %d piece(s) across %d rect(s)"):format(
                    fillPieces, #explored))
            end
        end

        -- Then: close whatever one-tile pinholes both passes above still
        -- left sitting inside otherwise-solid ground (see CloseFogGaps).
        fogPiecesDrawn = fogPiecesDrawn + CloseFogGaps(
            cols, rows, tileSource, filled, pieceTex, layerW, layerH,
            tilePxW, tilePxH, scaleX, scaleY, trace)

        -- Last: now that every cell this Refresh will ever fill IS filled,
        -- fade whichever of them sit on the true outer boundary of the
        -- whole assembled shape (see SoftenFogEdges).
        SoftenFogEdges(cols, rows, filled, pieceTex, trace)
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

-- Set for the duration of DoRefresh, cleared no matter how it exits (the
-- pcall below is what makes that unconditional -- a bare `return` deep
-- inside DoRefresh would otherwise skip a plain post-call reset).
local refreshing = false

--- Main overlay refresh.
---
--- Guards DoRefresh against being re-entered while it is already running.
--- That is not a theoretical concern here: DoRefresh's own Fog of War
--- section calls Exploration:EnumerateOverlayTextures, which calls
--- WorldMapFrame:RefreshAllDataProviders, which on this client can
--- synchronously fire MAP_EXPLORATION_UPDATED -- and Core.lua's handler
--- for that event calls this same Refresh again, before the outer call
--- has returned. Letting that inner call proceed used to run
--- Pool:ReleaseAll()/MaskPool:ReleaseAll() out from under the outer call's
--- own in-progress drawing, discarding some of its pieces and leaving
--- others orphaned -- tiles silently missing at what looked like regular
--- intervals despite every individual piece's own math being correct,
--- because the piece *was* correctly drawn, by whichever of the two
--- overlapping calls drew it last, while the pool bookkeeping the other
--- call was still relying on had already been swept out from under it.
--- The inner call is redundant anyway: whatever changed that it wanted to
--- redraw for, the outer call is about to finish drawing the current
--- state fresh regardless.
---@param force boolean|nil
function Renderer:Refresh(force)
    if refreshing then
        -- Dropped, not just ignored: the outer call already in progress is
        -- about to draw the current state fresh regardless (see above), but
        -- schedule a debounced follow-up anyway in case whatever triggered
        -- this specific call raced ahead of that -- cheap insurance against
        -- ever again silently dropping a real update instead of only ever
        -- dropping the redundant ones this guard exists for.
        self:ScheduleRefresh()
        return
    end
    refreshing = true
    local ok, err = pcall(DoRefresh, force)
    refreshing = false
    if not ok then
        error(err, 0)
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
