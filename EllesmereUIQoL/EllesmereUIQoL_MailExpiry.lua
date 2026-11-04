if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_MailExpiry.lua
--  Mail that is about to expire, each off by default (EllesmereUIDB.mailExpiry):
--   - warning: on opening the mailbox, one chat line for the mail with gold or
--     items that expires within WARN_DAYS.
--   - alts: the mailbox remembers, for each character, when its first mail
--     expires; one chat line at login names the characters (this one
--     included) whose mail expires within WARN_DAYS. A character is remembered
--     once its mailbox has been opened with this on.
--
--  Taint: nothing of Blizzard's is hooked or written; the inbox is only read.
--  While both are off no event is registered. MAIL_SHOW / MAIL_CLOSED follow
--  the mailbox; MAIL_INBOX_UPDATE is listened to only while it is open (once,
--  for the warning, and as the inbox changes, for the alts); and
--  PLAYER_ENTERING_WORLD once, for the login reminder.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local PREFIX = "|cff0cd29dEllesmereUI:|r "
local WARN_DAYS = 3

-- Reading never creates the table, so nothing is saved while both are off.
local EMPTY = {}
local function Cfg()
    local db = EllesmereUIDB
    return db and db.mailExpiry or EMPTY
end
local function CfgW()
    EllesmereUIDB.mailExpiry = EllesmereUIDB.mailExpiry or {}
    return EllesmereUIDB.mailExpiry
end
local function On(key) return Cfg()[key] == true end

local ev = CreateFrame("Frame")
local mailOpen          -- the mailbox is open
local waitingInbox      -- the mailbox just opened: its first update runs the warning

local function DaysText(days)
    return SecondsToTime(math.max(days, 0) * 86400, true)
end

-- The soonest expiry (days) of mail holding gold or items, and how many expire
-- within WARN_DAYS.
local function Scan()
    local count, soonest = 0, nil
    for i = 1, (GetInboxNumItems()) do
        local _, _, _, _, money, _, daysLeft, itemCount = GetInboxHeaderInfo(i)
        if ((money or 0) > 0 or (itemCount or 0) > 0) and daysLeft then
            if daysLeft < WARN_DAYS then count = count + 1 end
            if not soonest or daysLeft < soonest then soonest = daysLeft end
        end
    end
    return count, soonest
end

-------------------------------------------------------------------------------
--  Warning on opening
-------------------------------------------------------------------------------
local function WarnExpiry()
    local count, soonest = Scan()
    if count > 0 then
        EUI.Print(PREFIX .. EllesmereUI.Lf("%d mail with gold or items expires within %d days (soonest: %s).",
            count, WARN_DAYS, DaysText(soonest)))
    end
end

-------------------------------------------------------------------------------
--  Mail expiry of every character
-------------------------------------------------------------------------------
-- This character's key, "Name-Realm", and its class.
local function SelfKey()
    local name, realm = UnitFullName("player")
    if not name then return end
    return name .. "-" .. (realm or GetNormalizedRealmName()), select(2, UnitClass("player"))
end

-- A character as it is shown: "Name" on this realm, "Name-Realm" elsewhere,
-- in its class colour. Returns the plain label too.
local function CharLabel(key, class)
    local name, realm = key:match("^(.-)%-(.+)$")
    if not name then return key, key end
    local _, myRealm = UnitFullName("player")
    local label = realm == (myRealm or GetNormalizedRealmName()) and name or key
    local color = class and C_ClassColor.GetClassColor(class)
    return label, color and color:WrapTextInColorCode(label) or label
end

-- When this character's first mail expires (server time), kept as the inbox changes.
local function RecordExpiry()
    local key, class = SelfKey()
    if not key then return end
    local _, soonest = Scan()
    local c = CfgW()
    c.expiry = c.expiry or {}
    c.expiry[key] = soonest and { at = GetServerTime() + math.floor(soonest * 86400), class = class } or nil
end

-- One chat line for the characters whose mail expires soon; what has run out
-- by now is forgotten.
local function RemindExpiry()
    local c = Cfg()
    if not c.expiry then return end
    local now, list = GetServerTime(), {}
    for key, rec in pairs(c.expiry) do
        local days = (rec.at - now) / 86400
        if days <= 0 then
            c.expiry[key] = nil
        elseif days < WARN_DAYS then
            local _, text = CharLabel(key, rec.class)
            list[#list + 1] = { days = days, text = text .. " (" .. DaysText(days) .. ")" }
        end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return a.days < b.days end)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = e.text end
    EUI.Print(PREFIX .. EllesmereUI.Lf("Mail expires soon on: %s.", table.concat(parts, ", ")))
end

-------------------------------------------------------------------------------
--  Events and live apply
-------------------------------------------------------------------------------
local function Watching() return mailOpen and On("alts") end

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Once per session, and not after a /reload.
        ev:UnregisterEvent("PLAYER_ENTERING_WORLD")
        local isLogin = ...
        if isLogin and On("alts") then C_Timer.After(5, RemindExpiry) end
    elseif event == "MAIL_SHOW" then
        mailOpen = true
        waitingInbox = On("warning") or nil
        if waitingInbox or Watching() then ev:RegisterEvent("MAIL_INBOX_UPDATE") end
    elseif event == "MAIL_INBOX_UPDATE" then
        if waitingInbox then
            waitingInbox = nil
            if On("warning") then WarnExpiry() end
        end
        if Watching() then
            RecordExpiry()
        else
            ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        end
    elseif event == "MAIL_CLOSED" then
        mailOpen, waitingInbox = nil, nil
        ev:UnregisterEvent("MAIL_INBOX_UPDATE")
    end
end)

-- Options entry point: takes effect at once, both ways.
local function Apply()
    mailOpen = (_G.MailFrame and MailFrame:IsShown()) or nil
    if On("warning") or On("alts") then
        ev:RegisterEvent("MAIL_SHOW")
        ev:RegisterEvent("MAIL_CLOSED")
        if Watching() then
            ev:RegisterEvent("MAIL_INBOX_UPDATE")
        elseif not waitingInbox then
            ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        end
    else
        ev:UnregisterEvent("MAIL_SHOW")
        ev:UnregisterEvent("MAIL_CLOSED")
        ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        waitingInbox = nil
    end
end
_G._EUI_ApplyMailExpiry = Apply

Apply()
-- The reminder waits for the login of this session, if the game is not in yet.
if On("alts") and not IsLoggedIn() then ev:RegisterEvent("PLAYER_ENTERING_WORLD") end
