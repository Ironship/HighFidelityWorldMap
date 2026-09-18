-------------------------------------------------------------------------------
-- HFWM-Forever Exploration
-- Hide / show exploration overlay ("fog of war cleared" textures).
-- Searches pin pools and data providers directly on WorldMapFrame.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Exploration = ns.Exploration
local Config      = ns.Config

local hookedDPs = {}

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

    if WorldMapFrame.pinPools then
        for templateName, pinPool in next, WorldMapFrame.pinPools do
            if templateName:find("Exploration") or templateName:find("exploration") then
                for pin in pinPool:EnumerateActive() do
                    pin:SetAlpha(0)
                    pin:EnableMouse(false)
                    for _, region in ipairs({pin:GetRegions()}) do
                        region:SetAlpha(0)
                    end
                end
            end
        end
    end

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
        if WorldMapFrame.pinPools then
            for templateName, pinPool in next, WorldMapFrame.pinPools do
                if templateName:find("Exploration") or templateName:find("exploration") then
                    for pin in pinPool:EnumerateActive() do
                        pin:SetAlpha(1)
                        pin:EnableMouse(true)
                        pin:Show()
                        for _, region in ipairs({pin:GetRegions()}) do
                            region:SetAlpha(1)
                            region:Show()
                        end
                    end
                end
            end
        end
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
