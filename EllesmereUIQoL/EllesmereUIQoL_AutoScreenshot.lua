if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_AutoScreenshot.lua
--  Auto Screenshots: a screenshot on level up, achievements, boss kills,
--  deaths, Mythic+ completions, PvP wins, first raid entries and zone
--  discoveries, optionally with the interface
--  hidden and a card of the event (EllesmereUIQoL_AutoScreenshotCard.lua).
--  /euishot takes one clean screenshot now.
--
--  Taint: the interface is hidden with UIParent:SetAlpha(0), never Hide() or
--  SetUIVisibility(), so no Blizzard OnHide/OnShow code (CloseAllWindows, the
--  managed frame layout) runs inside this addon's call.
-------------------------------------------------------------------------------
local ns  = select(2, ...)
local EUI = EllesmereUI
local CC  = EUI.COLOR_CODES
local IS_FOREVER = EUI.IS_FOREVER
local issecretvalue = issecretvalue or function() return false end

local MAX_QUEUE = 4     -- a burst (several achievements at once) keeps at most this many
local GAP       = 0.5   -- seconds between two queued shots
local FAILSAFE  = 3     -- restores the UI if no screenshot result arrives

-- Off by default; the trigger toggles default as below once the master is on.
local function On(k)  local db = EllesmereUIDB; return db ~= nil and db[k] ~= false end
local function Opt(k) local db = EllesmereUIDB; return db ~= nil and db[k] == true end
local function Num(k, d)
    local v = EllesmereUIDB and EllesmereUIDB[k]
    return type(v) == "number" and v or d
end
local function Enabled() return Opt("autoShot") end

local PREFIX = CC.BRAND .. "EllesmereUI:|r "
local function Say(msg) EUI.Print(PREFIX .. msg) end

-------------------------------------------------------------------------------
--  Capture queue: one shot at a time, so hide/restore never overlap.
-------------------------------------------------------------------------------
local queue, busy = {}, false
local shotID, inFlight, savedAlpha = 0, nil, nil
local waitID = 0
local Process

local function Done()
    busy = false
    if #queue > 0 then C_Timer.After(GAP, Process) end
end

-- Image format: the screenshot CVars are held only around our own shot,
-- out of combat, through EUI's CVar record, and put back right after.
local OWNER = "EllesmereUIQoL"
local heldFormat, heldQuality

local function HoldFormat()
    local fmt = EllesmereUIDB and EllesmereUIDB.autoShotFormat
    if type(fmt) ~= "string" or fmt == "game" or InCombatLockdown() then return end
    local cur = C_CVar.GetCVar("screenshotFormat")
    if cur ~= nil and cur ~= fmt and EUI.HoldCVar("screenshotFormat", fmt, OWNER) then heldFormat = cur end
    if fmt ~= "jpeg" then return end
    local q, curQ = tostring(Num("autoShotQuality", 9)), C_CVar.GetCVar("screenshotQuality")
    if curQ ~= nil and curQ ~= q and EUI.HoldCVar("screenshotQuality", q, OWNER) then heldQuality = curQ end
end

local function ReleaseFormat()
    if not (heldFormat or heldQuality) then return end
    if InCombatLockdown() then
        ns.CombatQueue.Defer("AutoScreenshotFormat", ReleaseFormat)
        return
    end
    if heldFormat then EUI.ReleaseCVar("screenshotFormat", heldFormat, OWNER); heldFormat = nil end
    if heldQuality then EUI.ReleaseCVar("screenshotQuality", heldQuality, OWNER); heldQuality = nil end
end

-- Stock game sounds by SOUNDKIT name (present on both clients).
local SOUNDS = {
    camera = "REPORT_SCREENSHOT_CAMERA", ready = "READY_CHECK", quest = "IG_QUEST_LIST_COMPLETE",
    ping = "MAP_PING", epic = "UI_EPICLOOT_TOAST",
}

local function PlayShotSound()
    local name = SOUNDS[EllesmereUIDB and EllesmereUIDB.autoShotSound or ""]
    local kit = name and SOUNDKIT and SOUNDKIT[name]
    if type(kit) == "number" then PlaySound(kit) end
end

local function Finish(id, ok)
    if id ~= shotID or not inFlight then return end
    local job = inFlight
    inFlight = nil
    EUI._autoShotResult = nil
    if savedAlpha then
        if UIParent:GetAlpha() == 0 then UIParent:SetAlpha(savedAlpha) end
        savedAlpha = nil
    end
    ns.AutoShotCard.Hide()
    ReleaseFormat()
    if ok then PlayShotSound() end
    if ok and On("autoShotChat") then
        Say(EllesmereUI.Lf("Screenshot taken: %1$s", job.label or "/euishot"))
    end
    Done()
end

-- In a group inside a dungeon or raid.
local function InGroupInstance()
    if not IsInGroup() then return false end
    local _, instanceType = IsInInstance()
    return instanceType == "party" or instanceType == "raid"
end

local function Shoot(job)
    local combat = InCombatLockdown()
    if job.clean and combat then
        EUI.PrintError(EllesmereUI.L("You are in combat."))
        return Done()
    end
    if not job.clean and not Enabled() then return Done() end
    shotID = shotID + 1
    local id = shotID
    inFlight = job
    -- Scheduled first: the UI comes back even if anything below fails.
    C_Timer.After(FAILSAFE, function() Finish(id, false) end)
    -- Out of combat only, even though SetAlpha is not a protected call.
    if not combat and (job.clean or On("autoShotHideUI")) then
        savedAlpha = UIParent:GetAlpha()
        UIParent:SetAlpha(0)
        if job.card and On("autoShotCaption") then ns.AutoShotCard.Show(job) end
        if job.card and On("autoShotRoster") and (job.roster or InGroupInstance()) then
            ns.AutoShotCard.ShowRoster()
        end
    end
    -- One short wait so the hidden UI and the card are drawn first. The
    -- Hide Screenshot Status listener (EllesmereUIQoL.lua) hands the
    -- SCREENSHOT_SUCCEEDED / _FAILED result to _autoShotResult.
    C_Timer.After(savedAlpha and 0.1 or 0, function()
        if id ~= shotID or not inFlight then return end
        EUI._autoShotResult = function(event) Finish(id, event == "SCREENSHOT_SUCCEEDED") end
        HoldFormat()
        Screenshot()
    end)
end

local function AfterDelay(job)
    local d = job.clean and 0 or Num("autoShotDelay", 1)
    if job.minDelay and d < job.minDelay then d = job.minDelay end
    C_Timer.After(d, function() Shoot(job) end)
end

-- Boss kills: give combat up to N seconds to drop so the UI can be hidden.
local function WaitCombat(job, secs)
    waitID = waitID + 1
    local id = waitID
    local function go()
        if id ~= waitID then return end
        waitID = waitID + 1
        AfterDelay(job)
    end
    ns.CombatQueue.Defer("AutoScreenshot", go)
    C_Timer.After(secs, go)
end

Process = function()
    if busy then return end
    local job = table.remove(queue, 1)
    if not job then return end
    busy = true
    local secs = job.waitCombat and Num("autoShotBossWait", 3) or 0
    if secs > 0 and InCombatLockdown() and On("autoShotHideUI") then
        WaitCombat(job, secs)
    else
        AfterDelay(job)
    end
end

local function Request(job)
    if #queue >= MAX_QUEUE then return end
    queue[#queue + 1] = job
    Process()
end

-------------------------------------------------------------------------------
--  Triggers
-------------------------------------------------------------------------------
local function Known(v, kind)
    return not issecretvalue(v) and type(v) == kind
end

local function MaxLevel()
    if GetMaxLevelForPlayerExpansion then return GetMaxLevelForPlayerExpansion() end
    if GetMaxPlayerLevel then return GetMaxPlayerLevel() end
end

local function Str(v) return Known(v, "string") and v ~= "" and v or nil end

-- Card lines: { text, r, g, b, big }
local function Big(text) return { text, 1, 1, 1, true } end
local function Dim(text) return { text, 0.75, 0.75, 0.75 } end
local function Colored(text, r, g, b) return { text, r, g, b } end

local function Clock(sec)
    sec = math.floor(sec + 0.5)
    if sec >= 3600 then
        return ("%d:%02d:%02d"):format(math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
    end
    return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local function CharKey() return UnitName("player") .. " - " .. GetRealmName() end

-- First kills per character: EllesmereUIDB.autoShotKills["Name - Realm"][difficultyID][encounterID].
local function SeenKill(difficultyID, encounterID)
    local db = EllesmereUIDB
    if not db then return false end
    if type(db.autoShotKills) ~= "table" then db.autoShotKills = {} end
    local charKey = CharKey()
    local mine = db.autoShotKills[charKey]
    if not mine then mine = {}; db.autoShotKills[charKey] = mine end
    local diff = mine[difficultyID]
    if not diff then diff = {}; mine[difficultyID] = diff end
    local seen = diff[encounterID] == true
    diff[encounterID] = true
    return seen
end

-- Places seen per character: EllesmereUIDB[store]["Name - Realm"][key]. True the first time.
local function FirstVisit(store, key)
    local db = EllesmereUIDB
    if not db then return false end
    if type(db[store]) ~= "table" then db[store] = {} end
    local charKey = CharKey()
    local mine = db[store][charKey]
    if not mine then mine = {}; db[store][charKey] = mine end
    if mine[key] then return false end
    mine[key] = true
    return true
end

-- Capital cities by uiMapID (wago.tools UiMap). WoW Forever uses the classic
-- map IDs, the six capitals EllesmereUIForeverEssentials_ZoneLevels.lua lists.
local CAPITALS = IS_FOREVER and {
    [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true,
} or {
    [84] = true, [85] = true, [87] = true, [88] = true, [89] = true, [90] = true,   -- Stormwind .. Undercity
    [103] = true, [110] = true, [111] = true,                                     -- Exodar, Silvermoon, Shattrath
    [125] = true, [126] = true, [627] = true, [628] = true,                       -- Dalaran (Northrend, Broken Isles)
    [1161] = true, [1165] = true,                                                 -- Boralus, Dazar'alor
    [1670] = true, [1671] = true, [1672] = true, [1673] = true,                   -- Oribos
    [2112] = true, [2339] = true, [2393] = true,                                   -- Valdrakken, Dornogal, Silvermoon (Midnight)
}

local function RaidEntry()
    local name, instanceType, _, difficultyName, _, _, _, instanceID = GetInstanceInfo()
    if issecretvalue(instanceType) or instanceType ~= "raid" or not Known(instanceID, "number") then return end
    if not FirstVisit("autoShotRaids", instanceID) then return end
    name = Str(name)
    Request({ label = name or EllesmereUI.L("First Raid Entry"), roster = true, minDelay = 3,
              card = { title = EllesmereUI.L("First Raid Entry"),
                       lines = { Big(name), Dim(Str(difficultyName)) } } })
end

-- MAP_EXPLORATION_UPDATED has no payload: the player's map tells the place.
local function Discovery()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not Known(mapID, "number") then return end
    local zoneID, zoneName, capital, continent
    local id = mapID
    for _ = 1, 10 do
        local info = C_Map.GetMapInfo(id)
        if not info then break end
        if CAPITALS[id] then capital = id end
        if not zoneID and info.mapType == Enum.UIMapType.Zone then zoneID, zoneName = id, info.name end
        if info.mapType == Enum.UIMapType.Continent then continent = info.name; break end
        id = info.parentMapID
        if not Known(id, "number") or id == 0 then break end
    end
    local mode = EllesmereUIDB and EllesmereUIDB.autoShotZoneMode or "capitals"
    local key
    if mode == "all" then
        local sub = GetSubZoneText()
        key = "a" .. (zoneID or mapID) .. ":" .. (Str(sub) or "")
    elseif mode == "zones" then
        key = zoneID and ("z" .. zoneID)
    else
        key = capital and ("c" .. capital)
    end
    if not key or not FirstVisit("autoShotPlaces", key) then return end
    if capital then
        local info = C_Map.GetMapInfo(capital)
        zoneName = info and info.name or zoneName
    end
    zoneName = Str(zoneName)
    local lines = { Big(zoneName), Dim(Str(continent)) }
    -- Forever: the level range Show Zone Levels knows (ForeverEssentials).
    local zl = EUI._ZoneLevels
    local lv = zoneID and zl and zl.Levels and zl.Levels(zoneID)
    if lv then lines[#lines + 1] = Dim(EllesmereUI.Lf("Levels %1$d-%2$d", lv[1], lv[2])) end
    Request({ label = zoneName or EllesmereUI.L("Zone Discovery"),
              card = { title = EllesmereUI.L("Zone Discovery"), lines = lines } })
end

-- WoW Forever: achievements are Legacy challenges (Blizzard_LegacySystem).
local LEGACY = IS_FOREVER and Constants and Constants.LegacyConsts

-- "3/5" for a tracked challenge, as the objective tracker counts it.
local function Progress(id)
    local n = GetAchievementNumCriteria(id)
    if not Known(n, "number") or n == 0 then return nil end
    if n == 1 then
        local _, _, done, qty, total = GetAchievementCriteriaInfo(id, 1)
        if Known(qty, "number") and Known(total, "number") and total > 1 then
            return qty .. "/" .. total
        end
        return (not issecretvalue(done) and done) and "1/1" or "0/1"
    end
    local count = 0
    for i = 1, n do
        local _, _, done = GetAchievementCriteriaInfo(id, i)
        if not issecretvalue(done) and done then count = count + 1 end
    end
    return count .. "/" .. n
end

local function LegacyLines(lines, achievementID)
    if not LEGACY then return end
    local pts = C_Traits and C_Traits.GetTraitCurrencyForAchievement
        and C_Traits.GetTraitCurrencyForAchievement(LEGACY.LEGACY_POINTS_TRAIT_CURRENCY_ID, achievementID)
    if Known(pts, "number") and pts > 0 then
        lines[#lines + 1] = Colored(EllesmereUI.Lf("%1$d Legacy points", pts), 1, 0.82, 0)
    end
    -- The total Blizzard's Legacy window shows: the reward track's renown.
    local total = C_MajorFactions and C_MajorFactions.GetCurrentRenownLevel
        and C_MajorFactions.GetCurrentRenownLevel(LEGACY.LEGACY_REWARD_TRACK_FACTION_ID)
    if Known(total, "number") then
        lines[#lines + 1] = Dim(EllesmereUI.Lf("Total Legacy points: %1$d", total))
    end
    local tracked = C_ContentTracking and C_ContentTracking.GetTrackedIDs and Enum.ContentTrackingType
        and C_ContentTracking.GetTrackedIDs(Enum.ContentTrackingType.Achievement)
    if type(tracked) ~= "table" then return end
    local shown = 0
    for _, id in ipairs(tracked) do
        if shown == 3 then break end
        if Known(id, "number") and id ~= achievementID then
            local _, name, _, _, _, _, _, _, _, _, _, _, mine = GetAchievementInfo(id)
            name = Str(name)
            if name and not (not issecretvalue(mine) and mine) then
                if shown == 0 then lines[#lines + 1] = Dim(EllesmereUI.L("In progress:")) end
                local p = Progress(id)
                lines[#lines + 1] = { "  " .. name .. (p and ("  " .. p) or ""), 1, 1, 1 }
                shown = shown + 1
            end
        end
    end
end

-- key, default once the master is on, events, retail only
local TRIGGERS = {
    { "autoShotLevelUp",     true,  { "PLAYER_LEVEL_UP", "TIME_PLAYED_MSG", "PLAYER_LOGOUT" } },
    { "autoShotAchievement", true,  { "ACHIEVEMENT_EARNED" } },
    { "autoShotBoss",        true,  { "ENCOUNTER_START", "ENCOUNTER_END" } },
    { "autoShotWipe",        false, { "ENCOUNTER_START", "ENCOUNTER_END" } },
    { "autoShotDeath",       false, { "PLAYER_DEAD" } },
    { "autoShotMythicPlus",  false, { "CHALLENGE_MODE_COMPLETED" }, true },
    { "autoShotPvP",         false, { "PVP_MATCH_COMPLETE" }, true },
    { "autoShotRaidEntry",   true,  { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" } },
    { "autoShotZone",        false, { "MAP_EXPLORATION_UPDATED" } },
    { "autoShotRep",         false, { "FACTION_STANDING_CHANGED", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" } },
    { "autoShotWorldBoss",   false, { "BOSS_KILL" }, true },
    { "autoShotTravel",      false, { "PERKS_ACTIVITY_COMPLETED" }, true },
    { "autoShotDuel",        false, { "DUEL_FINISHED" } },
    { "autoShotMount",       false, { "NEW_MOUNT_ADDED" } },
    { "autoShotPet",         false, { "NEW_PET_ADDED" } },
    { "autoShotToy",         false, { "NEW_TOY_ADDED" } },
    { "autoShotRecipe",      false, { "NEW_RECIPE_LEARNED" } },
    { "autoShotDecor",       false, { "NEW_HOUSING_ITEM_ACQUIRED" } },
    { "autoShotLoot",        false, { IS_FOREVER and "CHAT_MSG_LOOT" or "SHOW_LOOT_TOAST" } },
    { "autoShotLogin",       false, { "PLAYER_ENTERING_WORLD" } },
    { "autoShotProf",        false, { "SKILL_LINES_CHANGED" } },
    { "autoShotGather",      false, { "CHAT_MSG_LOOT" } },
    { "autoShotInterval",    false, {} },
}

local BYKEY = {}
for _, t in ipairs(TRIGGERS) do BYKEY[t[1]] = t end

local function TriggerOn(t)
    if t[4] and IS_FOREVER then return false end
    local v = EllesmereUIDB and EllesmereUIDB[t[1]]
    if v == nil then return t[2] end
    return v == true
end

local function ValidEvent(ev)
    return C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid(ev) or false
end

-- For events several triggers share: is this one on?
local function IsOn(key) return Enabled() and TriggerOn(BYKEY[key]) end

-- Time played. Blizzard's chat frame prints every TIME_PLAYED_MSG itself
-- (ChatFrameMixin:SystemEventHandler, which returns before the message
-- filters run), so asking for it would always add a chat line. Nothing here
-- asks: the last report from any /played is kept per character and carried
-- forward with GetTime() while logged in, the only time played time grows.
local sessionStart = GetTime()
local played    -- { t = total, l = at this level, lvl = that level, at = GetTime() }

local function PlayedStore()
    local db = EllesmereUIDB
    if not db then return nil end
    if type(db.autoShotPlayed) ~= "table" then db.autoShotPlayed = {} end
    return db.autoShotPlayed
end

local function Played()
    if played then return played end
    local store = PlayedStore()
    local saved = store and store[CharKey()]
    if type(saved) == "table" and type(saved.t) == "number" then
        played = { t = saved.t, l = saved.l, lvl = saved.lvl, at = sessionStart }
    end
    return played
end

local function Span(sec)
    if SecondsToTime then return SecondsToTime(sec, true) end
    return Clock(sec)
end

-------------------------------------------------------------------------------
--  Reputation, collections and loot
-------------------------------------------------------------------------------
-- Per-character table under EllesmereUIDB[store].
local function CharTable(store)
    local db = EllesmereUIDB
    if not db then return nil end
    if type(db[store]) ~= "table" then db[store] = {} end
    local charKey = CharKey()
    if not db[store][charKey] then db[store][charKey] = {} end
    return db[store][charKey]
end

-- A faction's rank as one number (friendships 100 + level), its standing
-- text, whether it is the top rank, and its name. Renown factions have their
-- own event.
local function RankOf(factionID)
    local data = C_Reputation and C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(factionID)
    if type(data) ~= "table" or issecretvalue(data) then return end
    if C_Reputation.IsMajorFaction and C_Reputation.IsMajorFaction(factionID) then return end
    local name = Str(data.name)
    local fr = C_GossipInfo and C_GossipInfo.GetFriendshipReputation and C_GossipInfo.GetFriendshipReputation(factionID)
    if type(fr) == "table" and Known(fr.friendshipFactionID, "number") and fr.friendshipFactionID > 0 then
        local ranks = C_GossipInfo.GetFriendshipReputationRanks(factionID)
        local cur, max = ranks and ranks.currentLevel, ranks and ranks.maxLevel
        if not Known(cur, "number") then return end
        return 100 + cur, Str(fr.reaction), Known(max, "number") and cur >= max, name
    end
    local r = data.reaction
    if not Known(r, "number") then return end
    return r, _G["FACTION_STANDING_LABEL" .. r], r >= 8, name
end

local function ReputationShot(name, standing, isMax)
    if Opt("autoShotRepMaxOnly") and not isMax then return end
    Request({ label = name or EllesmereUI.L("Reputation"),
              card = { title = EllesmereUI.L("Reputation"), lines = { Big(name), Colored(standing, 0.3, 1, 0.3) } } })
end

local function Collected(title, name, icon)
    name = Str(name)
    Request({ label = name or title,
              card = { title = title, icon = not issecretvalue(icon) and icon or nil, lines = { Big(name) } } })
end

-- fn(name, quality, icon, r, g, b) once the item's data is in.
local function WithItem(link, fn)
    if not (C_Item and C_Item.GetItemInfo) then return end
    local function go()
        local name, _, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(link)
        name = Str(name)
        if not (name and Known(quality, "number")) then return end
        local r, g, b = C_Item.GetItemQualityColor(quality)
        fn(name, quality, icon, r or 1, g or 1, b or 1)
    end
    if C_Item.GetItemInfo(link) then
        go()
    elseif Item and Item.CreateFromItemLink then
        Item:CreateFromItemLink(link):ContinueOnItemLoad(go)
    end
end

-- Loot at or above the picked quality (default Epic).
local function LootShot(link, quantity)
    WithItem(link, function(name, quality, icon, r, g, b)
        local min = tonumber(EllesmereUIDB and EllesmereUIDB.autoShotLootQuality) or 4
        if quality < min then return end
        local text = name
        if Known(quantity, "number") and quantity > 1 then text = text .. " x" .. quantity end
        Request({ label = name, card = { title = EllesmereUI.L("Special Loot"), icon = icon,
                                         lines = { { text, r, g, b, true } } } })
    end)
end

-- First Gather: a herb, ore or stone, or leather (Trade Goods subclasses 9, 7
-- and 6, wago.tools ItemSubClass) this character never looted before. What
-- one loot brings in is gathered for a second into one shot.
local GATHER_SUBCLASS = { [6] = true, [7] = true, [9] = true }
local gatherPending

local function FlushGather()
    local list = gatherPending
    gatherPending = nil
    if not list or #list == 0 then return end
    Request({ label = list[1][1], card = { title = EllesmereUI.L("First Gather"), icon = list[1].icon, lines = list } })
end

local function GatherCheck(link)
    if not (C_Item and C_Item.GetItemInfoInstant) then return end
    local itemID, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
    if not Known(itemID, "number") or classID ~= 7 or not GATHER_SUBCLASS[subclassID] then return end
    local seen = CharTable("autoShotGathered")
    if not seen or seen[itemID] then return end
    seen[itemID] = true
    WithItem(link, function(name, quality, icon, r, g, b)
        if Opt("autoShotGatherRare") and quality < 3 then return end
        if not gatherPending then
            gatherPending = {}
            C_Timer.After(1, FlushGather)
        end
        gatherPending[#gatherPending + 1] = { name, r, g, b, true, icon = icon }
    end)
end

-- The player's own loot lines, matched against the client's
-- localized formats (the multiple-item one first: the single one matches
-- its lines too). Built on first use.
local lootPatterns
local function OwnLootLink(text)
    if not lootPatterns then
        lootPatterns = {}
        for _, key in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF",
                               "LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE", "LOOT_ITEM_BONUS_ROLL_SELF" }) do
            local fmt = _G[key]
            if type(fmt) == "string" and fmt ~= "" then
                local pat = fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
                pat = pat:gsub("%%%d%$s", "(.+)"):gsub("%%s", "(.+)")
                pat = pat:gsub("%%%d%$d", "(%%d+)"):gsub("%%d", "(%%d+)")
                lootPatterns[#lootPatterns + 1] = "^" .. pat .. "$"
            end
        end
    end
    for _, pat in ipairs(lootPatterns) do
        local link, count = text:match(pat)
        if link then return link, tonumber(count) or 1 end
    end
end

-------------------------------------------------------------------------------
--  Profession milestones: GetProfessions / GetProfessionInfo (both clients,
--  as Blizzard_ProfessionsBook reads them) on SKILL_LINES_CHANGED. A cap
--  reached (skill at the rank's maximum) or, on a raised maximum, a new rank
--  learned. Kept per character; the first scan only records.
-------------------------------------------------------------------------------
-- Base skill lines: gathering and secondary; every other one is crafting.
local PROF_KIND = {
    [182] = "Gather", [186] = "Gather", [393] = "Gather",                    -- Herbalism, Mining, Skinning
    [185] = "Second", [129] = "Second", [356] = "Second", [794] = "Second",  -- Cooking, First Aid, Fishing, Archaeology
}
-- WoW Forever rank names by maximum skill (Blizzard's PROFESSION_RANKS).
local RANK_NAMES = { [75] = "APPRENTICE", [150] = "JOURNEYMAN", [225] = "EXPERT", [300] = "ARTISAN" }

local function ProfessionShot(icon, name, lines)
    Request({ label = name or EllesmereUI.L("Profession Milestone"),
              card = { title = EllesmereUI.L("Profession Milestone"), icon = icon, lines = lines } })
end

-- Set when the trigger turns on: what changed while it was off is recorded only.
local profSeedNext = false

local function ScanProfessions()
    if not (GetProfessions and GetProfessionInfo) then return end
    local store = CharTable("autoShotProfs")
    if not store then return end
    local seed = profSeedNext or not store.seeded
    store.seeded, profSeedNext = true, false
    local list = { GetProfessions() }
    for i = 1, 6 do
        local index = list[i]
        if Known(index, "number") then
            local name, icon, rank, maxRank, _, _, line, _, _, _, tierName = GetProfessionInfo(index)
            if Known(line, "number") and Known(rank, "number") and Known(maxRank, "number") and maxRank > 0 then
                name = Str(name)
                tierName = Str(tierName)
                local rankName = tierName or _G[RANK_NAMES[maxRank] or ""]
                local capKey = line .. ":" .. (tierName or "") .. ":" .. maxRank
                local prevMax = store[line]
                local capped = rank >= maxRank
                local wanted = not seed and On("autoShotProf" .. (PROF_KIND[line] or "Craft"))
                if wanted and capped and not store[capKey] then
                    -- Forever: the top rank is Artisan; every retail tier cap is a maximum.
                    if not Opt("autoShotProfMaxOnly") or not IS_FOREVER or maxRank >= 300 then
                        ProfessionShot(icon, name, { Big(name), Colored(rankName, 0.3, 1, 0.3),
                            Dim(EllesmereUI.Lf("Skill %1$d / %2$d", rank, maxRank)) })
                    end
                elseif wanted and type(prevMax) == "number" and maxRank > prevMax and not Opt("autoShotProfMaxOnly") then
                    ProfessionShot(icon, name, { Big(name),
                        Colored(EllesmereUI.Lf("New rank learned: %1$s", rankName or maxRank), 0.3, 1, 0.3),
                        Dim(EllesmereUI.Lf("Skill %1$d / %2$d", rank, maxRank)) })
                end
                store[line] = maxRank
                if capped then store[capKey] = true end
            end
        end
    end
end

local encounterStart = {}

local HANDLERS = {
    ZONE_CHANGED_NEW_AREA   = RaidEntry,

    -- Shared by First Raid Entry and Login (the session's first load only).
    PLAYER_ENTERING_WORLD = function(isInitialLogin)
        if IsOn("autoShotRaidEntry") then RaidEntry() end
        if isInitialLogin == true and IsOn("autoShotLogin") then
            Request({ label = EllesmereUI.L("Login"), minDelay = 5,
                      card = { title = EllesmereUI.L("Login"),
                               lines = { Dim(EllesmereUI.Lf("Level %1$d", UnitLevel("player"))) } } })
        end
    end,
    MAP_EXPLORATION_UPDATED = Discovery,

    PLAYER_LEVEL_UP = function(level)
        if not Known(level, "number") then level = nil end
        local lines = {}
        if level then lines[1] = Big(EllesmereUI.Lf("Level %1$d", level)) end
        local className, class = UnitClass("player")
        local c = EUI.GetClassColor(class)
        lines[#lines + 1] = Colored((UnitRace("player") or "") .. " " .. (className or ""), c.r, c.g, c.b)
        local p = Played()
        if p then
            local now = GetTime()
            local total = p.t + (now - p.at)
            if level and p.l and p.lvl == level - 1 then
                lines[#lines + 1] = Dim(EllesmereUI.Lf("Time at level %1$d: %2$s", level - 1, Span(p.l + now - p.at)))
            end
            lines[#lines + 1] = Dim(EllesmereUI.Lf("Total time played: %1$s", Span(total)))
            played = { t = total, l = 0, lvl = level or UnitLevel("player"), at = now }
        end
        if Opt("autoShotLevelMaxOnly") then
            local max = MaxLevel()
            if not (level and max and level >= max) then return end
        end
        -- Forever: leave the level-up toast time to show.
        Request({ label = level and EllesmereUI.Lf("Level %1$d", level) or EllesmereUI.L("Level Up"),
                  minDelay = IS_FOREVER and 1 or nil,
                  card = { title = EllesmereUI.L("Level Up"), lines = lines } })
    end,

    TIME_PLAYED_MSG = function(total, thisLevel)
        if not Known(total, "number") or not Known(thisLevel, "number") then return end
        played = { t = total, l = thisLevel, lvl = UnitLevel("player"), at = GetTime() }
    end,

    PLAYER_LOGOUT = function()
        local p, store = Played(), PlayedStore()
        if not (p and store) then return end
        local since = GetTime() - p.at
        store[CharKey()] = { t = p.t + since, l = p.l and (p.l + since), lvl = p.lvl }
    end,

    ACHIEVEMENT_EARNED = function(achievementID, alreadyEarned)
        if not Known(achievementID, "number") or issecretvalue(alreadyEarned) or not GetAchievementInfo then return end
        if alreadyEarned and not Opt("autoShotAchAccount") then return end
        local _, name, points, _, _, _, _, description, _, icon, _, isGuild = GetAchievementInfo(achievementID)
        if isGuild and not Opt("autoShotAchGuild") then return end
        name = Str(name)
        local lines = { Big(name) }
        lines[#lines + 1] = Dim(Str(description))
        if LEGACY then
            LegacyLines(lines, achievementID)
        elseif Known(points, "number") and points > 0 then
            lines[#lines + 1] = Colored(EllesmereUI.Lf("%1$d points", points), 1, 0.82, 0)
        end
        Request({ label = name or EllesmereUI.L("Achievement Earned"),
                  card = { title = LEGACY and EllesmereUI.L("Legacy Challenge") or EllesmereUI.L("Achievement Earned"),
                           icon = not issecretvalue(icon) and icon or nil, lines = lines } })
    end,

    ENCOUNTER_START = function(encounterID)
        if Known(encounterID, "number") then encounterStart[encounterID] = GetTime() end
    end,

    ENCOUNTER_END = function(encounterID, encounterName, difficultyID, _, success)
        local started
        if Known(encounterID, "number") then
            started = encounterStart[encounterID]
            encounterStart[encounterID] = nil
        end
        if issecretvalue(success) then return end
        local kill = success == 1
        local known = Known(encounterID, "number") and Known(difficultyID, "number")
        if kill then
            if not IsOn("autoShotBoss") then return end
            local firstOnly = On("autoShotBossFirstOnly")
            if known then
                if SeenKill(difficultyID, encounterID) and firstOnly then return end
            elseif firstOnly then
                return
            end
        else
            if not IsOn("autoShotWipe") then return end
            local _, instanceType = IsInInstance()
            if On("autoShotWipeRaidsOnly") and instanceType ~= "raid" then return end
        end
        local boss = Str(encounterName)
        local instance = Str((GetInstanceInfo()))
        local lines = { Big(boss), instance and { instance, 1, 1, 1 } or nil }
        local diffName = known and GetDifficultyInfo and Str((GetDifficultyInfo(difficultyID)))
        if diffName then lines[#lines + 1] = Dim(diffName) end
        if started then
            lines[#lines + 1] = Dim(EllesmereUI.Lf("Duration: %1$s", Clock(GetTime() - started)))
        end
        local title = kill and EllesmereUI.L("Boss Kill") or EllesmereUI.L("Boss Wipe")
        Request({ label = boss or title, waitCombat = true, roster = true,
                  card = { title = title, lines = lines } })
    end,

    PLAYER_DEAD = function()
        local where = EllesmereUIDB and EllesmereUIDB.autoShotDeathWhere or "all"
        local inInstance = IsInInstance()
        if (where == "instance" and not inInstance) or (where == "world" and inInstance) then return end
        local lines = { Big(EllesmereUI.Lf("Level %1$d", UnitLevel("player"))) }
        -- Forever: Blizzard_HardcoreUI reads the ruleset from C_GameRules.
        if IS_FOREVER and C_GameRules and C_GameRules.IsHardcoreActive and C_GameRules.IsHardcoreActive() then
            lines[2] = Colored(EllesmereUI.L("Hardcore"), 1, 0.3, 0.3)
        end
        Request({ label = EllesmereUI.L("Death"),
                  card = { title = EllesmereUI.L("Death"), lines = lines } })
    end,

    CHALLENGE_MODE_COMPLETED = function()
        local info = C_ChallengeMode and C_ChallengeMode.GetChallengeCompletionInfo
            and C_ChallengeMode.GetChallengeCompletionInfo()
        if issecretvalue(info) or type(info) ~= "table" then info = nil end
        local onTime = info and info.onTime
        if issecretvalue(onTime) then onTime = nil end
        if On("autoShotMythicPlusTimed") and onTime ~= true then return end
        local label = EllesmereUI.L("Mythic+ Completed")
        local lines = {}
        local level = info and info.level
        local mapID, ms = info and info.mapChallengeModeID, info and info.time
        local name, _, limit
        if Known(mapID, "number") and C_ChallengeMode.GetMapUIInfo then
            name, _, limit = C_ChallengeMode.GetMapUIInfo(mapID)
        end
        name = Str(name)
        lines[1] = Big(name)
        if Known(level, "number") and level > 0 then
            label = label .. " +" .. level
            lines[#lines + 1] = { EllesmereUI.Lf("Keystone Level %1$d", level), 1, 1, 1 }
        end
        if Known(ms, "number") and Known(limit, "number") then
            lines[#lines + 1] = Dim(EllesmereUI.Lf("Time: %1$s / %2$s", Clock(ms / 1000), Clock(limit)))
        end
        if onTime == true then
            lines[#lines + 1] = Colored(EllesmereUI.L("On time"), 0.3, 1, 0.3)
        elseif onTime == false then
            lines[#lines + 1] = Colored(EllesmereUI.L("Over time"), 1, 0.3, 0.3)
        end
        Request({ label = label, roster = true,
                  card = { title = EllesmereUI.L("Mythic+ Completed"), lines = lines } })
    end,

    -- Win test as PVPMatchResults.lua: the winner index against the player's team.
    PVP_MATCH_COMPLETE = function(winner, duration)
        if not Known(winner, "number") or not GetBattlefieldArenaFaction then return end
        local team = GetBattlefieldArenaFaction()
        if not Known(team, "number") or winner ~= team then return end
        -- Matches scored on a custom stat (brawls) show no victory.
        local statID = C_PvP and C_PvP.GetCustomVictoryStatID and C_PvP.GetCustomVictoryStatID()
        if Known(statID, "number") and statID > 0
           and not (C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle()) then return end
        local lines = { Big(Str((GetInstanceInfo()))) }
        if Known(duration, "number") and duration > 0 then
            lines[#lines + 1] = Dim(EllesmereUI.Lf("Duration: %1$s", Clock(duration)))
        end
        Request({ label = EllesmereUI.L("PvP Victory"),
                  card = { title = EllesmereUI.L("PvP Victory"), lines = lines } })
    end,

    FACTION_STANDING_CHANGED = function(factionID)
        if not Known(factionID, "number") then return end
        local rank, standing, isMax, name = RankOf(factionID)
        local ranks = rank and CharTable("autoShotRanks")
        if not ranks then return end
        -- The first change of a faction only records its rank.
        local prev = ranks[factionID]
        ranks[factionID] = rank
        if type(prev) ~= "number" or rank <= prev or math.floor(rank / 100) ~= math.floor(prev / 100) then return end
        ReputationShot(name, standing, isMax)
    end,

    MAJOR_FACTION_RENOWN_LEVEL_CHANGED = function(factionID, newLevel, oldLevel)
        if not (Known(factionID, "number") and Known(newLevel, "number")) then return end
        if Known(oldLevel, "number") and newLevel <= oldLevel then return end
        local data = C_MajorFactions.GetMajorFactionData(factionID)
        local isMax = C_MajorFactions.HasMaximumRenown and C_MajorFactions.HasMaximumRenown(factionID)
        ReputationShot(type(data) == "table" and Str(data.name) or nil,
            EllesmereUI.Lf("Renown %1$d", newLevel), not issecretvalue(isMax) and isMax == true)
    end,

    -- Retail: a boss killed outside an instance.
    BOSS_KILL = function(_, encounterName)
        if IsInInstance() then return end
        local boss = Str(encounterName)
        Request({ label = boss or EllesmereUI.L("World Boss Kill"), waitCombat = true, roster = true,
                  card = { title = EllesmereUI.L("World Boss Kill"), lines = { Big(boss) } } })
    end,

    PERKS_ACTIVITY_COMPLETED = function(activityID)
        if not Known(activityID, "number") then return end
        local info = C_PerksActivities.GetPerksActivityInfo(activityID)
        if type(info) ~= "table" then return end
        local name = Str(info.activityName)
        Request({ label = name or EllesmereUI.L("Traveler's Log"),
                  card = { title = EllesmereUI.L("Traveler's Log"), lines = { Big(name), Dim(Str(info.description)) } } })
    end,

    -- No API names the winner, and a declined request ends with the same
    -- event: only a duel that left the player in combat counts.
    DUEL_FINISHED = function()
        if not UnitAffectingCombat("player") then return end
        Request({ label = EllesmereUI.L("Duel"), waitCombat = true,
                  card = { title = EllesmereUI.L("Duel"), lines = {} } })
    end,

    NEW_MOUNT_ADDED = function(mountID)
        if not Known(mountID, "number") then return end
        local name, _, icon = C_MountJournal.GetMountInfoByID(mountID)
        Collected(EllesmereUI.L("New Mount"), name, icon)
    end,

    NEW_PET_ADDED = function(petGUID)
        if not Known(petGUID, "string") then return end
        local _, customName, _, _, _, _, _, name, icon = C_PetJournal.GetPetInfoByPetID(petGUID)
        Collected(EllesmereUI.L("New Battle Pet"), Str(customName) or name, icon)
    end,

    NEW_TOY_ADDED = function(itemID)
        if not Known(itemID, "number") then return end
        local _, name, icon = C_ToyBox.GetToyInfo(itemID)
        Collected(EllesmereUI.L("New Toy"), name, icon)
    end,

    NEW_RECIPE_LEARNED = function(recipeID)
        if not Known(recipeID, "number") then return end
        Collected(EllesmereUI.L("New Recipe"), C_Spell.GetSpellName(recipeID), C_Spell.GetSpellTexture(recipeID))
    end,

    NEW_HOUSING_ITEM_ACQUIRED = function(itemType, itemName, icon)
        local decor = Enum.HousingItemToastType and Enum.HousingItemToastType.Decor
        if decor and (not Known(itemType, "number") or itemType ~= decor) then return end
        Collected(EllesmereUI.L("New Housing Decor"), itemName, icon)
    end,

    -- Retail loot toasts; money and currency only with their option.
    SHOW_LOOT_TOAST = function(typeIdentifier, link, quantity, _, _, isPersonal)
        if not Known(typeIdentifier, "string") then return end
        if typeIdentifier == "item" then
            if Known(link, "string") then LootShot(link, quantity) end
            return
        end
        if not Opt("autoShotLootMoney") then return end
        if typeIdentifier == "money" and Known(quantity, "number") and GetMoneyString then
            Request({ label = EllesmereUI.L("Special Loot"),
                      card = { title = EllesmereUI.L("Special Loot"), lines = { Big(GetMoneyString(quantity)) } } })
        elseif typeIdentifier == "currency" and isPersonal and Known(link, "string") then
            local info = C_CurrencyInfo.GetCurrencyInfoFromLink(link)
            local name = type(info) == "table" and Str(info.name)
            if not name then return end
            local text = name
            if Known(quantity, "number") and quantity > 1 then text = text .. " x" .. quantity end
            Request({ label = name, card = { title = EllesmereUI.L("Special Loot"), icon = info.iconFileID,
                                             lines = { Big(text) } } })
        end
    end,

    SKILL_LINES_CHANGED = ScanProfessions,

    -- The player's own loot lines: Special Loot on Forever, First Gather.
    CHAT_MSG_LOOT = function(text)
        if not Known(text, "string") then return end
        local link, count = OwnLootLink(text)
        if not (link and link:find("|Hitem:", 1, true)) then return end
        if IS_FOREVER and IsOn("autoShotLoot") then LootShot(link, count) end
        if IsOn("autoShotGather") then GatherCheck(link) end
    end,
}

-------------------------------------------------------------------------------
--  Enable / disable: events only while the master and that trigger are on.
-------------------------------------------------------------------------------
local evFrame = CreateFrame("Frame")
evFrame:SetScript("OnEvent", function(_, event, ...)
    local fn = HANDLERS[event]
    if fn then fn(...) end
end)
local registered = {}
local slashDone = false

-- Interval screenshots: a ticker only while that trigger is on. A tick is
-- skipped in combat, while dead, AFK or in a cinematic, or behind a capture.
local ticker, tickerMins
local function IntervalTick()
    if busy or #queue > 0 or InCombatLockdown() or UnitIsDeadOrGhost("player") or UnitIsAFK("player") then return end
    if (InCinematic and InCinematic()) or (IsInCinematicScene and IsInCinematicScene())
       or (MovieFrame and MovieFrame:IsShown()) then return end
    Request({ label = EllesmereUI.L("Interval Screenshot"),
              card = { title = EllesmereUI.L("Interval Screenshot"), lines = {} } })
end

local function SyncInterval(want)
    local mins = Num("autoShotIntervalMin", 30)
    if want and ticker and tickerMins == mins then return end
    if ticker then ticker:Cancel(); ticker = nil end
    if want then
        ticker, tickerMins = C_Timer.NewTicker(mins * 60, IntervalTick), mins
    end
end

local wanted = {}

local function Sync()
    local master = Enabled()
    wipe(wanted)
    for _, t in ipairs(TRIGGERS) do
        if master and TriggerOn(t) then
            for _, ev in ipairs(t[3]) do wanted[ev] = ValidEvent(ev) or nil end
        end
    end
    for _, t in ipairs(TRIGGERS) do
        for _, ev in ipairs(t[3]) do
            local want = wanted[ev] == true
            if want ~= (registered[ev] == true) then
                registered[ev] = want
                if want then evFrame:RegisterEvent(ev) else evFrame:UnregisterEvent(ev) end
                if want and ev == "SKILL_LINES_CHANGED" then profSeedNext = true end
            end
        end
    end
    if not registered.ENCOUNTER_END then wipe(encounterStart) end
    SyncInterval(master and TriggerOn(BYKEY.autoShotInterval))
    if master and not slashDone then
        slashDone = true
        SLASH_EUISHOT1 = "/euishot"
        SlashCmdList.EUISHOT = function()
            if InCombatLockdown() then
                EUI.PrintError(EllesmereUI.L("You are in combat."))
                return
            end
            Request({ clean = true })
        end
    end
end
EUI._applyAutoScreenshot = Sync

-- SavedVariables are loaded before this child addon's files run.
if Enabled() then Sync() end
