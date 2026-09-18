-------------------------------------------------------------------------------
-- HFWM-Forever Exploration
-- Hide / show exploration overlay ("fog of war cleared" textures).
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
