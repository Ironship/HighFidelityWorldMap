-------------------------------------------------------------------------------
-- HFWM-Forever Namespace
-- Shared addon namespace table initialised here.
-- Every other Lua module receives this via the "..." idiom:
--     local addonName, ns = ...
-------------------------------------------------------------------------------
local addonName, ns = ...

-- Public sub-tables filled by individual modules
ns.Config      = {}
ns.Pool        = {}
ns.BaseArt     = {}
ns.Exploration = {}
ns.Watchdog    = {}
ns.Renderer    = {}
ns.Commands    = {}
ns.Cave        = {}
ns.CaveRenderer = {}

-- Convenience printer (accessible everywhere via ns.P)
ns.P = function(msg) print("|cff33ccffHFWM-F:|r " .. msg) end
