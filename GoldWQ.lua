local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("QUEST_DATA_LOAD_RESULT")

-- Midnight zone map IDs
local ZONES = {
    { 2395, "Eversong Woods" },
    { 2437, "Zul'Aman" },
    { 2413, "Harandar" },
    { 2405, "Voidstorm" },
    { 2393, "Silvermoon City" },
    { 2512, "The Coiled Isle" },
}

local getQuests = C_TaskQuest.GetQuestsOnMap or C_TaskQuest.GetQuestsForPlayerByMapID
local available = {}      -- gold WQs currently up: { id, title, zone, mapID, copper }
local specials = {}       -- special assignments currently up
local activeList = {}     -- every active WQ, for /gwq debug
local skippedList = {}    -- POIs the scan rejected (and why), for /gwq debug
local knownZone = {}      -- questID -> zone name, for every world quest the scan has ever seen
local seenPOI = {}        -- questIDs the last scan found on the zone maps
local retries = 0
local stillUnloaded = 0   -- quests whose reward data had not loaded at the last scan
local eventScans = 0      -- rescans triggered by QUEST_DATA_LOAD_RESULT (capped)
local announce = false
local pending = false
local refreshUI           -- forward declaration (defined with the window code below)

local function charKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

local function me()
    local key = charKey()
    GoldWQDB.chars[key] = GoldWQDB.chars[key] or { weekQuests = {}, weekCopper = 0, totalCopper = 0, caches = {} }
    local c = GoldWQDB.chars[key]
    c.caches = c.caches or {}
    c.wqDone = c.wqDone or {}
    c.turnedIn = c.turnedIn or {}
    c.trackingSince = c.trackingSince or time()
    return c
end

-- Wipe weekly counters for every character once the weekly reset has passed.
local function rollWeek()
    local now = time()
    if GoldWQDB.resetAt and now >= GoldWQDB.resetAt then
        for _, c in pairs(GoldWQDB.chars) do
            c.weekQuests = {}
            c.weekCopper = 0
            c.caches = {}
            c.wqDone = {}
            c.turnedIn = {}
            c.trackingSince = time()
        end
    end
    GoldWQDB.resetAt = now + C_DateAndTime.GetSecondsUntilWeeklyReset()
end

local function fmt(copper)
    return GetCoinTextureString(copper or 0)
end

-- Count how many quests from each cache's list are done on THIS character.
-- Many of these quests never clear their "completed" flag between weeks, so a weekly
-- count can't rely on C_QuestLog.IsQuestFlaggedCompleted. Instead this counts against the
-- addon's own log of quests turned in since the last reset (see QUEST_TURNED_IN above).
local function snapshotCaches()
    local c = me()
    for _, cache in ipairs(GoldWQ_Caches) do
        local n = 0
        for _, id in ipairs(cache.quests) do
            if c.turnedIn[id] then n = n + 1 end
        end
        c.caches[cache.name] = n
    end
    if refreshUI then refreshUI() end
end


local function fmtLeft(sec)
    if not sec then return "" end
    if sec >= 3600 then return ("%dh %dm"):format(sec / 3600, (sec % 3600) / 60) end
    return ("%dm"):format(sec / 60)
end

-- A quest's zone ID is often a sub-area (e.g. "Slayer's Rise" inside Harandar), not the
-- top-level zone itself, so this walks up the map's parent chain until it reaches one of
-- our tracked top-level zones and uses that name instead.
local function topZoneName(zid)
    local guard = 0
    while zid and zid > 0 and guard < 10 do
        for _, z in ipairs(ZONES) do
            if z[1] == zid then return z[2] end
        end
        local mi = C_Map.GetMapInfo(zid)
        zid = mi and mi.parentMapID
        guard = guard + 1
    end
    return nil
end

-- Some quests are tagged with a zone ID that doesn't match where you actually do them
-- (e.g. Lightbloom/Bitterbloom quests span Eversong and Harandar in the story, and the
-- game can file them under Eversong even when fought in Harandar). Force those here.
local ZONE_OVERRIDE = {
    [92119] = "Harandar", -- Bitterbloom Burn Down
}

local function zoneName(id, fallback)
    if ZONE_OVERRIDE[id] then return ZONE_OVERRIDE[id] end
    local zid = C_TaskQuest.GetQuestZoneID and C_TaskQuest.GetQuestZoneID(id)
    if zid and zid > 0 then
        local top = topZoneName(zid)
        if top then return top end
        local mi = C_Map.GetMapInfo(zid)
        if mi and mi.name then return mi.name end
    end
    return fallback
end

local function cacheEnabled(name)
    return not (GoldWQDB.disabledCaches and GoldWQDB.disabledCaches[name])
end

local function trackedCaches()
    local list = {}
    for _, cache in ipairs(GoldWQ_Caches) do
        if #cache.quests > 0 and cacheEnabled(cache.name) then list[#list + 1] = cache end
    end
    return list
end

local function questTitle(id)
    local info = C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(id)
    if type(info) == "string" then return info end
    return C_QuestLog.GetTitleForQuestID(id) or ("Quest " .. id)
end

-- Scan every Midnight zone for active world quests that reward gold.
local function scan()
    local list, seen, unloaded, sa, active, skipped = {}, {}, 0, {}, {}, {}
    for _, z in ipairs(ZONES) do
        local ok, infos = pcall(getQuests, z[1])
        if ok and infos then
            for _, info in ipairs(infos) do
                local id = info.questID
                if id and not seen[id] then
                    seen[id] = true
                    if C_QuestLog.IsWorldQuest(id) then knownZone[id] = zoneName(id, z[2]) end
                    local left = C_TaskQuest.GetQuestTimeLeftSeconds(id)

                    -- every flag the game set on this quest (for diagnosing special assignments)
                    local flags = {}
                    for k, v in pairs(info) do
                        if v == true then flags[#flags + 1] = k end
                    end
                    table.sort(flags)
                    local tag = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(id)
                    local tagName = tag and tag.tagName
                    local flagText = table.concat(flags, ",") .. (tagName and (" tag=" .. tagName) or "")

                    local reason
                    if not C_QuestLog.IsWorldQuest(id) then reason = "not a world quest"
                    elseif not C_TaskQuest.IsActive(id) then reason = "not active"
                    elseif left and left <= 0 then reason = "expired"
                    elseif C_QuestLog.IsQuestFlaggedCompleted(id) then reason = "completed" end

                    if reason then
                        skipped[#skipped + 1] = { id = id, title = questTitle(id), zone = zoneName(id, z[2]),
                                                  reason = reason, flags = flagText,
                                                  mapID = z[1], x = info.x, y = info.y, left = left }
                    else
                        -- use the quest's own zone map + coordinates when it lives in a sub-zone
                        local ex, ey, emap = info.x, info.y, z[1]
                        local zid = C_TaskQuest.GetQuestZoneID and C_TaskQuest.GetQuestZoneID(id)
                        if zid and zid > 0 and zid ~= z[1] and C_TaskQuest.GetQuestLocation then
                            local lx, ly = C_TaskQuest.GetQuestLocation(id, zid)
                            if lx and ly then ex, ey, emap = lx, ly, zid end
                        end
                        local entry = { id = id, title = questTitle(id), zone = zoneName(id, z[2]), mapID = emap,
                                        x = ex, y = ey, left = left, copper = 0, flags = flagText }

                        local isSA = (info.isCapstone == true)
                            or (tagName and tagName:lower():find("assignment") ~= nil) or false
                        local rewNames = {}
                        local loaded = (not HaveQuestRewardData) or HaveQuestRewardData(id)
                        -- The loaded flag can lag behind the data: if gold is already readable, use it.
                        if not loaded and (GetQuestLogRewardMoney(id) or 0) > 0 then loaded = true end
                        if loaded then
                            entry.copper = GetQuestLogRewardMoney(id) or 0
                            for i = 1, (GetNumQuestLogRewards(id) or 0) do
                                local rname = GetQuestLogRewardInfo(i, id)
                                if rname then
                                    rewNames[#rewNames + 1] = rname
                                    if rname:find("Fabled") and rname:find("Cache") then isSA = true end
                                end
                            end
                        else
                            C_TaskQuest.RequestPreloadRewardData(id)
                            unloaded = unloaded + 1
                        end

                        active[#active + 1] = { entry = entry,
                            rew = loaded and table.concat(rewNames, ", ") or "(reward not loaded)" }
                        if entry.copper > 0 then list[#list + 1] = entry end
                        if isSA then sa[#sa + 1] = entry end
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.copper > b.copper end)
    table.sort(sa, function(a, b) return a.zone < b.zone end)
    available = list
    specials = sa
    activeList = active
    skippedList = skipped
    seenPOI = seen
    if refreshUI then refreshUI() end

    -- Reward data loads late: retry a few times until everything has loaded.
    stillUnloaded = unloaded
    if unloaded == 0 then eventScans = 0 end
    if unloaded > 0 and retries < 50 then
        retries = retries + 1
        C_Timer.After(retries <= 20 and 2 or 10, scan)
        return
    end

    if announce then
        announce = false
        local total = 0
        for _, q in ipairs(available) do total = total + q.copper end
        print(("|cffffd100GoldWQ|r %d gold world quests up (%s total). /gwq opens the window."):format(#available, fmt(total)))
    end
end

local function requestScan(delay)
    if pending then return end
    pending = true
    C_Timer.After(delay or 1, function()
        pending = false
        retries = 0
        scan()
    end)
end

-- Catch the weekly reset even if you stay logged in through it, by checking
-- periodically instead of only at login.
C_Timer.NewTicker(60, function()
    if not GoldWQDB then return end
    local before = GoldWQDB.resetAt
    rollWeek()
    if before and GoldWQDB.resetAt ~= before and time() >= (before or 0) then
        me()
        snapshotCaches()
        requestScan(2)
        print("|cffffd100GoldWQ|r weekly reset detected, counters cleared.")
    end
end)

------------------------------------------------------------------
-- In-game window
------------------------------------------------------------------
local ui, content, optionsUI
local toggleOptions   -- defined after the window code
local setMinimapShown -- defined with the minimap button
local rows = {}
local ROW_H = 18

-- Show the world map on a zone. Re-applies once shortly after, because the map can
-- snap back to your current zone if it was already open.
local function showMap(mapID)
    if not WorldMapFrame:IsShown() then ToggleWorldMap() end
    WorldMapFrame:SetMapID(mapID)
    C_Timer.After(0.2, function()
        if WorldMapFrame:IsShown() and WorldMapFrame:GetMapID() ~= mapID then
            WorldMapFrame:SetMapID(mapID)
        end
    end)
end

-- Drop a waypoint on the quest, point the arrow at it, and open the map there.
-- The actual map/waypoint calls are deferred a frame (C_Timer.After(0, ...)) so they run
-- on a clean call stack, away from whatever triggered the click - the standard way to avoid
-- tainting the map/tooltip UI when a button handler touches WorldMapFrame.
local function openQuest(q)
    pcall(C_QuestLog.AddWorldQuestWatch, q.id)
    print("|cffffd100GoldWQ|r waypoint set: " .. q.title)
    C_Timer.After(0, function()
        if q.x and q.y and q.mapID and C_Map.CanSetUserWaypointOnMap(q.mapID) then
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(q.mapID, q.x, q.y))
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        else
            C_SuperTrack.SetSuperTrackedQuestID(q.id)
        end
        if q.mapID then showMap(q.mapID) end
    end)
end

------------------------------------------------------------------
-- TomTom route through every gold world quest
------------------------------------------------------------------
-- Fallback order for zones whose distance from Silvermoon can't be worked out.
local ROUTE_ORDER = { 2395, 2393, 2437, 2413, 2405, 2512 }
local routeState = {}   -- { { q = quest, uid = TomTom waypoint, title = text }, ... } still to do

local function pdist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Shorten an open path (first point stays fixed) by reversing segments.
local function twoOpt(p)
    local n, guard, improved = #p, 0, true
    while improved and guard < 50 do
        improved, guard = false, guard + 1
        for i = 1, n - 1 do
            for j = i + 1, n do
                local a, b, c, d = p[i], p[i + 1], p[j], p[j + 1]
                local before = pdist(a, b) + (d and pdist(c, d) or 0)
                local after = pdist(a, c) + (d and pdist(b, d) or 0)
                if after + 1e-9 < before then
                    local lo, hi = i + 1, j
                    while lo < hi do
                        p[lo], p[hi] = p[hi], p[lo]
                        lo, hi = lo + 1, hi - 1
                    end
                    improved = true
                end
            end
        end
    end
end

-- Zone by zone in ROUTE_ORDER; inside a zone, nearest-neighbour then 2-opt.
local function buildRoute()
    local byMap = {}
    for _, q in ipairs(available) do
        if q.x and q.y and q.mapID then
            byMap[q.mapID] = byMap[q.mapID] or {}
            table.insert(byMap[q.mapID], q)
        end
    end
    local maps, listed = {}, {}
    for _, m in ipairs(ROUTE_ORDER) do
        listed[m] = true
        if byMap[m] then maps[#maps + 1] = m end
    end
    for m in pairs(byMap) do
        if not listed[m] then maps[#maps + 1] = m end
    end

    -- order zones by how far they are from Silvermoon (using the game's world coordinates);
    -- zones the game can't measure (other continents/instances) follow in ROUTE_ORDER order
    local SILVERMOON = 2393
    local function centre(m)
        if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
        local cont, pos = C_Map.GetWorldPosFromMapPos(m, CreateVector2D(0.5, 0.5))
        if cont and pos then
            local x, y = pos:GetXY()
            return cont, x, y
        end
    end
    local idx = {}
    for i, m in ipairs(ROUTE_ORDER) do idx[m] = i end
    local hc, hx, hy = centre(SILVERMOON)
    local function key(m)
        if m == SILVERMOON then return 0 end
        local c, x, y = centre(m)
        if hc and c and c == hc then
            return 1 + math.sqrt((x - hx) ^ 2 + (y - hy) ^ 2)
        end
        return 1e9 + (idx[m] or 99)
    end
    table.sort(maps, function(a, b) return key(a) < key(b) end)

    local route = {}
    for _, m in ipairs(maps) do
        local remaining = {}
        for _, q in ipairs(byMap[m]) do remaining[#remaining + 1] = q end   -- already richest first

        -- start from where you stand if you are in this zone, otherwise from the richest quest
        local path, virtual = {}, false
        local pos = C_Map.GetPlayerMapPosition(m, "player")
        if pos then
            local px, py = pos:GetXY()
            if px and py then
                path[1] = { x = px, y = py }
                virtual = true
            end
        end
        if not virtual then path[1] = table.remove(remaining, 1) end

        while #remaining > 0 do
            local last, bi, bd = path[#path], 1, math.huge
            for i, q in ipairs(remaining) do
                local d = pdist(last, q)
                if d < bd then bi, bd = i, d end
            end
            path[#path + 1] = table.remove(remaining, bi)
        end
        twoOpt(path)

        for i, q in ipairs(path) do
            if not (virtual and i == 1) then route[#route + 1] = q end
        end
    end
    return route, maps
end

local function clearRoute()
    if TomTom and TomTom.RemoveWaypoint then
        for _, r in ipairs(routeState) do
            if r.uid then pcall(TomTom.RemoveWaypoint, TomTom, r.uid) end
        end
    end
    routeState = {}
end

local function pointArrow(r)
    if r and r.uid and TomTom and TomTom.SetCrazyArrow then
        local arrival = (TomTom.profile and TomTom.profile.arrow and TomTom.profile.arrow.arrival) or 10
        TomTom:SetCrazyArrow(r.uid, arrival, r.title)
    end
end

local function sendRoute()
    if not (TomTom and TomTom.AddWaypoint) then
        print("|cffffd100GoldWQ|r TomTom isn't loaded - install/enable it to use routes.")
        return
    end
    local route, maps = buildRoute()
    if #route == 0 then
        print("|cffffd100GoldWQ|r no gold world quests to route (try Rescan first).")
        return
    end
    clearRoute()
    for i, q in ipairs(route) do
        local title = ("%d. %s - %dg"):format(i, q.title, math.floor(q.copper / 10000))
        local uid = TomTom:AddWaypoint(q.mapID, q.x, q.y, {
            title = title, persistent = false, minimap = true, world = true, from = "GoldWQ",
        })
        routeState[#routeState + 1] = { q = q, uid = uid, title = title }
    end
    pointArrow(routeState[1])
    local names = {}
    for _, m in ipairs(maps) do
        local mi = C_Map.GetMapInfo(m)
        names[#names + 1] = (mi and mi.name) or tostring(m)
    end
    print(("|cffffd100GoldWQ|r route sent to TomTom: %d stops."):format(#route))
    print("|cffffd100GoldWQ|r zone order: " .. table.concat(names, " > "))
end

-- When you hand in a gold quest, drop its waypoint and point the arrow at the next stop.
local function advanceRoute(questID)
    if #routeState == 0 or not TomTom then return end
    for i, r in ipairs(routeState) do
        if r.q.id == questID then
            if r.uid and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, r.uid) end
            table.remove(routeState, i)
            if routeState[1] then
                pointArrow(routeState[1])
            else
                print("|cffffd100GoldWQ|r route complete!")
            end
            return
        end
    end
end

local function getRow(i)
    local r = rows[i]
    if not r then
        r = CreateFrame("Button", nil, content)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
        r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.text:SetPoint("LEFT", 4, 0)
        r.text:SetPoint("RIGHT", -4, 0)
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r.hl = r:CreateTexture(nil, "BACKGROUND")
        r.hl:SetAllPoints()
        r.hl:SetColorTexture(1, 0.82, 0, 0.14)
        r.hl:Hide()
        r:SetScript("OnEnter", function(self) if self.clickable then self.hl:Show() end end)
        r:SetScript("OnLeave", function(self) self.hl:Hide() end)
        rows[i] = r
    end
    return r
end

-- Work out where one known special assignment stands right now.
--   done   : the assignment quest is completed
--   up     : unlocked (3 world quests done) and available
--   locked : available this week in the zone but still locked
--   none   : not out this week
local function saState(sa)
    local timeLeft = C_TaskQuest.GetQuestTimeLeftSeconds
    if C_QuestLog.IsQuestFlaggedCompleted(sa.quest) then return "done" end

    -- Once unlocked, the real assignment behaves like a world quest: it can be "active"
    -- on the map without ever being formally accepted, so IsOnQuest alone can miss it.
    local questLive = C_QuestLog.IsOnQuest(sa.quest) or C_TaskQuest.IsActive(sa.quest) or timeLeft(sa.quest) ~= nil
    local unlocked = C_QuestLog.IsQuestFlaggedCompleted(sa.unlock) or questLive

    -- Same test WeeklyRewards uses: it is this week's assignment only if its
    -- placeholder is live, or the real quest turns out to be unlocked/live.
    local thisWeek = C_QuestLog.IsOnQuest(sa.unlock) or timeLeft(sa.unlock) or unlocked
    if not thisWeek then return "none" end
    local state = unlocked and "up" or "locked"

    local mapID
    for _, z in ipairs(ZONES) do
        if z[2] == sa.zone then mapID = z[1] end
    end
    local e = { id = sa.quest, title = "Special Assignment: " .. sa.name, zone = sa.zone, mapID = mapID,
                left = timeLeft(sa.quest) or timeLeft(sa.unlock) }
    if mapID and C_TaskQuest.GetQuestLocation then
        local x, y = C_TaskQuest.GetQuestLocation(sa.unlock, mapID)
        if not x then x, y = C_TaskQuest.GetQuestLocation(sa.quest, mapID) end
        e.x, e.y = x, y
    end
    return state, e
end

refreshUI = function()
    if not ui or not ui:IsShown() or not GoldWQDB then return end
    local n = 0
    local function add(text, onclick)
        n = n + 1
        local r = getRow(n)
        r.text:SetText(text)
        r:SetScript("OnClick", onclick)
        r.clickable = (onclick ~= nil)
        r.hl:Hide()
        r:Show()
    end

    -- Gold world quests, grouped by zone (zones with the most gold first)
    local total = 0
    local groups, zoneTotal, zoneNames = {}, {}, {}
    for _, q in ipairs(available) do
        total = total + q.copper
        if not groups[q.zone] then
            groups[q.zone] = {}
            zoneTotal[q.zone] = 0
            zoneNames[#zoneNames + 1] = q.zone
        end
        table.insert(groups[q.zone], q)
        zoneTotal[q.zone] = zoneTotal[q.zone] + q.copper
    end
    table.sort(zoneNames, function(x, y) return zoneTotal[x] > zoneTotal[y] end)
    add(("|cffffd100Gold world quests: %d (%s)|r"):format(#available, fmt(total)))
    if #available == 0 then
        add("  none found yet - click Rescan")
    end
    for _, zone in ipairs(zoneNames) do
        add(("  |cffffffff%s|r |cff999999- %d, %s|r"):format(zone, #groups[zone], fmt(zoneTotal[zone])))
        for _, q in ipairs(groups[zone]) do
            add(("      %s  %s |cff999999%s|r"):format(fmt(q.copper), q.title, fmtLeft(q.left)), function() openQuest(q) end)
        end
    end

    -- Special assignments (locked WQs that need 3 WQs done in the zone)
    add(" ")
    add("|cffffd100Special assignments|r")
    -- only one assignment per zone is out each week: keep the best match per zone
    local rank = { done = 3, up = 2, locked = 1 }
    local best = {}
    for _, sa in ipairs(GoldWQ_SpecialAssignments) do
        local state, e = saState(sa)
        if rank[state] and (not best[sa.zone] or rank[state] > best[sa.zone].rank) then
            best[sa.zone] = { rank = rank[state], sa = sa, state = state, e = e }
        end
    end
    for _, sa in ipairs(GoldWQ_SpecialAssignments) do
        local b = best[sa.zone]
        local state, e = "none", nil
        if b and b.sa == sa then state, e = b.state, b.e end
        local label = ("%s |cff999999[%s]|r"):format(sa.name, sa.zone)
        if state == "done" then
            add("  |cff00ff00done|r    " .. label)
        elseif state == "up" then
            add("  |cffffd100UP|r      " .. label .. " |cff999999" .. fmtLeft(e.left) .. "|r", function() openQuest(e) end)
        elseif state == "locked" then
            add("  |cffff9900locked|r  " .. label .. " |cff999999" .. fmtLeft(e.left) .. "|r", function() openQuest(e) end)
        end
    end
    -- any other assignment the scan spotted that isn't in the known list
    for _, q in ipairs(specials) do
        local known = false
        for _, sa in ipairs(GoldWQ_SpecialAssignments) do
            if q.id == sa.quest or q.id == sa.unlock or (q.title and q.title:find(sa.name, 1, true)) then known = true end
        end
        if not known then
            add(("  |cffffd100UP|r      %s |cff999999[%s] %s|r"):format(q.title, q.zone, fmtLeft(q.left)), function() openQuest(q) end)
        end
    end
    -- Progress toward the 3-world-quest unlock, using Blizzard's own objective data.
    -- The unlock quest (sa.unlock) contains the exact weekly objective, e.g.
    -- "Complete World Quests in Eversong Woods 0 / 3". This is more reliable than
    -- reconstructing progress from QUEST_TURNED_IN and wqDone, especially if the addon
    -- was not loaded when some of the world quests were completed.
    local function getSAProgress(sa)
        local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(sa.unlock)
        if not objectives then return nil, nil end

        for _, obj in ipairs(objectives) do
            if obj.numRequired and obj.numRequired > 0 then
                return obj.numFulfilled or 0, obj.numRequired
            end
        end

        return nil, nil
    end

    local header = false
    for _, sa in ipairs(GoldWQ_SpecialAssignments) do
        local b = best[sa.zone]
        if b and b.sa == sa and (b.state == "locked" or b.state == "up") then
            local done, required = getSAProgress(sa)
            if done ~= nil and required ~= nil then
                if not header then
                    add("  |cff999999World quests done toward the unlock:|r")
                    header = true
                end
                local colour = done >= required and "|cff00ff00" or "|cffffffff"
                add("    " .. sa.zone .. "  " .. colour .. done .. "/" .. required .. "|r")
            end
        end
    end

    -- Weekly caches for the character you are logged in on
    add(" ")
    add("|cffffd100Weekly caches|r")
    local cc = GoldWQDB.chars[charKey()]
    -- Unity Against the Void is the one-off unlock for the Apex chain, not a weekly quest,
    -- so this checks the permanent completed flag rather than the weekly turn-in log.
    add(("   |cff999999Unity Against the Void: %s|r"):format(
        C_QuestLog.IsQuestFlaggedCompleted(93744) and "|cff00ff00done|r" or "|cffff6060not done|r"))
    -- Trailing Xal'atath is on its own ~2-week cycle rather than weekly, so like Unity
    -- Against the Void this checks the permanent flag instead of the weekly turn-in log.
    add(("   |cff999999Trailing Xal'atath: %s|r"):format(
        C_QuestLog.IsQuestFlaggedCompleted(98172) and "|cff00ff00done|r" or "|cffff6060not done|r"))
    for _, cache in ipairs(trackedCaches()) do
        local done = ((cc and cc.caches) or {})[cache.name] or 0
        -- caches with several possible quests show the quest name instead of a count
        local extra = ""
        if #cache.quests > 1 then
            local names = {}
            if done > 0 then
                for _, id in ipairs(cache.quests) do
                    if cc.turnedIn[id] then names[#names + 1] = cc.turnedIn[id] end
                end
                if #names == 0 then names[1] = "quest name unavailable" end
            else
                for _, id in ipairs(cache.quests) do
                    if C_QuestLog.IsOnQuest(id) then
                        names[1] = C_QuestLog.GetTitleForQuestID(id) or "in progress"
                        break
                    end
                end
            end
            if #names > 0 then extra = " |cff999999- " .. table.concat(names, ", ") .. "|r" end
        end
        if done > 0 then
            add("   |cff00ff00done|r    " .. cache.name .. extra)
        else
            local fresh = cc and cc.trackingSince and (time() - cc.trackingSince) < 6 * 86400
            add("   |cffff6060to do|r   " .. cache.name .. (fresh and " |cff999999(may already be done - tracking just started)|r" or extra))
        end
    end

    for i = n + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(n * ROW_H, 1))
end

local function saveUI()
    if not ui or not GoldWQDB then return end
    if not GoldWQDB.collapsed then ui.fullHeight = ui:GetHeight() end
    local point, _, relPoint, x, y = ui:GetPoint()
    GoldWQDB.ui = { point = point, relPoint = relPoint, x = x, y = y,
                    w = ui:GetWidth(), h = ui.fullHeight or ui:GetHeight() }
end

local function buildUI()
    local saved = GoldWQDB.ui or {}
    ui = CreateFrame("Frame", "GoldWQFrame", UIParent, "BackdropTemplate")
    ui:SetSize(saved.w or 350, saved.h or 400)
    ui:SetScale(GoldWQDB.scale or 1)
    ui:SetPoint(saved.point or "CENTER", UIParent, saved.relPoint or "CENTER", saved.x or 0, saved.y or 0)
    ui:SetFrameStrata("MEDIUM")
    ui:SetClampedToScreen(false)
    ui:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    ui:SetBackdropColor(0.04, 0.04, 0.07, GoldWQDB.alpha or 0.72)
    ui:SetBackdropBorderColor(1, 1, 1, GoldWQDB.noBorder and 0 or 0.12)

    -- drag to move, grip to resize
    ui:SetMovable(true)
    ui:EnableMouse(true)
    ui:RegisterForDrag("LeftButton")
    ui:SetScript("OnDragStart", ui.StartMoving)
    ui:SetScript("OnDragStop", function() ui:StopMovingOrSizing(); saveUI() end)
    ui:SetResizable(true)
    if ui.SetResizeBounds then ui:SetResizeBounds(350, 200, 800, 1000) end

    -- title bar
    local title = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("GoldWQ")

    local line = ui:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.10)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 10, -32)
    line:SetPoint("TOPRIGHT", -10, -32)

    local close = CreateFrame("Button", nil, ui)
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", -8, -8)
    close.t = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    close.t:SetPoint("CENTER")
    close.t:SetText("x")
    close:SetScript("OnClick", function() ui:Hide() end)

    local rescan = CreateFrame("Button", nil, ui)
    rescan:SetSize(54, 18)
    rescan:SetPoint("TOPRIGHT", -34, -10)
    rescan.t = rescan:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rescan.t:SetPoint("CENTER")
    rescan.t:SetText("Rescan")
    rescan:SetScript("OnClick", function() requestScan(0) end)
    rescan:SetScript("OnEnter", function(self) self.t:SetTextColor(1, 0.82, 0) end)
    rescan:SetScript("OnLeave", function(self) self.t:SetTextColor(1, 1, 1) end)

    local routeBtn = CreateFrame("Button", nil, ui)
    routeBtn:SetSize(84, 18)
    routeBtn:SetPoint("TOPRIGHT", -92, -10)
    routeBtn.t = routeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    routeBtn.t:SetPoint("CENTER")
    routeBtn.t:SetText("TomTom route")
    routeBtn:SetScript("OnClick", sendRoute)
    routeBtn:SetScript("OnEnter", function(self) self.t:SetTextColor(1, 0.82, 0) end)
    routeBtn:SetScript("OnLeave", function(self) self.t:SetTextColor(1, 1, 1) end)

    local optBtn = CreateFrame("Button", nil, ui)
    optBtn:SetSize(50, 18)
    optBtn:SetPoint("TOPLEFT", 104, -10)
    optBtn.t = optBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optBtn.t:SetPoint("CENTER")
    optBtn.t:SetText("Options")
    optBtn:SetScript("OnClick", function() toggleOptions() end)
    optBtn:SetScript("OnEnter", function(self) self.t:SetTextColor(1, 0.82, 0) end)
    optBtn:SetScript("OnLeave", function(self) self.t:SetTextColor(1, 1, 1) end)

    -- slim scroll area (mouse wheel), width follows the window
    local scroll = CreateFrame("ScrollFrame", nil, ui)
    scroll:SetPoint("TOPLEFT", 10, -38)
    scroll:SetPoint("BOTTOMRIGHT", -10, 24)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(340, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.min(math.max(self:GetVerticalScroll() - delta * ROW_H * 3, 0), max))
    end)

    local grip = CreateFrame("Button", nil, ui)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() ui:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() ui:StopMovingOrSizing(); saveUI() end)

    -- collapse to just the title bar
    ui.fullHeight = saved.h or 400
    local cbtn = CreateFrame("Button", nil, ui)
    cbtn:SetSize(18, 18)
    cbtn:SetPoint("TOPLEFT", 80, -10)
    cbtn.t = cbtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cbtn.t:SetPoint("CENTER")
    local function anchorTopLeft()
      local left, top = ui:GetLeft(), ui:GetTop()
      if left and top then
        ui:ClearAllPoints()
        ui:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
      end
    end
    local function applyCollapse()
       anchorTopLeft()
        if GoldWQDB.collapsed then
            scroll:Hide()
            grip:Hide()
            ui:SetHeight(34)
            cbtn.t:SetText("+")
        else
            scroll:Show()
            grip:Show()
            ui:SetHeight(ui.fullHeight)
            cbtn.t:SetText("-")
        end
    end
    ui.setCollapsed = function(v)
        if v and not GoldWQDB.collapsed then ui.fullHeight = ui:GetHeight() end
        GoldWQDB.collapsed = v and true or false
        applyCollapse()
        saveUI()
    end
    cbtn:SetScript("OnClick", function()
        ui.setCollapsed(not GoldWQDB.collapsed)
        if optionsUI and optionsUI.sync then optionsUI.sync() end
    end)
    applyCollapse()

    ui:SetScript("OnShow", function()
        snapshotCaches()
        refreshUI()
        requestScan(0)
    end)
    ui:Hide()
end

------------------------------------------------------------------
-- Options menu
------------------------------------------------------------------
local function resetWindow()
    GoldWQDB.ui, GoldWQDB.scale, GoldWQDB.alpha, GoldWQDB.collapsed = nil, nil, nil, false
    GoldWQDB.openOnLogin = nil
    GoldWQDB.noBorder = false
    GoldWQDB.disabledCaches = {}
    if GoldWQDB.minimap then GoldWQDB.minimap.hide = false end
    if setMinimapShown then setMinimapShown(true) end
    if ui then
        ui:ClearAllPoints()
        ui:SetPoint("CENTER")
        ui.fullHeight = 400
        ui:SetSize(350, 400)
        ui:SetScale(1)
        ui:SetBackdropColor(0.04, 0.04, 0.07, 0.72)
        ui:SetBackdropBorderColor(1, 1, 1, 0.12)
        ui.setCollapsed(false)
    end
    if optionsUI then optionsUI.sync() end
end

local function makeSlider(parent, label, minV, maxV, step, y, setter)
    local txt = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    txt:SetPoint("TOPLEFT", 14, y)
    local sl = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    sl:SetOrientation("HORIZONTAL")
    sl:SetPoint("TOPLEFT", 14, y - 20)
    sl:SetSize(220, 10)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    sl:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    sl:SetBackdropColor(1, 1, 1, 0.15)
    sl:SetThumbTexture("Interface\\Buttons\\WHITE8x8")
    local th = sl:GetThumbTexture()
    th:SetSize(8, 16)
    th:SetVertexColor(1, 0.82, 0, 1)
    sl:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        txt:SetText(("%s: %.2f"):format(label, v))
        setter(v)
    end)
    return sl
end

local function buildOptions()
    optionsUI = CreateFrame("Frame", "GoldWQOptions", UIParent, "BackdropTemplate")
    optionsUI:SetSize(256, 320)
    optionsUI:SetPoint("CENTER", 0, 60)
    optionsUI:SetFrameStrata("DIALOG")
    optionsUI:SetClampedToScreen(true)
    optionsUI:SetMovable(true)
    optionsUI:EnableMouse(true)
    optionsUI:RegisterForDrag("LeftButton")
    optionsUI:SetScript("OnDragStart", optionsUI.StartMoving)
    optionsUI:SetScript("OnDragStop", optionsUI.StopMovingOrSizing)
    optionsUI:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    optionsUI:SetBackdropColor(0.04, 0.04, 0.07, 0.94)
    optionsUI:SetBackdropBorderColor(1, 1, 1, 0.15)
    table.insert(UISpecialFrames, "GoldWQOptions")

    local title = optionsUI:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("GoldWQ options")

    local close = CreateFrame("Button", nil, optionsUI)
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", -8, -8)
    close.t = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    close.t:SetPoint("CENTER")
    close.t:SetText("x")
    close:SetScript("OnClick", function() optionsUI:Hide() end)

    local scaleSlider = makeSlider(optionsUI, "Window scale", 0.5, 1.5, 0.05, -44, function(v)
        GoldWQDB.scale = v
        if ui then ui:SetScale(v) end
    end)
    local alphaSlider = makeSlider(optionsUI, "Background opacity", 0, 1, 0.05, -92, function(v)
        GoldWQDB.alpha = v
        if ui then ui:SetBackdropColor(0.04, 0.04, 0.07, v) end
    end)

    local cb = CreateFrame("CheckButton", nil, optionsUI, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 8, -128)
    cb:SetSize(24, 24)
    local cbText = optionsUI:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cbText:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cbText:SetText("Collapse to title bar")
    cb:SetScript("OnClick", function(self)
        if ui then ui.setCollapsed(self:GetChecked() and true or false) end
    end)

    local cb2 = CreateFrame("CheckButton", nil, optionsUI, "UICheckButtonTemplate")
    cb2:SetPoint("TOPLEFT", 8, -154)
    cb2:SetSize(24, 24)
    local cb2Text = optionsUI:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb2Text:SetPoint("LEFT", cb2, "RIGHT", 4, 0)
    cb2Text:SetText("Open window on login")
    cb2:SetScript("OnClick", function(self)
        GoldWQDB.openOnLogin = self:GetChecked() and true or false
    end)

    local cbBorder = CreateFrame("CheckButton", nil, optionsUI, "UICheckButtonTemplate")
    cbBorder:SetPoint("TOPLEFT", 8, -206)
    cbBorder:SetSize(24, 24)
    local cbBorderText = optionsUI:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cbBorderText:SetPoint("LEFT", cbBorder, "RIGHT", 4, 0)
    cbBorderText:SetText("Remove border")
    cbBorder:SetScript("OnClick", function(self)
        GoldWQDB.noBorder = self:GetChecked() and true or false
        if ui then ui:SetBackdropBorderColor(1, 1, 1, GoldWQDB.noBorder and 0 or 0.12) end
    end)

    local cb3 = CreateFrame("CheckButton", nil, optionsUI, "UICheckButtonTemplate")
    cb3:SetPoint("TOPLEFT", 8, -180)
    cb3:SetSize(24, 24)
    local cb3Text = optionsUI:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb3Text:SetPoint("LEFT", cb3, "RIGHT", 4, 0)
    cb3Text:SetText("Show minimap button")
    cb3:SetScript("OnClick", function(self)
        setMinimapShown(self:GetChecked() and true or false)
    end)

    -- one checkbox per real (non-empty) cache, so people can pick what gets tracked
    local trackHdr = optionsUI:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    trackHdr:SetPoint("TOPLEFT", 12, -232)
    trackHdr:SetText("Track these weekly caches:")
    local cacheChecks, y = {}, -252
    for _, cache in ipairs(GoldWQ_Caches) do
        if #cache.quests > 0 then
            local cb = CreateFrame("CheckButton", nil, optionsUI, "UICheckButtonTemplate")
            cb:SetPoint("TOPLEFT", 8, y)
            cb:SetSize(20, 20)
            local fs = optionsUI:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            fs:SetText(cache.name)
            cb:SetScript("OnClick", function(self)
                GoldWQDB.disabledCaches = GoldWQDB.disabledCaches or {}
                GoldWQDB.disabledCaches[cache.name] = not (self:GetChecked() and true or false)
                if refreshUI then refreshUI() end
            end)
            cacheChecks[cache.name] = cb
            y = y - 24
        end
    end
    optionsUI:SetHeight(-y + 50)

    local reset = CreateFrame("Button", nil, optionsUI)
    reset:SetSize(150, 20)
    reset:SetPoint("TOPLEFT", 12, y - 8)
    reset.t = reset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reset.t:SetPoint("LEFT")
    reset.t:SetText("Reset window to default")
    reset:SetScript("OnClick", resetWindow)
    reset:SetScript("OnEnter", function(self) self.t:SetTextColor(1, 0.82, 0) end)
    reset:SetScript("OnLeave", function(self) self.t:SetTextColor(1, 1, 1) end)
    reset:SetWidth(200)

    optionsUI.sync = function()
        scaleSlider:SetValue(GoldWQDB.scale or 1)
        alphaSlider:SetValue(GoldWQDB.alpha or 0.72)
        cb:SetChecked(GoldWQDB.collapsed and true or false)
        cb2:SetChecked(GoldWQDB.openOnLogin ~= false)
        cb3:SetChecked(not (GoldWQDB.minimap and GoldWQDB.minimap.hide))
        cbBorder:SetChecked(GoldWQDB.noBorder and true or false)
        for name, cb in pairs(cacheChecks) do
            cb:SetChecked(cacheEnabled(name))
        end
    end
    optionsUI:SetScript("OnShow", optionsUI.sync)
    optionsUI:Hide()
end

toggleOptions = function()
    if not ui then buildUI() end
    if not optionsUI then buildOptions() end
    if optionsUI:IsShown() then optionsUI:Hide() else optionsUI:Show() end
end

local function toggleUI()
    if not ui then buildUI() end
    if ui:IsShown() then ui:Hide() else ui:Show() end
end

------------------------------------------------------------------
-- Chat output (still available)
------------------------------------------------------------------
local function showAvailable()
    if #available == 0 then
        print("|cffffd100GoldWQ|r no gold world quests found (try /gwq scan in a moment).")
        return
    end
    print("|cffffd100GoldWQ|r gold world quests available now:")
    for _, q in ipairs(available) do
        print(("  %s - %s [%s]"):format(fmt(q.copper), q.title, q.zone))
    end
end

local function report()
    print("|cffffd100GoldWQ|r this week (resets at weekly reset):")
    for name, c in pairs(GoldWQDB.chars) do
        local n = 0
        for _ in pairs(c.weekQuests) do n = n + 1 end
        print(("  %s: %d gold WQs, %s (lifetime %s)"):format(name, n, fmt(c.weekCopper), fmt(c.totalCopper)))
        for _, cache in ipairs(GoldWQ_Caches) do
            local done = (c.caches or {})[cache.name] or 0
            print(("     %s: %d/%d quests done"):format(cache.name, done, #cache.quests))
        end
    end
end

------------------------------------------------------------------
-- Minimap button (goblin)
--  * If LibDataBroker + LibDBIcon are loaded (most addon suites embed them) the button
--    is registered through them, so minimap-button collectors handle it like any other.
--  * Otherwise a button with the same name/layout (LibDBIcon10_GoldWQ) is built by hand.
------------------------------------------------------------------
local MM_ICON = 4638725
local mmButton, dbicon

local function mmTooltip(tt)
    tt:AddLine("GoldWQ")
    tt:AddLine("Left-click: show / hide window", 1, 1, 1)
    tt:AddLine("Right-click: options", 1, 1, 1)
    tt:AddLine("Drag: move this button", 1, 1, 1)
end

local function mmClick(_, button)
    if button == "RightButton" then toggleOptions() else toggleUI() end
end

local function placeMinimapButton()
    local angle = math.rad(GoldWQDB.minimap.minimapPos or 220)
    local rw = Minimap:GetWidth() / 2 + 5
    local rh = Minimap:GetHeight() / 2 + 5
    local x, y = math.cos(angle), math.sin(angle)
    if GetMinimapShape and GetMinimapShape() == "SQUARE" then
        x = math.max(-rw, math.min(x * rw * 1.4142, rw))
        y = math.max(-rh, math.min(y * rh * 1.4142, rh))
    else
        x, y = x * rw, y * rh
    end
    mmButton:ClearAllPoints()
    mmButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function createMinimapButton()
    GoldWQDB.minimap = GoldWQDB.minimap or {}
    if GoldWQDB.minimap.hide == nil then GoldWQDB.minimap.hide = false end

    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if LDB and DBIcon then
        local obj = LDB:NewDataObject("GoldWQ", {
            type = "launcher", label = "GoldWQ", icon = MM_ICON,
            OnClick = mmClick, OnTooltipShow = mmTooltip,
        }) or LDB:GetDataObjectByName("GoldWQ")
        DBIcon:Register("GoldWQ", obj, GoldWQDB.minimap)
        dbicon = DBIcon
        return
    end

    -- hand-built button, laid out the way LibDBIcon does it
    local b = CreateFrame("Button", "LibDBIcon10_GoldWQ", Minimap)
    mmButton = b
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetSize(31, 31)
    b:RegisterForClicks("anyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(MM_ICON)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetPoint("TOPLEFT", 7, -6)
    b.icon = icon

    b:SetScript("OnClick", mmClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        mmTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            GoldWQDB.minimap.minimapPos = math.deg(math.atan2(py - my, px - mx)) % 360
            placeMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    placeMinimapButton()
    b:SetShown(not GoldWQDB.minimap.hide)
end

setMinimapShown = function(v)
    GoldWQDB.minimap = GoldWQDB.minimap or {}
    GoldWQDB.minimap.hide = not v
    if dbicon then
        if v then dbicon:Show("GoldWQ") else dbicon:Hide("GoldWQ") end
    elseif mmButton then
        mmButton:SetShown(v)
    end
end

f:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        GoldWQDB = GoldWQDB or {}
        GoldWQDB.chars = GoldWQDB.chars or {}
        rollWeek()
        me()
        snapshotCaches()
        createMinimapButton()
        announce = true
        requestScan(3)
        if GoldWQDB.openOnLogin ~= false then
            C_Timer.After(2, function()
                if not ui then buildUI() end
                ui:Show()
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if GoldWQDB then requestScan(2) end
    elseif event == "QUEST_LOG_UPDATE" then
        if GoldWQDB then requestScan(1) end
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        -- Extra trigger on top of the timer retries; capped so it can never loop forever.
        if GoldWQDB and stillUnloaded > 0 and eventScans < 30 then
            eventScans = eventScans + 1
            requestScan(1)
        end
    elseif event == "QUEST_TURNED_IN" then
        local questID, _, money = ...
        advanceRoute(questID)
        me().turnedIn[questID] = questTitle(questID)
        local isWQ = knownZone[questID] ~= nil or C_QuestLog.IsWorldQuest(questID)
        if isWQ then
            me().wqDone[questID] = knownZone[questID] or zoneName(questID, "Unknown zone")
        end
        if money and money > 0 and isWQ then
            local c = me()
            if not c.weekQuests[questID] then
                c.weekQuests[questID] = money
                c.weekCopper = c.weekCopper + money
                c.totalCopper = c.totalCopper + money
                print("|cffffd100GoldWQ|r +" .. fmt(money))
            end
        end
        C_Timer.After(1, snapshotCaches)
        requestScan(2)
    end
end)

SLASH_GOLDWQ1 = "/gwq"
SlashCmdList.GOLDWQ = function(msg)
    msg = (msg or ""):lower()
    if msg == "list" then
        showAvailable()
    elseif msg == "scan" then
        announce = true
        requestScan(0)
    elseif msg == "report" then
        report()
    elseif msg == "sa" then
        print("|cffffd100GoldWQ|r special assignment checks (U = locked placeholder, Q = the assignment):")
        for _, sa in ipairs(GoldWQ_SpecialAssignments) do
            local T = C_TaskQuest.GetQuestTimeLeftSeconds
            print(("  %s [%s] -> %s | U: onQ=%s left=%s active=%s done=%s onMap=%s | Q: onQ=%s left=%s active=%s done=%s onMap=%s"):format(
                sa.name, sa.zone, saState(sa),
                tostring(C_QuestLog.IsOnQuest(sa.unlock)), tostring(T(sa.unlock)),
                tostring(C_TaskQuest.IsActive(sa.unlock)), tostring(C_QuestLog.IsQuestFlaggedCompleted(sa.unlock)),
                tostring(seenPOI[sa.unlock] == true),
                tostring(C_QuestLog.IsOnQuest(sa.quest)), tostring(T(sa.quest)),
                tostring(C_TaskQuest.IsActive(sa.quest)), tostring(C_QuestLog.IsQuestFlaggedCompleted(sa.quest)),
                tostring(seenPOI[sa.quest] == true)))
        end
    elseif msg == "route" then
        sendRoute()
    elseif msg == "clearroute" then
        clearRoute()
        print("|cffffd100GoldWQ|r route cleared.")
    elseif msg == "map" then
        local id = C_Map.GetBestMapForUnit("player")
        local info = id and C_Map.GetMapInfo(id)
        print(("|cffffd100GoldWQ|r map ID: %s (%s)"):format(tostring(id), info and info.name or "?"))
    elseif msg == "minimap" then
        setMinimapShown(GoldWQDB.minimap and GoldWQDB.minimap.hide == true)
    elseif msg == "options" or msg == "config" then
        toggleOptions()
    elseif msg:match("^scale") then
        local sc = tonumber(msg:match("^scale%s+([%d%.]+)"))
        if sc then
            GoldWQDB.scale = math.min(math.max(sc, 0.5), 1.5)
            if ui then ui:SetScale(GoldWQDB.scale) end
        else
            print("|cffffd100GoldWQ|r usage: /gwq scale 0.5 - 1.5 (window size)")
        end
    elseif msg:match("^alpha") then
        local a = tonumber(msg:match("^alpha%s+([%d%.]+)"))
        if a then
            GoldWQDB.alpha = math.min(math.max(a, 0.1), 1)
            if ui then ui:SetBackdropColor(0.04, 0.04, 0.07, GoldWQDB.alpha) end
        else
            print("|cffffd100GoldWQ|r usage: /gwq alpha 0.1 - 1 (window opacity)")
        end
    elseif msg:match("^names") then
        -- /gwq names 89347 92139 91804 ... - prints each ID's quest title
        print("|cffffd100GoldWQ|r quest names:")
        for id in msg:gmatch("(%d+)") do
            local n = tonumber(id)
            print(("  %d  %s"):format(n, questTitle(n)))
        end
    elseif msg == "zones" then
        local cc4 = GoldWQDB.chars[charKey()]
        print("|cffffd100GoldWQ|r world quests counted toward zone unlocks this week:")
        local any = false
        for id, zone in pairs((cc4 and cc4.wqDone) or {}) do
            any = true
            print(("  %d  [%s]"):format(id, zone))
        end
        if not any then print("  (none logged yet)") end
    elseif msg == "turned" then
        print("|cffffd100GoldWQ|r current character key: " .. charKey())
        local names = {}
        for k in pairs(GoldWQDB.chars) do names[#names + 1] = k end
        table.sort(names)
        print("|cffffd100GoldWQ|r all character keys stored: " .. table.concat(names, ", "))
        local cc3 = GoldWQDB.chars[charKey()]
        print("|cffffd100GoldWQ|r quests turned in this week (this character):")
        local any = false
        for id, name in pairs((cc3 and cc3.turnedIn) or {}) do
            any = true
            print(("  %d  %s"):format(id, name))
        end
        if not any then print("  (none logged yet)") end
        print("|cffffd100GoldWQ|r cache counts stored for this character:")
        for name2, n in pairs((cc3 and cc3.caches) or {}) do
            print(("  %s = %d"):format(name2, n))
        end
    elseif msg == "apex" then
        print("|cffffd100GoldWQ|r Apex Cache quest IDs (lifetime flag rarely resets - check 'this week' instead):")
        local cc2 = GoldWQDB.chars[charKey()]
        for _, cache in ipairs(GoldWQ_Caches) do
            if cache.name == "Apex Cache" then
                for _, id in ipairs(cache.quests) do
                    local nm = C_QuestLog.GetTitleForQuestID(id) or "(name unavailable)"
                    print(("  %d  %s  lifetime=%s  this week=%s"):format(id, nm,
                        tostring(C_QuestLog.IsQuestFlaggedCompleted(id)), tostring(cc2.turnedIn[id] ~= nil)))
                end
            end
        end
    elseif msg == "debug" then
        print("|cffffd100GoldWQ|r active world quests: " .. #activeList)
        for _, a in ipairs(activeList) do
            print(("  %s [%s] %s -> %s | %s"):format(a.entry.title, a.entry.zone, fmtLeft(a.entry.left),
                a.rew ~= "" and a.rew or "no item", a.entry.flags))
        end
        print("|cffffd100GoldWQ|r skipped: " .. #skippedList)
        for _, k in ipairs(skippedList) do
            print(("  %s [%s] %d - %s | %s"):format(k.title, k.zone, k.id, k.reason, k.flags))
        end
    else
        toggleUI()
    end
end
