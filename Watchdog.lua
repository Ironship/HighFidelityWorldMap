-------------------------------------------------------------------------------
-- HFWM-Forever Watchdog
-- OnUpdate watchdog: retries the overlay if the canvas was initially 0x0,
-- detects submerged-state and canvas-identity changes, and periodically
-- re-asserts BaseArt/MapFrameBg's concealment against whatever Blizzard's
-- own map code shows back at us.
-- Does NOT touch Blizzard-owned frames — suppression is handled by hooks
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
--- Both modules already hook Show/SetShown on every region they find, which
--- covers the client re-tiling or re-showing an *existing* object. What it
--- cannot cover is a region recreated through some other path — a fresh Lua
--- wrapper for what is conceptually "the same" texture, with none of our
--- hooks attached — which is exactly what turned out to be happening to
--- WorldMapFrame.ScrollContainer.Child.TiledBackground under Transparent:
--- concealing it once, right when the background changed, raced against the
--- client's own layout pass creating or re-showing it moments later with
--- nothing left to catch that. `/hfwm framebg nuke` then `restore` fixed it
--- by hand — and stuck — because by the time `restore` called Show() on it,
--- that object already had our hook attached from the first attempt, which
--- caught that Show() and re-hid it instantly. That proved the concealment
--- itself works and only its *timing* was the problem, so re-running it on a
--- short interval for as long as the overlay is up closes the same window
--- automatically, without needing to know exactly when the client's pass
--- runs.
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
    -- only re-parents the overlay frame and re-applies MapFrameBg/BaseArt's
    -- concealment when it actually runs a full refresh, which its own
    -- "skip if nothing changed" check can otherwise defer indefinitely if
    -- nothing else prompts one — leaving the new canvas's own fresh backing
    -- (e.g. its TiledBackground) unhidden under Transparent. This poll is
    -- what notices in that case, the same way it already notices a
    -- submerged-state change below.
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

    -- Re-run BaseArt/MapFrameBg's own concealment against whatever the
    -- client is currently showing — see REASSERT_INTERVAL's comment above.
    -- Both re-apply whatever state they already believe is correct
    -- (`.visible`), so this is a cheap no-op once nothing has slipped past
    -- their hooks, not a fight against the addon's own settings: a
    -- Hybrid/Ocean Blue/Original session spends this call on SetVisible(true),
    -- which only re-Shows what it once hid and is a no-op once that list is
    -- empty.
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
