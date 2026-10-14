-------------------------------------------------------------------------------
-- HFWM-Forever Pin Taint Guard
-- Blizzard's MapCanvasMixin:AcquirePin ends every acquisition with
-- pin:CheckMouseButtonPassthrough("RightButton"), which calls the
-- combat-restricted SetPassThroughButtons on the pin. Once anything has
-- tainted the map's state -- MapMemory's designed mapID restore does (see
-- its header), and so can any full provider refresh run from addon code --
-- that call runs from a tainted execution path. Out of combat tainted code
-- may still use the function; in combat it may not, so every pin acquired
-- then throws ADDON_ACTION_BLOCKED and names this addon.
--
-- The function itself is unreachable for a fix: it is protected, an addon
-- cannot call it in combat at all. What is reachable is the pin instance it
-- is invoked on: shadow each pin's own SetPassThroughButtons (and
-- SetPropagateMouseClicks, which some pin mixins call on their own) with a
-- wrapper that skips the call while InCombatLockdown() and otherwise calls
-- straight through. Out of combat nothing changes; in combat the pin keeps
-- whatever passthrough state it already had until the next out-of-combat
-- refresh re-acquires it. PersistentWorldMap's taintPrevent.lua ships the
-- same shadowing for the same reason and the same call site.
--
-- Pins are patched at pool-acquire time: inside Blizzard's own AcquirePin
-- (pool:Acquire runs before CheckMouseButtonPassthrough), an Acquire
-- wrapper on each pool hands the pin to PatchPin first, and a __newindex
-- metatable on the canvas's pinPools catches pools created later. Patches
-- are on the pin instance, so they survive the pool recycling pins across
-- map opens. Does nothing else with the pins; the mouse-state save/restore
-- in Exploration.lua is unrelated and unchanged.
-------------------------------------------------------------------------------
local addonName, ns = ...
local PinTaint = ns.PinTaint

local InCombatLockdown = _G.InCombatLockdown

---@param pin Button|Frame
local function PatchPin(pin)
    if pin._hfwmPassthroughPatched then return end
    pin._hfwmPassthroughPatched = true

    -- ScriptRegion methods, so present on every pin; the nil checks are
    -- only future-proofing against a client that stops exposing one of them.
    local origSetPassThroughButtons = pin.SetPassThroughButtons
    if origSetPassThroughButtons then
        pin.SetPassThroughButtons = function(self, ...)
            if InCombatLockdown() then return end
            return origSetPassThroughButtons(self, ...)
        end
    end

    local origSetPropagateMouseClicks = pin.SetPropagateMouseClicks
    if origSetPropagateMouseClicks then
        pin.SetPropagateMouseClicks = function(self, ...)
            if InCombatLockdown() then return end
            return origSetPropagateMouseClicks(self, ...)
        end
    end
end

--- Patch each pin the pool hands out, before Blizzard's AcquirePin can
--- reach the protected call. Must return Blizzard's own (pin, isNew).
local function WrapPool(pool)
    if pool._hfwmAcquireWrapped then return end
    pool._hfwmAcquireWrapped = true

    local origAcquire = pool.Acquire
    pool.Acquire = function(self, ...)
        local pin, isNew = origAcquire(self, ...)
        if pin then PatchPin(pin) end
        return pin, isNew
    end
end

local function GuardCanvas(canvas)
    if not canvas or not canvas.pinPools or canvas._hfwmPinGuardInstalled then
        return
    end
    canvas._hfwmPinGuardInstalled = true

    -- Pools that already exist: wrap them, and patch whatever is still
    -- active in them (its next CheckMouseButtonPassthrough would otherwise
    -- come from a re-acquisition, which the wrapper covers).
    for _, pool in pairs(canvas.pinPools) do
        WrapPool(pool)
        for pin in pool:EnumerateActive() do PatchPin(pin) end
    end

    -- Blizzard never sets a metatable on pinPools, so a plain
    -- setmetatable is enough; revisit if a client patch ever adds one.
    setmetatable(canvas.pinPools, {
        __newindex = function(t, pinTemplate, pool)
            rawset(t, pinTemplate, pool)
            WrapPool(pool)
        end,
    })
end

--- Called once from Core.lua's PLAYER_LOGIN wiring, before anything can
--- acquire map pins (the preload rehearsal opens the map later, from
--- PLAYER_ENTERING_WORLD).
function PinTaint:Start()
    GuardCanvas(WorldMapFrame)
end
