-------------------------------------------------------------------------------
-- HFWM-Forever Options
-- The options panel: enable toggle, map-background dropdown, opacity slider,
-- and the cave-map section (on/off plus its own opacity).
--
-- Registered into the client's own AddOns options list where an API for that
-- exists, and openable as a standalone window either way (/hfwm options).
-- The registration APIs differ by flavour and this addon is pinned to a beta
-- client, so every one of them is probed rather than assumed; the standalone
-- window is the fallback that cannot break.
--
-- The background selector is the client's own settings dropdown. Which one
-- that is depends on the flavour, so all of them are tried in turn, newest
-- first: the Settings-panel dropdown (WowStyle1DropdownTemplate, driven by a
-- menu generator), then the long-lived UIDropDownMenuTemplate, and only if
-- neither exists a hand-built widget dressed to match. Every path exposes the
-- same two methods to the panel, Sync() and CloseMenu(), so the rest of this
-- file does not care which one it got.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Options = ns.Options
local Config  = ns.Config
local P       = ns.P

local PANEL_TITLE = "High Fidelity World Map Forever"

-------------------------------------------------------------------------------
-- Small widget helpers
-------------------------------------------------------------------------------

--- Flat dark panel with a 1px border, used for the dropdown and its menu.
local function StyleBox(frame, r, g, b, a)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(r or 0.06, g or 0.06, b or 0.07, a or 0.95)

    for _, edge in ipairs({
        { "TOPLEFT", "TOPRIGHT", 0, 0, nil, 1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 0, nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 0, 0, 1, nil },
        { "TOPRIGHT", "BOTTOMRIGHT", 0, 0, 1, nil },
    }) do
        local line = frame:CreateTexture(nil, "BORDER")
        line:SetColorTexture(0.35, 0.35, 0.38, 1)
        line:SetPoint(edge[1], frame, edge[1])
        line:SetPoint(edge[2], frame, edge[2])
        if edge[5] then line:SetWidth(edge[5]) end
        if edge[6] then line:SetHeight(edge[6]) end
    end
    return bg
end

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK",
        font or "GameFontHighlight")
    fs:SetText(text)
    return fs
end

--- CreateFrame against the first template that actually exists.
--- CreateFrame *errors* on an unknown template rather than returning nil, and
--- which FrameXML templates a given flavour ships is exactly the sort of thing
--- this build cannot be asked about, so each candidate is tried in turn and
--- the last resort is no template at all.
local function CreateFrameTry(kind, name, parent, ...)
    for i = 1, select("#", ...) do
        local template = select(i, ...)
        local ok, frame = pcall(CreateFrame, kind, name, parent, template)
        if ok and frame then return frame, template end
    end
    return CreateFrame(kind, name, parent), nil
end

--- Resolve a widget's named sub-element across naming conventions: modern
--- clients attach it as a field, older ones only create the $parentFoo global.
local function SubElement(frame, name, field)
    if frame[field] then return frame[field] end
    local frameName = frame.GetName and frame:GetName()
    if frameName then return _G[frameName .. name] end
    return nil
end

-------------------------------------------------------------------------------
-- Background dropdown
--
-- Three implementations of one widget, tried newest first. Each returns a
-- frame carrying:
--
--   Sync()      -- pull the displayed selection back from the SavedVariables
--   CloseMenu() -- shut the list, for when the panel is hidden under it
--   inset       -- x nudge the caller should apply so the widget's *visible*
--                  left edge lines up with the label above it. The Settings
--                  dropdown and our own are flush (0); UIDropDownMenuTemplate
--                  pads its frame well past its artwork.
--
-- Selecting a background writes it through Config:SetBackground, which also
-- forces the redraw, so the chat command and the dropdown cannot disagree.
-------------------------------------------------------------------------------

local DROPDOWN_WIDTH = 220

--- The modern Settings dropdown: a DropdownButton whose list is described by
--- a generator rather than built button by button. Both the frame type and
--- the template postdate most flavours, so the whole construction is pcalled.
local function TrySettingsDropdown(parent)
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent,
        "WowStyle1DropdownTemplate")
    if not ok or not dd or not dd.SetupMenu then return nil end

    local setup = pcall(dd.SetupMenu, dd, function(_, rootDescription)
        for _, bg in ipairs(Config:AvailableBackgrounds()) do
            local radio = rootDescription:CreateRadio(
                bg.label,
                function(key) return Config:GetBackground().key == key end,
                function(key)
                    Config:SetBackground(key)
                    if Options.panel then Options:Refresh() end
                end,
                bg.key)
            -- SetTooltip is newer than the template itself on some builds.
            if radio and radio.SetTooltip then
                pcall(radio.SetTooltip, radio, function(tooltip)
                    if GameTooltip_SetTitle then
                        GameTooltip_SetTitle(tooltip, bg.label)
                        GameTooltip_AddNormalLine(tooltip, bg.desc)
                    end
                end)
            end
        end
    end)
    if not setup then return nil end

    dd:SetWidth(DROPDOWN_WIDTH)
    dd.inset = 0
    -- Captured before we shadow it: the mixin has a CloseMenu of its own and
    -- assigning ours over the top would otherwise call itself forever.
    local mixinClose = dd.CloseMenu
    dd.Sync = function()
        local active = Config:GetBackground()
        -- The generator already names the checked radio, but say it outright:
        -- /hfwm bg changes the setting without the menu ever being opened.
        if dd.OverrideText then
            pcall(dd.OverrideText, dd, active.label)
        elseif dd.SetText then
            pcall(dd.SetText, dd, active.label)
        end
        if dd.Update then pcall(dd.Update, dd) end
    end
    dd.CloseMenu = function()
        if mixinClose then pcall(mixinClose, dd) end
        if CloseMenus then pcall(CloseMenus) end
    end
    return dd, "WowStyle1DropdownTemplate"
end

--- UIDropDownMenuTemplate: the settings dropdown every flavour from vanilla
--- through Dragonflight uses, and still present alongside the new one.
local function TryLegacyDropdown(parent)
    if not (UIDropDownMenu_Initialize and UIDropDownMenu_CreateInfo
            and UIDropDownMenu_AddButton and UIDropDownMenu_SetText) then
        return nil
    end
    local ok, dd = pcall(CreateFrame, "Frame", "HFWMForeverBackgroundDropdown",
        parent, "UIDropDownMenuTemplate")
    if not ok or not dd then return nil end

    local built = pcall(UIDropDownMenu_Initialize, dd, function(_, level)
        for _, bg in ipairs(Config:AvailableBackgrounds()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text            = bg.label
            info.value           = bg.key
            info.checked         = (Config:GetBackground().key == bg.key)
            info.tooltipTitle    = bg.label
            info.tooltipText     = bg.desc
            info.tooltipOnButton = true
            info.func = function()
                Config:SetBackground(bg.key)
                if Options.panel then Options:Refresh() end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    if not built then
        dd:Hide()
        return nil
    end

    if UIDropDownMenu_SetWidth then
        pcall(UIDropDownMenu_SetWidth, dd, DROPDOWN_WIDTH - 40)
    end
    -- The template's frame is ~15px wider than its artwork on each side, and
    -- its text starts inside that. Nudge left so the closed widget lines up
    -- with the heading above it.
    dd.inset = -16
    dd.Sync = function()
        UIDropDownMenu_SetText(dd, Config:GetBackground().label)
    end
    dd.CloseMenu = function()
        if CloseDropDownMenus then pcall(CloseDropDownMenus) end
    end
    return dd, "UIDropDownMenuTemplate"
end

--- Last resort: a dropdown of our own, for a client that ships neither
--- template. Dressed to sit quietly next to the rest of the panel rather than
--- to imitate artwork we cannot load.
local function BuildOwnDropdown(parent)
    local dd = CreateFrame("Button", nil, parent)
    dd:SetSize(DROPDOWN_WIDTH, 24)
    StyleBox(dd)

    local text = Label(dd, "", "GameFontHighlight")
    text:SetPoint("LEFT", dd, "LEFT", 8, 0)
    text:SetPoint("RIGHT", dd, "RIGHT", -22, 0)
    text:SetJustifyH("LEFT")

    local arrow = dd:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    arrow:SetPoint("RIGHT", dd, "RIGHT", -7, -1)
    arrow:SetText("v")

    -- The menu. Parented to UIParent at a high strata so it is never clipped
    -- by whichever container the panel ends up inside.
    local menu = CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetToplevel(true)
    menu:Hide()
    StyleBox(menu, 0.04, 0.04, 0.05, 0.98)

    local rows = {}
    local ROW_H = 22

    local function Close()
        menu:Hide()
        arrow:SetText("v")
    end

    local function Sync()
        local active = Config:GetBackground()
        text:SetText(active.label)
        for _, row in ipairs(rows) do
            local on = row.bg.key == active.key
            row.label:SetText((on and "|cff33ccff" or "|cffffffff")
                .. row.bg.label .. "|r")
            row.check:SetShown(on)
        end
    end

    for i, bg in ipairs(Config:AvailableBackgrounds()) do
        local row = CreateFrame("Button", nil, menu)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -(1 + (i - 1) * ROW_H))
        row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, -(1 + (i - 1) * ROW_H))

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(row)
        hl:SetColorTexture(0.2, 0.4, 0.6, 0.45)

        local check = Label(row, "|cff33ccff*|r", "GameFontNormal")
        check:SetPoint("LEFT", row, "LEFT", 6, 0)

        local label = Label(row, bg.label, "GameFontHighlight")
        label:SetPoint("LEFT", row, "LEFT", 18, 0)

        row.bg, row.label, row.check = bg, label, check
        row:SetScript("OnClick", function()
            Config:SetBackground(bg.key)
            Sync()
            Close()
            if Options.panel then Options:Refresh() end
        end)
        row:SetScript("OnEnter", function()
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(bg.label, 1, 1, 1)
            GameTooltip:AddLine(bg.desc, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[#rows + 1] = row
    end

    menu:SetSize(DROPDOWN_WIDTH, #rows * ROW_H + 2)

    dd:SetScript("OnClick", function()
        if menu:IsShown() then
            Close()
        else
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
            menu:SetWidth(dd:GetWidth())
            Sync()
            menu:Show()
            arrow:SetText("^")
        end
    end)

    -- Click-away close: the menu is a plain frame, so nothing dismisses it
    -- for us.
    menu:SetScript("OnShow", function()
        if not menu._closer then
            menu._closer = CreateFrame("Button", nil, UIParent)
            menu._closer:SetAllPoints(UIParent)
            menu._closer:SetFrameStrata("FULLSCREEN")
            menu._closer:SetScript("OnClick", Close)
        end
        menu._closer:Show()
    end)
    menu:SetScript("OnHide", function()
        if menu._closer then menu._closer:Hide() end
    end)

    dd.inset = 0
    dd.Sync = Sync
    dd.CloseMenu = Close
    return dd, "hand-built"
end

--- Whichever of the three this client can give us.
local function CreateBackgroundDropdown(parent)
    local dd, kind = TrySettingsDropdown(parent)
    if not dd then dd, kind = TryLegacyDropdown(parent) end
    if not dd then dd, kind = BuildOwnDropdown(parent) end
    Options.dropdownKind = kind
    return dd
end

-------------------------------------------------------------------------------
-- Panel contents
--
-- Built once into a container frame, which is then either parented into the
-- client's options canvas or into our own window.
-------------------------------------------------------------------------------

function Options:BuildPanel()
    if self.panel then return self.panel end

    local panel = CreateFrame("Frame")
    panel.name = PANEL_TITLE
    panel:SetSize(560, 450)
    panel:Hide()

    local title = Label(panel, PANEL_TITLE, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)

    local sub = Label(panel,
        "|cff999999Satellite world map stitched from the game's own minimap "
        .. "terrain tiles.|r", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

    -- Enable
    local enable = CreateFrameTry("CheckButton", "HFWMForeverEnableCheck",
        panel, "InterfaceOptionsCheckButtonTemplate", "UICheckButtonTemplate")
    enable:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", -2, -16)
    enable:SetSize(26, 26)
    local enableText = enable.Text or enable.text
        or SubElement(enable, "Text", "Text")
    if enableText then
        enableText:SetText("Enable the overlay")
    else
        enableText = Label(panel, "Enable the overlay", "GameFontHighlight")
        enableText:SetPoint("LEFT", enable, "RIGHT", 2, 0)
    end
    enable:SetScript("OnClick", function(btn)
        Config.db.enabled = btn:GetChecked() and true or false
        ns.Renderer:ForceRefresh()
        Options:Refresh()
    end)

    -- Background dropdown
    local bgLabel = Label(panel, "Map background", "GameFontNormal")
    bgLabel:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 2, -18)

    local dropdown = CreateBackgroundDropdown(panel)
    dropdown:SetPoint("TOPLEFT", bgLabel, "BOTTOMLEFT",
        dropdown.inset or 0, -6)

    local bgDesc = Label(panel, "", "GameFontHighlightSmall")
    bgDesc:SetPoint("TOPLEFT", bgLabel, "BOTTOMLEFT", 2,
        -6 - (dropdown:GetHeight() or 24) - 8)
    bgDesc:SetWidth(500)
    bgDesc:SetJustifyH("LEFT")

    -- Opacity
    local slider = CreateFrameTry("Slider", "HFWMForeverAlphaSlider", panel,
        "OptionsSliderTemplate", "UISliderTemplate")
    slider:SetPoint("TOPLEFT", bgDesc, "BOTTOMLEFT", 0, -34)
    slider:SetWidth(220)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(0, 1)
    slider:SetValueStep(0.05)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end

    local low  = SubElement(slider, "Low", "Low")
    local high = SubElement(slider, "High", "High")
    local sliderText = SubElement(slider, "Text", "Text")
    if low then low:SetText("0%") end
    if high then high:SetText("100%") end
    if not sliderText then
        sliderText = Label(panel, "", "GameFontNormal")
        sliderText:SetPoint("BOTTOM", slider, "TOP", 0, 2)
    end
    slider.textLabel = sliderText

    slider:SetScript("OnValueChanged", function(self, value)
        if self._syncing then return end
        Config.db.alpha = math.max(0, math.min(1, value))
        self.textLabel:SetText(
            ("Opacity: %d%%"):format(Config.db.alpha * 100))
        ns.Renderer:ForceRefresh()
    end)

    -- Cave map
    --
    -- Its own heading rather than another line of checkboxes at the top: it
    -- is a separate window with its own behaviour, not a variation on how the
    -- world map is drawn, and grouping it with the background options would
    -- suggest otherwise.
    local caveHeading = Label(panel, "Cave map", "GameFontNormal")
    caveHeading:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -30)

    local caveCheck = CreateFrameTry("CheckButton", "HFWMForeverCaveCheck",
        panel, "InterfaceOptionsCheckButtonTemplate", "UICheckButtonTemplate")
    caveCheck:SetPoint("TOPLEFT", caveHeading, "BOTTOMLEFT", -4, -6)
    caveCheck:SetSize(26, 26)
    local caveCheckText = caveCheck.Text or caveCheck.text
        or SubElement(caveCheck, "Text", "Text")
    if caveCheckText then
        caveCheckText:SetText("Show a cave map when I'm indoors")
    else
        caveCheckText = Label(panel, "Show a cave map when I'm indoors",
            "GameFontHighlight")
        caveCheckText:SetPoint("LEFT", caveCheck, "RIGHT", 2, 0)
    end
    caveCheck:SetScript("OnClick", function(btn)
        Config.db.caveEnabled = btn:GetChecked() and true or false
        if Config.db.caveEnabled then
            -- Same qualification as /hfwm cave on: on a client with no
            -- interior maps the checkbox going green would otherwise be the
            -- only feedback the user ever gets.
            ns.Cave:WarnIfUnsupported()
            ns.Cave:Unsuppress()
            ns.Cave:UpdateState()
        else
            ns.CaveRenderer:HideCave()
        end
        Options:Refresh()
    end)

    local caveDesc = Label(panel,
        "|cff999999Caves, mines and dungeon interiors have their own map, "
        .. "which the zone map above them cannot show. With this on, walking "
        .. "into one opens a small window over the world map — draggable, "
        .. "closable, with a depth slider for multi-level dungeons.|r",
        "GameFontHighlightSmall")
    caveDesc:SetPoint("TOPLEFT", caveCheck, "BOTTOMLEFT", 6, -2)
    caveDesc:SetWidth(500)
    caveDesc:SetJustifyH("LEFT")

    local caveSlider = CreateFrameTry("Slider", "HFWMForeverCaveAlphaSlider",
        panel, "OptionsSliderTemplate", "UISliderTemplate")
    caveSlider:SetPoint("TOPLEFT", caveDesc, "BOTTOMLEFT", -6, -28)
    caveSlider:SetWidth(220)
    caveSlider:SetOrientation("HORIZONTAL")
    caveSlider:SetMinMaxValues(0.2, 1)
    caveSlider:SetValueStep(0.05)
    if caveSlider.SetObeyStepOnDrag then caveSlider:SetObeyStepOnDrag(true) end

    local caveLow  = SubElement(caveSlider, "Low", "Low")
    local caveHigh = SubElement(caveSlider, "High", "High")
    local caveSliderText = SubElement(caveSlider, "Text", "Text")
    if caveLow then caveLow:SetText("20%") end
    if caveHigh then caveHigh:SetText("100%") end
    if not caveSliderText then
        caveSliderText = Label(panel, "", "GameFontNormal")
        caveSliderText:SetPoint("BOTTOM", caveSlider, "TOP", 0, 2)
    end
    caveSlider.textLabel = caveSliderText

    caveSlider:SetScript("OnValueChanged", function(self, value)
        if self._syncing then return end
        Config.db.caveAlpha = math.max(0.2, math.min(1, value))
        self.textLabel:SetText(
            ("Cave map opacity: %d%%"):format(Config.db.caveAlpha * 100))
        ns.CaveRenderer:ApplyAlpha()
    end)

    -- Built from the same list as the dropdown, so it never advertises a
    -- background this install cannot draw.
    local keys = {}
    for _, bg in ipairs(Config:AvailableBackgrounds()) do
        keys[#keys + 1] = bg.key
    end
    local hint = Label(panel,
        "|cff999999Also available from chat: /hfwm bg "
            .. table.concat(keys, "|") .. "  |  /hfwm cave on|off|r",
        "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", caveSlider, "BOTTOMLEFT", 0, -28)

    panel.enable     = enable
    panel.dropdown   = dropdown
    panel.bgDesc     = bgDesc
    panel.slider     = slider
    panel.caveCheck  = caveCheck
    panel.caveSlider = caveSlider

    -- An open list outlives the panel it belongs to: the legacy menu and the
    -- new one both parent themselves high up so they are not clipped, so
    -- closing the panel with the list down would leave it floating.
    panel:SetScript("OnHide", function() dropdown.CloseMenu() end)

    -- The client calls these on its own canvas panels.
    panel.OnRefresh = function() Options:Refresh() end
    panel.refresh   = panel.OnRefresh
    panel.okay      = function() end
    panel.cancel    = function() end
    panel.default   = function()
        for k, v in pairs(Config.DEFAULTS) do Config.db[k] = v end
        ns.Renderer:ForceRefresh()
        -- Reconcile rather than hide outright: "default" for the cave map is
        -- off, but that is a fact about DEFAULTS, not something to hard-code
        -- a second time here.
        ns.Cave:UpdateState()
        Options:Refresh()
    end

    self.panel = panel
    return panel
end

--- Pull every widget's state back from the SavedVariables.
function Options:Refresh()
    local panel = self.panel
    if not panel or not Config.db then return end

    local bg = Config:GetBackground()

    panel.enable:SetChecked(Config.db.enabled and true or false)
    panel.dropdown:Sync()
    panel.bgDesc:SetText("|cff999999" .. bg.desc .. "|r")

    panel.slider._syncing = true
    panel.slider:SetValue(Config.db.alpha or 1)
    panel.slider._syncing = false
    panel.slider.textLabel:SetText(
        ("Opacity: %d%%"):format((Config.db.alpha or 1) * 100))

    panel.caveCheck:SetChecked(Config.db.caveEnabled and true or false)

    local caveAlpha = Config:CaveAlpha()
    panel.caveSlider._syncing = true
    panel.caveSlider:SetValue(caveAlpha)
    panel.caveSlider._syncing = false
    panel.caveSlider.textLabel:SetText(
        ("Cave map opacity: %d%%"):format(caveAlpha * 100))
    -- The opacity of a window you have turned off is not a live setting.
    -- Enable/Disable rather than SetEnabled: the former has been on Slider
    -- since vanilla, the latter is a mixin method of uncertain vintage here.
    if Config.db.caveEnabled then
        panel.caveSlider:Enable()
        panel.caveSlider:SetAlpha(1)
    else
        panel.caveSlider:Disable()
        panel.caveSlider:SetAlpha(0.4)
    end
end

-------------------------------------------------------------------------------
-- Registration
-------------------------------------------------------------------------------

--- Standalone window, used when there is no options API to register into and
--- whenever /hfwm options is typed.
function Options:BuildWindow()
    if self.window then return self.window end

    local win = CreateFrame("Frame", "HFWMForeverOptionsWindow", UIParent)
    win:SetSize(580, 480)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:Hide()
    StyleBox(win, 0.03, 0.03, 0.04, 0.96)

    local close = CreateFrameTry("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", win, "TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() win:Hide() end)

    -- One panel, moved here. If registration with the client's own options
    -- succeeded but opening it failed, this takes the panel out of that
    -- canvas — the category is then an empty page, which is the right
    -- trade: the window is only ever reached when the canvas would not open.
    local panel = self:BuildPanel()
    panel:SetParent(win)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", win, "TOPLEFT", 4, -4)
    panel:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -4, 4)
    panel:Show()

    if UISpecialFrames then                    -- Escape closes it
        tinsert(UISpecialFrames, "HFWMForeverOptionsWindow")
    end
    self.window = win
    return win
end

--- Register the panel with the client's own options UI, if it has one we
--- recognise. Returns true if it took.
function Options:RegisterWithClient()
    local panel = self:BuildPanel()

    -- Modern Settings API (retail 10.0+ and some classic flavours).
    if Settings and Settings.RegisterCanvasLayoutCategory
       and Settings.RegisterAddOnCategory then
        local ok, category = pcall(
            Settings.RegisterCanvasLayoutCategory, panel, PANEL_TITLE)
        if ok and category then
            category.ID = PANEL_TITLE
            pcall(Settings.RegisterAddOnCategory, category)
            self.settingsCategory = category
            return true
        end
    end

    -- Legacy Interface Options.
    if InterfaceOptions_AddCategory then
        local ok = pcall(InterfaceOptions_AddCategory, panel)
        if ok then
            self.legacyRegistered = true
            return true
        end
    end

    return false
end

--- Open the options, wherever they ended up living.
function Options:Open()
    self:BuildPanel()
    self:Refresh()

    if self.settingsCategory and Settings and Settings.OpenToCategory then
        if pcall(Settings.OpenToCategory, self.settingsCategory.ID
                or self.settingsCategory) then
            return
        end
    end
    if self.legacyRegistered and InterfaceOptionsFrame_OpenToCategory then
        -- Called twice on purpose: the legacy function is famously unreliable
        -- the first time, landing on the wrong category.
        pcall(InterfaceOptionsFrame_OpenToCategory, self.panel)
        pcall(InterfaceOptionsFrame_OpenToCategory, self.panel)
        if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
            return
        end
    end

    local win = self:BuildWindow()
    self:Refresh()
    win:Show()
end

function Options:Init()
    self:BuildPanel()
    self.clientRegistered = self:RegisterWithClient()
    self:Refresh()
end
