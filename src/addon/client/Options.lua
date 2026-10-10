-------------------------------------------------------------------------------
-- HFWM-Forever Options
-- The options panel, as an AceConfig-3.0 table: enable toggle,
-- remember/zoom toggles, the Map Background section (Global
-- Background plus a per-map-type override each for Zone/Continent/World),
-- the cave map section, and a profiles tab (AceDBOptions-3.0).
--
-- AceConfigDialog handles the rest: registering into the client's Interface
-- Options (AddToBlizOptions) and drawing the standalone window /hfwm
-- options opens, across every client flavour this addon supports.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Options = ns.Options
local Config  = ns.Config

local PANEL_TITLE = "High Fidelity World Map"

--- Blizzard's own colour for a Battle.net-linked friend's name, the
--- closest thing the client already defines to an official "Blizzard
--- cyan". Reused here for "Use Global" (see MapTypeBackgroundValues)
--- same as CaveRenderer.lua reuses it for its floor-picker's "All" entry.
--- Falls back to the literal hex on a client build that doesn't expose
--- the constant as a global.
local BLIZZARD_CYAN_HEX = FRIENDS_BNET_NAME_COLOR_CODE or "|cff82c5ff"

--- {key = label} for every background this install can actually draw.
--- Used by the Global Background dropdown.
local function BackgroundValues()
    local values = {}
    for _, bg in ipairs(Config:AvailableBackgrounds()) do
        values[bg.key] = bg.label
    end
    return values
end

--- Same as BackgroundValues, plus "Use Global" up front, in Blizzard cyan
--- so it reads as the inherited/default choice rather than an ordinary
--- background -- same treatment CaveRenderer's floor picker gives "All".
--- Used by the Zone/Continent/World Map dropdowns, which can each either
--- inherit the Global Background or name one of their own.
local function MapTypeBackgroundValues()
    local values = { global = BLIZZARD_CYAN_HEX .. "Use Global|r" }
    for _, bg in ipairs(Config:AvailableBackgrounds()) do
        values[bg.key] = bg.label
    end
    return values
end

--- Chat-command reference line shown at the bottom of the panel. Built
--- from the same background list as the dropdown, so it never advertises
--- one this install can't draw.
local function ChatCommandHint()
    local keys = {}
    for _, bg in ipairs(Config:AvailableBackgrounds()) do
        keys[#keys + 1] = bg.key
    end
    return "Also from chat: /hfwm bg " .. table.concat(keys, "|")
        .. "  |  /hfwm cave on|off|autoopen|remember  |  /hfwm remember on|off"
        .. "  |  /hfwm zoom on|off  |  /hfwm clarity on|off  |  /hfwm fog on|off"
end

--- Is Zone Map's effective background Hybrid? Gates the Fog of War
--- checkbox, which only works over Blizzard's own art (Hybrid).
local function ZoneIsHybrid()
    local zoneBg = Config:GetEffectiveMapTypeBackground("zone")
    return zoneBg ~= nil and zoneBg.key == "hybrid"
end

local options = {
    type = "group",
    name = PANEL_TITLE,
    args = {
        intro = {
            order = 1,
            type = "description",
            name = "Satellite world map stitched from the game's own "
                .. "minimap terrain tiles.\n",
        },
        enabled = {
            order = 10,
            type = "toggle",
            name = "Enable the overlay",
            desc = "Turns the satellite map overlay on or off.",
            get = function() return Config.db.enabled end,
            set = function(_, value)
                Config.db.enabled = value
                ns.Renderer:ForceRefresh()
            end,
        },
        rememberMapZoomPan = {
            order = 40,
            type = "toggle",
            name = "Remember map zoom and pan",
            desc = "Keeps the world map at the zoom and pan you left it "
                .. "at, instead of resetting to your current zone on "
                .. "reopen.",
            get = function() return Config.db.rememberMapZoomPan end,
            set = function(_, value)
                Config.db.rememberMapZoomPan = value
                if not value then ns.MapMemory:Clear() end
            end,
        },
        additionalZoomLevels = {
            order = 50,
            type = "toggle",
            name = "Additional zoom levels",
            desc = "Lets the world map zoom eight steps closer than the "
                .. "client's own maximum. Off by default.",
            get = function() return Config.db.additionalZoomLevels end,
            set = function(_, value)
                Config.db.additionalZoomLevels = value
                ns.ZoomLevels:Refresh()
            end,
        },
        toggleButtonEnabled = {
            order = 72,
            type = "toggle",
            name = "HD/SD map toggle button",
            desc = "Adds a small button to the world map's top-right "
                .. "corner for switching between the high-fidelity "
                .. "overlay and Blizzard's own map, just for the current "
                .. "map session -- it does not touch \"Enable the "
                .. "overlay\" above, so the cave map and everything else "
                .. "stay on. Turn off for a cleaner map with one less "
                .. "button.",
            get = function() return Config.db.toggleButtonEnabled end,
            set = function(_, value)
                Config.db.toggleButtonEnabled = value
                ns.ToggleButton:Refresh()
            end,
        },
        mapBackground = {
            order = 75,
            type = "group",
            inline = true,
            -- Boxed section, same treatment as Cave map (beta) just below
            -- it -- not a tab under Profiles' tree, and placed directly
            -- above Cave map since it matters more.
            name = "Map Background",
            args = {
                intro = {
                    order = 1,
                    type = "description",
                    name = "What draws behind and in place of this addon's "
                        .. "own tiles. Zone Map, Continent Map and World "
                        .. "Map can each override the Global Background "
                        .. "below; leave one at \"Use Global\" to just "
                        .. "follow it.\n",
                },
                globalBackground = {
                    order = 10,
                    type = "select",
                    -- width = "full": its own row, set apart from the
                    -- Zone/World/Continent rows below.
                    width = "full",
                    name = "Global Background",
                    desc = function() return Config:GetBackground().desc end,
                    values = BackgroundValues,
                    get = function() return Config:GetBackground().key end,
                    set = function(_, value) Config:SetBackground(value) end,
                },
                -- Zone/World/Continent Map dropdowns, stacked below Global
                -- Background, filled in just after this table from
                -- Config.MAP_TYPES.
            },
        },
        cave = {
            order = 80,
            type = "group",
            inline = true,
            name = "Cave map (beta)",
            args = {
                intro = {
                    order = 1,
                    type = "description",
                    name = "Opens a small window over the world map for "
                        .. "caves, mines and dungeon interiors, which the "
                        .. "zone map can't show.\n",
                },
                caveEnabled = {
                    order = 10,
                    type = "toggle",
                    name = "Enable the cave map",
                    desc = "Turns the cave map window on or off.",
                    get = function() return Config.db.caveEnabled end,
                    set = function(_, value)
                        Config.db.caveEnabled = value
                        if value then
                            -- On a client with no interior maps, the
                            -- checkbox going green would otherwise be the
                            -- only feedback the user gets.
                            ns.Cave:WarnIfUnsupported()
                            ns.Cave:Unsuppress()
                            ns.Cave:UpdateState()
                        else
                            ns.CaveRenderer:HideCave()
                        end
                    end,
                },
                caveAutoOpen = {
                    order = 20,
                    type = "toggle",
                    name = "Open automatically",
                    desc = "Opens the cave map the instant you enter a "
                        .. "tracked cave.",
                    disabled = function() return not Config.db.caveEnabled end,
                    get = function() return Config.db.caveAutoOpen end,
                    set = function(_, value) Config.db.caveAutoOpen = value end,
                },
                caveRememberState = {
                    order = 30,
                    type = "toggle",
                    name = "Remember state",
                    desc = "Reopens the cave map only if it was open when "
                        .. "you last closed one. Takes over from Open "
                        .. "Automatically when the two disagree.",
                    disabled = function() return not Config.db.caveEnabled end,
                    get = function() return Config.db.caveRememberState end,
                    set = function(_, value)
                        Config.db.caveRememberState = value
                    end,
                },
                caveAlpha = {
                    order = 40,
                    type = "range",
                    name = "Cave map opacity",
                    desc = "Opacity of the cave map window.",
                    min = 0.2, max = 1, step = 0.05, isPercent = true,
                    disabled = function() return not Config.db.caveEnabled end,
                    get = function() return Config:CaveAlpha() end,
                    set = function(_, value)
                        Config.db.caveAlpha = value
                        ns.CaveRenderer:ApplyAlpha()
                    end,
                },
            },
        },
        hint = {
            order = 200,
            type = "description",
            name = function() return "\n" .. ChatCommandHint() end,
        },
    },
}
-- Zone/World/Continent Map dropdowns, one per Config.MAP_TYPES entry,
-- stacked vertically (each row: a relWidth 0.32 dropdown, then whatever
-- else belongs on its right). Built with a loop so the order/name/desc/
-- get/set/width wiring can't drift between them.
--
-- AceConfigDialog flows widgets left to right and wraps when one doesn't
-- fit, so a row is forced to end by padding it past 0.68 of the width with
-- a blank description -- otherwise the next dropdown would slide up beside
-- this one. Replace the filler with real widgets as the right-hand side
-- fills up; just keep each row's relWidths summing to 0.9-0.99.
--
-- Display order top to bottom is Zone, World, Continent -- Continent last
-- rather than in Config.MAP_TYPES' own zone/continent/world order, which
-- stays as-is since other code reads it independently of how Options lays
-- these out.
local MAP_TYPE_ORDER = { zone = 20, world = 30, continent = 40 }
local mapBackgroundArgs = options.args.mapBackground.args
for _, mapType in ipairs(Config.MAP_TYPES) do
    local desc = "Which background " .. mapType.label .. " draws with, "
        .. "or \"Use Global\" to just follow the Global Background above."
    local isZone = mapType.key == "zone"
    if isZone then
        -- The "little info section that pops up": AceConfig shows every
        -- option's own `desc` as a hover tooltip, so this is that tooltip
        -- rather than a separate widget. Config:FogOfWarEnabled() enforces
        -- the same Hybrid-only rule in code.
        desc = desc .. "\n\nFog of War is only supported while this ends "
            .. "up Hybrid -- set directly, or by leaving this on \"Use "
            .. "Global\" while the Global Background is Hybrid. The Fog "
            .. "of War checkbox appears beside it while that's the case."
    end
    local order = MAP_TYPE_ORDER[mapType.key]
    mapBackgroundArgs["mapType_" .. mapType.key] = {
        order = order,
        type = "select",
        width = "relative",
        relWidth = 0.32,
        name = mapType.label,
        desc = desc,
        values = MapTypeBackgroundValues,
        get = function() return Config:GetMapTypeBackgroundKey(mapType.key) end,
        set = function(_, value)
            Config:SetMapTypeBackground(mapType.key, value)
        end,
    }
    -- Every row gets a filler; the Zone one yields to the Fog of War
    -- checkbox (order + 1, added below) while Zone Map is Hybrid.
    mapBackgroundArgs["mapTypeFill_" .. mapType.key] = {
        order = order + 2,
        type = "description",
        name = " ",
        width = "relative",
        relWidth = mapType.key == "world" and 0.33 or 0.65,
        hidden = isZone and ZoneIsHybrid or nil,
    }
end
mapBackgroundArgs.fogOfWarEnabled = {
    order = MAP_TYPE_ORDER.zone + 1,
    type = "toggle",
    width = "relative",
    relWidth = 0.3,
    name = "Fog of War",
    desc = "Brings back the grayscale fog over unexplored ground. Off by "
        .. "default. Only shown while the Zone Map background is Hybrid, "
        .. "either directly or by inheriting a Hybrid Global Background "
        .. "-- that grayscale look IS Blizzard's own map art, which only "
        .. "Hybrid leaves showing through.",
    -- Hidden, not disabled: a saved "on" picks back up by itself once Zone
    -- Map is Hybrid again, because Config:FogOfWarEnabled() checks the
    -- background too.
    hidden = function() return not ZoneIsHybrid() end,
    get = function() return Config.db.fogOfWarEnabled end,
    set = function(_, value)
        Config.db.fogOfWarEnabled = value
        ns.Renderer:ForceRefresh()
    end,
}
-- World Map's neighbour: Kalimdor / Eastern Kingdoms / Azeroth resolution.
-- Stored as the boolean Config.db.worldMapClarity (also driven by `/hfwm
-- clarity`), so "high" is true and "low" is false (the default).
mapBackgroundArgs.worldMapClarity = {
    order = MAP_TYPE_ORDER.world + 1,
    type = "select",
    width = "relative",
    relWidth = 0.32,
    name = "Map Resolution",
    desc = "How sharply Kalimdor, Eastern Kingdoms and Azeroth are drawn. "
        .. "High Resolution draws them at much higher detail but may "
        .. "render slower. Low Resolution is the default.",
    values = { high = "High Resolution (slow)", low = "Low Resolution (fast)" },
    sorting = { "high", "low" },
    get = function() return Config.db.worldMapClarity and "high" or "low" end,
    set = function(_, value)
        Config.db.worldMapClarity = (value == "high")
        ns.Renderer:ForceRefresh()
    end,
}
-- Pads the Hybrid-only Zone row (0.32 + 0.3 + 0.3) past the wrap point.
mapBackgroundArgs.fogFill = {
    order = MAP_TYPE_ORDER.zone + 2,
    type = "description",
    name = " ",
    width = "relative",
    relWidth = 0.3,
    hidden = function() return not ZoneIsHybrid() end,
}

Options.optionsTable = options

--- Register the options table and hook it into the client's own options
--- UI. Safe to call more than once.
function Options:Init()
    if not options.args.profiles then
        options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(
            Config.dbObj)
        options.args.profiles.order = 100
    end

    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable(addonName, options)

    local AceConfigDialog = LibStub("AceConfigDialog-3.0")
    self.clientRegistered = pcall(
        AceConfigDialog.AddToBlizOptions, AceConfigDialog,
        addonName, PANEL_TITLE)
end

--- Open the options, wherever they ended up living.
function Options:Open()
    LibStub("AceConfigDialog-3.0"):Open(addonName)
end

--- Push a live setting change (from a slash command, say) out to any open
--- options window. Safe to call whether or not one is open.
function Options:Refresh()
    LibStub("AceConfigRegistry-3.0"):NotifyChange(addonName)
end
