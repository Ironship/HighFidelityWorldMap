-------------------------------------------------------------------------------
-- HFWM-Forever Options
-- The options panel, as an AceConfig-3.0 table: enable toggle, map
-- background, opacity, remember/zoom/clarity/fog toggles, the cave map
-- section, and a profiles tab (AceDBOptions-3.0).
--
-- AceConfigDialog handles the rest: registering into the client's Interface
-- Options (AddToBlizOptions) and drawing the standalone window /hfwm
-- options opens, across every client flavour this addon supports.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Options = ns.Options
local Config  = ns.Config

local PANEL_TITLE = "High Fidelity World Map Forever"

--- {key = label} for every background this install can actually draw.
local function BackgroundValues()
    local values = {}
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
        mapBackground = {
            order = 20,
            type = "select",
            name = "Map background",
            desc = function() return Config:GetBackground().desc end,
            values = BackgroundValues,
            get = function() return Config:GetBackground().key end,
            set = function(_, value) Config:SetBackground(value) end,
        },
        alpha = {
            order = 30,
            type = "range",
            name = "Opacity",
            desc = "Overlay opacity.",
            min = 0, max = 1, step = 0.05, isPercent = true,
            get = function() return Config.db.alpha end,
            set = function(_, value)
                Config.db.alpha = value
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
        worldMapClarity = {
            order = 60,
            type = "toggle",
            name = "Increase world map clarity",
            desc = "Draws Kalimdor, Eastern Kingdoms and Azeroth at much "
                .. "higher detail. May render slower. Off by default.",
            get = function() return Config.db.worldMapClarity end,
            set = function(_, value)
                Config.db.worldMapClarity = value
                ns.Renderer:ForceRefresh()
            end,
        },
        fogOfWarEnabled = {
            order = 70,
            type = "toggle",
            name = "Fog of War",
            desc = "Brings back the grayscale fog over unexplored ground. "
                .. "Off by default.",
            get = function() return Config.db.fogOfWarEnabled end,
            set = function(_, value)
                Config.db.fogOfWarEnabled = value
                ns.Renderer:ForceRefresh()
            end,
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
