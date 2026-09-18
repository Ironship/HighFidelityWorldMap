-------------------------------------------------------------------------------
-- HFWM-Forever TexturePool
-- Recycle Texture objects to avoid creating new ones every refresh.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Pool   = ns.Pool
local Config = ns.Config

local texturePool    = {}   -- recycled Texture objects
local activeTextures = {}   -- currently displayed

function Pool:Acquire()
    local tex = tremove(texturePool)
    if not tex then
        tex = Config.overlayFrame:CreateTexture(nil, "ARTWORK", nil, 2)
    end
    tex:SetVertexColor(1, 1, 1, 1)
    tex:Show()
    activeTextures[#activeTextures + 1] = tex
    return tex
end

function Pool:ReleaseAll()
    for i = #activeTextures, 1, -1 do
        local tex = activeTextures[i]
        tex:Hide()
        tex:ClearAllPoints()
        activeTextures[i] = nil
        texturePool[#texturePool + 1] = tex
    end
end

function Pool:ActiveCount()
    return #activeTextures
end

function Pool:GetActive()
    return activeTextures
end
