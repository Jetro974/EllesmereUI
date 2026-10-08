if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_Mailbox.lua
--  Mailbox helpers, each off by default:
--   - Collect Gold: a coin button right of Open All Mail. Its tooltip sums up
--     the inbox (gold, items, the soonest expiry); a click takes the gold of
--     every mail, one at a time as each take is answered. A cog option
--     collects it as soon as the mailbox opens.
--   - Expiry Warning: on opening the mailbox, one chat line for the mail with
--     gold or items that expires within WARN_DAYS.
--
--  Taint: TakeInboxMoney is not protected. The button is our own frame,
--  parented to the inbox; nothing of Blizzard's is hooked or written to.
--  While both are off no event is registered. MAIL_INBOX_UPDATE waits for the
--  inbox to load after an opening, and with MAIL_SUCCESS / MAIL_FAILED for
--  the answer to each take while gold is being collected.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local PREFIX = "|cff0cd29dEllesmereUI:|r "
local WARN_DAYS = 3
local COIN = "Interface\\MoneyFrame\\UI-GoldIcon"

local function Cfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.mailbox = EllesmereUIDB.mailbox or {}
    return EllesmereUIDB.mailbox
end
local function On(key) return Cfg()[key] == true end

local ev = CreateFrame("Frame")
local btn
local waitingInbox      -- the mailbox just opened: its first update runs the checks
local nextIndex         -- collecting: the next mail to look at (last to first), nil when idle
local taken, takenMails, lastMoney

-------------------------------------------------------------------------------
--  Inbox summary (the loaded mail)
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

-------------------------------------------------------------------------------
--  Collect Gold
-------------------------------------------------------------------------------
local function SyncButtonLook()
    if btn then btn:SetAlpha(nextIndex and 0.5 or 1) end
end

local function StopCollect()
    if not nextIndex then return end
    nextIndex, lastMoney = nil, nil
    ev:UnregisterEvent("MAIL_SUCCESS")
    ev:UnregisterEvent("MAIL_FAILED")
    if not waitingInbox then ev:UnregisterEvent("MAIL_INBOX_UPDATE") end
    SyncButtonLook()
    if takenMails > 0 then
        EUI.Print(PREFIX .. EllesmereUI.Lf("Collected %s from %d mail.", GetMoneyString(taken, true), takenMails))
    end
end

-- Takes the gold of the next mail that has some (COD and GM mail are left to
-- the player, as Open All Mail does), or stops once none is left.
local function CollectNext()
    while nextIndex and nextIndex >= 1 do
        local i = nextIndex
        nextIndex = i - 1
        local _, _, _, _, money, cod, _, _, _, _, _, _, isGM = GetInboxHeaderInfo(i)
        if money and money > 0 and (cod or 0) == 0 and not isGM then
            lastMoney = money
            taken, takenMails = taken + money, takenMails + 1
            TakeInboxMoney(i)
            return
        end
    end
    StopCollect()
end

-- Last to first, so a mail emptied and deleted never shifts the ones left.
local function StartCollect()
    local openAll = _G.OpenAllMail
    if nextIndex or (openAll and not openAll:IsEnabled()) then return end  -- Open All Mail is running
    nextIndex, taken, takenMails = GetInboxNumItems(), 0, 0
    -- A take answers with MAIL_SUCCESS or MAIL_FAILED, and the inbox updates.
    ev:RegisterEvent("MAIL_SUCCESS")
    ev:RegisterEvent("MAIL_FAILED")
    ev:RegisterEvent("MAIL_INBOX_UPDATE")
    SyncButtonLook()
    CollectNext()
end

local function ButtonOnEnter(self)
    local shown, total, gold, items, soonest = Summary()
    local lines = { EllesmereUI.L("Collect Gold"),
        EllesmereUI.Lf("Gold: %s", GetMoneyString(gold, true)),
        EllesmereUI.Lf("Items: %d", items) }
    if soonest then
        lines[#lines + 1] = EllesmereUI.Lf("Soonest expiry: %s", DaysText(soonest))
    end
    if total > shown then
        lines[#lines + 1] = EllesmereUI.Lf("%d more mail waits on the server.", total - shown)
    end
    lines[#lines + 1] = EllesmereUI.L("Click to take the gold of every mail (COD mail excluded).")
    EUI.ShowWidgetTooltip(self, table.concat(lines, "\n"))
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
        StartCollect()
    end)
end

-- Shown with Open All Mail (WoW Forever hides it in gamepad mode).
local function SyncButton()
    local openAll = _G.OpenAllMail
    local on = On("collectGold") and openAll ~= nil
    if on and not btn then BuildButton() end
    if btn then btn:SetShown(on and openAll:IsShown()) end
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
--  Events and live apply
-------------------------------------------------------------------------------
-- The answer to the last take: the next one goes once no mail command runs.
-- lastMoney is set while a take waits, so its later events are ignored.
local function OnTakeAnswered(failed)
    if not lastMoney or C_Mail.IsCommandPending() then return end
    if failed then taken, takenMails = taken - lastMoney, takenMails - 1 end
    lastMoney = nil
    CollectNext()
end

ev:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SUCCESS" or event == "MAIL_FAILED" then
        OnTakeAnswered(event == "MAIL_FAILED")
    elseif event == "MAIL_SHOW" then
        SyncButton()
        if On("expiryWarning") or (On("collectGold") and On("collectOnOpen")) then
            waitingInbox = true
            ev:RegisterEvent("MAIL_INBOX_UPDATE")
        end
    elseif event == "MAIL_INBOX_UPDATE" then
        if waitingInbox then
            waitingInbox = nil
            if not nextIndex then ev:UnregisterEvent("MAIL_INBOX_UPDATE") end
            if On("expiryWarning") then WarnExpiry() end
            if On("collectGold") and On("collectOnOpen") then StartCollect() end
        elseif nextIndex then
            OnTakeAnswered(false)
        else
            ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        end
    elseif event == "MAIL_CLOSED" then
        waitingInbox = nil
        ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        StopCollect()
    end
end)

-- Options entry point: takes effect at once, both ways.
local function Apply()
    if On("collectGold") or On("expiryWarning") then
        ev:RegisterEvent("MAIL_SHOW")
        ev:RegisterEvent("MAIL_CLOSED")
    else
        ev:UnregisterEvent("MAIL_SHOW")
        ev:UnregisterEvent("MAIL_CLOSED")
        ev:UnregisterEvent("MAIL_INBOX_UPDATE")
        waitingInbox = nil
        StopCollect()
    end
    if btn or (On("collectGold") and _G.MailFrame and MailFrame:IsShown()) then SyncButton() end
end
_G._EUI_ApplyMailbox = Apply

Apply()
