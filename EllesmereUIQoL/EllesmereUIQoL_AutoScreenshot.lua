if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_AutoScreenshot.lua
--  Auto Screenshots: a screenshot on level up, achievements, boss kills,
--  deaths, Mythic+ completions and PvP wins, optionally with the interface
--  hidden and a caption. /euishot takes one clean screenshot now.
--
--  Taint: the interface is hidden with UIParent:SetAlpha(0), never Hide() or
--  SetUIVisibility(), so no Blizzard OnHide/OnShow code (CloseAllWindows, the
--  managed frame layout) runs inside this addon's call. The caption is an
--  addon frame on WorldFrame, which stays drawn while UIParent is invisible
--  (Blizzard's ActionStatus falls back to the same parent).
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
--  Caption (built on the first shot that shows it)
-------------------------------------------------------------------------------
local caption

local function ShowCaption(label)
    if not caption then
        caption = CreateFrame("Frame", nil, WorldFrame)
        caption:SetFrameStrata("TOOLTIP")
        caption:EnableMouse(false)
        local bg = caption:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.05, 0.6)
        caption.bar = caption:CreateTexture(nil, "ARTWORK")
        caption.bar:SetPoint("TOPLEFT")
        caption.bar:SetPoint("BOTTOMLEFT")
        caption.bar:SetWidth(3)
        caption.title = caption:CreateFontString(nil, "OVERLAY")
        caption.title:SetPoint("TOPLEFT", 14, -9)
        caption.sub = caption:CreateFontString(nil, "OVERLAY")
        caption.sub:SetPoint("TOPLEFT", caption.title, "BOTTOMLEFT", 0, -4)
    end
    -- UIParent's scale on a WorldFrame child, like ActionStatus.
    caption:SetScale(UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale())
    EUI.ApplyModuleFont(caption.title, nil, 16, "extras")
    EUI.ApplyModuleFont(caption.sub, nil, 12, "extras")
    caption.bar:SetColorTexture(EUI.GetAccentColor())
    caption.title:SetText(label)
    caption.sub:SetText(UnitName("player") .. " - " .. GetRealmName() .. "   " .. date("%Y-%m-%d %H:%M"))
    caption.sub:SetTextColor(0.8, 0.8, 0.8)
    local w = math.max(caption.title:GetStringWidth(), caption.sub:GetStringWidth())
    caption:SetSize(w + 28, caption.title:GetStringHeight() + caption.sub:GetStringHeight() + 22)
    caption:ClearAllPoints()
    caption:SetPoint("BOTTOMRIGHT", WorldFrame, "BOTTOMRIGHT", -30, 30)
    caption:Show()
end

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
    if caption then caption:Hide() end
    if ok and On("autoShotChat") then
        Say(EllesmereUI.Lf("Screenshot taken: %1$s", job.label or "/euishot"))
    end
    Done()
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
        if job.label and On("autoShotCaption") then ShowCaption(job.label) end
    end
    -- One short wait so the hidden UI and the caption are drawn first. The
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

-- First kills per character: EllesmereUIDB.autoShotKills["Name - Realm"][difficultyID][encounterID].
local function SeenKill(difficultyID, encounterID)
    local db = EllesmereUIDB
    if not db then return false end
    if type(db.autoShotKills) ~= "table" then db.autoShotKills = {} end
    local charKey = UnitName("player") .. " - " .. GetRealmName()
    local mine = db.autoShotKills[charKey]
    if not mine then mine = {}; db.autoShotKills[charKey] = mine end
    local diff = mine[difficultyID]
    if not diff then diff = {}; mine[difficultyID] = diff end
    local seen = diff[encounterID] == true
    diff[encounterID] = true
    return seen
end

local HANDLERS = {
    PLAYER_LEVEL_UP = function(level)
        if not Known(level, "number") then level = nil end
        if Opt("autoShotLevelMaxOnly") then
            local max = MaxLevel()
            if not (level and max and level >= max) then return end
        end
        -- Forever: leave the level-up toast time to show.
        Request({ label = level and EllesmereUI.Lf("Level %1$d", level) or EllesmereUI.L("Level Up"),
                  minDelay = IS_FOREVER and 1 or nil })
    end,

    ACHIEVEMENT_EARNED = function(achievementID, alreadyEarned)
        if not Known(achievementID, "number") or issecretvalue(alreadyEarned)
           or alreadyEarned or not GetAchievementInfo then return end
        local _, name, _, _, _, _, _, _, _, _, _, isGuild = GetAchievementInfo(achievementID)
        if isGuild then return end
        Request({ label = Known(name, "string") and name or EllesmereUI.L("Achievement Earned") })
    end,

    ENCOUNTER_END = function(encounterID, encounterName, difficultyID, _, success)
        if issecretvalue(success) or success ~= 1 then return end
        local firstOnly = On("autoShotBossFirstOnly")
        if Known(encounterID, "number") and Known(difficultyID, "number") then
            if SeenKill(difficultyID, encounterID) and firstOnly then return end
        elseif firstOnly then
            return
        end
        Request({ label = Known(encounterName, "string") and encounterName or EllesmereUI.L("Boss Kill"),
                  waitCombat = true })
    end,

    PLAYER_DEAD = function()
        local where = EllesmereUIDB and EllesmereUIDB.autoShotDeathWhere or "all"
        local inInstance = IsInInstance()
        if (where == "instance" and not inInstance) or (where == "world" and inInstance) then return end
        Request({ label = EllesmereUI.L("Death") })
    end,

    CHALLENGE_MODE_COMPLETED = function()
        local info = C_ChallengeMode and C_ChallengeMode.GetChallengeCompletionInfo
            and C_ChallengeMode.GetChallengeCompletionInfo()
        if issecretvalue(info) or type(info) ~= "table" then info = nil end
        local onTime = info and info.onTime
        if issecretvalue(onTime) then onTime = nil end
        if On("autoShotMythicPlusTimed") and onTime ~= true then return end
        local label = EllesmereUI.L("Mythic+ Completed")
        local level = info and info.level
        if Known(level, "number") and level > 0 then label = label .. " +" .. level end
        Request({ label = label })
    end,

    -- Win test as PVPMatchResults.lua: the winner index against the player's team.
    PVP_MATCH_COMPLETE = function(winner)
        if not Known(winner, "number") or not GetBattlefieldArenaFaction then return end
        local team = GetBattlefieldArenaFaction()
        if not Known(team, "number") or winner ~= team then return end
        -- Matches scored on a custom stat (brawls) show no victory.
        local statID = C_PvP and C_PvP.GetCustomVictoryStatID and C_PvP.GetCustomVictoryStatID()
        if Known(statID, "number") and statID > 0
           and not (C_PvP.IsRatedSoloShuffle and C_PvP.IsRatedSoloShuffle()) then return end
        Request({ label = EllesmereUI.L("PvP Victory") })
    end,
}

-- key, default once the master is on, event, retail only
local TRIGGERS = {
    { "autoShotLevelUp",     true,  "PLAYER_LEVEL_UP" },
    { "autoShotAchievement", true,  "ACHIEVEMENT_EARNED" },
    { "autoShotBoss",        true,  "ENCOUNTER_END" },
    { "autoShotDeath",       false, "PLAYER_DEAD" },
    { "autoShotMythicPlus",  false, "CHALLENGE_MODE_COMPLETED", true },
    { "autoShotPvP",         false, "PVP_MATCH_COMPLETE", true },
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

local function Sync()
    local master = Enabled()
    for _, t in ipairs(TRIGGERS) do
        local ev = t[3]
        local want = master and TriggerOn(t) and ValidEvent(ev) or false
        if want ~= (registered[ev] == true) then
            registered[ev] = want
            if want then evFrame:RegisterEvent(ev) else evFrame:UnregisterEvent(ev) end
        end
    end
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
