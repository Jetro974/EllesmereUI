if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_Mailbox.lua
--  Mailbox helpers, each off by default (EllesmereUIDB.mailbox):
--   - collect: a coin button right of Open All Mail. Hover for a summary of
--     the inbox; click for a menu that takes the gold, the items, both, the
--     auction mail or the selected mail, one take at a time as each is
--     answered. A click while it runs stops it. collectOnOpen (its cog) takes
--     the gold as soon as the mailbox opens.
--   - select: a checkbox on every inbox row; the menu then also opens or
--     returns the checked mail.
--   - addressBook: a button beside the To: field listing your alts and the
--     last recipients.
--   - fillSubject: a mail that sends only gold gets the amount as its subject.
--   - expiryWarning: on opening the mailbox, one chat line for the mail with
--     gold or items that expires within WARN_DAYS.
--   - expiryAlts: the mailbox remembers, for each character, when its first
--     mail expires; one chat line at login names the characters (this one
--     included) whose mail expires within WARN_DAYS.
--
--  Taint: the take and return calls are not protected. The button, the
--  checkboxes and the address book are our own frames, parented to Blizzard's;
--  the only hooks are hooksecurefunc on InboxFrame:Update, SendMail and
--  SendMailFrame_CanSend, installed once a feature needs them, and they do
--  nothing while it is off. The fill and the address book write text the
--  player asked for into the Send Mail boxes.
--  While every feature is off no event is registered. MAIL_INBOX_UPDATE waits
--  for the inbox after an opening (and, with expiryAlts, follows it while the
--  mailbox is open); MAIL_SUCCESS / MAIL_FAILED answer each command while a
--  job runs; MAIL_SEND_SUCCESS is listened to only while the mailbox is open
--  and the address book is on; PLAYER_ENTERING_WORLD is listened to once,
--  only with expiryAlts on.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local PREFIX = "|cff0cd29dEllesmereUI:|r "
local WARN_DAYS = 3
local RECENT_MAX = 10
local COIN = "Interface\\MoneyFrame\\UI-GoldIcon"

-- Reading never creates the table, so nothing is saved while every feature is off.
local EMPTY = {}
local function Cfg()
    local db = EllesmereUIDB
    return db and db.mailbox or EMPTY
end
local function CfgW()
    EllesmereUIDB.mailbox = EllesmereUIDB.mailbox or {}
    return EllesmereUIDB.mailbox
end
local function On(key) return Cfg()[key] == true end

local ev = CreateFrame("Frame")
local btn, bookBtn
local checks = {}       -- the checkbox of each inbox row
local inboxRows = {}    -- the inbox rows and their item buttons, looked up once
local selected = {}     -- inbox index -> true, for the checked mail
local selectedCount     -- the inbox size the selection belongs to
local hooked = {}
local waitingInbox      -- the mailbox just opened: its first update runs the checks
local job               -- the running take or return, nil when idle
local lastRecipient     -- the To: field of the mail being sent
local wired             -- the subject written by fillSubject
local mailOpen          -- the mailbox is open

-------------------------------------------------------------------------------
--  The mail
-------------------------------------------------------------------------------
-- Gold and items waiting, and the soonest expiry (days) of mail holding either.
local function Summary()
    local shown, total = GetInboxNumItems()
    local gold, items, soonest = 0, 0, nil
    for i = 1, shown do
        local _, _, _, _, money, cod, daysLeft, itemCount = GetInboxHeaderInfo(i)
        money, itemCount = money or 0, itemCount or 0
        if (cod or 0) == 0 then gold = gold + money end
        items = items + itemCount
        if (money > 0 or itemCount > 0) and daysLeft and (not soonest or daysLeft < soonest) then
            soonest = daysLeft
        end
    end
    return shown, total, gold, items, soonest
end

local function DaysText(days)
    return SecondsToTime(math.max(days, 0) * 86400, true)
end

-- COD and GM mail are left to the player, as Open All Mail does.
local function Takeable(i)
    local _, _, _, _, money, cod, _, itemCount, _, _, _, _, isGM = GetInboxHeaderInfo(i)
    return not isGM and (cod or 0) == 0, money or 0, itemCount or 0
end

local function CanReturn(i)
    local _, _, _, _, _, _, _, _, _, _, _, canReply, isGM = GetInboxHeaderInfo(i)
    return canReply and not isGM and not InboxItemCanDelete(i)
end

local FILTER = {
    gold = function(i)
        local ok, money = Takeable(i)
        return ok and money > 0
    end,
    items = function(i)
        local ok, _, items = Takeable(i)
        return ok and items > 0
    end,
    both = function(i)
        local ok, money, items = Takeable(i)
        return ok and (money > 0 or items > 0)
    end,
    -- Sales and purchases carry an invoice, whatever the language.
    auction = function(i)
        local ok, money, items = Takeable(i)
        return ok and (money > 0 or items > 0) and GetInboxInvoiceInfo(i) ~= nil
    end,
    selected = function(i)
        local ok, money, items = Takeable(i)
        return selected[i] and ok and (money > 0 or items > 0)
    end,
    returned = function(i) return selected[i] and CanReturn(i) end,
}

local function SelectedCount()
    local n = 0
    for i = 1, GetInboxNumItems() do
        if selected[i] then n = n + 1 end
    end
    return n
end

-------------------------------------------------------------------------------
--  The job: one command at a time, last mail to first, so a mail emptied and
--  deleted never shifts the ones left. What a mail holds is read once, when the
--  job reaches it: after its last take the index may already be the next mail.
--  Each command is answered by MAIL_SUCCESS, MAIL_FAILED or an inbox update,
--  and the next one goes once none is pending.
-------------------------------------------------------------------------------
local SyncChecks, Watching, RecordExpiry

local function SyncLook()
    if btn then btn:SetAlpha(job and 0.5 or 1) end
end

local function Finish()
    local j = job
    if not j then return end
    job = nil
    ev:UnregisterEvent("MAIL_SUCCESS")
    ev:UnregisterEvent("MAIL_FAILED")
    if not waitingInbox and not Watching() then ev:UnregisterEvent("MAIL_INBOX_UPDATE") end
    SyncLook()
    wipe(selected)
    SyncChecks()
    if mailOpen and On("expiryAlts") then RecordExpiry() end
    local mails = 0
    for _ in pairs(j.touched) do mails = mails + 1 end
    if j.mode == "return" then
        if mails > 0 then EUI.Print(PREFIX .. EllesmereUI.Lf("Returned %d mail.", mails)) end
        return
    end
    local parts = {}
    if j.gold > 0 then parts[#parts + 1] = GetMoneyString(j.gold, true) end
    if j.items > 0 then parts[#parts + 1] = EllesmereUI.Lf("%d items", j.items) end
    if #parts > 0 then
        EUI.Print(PREFIX .. EllesmereUI.Lf("Collected %s from %d mail.", table.concat(parts, ", "), mails))
    end
end

-- Sends the next command, or finishes once nothing is left.
local function Step()
    local j = job
    while j and j.pos <= #j.list do
        local i = j.list[j.pos]
        if j.mode == "return" then
            j.pos = j.pos + 1
            if CanReturn(i) then
                j.touched[i], j.waiting = true, true
                ReturnInboxItem(i)
                return
            end
        else
            if not j.slot then
                local _, _, _, _, money, _, _, itemCount = GetInboxHeaderInfo(i)
                j.slot = ATTACHMENTS_MAX
                j.money = j.mode ~= "items" and money or 0
                j.left = j.mode ~= "gold" and (itemCount or 0) or 0
            end
            if j.money > 0 then
                local money = j.money
                j.money = 0
                j.touched[i], j.waiting, j.pendingGold = true, true, money
                TakeInboxMoney(i)
                return
            end
            while j.left > 0 and j.slot >= 1 do
                local slot = j.slot
                j.slot = slot - 1
                if HasInboxItem(i, slot) then
                    j.left = j.left - 1
                    j.touched[i], j.waiting, j.pendingItem = true, true, true
                    TakeInboxItem(i, slot)
                    return
                end
            end
            j.pos, j.slot = j.pos + 1, nil
        end
    end
    Finish()
end

-- The answer to the last command: count it, then the next one goes. An answer
-- can come before the game has cleared the command: look once more a moment
-- later, and otherwise the next event carries on.
local function OnAnswered(failed, retried)
    local j = job
    if not (j and j.waiting) then return end
    if C_Mail.IsCommandPending() then
        if not retried and not j.retry then
            j.retry = true
            C_Timer.After(0.3, function()
                j.retry = nil
                if job == j then OnAnswered(failed, true) end
            end)
        end
        return
    end
    j.waiting = false
    if not failed then
        if j.pendingGold then j.gold = j.gold + j.pendingGold end
        if j.pendingItem then j.items = j.items + 1 end
    end
    j.pendingGold, j.pendingItem = nil, nil
    Step()
end

local function Start(filter, mode)
    local openAll = _G.OpenAllMail
    if job or C_Mail.IsCommandPending() or (openAll and not openAll:IsEnabled()) then return end  -- Open All Mail is running
    local list = {}
    for i = GetInboxNumItems(), 1, -1 do
        if filter(i) then list[#list + 1] = i end
    end
    if #list == 0 then
        EUI.Print(PREFIX .. EllesmereUI.L("Nothing to take."))
        return
    end
    job = { list = list, pos = 1, gold = 0, items = 0, touched = {}, mode = mode }
    ev:RegisterEvent("MAIL_SUCCESS")
    ev:RegisterEvent("MAIL_FAILED")
    ev:RegisterEvent("MAIL_INBOX_UPDATE")
    SyncLook()
    Step()
end

-------------------------------------------------------------------------------
--  Select: a checkbox on every inbox row
-------------------------------------------------------------------------------
local function BuildCheck(row)
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    cb:SetFrameLevel(row:GetFrameLevel() + 5)
    cb:SetScript("OnClick", function(self)
        if self.index then selected[self.index] = self:GetChecked() or nil end
    end)
    cb:SetScript("OnEnter", function(self)
        EUI.ShowWidgetTooltip(self, EllesmereUI.L("Select this mail. The coin button's menu then acts on the checked mail."))
    end)
    cb:SetScript("OnLeave", function() EUI.HideWidgetTooltip() end)
    return cb
end

function SyncChecks()
    local on = On("select")
    local size = GetInboxNumItems()
    -- A selection belongs to one inbox: mail taken or arriving moves the indexes.
    if selectedCount ~= size then
        wipe(selected)
        selectedCount = size
    end
    for i = 1, INBOXITEMS_TO_DISPLAY do
        local r = inboxRows[i]
        if not r then
            local row, button = _G["MailItem" .. i], _G["MailItem" .. i .. "Button"]
            if row and button then
                r = { row = row, button = button }
                inboxRows[i] = r
            end
        end
        local button = r and r.button
        local cb = checks[i]
        if on and button and button:IsShown() and button.index then
            if not cb then
                cb = BuildCheck(r.row)
                checks[i] = cb
            end
            cb.index = button.index
            cb:SetChecked(selected[button.index] == true)
            cb:Show()
        elseif cb then
            cb:Hide()
        end
    end
end

-------------------------------------------------------------------------------
--  The coin button and its menu
-------------------------------------------------------------------------------
local function ButtonOnEnter(self)
    local shown, total, gold, items, soonest = Summary()
    local lines = { EllesmereUI.L("Collect"),
        EllesmereUI.Lf("Gold: %s", GetMoneyString(gold, true)),
        EllesmereUI.Lf("Items: %d", items) }
    if soonest then
        lines[#lines + 1] = EllesmereUI.Lf("Soonest expiry: %s", DaysText(soonest))
    end
    if total > shown then
        lines[#lines + 1] = EllesmereUI.Lf("%d more mail waits on the server.", total - shown)
    end
    lines[#lines + 1] = job and EllesmereUI.L("Click to stop.")
        or EllesmereUI.L("Click for the collect menu (COD mail excluded).")
    EUI.ShowWidgetTooltip(self, table.concat(lines, "\n"))
end

local function ShowMenu()
    MenuUtil.CreateContextMenu(btn, function(_, root)
        root:CreateTitle(EllesmereUI.L("Collect"))
        root:CreateButton(EllesmereUI.L("Gold"), function() Start(FILTER.gold, "gold") end)
        root:CreateButton(EllesmereUI.L("Items"), function() Start(FILTER.items, "items") end)
        root:CreateButton(EllesmereUI.L("Gold and items"), function() Start(FILTER.both, "both") end)
        root:CreateButton(EllesmereUI.L("Auction mail"), function() Start(FILTER.auction, "both") end)
        if On("select") then
            local n = SelectedCount()
            root:CreateDivider()
            root:CreateButton(EllesmereUI.Lf("Open selected (%d)", n), function() Start(FILTER.selected, "both") end)
            root:CreateButton(EllesmereUI.Lf("Return selected (%d)", n), function() Start(FILTER.returned, "return") end)
            root:CreateButton(EllesmereUI.L("Select all"), function()
                for i = 1, GetInboxNumItems() do selected[i] = true end
                SyncChecks()
            end)
            root:CreateButton(EllesmereUI.L("Select none"), function()
                wipe(selected)
                SyncChecks()
            end)
        end
    end)
end

local function BuildButton()
    local openAll = _G.OpenAllMail
    btn = CreateFrame("Button", nil, InboxFrame)
    btn:SetSize(24, 24)
    btn:SetPoint("LEFT", openAll, "RIGHT", 6, 0)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(COIN)
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    btn:SetScript("OnEnter", ButtonOnEnter)
    btn:SetScript("OnLeave", function() EUI.HideWidgetTooltip() end)
    btn:SetScript("OnClick", function()
        EUI.HideWidgetTooltip()
        if job then
            Finish()
        else
            ShowMenu()
        end
    end)
end

-- Shown with Open All Mail (WoW Forever hides it in gamepad mode).
local function SyncButton()
    local openAll = _G.OpenAllMail
    local on = On("collect") and openAll ~= nil
    if on and not btn then BuildButton() end
    if btn then btn:SetShown(on and openAll:IsShown()) end
end

-------------------------------------------------------------------------------
--  Address book
-------------------------------------------------------------------------------
local function Recent()
    local c = CfgW()
    c.recent = c.recent or {}
    return c.recent
end

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

-- Your characters, as the mailbox has seen them.
local function RememberSelf()
    local key, class = SelfKey()
    if not key then return end
    local c = CfgW()
    c.alts = c.alts or {}
    c.alts[key] = class
end

local function AltList()
    local out = {}
    local me = SelfKey()
    for key, class in pairs(Cfg().alts or {}) do
        if key ~= me then
            local label, text = CharLabel(key, class)
            out[#out + 1] = { name = label, text = text }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function PickName(name)
    SendMailNameEditBox:SetText(name)
    SendMailSubjectEditBox:SetFocus()
end

local function ShowBook()
    MenuUtil.CreateContextMenu(bookBtn, function(_, root)
        local alts, recent = AltList(), Recent()
        if #alts > 0 then
            root:CreateTitle(EllesmereUI.L("Alts"))
            for _, a in ipairs(alts) do
                root:CreateButton(a.text, function() PickName(a.name) end)
            end
        end
        if #recent > 0 then
            root:CreateTitle(EllesmereUI.L("Recent"))
            for _, name in ipairs(recent) do
                root:CreateButton(name, function() PickName(name) end)
            end
            root:CreateDivider()
            root:CreateButton(EllesmereUI.L("Clear Recent"), function() wipe(Recent()) end)
        end
        if #alts == 0 and #recent == 0 then
            root:CreateTitle(EllesmereUI.L("Nobody yet. Your alts show up once the mailbox has been opened on them."))
        end
    end)
end

local function BuildBook()
    bookBtn = CreateFrame("Button", nil, SendMailFrame)
    bookBtn:SetSize(22, 22)
    bookBtn:SetPoint("LEFT", SendMailNameEditBox, "RIGHT", 6, 0)
    bookBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    bookBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
    bookBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    bookBtn:SetScript("OnClick", ShowBook)
    bookBtn:SetScript("OnEnter", function(self)
        EUI.ShowWidgetTooltip(self, EllesmereUI.L("Address Book"))
    end)
    bookBtn:SetScript("OnLeave", function() EUI.HideWidgetTooltip() end)
end

local function SyncBook()
    local on = On("addressBook") and _G.SendMailNameEditBox ~= nil
    if on and not bookBtn then BuildBook() end
    if bookBtn then bookBtn:SetShown(on) end
end

-- The recipient of a sent mail goes to the top of the recent list.
local function RememberRecipient(name)
    name = strtrim(name or "")
    if name == "" then return end
    local list = Recent()
    for i = #list, 1, -1 do
        if list[i]:lower() == name:lower() then table.remove(list, i) end
    end
    table.insert(list, 1, name)
    while #list > RECENT_MAX do table.remove(list) end
end

-------------------------------------------------------------------------------
--  Fill the subject of a mail that sends only gold
-------------------------------------------------------------------------------
local function CoinText(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

local filling
local function FillSubject()
    if filling or not On("fillSubject") then return end
    filling = true
    local box = SendMailSubjectEditBox
    local text = box:GetText()
    local copper = SendMailSendMoneyButton:GetChecked() and MoneyInputFrame_GetCopper(SendMailMoney) or 0
    local hasItem = false
    for i = 1, ATTACHMENTS_MAX_SEND do
        if HasSendMailItem(i) then
            hasItem = true
            break
        end
    end
    local want = (copper > 0 and not hasItem) and CoinText(copper) or nil
    if text == "" then
        if want then
            wired = want
            box:SetText(want)
        end
    elseif wired and text == wired then
        -- Still our line: it follows the amount, and goes with it.
        if want ~= wired then
            wired = want
            box:SetText(want or "")
        end
    else
        wired = nil
    end
    filling = nil
end

-------------------------------------------------------------------------------
--  Expiry Warning
-------------------------------------------------------------------------------
local function WarnExpiry()
    local count, soonest = 0, nil
    local shown = GetInboxNumItems()
    for i = 1, shown do
        local _, _, _, _, money, _, daysLeft, itemCount = GetInboxHeaderInfo(i)
        if ((money or 0) > 0 or (itemCount or 0) > 0) and daysLeft and daysLeft < WARN_DAYS then
            count = count + 1
            if not soonest or daysLeft < soonest then soonest = daysLeft end
        end
    end
    if count > 0 then
        EUI.Print(PREFIX .. EllesmereUI.Lf("%d mail with gold or items expires within %d days (soonest: %s).",
            count, WARN_DAYS, DaysText(soonest)))
    end
end

-------------------------------------------------------------------------------
--  Mail expiry of every character
-------------------------------------------------------------------------------
-- When this character's first mail expires (server time), kept as the inbox changes.
function RecordExpiry()
    local key, class = SelfKey()
    if not key then return end
    local soonest
    for i = 1, (GetInboxNumItems()) do
        local _, _, _, _, money, _, daysLeft, itemCount = GetInboxHeaderInfo(i)
        if ((money or 0) > 0 or (itemCount or 0) > 0) and daysLeft and (not soonest or daysLeft < soonest) then
            soonest = daysLeft
        end
    end
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
            local label, text = CharLabel(key, rec.class)
            list[#list + 1] = { days = days, name = label, text = text .. " (" .. DaysText(days) .. ")" }
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
local function AnyOn()
    return On("collect") or On("select") or On("addressBook") or On("fillSubject")
        or On("expiryWarning") or On("expiryAlts")
end

-- The inbox is followed while it is open only to keep the expiry memory right.
function Watching() return mailOpen and On("expiryAlts") end

-- Hooks go in once a feature needs them; their bodies check the setting.
local function InstallHooks()
    if On("select") and not hooked.inbox and _G.InboxFrame then
        hooked.inbox = true
        hooksecurefunc(InboxFrame, "Update", function()
            if On("select") then SyncChecks() end
        end)
    end
    if On("addressBook") and not hooked.send and _G.SendMail then
        hooked.send = true
        hooksecurefunc("SendMail", function(recipient)
            if On("addressBook") then lastRecipient = recipient end
        end)
    end
    if On("fillSubject") and not hooked.fill and _G.SendMailFrame_CanSend then
        hooked.fill = true
        hooksecurefunc("SendMailFrame_CanSend", FillSubject)
    end
end

local function SyncAll()
    InstallHooks()
    SyncButton()
    SyncChecks()
    SyncBook()
end

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "MAIL_SUCCESS" or event == "MAIL_FAILED" then
        OnAnswered(event == "MAIL_FAILED")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Once per session, and not after a /reload.
        ev:UnregisterEvent("PLAYER_ENTERING_WORLD")
        local isLogin = ...
        if isLogin and On("expiryAlts") then C_Timer.After(5, RemindExpiry) end
    elseif event == "MAIL_SHOW" then
        mailOpen = true
        if Watching() then ev:RegisterEvent("MAIL_INBOX_UPDATE") end
        if On("addressBook") then
            RememberSelf()
            ev:RegisterEvent("MAIL_SEND_SUCCESS")
        end
        SyncAll()
        if On("expiryWarning") or (On("collect") and On("collectOnOpen")) then
            waitingInbox = true
            ev:RegisterEvent("MAIL_INBOX_UPDATE")
        end
    elseif event == "MAIL_SEND_SUCCESS" then
        if On("addressBook") then RememberRecipient(lastRecipient) end
        lastRecipient = nil
    elseif event == "MAIL_INBOX_UPDATE" then
        if waitingInbox then
            waitingInbox = nil
            if not job and not Watching() then ev:UnregisterEvent("MAIL_INBOX_UPDATE") end
            if On("expiryWarning") then WarnExpiry() end
            if On("collect") and On("collectOnOpen") then Start(FILTER.gold, "gold") end
        elseif job then
            OnAnswered(false)
        elseif not Watching() then
            ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        end
        if On("expiryAlts") and not job then RecordExpiry() end
    elseif event == "MAIL_CLOSED" then
        mailOpen = nil
        waitingInbox = nil
        ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        ev:UnregisterEvent("MAIL_SEND_SUCCESS")
        Finish()
        wipe(selected)
    end
end)

-- Options entry point: takes effect at once, both ways.
local function Apply()
    mailOpen = (_G.MailFrame and MailFrame:IsShown()) or nil
    if AnyOn() then
        ev:RegisterEvent("MAIL_SHOW")
        ev:RegisterEvent("MAIL_CLOSED")
        if Watching() then ev:RegisterEvent("MAIL_INBOX_UPDATE") end
    else
        ev:UnregisterEvent("MAIL_SHOW")
        ev:UnregisterEvent("MAIL_CLOSED")
        ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        ev:UnregisterEvent("MAIL_SEND_SUCCESS")
        waitingInbox = nil
        Finish()
    end
    if _G.MailFrame and MailFrame:IsShown() then
        if On("addressBook") then
            ev:RegisterEvent("MAIL_SEND_SUCCESS")
        else
            ev:UnregisterEvent("MAIL_SEND_SUCCESS")
        end
        SyncAll()
    elseif btn or bookBtn or next(checks) then
        SyncButton()
        SyncChecks()
        SyncBook()
    end
end
_G._EUI_ApplyMailbox = Apply

Apply()
-- The reminder waits for the login of this session, if the game is not in yet.
if On("expiryAlts") and not IsLoggedIn() then ev:RegisterEvent("PLAYER_ENTERING_WORLD") end
