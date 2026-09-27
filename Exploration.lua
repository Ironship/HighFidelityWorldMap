-------------------------------------------------------------------------------
-- HFWM-Forever Exploration
-- Hide / show exploration overlay ("fog of war cleared" textures), and (for
-- Fog of War — see EnumerateOverlayTextures) hand their live geometry back
-- to Renderer.lua instead of just hiding them.
-- Searches pin pools and data providers directly on WorldMapFrame.
--
-- Mouse state is saved and restored rather than forced.  Exploration pins
-- are pure art stretched over the whole canvas and Blizzard leaves them
-- mouse-disabled; calling EnableMouse(true) on them turns the overlay into
-- an invisible sheet that eats every click on the map, so zone clicks,
-- drag-panning and pin tooltips all stop working.  Pins are pooled, so a
-- forced-on flag also survives release and comes back on the next acquire.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Exploration = ns.Exploration
local Config      = ns.Config

local hookedDPs = {}

--- Run *fn* over every exploration pin, optionally including pooled-but-
--- inactive ones (their state carries over when they are re-acquired).
local function ForEachPin(fn, includeInactive)
    if not WorldMapFrame.pinPools then return end
    for templateName, pinPool in next, WorldMapFrame.pinPools do
        if templateName:lower():find("exploration") then
            for pin in pinPool:EnumerateActive() do fn(pin) end
            if includeInactive and pinPool.EnumerateInactive then
                for pin in pinPool:EnumerateInactive() do fn(pin) end
            end
        end
    end
end

--- Disable mouse input, remembering whether it was on to begin with.
local function SuppressMouse(pin)
    if pin._hfwmMouseWasEnabled == nil then
        pin._hfwmMouseWasEnabled = pin:IsMouseEnabled() and true or false
    end
    pin:EnableMouse(false)
end

--- Put mouse input back exactly how Blizzard had it.
local function RestoreMouse(pin)
    if pin._hfwmMouseWasEnabled ~= nil then
        pin:EnableMouse(pin._hfwmMouseWasEnabled)
        pin._hfwmMouseWasEnabled = nil
    end
end

local function IsExplorationDP(dp)
    if dp.overlayTexturePool then return true end
    local tmpl = dp.pinTemplate
    return type(tmpl) == "string" and tmpl:find("Exploration") and true or false
end

local function HookDPs()
    if not WorldMapFrame.dataProviders then return end
    for dp in next, WorldMapFrame.dataProviders do
        if not hookedDPs[dp] and dp.RefreshAllData and IsExplorationDP(dp) then
            hookedDPs[dp] = true
            hooksecurefunc(dp, "RefreshAllData", function()
                -- Always re-hidden, Fog of War included: Renderer.lua's own
                -- tiles are what Fog of War shows instead of these (see
                -- DrawExploredPiece), reusing the geometry and art of the
                -- very textures this hides -- alpha 0 on the original
                -- object has no bearing on a *different* MaskTexture later
                -- pointed at the same file, so there is nothing here for
                -- Fog of War to make conditional.
                if Config.db and Config.db.enabled and Config.overlayActive then
                    Exploration:HidePins()
                end
            end)
        end
    end
end

function Exploration:HidePins()
    HookDPs()

    ForEachPin(function(pin)
        pin:SetAlpha(0)
        SuppressMouse(pin)
        for _, region in ipairs({pin:GetRegions()}) do
            region:SetAlpha(0)
        end
    end)

    if WorldMapFrame.dataProviders then
        for dp in next, WorldMapFrame.dataProviders do
            if dp.overlayTexturePool then
                for tex in dp.overlayTexturePool:EnumerateActive() do
                    tex:SetAlpha(0)
                end
            end
        end
    end
end

---@param visible boolean
function Exploration:SetVisible(visible)
    HookDPs()

    if visible then
        -- Includes inactive pins: RemoveAllData() released them while the
        -- overlay was up, and the refresh below hands the same frames back.
        ForEachPin(function(pin)
            pin:SetAlpha(1)
            RestoreMouse(pin)
            pin:Show()
            for _, region in ipairs({pin:GetRegions()}) do
                region:SetAlpha(1)
                region:Show()
            end
        end, true)
        if WorldMapFrame.dataProviders then
            for dp in next, WorldMapFrame.dataProviders do
                if dp.overlayTexturePool then
                    for tex in dp.overlayTexturePool:EnumerateActive() do
                        tex:SetAlpha(1)
                        tex:Show()
                    end
                end
            end
        end
        if WorldMapFrame.RefreshAllDataProviders then
            WorldMapFrame:RefreshAllDataProviders()
        elseif WorldMapFrame.dataProviders then
            for dp in next, WorldMapFrame.dataProviders do
                if IsExplorationDP(dp) and dp.RefreshAllData then
                    dp:RefreshAllData()
                end
            end
        end

        -- Second pass, in case a pool without EnumerateInactive handed back
        -- a pin we could not reach above.  No-op once flags are cleared.
        ForEachPin(RestoreMouse, true)
    else
        if WorldMapFrame.dataProviders then
            for dp in next, WorldMapFrame.dataProviders do
                if IsExplorationDP(dp) and dp.RemoveAllData then
                    dp:RemoveAllData()
                end
            end
        end
        self:HidePins()
    end
end

--- Every currently-active "explored" reveal texture Blizzard's own
--- exploration data provider is drawing right now — hidden (see HidePins,
--- called from the RefreshAllData hook above, and by this too) but very
--- much still real Texture objects with their own correct position, size,
--- texture and texture coordinates, kept and refreshed rather than
--- released the way SetVisible(false) releases them.
---
--- This is Fog of War's whole way of finding what to reveal (see
--- Renderer's DrawExploredPiece): read the real geometry Blizzard's own
--- client already computed correctly, rather than recomputing it from
--- C_MapExplorationInfo ourselves, which turned out to need assumptions
--- (tile size, file-padding, coordinate space) this addon has no way to
--- verify hold on every client. RefreshAllDataProviders (same call
--- SetVisible(true) already makes) first, so this is never reading data
--- that predates whatever most recently changed it.
---
--- Two different client implementations are covered, since this addon
--- has no way to know in advance which one it is talking to:
---   - Retail-style: the data provider itself pools plain Texture objects
---     directly (dp.overlayTexturePool) -- each pooled object already IS
---     the reveal texture.
---   - Pin-style (the one this addon actually ships on, confirmed by
---     tracing): there is exactly ONE active "MapExplorationPinTemplate"
---     pin per map, sized to the *entire canvas* -- not one pin per
---     explored area, which is what this addon's very first bug report
---     (real chunk-shaped squares of Blizzard's own art appearing over
---     explored ground) actually was: one single pin frame, hidden as a
---     whole by HidePins/ForEachPin, that Blizzard has papered with one
---     child Texture region PER real explored area, each individually
---     positioned/sized to its own true rect rather than to the pin's own
---     (whole-canvas) bounds. Taking only the first such region (an
---     earlier version of this function) threw away every explored area
---     but one; this collects all of them.
---@return table[] textures
function Exploration:EnumerateOverlayTextures()
    HookDPs()

    if WorldMapFrame.RefreshAllDataProviders then
        WorldMapFrame:RefreshAllDataProviders()
    elseif WorldMapFrame.dataProviders then
        for dp in next, WorldMapFrame.dataProviders do
            if IsExplorationDP(dp) and dp.RefreshAllData then
                dp:RefreshAllData()
            end
        end
    end

    local out = {}
    local dpPoolCount, dpPoolTotal = 0, 0
    if WorldMapFrame.dataProviders then
        for dp in next, WorldMapFrame.dataProviders do
            if dp.overlayTexturePool then
                dpPoolCount = dpPoolCount + 1
                for tex in dp.overlayTexturePool:EnumerateActive() do
                    out[#out + 1] = tex
                    dpPoolTotal = dpPoolTotal + 1
                end
            end
        end
    end

    -- Per-template breakdown, trace-only: "exploration" as a substring
    -- can just as easily match a thin animated boundary-line pin template
    -- as the actual fill-chunk template, and only one of those is real
    -- reveal art -- if more than one template shows up here, whichever
    -- one has pin sizes far smaller than a map chunk is almost certainly
    -- the wrong one to be feeding into DrawExploredPiece as if it were a
    -- fill piece.
    if Config.tracing and WorldMapFrame.pinPools then
        for templateName, pinPool in next, WorldMapFrame.pinPools do
            if templateName:lower():find("exploration") then
                local n, wSum, hSum, wMin, hMin, wMax, hMax = 0, 0, 0, nil, nil, nil, nil
                for pin in pinPool:EnumerateActive() do
                    n = n + 1
                    local w, h = pin:GetSize()
                    w, h = w or 0, h or 0
                    wSum, hSum = wSum + w, hSum + h
                    wMin = wMin and math.min(wMin, w) or w
                    hMin = hMin and math.min(hMin, h) or h
                    wMax = wMax and math.max(wMax, w) or w
                    hMax = hMax and math.max(hMax, h) or h
                end
                ns.P(("  template %q: active=%d  size avg=%.1fx%.1f  "
                    .. "min=%.1fx%.1f  max=%.1fx%.1f"):format(
                    templateName, n,
                    n > 0 and wSum / n or 0, n > 0 and hSum / n or 0,
                    wMin or 0, hMin or 0, wMax or 0, hMax or 0))
            end
        end
    end

    -- One pin per map, not one per explored area -- confirmed by tracing
    -- (a single active MapExplorationPinTemplate sized to the entire
    -- canvas), matching this file's header comment ("pure art stretched
    -- over the whole canvas"). The real per-area reveal pieces are its
    -- CHILD regions, each individually positioned/sized to its own true
    -- explored rect rather than to the whole pin -- collecting only the
    -- first Texture-type region (the previous version of this loop) threw
    -- away every piece but one, which is exactly why only a single small
    -- sliver was showing up regardless of how much ground was actually
    -- explored. pin.Texture, if the pin happens to expose one, is already
    -- one of these regions and would otherwise be double-counted, so
    -- there is no separate special case for it here.
    local pinCount, pinTexCount = 0, 0
    ForEachPin(function(pin)
        pinCount = pinCount + 1
        for _, region in ipairs({ pin:GetRegions() }) do
            if region.GetTexture and region.GetObjectType
                and region:GetObjectType() == "Texture" then
                out[#out + 1] = region
                pinTexCount = pinTexCount + 1
                if Config.tracing then
                    local texLeft, texTop = region:GetLeft(), region:GetTop()
                    local texRight, texBottom = region:GetRight(), region:GetBottom()
                    local texFile = region:GetTexture()
                    ns.P(("    pin texture: screen=[%s,%s]-[%s,%s]  file=%s"):format(
                        tostring(texLeft), tostring(texTop),
                        tostring(texRight), tostring(texBottom), tostring(texFile)))
                end
            end
        end
    end)

    if Config.tracing then
        ns.P(("  Exploration:EnumerateOverlayTextures: overlayTexturePool "
            .. "dp(s)=%d texture(s)=%d  pins seen=%d pin texture(s)=%d  "
            .. "total=%d"):format(
            dpPoolCount, dpPoolTotal, pinCount, pinTexCount, #out))
    end

    return out
end
