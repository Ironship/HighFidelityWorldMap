-------------------------------------------------------------------------------
-- HFWM-Forever BaseArt
-- Hide / show the default detail-layer map tiles (the base art).
--
-- This is Blizzard's hand-painted map: on a continent it is the parchment,
-- the "THE GREAT SEA" and "EASTERN KINGDOMS" labels, the compass rose and the
-- sea monsters, all baked into the client's own art tiles. It draws behind
-- the addon's tiles, so on every background but Hybrid it has to go.
--
-- Two bugs used to hide each other here. The layers were reached only
-- through `WorldMapFrame.detailLayerPool`, with an early `return` if that
-- field was missing, so on a client that keeps its detail layers anywhere
-- else, SetVisible was a silent no-op. Nobody noticed, since the default
-- Ocean Blue background paints an opaque colour on the overlay frame *in
-- front* of the detail layer, covering Blizzard's art either way. Only
-- Transparent shows the bug, and it shows it as "Transparent looks exactly
-- like Hybrid".
--
-- Fix: layers are now found by duck type, any frame under the canvas with a
-- RefreshDetailTiles method, whatever the pool is called or whether there is
-- one. The pool, if it exists, is just one source among several, not the
-- only one.
--
-- Concealment is Hide(), not alpha 0 (same reasoning as MapFrameBg's): the
-- client re-asserts alpha along with shown state when it re-tiles, so an
-- alpha-0 layer comes back opaque. Hide() is the stronger claim, so
-- everything that undoes it (Show, SetShown, RefreshDetailTiles) is hooked
-- below. Restore re-Shows only what this module actually hid, so a layer the
-- client had already released and hidden is not resurrected.
-------------------------------------------------------------------------------
local addonName, ns = ...
local BaseArt = ns.BaseArt
local Config  = ns.Config

-- Last visibility asked for. The client re-Shows and re-tiles its detail
-- layers behind our back (on pan, zoom and map change), so the hooks below
-- re-assert this choice afterward. Keyed off this rather than
-- Config.overlayActive, since Hybrid wants the overlay active *and*
-- Blizzard's art visible.
BaseArt.visible = true

-- Everything this module has hidden and not yet put back. Same shape and same
-- reasoning as MapFrameBg's: a set for the membership test, an array for
-- ordered restore, kept for the session because the client swaps layers and
-- tiles in and out and something hidden on one map may not be found on the
-- next.
BaseArt.hidden = {}
BaseArt.order  = {}

--- Frames that could be parenting detail layers.
local function layerHosts()
    local wmf = WorldMapFrame
    if not wmf then return {} end

    local out = {}
    local function add(frame)
        if type(frame) == "table" then out[#out + 1] = frame end
    end

    local scroll = wmf.ScrollContainer
    add(scroll)
    add(scroll and scroll.Child)
    -- The canvas mixin's own accessors, where this client has them. Called
    -- defensively: they are the authoritative answer when present, and
    -- absent rather than wrong when not.
    if wmf.GetCanvasContainer then
        local ok, frame = pcall(wmf.GetCanvasContainer, wmf)
        if ok then add(frame) end
    end
    if wmf.GetCanvas then
        local ok, frame = pcall(wmf.GetCanvas, wmf)
        if ok then add(frame) end
    end

    return out
end

--- Every detail layer, from the pool if there is one and by duck type either
--- way. Inactive pooled layers are included: their state carries over when
--- the pool hands them back, and `conceal` skips anything already hidden, so
--- a released layer is not disturbed.
---@return table[] layers, in discovery order
local function collectLayers()
    local out, seen = {}, {}

    local function take(frame)
        -- RefreshDetailTiles is what makes a frame a detail layer, and Hide
        -- is what we need from it.
        if type(frame) == "table" and frame.Hide and frame.RefreshDetailTiles
            and not seen[frame]
        then
            seen[frame] = true
            out[#out + 1] = frame
        end
    end

    local pool = WorldMapFrame and WorldMapFrame.detailLayerPool
    if pool then
        if pool.EnumerateActive then
            for layer in pool:EnumerateActive() do take(layer) end
        end
        if pool.EnumerateInactive then
            for layer in pool:EnumerateInactive() do take(layer) end
        end
    end

    for _, host in ipairs(layerHosts()) do
        if host.GetChildren then
            for _, child in ipairs({ host:GetChildren() }) do
                take(child)
            end
        end
    end

    return out
end

--- Every texture a detail layer draws its art with. The three sources
--- overlap (a tile in `textures` is usually also a region of the frame), so
--- they are deduplicated, or the diagnostic below would report every tile
--- twice.
---@param layer table
---@return table[]
local function layerTextures(layer)
    local out, seen = {}, {}

    local function take(tex)
        if type(tex) == "table" and tex.Hide and not seen[tex] then
            seen[tex] = true
            out[#out + 1] = tex
        end
    end

    if layer.tilePool and layer.tilePool.EnumerateActive then
        for tile in layer.tilePool:EnumerateActive() do take(tile) end
    end
    if type(layer.textures) == "table" then
        for _, tex in ipairs(layer.textures) do take(tex) end
    end
    -- Whatever the mixin on this client calls its tile store, the tiles are
    -- still regions of the layer frame.
    if layer.GetRegions then
        for _, region in ipairs({ layer:GetRegions() }) do
            if type(region) == "table" and region.GetObjectType
                and region:GetObjectType() == "Texture"
            then
                take(region)
            end
        end
    end

    return out
end

--- Hide something, remembering that we were the one who did it. Already-hidden
--- widgets are left unrecorded so that restore does not Show something the
--- client wanted hidden anyway.
local function conceal(obj)
    if obj.IsShown and not obj:IsShown() then return end
    if not BaseArt.hidden[obj] then
        BaseArt.hidden[obj] = true
        BaseArt.order[#BaseArt.order + 1] = obj
    end
    obj:Hide()
end

--- Undo one conceal, and only that.
local function reveal(obj)
    if BaseArt.hidden[obj] then
        BaseArt.hidden[obj] = nil
        if obj.SetAlpha then obj:SetAlpha(1) end
        obj:Show()
    end
end

--- Hide a layer and everything it draws with.
local function concealLayer(layer)
    conceal(layer)
    for _, tex in ipairs(layerTextures(layer)) do
        conceal(tex)
    end
end

--- Re-assert the choice when the client hands the art back. Show and SetShown
--- are separate entry points; RefreshDetailTiles is the one that re-tiles and
--- re-Shows the individual tiles underneath.
local function hook(layer)
    if layer._hfwmHooked then return end
    layer._hfwmHooked = true

    local function reassert()
        if Config.overlayActive and not BaseArt.visible then
            concealLayer(layer)
        end
    end

    if layer.Show then hooksecurefunc(layer, "Show", reassert) end
    if layer.SetShown then
        hooksecurefunc(layer, "SetShown", function(_, shown)
            if shown then reassert() end
        end)
    end
    if layer.RefreshDetailTiles then
        hooksecurefunc(layer, "RefreshDetailTiles", reassert)
    end
end

--- Set visibility on all detail-layer tiles and textures.
---@param visible boolean
function BaseArt:SetVisible(visible)
    self.visible = visible and true or false

    if self.visible then
        -- Restore covers everything ever hidden, not just what the search
        -- finds this time, so switching to Hybrid can never leave a layer
        -- permanently invisible.
        for _, obj in ipairs(self.order) do
            reveal(obj)
        end
        wipe(self.order)
        return
    end

    for _, layer in ipairs(collectLayers()) do
        hook(layer)
        concealLayer(layer)
    end
end

--- Human-readable account of what SetVisible would act on right now. Purely
--- for `/hfwm baseart`: if Blizzard's parchment is still showing, this is
--- what the search did and did not find.
---@return string[]
function BaseArt:Describe()
    local out = {}
    for _, layer in ipairs(collectLayers()) do
        local name = layer.GetDebugName and layer:GetDebugName()
        if not name or name == "" then name = "<anonymous layer>" end
        out[#out + 1] = ("%s  shown=%s alpha=%.2f  %d texture(s)"):format(
            name,
            tostring(layer.IsShown and layer:IsShown()),
            layer.GetAlpha and layer:GetAlpha() or -1,
            #layerTextures(layer))
    end
    return out
end
