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
-- Label reads "SD" while the overlay is on -- click to drop back to
-- Blizzard's own stock map -- and "HD" once it's off, so clicking again
-- brings the high-fidelity overlay back. This is purely visual
-- (Config.visuallySuppressed, force-refreshed through directly) and
-- deliberately does NOT touch Config.db.enabled, the real `/hfwm` on/off
-- switch -- that also gates the cave map (see Cave.lua), and this button
-- has no business taking that down too. It's also session-only: closing
-- the map resets it, so the next open always starts back on high-fidelity.
--
-- The button itself is opt-out: Config.db.toggleButtonEnabled (Options'
-- own "HD/SD map toggle button" checkbox) gates whether it's ever created
-- at all, not just whether it's shown -- see Refresh below -- so turning
-- it off leaves nothing behind to get in the way of a plainer map.
-------------------------------------------------------------------------------
local addonName, ns = ...
local Config       = ns.Config
local Renderer     = ns.Renderer
local ToggleButton = ns.ToggleButton

local WorldMapFrame = _G.WorldMapFrame

local button

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

local function UpdateLabel()
    if not button then return end
    local overlayOn = Config.db and Config.db.enabled and not Config.visuallySuppressed
    local text = overlayOn and "SD" or "HD"
    if button.SetText then
        button:SetText(text)
    elseif button.Text then
        button.Text:SetText(text)
    end
end

local function OnClick()
    -- Flips the visual-only override and redraws immediately. Leaves
    -- Config.db.enabled (and therefore the cave map) completely alone.
    Config.visuallySuppressed = not Config.visuallySuppressed
    Renderer:ForceRefresh()
    UpdateLabel()
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
    button:SetPoint("TOPRIGHT", mapPane, "TOPRIGHT", -2, 0)

    if not button.SetText then
        -- No button template resolved (CreateFrameTry's own plain-frame
        -- fallback): draw our own label rather than leave a blank button.
        button.Text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        button.Text:SetPoint("CENTER")
    end

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

    -- The visual override is session-only: drop it the moment the map
    -- closes so the next open always starts back on high-fidelity, rather
    -- than silently staying suppressed until someone clicks the button
    -- again to notice.
    WorldMapFrame:HookScript("OnHide", function()
        Config.visuallySuppressed = false
    end)
end

--- Build (if needed) and show/hide the button to match Config.db.
--- toggleButtonEnabled -- the Options panel's "HD/SD map toggle button"
--- checkbox. Disabled means the button is never even created (or is
--- hidden, once one already exists), so it can't get in the way of anyone
--- who just wants the plain map back. Safe to call anytime, including
--- before CreateButton has ever run.
function ToggleButton:Refresh()
    local wantShown = Config.db and Config.db.toggleButtonEnabled
    if wantShown then
        CreateButton()
        if button then button:Show() end
    elseif button then
        button:Hide()
    end
    UpdateLabel()
end
