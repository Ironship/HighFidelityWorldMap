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
        .. "  |  /hfwm cave on|off|autoopen|remember|indoors  |  /hfwm remember on|off"
        .. "  |  /hfwm zoom on|off  |  /hfwm clarity on|off  |  /hfwm fog on|off"
end

--- Fog of War only works over Blizzard's own art, which only Hybrid leaves
--- showing. Each map type's checkbox is disabled (not hidden) otherwise,
--- with the reason appended to its tooltip.
local function NotHybrid(mapTypeKey)
    return function() return not Config:MapTypeBackgroundIsHybrid(mapTypeKey) end
end
local HYBRID_ONLY = "\n\n|cffff8800Fog of War is only supported with the "
    .. "Hybrid background type.|r"
local function FogDesc(base, mapTypeKey)
    return function()
        return Config:MapTypeBackgroundIsHybrid(mapTypeKey) and base
            or base .. HYBRID_ONLY
    end
end
local FOG_ZONE_DESC = "Brings back the grayscale fog over unexplored ground. "
    .. "Off by default. That grayscale look IS Blizzard's own map art, "
    .. "which only Hybrid leaves showing through."
local FOG_WORLD_DESC = "On the World map, only draws this addon's map over "
    .. "zones you have fully explored. A zone with any area still "
    .. "undiscovered stays as the game draws it."
local FOG_CONTINENT_DESC = "On the Continent maps, only draws this addon's "
    .. "map over zones you have fully explored. A zone with any area still "
    .. "undiscovered stays as the game draws it."

--- High Resolution World and continent maps come from the optional Art
--- addon. Without it that one Map Resolution entry is disabled (everything
--- else, low resolution included, ships with this addon) and explains why.
local ART_URL = "https://www.curseforge.com/wow/addons/high-fidelity-world-map-art"
local ART_NOTE = "Requires the High Fidelity World Map: Art addon, which is "
    .. "not installed or not enabled. Install it and reload the UI to "
    .. "unlock it."

-- The game can't open a browser, so the link goes in a popup's edit box,
-- selected for Ctrl+C. Edits are undone so it stays copy-only.
StaticPopupDialogs["HFWM_ART_URL"] = {
    text = "High Resolution needs the High Fidelity World Map: Art addon.\n"
        .. "Copy this link (Ctrl+C) and open it in your browser:",
    button1 = CLOSE,
    hasEditBox = true,
    editBoxWidth = 350,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self)
        self:SetFrameStrata("TOOLTIP")  -- above the options window
        local box = self.EditBox or self.editBox
        box:SetText(ART_URL)
        box:HighlightText()
        box:SetFocus()
    end,
    EditBoxOnTextChanged = function(box)
        if box:GetText() ~= ART_URL then
            box:SetText(ART_URL)
            box:HighlightText()
        end
    end,
    EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
}

--- Dropdown that disables its "high" entry, with a tooltip saying why,
--- while the Art addon is missing. AceConfig has no per-entry disable, so
--- the Map Resolution row asks for this through `dialogControl`.
local RESOLUTION_DROPDOWN = "HFWM-ResolutionDropdown"
do
    local AceGUI = LibStub("AceGUI-3.0")

    local function ShowArtTooltip(item)
        GameTooltip:SetOwner(item.frame, "ANCHOR_RIGHT")
        GameTooltip:SetText("High Resolution unavailable", 1, 1, 1)
        GameTooltip:AddLine(ART_NOTE, 1, 0.53, 0, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to show the CurseForge link for the Art addon.",
            0, 1, 1, true)
        GameTooltip:Show()
    end

    AceGUI:RegisterWidgetType(RESOLUTION_DROPDOWN, function()
        local dropdown = AceGUI.WidgetRegistry.Dropdown()
        dropdown.type = RESOLUTION_DROPDOWN  -- own pool, not Dropdown's
        local setList = dropdown.SetList
        function dropdown:SetList(...)
            setList(self, ...)
            if Config:IsArtInstalled() then return end
            for _, item in self.pullout:IterateItems() do
                if item.userdata.value == "high" then
                    item:SetDisabled(true)
                    item:SetCallback("OnEnter", ShowArtTooltip)
                    item:SetCallback("OnLeave", function() GameTooltip:Hide() end)
                    item.hfwmArt = true
                    -- A disabled item's own OnClick is skipped by AceGUI, so
                    -- hook the frame; hfwmArt/disabled stop pooled items
                    -- reused elsewhere from opening it.
                    if not item.frame.hfwmArtHooked then
                        item.frame.hfwmArtHooked = true
                        item.frame:HookScript("OnClick", function(frame)
                            local it = frame.obj
                            if it.hfwmArt and it.disabled then
                                GameTooltip:Hide()
                                it.pullout:Close()
                                StaticPopup_Show("HFWM_ART_URL")
                            end
                        end)
                    end
                end
            end
        end
        return dropdown
    end, 1)
end

--- Checkbox that keeps its tooltip while disabled. The stock one calls
--- frame:Disable(), after which this client sends no OnEnter, so the "only
--- supported with Hybrid" tooltip never showed. AceGUI's click handlers
--- already ignore clicks while `self.disabled`, so re-enabling the frame
--- only restores mouse-over.
local FOG_CHECKBOX = "HFWM-FogCheckBox"
do
    local AceGUI = LibStub("AceGUI-3.0")
    AceGUI:RegisterWidgetType(FOG_CHECKBOX, function()
        local checkbox = AceGUI.WidgetRegistry.CheckBox()
        checkbox.type = FOG_CHECKBOX  -- own pool, not CheckBox's
        local setDisabled = checkbox.SetDisabled
        function checkbox:SetDisabled(disabled)
            setDisabled(self, disabled)
            self.frame:Enable()
        end
        return checkbox
    end, 1)
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
            name = "Enable",
            desc = "Enables High Fidelity World Map",
            get = function() return Config.db.enabled end,
            set = function(_, value)
                Config.db.enabled = value
                ns.Renderer:ForceRefresh()
                ns.ToggleButton:Refresh()
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
        keepCentered = {
            order = 55,
            type = "toggle",
            name = "Keep Centered",
            desc = "Pans the world map as you move so your arrow stays "
                .. "in the center of it. Off by default.",
            get = function() return Config.db.keepCentered end,
            set = function(_, value)
                Config.db.keepCentered = value
                ns.KeepCentered:Refresh()
            end,
        },
        disableMapFade = {
            order = 56,
            type = "toggle",
            name = "Disable map fade",
            desc = "Stops the world map going see-through while you "
                .. "move (the mapFade console variable). Reads and "
                .. "writes the game setting directly; turning this off "
                .. "sets mapFade back to 1.",
            get = function() return _G.GetCVar("mapFade") == "0" end,
            set = function(_, value)
                _G.SetCVar("mapFade", value and "0" or "1")
            end,
        },

        toggleButtonEnabled = {
            order = 72,
            type = "toggle",
            name = "HD/SD map toggle button",
            desc = "Adds a small button to the world map's top-right "
                .. "corner for switching between the high-fidelity "
                .. "overlay and Blizzard's own map, just for the current "
                .. "map session -- it does not touch \"Enable\" "
                .. "above, so the cave map and everything else "
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
                    disabled = function() return not (Config.db.enabled and Config.db.caveEnabled) end,
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
                    disabled = function() return not (Config.db.enabled and Config.db.caveEnabled) end,
                    get = function() return Config.db.caveRememberState end,
                    set = function(_, value)
                        Config.db.caveRememberState = value
                    end,
                },
                caveKeepOpen = {
                    order = 35,
                    type = "toggle",
                    name = "Keep open",
                    desc = "Keeps the cave map open on its own when you "
                        .. "close the world map.",
                    disabled = function() return not (Config.db.enabled and Config.db.caveEnabled) end,
                    get = function() return Config.db.caveKeepOpen end,
                    set = function(_, value)
                        Config.db.caveKeepOpen = value
                        -- Re-parent an already-open window now.
                        ns.CaveRenderer:Relayout()
                    end,
                },
                caveOtherIndoors = {
                    order = 37,
                    type = "toggle",
                    name = "Other indoors",
                    desc = "Also opens the cave map inside buildings, "
                        .. "houses and every other indoor area, not just "
                        .. "caves, mines and dungeons.",
                    disabled = function() return not (Config.db.enabled and Config.db.caveEnabled) end,
                    get = function() return Config.db.caveOtherIndoors end,
                    set = function(_, value)
                        Config.db.caveOtherIndoors = value
                        ns.Cave:Unsuppress()
                        ns.Cave:UpdateState()
                    end,
                },
                caveAlpha = {
                    order = 40,
                    type = "range",
                    name = "Cave map opacity",
                    desc = "Opacity of the cave map window background. At 0% only the border and map elements are visible.",
                    min = 0, max = 1, step = 0.05, isPercent = true,
                    disabled = function() return not (Config.db.enabled and Config.db.caveEnabled) end,
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
end
mapBackgroundArgs.fogOfWarEnabled = {
    order = MAP_TYPE_ORDER.zone + 1,
    type = "toggle",
    width = "relative",
    relWidth = 0.3,
    name = "Fog of War",
    desc = FogDesc(FOG_ZONE_DESC, "zone"),
    -- Disabled, not hidden: a saved "on" picks back up by itself once Zone
    -- Map is Hybrid again, because Config:FogOfWarEnabled() checks the
    -- background too.
    disabled = NotHybrid("zone"),
    dialogControl = FOG_CHECKBOX,
    get = function() return Config.db.fogOfWarEnabled end,
    set = function(_, value)
        Config.db.fogOfWarEnabled = value
        ns.Renderer:ForceRefresh()
    end,
}
-- World/Continent Map's neighbour: Kalimdor / Eastern Kingdoms / Azeroth
-- resolution, one saved boolean per map type (Config.db.worldMapClarity /
-- continentMapClarity; `/hfwm clarity` sets both), so "high" is true and
-- "low" is false (the default).
local function ResolutionOption(mapTypeKey, dbKey, what)
    return {
        order = MAP_TYPE_ORDER[mapTypeKey] + 1,
        type = "select",
        width = "relative",
        relWidth = 0.32,
        name = "Map Resolution",
        desc = "How sharply " .. what .. " drawn. High Resolution draws "
            .. "at much higher detail but may render slower. Low Resolution "
            .. "is the default.",
        dialogControl = RESOLUTION_DROPDOWN,
        values = { high = "High Resolution (slow)", low = "Low Resolution (fast)" },
        sorting = { "high", "low" },
        get = function() return Config:MapClarityEnabled(mapTypeKey) and "high" or "low" end,
        set = function(_, value)
            Config.db[dbKey] = (value == "high")
            ns.ZoomLevels:Refresh()
            ns.Renderer:ForceRefresh()
        end,
    }
end
mapBackgroundArgs.worldMapClarity =
    ResolutionOption("world", "worldMapClarity", "Azeroth is")
mapBackgroundArgs.continentMapClarity =
    ResolutionOption("continent", "continentMapClarity",
        "Kalimdor and Eastern Kingdoms are")
-- World Map's second neighbour, between it and Map Resolution: the World
-- Map version of Fog of War. Same rule as the Zone one, but keyed to the
-- World Map's own background and its own saved value;
-- Config:WorldFogOfWarEnabled() enforces the rule in code, and a saved "on"
-- picks back up when it holds.
mapBackgroundArgs.worldFogOfWar = {
    order = MAP_TYPE_ORDER.world + 0.5,
    type = "toggle",
    width = "relative",
    relWidth = 0.3,
    name = "Fog of War",
    desc = FogDesc(FOG_WORLD_DESC, "world"),
    disabled = NotHybrid("world"),
    dialogControl = FOG_CHECKBOX,
    get = function() return Config.db.worldFogOfWar end,
    set = function(_, value)
        Config.db.worldFogOfWar = value
        ns.Renderer:ForceRefresh()
    end,
}
-- Continent Map's own Fog of War, same rule, separate saved value.
mapBackgroundArgs.continentFogOfWar = {
    order = MAP_TYPE_ORDER.continent + 0.5,
    type = "toggle",
    width = "relative",
    relWidth = 0.3,
    name = "Fog of War",
    desc = FogDesc(FOG_CONTINENT_DESC, "continent"),
    disabled = NotHybrid("continent"),
    dialogControl = FOG_CHECKBOX,
    get = function() return Config.db.continentFogOfWar end,
    set = function(_, value)
        Config.db.continentFogOfWar = value
        ns.Renderer:ForceRefresh()
    end,
}
-- Pads the Zone row (0.32 + 0.3 + 0.3) like the other rows' two selects.
mapBackgroundArgs.fogFill = {
    order = MAP_TYPE_ORDER.zone + 2,
    type = "description",
    name = " ",
    width = "relative",
    relWidth = 0.3,
}
-- Everything but the Enable toggle (and the intro text) greys out while the
-- addon is off. `disabled` is inherited, but the deepest definition wins, so
-- the cave children (which have their own) repeat the check above, and the
-- Fog of War toggles' own Hybrid-only rule is combined in here.
-- Profiles is added later in Init, so it stays usable.
for key, option in pairs(options.args) do
    if key ~= "enabled" and key ~= "intro" then
        option.disabled = function() return not Config.db.enabled end
    end
end
for key, option in pairs(mapBackgroundArgs) do
    if option.disabled then
        local notHybrid = option.disabled
        option.disabled = function() return not Config.db.enabled or notHybrid() end
    end
end

Options.optionsTable = options

local LOGO = "Interface\\AddOns\\" .. addonName .. "\\Assets\\logo_lowres.dxt5.blp"

--- Replace the panel's title text with the logo (512x128 source, shown at 4:1).
--- Title is hidden via alpha, not cleared: AceConfigDialog re-sets its text
--- on every redraw.
local function ShowLogo(frame)
    frame.obj.label:SetAlpha(0)
    local logo = frame:CreateTexture(nil, "OVERLAY")
    logo:SetTexture(LOGO)
    logo:SetSize(144, 36)
    logo:SetPoint("TOPLEFT", 10, -4)
end

--- Register the options table and hook it into the client's own options
--- UI. Safe to call more than once.
function Options:Init()
    if not options.args.profiles then
        options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(
            Config.dbObj)
        options.args.profiles.order = 100
        -- Inline: with no tab/tree child groups AceConfigDialog wraps the
        -- whole page in one ScrollFrame, instead of squeezing a tree
        -- under the settings above.
        options.args.profiles.inline = true
    end

    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable(addonName, options)

    local AceConfigDialog = LibStub("AceConfigDialog-3.0")
    -- Standalone window only; the client's options panel sets its own size.
    AceConfigDialog:SetDefaultSize(addonName, 700, 650)
    local ok, blizFrame = pcall(
        AceConfigDialog.AddToBlizOptions, AceConfigDialog,
        addonName, PANEL_TITLE)
    self.clientRegistered = ok
    if ok and blizFrame then ShowLogo(blizFrame) end
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
