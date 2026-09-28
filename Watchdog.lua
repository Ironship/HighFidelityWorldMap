-------------------------------------------------------------------------------
-- HFWM-Forever Watchdog
-- OnUpdate watchdog: retries the overlay if the canvas was initially 0x0,
-- detects submerged-state and canvas-identity changes, and periodically
-- re-asserts BaseArt/MapFrameBg's concealment against whatever Blizzard's
-- own map code shows back at us.
-- Does NOT touch Blizzard-owned frames; suppression is handled by hooks
-- in BaseArt and Exploration to avoid taint propagation.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Watchdog   = ns.Watchdog
local Config     = ns.Config
local Pool       = ns.Pool
local BaseArt    = ns.BaseArt
local MapFrameBg = ns.MapFrameBg

--- How often to re-run BaseArt/MapFrameBg's own concealment while the
--- overlay is active, independent of every other check in this file.
---
--- Both modules hook Show/SetShown on every region they find, covering the
--- client re-tiling or re-showing an *existing* object. What they can't
--- cover is a region recreated through some other path: a fresh Lua wrapper
--- for what is conceptually "the same" texture, with no hooks attached. This
--- happened to WorldMapFrame.ScrollContainer.Child.TiledBackground under
--- Transparent: concealing it once raced against the client's own layout
--- pass re-creating it moments later. `/hfwm framebg nuke` then `restore`
--- confirmed the concealment logic itself works (the hook from the first
--- attempt caught `restore`'s Show() and re-hid it instantly); only the
--- *timing* was the problem. Re-running concealment on a short interval
--- while the overlay is up closes that window without needing to know when
--- the client's own pass runs.
local REASSERT_INTERVAL = 0.25
local reassertAccum = 0

local function OnUpdate(self, elapsed)
    if not Config.overlayActive or not Config.db or not Config.db.enabled then
        self:SetScript("OnUpdate", nil)
        return
    end
    if not WorldMapFrame:GetMapID() then
        self:SetScript("OnUpdate", nil)
        return
    end

    local canvas = WorldMapFrame.ScrollContainer
        and WorldMapFrame.ScrollContainer.Child

    -- Detect the canvas itself being swapped out from under us (WoW 12.0+
    -- can replace WorldMapFrame.ScrollContainer.Child wholesale). Renderer
    -- only re-applies MapFrameBg/BaseArt's concealment on a full refresh,
    -- and its "skip if nothing changed" check can defer that indefinitely,
    -- leaving the new canvas's fresh backing (e.g. TiledBackground) unhidden
    -- under Transparent. This poll catches that case, same as the
    -- submerged-state check below.
    if canvas and canvas ~= Config.lastCanvas then
        Config.lastMapID = nil
        ns.Renderer:Refresh(true)
        return
    end

    if Pool:ActiveCount() == 0 then
        if canvas then
            local w, h = canvas:GetSize()
            if w > 0 and h > 0 then
                Config.lastMapID = nil
                ns.Renderer:Refresh(true)
                return
            end
        end
    end

    -- Detect submerged state change -> refresh to swap art layer
    local nowSubmerged = IsSubmerged() and true or false
    if nowSubmerged ~= Config.lastSubmerged then
        Config.lastSubmerged = nowSubmerged
        Config.lastMapID = nil
        ns.Renderer:Refresh(true)
        return
    end

    -- Re-run BaseArt/MapFrameBg's own concealment (see REASSERT_INTERVAL's
    -- comment above). Both just re-apply the state they already believe is
    -- correct (`.visible`), so this is a cheap no-op once nothing has
    -- slipped past their hooks: a Hybrid/Ocean Blue/Original session spends
    -- this call on SetVisible(true), which only re-Shows what it once hid.
    reassertAccum = reassertAccum + elapsed
    if reassertAccum >= REASSERT_INTERVAL then
        reassertAccum = 0
        BaseArt:SetVisible(BaseArt.visible)
        MapFrameBg:SetVisible(MapFrameBg.visible)
    end
end

function Watchdog:Start()
    if not Config.overlayFrame then return end
    reassertAccum = 0
    Config.overlayFrame:SetScript("OnUpdate", OnUpdate)
end
