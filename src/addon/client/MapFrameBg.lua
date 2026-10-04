-------------------------------------------------------------------------------
-- HFWM-Forever MapFrameBg
-- Hide/show the world map frame's own backing: the layer behind the map.
--
-- BaseArt deals with Blizzard's map art (the zone detail layer). This deals
-- with what's behind it: the map frame's own panel backing, and (when
-- maximised) the blackout frame covering the 3D world. Leave those in place
-- and "Transparent" isn't transparent: the erased sea becomes a hole onto a
-- flat panel, barely different from Hybrid. Hide them and the sea is a hole
-- straight through the UI onto the world.
--
-- Only Transparent asks for this (Config's `seeThrough` field); Ocean Blue,
-- Hybrid and Raw all leave the backing as the client set it.
--
-- Targets are found two ways, not by frame name (names differ between
-- windowed/maximised and between client builds, and a missing name would
-- fail silently). First, every BACKGROUND-layer texture on the handful of
-- frames making up the map's own panel (BORDER/OVERLAY art, like edges and
-- title, is left alone). Second, a sweep of the rest of the chrome tree for
-- any BACKGROUND texture covering most of the map frame, size-gated so it
-- doesn't also grab small backgrounds behind buttons and dropdowns.
-- `/hfwm framebg` lists what the search currently finds.
--
-- Concealment is Hide(), not alpha 0. Alpha was tried first, on the theory
-- the client would leave alpha alone while fighting over shown state; that
-- turned out false, since the panel templates re-assert alpha along with
-- shown state when the map opens or maximises, so an alpha-0 backing came
-- back opaque. Hide() is hooked against being undone: both Show and
-- SetShown, since SetShown is a separate entry point that skips the Show
-- hook.
--
-- Restore only re-Shows what this module actually hid, tracked in `hidden`.
-- Recording the client's shown state up front instead would get
-- BlackoutFrame wrong: it's hidden while windowed, so a state captured then
-- and replayed later would keep the world visible through a maximised map.
-------------------------------------------------------------------------------
local addonName, ns = ...
local MapFrameBg = ns.MapFrameBg
local Config     = ns.Config

-- Last visibility asked for. The hooks need to know what to re-assert, and
-- Renderer only calls in on a refresh.
MapFrameBg.visible = true

-- Everything this module has hidden and not yet put back: a set for the
-- membership test, an array for ordered restore. Kept for the lifetime of
-- the session rather than rebuilt, since maximising swaps regions in and
-- out; a region hidden while windowed may not be found by the next search,
-- and must still be restored.
MapFrameBg.hidden = {}
MapFrameBg.order  = {}

--- Is this widget ours, or inside something of ours?
local function isOurs(obj)
    local frames = { Config.overlayFrame, Config.caveOverlayFrame }
    for _, mine in ipairs(frames) do
        if mine then
            if obj == mine then return true end
            local node = obj.GetParent and obj:GetParent()
            local depth = 0
            while node and depth < 12 do
                if node == mine then return true end
                node = node.GetParent and node:GetParent()
                depth = depth + 1
            end
        end
    end
    return false
end

--- Frames whose BACKGROUND layer is map-frame backing rather than content.
--- Appended one at a time rather than written as a literal: most of these are
--- optional on some client build or other, and a nil in the middle of a table
--- literal would end the ipairs walk early and silently drop the rest.
local function backingHosts()
    local wmf = WorldMapFrame
    if not wmf then return {} end

    local out = {}
    local function add(frame)
        if type(frame) == "table" then out[#out + 1] = frame end
    end

    add(wmf)
    add(wmf.NineSlice)
    add(wmf.Inset)
    add(wmf.Inset and wmf.Inset.NineSlice)
    local border = wmf.BorderFrame
    add(border)
    add(border and border.NineSlice)
    add(border and border.Inset)
    add(border and border.Inset and border.Inset.NineSlice)
    local scroll = wmf.ScrollContainer
    add(scroll)
    add(scroll and scroll.Child)

    return out
end

-- How much of the map frame a texture has to cover, in both dimensions, to be
-- treated as backing. Generous enough for a panel inset a good way inside the
-- border, tight enough that no button, tab or side panel can qualify: the ones
-- that are tall are narrow and the ones that are wide are short.
local FULL_SIZE_FRACTION = 0.7

--- Is this texture big enough to be map backing rather than button trim?
--- Anything covering most of the map frame is backing whoever owns it;
--- anything smaller is chrome and is left alone.
local function isFullSize(region)
    local wmf = WorldMapFrame
    if not wmf or not region.GetWidth then return false end
    local fw, fh = wmf:GetWidth(), wmf:GetHeight()
    if not fw or not fh or fw <= 0 or fh <= 0 then return false end
    local w, h = region:GetWidth(), region:GetHeight()
    if not w or not h then return false end
    return w >= fw * FULL_SIZE_FRACTION and h >= fh * FULL_SIZE_FRACTION
end

local function isBackgroundTexture(region)
    return type(region) == "table"
        and region.GetObjectType
        and region:GetObjectType() == "Texture"
        and region.GetDrawLayer
        and region:GetDrawLayer() == "BACKGROUND"
end

--- Everything currently behind the map that would keep the world hidden.
---@return table[] widgets, in discovery order
local function collect()
    local out, seen = {}, {}

    local function take(obj)
        -- Hide is the method that matters on these, so it doubles as the test
        -- for "is this actually a widget".
        if type(obj) == "table" and obj.Hide and not seen[obj]
            and not isOurs(obj)
        then
            seen[obj] = true
            out[#out + 1] = obj
        end
    end

    -- Pass one: the panel frames whose backing we already know about.
    for _, host in ipairs(backingHosts()) do
        if type(host) == "table" then
            if host.GetRegions then
                for _, region in ipairs({ host:GetRegions() }) do
                    if isBackgroundTexture(region) then take(region) end
                end
            end
            -- Named backing that is not guaranteed to sit on BACKGROUND: the
            -- `Bg` the panel template mixins attach, and a NineSlice centre.
            take(host.Bg)
            take(host.Center)
        end
    end

    -- Pass two: anywhere else in the chrome, anything map-sized. Stops at
    -- the canvas, since everything under that is content (detail layers,
    -- pins, our own overlay) and BaseArt owns the detail layers.
    local scroll = WorldMapFrame and WorldMapFrame.ScrollContainer
    local canvas = scroll and scroll.Child
    local visited = {}

    local function sweep(frame, depth)
        if depth > 6 or type(frame) ~= "table" or visited[frame] then return end
        visited[frame] = true

        if frame.GetRegions then
            for _, region in ipairs({ frame:GetRegions() }) do
                if isBackgroundTexture(region) and isFullSize(region) then
                    take(region)
                end
            end
        end

        if frame == canvas then return end

        if frame.GetChildren then
            for _, child in ipairs({ frame:GetChildren() }) do
                if type(child) == "table" and not isOurs(child) then
                    sweep(child, depth + 1)
                end
            end
        end
    end

    sweep(WorldMapFrame, 0)

    -- The maximised map hides the world with a frame of its own rather than a
    -- texture. Nothing of ours is inside it, so the whole frame can go.
    take(WorldMapFrame and WorldMapFrame.BlackoutFrame)

    -- Confirmed with `/hfwm framebg big`: on the World map (two continents
    -- that don't fill the frame), the wood/parchment showing through
    -- Transparent's holes is WorldMapFrame.OverscrollBG, Blizzard's own
    -- fallback fill for whatever space the canvas leaves uncovered (atlas
    -- "gamepad-mapquestlog-bgtile-2k"). It sits at BACKGROUND layer but
    -- isn't one of backingHosts(), and pass two's sweep reaches it but
    -- rejects it on size: 697x465 against a 1035x534 frame is 67% wide,
    -- just under isFullSize's 70% gate. Taking the frame directly, like
    -- BlackoutFrame, needs neither gate: hiding it also hides its texture.
    take(WorldMapFrame and WorldMapFrame.OverscrollBG)

    return out
end

--- Hide a region, remembering that we were the one who did it. Already-hidden
--- regions are left unrecorded so that restore does not Show something the
--- client wanted hidden anyway.
local function conceal(obj)
    if obj.IsShown and not obj:IsShown() then return end
    if not MapFrameBg.hidden[obj] then
        MapFrameBg.hidden[obj] = true
        MapFrameBg.order[#MapFrameBg.order + 1] = obj
    end
    obj:Hide()
end

--- Undo one conceal, and only that.
local function reveal(obj)
    if MapFrameBg.hidden[obj] then
        MapFrameBg.hidden[obj] = nil
        obj:Show()
    end
end

--- Re-hide when the client Shows something back at us. SetShown is hooked as
--- well: it is a separate C entry point and does not run the Show hook.
local function hook(obj)
    if obj._hfwmBgHooked then return end
    obj._hfwmBgHooked = true
    local function reassert(self)
        if Config.overlayActive and not MapFrameBg.visible then
            conceal(self)
        end
    end
    if obj.Show then hooksecurefunc(obj, "Show", reassert) end
    if obj.SetShown then
        hooksecurefunc(obj, "SetShown", function(self, shown)
            if shown then reassert(self) end
        end)
    end
end

--- Show or hide the map frame's backing.
---@param visible boolean true to leave the client's backing alone
function MapFrameBg:SetVisible(visible)
    visible = visible and true or false
    self.visible = visible

    if visible then
        -- Restore covers everything ever hidden, not just what the search
        -- finds this time, so switching away from Transparent can never leave
        -- a region permanently invisible.
        for _, obj in ipairs(self.order) do
            reveal(obj)
        end
        wipe(self.order)
        return
    end

    for _, obj in ipairs(collect()) do
        hook(obj)
        conceal(obj)
    end
end

--- Human-readable list of what SetVisible would act on right now, each with
--- its own actual IsShown()/GetAlpha(), not just whether the search found
--- it. Purely for `/hfwm framebg`: "found it, hidden it, and it's still
--- reported as shown" is a different bug than "never found it at all", and
--- the two used to print identically, with only one blanket
--- MapFrameBg.visible flag (what SetVisible was last told, not what any
--- region actually is) to go on.
---@return table[] rows { name, shown, alpha, weHid }
function MapFrameBg:Describe()
    local out = {}
    for _, obj in ipairs(collect()) do
        local name = obj.GetDebugName and obj:GetDebugName()
        if not name or name == "" then
            local tex = obj.GetTexture and obj:GetTexture()
            name = type(tex) == "string" and tex or "<unnamed>"
        end
        out[#out + 1] = {
            name  = name,
            shown = obj.IsShown and obj:IsShown() or false,
            alpha = obj.GetAlpha and obj:GetAlpha() or -1,
            weHid = self.hidden[obj] and true or false,
        }
    end
    return out
end

-------------------------------------------------------------------------------
-- Survey
--
-- The search above is still a hypothesis: that the map's backing is a
-- BACKGROUND-layer texture, either on one of a handful of panel frames or
-- map-sized somewhere else in the chrome. If Transparent still is not
-- see-through then the hypothesis is wrong somewhere, and Describe() cannot
-- say where, because it only reports what the search already reaches.
--
-- This walks the whole frame tree under WorldMapFrame instead and reports
-- every texture it finds, reached or not. Diagnostic only: nothing here runs
-- unless `/hfwm framebg all` or `/hfwm framebg nuke` asks for it.
-------------------------------------------------------------------------------

local function nameOf(obj)
    local name = obj.GetDebugName and obj:GetDebugName()
    if name and name ~= "" then return name end
    name = obj.GetName and obj:GetName()
    if name and name ~= "" then return name end
    return "<anonymous>"
end

--- Every texture under WorldMapFrame, deepest-last, with what it is and
--- whether the search above reaches it.
---@return table[] rows { owner, layer, sublevel, alpha, shown, width, height, tex, reached }
function MapFrameBg:Survey()
    local reached = {}
    for _, obj in ipairs(collect()) do reached[obj] = true end

    local rows, seen = {}, {}

    local function walk(frame, depth)
        if depth > 8 or not frame or seen[frame] then return end
        seen[frame] = true

        if frame.GetRegions then
            for _, r in ipairs({ frame:GetRegions() }) do
                if type(r) == "table" and r.GetObjectType
                    and r:GetObjectType() == "Texture" and not isOurs(r)
                then
                    local layer, sub = "?", 0
                    if r.GetDrawLayer then layer, sub = r:GetDrawLayer() end
                    local tex = r.GetTexture and r:GetTexture()
                    local atlas = r.GetAtlas and r:GetAtlas()
                    local w = r.GetWidth and r:GetWidth() or 0
                    local h = r.GetHeight and r:GetHeight() or 0
                    rows[#rows + 1] = {
                        obj      = r,
                        depth    = depth,
                        owner    = nameOf(frame),
                        region   = nameOf(r),
                        layer    = tostring(layer),
                        sublevel = tonumber(sub) or 0,
                        alpha    = r.GetAlpha and r:GetAlpha() or -1,
                        shown    = r.IsShown and r:IsShown(),
                        width    = w,
                        height   = h,
                        tex      = atlas or (type(tex) == "string" and tex)
                                   or (tex and ("fdid:" .. tostring(tex)))
                                   or "<colour>",
                        reached  = reached[r] and true or false,
                    }
                end
            end
        end

        if frame.GetChildren then
            for _, child in ipairs({ frame:GetChildren() }) do
                if type(child) == "table" and not isOurs(child) then
                    -- A frame with no regions of its own still matters if it
                    -- is a blackout-style cover, so record it either way.
                    if child.GetObjectType and child:GetObjectType() == "Frame"
                        and child.GetAlpha
                    then
                        rows[#rows + 1] = {
                            obj     = child,
                            depth   = depth,
                            owner   = nameOf(frame),
                            region  = nameOf(child) .. "  (frame)",
                            layer   = "-",
                            sublevel = 0,
                            alpha   = child:GetAlpha(),
                            shown   = child.IsShown and child:IsShown(),
                            width   = child.GetWidth and child:GetWidth() or 0,
                            height  = child.GetHeight and child:GetHeight() or 0,
                            tex     = "<frame>",
                            reached = reached[child] and true or false,
                        }
                    end
                    walk(child, depth + 1)
                end
            end
        end
    end

    walk(WorldMapFrame, 0)
    return rows
end

--- Hide every texture the survey found, ours excepted, and remember it for
--- Unnuke. The point is not to be a setting: it answers one question, can
--- this map be made see-through at all? If so, the survey rows tell us
--- which region mattered and the ordinary search can be taught to find it.
--- Hide() rather than alpha 0, for the reason at the top of the file: alpha
--- doesn't survive the client's own refreshes, so an alpha-based nuke could
--- answer "no" to a map that's actually perfectly see-through.
function MapFrameBg:Nuke()
    self._nuked = self._nuked or {}
    local n = 0
    for _, row in ipairs(self:Survey()) do
        local obj = row.obj
        if obj and obj.Hide and (not obj.IsShown or obj:IsShown()) then
            self._nuked[#self._nuked + 1] = obj
            obj:Hide()
            n = n + 1
        end
    end
    return n
end

--- Put back whatever Nuke hid.
function MapFrameBg:Unnuke()
    local n = 0
    for _, obj in ipairs(self._nuked or {}) do
        obj:Show()
        n = n + 1
    end
    self._nuked = {}
    return n
end
