-------------------------------------------------------------------------------
-- HFWM-Forever Map Coordinates
--
-- The WoW Forever client draws its own Player and Cursor coordinate readouts
-- on the world map (framestack: "CursorCords", and a Player counterpart).
-- This module only decides whether they are shown: Config.db.showPlayerCoords
-- and Config.db.showMouseCoords (both on by default, matching the client),
-- each toggled from Options. It draws nothing of its own.
--
-- The client's frame names are not documented, so they are found at runtime
-- instead of hard-coded: walk the map's frames (skipping the canvas, which
-- holds every pin) for a parentKey or frame name that looks like
-- "...Cords"/"...Coords", then call it the player readout if the name
-- says "player" and the cursor readout if it says "cursor"/"mouse".
-- Hidden readouts are kept hidden by hooking their Show/SetShown, since the
-- client re-shows them as the map updates. While the addon is disabled
-- nothing is touched. `/hfwm debug` lists what was found.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config = ns.Config
local Coords = ns.Coords

local WorldMapFrame = _G.WorldMapFrame

local MAX_DEPTH = 4

-- { obj = frame-or-region, kind = "player"|"mouse", name = string }
local found = {}
local seen  = {}

--- "player"/"mouse" if *name* names one of the client's coordinate
--- readouts, else nil.
local function Classify(name)
    name = name:lower()
    if not name:find("co?o?rds") then return nil end
    if name:find("player") then return "player" end
    if name:find("cursor") or name:find("mouse") then return "mouse" end
    return nil
end

local function Hidden(kind)
    local key = kind == "player" and "showPlayerCoords" or "showMouseCoords"
    return Config.db.enabled and not Config.db[key]
end

local function Register(obj, name)
    if seen[obj] or not obj.Hide then return end
    local kind = Classify(name)
    if not kind then return end
    seen[obj] = true
    local entry = { obj = obj, kind = kind, name = name }
    found[#found + 1] = entry
    -- Re-hide whenever the client shows it again while we want it gone.
    for _, method in ipairs({ "Show", "SetShown" }) do
        if obj[method] then
            hooksecurefunc(obj, method, function(self)
                if Hidden(kind) and self:IsShown() then self:Hide() end
            end)
        end
    end
end

local visited = {}

--- Look through *frame*'s parentKeys and children (to MAX_DEPTH) for
--- coordinate readouts. The map canvas is skipped: it holds every pin.
local function Scan(frame, depth)
    if visited[frame] or frame == WorldMapFrame.ScrollContainer then return end
    visited[frame] = true

    for key, value in pairs(frame) do
        if type(key) == "string" and type(value) == "table"
           and type(value[0]) == "userdata" then
            Register(value, key)
        end
    end
    local gname = frame.GetName and frame:GetName()
    if gname then Register(frame, gname) end

    if depth >= MAX_DEPTH then return end
    for _, child in ipairs({ frame:GetChildren() }) do
        Scan(child, depth + 1)
    end
    -- Regions (font strings) are parentKeys of their frame, found above, but
    -- an unkeyed named region is only reachable here.
    for _, region in ipairs({ frame:GetRegions() }) do
        local rname = region.GetName and region:GetName()
        if rname then Register(region, rname) end
    end
end

--- Apply both toggles to every readout found so far.
function Coords:Refresh()
    for _, e in ipairs(found) do
        if Hidden(e.kind) then
            e.obj:Hide()
        elseif WorldMapFrame:IsShown() then
            e.obj:Show()
        end
    end
end

--- One line per readout found, for /hfwm debug.
---@return string[]
function Coords:Describe()
    local out = {}
    for _, e in ipairs(found) do
        out[#out + 1] = ("%s (%s) shown=%s"):format(
            e.name, e.kind, tostring(e.obj:IsShown()))
    end
    return out
end

--- Called once from Core.lua. The readouts may be created after the map
--- frame, so rescan (cheap, deduplicated) each time the map is shown.
function Coords:Start()
    WorldMapFrame:HookScript("OnShow", function()
        wipe(visited)
        Scan(WorldMapFrame, 0)
        self:Refresh()
    end)
    if WorldMapFrame:IsShown() then
        Scan(WorldMapFrame, 0)
        self:Refresh()
    end
end
