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
        Screenshot()
    end)
    C_Timer.After(FAILSAFE, function() Finish(id, false) end)
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

local encounterStart = {}

local HANDLERS = {
    PLAYER_ENTERING_WORLD   = RaidEntry,
    ZONE_CHANGED_NEW_AREA   = RaidEntry,
    MAP_EXPLORATION_UPDATED = Discovery,

    PLAYER_LEVEL_UP = function(level)
        if not Known(level, "number") then level = nil end
        if Opt("autoShotLevelMaxOnly") then
            local max = MaxLevel()
            if not (level and max and level >= max) then return end
        end
        local lines = {}
        if level then lines[1] = Big(EllesmereUI.Lf("Level %1$d", level)) end
        local className, class = UnitClass("player")
        local c = EUI.GetClassColor(class)
        lines[#lines + 1] = Colored((UnitRace("player") or "") .. " " .. (className or ""), c.r, c.g, c.b)
        -- Forever: leave the level-up toast time to show.
        Request({ label = level and EllesmereUI.Lf("Level %1$d", level) or EllesmereUI.L("Level Up"),
                  minDelay = IS_FOREVER and 1 or nil,
                  card = { title = EllesmereUI.L("Level Up"), lines = lines } })
    end,

    ACHIEVEMENT_EARNED = function(achievementID, alreadyEarned)
        if not Known(achievementID, "number") or issecretvalue(alreadyEarned)
           or alreadyEarned or not GetAchievementInfo then return end
        local _, name, points, _, _, _, _, description, _, icon, _, isGuild = GetAchievementInfo(achievementID)
        if isGuild then return end
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
        if issecretvalue(success) or success ~= 1 then return end
        local firstOnly = On("autoShotBossFirstOnly")
        local known = Known(encounterID, "number") and Known(difficultyID, "number")
        if known then
            if SeenKill(difficultyID, encounterID) and firstOnly then return end
        elseif firstOnly then
            return
        end
        local boss = Str(encounterName)
        local instance = Str((GetInstanceInfo()))
        local lines = { Big(boss), instance and { instance, 1, 1, 1 } or nil }
        local diffName = known and GetDifficultyInfo and Str((GetDifficultyInfo(difficultyID)))
        if diffName then lines[#lines + 1] = Dim(diffName) end
        if started then
            lines[#lines + 1] = Dim(EllesmereUI.Lf("Duration: %1$s", Clock(GetTime() - started)))
        end
        Request({ label = boss or EllesmereUI.L("Boss Kill"), waitCombat = true, roster = true,
                  card = { title = EllesmereUI.L("Boss Kill"), lines = lines } })
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
}

-- key, default once the master is on, events, retail only
local TRIGGERS = {
    { "autoShotLevelUp",     true,  { "PLAYER_LEVEL_UP" } },
    { "autoShotAchievement", true,  { "ACHIEVEMENT_EARNED" } },
    { "autoShotBoss",        true,  { "ENCOUNTER_START", "ENCOUNTER_END" } },
    { "autoShotDeath",       false, { "PLAYER_DEAD" } },
    { "autoShotMythicPlus",  false, { "CHALLENGE_MODE_COMPLETED" }, true },
    { "autoShotPvP",         false, { "PVP_MATCH_COMPLETE" }, true },
    { "autoShotRaidEntry",   true,  { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" } },
    { "autoShotZone",        false, { "MAP_EXPLORATION_UPDATED" } },
}

local function TriggerOn(t)
    if t[4] and IS_FOREVER then return false end
    local v = EllesmereUIDB and EllesmereUIDB[t[1]]
    if v == nil then return t[2] end
    return v == true
end

local function ValidEvent(ev)
    return C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid(ev) or false
end

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
            end
        end
    end
    if not registered.ENCOUNTER_END then wipe(encounterStart) end
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
