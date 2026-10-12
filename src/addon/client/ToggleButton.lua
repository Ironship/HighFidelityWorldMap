-------------------------------------------------------------------------------
-- HFWM-Forever Toggle Button
--
-- A small button docked in the world map's own top-right corner. Its size
-- is borrowed from the quest-list toggle (WorldMapFrame.SidePanelToggle.
-- OpenButton) when that exists, purely for a size that matches the rest of
-- the map's chrome -- its own "?" artwork is deliberately left alone rather
-- than copied, so this stays a plain Blizzard button template showing our
-- own "SD"/"HD" text, nothing more. (See Commands.lua's `/hfwm icon` for
-- pulling the real texture/atlas info for that button's own artwork, if
-- it's ever needed.)
--
-- Label reads "SD" while the blend is past 50% HD -- click to drop back to
-- Blizzard's own stock map -- and "HD" otherwise, so clicking again
-- brings the high-fidelity overlay back. A click is just the blend slider
-- (below) jumping to 0% or 100%, so the two always agree, and like the
-- slider it persists. It deliberately does NOT touch Config.db.enabled,
-- the real `/hfwm` on/off switch -- that also gates the cave map (see
-- Cave.lua), and this button has no business taking that down too.
--
-- Right-clicking it opens a small slider just below (see CreatePopup) that
-- blends between the HD overlay and Blizzard's own map, to compare them.
--
-- The button itself is opt-out: Config.db.toggleButtonEnabled (Options'
-- own "HD/SD map toggle button" checkbox) gates whether it's ever created
-- at all, not just whether it's shown -- see Refresh below -- so turning
-- it off leaves nothing behind to get in the way of a plainer map. It is
-- also hidden while the addon is disabled (Config.db.enabled off).
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config       = ns.Config
local Renderer     = ns.Renderer
local ToggleButton = ns.ToggleButton

local WorldMapFrame = _G.WorldMapFrame

local button
local popup

--- CreateFrame against the first template that actually exists. Same reason
--- as CaveRenderer.lua's own copy: CreateFrame *errors* on an unknown
--- template rather than returning nil, and which FrameXML templates this
--- beta client ships is not something the addon can ask about.
local function CreateFrameTry(kind, name, parent, ...)
    for i = 1, select("#", ...) do
        local ok, frame = pcall(CreateFrame, kind, name, parent, (select(i, ...)))
        if ok and frame then return frame end
    end
    return CreateFrame(kind, name, parent)
end

--- Is the HD side of the blend the dominant one? Past the halfway mark, and
--- not when the overlay is off. This one test drives both the label (which
--- names what a click switches to) and the click's own direction.
local function HDShowing()
    return Config.db and Config.db.enabled and Config:GetAlpha() > 0.5
end

local function UpdateLabel()
    if not button then return end
    local text = HDShowing() and "SD" or "HD"
    if button.SetText then
        button:SetText(text)
    elseif button.Text then
        button.Text:SetText(text)
    end
    local alpha = Config:GetAlpha()
    button.blendLine:SetShown(alpha > 0.005 and alpha < 0.995)
end

local syncPopup  -- set by CreatePopup: reload the slider from Config:GetAlpha()

--- Set the HD overlay's opacity (the slider's value), live. A full Refresh
--- only when crossing 100%, which changes what else must be visible
--- (Blizzard's own map underneath).
local function ApplyAlpha(value)
    local wasMixing = Config:IsMixing()
    Config:SetAlpha(value)
    if Config.overlayFrame then Config.overlayFrame:SetAlpha(value) end
    if Config:IsMixing() ~= wasMixing then Renderer:ForceRefresh() end
    UpdateLabel()
end

local pinned        -- popup is detached from the map and staying open
local unpinPopup    -- set by CreatePopup: close the popup and clear the pin
-- How far (UI units) the mouse may stray past the popup or button before
-- the popup closes.
local CLOSE_DISTANCE = 40

--- Is the cursor within CLOSE_DISTANCE of this frame's rectangle?
local function IsNear(frame)
    local left, bottom, width, height = frame:GetRect()
    if not left then return false end
    local x, y = GetCursorPosition()
    local scale = frame:GetEffectiveScale()
    x, y = x / scale, y / scale
    return x >= left - CLOSE_DISTANCE and x <= left + width + CLOSE_DISTANCE
        and y >= bottom - CLOSE_DISTANCE and y <= bottom + height + CLOSE_DISTANCE
end

--- Right click: a small Blizzard-style HD/SD blend slider drops below the
--- button, its top-right corner on the button's bottom-right. 100% is the
--- plain HD overlay, 0% Blizzard's own map, and anything between is an
--- exact mix of the two: the overlay draws at that alpha over Blizzard's
--- map, which Config:IsMixing() makes Renderer leave visible. Stored in
--- Config.db.alphas (per map type; no Options entry or chat command) and applied live,
--- with a full Refresh only when crossing 100%.
local function CreatePopup()
    popup = CreateFrameTry("Frame", nil, button, "BackdropTemplate")
    popup:SetSize(140, 46)
    popup:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, 0)
    popup:SetFrameLevel(button:GetFrameLevel() + 5)
    -- Swallow clicks so they don't pan the map underneath.
    popup:EnableMouse(true)
    if popup.SetBackdrop then
        popup:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        popup:SetBackdropColor(0, 0, 0, 0.9)
    end
    popup:Hide()

    local label = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOP", 0, -8)

    local slider = CreateFrameTry(
        "Slider", "HFWMForeverOpacitySlider", popup, "OptionsSliderTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(17)
    slider:SetPoint("TOPLEFT", popup, "TOPLEFT", 12, -24)
    slider:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -12, -24)
    slider:SetMinMaxValues(0, 1)
    slider:SetValueStep(0.05)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    -- The template's own title and Low/High captions; the label above
    -- shows the value instead.
    for _, suffix in ipairs({ "Text", "Low", "High" }) do
        local region = _G["HFWMForeverOpacitySlider" .. suffix]
        if region then region:Hide() end
    end

    local syncing
    local function Caption(value)
        label:SetText(("Blend: %.0f%%"):format(value * 100))
    end
    slider:SetScript("OnValueChanged", function(_, value)
        Caption(value)
        -- SetValue from Sync below fires this too; don't let it re-save
        -- the value it was just loaded from.
        if syncing then return end
        ApplyAlpha(value)
    end)
    syncPopup = function()
        syncing = true
        slider:SetValue(Config:GetAlpha())
        Caption(Config:GetAlpha())
        syncing = false
    end
    popup:SetScript("OnShow", syncPopup)

    -- Pin (top right): keeps the popup open when the mouse leaves it, and
    -- through closing the map -- it is still a child of the map, so it
    -- disappears with the map and is back when the map reopens, without
    -- another right click. Turns into an X, which closes the popup and
    -- clears the pin. Session-only, not saved.
    local pinBtn = CreateFrame("Button", nil, popup)
    pinBtn:SetSize(16, 16)
    pinBtn:SetPoint("TOPRIGHT", -4, -4)
    pinBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local icon = pinBtn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    local function SetPinIcon()
        icon:SetTexCoord(0, 1, 0, 1)
        if pinned then
            icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
            icon:SetAlpha(1)
        else
            icon:SetTexture("Interface\\COMMON\\Indicator-Gray")
            icon:SetAlpha(0.6)
        end
    end
    SetPinIcon()

    local function Pin()
        pinned = true
        SetPinIcon()
    end
    unpinPopup = function()
        pinned = false
        popup:Hide()
        SetPinIcon()
    end
    pinBtn:SetScript("OnClick", function()
        if pinned then unpinPopup() else Pin() end
    end)
    pinBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(pinned and "Close" or "Pin open")
    end)
    pinBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- Close once the mouse is off both the popup and the button. Skipped
    -- while a mouse button is held so a drag that strays off the popup
    -- doesn't close it mid-adjustment, and while pinned.
    popup:SetScript("OnUpdate", function()
        if pinned or IsMouseButtonDown("LeftButton") then return end
        if not (IsNear(popup) or IsNear(button)) then popup:Hide() end
    end)
end

local function OnClick(_, mouseButton)
    if mouseButton == "RightButton" then
        -- A pinned popup is closed with its X, not toggled from here.
        if pinned then return end
        if not popup then CreatePopup() end
        popup:SetShown(not popup:IsShown())
        return
    end
    -- Leaves Config.db.enabled (and therefore the cave map) completely
    -- alone. The button reads "SD" while HD is showing at all, and "HD"
    -- when it isn't; clicking slides the blend all the way to the other
    -- end, with the slider following if it's open.
    ApplyAlpha(HDShowing() and 0 or 1)
    if syncPopup and popup and popup:IsShown() then syncPopup() end
end

-- Fallback size when WorldMapFrame.SidePanelToggle.OpenButton isn't around
-- to measure (see CreateButton) -- close to that button's own usual size.
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 32, 22

--- Build the button. WorldMapFrame itself is guaranteed to exist by the
--- time Core.lua's OnEnable calls ToggleButton:Start (every other module
--- here relies on that same assumption), so unlike the size lookup below
--- this doesn't need a nil-guard or a retry.
local function CreateButton()
    if button then return button end

    -- UIPanelButtonTemplate ships on every client build that matters here,
    -- and comes with its own Left/Middle/Right + pushed/highlight textures
    -- and a built-in Text font string (hence button:SetText below) -- a
    -- plain, generic button skin with no borrowed artwork of its own to
    -- accidentally drag the "?" icon along with it.
    button = CreateFrameTry(
        "Button", "HFWMForeverToggleButton", WorldMapFrame,
        "UIPanelButtonTemplate", "UIPanelButtonTemplate2")

    local sidePanelToggle = WorldMapFrame.SidePanelToggle
    local reference = sidePanelToggle and sidePanelToggle.OpenButton
    local width, height
    if reference then
        width, height = reference:GetSize()
    else
        width, height = DEFAULT_WIDTH, DEFAULT_HEIGHT
    end
    button:SetSize(width, height)

    button:SetFrameStrata(WorldMapFrame:GetFrameStrata())
    button:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 10)

    -- Anchor to the actual map pane rather than the full WorldMapFrame, so
    -- opening the quest side panel does not drag the button out over that
    -- extra width. Fall back to WorldMapFrame on clients that lack the
    -- ScrollContainer field for some reason.
    local mapPane = WorldMapFrame.ScrollContainer or WorldMapFrame
    button:SetPoint("TOPRIGHT", mapPane, "TOPRIGHT", -2, 2)

    -- Small gold dot (the stock yellow status indicator) centred on the
    -- button's top-left corner while the blend is strictly between 0% and
    -- 100%; see UpdateLabel. Same thresholds as Config:IsMixing.
    button.blendLine = button:CreateTexture(nil, "OVERLAY", nil, 7)
    button.blendLine:SetTexture("Interface\\COMMON\\Indicator-Yellow")
    button.blendLine:SetSize(10, 10)
    button.blendLine:SetPoint("CENTER", button, "TOPLEFT", 3, -3)

    if not button.SetText then
        -- No button template resolved (CreateFrameTry's own plain-frame
        -- fallback): draw our own label rather than leave a blank button.
        button.Text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        button.Text:SetPoint("CENTER")
    end

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", OnClick)
    UpdateLabel()

    return button
end

--- Wire up the button. Called once from Core.lua's PLAYER_LOGIN handler,
--- same timing every other module here waits for.
function ToggleButton:Start()
    self:Refresh()

    -- Keep the label (and, if the Options toggle changed while the map was
    -- closed, the button's very existence) in sync on every reopen, not
    -- just this button's own clicks.
    WorldMapFrame:HookScript("OnShow", function()
        ToggleButton:Refresh()
    end)

    -- Each map type has its own blend: follow the slider and label to it.
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        UpdateLabel()
        if syncPopup and popup and popup:IsShown() then syncPopup() end
    end)

    -- Close the opacity popup with the map, unless it's pinned: a pinned one
    -- is left "shown", so it hides with the map and returns when it reopens.
    WorldMapFrame:HookScript("OnHide", function()
        if popup and not pinned then popup:Hide() end
    end)
end

--- Build (if needed) and show/hide the button to match Config.db.
--- toggleButtonEnabled -- the Options panel's "HD/SD map toggle button"
--- checkbox. Disabled means the button is never even created (or is
--- hidden, once one already exists), so it can't get in the way of anyone
--- who just wants the plain map back. Safe to call anytime, including
--- before CreateButton has ever run.
function ToggleButton:Refresh()
    local wantShown = Config.db and Config.db.enabled and Config.db.toggleButtonEnabled
    if wantShown then
        CreateButton()
        if button then button:Show() end
    elseif button then
        if pinned then unpinPopup() end
        button:Hide()
    end
    UpdateLabel()
end
