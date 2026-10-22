if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_AFK.lua
--  AFK screen: while the player is flagged AFK the UI fades out, the camera
--  drifts around the character and a full-screen card layout takes over.
--
--  Scenes   cinema (letterbox bars), portrait (large model over a dark side
--           vignette), seasons (cinema plus drifting particles in the season's
--           palette) and forever (gold accents and the game font).
--  Model    the player (and the summoned companion) on a PlayerModel that
--           plays a random emote every 15-30s, waves at a whisper, applauds a
--           friend coming online and falls asleep after ten minutes.
--  Cards    identity, this week (Great Vault rows, keystone, crests), keys
--           (own + party/guild through LibKeystone), timers (daily/weekly
--           reset, today's holidays), gains (rested XP and gold since the
--           screen opened) and social (friends/guild online, who logged in).
--  Feed     whispers (and optionally guild chat) received while away; a click
--           leaves the screen and opens a reply.
--  Alerts   queue pops, ready checks, summons, invites and the camp countdown
--           leave the screen with a sound, a taskbar flash and a toast; an
--           auction sale or new mail only flashes and lands in the feed.
--  Return   a summary card (time away, messages, logins, rested XP, gold,
--           new vault option) with the last messages, click to reply.
--  Extras   eco mode (FPS cap held through HoldCVar/ReleaseCVar so Uninstall
--           and a crash both give the player's value back), streamer mode
--           (names, guild, gold and message text hidden) and a screenshot
--           button that hides the cards for the shot.
--
--  Safety: never opens in combat, an instance, a vehicle, on a taxi, in a pet
--  battle, during a cinematic, while casting or with a merchant/bank/mail/
--  auction/trade window open. PLAYER_REGEN_DISABLED closes it inside the
--  window before combat lockdown (UIParent is shown again there). The camera
--  view is saved to view slot 5 on open and put back on close.
--
--  Settings: EllesmereUIDB.afkScreen (account-wide). Off, nothing is built and
--  only PLAYER_LOGIN is registered (to release a leftover FPS hold).
-------------------------------------------------------------------------------
local EllesmereUI = _G.EllesmereUI
local IS_FOREVER = EllesmereUI.IS_FOREVER
local OWNER = "EllesmereUIQoL"

local floor, max, min, random, format = math.floor, math.max, math.min, math.random, string.format
local GetTime = GetTime

local DEFAULTS = {
    enabled = false,
    where = "always",        -- always | resting
    delay = 0,               -- seconds after the AFK flag before opening
    scale = 1,
    scene = "cinema",        -- cinema | portrait | seasons | forever
    season = "auto",         -- auto | spring | summer | fall | winter
    camera = "orbit",        -- orbit | pullback | sway | fixed
    cameraSpeed = 3,         -- 1..10
    restoreCamera = true,
    showModel = true, modelReactions = true, showPet = true,
    showIdentity = true, showWeek = true, showKeys = true, showTimers = true,
    showGains = true, showSocial = true, showTips = true,
    showMessages = true, msgGuild = false,
    alertQueue = true, alertReadyCheck = true, alertSummon = true, alertInvite = true,
    alertAuction = true, alertMail = true, alertSound = true, flashIcon = true,
    logoutWarning = true, returnSummary = true,
    ecoMode = true, ecoFPS = 30,
    streamer = false,
}
EllesmereUI.AFK_DEFAULTS = DEFAULTS

local function Cfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.afkScreen = EllesmereUIDB.afkScreen or {}
    return EllesmereUIDB.afkScreen
end

local function Get(key)
    local v = Cfg()[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- SEASON UPDATE: keep in sync with CRESTS in EllesmereUIDataBars/Blocks/Shared.lua
-- (DataBars can be disabled, so this file carries its own copy).
local CREST_IDS = { 3442, 3443, 3444, 3445, 3446 }

-- Emotes a PlayerModel can play (filtered by HasAnimation per model).
local EMOTES = { 60, 66, 67, 68, 69, 70, 73, 74, 75, 77, 78, 79, 80, 81, 82, 83, 84, 113, 185, 186, 195 }
local ANIM_IDLE, ANIM_WAVE, ANIM_APPLAUD, ANIM_SLEEP = 0, 67, 80, 71
local SLEEP_AFTER = 600

-- Blizzard logs an idle player out 30 min after the last input; the AFK flag
-- usually comes 5 min into that, so the estimate counts 25 min from the flag.
local LOGOUT_AFTER_FLAG = 25 * 60

local SEASONS = {
    spring = { dir = -1, size = { 4, 7 }, speed = { 18, 32 }, alpha = 0.55,
        colors = { { 1.00, 0.70, 0.82 }, { 0.98, 0.86, 0.91 }, { 0.66, 0.88, 0.55 } } },
    summer = { dir = 1, size = { 3, 4 }, speed = { 14, 26 }, alpha = 0.60,
        colors = { { 1.00, 0.84, 0.34 }, { 1.00, 0.64, 0.40 }, { 1.00, 0.93, 0.62 } } },
    fall   = { dir = -1, size = { 5, 8 }, speed = { 20, 36 }, alpha = 0.60,
        colors = { { 0.96, 0.58, 0.20 }, { 0.84, 0.34, 0.15 }, { 0.98, 0.78, 0.30 }, { 0.70, 0.42, 0.18 } } },
    winter = { dir = -1, size = { 3, 5 }, speed = { 16, 30 }, alpha = 0.70,
        colors = { { 0.72, 0.86, 1.00 }, { 0.90, 0.95, 1.00 }, { 0.62, 0.74, 0.95 } } },
}
local NUM_PARTICLES = 48

local TIPS = {
    EllesmereUI.L("Type /keys to see the keystones of your party and guild."),
    EllesmereUI.L("Unlock Mode lets you move and anchor every EllesmereUI element."),
    EllesmereUI.L("Spec Overrides can change any setting for a single specialization."),
    EllesmereUI.L("Profiles can be exported as a string and shared with friends."),
    EllesmereUI.L("Shift+drag a Blizzard window to move it with the Shifter."),
    EllesmereUI.L("Raid Tools gives you pull timers, ready checks and markers in one bar."),
    EllesmereUI.L("Quickdraw opens an action palette while you hold a key."),
    EllesmereUI.L("Global Search finds any EllesmereUI setting from the options sidebar."),
    EllesmereUI.L("The Cooldown Manager can glow a spell when a condition is met."),
    EllesmereUI.L("Bags can be shown as a grid, a list or compact category blocks."),
    EllesmereUI.L("Data Bars can show your Great Vault, crests and durability at a glance."),
    EllesmereUI.L("The Mythic+ timer can show a summary of your run at the end."),
    EllesmereUI.L("Movement Alert warns you when your movement ability is back."),
    EllesmereUI.L("Auto Combat Logging starts logs for raids and Mythic+ on its own."),
    EllesmereUI.L("Rounded Corners can be set beside each module's border color."),
    EllesmereUI.L("The AFK screen has a preview button in its options page."),
}

-------------------------------------------------------------------------------
--  State
-------------------------------------------------------------------------------
local S = {
    shown = false, preview = false, dismissed = false,
    openedAt = 0, afkSince = nil, uiHidden = false,
    money = 0, restedPct = nil, vaultDone = 0,
    lastAnim = 0, asleep = false,
    shot = false,
}
local messages = {}     -- { kind, sender, text, at, guid, bnID }
local logins = {}       -- names that came online while away
local keys = {}         -- [player] = { level, map, guild }
local heldFPS           -- { [cvar] = previous value } while eco mode holds

local root, content, ev
local ticker, animTimer, swayTimer, pullTimer, delayTimer, summaryTimer
local Exit, Enter, RefreshCards, RefreshFeed

-------------------------------------------------------------------------------
--  Look
-------------------------------------------------------------------------------
local function Accent()
    if Get("scene") == "forever" then return 1, 0.82, 0 end
    return EllesmereUI.GetAccentColor()
end

local function AccentHex()
    local r, g, b = Accent()
    return format("%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

local function FontPath()
    if Get("scene") == "forever" then return STANDARD_TEXT_FONT end
    return (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("EllesmereUIQoL")) or STANDARD_TEXT_FONT
end

local function SetFont(fs, size, flags)
    if not fs:SetFont(FontPath(), size, flags or "") then
        fs:SetFont(STANDARD_TEXT_FONT, size, flags or "")
    end
end

local fontStrings = {}  -- { fs, size, flags } refreshed when the scene changes

local function Text(parent, size, flags, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    SetFont(fs, size, flags)
    fs:SetTextColor(1, 1, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.9)
    fontStrings[#fontStrings + 1] = { fs, size, flags }
    return fs
end

local function Solid(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

local function ClassHex(classToken)
    local c = classToken and EllesmereUI.GetClassColor(classToken)
    if not c then return "ffffff" end
    return format("%02x%02x%02x", floor(c.r * 255 + 0.5), floor(c.g * 255 + 0.5), floor(c.b * 255 + 0.5))
end

local function Clock(sec)
    sec = max(0, floor(sec))
    local h = floor(sec / 3600)
    local m = floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return format("%d:%02d:%02d", h, m, s) end
    return format("%02d:%02d", m, s)
end

local function Duration(sec)
    if SecondsToTime then return SecondsToTime(max(60, floor(sec)), true, false, 2) end
    return Clock(sec)
end

local function DateText()
    local t = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
    if t and FULLDATE and CALENDAR_WEEKDAY_NAMES and CALENDAR_FULLDATE_MONTH_NAMES then
        local ok, text = pcall(format, FULLDATE, CALENDAR_WEEKDAY_NAMES[t.weekday], CALENDAR_FULLDATE_MONTH_NAMES[t.month], t.monthDay, t.year)
        if ok then return text end
    end
    return date("%d/%m/%Y")
end

local function Money(copper)
    if GetMoneyString then return GetMoneyString(copper, true) end
    return tostring(floor(copper / 10000))
end

-------------------------------------------------------------------------------
--  Data
-------------------------------------------------------------------------------
local function RestedPct()
    if IsXPUserDisabled and IsXPUserDisabled() then return nil end
    local maxLevel = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()) or MAX_PLAYER_LEVEL
    if maxLevel and UnitLevel("player") >= maxLevel then return nil end
    local xpMax = UnitXPMax("player") or 0
    if xpMax <= 0 then return nil end
    return ((GetXPExhaustion and GetXPExhaustion()) or 0) / xpMax * 100
end

local VAULT_ROWS
if not IS_FOREVER and Enum and Enum.WeeklyRewardChestThresholdType then
    local T = Enum.WeeklyRewardChestThresholdType
    VAULT_ROWS = {
        { type = T.Raid, label = EllesmereUI.L("Raid") },
        { type = T.Activities, label = EllesmereUI.L("Dungeons") },
        { type = T.World, label = EllesmereUI.L("World") },
    }
end

-- Unlocked slots per vault row, and the total.
local function VaultState()
    if not (VAULT_ROWS and C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return nil, 0 end
    local rows, total = {}, 0
    for i, row in ipairs(VAULT_ROWS) do
        local acts = row.type and C_WeeklyRewards.GetActivities(row.type) or {}
        local done = 0
        for _, a in ipairs(acts) do
            local th = tonumber(a.threshold) or 0
            if th > 0 and (tonumber(a.progress) or 0) >= th then done = done + 1 end
        end
        rows[i] = { label = row.label, done = done, count = #acts }
        total = total + done
    end
    return rows, total
end

local function OwnKeystone()
    if IS_FOREVER or not C_MythicPlus then return nil end
    local map = C_MythicPlus.GetOwnedKeystoneChallengeMapID and C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    local lvl = C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
    if not map or map == 0 or not lvl or lvl == 0 then return nil end
    return map, lvl
end

local function DungeonName(mapID)
    if mapID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
        local name = C_ChallengeMode.GetMapUIInfo(mapID)
        if name then return name end
    end
    return "?"
end

local function MythicScore()
    if IS_FOREVER or not (C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore) then return nil end
    local score = C_ChallengeMode.GetOverallDungeonScore()
    if score and score > 0 then return score end
    return nil
end

local function TodayHolidays()
    if not (C_Calendar and C_Calendar.GetNumDayEvents and C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime) then return nil end
    local now = C_DateAndTime.GetCurrentCalendarTime()
    if not now then return nil end
    local ok, n = pcall(C_Calendar.GetNumDayEvents, 0, now.monthDay)
    if not ok or not n or n == 0 then return nil end
    local out = {}
    for i = 1, n do
        local okE, e = pcall(C_Calendar.GetDayEvent, 0, now.monthDay, i)
        if okE and e and e.calendarType == "HOLIDAY" and e.title and #out < 3 then
            out[#out + 1] = e.title
        end
    end
    return #out > 0 and out or nil
end

local function FriendsOnline()
    local n = (C_FriendList and C_FriendList.GetNumOnlineFriends and C_FriendList.GetNumOnlineFriends()) or 0
    if BNGetNumFriends then
        local _, bnOnline = BNGetNumFriends()
        n = n + (bnOnline or 0)
    end
    return n
end

local function GuildOnline()
    if not (IsInGuild and IsInGuild()) or not GetNumGuildMembers then return nil end
    local _, online = GetNumGuildMembers()
    return online
end

-------------------------------------------------------------------------------
--  Camera
-------------------------------------------------------------------------------
local function CameraSpeed()
    return (tonumber(Get("cameraSpeed")) or 3) * 0.012
end

local function StopCamera()
    if swayTimer then swayTimer:Cancel(); swayTimer = nil end
    if pullTimer then pullTimer:Cancel(); pullTimer = nil end
    if MoveViewLeftStop then MoveViewLeftStop() end
    if MoveViewRightStop then MoveViewRightStop() end
    if MoveViewOutStop then MoveViewOutStop() end
end

local function StartCamera()
    StopCamera()
    if Get("restoreCamera") and SaveView then SaveView(5) end
    local mode, speed = Get("camera"), CameraSpeed()
    if mode == "orbit" then
        MoveViewLeftStart(speed)
    elseif mode == "pullback" then
        MoveViewOutStart(0.25)
        pullTimer = C_Timer.NewTimer(4, function()
            pullTimer = nil
            MoveViewOutStop()
            MoveViewLeftStart(speed * 0.6)
        end)
    elseif mode == "sway" then
        local left = true
        MoveViewLeftStart(speed)
        swayTimer = C_Timer.NewTicker(12, function()
            left = not left
            if left then MoveViewRightStop(); MoveViewLeftStart(speed)
            else MoveViewLeftStop(); MoveViewRightStart(speed) end
        end)
    end
end

local function RestoreCamera()
    StopCamera()
    if Get("restoreCamera") and SetView then SetView(5) end
end

-------------------------------------------------------------------------------
--  Eco mode (FPS cap held while the screen is up)
-------------------------------------------------------------------------------
local ECO_CVARS = { "maxFPS", "useMaxFPS" }

local function ReleaseFPS()
    local held = heldFPS or Cfg()._heldFPS
    if not held then return end
    for _, name in ipairs(ECO_CVARS) do
        if held[name] ~= nil and EllesmereUI.ReleaseCVar then
            EllesmereUI.ReleaseCVar(name, held[name], OWNER)
        end
    end
    heldFPS = nil
    Cfg()._heldFPS = nil
end

local function HoldFPS()
    if not Get("ecoMode") or heldFPS or not EllesmereUI.HoldCVar then return end
    heldFPS = {}
    for _, name in ipairs(ECO_CVARS) do heldFPS[name] = GetCVar(name) end
    -- Saved too: a crash or a disconnect while held is undone at next login.
    Cfg()._heldFPS = heldFPS
    EllesmereUI.HoldCVar("maxFPS", tonumber(Get("ecoFPS")) or 30, OWNER)
    EllesmereUI.HoldCVar("useMaxFPS", 1, OWNER)
end

-------------------------------------------------------------------------------
--  Frames
-------------------------------------------------------------------------------
local F = {}           -- named regions
local cards = {}       -- ordered card frames
local feedRows = {}
local particles = {}

local function MakeCard(key, title)
    local c = CreateFrame("Frame", nil, content)
    c:SetWidth(310)
    c.bg = Solid(c, "BACKGROUND", 0, 0, 0, 0.55)
    c.bg:SetAllPoints()
    c.stripe = Solid(c, "BORDER", 1, 1, 1, 1)
    c.stripe:SetPoint("TOPLEFT"); c.stripe:SetPoint("BOTTOMLEFT"); c.stripe:SetWidth(2)
    c.title = Text(c, 11, "OUTLINE")
    c.title:SetPoint("TOPLEFT", 14, -10)
    c.title:SetText(title)
    c.body = Text(c, 13)
    c.body:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -6)
    c.body:SetWidth(310 - 28)
    c.body:SetJustifyH("LEFT")
    c.body:SetSpacing(3)
    c.key = key
    cards[#cards + 1] = c
    return c
end

local function LayoutCards()
    local y = F.cardTop or -40
    for _, c in ipairs(cards) do
        if c.wanted and (c.body:GetText() or "") ~= "" then
            local h = 10 + c.title:GetStringHeight() + 6 + c.body:GetStringHeight() + 12
            c:SetHeight(h)
            c:ClearAllPoints()
            c:SetPoint("TOPRIGHT", content, "TOPRIGHT", -40, y)
            c:Show()
            y = y - h - 10
        else
            c:Hide()
        end
    end
end

local function ReplyTo(m)
    if not m or m.kind == "system" or not m.sender then return end
    if Exit then Exit("reply") end
    C_Timer.After(0.1, function()
        if m.bnID and m.sender then
            local fn = (ChatFrameUtil and ChatFrameUtil.SendBNetTell) or ChatFrame_SendBNetTell
            if fn then pcall(fn, m.sender) end
        elseif m.sender then
            local fn = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
            if fn then pcall(fn, m.sender) end
        end
    end)
end

local function MessageLine(m)
    local when = date("%H:%M", m.at)
    if Get("streamer") then
        return format("|cff888888%s|r  %s", when, m.kind == "guild" and EllesmereUI.L("Guild message") or EllesmereUI.L("Whisper"))
    end
    local who = m.sender or "?"
    if m.kind == "system" then who = "|cffffd100EllesmereUI|r"
    elseif m.kind == "guild" then who = "|cff40ff40" .. who .. "|r"
    elseif m.bnID then who = "|cff00ccff" .. who .. "|r"
    else who = "|cffff80ff" .. who .. "|r" end
    return format("|cff888888%s|r  %s: %s", when, who, m.text or "...")
end

local function Build()
    if root then return end

    root = CreateFrame("Frame", "EllesmereUIAFKScreen", nil)
    root:SetFrameStrata("FULLSCREEN_DIALOG")
    root:SetAllPoints(UIParent)
    root:Hide()
    root:EnableMouse(true)
    root:EnableKeyboard(true)

    content = CreateFrame("Frame", nil, root)
    content:SetAllPoints()

    -- Fade in
    root.fade = root:CreateAnimationGroup()
    local a = root.fade:CreateAnimation("Alpha")
    a:SetFromAlpha(0); a:SetToAlpha(1); a:SetDuration(0.8); a:SetSmoothing("OUT")

    -- Vignette (portrait) and letterbox bars
    F.vignette = content:CreateTexture(nil, "BACKGROUND")
    F.vignette:SetTexture("Interface\\Buttons\\WHITE8x8")
    F.vignette:SetPoint("TOPLEFT"); F.vignette:SetPoint("BOTTOMLEFT")
    F.vignetteR = content:CreateTexture(nil, "BACKGROUND")
    F.vignetteR:SetTexture("Interface\\Buttons\\WHITE8x8")
    F.vignetteR:SetPoint("TOPRIGHT"); F.vignetteR:SetPoint("BOTTOMRIGHT")
    F.topBar = content:CreateTexture(nil, "BACKGROUND")
    F.topBar:SetTexture("Interface\\Buttons\\WHITE8x8")
    F.topBar:SetPoint("TOPLEFT"); F.topBar:SetPoint("TOPRIGHT")
    F.botBar = content:CreateTexture(nil, "BACKGROUND")
    F.botBar:SetTexture("Interface\\Buttons\\WHITE8x8")
    F.botBar:SetPoint("BOTTOMLEFT"); F.botBar:SetPoint("BOTTOMRIGHT")
    F.topLine = Solid(content, "BORDER", 1, 1, 1, 1)
    F.topLine:SetHeight(1)
    F.topLine:SetPoint("TOPLEFT", F.topBar, "BOTTOMLEFT"); F.topLine:SetPoint("TOPRIGHT", F.topBar, "BOTTOMRIGHT")
    F.botLine = Solid(content, "BORDER", 1, 1, 1, 1)
    F.botLine:SetHeight(1)
    F.botLine:SetPoint("BOTTOMLEFT", F.botBar, "TOPLEFT"); F.botLine:SetPoint("BOTTOMRIGHT", F.botBar, "TOPRIGHT")

    -- Season particles
    F.particles = CreateFrame("Frame", nil, content)
    F.particles:SetAllPoints()
    F.particles:Hide()
    for i = 1, NUM_PARTICLES do
        local t = F.particles:CreateTexture(nil, "ARTWORK")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        particles[i] = { tex = t }
    end
    F.particles:SetScript("OnUpdate", function(self, elapsed)
        if not particles[1].reset then return end
        local w, h = self:GetWidth(), self:GetHeight()
        for _, p in ipairs(particles) do
            p.x = p.x + p.vx * elapsed
            p.y = p.y + p.vy * elapsed
            p.rot = p.rot + p.spin * elapsed
            if p.y < -10 or p.y > h + 10 or p.x < -10 or p.x > w + 10 then
                p.reset(p, false)
            end
            p.tex:ClearAllPoints()
            p.tex:SetPoint("CENTER", self, "BOTTOMLEFT", p.x, p.y)
            p.tex:SetRotation(p.rot)
        end
    end)

    -- Models
    F.model = CreateFrame("PlayerModel", nil, content)
    F.model:SetScript("OnAnimFinished", function(self)
        if S.asleep then self:SetAnimation(ANIM_SLEEP) else self:SetAnimation(ANIM_IDLE) end
    end)
    F.pet = CreateFrame("PlayerModel", nil, content)

    -- Header: label, elapsed, clock
    F.label = Text(content, 14, "OUTLINE")
    F.elapsed = Text(content, 56, "OUTLINE")
    F.elapsed:SetPoint("TOP", F.label, "BOTTOM", 0, -4)
    F.clock = Text(content, 14)
    F.clock:SetPoint("TOP", F.elapsed, "BOTTOM", 0, -6)
    F.clock:SetTextColor(0.8, 0.8, 0.8)

    -- Bottom bar: brand, tip, buttons, logout estimate
    F.logo = content:CreateTexture(nil, "ARTWORK")
    F.logo:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\eg-logo.tga")
    F.logo:SetSize(28, 28)
    F.brand = Text(content, 16, "OUTLINE")
    F.brand:SetPoint("LEFT", F.logo, "RIGHT", 8, 0)
    F.brand:SetText("EllesmereUI")
    F.tip = Text(content, 13)
    F.tip:SetTextColor(0.85, 0.85, 0.85)
    F.tip:SetWidth(700)
    F.logout = Text(content, 12)

    local function Button(label, onClick)
        local b = CreateFrame("Button", nil, content)
        b:SetSize(120, 30)
        b.bg = Solid(b, "BACKGROUND", 0, 0, 0, 0.6)
        b.bg:SetAllPoints()
        b.border = Solid(b, "BORDER", 1, 1, 1, 0.25)
        b.border:SetPoint("TOPLEFT", -1, 1); b.border:SetPoint("BOTTOMRIGHT", 1, -1)
        b.bg:SetDrawLayer("ARTWORK")
        b.label = Text(b, 13)
        b.label:SetPoint("CENTER")
        b.label:SetText(label)
        b:SetScript("OnEnter", function(self) local r, g, bl = Accent(); self.border:SetColorTexture(r, g, bl, 0.9) end)
        b:SetScript("OnLeave", function(self) self.border:SetColorTexture(1, 1, 1, 0.25) end)
        b:SetScript("OnClick", onClick)
        return b
    end
    F.back = Button(EllesmereUI.L("Back"), function() Exit("button") end)
    F.shot = Button(EllesmereUI.L("Screenshot"), function()
        if not Screenshot then return end
        S.shot = true
        for _, c in ipairs(cards) do c:SetAlpha(0) end
        F.hud:SetAlpha(0)
        C_Timer.After(0.05, Screenshot)
    end)

    -- Everything that hides for a screenshot except the model and bars.
    F.hud = CreateFrame("Frame", nil, content)
    F.hud:SetAllPoints()
    for _, r in ipairs({ F.label, F.elapsed, F.clock, F.logo, F.brand, F.tip, F.logout }) do r:SetParent(F.hud) end
    F.back:SetParent(F.hud); F.shot:SetParent(F.hud)

    -- Card stack
    F.cIdentity = MakeCard("identity", EllesmereUI.L("IDENTITY"))
    if not IS_FOREVER then
        F.cWeek = MakeCard("week", EllesmereUI.L("THIS WEEK"))
        F.cKeys = MakeCard("keys", EllesmereUI.L("KEYSTONES"))
    end
    F.cTimers = MakeCard("timers", EllesmereUI.L("TIMERS"))
    F.cGains = MakeCard("gains", EllesmereUI.L("WHILE AWAY"))
    F.cSocial = MakeCard("social", EllesmereUI.L("SOCIAL"))

    -- Message feed
    F.feed = CreateFrame("Frame", nil, F.hud)
    F.feed:SetSize(460, 10)
    F.feed.bg = Solid(F.feed, "BACKGROUND", 0, 0, 0, 0.55)
    F.feed.bg:SetAllPoints()
    F.feed.title = Text(F.feed, 11, "OUTLINE")
    F.feed.title:SetPoint("TOPLEFT", 14, -10)
    for i = 1, 6 do
        local row = CreateFrame("Button", nil, F.feed)
        row:SetSize(460 - 28, 18)
        row:SetPoint("TOPLEFT", F.feed.title, "BOTTOMLEFT", 0, -6 - (i - 1) * 20)
        row.text = Text(row, 12)
        row.text:SetAllPoints()
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.hl = Solid(row, "HIGHLIGHT", 1, 1, 1, 0.08)
        row.hl:SetAllPoints()
        row:SetScript("OnClick", function(self) ReplyTo(self.msg) end)
        feedRows[i] = row
    end

    -- Keys: Escape leaves; everything else leaves and passes through
    -- (a movement key then clears the AFK flag the usual way).
    root:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            Exit("key")
            return
        end
        if key == "PRINTSCREEN" or key:find("SHIFT") or key:find("CTRL") or key:find("ALT") then
            self:SetPropagateKeyboardInput(true)
            return
        end
        self:SetPropagateKeyboardInput(true)
        Exit("key")
    end)
end

-------------------------------------------------------------------------------
--  Scenes
-------------------------------------------------------------------------------
local function CurrentSeason()
    local s = Get("season")
    if SEASONS[s] then return s end
    local month = tonumber(date("%m")) or 1
    if month >= 3 and month <= 5 then return "spring" end
    if month >= 6 and month <= 8 then return "summer" end
    if month >= 9 and month <= 11 then return "fall" end
    return "winter"
end

local function SeedParticles()
    local season = SEASONS[CurrentSeason()]
    local w, h = content:GetWidth(), content:GetHeight()
    local function reset(p, anywhere)
        local col = season.colors[random(#season.colors)]
        local size = random(season.size[1], season.size[2])
        p.tex:SetSize(size, size)
        p.tex:SetVertexColor(col[1], col[2], col[3], season.alpha * (0.6 + random() * 0.4))
        p.x = random() * w
        if anywhere then p.y = random() * h
        else p.y = (season.dir < 0) and (h + 5) or -5 end
        p.vy = season.dir * random(season.speed[1], season.speed[2])
        p.vx = (random() - 0.5) * 20
        p.rot = random() * 6.28
        p.spin = (random() - 0.5) * 2
    end
    for _, p in ipairs(particles) do
        p.reset = reset
        reset(p, true)
    end
end

local function ApplyScene()
    local scene = Get("scene")
    local r, g, b = Accent()
    content:SetScale(tonumber(Get("scale")) or 1)
    local W, H = content:GetWidth(), content:GetHeight()

    for _, e in ipairs(fontStrings) do SetFont(e[1], e[2], e[3]) end

    local topH, botH
    if scene == "portrait" then topH, botH = 0, 56
    elseif scene == "seasons" then topH, botH = floor(H * 0.07), floor(H * 0.07)
    else topH, botH = floor(H * 0.1), floor(H * 0.1) end
    botH = max(botH, 56)

    F.topBar:SetHeight(max(topH, 0.01)); F.topBar:SetShown(topH > 0)
    F.botBar:SetHeight(botH)
    -- Bars are white textures tinted by a vertical gradient (min = bottom):
    -- plain black, or black fading into a dark shade of the season's color.
    local barA = (scene == "seasons") and 0.85 or 1
    local black = CreateColor(0, 0, 0, barA)
    local edge = black
    if scene == "seasons" then
        local c = SEASONS[CurrentSeason()].colors[1]
        edge = CreateColor(c[1] * 0.25, c[2] * 0.25, c[3] * 0.25, barA)
    end
    F.topBar:SetGradient("VERTICAL", black, edge)
    F.botBar:SetGradient("VERTICAL", edge, black)
    local lineA = (scene == "forever") and 0.9 or 0.6
    F.topLine:SetColorTexture(r, g, b, lineA); F.topLine:SetShown(topH > 0)
    F.botLine:SetColorTexture(r, g, b, lineA)

    -- Vignettes: a dark side behind the model (portrait), a light one behind
    -- the cards (all scenes) so text reads over any world.
    F.vignette:SetShown(scene == "portrait")
    F.vignette:SetWidth(W * 0.55)
    F.vignette:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.85), CreateColor(0, 0, 0, 0))
    F.vignetteR:SetWidth(W * 0.35)
    F.vignetteR:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.5))

    -- Header
    F.label:ClearAllPoints()
    F.label:SetPoint("TOP", content, "TOP", 0, -(topH + 24))
    F.label:SetTextColor(r, g, b)
    F.label:SetText(EllesmereUI.L("AWAY FROM KEYBOARD"))

    -- Bottom bar contents
    F.logo:ClearAllPoints(); F.logo:SetPoint("LEFT", F.botBar, "LEFT", 30, 0)
    if scene == "forever" then F.logo:SetVertexColor(r, g, b) else F.logo:SetVertexColor(1, 1, 1) end
    F.brand:SetTextColor(r, g, b)
    F.back:ClearAllPoints(); F.back:SetPoint("RIGHT", F.botBar, "RIGHT", -30, 0)
    F.shot:ClearAllPoints(); F.shot:SetPoint("RIGHT", F.back, "LEFT", -10, 0)
    F.tip:ClearAllPoints(); F.tip:SetPoint("CENTER", F.botBar, "CENTER", 0, 0)
    F.tip:SetShown(Get("showTips"))
    F.logout:ClearAllPoints(); F.logout:SetPoint("BOTTOMRIGHT", F.botBar, "TOPRIGHT", -30, 10)

    -- Cards
    F.cardTop = -(max(topH, 0) + 30)
    for _, c in ipairs(cards) do c.stripe:SetColorTexture(r, g, b, 1); c.title:SetTextColor(r, g, b) end
    F.feed.title:SetTextColor(r, g, b)

    -- Model
    local showModel = Get("showModel")
    F.model:SetShown(showModel)
    F.model:ClearAllPoints()
    if scene == "portrait" then
        F.model:SetSize(W * 0.42, H * 0.85)
        F.model:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", W * 0.04, botH)
    else
        F.model:SetSize(W * 0.28, H * 0.62)
        F.model:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", W * 0.03, botH)
    end
    F.pet:ClearAllPoints()
    F.pet:SetSize(W * 0.14, H * 0.28)
    F.pet:SetPoint("BOTTOMLEFT", F.model, "BOTTOMRIGHT", -W * 0.05, 0)

    -- Feed: above the bottom bar, right of the model in portrait
    F.feed:ClearAllPoints()
    if scene == "portrait" then
        F.feed:SetPoint("BOTTOM", content, "BOTTOM", 0, botH + 20)
    else
        F.feed:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", W * 0.03 + (showModel and W * 0.26 or 0), botH + 20)
    end

    -- Particles
    local seasons = (scene == "seasons")
    F.particles:SetShown(seasons)
    if seasons then SeedParticles() end
end

-------------------------------------------------------------------------------
--  Model
-------------------------------------------------------------------------------
local function PlayAnim(id)
    if not (F.model and F.model:IsShown()) then return end
    if F.model.HasAnimation and not F.model:HasAnimation(id) then return end
    F.model:SetAnimation(id)
end

local function NextEmote()
    if animTimer then animTimer:Cancel(); animTimer = nil end
    if not S.shown then return end
    if S.openedAt > 0 and GetTime() - S.openedAt >= SLEEP_AFTER and Get("modelReactions") then
        S.asleep = true
        PlayAnim(ANIM_SLEEP)
    else
        local pool = {}
        for _, id in ipairs(EMOTES) do
            if id ~= S.lastAnim and (not F.model.HasAnimation or F.model:HasAnimation(id)) then pool[#pool + 1] = id end
        end
        if #pool > 0 then
            S.lastAnim = pool[random(#pool)]
            PlayAnim(S.lastAnim)
        end
    end
    animTimer = C_Timer.NewTimer(random(15, 30), NextEmote)
end

local function React(id)
    if not (S.shown and Get("modelReactions")) or S.asleep then return end
    PlayAnim(id)
end

local function SetupModel()
    local m = F.model
    if not Get("showModel") then F.pet:Hide(); return end
    m:ClearModel()
    m:SetUnit("player")
    m:SetPortraitZoom(0)
    m:SetCamDistanceScale(Get("scene") == "portrait" and 0.95 or 1.15)
    m:SetFacing(0.45)
    m:SetAnimation(ANIM_IDLE)
    S.asleep = false

    local petShown = false
    if Get("showPet") and C_PetJournal and C_PetJournal.GetSummonedPetGUID then
        local guid = C_PetJournal.GetSummonedPetGUID()
        if guid then
            local ok, _, _, _, _, _, displayID = pcall(C_PetJournal.GetPetInfoByPetID, guid)
            if ok and displayID and displayID > 0 then
                F.pet:ClearModel()
                F.pet:SetDisplayInfo(displayID)
                F.pet:SetFacing(0.6)
                petShown = true
            end
        end
    end
    F.pet:SetShown(petShown)
    NextEmote()
end

-------------------------------------------------------------------------------
--  Cards
-------------------------------------------------------------------------------
local function IdentityText()
    local lines = {}
    local name = UnitName("player") or ""
    local _, class = UnitClass("player")
    local level = UnitLevel("player")
    local specName
    if GetSpecialization and GetSpecializationInfo then
        local spec = GetSpecialization()
        if spec then specName = select(2, GetSpecializationInfo(spec)) end
    end
    local className = UnitClass("player")
    if Get("streamer") then
        lines[#lines + 1] = format("|cff%s%s|r", ClassHex(class), specName and (specName .. " " .. className) or className)
    else
        local title = GetCurrentTitle and GetTitleName and GetCurrentTitle() > 0 and GetTitleName(GetCurrentTitle())
        lines[#lines + 1] = format("|cff%s%s|r%s", ClassHex(class), name, title and ("  |cff999999" .. strtrim(title) .. "|r") or "")
        lines[#lines + 1] = format("|cff%s%s|r", ClassHex(class), specName and (specName .. " " .. className) or className)
    end
    local ilvlText = ""
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then ilvlText = EllesmereUI.Lf("Item level %.1f", equipped) end
    end
    lines[#lines + 1] = EllesmereUI.Lf("Level %d", level) .. (ilvlText ~= "" and ("  -  " .. ilvlText) or "")
    local score = MythicScore()
    if score then
        local color = C_ChallengeMode.GetDungeonScoreRarityColor and C_ChallengeMode.GetDungeonScoreRarityColor(score)
        local hex = color and color.GenerateHexColor and color:GenerateHexColor() or "ffffffff"
        lines[#lines + 1] = EllesmereUI.Lf("Mythic+ score %s", "|c" .. hex .. floor(score) .. "|r")
    end
    if not Get("streamer") then
        local guild = GetGuildInfo and GetGuildInfo("player")
        if guild then lines[#lines + 1] = "|cff40ff40<" .. guild .. ">|r" end
        local zone, sub = GetZoneText(), GetSubZoneText()
        if zone and zone ~= "" then
            lines[#lines + 1] = "|cffbbbbbb" .. ((sub and sub ~= "" and sub ~= zone) and (sub .. ", " .. zone) or zone) .. "|r"
        end
    end
    return table.concat(lines, "\n")
end

local function WeekText()
    local lines = {}
    local rows = VaultState()
    if rows then
        local parts = {}
        local ah = AccentHex()
        for _, row in ipairs(rows) do
            local col = (row.done >= row.count and row.count > 0) and ah or (row.done > 0 and "ffffff" or "777777")
            parts[#parts + 1] = format("%s |cff%s%d/%d|r", row.label, col, row.done, row.count)
        end
        lines[#lines + 1] = EllesmereUI.L("Great Vault") .. ":  " .. table.concat(parts, "   ")
    end
    local map, lvl = OwnKeystone()
    if map then lines[#lines + 1] = EllesmereUI.Lf("Keystone: +%d %s", lvl, DungeonName(map)) end
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        local parts = {}
        for _, id in ipairs(CREST_IDS) do
            local info = C_CurrencyInfo.GetCurrencyInfo(id)
            if info and info.iconFileID and ((info.quantity or 0) > 0 or (info.totalEarned or 0) > 0) then
                parts[#parts + 1] = format("|T%d:14:14:0:0|t %d", info.iconFileID, info.quantity or 0)
            end
        end
        if #parts > 0 then lines[#lines + 1] = table.concat(parts, "   ") end
    end
    return table.concat(lines, "\n")
end

local function KeysText()
    local list = {}
    local me = UnitName("player")
    local map, lvl = OwnKeystone()
    if map then list[#list + 1] = { name = me, level = lvl, map = map, mine = true } end
    for name, k in pairs(keys) do
        if name ~= me and k.level and k.level > 0 and k.map and k.map > 0 then
            list[#list + 1] = { name = name, level = k.level, map = k.map, guild = k.guild }
        end
    end
    if #list == 0 then return "" end
    table.sort(list, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return a.name < b.name
    end)
    local lines = {}
    local ah = AccentHex()
    for i = 1, min(#list, 6) do
        local k = list[i]
        local who = Get("streamer") and "" or ("  |cff999999" .. Ambiguate(k.name, "short") .. "|r")
        lines[#lines + 1] = format("|cff%s+%d|r %s%s", k.mine and ah or "ffffff", k.level, DungeonName(k.map), who)
    end
    return table.concat(lines, "\n")
end

local function TimersText()
    local lines = {}
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
        local d = C_DateAndTime.GetSecondsUntilDailyReset()
        if d and d > 0 then lines[#lines + 1] = EllesmereUI.Lf("Daily reset in %s", Duration(d)) end
    end
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local w = C_DateAndTime.GetSecondsUntilWeeklyReset()
        if w and w > 0 then lines[#lines + 1] = EllesmereUI.Lf("Weekly reset in %s", Duration(w)) end
    end
    local holidays = TodayHolidays()
    if holidays then
        for _, t in ipairs(holidays) do lines[#lines + 1] = "|cffffd100" .. t .. "|r" end
    end
    return table.concat(lines, "\n")
end

local function GainsText()
    local lines = {}
    local pct = RestedPct()
    if pct then
        local delta = S.restedPct and (pct - S.restedPct) or 0
        lines[#lines + 1] = EllesmereUI.Lf("Rested XP %d%%", floor(pct + 0.5))
            .. (delta >= 0.5 and format("  |cff40ff40+%d%%|r", floor(delta + 0.5)) or "")
    end
    if not Get("streamer") then
        local diff = GetMoney() - (S.money or 0)
        if diff ~= 0 then
            lines[#lines + 1] = EllesmereUI.L("Gold") .. ": " .. (diff > 0 and "|cff40ff40+|r" or "|cffff4040-|r") .. Money(math.abs(diff))
        end
    end
    local _, total = VaultState()
    if total > (S.vaultDone or 0) then
        lines[#lines + 1] = "|cff40ff40" .. EllesmereUI.L("New Great Vault option") .. "|r"
    end
    if #lines == 0 then lines[1] = "|cff888888" .. EllesmereUI.L("Nothing yet") .. "|r" end
    return table.concat(lines, "\n")
end

local function SocialText()
    local lines = {}
    lines[#lines + 1] = EllesmereUI.Lf("Friends online: %d", FriendsOnline())
    local g = GuildOnline()
    if g then lines[#lines + 1] = EllesmereUI.Lf("Guild online: %d", g) end
    if #logins > 0 then
        if Get("streamer") then
            lines[#lines + 1] = EllesmereUI.Lf("%d logged in while you were away", #logins)
        else
            local first = {}
            for i = max(1, #logins - 4), #logins do first[#first + 1] = logins[i] end
            lines[#lines + 1] = EllesmereUI.L("Logged in:") .. " |cffffffff" .. table.concat(first, ", ") .. "|r"
        end
    end
    return table.concat(lines, "\n")
end

function RefreshCards()
    if not (root and S.shown) then return end
    local sections = {
        { F.cIdentity, "showIdentity", IdentityText },
        { F.cWeek, "showWeek", WeekText },
        { F.cKeys, "showKeys", KeysText },
        { F.cTimers, "showTimers", TimersText },
        { F.cGains, "showGains", GainsText },
        { F.cSocial, "showSocial", SocialText },
    }
    for _, s in ipairs(sections) do
        local card = s[1]
        if card then
            card.wanted = Get(s[2]) and true or false
            if card.wanted then
                local ok, text = pcall(s[3])
                card.body:SetText(ok and text or "")
            end
        end
    end
    LayoutCards()
end

function RefreshFeed()
    if not root then return end
    local show = S.shown and Get("showMessages") and #messages > 0
    F.feed:SetShown(show and true or false)
    if not show then return end
    F.feed.title:SetText(EllesmereUI.Lf("MESSAGES (%d)", #messages))
    local n = 0
    for i = #messages, max(1, #messages - #feedRows + 1), -1 do
        n = n + 1
        local row = feedRows[n]
        row.msg = messages[i]
        row.text:SetText(MessageLine(messages[i]))
        row:Show()
    end
    for i = n + 1, #feedRows do feedRows[i]:Hide() end
    F.feed:SetHeight(10 + F.feed.title:GetStringHeight() + 6 + n * 20 + 8)
end

local tipIndex = 0
local function NextTip()
    if not (F.tip and Get("showTips")) then return end
    tipIndex = (tipIndex % #TIPS) + 1
    if tipIndex == 1 then
        -- Reshuffle once per pass.
        for i = #TIPS, 2, -1 do
            local j = random(i)
            TIPS[i], TIPS[j] = TIPS[j], TIPS[i]
        end
    end
    F.tip:SetText("|cff" .. AccentHex() .. EllesmereUI.L("Tip:") .. "|r " .. TIPS[tipIndex])
end

local tick = 0
local function OnTick()
    if not S.shown then return end
    tick = tick + 1
    local now = GetTime()
    F.elapsed:SetText(Clock(now - S.openedAt))
    F.clock:SetText(date("%H:%M") .. "  -  " .. DateText())
    if Get("logoutWarning") and not S.preview and S.afkSince then
        local left = LOGOUT_AFTER_FLAG - (now - S.afkSince)
        local col = left < 300 and "ff4040" or "bbbbbb"
        F.logout:SetText(left > 0 and format("|cff%s%s %s|r", col, EllesmereUI.L("Auto logout (estimated) in"), Clock(left))
            or format("|cffff4040%s|r", EllesmereUI.L("Auto logout imminent")))
        F.logout:Show()
    else
        F.logout:Hide()
    end
    if tick % 5 == 0 then RefreshCards() end
    if tick % 20 == 0 then NextTip() end
    if tick % 60 == 0 and C_GuildInfo and C_GuildInfo.GuildRoster and IsInGuild and IsInGuild() then
        C_GuildInfo.GuildRoster()
    end
end

-------------------------------------------------------------------------------
--  Return summary
-------------------------------------------------------------------------------
local summary

local function ShowSummary(away, startRested, startVault)
    if not Get("returnSummary") or away < 60 then return end
    if not summary then
        summary = CreateFrame("Frame", "EllesmereUIAFKSummary", UIParent)
        summary:SetFrameStrata("DIALOG")
        summary:SetSize(560, 60)
        summary:SetPoint("TOP", UIParent, "TOP", 0, -90)
        summary:EnableMouse(true)
        summary.bg = Solid(summary, "BACKGROUND", 0.05, 0.05, 0.05, 0.92)
        summary.bg:SetAllPoints()
        summary.stripe = Solid(summary, "BORDER", 1, 1, 1, 1)
        summary.stripe:SetPoint("TOPLEFT"); summary.stripe:SetPoint("TOPRIGHT"); summary.stripe:SetHeight(2)
        summary.head = summary:CreateFontString(nil, "OVERLAY")
        summary.head:SetPoint("TOPLEFT", 14, -12)
        summary.head:SetPoint("RIGHT", -34, 0)
        summary.head:SetJustifyH("LEFT")
        summary.rows = {}
        for i = 1, 3 do
            local row = CreateFrame("Button", nil, summary)
            row:SetHeight(18)
            row:SetPoint("TOPLEFT", summary.head, "BOTTOMLEFT", 0, -6 - (i - 1) * 20)
            row:SetPoint("RIGHT", summary, "RIGHT", -14, 0)
            row.text = row:CreateFontString(nil, "OVERLAY")
            row.text:SetAllPoints()
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)
            row.hl = Solid(row, "HIGHLIGHT", 1, 1, 1, 0.08)
            row.hl:SetAllPoints()
            row:SetScript("OnClick", function(self)
                summary:Hide()
                local m = self.msg
                if not m then return end
                if m.bnID then
                    local fn = (ChatFrameUtil and ChatFrameUtil.SendBNetTell) or ChatFrame_SendBNetTell
                    if fn then pcall(fn, m.sender) end
                else
                    local fn = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
                    if fn then pcall(fn, m.sender) end
                end
            end)
            summary.rows[i] = row
        end
        local close = CreateFrame("Button", nil, summary, "UIPanelCloseButtonNoScripts")
        close:SetPoint("TOPRIGHT", 2, 2)
        close:SetScript("OnClick", function() summary:Hide() end)
        summary:SetScript("OnEnter", function() if summaryTimer then summaryTimer:Cancel(); summaryTimer = nil end end)
        summary:SetScript("OnLeave", function()
            summaryTimer = C_Timer.NewTimer(6, function() summaryTimer = nil; summary:Hide() end)
        end)
    end

    local r, g, b = Accent()
    summary.stripe:SetColorTexture(r, g, b, 1)
    local fontPath = FontPath()
    if not summary.head:SetFont(fontPath, 13, "") then summary.head:SetFont(STANDARD_TEXT_FONT, 13, "") end

    local chips = { "|cff" .. AccentHex() .. EllesmereUI.Lf("Away %s", Duration(away)) .. "|r" }
    local whispers = 0
    for _, m in ipairs(messages) do if m.kind == "whisper" then whispers = whispers + 1 end end
    if whispers > 0 then chips[#chips + 1] = EllesmereUI.Lf("%d whispers", whispers) end
    if #logins > 0 then chips[#chips + 1] = EllesmereUI.Lf("%d friends logged in", #logins) end
    local pct = RestedPct()
    if pct and startRested and pct - startRested >= 0.5 then
        chips[#chips + 1] = EllesmereUI.Lf("+%d%% rested XP", floor(pct - startRested + 0.5))
    end
    if not Get("streamer") then
        local diff = GetMoney() - (S.money or 0)
        if diff > 0 then chips[#chips + 1] = "+" .. Money(diff) end
    end
    local _, total = VaultState()
    if total > (startVault or 0) then chips[#chips + 1] = EllesmereUI.L("New Great Vault option") end
    summary.head:SetText(table.concat(chips, "  -  "))

    local n = 0
    for i = #messages, 1, -1 do
        local m = messages[i]
        if m.kind == "whisper" and m.sender and n < 3 then
            n = n + 1
            local row = summary.rows[n]
            if not row.text:SetFont(fontPath, 12, "") then row.text:SetFont(STANDARD_TEXT_FONT, 12, "") end
            row.msg = m
            row.text:SetText(MessageLine(m))
            row:Show()
        end
    end
    for i = n + 1, 3 do summary.rows[i]:Hide() end
    summary:SetHeight(12 + summary.head:GetStringHeight() + 12 + n * 20)
    summary:Show()
    if summaryTimer then summaryTimer:Cancel() end
    summaryTimer = C_Timer.NewTimer(15, function() summaryTimer = nil; summary:Hide() end)
end

-------------------------------------------------------------------------------
--  Alert toast (shown after an urgent alert has closed the screen)
-------------------------------------------------------------------------------
local toast, toastTicker

local function ShowToast(text, seconds)
    if not toast then
        toast = CreateFrame("Frame", nil, UIParent)
        toast:SetFrameStrata("FULLSCREEN_DIALOG")
        toast:SetSize(520, 70)
        toast:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
        toast.bg = Solid(toast, "BACKGROUND", 0, 0, 0, 0.8)
        toast.bg:SetAllPoints()
        toast.stripe = Solid(toast, "BORDER", 1, 1, 1, 1)
        toast.stripe:SetPoint("BOTTOMLEFT"); toast.stripe:SetPoint("BOTTOMRIGHT"); toast.stripe:SetHeight(2)
        toast.text = toast:CreateFontString(nil, "OVERLAY")
        toast.text:SetPoint("CENTER", 0, 8)
        toast.count = toast:CreateFontString(nil, "OVERLAY")
        toast.count:SetPoint("TOP", toast.text, "BOTTOM", 0, -4)
    end
    local r, g, b = Accent()
    toast.stripe:SetColorTexture(r, g, b, 1)
    local fp = FontPath()
    if not toast.text:SetFont(fp, 22, "OUTLINE") then toast.text:SetFont(STANDARD_TEXT_FONT, 22, "OUTLINE") end
    if not toast.count:SetFont(fp, 14, "") then toast.count:SetFont(STANDARD_TEXT_FONT, 14, "") end
    toast.text:SetText(text)
    toast.text:SetTextColor(r, g, b)
    if toastTicker then toastTicker:Cancel(); toastTicker = nil end
    local left = floor(seconds or 0)
    local function update()
        if left > 0 then toast.count:SetText(EllesmereUI.Lf("%d seconds left", left)) else toast.count:SetText("") end
    end
    update()
    toast:Show()
    local life = (left > 0) and left or 8
    toastTicker = C_Timer.NewTicker(1, function()
        left = left - 1
        life = life - 1
        update()
        if life <= 0 then toastTicker:Cancel(); toastTicker = nil; toast:Hide() end
    end)
end

local function Alert(key, text, seconds, urgent)
    if not (S.shown and Get(key)) then return end
    if Get("alertSound") then PlaySound((SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960, "Master") end
    if Get("flashIcon") and FlashClientIcon then FlashClientIcon() end
    if urgent then
        Exit("alert")
        ShowToast(text, seconds)
    else
        messages[#messages + 1] = { kind = "system", text = text, at = time() }
        RefreshFeed()
    end
end

-------------------------------------------------------------------------------
--  Open / close
-------------------------------------------------------------------------------
local function FrameShown(name)
    local f = _G[name]
    return f and f.IsShown and f:IsShown()
end

local function CanEnter()
    if InCombatLockdown() or UnitAffectingCombat("player") then return false end
    if Get("where") == "resting" and not IsResting() then return false end
    local inInstance = IsInInstance()
    if inInstance then return false end
    if UnitOnTaxi and UnitOnTaxi("player") then return false end
    if UnitInVehicle and UnitInVehicle("player") then return false end
    if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then return false end
    if InCinematic and InCinematic() then return false end
    if FrameShown("MovieFrame") or FrameShown("CinematicFrame") then return false end
    if UnitCastingInfo("player") or UnitChannelInfo("player") then return false end
    for _, name in ipairs({ "MerchantFrame", "BankFrame", "MailFrame", "AuctionHouseFrame", "TradeFrame", "GuildBankFrame" }) do
        if FrameShown(name) then return false end
    end
    return true
end

function Enter(preview)
    if S.shown or InCombatLockdown() then return end
    if not preview and not CanEnter() then return end
    Build()

    S.shown, S.preview, S.dismissed = true, preview and true or false, false
    S.openedAt = GetTime()
    S.money = GetMoney()
    S.restedPct = RestedPct()
    local _, vaultDone = VaultState()
    S.vaultDone = vaultDone
    S.lastAnim, S.asleep, S.mailNoted, tick = 0, false, false, 0
    wipe(messages); wipe(logins)

    if UIParent:IsShown() then UIParent:Hide(); S.uiHidden = true end
    root:SetScale(UIParent:GetScale())
    root:SetAlpha(0)
    root:Show()
    ApplyScene()
    for _, c in ipairs(cards) do c:SetAlpha(1) end
    F.hud:SetAlpha(1)
    root.fade:SetScript("OnFinished", function() root:SetAlpha(1) end)
    root.fade:Play()

    StartCamera()
    SetupModel()
    HoldFPS()

    -- Ask for the data that arrives late.
    if C_Calendar and C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end
    if C_GuildInfo and C_GuildInfo.GuildRoster and IsInGuild and IsInGuild() then C_GuildInfo.GuildRoster() end
    local LibKeystone = LibStub and LibStub("LibKeystone", true)
    if LibKeystone and not IS_FOREVER and Get("showKeys") then
        if IsInGroup() then LibKeystone.Request("PARTY") end
        if IsInGuild() then LibKeystone.Request("GUILD") end
    end

    tipIndex = 0
    NextTip()
    RefreshCards()
    RefreshFeed()
    OnTick()
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(1, OnTick)
    C_Timer.After(2, RefreshCards)
end

function Exit(reason)
    if not S.shown then return end
    local away = GetTime() - S.openedAt
    local wasPreview = S.preview
    local startRested, startVault = S.restedPct, S.vaultDone
    S.shown, S.preview = false, false

    if ticker then ticker:Cancel(); ticker = nil end
    if animTimer then animTimer:Cancel(); animTimer = nil end
    RestoreCamera()
    ReleaseFPS()
    if root then root.fade:Stop(); root:Hide() end
    if S.uiHidden then UIParent:Show(); S.uiHidden = false end

    if UnitIsAFK("player") and not wasPreview then S.dismissed = true end
    if not wasPreview and reason ~= "combat" and reason ~= "leaving" then
        ShowSummary(away, startRested, startVault)
    end
end

-- Opens after the configured delay; while something blocks it (a cast, an
-- open merchant...) it keeps checking every 10s for as long as the flag holds.
local function TryEnter(delay)
    if delayTimer then delayTimer:Cancel(); delayTimer = nil end
    if not Get("enabled") or not UnitIsAFK("player") or S.dismissed or S.shown then return end
    delay = delay or tonumber(Get("delay")) or 0
    if delay > 0 then
        delayTimer = C_Timer.NewTimer(delay, function()
            delayTimer = nil
            TryEnter(0)
        end)
        return
    end
    Enter(false)
    if not S.shown then TryEnter(10) end
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local FRIEND_ONLINE_PATTERN
do
    local s = ERR_FRIEND_ONLINE_SS
    if type(s) == "string" then
        s = s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        FRIEND_ONLINE_PATTERN = "^" .. s:gsub("%%%%s", "(.-)") .. "$"
    end
end
local AUCTION_SOLD_PATTERN
do
    local s = ERR_AUCTION_SOLD_S
    if type(s) == "string" then
        s = s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        AUCTION_SOLD_PATTERN = "^" .. s:gsub("%%%%s", "(.-)") .. "$"
    end
end

local function AddMessage(kind, text, sender, guid, bnID)
    if IsSecret(text) or IsSecret(sender) then text, sender = nil, nil end
    if kind == "whisper" and sender and not bnID then sender = Ambiguate(sender, "none") end
    messages[#messages + 1] = { kind = kind, text = text, sender = sender, guid = guid, bnID = bnID, at = time() }
    while #messages > 30 do table.remove(messages, 1) end
    RefreshFeed()
end

local handlers = {}

handlers.PLAYER_FLAGS_CHANGED = function(unit)
    if unit and unit ~= "player" then return end
    if UnitIsAFK("player") then
        if not S.afkSince then S.afkSince = GetTime() end
        TryEnter()
    else
        S.afkSince, S.dismissed = nil, false
        if delayTimer then delayTimer:Cancel(); delayTimer = nil end
        if S.shown and not S.preview then Exit("back") end
    end
end

handlers.PLAYER_REGEN_DISABLED = function() Exit("combat") end
handlers.PLAYER_LEAVING_WORLD = function() Exit("leaving") end
handlers.PLAYER_ENTERING_WORLD = function()
    if S.shown and not S.preview and not CanEnter() then Exit("zone") end
end

handlers.CHAT_MSG_WHISPER = function(msg, sender, _, _, _, _, _, _, _, _, _, guid)
    if not S.shown then return end
    AddMessage("whisper", msg, sender, guid)
    React(ANIM_WAVE)
end
handlers.CHAT_MSG_BN_WHISPER = function(msg, sender, _, _, _, _, _, _, _, _, _, _, bnID)
    if not S.shown then return end
    AddMessage("whisper", msg, sender, nil, bnID or true)
    React(ANIM_WAVE)
end
handlers.CHAT_MSG_GUILD = function(msg, sender)
    if not (S.shown and Get("msgGuild")) then return end
    AddMessage("guild", msg, sender and not IsSecret(sender) and Ambiguate(sender, "guild") or sender)
end

handlers.CHAT_MSG_SYSTEM = function(msg)
    if IsSecret(msg) or type(msg) ~= "string" then return end
    if S.shown and FRIEND_ONLINE_PATTERN then
        local who = msg:match(FRIEND_ONLINE_PATTERN)
        if who then
            local name = who:match("%[(.-)%]") or who:gsub("|H.-|h", ""):gsub("|h", "")
            logins[#logins + 1] = name
            React(ANIM_APPLAUD)
            return
        end
    end
    if AUCTION_SOLD_PATTERN then
        local item = msg:match(AUCTION_SOLD_PATTERN)
        if item then Alert("alertAuction", EllesmereUI.Lf("Auction sold: %s", item), nil, false) end
    end
end

handlers.BN_FRIEND_ACCOUNT_ONLINE = function(bnID)
    if not S.shown or not (C_BattleNet and C_BattleNet.GetAccountInfoByID) then return end
    local info = C_BattleNet.GetAccountInfoByID(bnID)
    if info and info.accountName and not IsSecret(info.accountName) then
        logins[#logins + 1] = info.accountName
        React(ANIM_APPLAUD)
    end
end

handlers.UPDATE_PENDING_MAIL = function()
    -- The event repeats while mail waits: one line per screen session.
    if S.shown and not S.mailNoted and HasNewMail and HasNewMail() then
        S.mailNoted = true
        Alert("alertMail", EllesmereUI.L("New mail"), nil, false)
    end
end

handlers.LFG_PROPOSAL_SHOW = function() Alert("alertQueue", EllesmereUI.L("Your queue is ready!"), 40, true) end
handlers.PET_BATTLE_QUEUE_PROPOSE_MATCH = function() Alert("alertQueue", EllesmereUI.L("Your pet battle is ready!"), 30, true) end
handlers.UPDATE_BATTLEFIELD_STATUS = function(index)
    if not (S.shown and GetBattlefieldStatus) then return end
    local status = GetBattlefieldStatus(index or 1)
    if status == "confirm" then
        local left = GetBattlefieldPortExpiration and GetBattlefieldPortExpiration(index or 1) or 0
        Alert("alertQueue", EllesmereUI.L("Your battleground is ready!"), left, true)
    end
end
handlers.READY_CHECK = function(_, timeLeft) Alert("alertReadyCheck", EllesmereUI.L("Ready check!"), timeLeft, true) end
handlers.CONFIRM_SUMMON = function()
    local left = C_SummonInfo and C_SummonInfo.GetSummonConfirmTimeLeft and C_SummonInfo.GetSummonConfirmTimeLeft() or 0
    Alert("alertSummon", EllesmereUI.L("You are being summoned"), left, true)
end
handlers.PARTY_INVITE_REQUEST = function() Alert("alertInvite", EllesmereUI.L("Group invite"), nil, true) end
handlers.LFG_LIST_APPLICATION_STATUS_UPDATED = function(_, newStatus)
    if newStatus == "invited" then Alert("alertInvite", EllesmereUI.L("Group Finder invite"), nil, true) end
end
handlers.PLAYER_CAMPING = function() Alert("logoutWarning", EllesmereUI.L("You are about to be logged out"), 20, true) end

handlers.SCREENSHOT_SUCCEEDED = function()
    if not S.shot then return end
    S.shot = false
    if not root then return end
    for _, c in ipairs(cards) do c:SetAlpha(1) end
    F.hud:SetAlpha(1)
end
handlers.SCREENSHOT_FAILED = handlers.SCREENSHOT_SUCCEEDED

handlers.GUILD_ROSTER_UPDATE = function() if S.shown then RefreshCards() end end
handlers.CALENDAR_UPDATE_EVENT_LIST = handlers.GUILD_ROSTER_UPDATE

-- LibKeystone feed (own table, separate from the /keys popup's).
local lksTable = {}
local lksRegistered = false
local function RegisterKeystoneFeed()
    if lksRegistered or IS_FOREVER then return end
    local LibKeystone = LibStub and LibStub("LibKeystone", true)
    if not LibKeystone then return end
    lksRegistered = true
    LibKeystone.Register(lksTable, function(keyLevel, keyMapID, _, playerName, channel)
        if not playerName then return end
        keys[playerName] = { level = keyLevel, map = keyMapID, guild = channel == "GUILD" }
        if S.shown then RefreshCards() end
    end)
end

ev = CreateFrame("Frame")
local registered = false
local function SyncEvents()
    local want = Get("enabled") and true or false
    if want == registered then return end
    registered = want
    for name in pairs(handlers) do
        pcall(want and ev.RegisterEvent or ev.UnregisterEvent, ev, name)
    end
    if want then RegisterKeystoneFeed() end
end

ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        -- A hold that outlived its session (disconnect, crash) goes back first.
        if Cfg()._heldFPS then ReleaseFPS() end
        SyncEvents()
        if registered and UnitIsAFK("player") then
            S.afkSince = GetTime()
            TryEnter()
        end
        return
    end
    local h = handlers[event]
    if h then h(...) end
end)

-------------------------------------------------------------------------------
--  Options hooks
-------------------------------------------------------------------------------
_G._EUI_ApplyAFKScreen = function()
    SyncEvents()
    if not Get("enabled") then
        if S.shown and not S.preview then Exit("disabled") end
        return
    end
    if S.shown then
        ApplyScene()
        SetupModel()
        RefreshCards()
        RefreshFeed()
    elseif UnitIsAFK("player") then
        TryEnter()
    end
end

-- Preview from the options page: opens regardless of the AFK flag and the
-- open conditions (combat aside); any key or the Back button closes it.
_G._EUI_AFKScreenPreview = function(on)
    if on then
        if S.shown then return end
        Enter(true)
        if S.shown then
            -- Sample content so every card and the feed have something to show.
            AddMessage("whisper", EllesmereUI.L("Ready for the key tonight?"), UnitName("player"))
            logins[#logins + 1] = UnitName("player")
            RefreshCards()
        end
    elseif S.shown and S.preview then
        Exit("preview")
    end
end
_G._EUI_AFKScreenPreviewActive = function() return S.shown and S.preview end
