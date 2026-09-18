-------------------------------------------------------------------------------
-- HFWM-Forever Cave
-- Detects when the player is inside a cave / micro dungeon / dungeon instance
-- whose UiMapID differs from what the world map is showing, and drives the
-- separate cave overlay (CaveRenderer) accordingly.
--
-- Floor (multi-level dungeon) detection is automatic: when the player moves
-- between floors of the same map group, the active floor is swapped.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Cave         = ns.Cave
local Config       = ns.Config
local P            = ns.P

-- Map types that should trigger the cave overlay.
-- Enum.UiMapType: World=0, Continent=1, Zone=2, Dungeon=4, Micro=5, Orphan=6
local CAVE_MAP_TYPES = {
    [4] = true, -- Dungeon
    [5] = true, -- Micro
}

local pollFrame  -- always-on polling frame (separate from Watchdog)
local POLL_INTERVAL = 0.5
local elapsedSincePoll = 0

--- Get the UiMapID the player is physically standing on (specific floor).
function Cave:GetCurrentFloorMapID()
    return C_Map.GetBestMapForUnit("player")
end

--- Returns true if the player is in a cave/micro/dungeon map *and* the world
--- map is showing a different (parent) map. If they match, no overlay needed
--- because the regular Renderer already shows the cave.
function Cave:IsPlayerInCave()
    local playerMapID = C_Map.GetBestMapForUnit("player")
    if not playerMapID then return false end

    local info = C_Map.GetMapInfo(playerMapID)
    if not info or not CAVE_MAP_TYPES[info.mapType] then
        return false
    end

    local displayedMapID = WorldMapFrame:GetMapID()
    if displayedMapID == playerMapID then
        return false
    end

    return true, playerMapID
end

--- Build sorted floor list for a cave map. Falls back to a single-entry list
--- if the map is not part of a group.
function Cave:BuildFloorList(caveMapID)
    local groupID = C_Map.GetMapGroupID(caveMapID)
    if not groupID then
        local info = C_Map.GetMapInfo(caveMapID)
        return {
            { mapID = caveMapID,
              name = info and info.name or ("Map " .. caveMapID),
              relativeHeightIndex = 0 },
        }
    end

    local members = C_Map.GetMapGroupMembersInfo(groupID)
    if not members or #members == 0 then
        local info = C_Map.GetMapInfo(caveMapID)
        return {
            { mapID = caveMapID,
              name = info and info.name or ("Map " .. caveMapID),
              relativeHeightIndex = 0 },
        }
    end

    -- Sort by relativeHeightIndex descending (top floor first)
    local sorted = {}
    for _, m in ipairs(members) do
        sorted[#sorted + 1] = {
            mapID = m.mapID,
            name = m.name or ("Floor " .. (m.relativeHeightIndex or 0)),
            relativeHeightIndex = m.relativeHeightIndex or 0,
        }
    end
    table.sort(sorted, function(a, b)
        return a.relativeHeightIndex > b.relativeHeightIndex
    end)
    return sorted
end

--- Reconcile cave state. Called when player map or world-map map changes.
function Cave:UpdateState()
    if not Config.db or not Config.db.enabled or not Config.db.caveEnabled then
        ns.CaveRenderer:HideCave()
        return
    end

    local inCave, playerMapID = self:IsPlayerInCave()
    if not inCave then
        if Config.caveOverlayActive then
            ns.CaveRenderer:HideCave()
        end
        return
    end

    -- Build floor list once per cave (or rebuild if map group changed)
    local existingFloors = Config.caveAllFloors
    local needRebuild = true
    if existingFloors then
        for _, f in ipairs(existingFloors) do
            if f.mapID == playerMapID then
                needRebuild = false
                break
            end
        end
    end
    if needRebuild then
        Config.caveAllFloors = self:BuildFloorList(playerMapID)
    end

    -- Auto-select the player's current floor
    if Config.caveCurrentFloorMapID ~= playerMapID
       or not Config.caveOverlayActive then
        Config.caveCurrentFloorMapID = playerMapID
        ns.CaveRenderer:ShowCave(playerMapID)
    end
end

--- Periodic poll for cave state changes.
local function OnPollUpdate(self, elapsed)
    elapsedSincePoll = elapsedSincePoll + elapsed
    if elapsedSincePoll < POLL_INTERVAL then return end
    elapsedSincePoll = 0

    if not Config.db or not Config.db.enabled or not Config.db.caveEnabled then return end
    -- Use GetMapID() as the visibility gate — IsShown() is unreliable in WoW 12.0
    if not WorldMapFrame:GetMapID() then
        -- Don't render while map is hidden, but reset detection cache so
        -- next show triggers a fresh evaluation.
        if Config.caveOverlayActive then
            ns.CaveRenderer:HideCave()
        end
        return
    end

    local playerMapID = C_Map.GetBestMapForUnit("player")
    local displayedMapID = WorldMapFrame:GetMapID()
    if playerMapID ~= Config.lastPlayerMapID
       or displayedMapID ~= Config.caveDisplayedMapID then
        Config.lastPlayerMapID = playerMapID
        Config.caveDisplayedMapID = displayedMapID
        Cave:UpdateState()
    end
end

--- Start the always-on cave-state poller.
function Cave:Start()
    if pollFrame then return end
    pollFrame = CreateFrame("Frame", "HFWMForeverCavePoller")
    pollFrame:SetScript("OnUpdate", OnPollUpdate)
end
