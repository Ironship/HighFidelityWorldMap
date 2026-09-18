-------------------------------------------------------------------------------
-- HFWM-Forever Watchdog
-- OnUpdate watchdog: retries the overlay if the canvas was initially 0x0,
-- and detects submerged-state changes.
-- Does NOT touch Blizzard-owned frames — suppression is handled by hooks
-- in BaseArt and Exploration to avoid taint propagation.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Watchdog   = ns.Watchdog
local Config     = ns.Config
local Pool       = ns.Pool

local function OnUpdate(self)
    if not Config.overlayActive or not Config.db or not Config.db.enabled then
        self:SetScript("OnUpdate", nil)
        return
    end
    if not WorldMapFrame:GetMapID() then
        self:SetScript("OnUpdate", nil)
        return
    end

    if Pool:ActiveCount() == 0 then
        local canvas = WorldMapFrame.ScrollContainer
            and WorldMapFrame.ScrollContainer.Child
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
end

function Watchdog:Start()
    if not Config.overlayFrame then return end
    Config.overlayFrame:SetScript("OnUpdate", OnUpdate)
end
