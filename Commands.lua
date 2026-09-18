-------------------------------------------------------------------------------
-- HFWM-Forever Commands
-- Slash command handler (/hfwm, /highfidelity).
-------------------------------------------------------------------------------
local addonName, ns = ...
local Commands = ns.Commands
local Config   = ns.Config
local Pool     = ns.Pool
local P        = ns.P

function Commands:Handle(msg)
    local args = { strsplit(" ", strtrim(msg):lower()) }
    local cmd  = args[1] or ""
    local db   = Config.db

    if cmd == "on" or cmd == "enable" then
        db.enabled = true
    elseif cmd == "off" or cmd == "disable" then
        db.enabled = false
    elseif cmd == "cave" then
        local sub = args[2] or ""
        if sub == "on" or sub == "enable" then
            db.caveEnabled = true
        elseif sub == "off" or sub == "disable" then
            db.caveEnabled = false
        else
            db.caveEnabled = not db.caveEnabled
        end
        if db.caveEnabled then
            P("|cff00ff00Cave overlay enabled|r")
        else
            P("|cffff4444Cave overlay disabled|r")
            ns.CaveRenderer:HideCave()
        end
        return
    elseif cmd == "bg" or cmd == "background" then
        local want = args[2] or ""
        -- Only what this install can actually draw: "original" needs the
        -- second, raw tile dump, which a build without --original never wrote.
        local list = Config:AvailableBackgrounds()
        if want == "" then
            -- No argument: cycle, which is what a keybind would want.
            local cur = Config:GetBackground()
            local nxt = list[1]
            for i, bg in ipairs(list) do
                if bg.key == cur.key then
                    nxt = list[i % #list + 1]
                    break
                end
            end
            want = nxt and nxt.key or ""
        end
        local applied = Config:SetBackground(want)
        if applied then
            P(("Map background: |cff33ccff%s|r — %s"):format(
                applied.label, applied.desc))
            if ns.Options.panel then ns.Options:Refresh() end
        else
            local keys = {}
            for _, bg in ipairs(list) do
                keys[#keys + 1] = bg.key
            end
            P(("Unknown background '%s'. Options: %s"):format(
                want, table.concat(keys, ", ")))
            if not Config:BackgroundAvailable({ tiles = "original" }) then
                P("  (|cff999999original|r needs the raw tile dump — rebuild "
                    .. "the art with --original)")
            end
        end
        return
    elseif cmd == "options" or cmd == "config" or cmd == "settings" then
        ns.Options:Open()
        return
    elseif cmd == "alpha" then
        local val = tonumber(args[2])
        if val then
            db.alpha = math.max(0, math.min(1, val))
            P(("Alpha set to %.0f%%"):format(db.alpha * 100))
            ns.Renderer:ForceRefresh()
            return
        else
            P("Usage: /hfwm alpha 0.0-1.0")
            return
        end
    elseif cmd == "baseart" then
        -- Blizzard's own detail layer: the parchment, the sea labels and the
        -- compass rose. Every background but Hybrid hides it, but only
        -- Transparent puts nothing opaque in front — so if the search below
        -- comes back empty, Transparent is the one entry that shows it.
        local BaseArt = ns.BaseArt
        local found = BaseArt:Describe()
        P(("detail layers: %d found, currently %s"):format(
            #found, BaseArt.visible and "shown" or "hidden"))
        for i, line in ipairs(found) do
            print(("  %d. %s"):format(i, line))
        end
        if #found == 0 then
            print("  (none found — open the map first; if the map is open and "
                .. "this is still empty, the client keeps its detail layers "
                .. "somewhere the search does not look)")
        end
        return
    elseif cmd == "framebg" then
        -- What the Transparent background hides, and — when the answer turns
        -- out to be "not enough" — what else is down there. The search is by
        -- draw layer and size rather than by name, so a miss is invisible
        -- unless something walks the whole tree and says so.
        local MapFrameBg = ns.MapFrameBg
        local sub = args[2] or ""

        if sub == "all" or sub == "survey" then
            local rows = MapFrameBg:Survey()
            P(("map-frame survey: %d widget(s) under WorldMapFrame"):format(
                #rows))
            print("  reached | alpha shown  layer/sub  owner -> region  = texture")
            for _, r in ipairs(rows) do
                print(("  %s | %.2f %-5s %s/%d  %s -> %s  = %s"):format(
                    r.reached and "YES" or " no", r.alpha,
                    tostring(r.shown), r.layer, r.sublevel,
                    r.owner, r.region, r.tex))
            end
            if #rows == 0 then
                print("  (nothing found — open the map first)")
            end
            return
        elseif sub == "nuke" then
            -- Not a setting: a bisection tool. If this makes the map
            -- see-through then the backing is in the survey and the ordinary
            -- search can be taught to reach it; if it does not, nothing in
            -- the UI is what we are looking at.
            local n = MapFrameBg:Nuke()
            P(("hid %d widget(s) under WorldMapFrame. "):format(n)
                .. "|cffff4444/hfwm framebg restore|r puts them back.")
            return
        elseif sub == "restore" then
            P(("restored %d widget(s)."):format(MapFrameBg:Unnuke()))
            return
        end

        local found = MapFrameBg:Describe()
        P(("map-frame backing: %d region(s), currently %s"):format(
            #found, MapFrameBg.visible and "shown" or "hidden"))
        for i, name in ipairs(found) do
            print(("  %d. %s"):format(i, name))
        end
        if #found == 0 then
            print("  (nothing found — open the map first)")
        end
        print("  |cff999999framebg all|r surveys the whole frame tree; "
            .. "|cff999999framebg nuke|r hides all of it")
        return
    elseif cmd == "debug" then
        self:Debug()
        return
    elseif cmd == "" then
        db.enabled = not db.enabled
    else
        print("|cff33ccffHigh Fidelity World Map Forever|r commands:")
        print("  /hfwm               - toggle overlay")
        print("  /hfwm on|off        - enable / disable")
        print("  /hfwm options       - open the options panel")
        local keys = {}
        for _, bg in ipairs(Config:AvailableBackgrounds()) do
            keys[#keys + 1] = bg.key
        end
        print("  /hfwm bg [NAME]     - map background: "
            .. table.concat(keys, " | ") .. " (no name cycles)")
        print("  /hfwm alpha N       - set opacity (0-1)")
        print("  /hfwm cave [on|off] - toggle cave/dungeon overlay (opt-in)")
        print("  /hfwm baseart       - Blizzard's detail layer, and whether "
            .. "the search finds it")
        print("  /hfwm framebg       - map-frame backing Transparent hides")
        print("                        (all = survey everything, nuke/restore)")
        print("  /hfwm debug         - diagnostic info + force refresh")
        return
    end

    if db.enabled then
        P("|cff00ff00Enabled|r")
    else
        P("|cffff4444Disabled|r")
    end
    ns.Renderer:ForceRefresh()
end

function Commands:Debug()
    local bg = Config:GetBackground()
    -- The tile table the active background actually draws from, so every
    -- lookup reported below matches what is on screen.
    local FDID_MAP     = Config:GetTileMap(bg)
    local FDID_MAP_SUB = Config.FDID_MAP_SUB

    -- FDID_MAP health check
    local mapCount = 0
    for _ in pairs(FDID_MAP) do mapCount = mapCount + 1 end
    local subCount = 0
    for _ in pairs(FDID_MAP_SUB) do subCount = subCount + 1 end
    P("debug: FDID_MAP=" .. mapCount .. " entries, FDID_MAP_SUB=" .. subCount
        .. "  enabled=" .. tostring(Config.db and Config.db.enabled))
    print(("  FDID_BASE: %s"):format(Config.FDID_BASE or "nil"))
    print(("  tile tables: bundled=%d  original=%d"):format(
        Config._fdidMapSize or -1, Config._fdidMapOriginalSize or -1))
    local bgHow
    if bg.rgb then
        bgHow = ("#%02X%02X%02X"):format(
            bg.rgb[1] * 255, bg.rgb[2] * 255, bg.rgb[3] * 255)
    elseif bg.blizzardArt then
        bgHow = "Blizzard art"
    elseif bg.seeThrough then
        bgHow = "nothing behind the tiles, map frame backing hidden"
    else
        bgHow = "nothing behind the tiles"
    end
    print(("  background: %s (%s)  tiles=%s  backdrop=%s  baseArtVisible=%s")
        :format(
            bg.key, bgHow, bg.tiles or "bundled",
            Config.backdropTexture
                and tostring(Config.backdropTexture:IsShown()) or "nil",
            tostring(ns.BaseArt.visible)))
    print(("  frame backing: %d region(s) touched, currently %s"):format(
        #ns.MapFrameBg.order,
        ns.MapFrameBg.visible and "shown" or "hidden"))
    print(("  options: dropdown=%s  registered=%s"):format(
        tostring(ns.Options.dropdownKind),
        tostring(ns.Options.clientRegistered)))

    local mapID = WorldMapFrame:GetMapID()
    P("debug: mapID=" .. tostring(mapID)
        .. "  lastMapID=" .. tostring(Config.lastMapID))

    local minimapMapID = C_Minimap and C_Minimap.GetUiMapID and C_Minimap.GetUiMapID()
    local bestMapID = C_Map.GetBestMapForUnit("player")
    local minimapInfo = minimapMapID and C_Map.GetMapInfo(minimapMapID)
    local bestInfo = bestMapID and C_Map.GetMapInfo(bestMapID)
    print(("  minimap mapID: %s (%s)"):format(
        tostring(minimapMapID),
        minimapInfo and minimapInfo.name or "?"))
    print(("  bestMap(player): %s (%s)"):format(
        tostring(bestMapID),
        bestInfo and bestInfo.name or "?"))
    print(("  minimapZone: %s  subZone: %s"):format(
        tostring(GetMinimapZoneText()), tostring(GetSubZoneText())))
    local hybridMinimap = C_Minimap and C_Minimap.ShouldUseHybridMinimap
        and C_Minimap.ShouldUseHybridMinimap()
    print(("  submerged: %s  outdoors: %s  hybridMinimap: %s"):format(
        tostring(IsSubmerged()), tostring(IsOutdoors()), tostring(hybridMinimap)))

    if minimapMapID then
        local groupID = C_Map.GetMapGroupID(minimapMapID)
        if groupID then
            local members = C_Map.GetMapGroupMembersInfo(groupID)
            print(("  mapGroup: %d  floors: %d"):format(
                groupID, members and #members or 0))
            if members then
                for i, m in ipairs(members) do
                    local current = (m.mapID == minimapMapID) and " <-- CURRENT" or ""
                    print(("    floor %d: mapID=%d  heightIdx=%d  name=%s%s"):format(
                        i, m.mapID, m.relativeHeightIndex, m.name or "?", current))
                end
            end
        else
            print("  mapGroup: none (no floors)")
        end
    end

    if bestMapID and bestMapID ~= minimapMapID then
        local groupID = C_Map.GetMapGroupID(bestMapID)
        if groupID then
            local members = C_Map.GetMapGroupMembersInfo(groupID)
            print(("  bestMap group: %d  floors: %d"):format(
                groupID, members and #members or 0))
            if members then
                for i, m in ipairs(members) do
                    local current = (m.mapID == bestMapID) and " <-- CURRENT" or ""
                    print(("    floor %d: mapID=%d  heightIdx=%d  name=%s%s"):format(
                        i, m.mapID, m.relativeHeightIndex, m.name or "?", current))
                end
            end
        end
    end

    if mapID then
        local allLayers = C_Map.GetMapArtLayers(mapID)
        local numLayers = allLayers and #allLayers or 0
        local sub = IsSubmerged() and true or false
        local lIdx = (numLayers >= 2 and sub) and 2 or 1
        print(("  worldmap layers: %d  activeLayer: %d"):format(numLayers, lIdx))
        local fdids = C_Map.GetMapArtLayerTextures(mapID, lIdx)
        local hasBundled = fdids and #fdids > 0 and FDID_MAP[fdids[1]]
        local hasSub = fdids and #fdids > 0 and FDID_MAP_SUB[fdids[1]]
        if hasSub and sub then
            print("  source: BUNDLED BLP SUB (" .. FDID_MAP_SUB[fdids[1]] .. ")")
        elseif hasBundled then
            print("  source: BUNDLED BLP (" .. FDID_MAP[fdids[1]] .. ")")
        else
            print("  source: C_Map API (no bundled BLPs)")
        end
        if numLayers > 0 then
            local l = allLayers[lIdx]
            print(("  art layer %d: %dx%d  tile: %dx%d"):format(
                lIdx, l.layerWidth, l.layerHeight,
                l.tileWidth or 256, l.tileHeight or 256))
        end
        print("  FileDataIDs: " .. (fdids and #fdids or 0))
        if fdids and #fdids > 0 then
            print(("  first FDID: %d  last FDID: %d"):format(fdids[1], fdids[#fdids]))
            -- Show lookup result for first 3 FDIDs
            for i = 1, math.min(3, #fdids) do
                local rel = FDID_MAP[fdids[i]]
                if rel then
                    local full = Config.FDID_BASE .. rel
                    print(("  FDID[%d]=%d => %s"):format(i, fdids[i], full))
                else
                    print(("  FDID[%d]=%d => NOT IN MAP"):format(i, fdids[i]))
                end
            end
        end
        local canvas = WorldMapFrame.ScrollContainer.Child
        if canvas then
            local w, h = canvas:GetSize()
            print(("  canvas: %.0f x %.0f"):format(w, h))
        end

        -- Check detail layer pool. The pool is only one of the places BaseArt
        -- looks, and a NIL here used to mean BaseArt gave up entirely — so
        -- report what it actually found alongside it.
        local dlp = WorldMapFrame.detailLayerPool
        local dlpCount = 0
        if dlp and dlp.EnumerateActive then
            for _ in dlp:EnumerateActive() do dlpCount = dlpCount + 1 end
        end
        print(("  detailLayerPool: %s  active=%d"):format(
            dlp and "exists" or "NIL", dlpCount))
        print(("  BaseArt: %d layer(s) found, visible=%s  "
            .. "(|cff999999/hfwm baseart|r for detail)"):format(
            #ns.BaseArt:Describe(), tostring(ns.BaseArt.visible)))
    end

    print("  overlayActive: " .. tostring(Config.overlayActive))
    print("  active overlay textures: " .. Pool:ActiveCount())
    if Config.overlayFrame then
        local w, h = Config.overlayFrame:GetSize()
        print(("  overlayFrame: %.0f x %.0f  alpha=%.2f  level=%d  shown=%s"):format(
            w, h, Config.overlayFrame:GetAlpha(), Config.overlayFrame:GetFrameLevel(),
            tostring(Config.overlayFrame:IsShown())))
    else
        print("  overlayFrame: NIL")
    end

    -- Cave overlay diagnostics
    print(("  caveOverlayActive: %s  currentFloor: %s  floors: %d"):format(
        tostring(Config.caveOverlayActive),
        tostring(Config.caveCurrentFloorMapID),
        Config.caveAllFloors and #Config.caveAllFloors or 0))
    if Config.caveOverlayFrame then
        local cw, ch = Config.caveOverlayFrame:GetSize()
        print(("  caveOverlayFrame: %.0f x %.0f  alpha=%.2f  level=%d  shown=%s  tiles=%d"):format(
            cw, ch, Config.caveOverlayFrame:GetAlpha(),
            Config.caveOverlayFrame:GetFrameLevel(),
            tostring(Config.caveOverlayFrame:IsShown()),
            ns.CaveRenderer.ActiveTileCount and ns.CaveRenderer:ActiveTileCount() or -1))
    end
    if Config.caveAllFloors then
        for i, f in ipairs(Config.caveAllFloors) do
            local marker = (f.mapID == Config.caveCurrentFloorMapID) and " <-- ACTIVE" or ""
            print(("    floor %d: mapID=%d  heightIdx=%d  name=%s%s"):format(
                i, f.mapID, f.relativeHeightIndex, f.name or "?", marker))
        end
    end
    Config.tracing = true
    ns.Renderer:ForceRefresh()
    Config.tracing = false
    print("  After refresh: " .. Pool:ActiveCount() .. " textures")

    -- Show first active texture info
    local active = Pool:GetActive()
    if active and #active > 0 then
        local tex = active[1]
        local texFile = tex:GetTexture()
        print(("  tex[1]: texture=%s  shown=%s  alpha=%.2f  w=%.0f h=%.0f"):format(
            tostring(texFile), tostring(tex:IsShown()), tex:GetAlpha(),
            tex:GetWidth(), tex:GetHeight()))
    end
end

function Commands:Register()
    SLASH_HFWMF1 = "/hfwm"
    SLASH_HFWMF2 = "/hfwmforever"
    SlashCmdList["HFWMF"] = function(msg) self:Handle(msg) end
end
