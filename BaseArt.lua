-------------------------------------------------------------------------------
-- HFWM-Forever BaseArt
-- Hide / show the default detail-layer map tiles (the base art).
-------------------------------------------------------------------------------
local addonName, ns = ...
local BaseArt = ns.BaseArt
local Config  = ns.Config

--- Set visibility on all detail-layer tiles and textures.
---@param visible boolean
function BaseArt:SetVisible(visible)
    if not WorldMapFrame.detailLayerPool then return end
    for dtl in WorldMapFrame.detailLayerPool:EnumerateActive() do
        if not dtl._hfwmHooked then
            dtl._hfwmHooked = true
            hooksecurefunc(dtl, "Show", function(self)
                if Config.overlayActive then self:SetAlpha(0) end
            end)
            if dtl.RefreshDetailTiles then
                hooksecurefunc(dtl, "RefreshDetailTiles", function(self)
                    if Config.overlayActive then
                        self:SetAlpha(0)
                        if self.tilePool then
                            for tile in self.tilePool:EnumerateActive() do
                                tile:SetAlpha(0)
                            end
                        end
                    end
                end)
            end
        end

        if visible then
            dtl:SetAlpha(1)
            dtl:Show()
        else
            dtl:SetAlpha(0)
        end

        if dtl.tilePool then
            for tile in dtl.tilePool:EnumerateActive() do
                if visible then
                    tile:SetAlpha(1)
                    tile:Show()
                else
                    tile:SetAlpha(0)
                end
            end
        end
        if dtl.textures then
            for _, tex in ipairs(dtl.textures) do
                if visible then
                    tex:SetAlpha(1)
                    tex:Show()
                else
                    tex:SetAlpha(0)
                end
            end
        end
    end
end
