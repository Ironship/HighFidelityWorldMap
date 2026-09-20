-------------------------------------------------------------------------------
-- HFWM-Forever Map Memory
--
-- Remembers the world map's zoom (scale) and pan (scroll position) across
-- closing and reopening it — the one job the separate PersistentWorldMap
-- addon (Interface/AddOns/PersistentWorldMap) is built around, folded in
-- here as a single opt-out instead of a second install. On by default via
-- Config.DEFAULTS.rememberMapZoomPan; toggle from Options or
-- `/hfwm remember on|off`.
--
-- Save: a pre-hook on the map's ScrollContainer OnHide (like
-- PersistentWorldMap's restoreAndReset.lua, a *pre*-hook, because a normal
-- HookScript OnHide runs too late relative to the container tearing state
-- down), reading the same three fields PersistentWorldMap reads —
-- currentScale / currentScrollX / currentScrollY — straight off the
-- ScrollContainer, tagged with the mapID they belong to. Method-call
-- equivalents (GetCanvasScale etc.) are tried first and the field used as
-- the fallback, the same belt-and-suspenders this addon already applies to
-- every other client-version-sensitive API (see Options.lua's
-- CreateFrameTry/SubElement).
--
-- Restore: a post-hook on ToggleWorldMap and ToggleQuestLog. WorldMapFrame's
-- own OnShow fires before mapID and layout have settled — PersistentWorldMap
-- calls this out explicitly — so the toggle functions are the reliable
-- point, not HookScript("OnShow", ...). Restoring means forcing the map
-- back to the remembered mapID (undoing the client's own reset-to-current-
-- zone) and then instantly panning/zooming to the remembered position.
--
-- Not reproduced here: PersistentWorldMap's auto-centering, double-click,
-- recenter button and its whole taint-prevention module (taintPrevent.lua) —
-- that machinery exists because PersistentWorldMap permanently taints
-- WorldMapFrame.mapID and then has to patch every map pin so combat doesn't
-- start throwing ADDON_ACTION_BLOCKED. This module makes the same tainting
-- write, but sidesteps the fallout with a much smaller fix: skip the restore
-- entirely while InCombatLockdown() and simply retry once combat ends,
-- rather than patching pins to tolerate it mid-combat. The one place that
-- costs something is a reopen during combat itself, which briefly shows the
-- client's own default view until PLAYER_REGEN_ENABLED fires.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config    = ns.Config
local MapMemory  = ns.MapMemory

local WorldMapFrame    = _G.WorldMapFrame
local InCombatLockdown = _G.InCombatLockdown

-------------------------------------------------------------------------------
-- Field access with a method-call preference, mirroring the comment above.
-------------------------------------------------------------------------------

local function GetCanvasScale(sc)
    if sc.GetCanvasScale then
        local ok, v = pcall(sc.GetCanvasScale, sc)
        if ok and v then return v end
    end
    return sc.currentScale
end

local function GetScrollX(sc)
    if sc.GetCurrentScrollX then
        local ok, v = pcall(sc.GetCurrentScrollX, sc)
        if ok and v then return v end
    end
    return sc.currentScrollX
end

local function GetScrollY(sc)
    if sc.GetCurrentScrollY then
        local ok, v = pcall(sc.GetCurrentScrollY, sc)
        if ok and v then return v end
    end
    return sc.currentScrollY
end

-------------------------------------------------------------------------------
-- Remembered state
--
-- Session-only, same as PersistentWorldMap's own lastMapID/lastScale/
-- lastScrollX/lastScrollY locals: not written to SavedVariables, so a
-- /reload or relog starts fresh rather than carrying a stale position from
-- a previous session into a client that may not even show the same map on
-- login.
-------------------------------------------------------------------------------
local savedMapID, savedScale, savedScrollX, savedScrollY

-- Guards against saving a half-initialised ScrollContainer before the map
-- has ever actually been shown this session.
local firstShownAfterLogin = false

-- Set when a restore was skipped for being in combat, so it can be retried
-- the moment combat ends instead of leaving the map on the wrong view.
local pendingRestore = false

local function Enabled()
    return Config.db and Config.db.rememberMapZoomPan
end

local function SaveState()
    if not firstShownAfterLogin or not Enabled() then return end

    local sc = WorldMapFrame.ScrollContainer
    local mapID = WorldMapFrame:GetMapID()
    if not mapID or not sc then
        savedMapID = nil
        return
    end

    savedMapID   = mapID
    savedScale   = GetCanvasScale(sc)
    savedScrollX = GetScrollX(sc)
    savedScrollY = GetScrollY(sc)
end

local function RestoreState()
    if not Enabled() then return end
    if not (savedMapID and savedScale and savedScrollX and savedScrollY) then
        return
    end

    if InCombatLockdown() then
        pendingRestore = true
        return
    end
    pendingRestore = false

    if WorldMapFrame:GetMapID() ~= savedMapID then
        pcall(WorldMapFrame.SetMapID, WorldMapFrame, savedMapID)
    end

    local sc = WorldMapFrame.ScrollContainer
    if sc and sc.InstantPanAndZoom then
        pcall(sc.InstantPanAndZoom, sc, savedScale, savedScrollX, savedScrollY,
            true)
    end
    if WorldMapFrame.OnMapChanged then
        pcall(WorldMapFrame.OnMapChanged, WorldMapFrame)
    end
end

--- Post-hook target for ToggleWorldMap/ToggleQuestLog: only meaningful once
--- the map is actually on screen, mirroring PersistentWorldMap's own
--- RestoreMap gate.
local function OnToggle()
    if not WorldMapFrame:IsShown() then return end
    firstShownAfterLogin = true
    RestoreState()
end

--- Discard the remembered position without touching the enabled setting —
--- used when the feature is switched off from Options or `/hfwm remember
--- off`, so flipping it back on later doesn't reapply a stale spot.
function MapMemory:Clear()
    savedMapID, savedScale, savedScrollX, savedScrollY = nil, nil, nil, nil
    pendingRestore = false
end

--- Wire up the hooks. Called once from Core.lua's PLAYER_LOGIN handler,
--- after WorldMapFrame is guaranteed to exist — same timing every other
--- module here waits for.
function MapMemory:Start()
    local sc = WorldMapFrame.ScrollContainer

    -- Pre-hook: capture whatever OnHide script is already there (Blizzard's
    -- own, or another addon's) and still run it, same as PersistentWorldMap
    -- does for the identical reason.
    local otherOnHide = sc:GetScript("OnHide")
    sc:SetScript("OnHide", function(self, ...)
        SaveState()
        if otherOnHide then otherOnHide(self, ...) end
    end)

    hooksecurefunc("ToggleWorldMap", OnToggle)
    hooksecurefunc("ToggleQuestLog", OnToggle)

    -- Retry a restore that combat lockdown blocked.
    local combatFrame = CreateFrame("Frame")
    combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatFrame:SetScript("OnEvent", function()
        if pendingRestore and WorldMapFrame:IsShown() then
            RestoreState()
        end
        pendingRestore = false
    end)
end
