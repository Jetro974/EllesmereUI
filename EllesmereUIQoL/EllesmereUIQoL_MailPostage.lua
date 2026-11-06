if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_MailPostage.lua
--  Postage Warning, off by default (EllesmereUIDB.mailPostageWarn): a line
--  under the Send Mail window when what is attached sells to a vendor for
--  less than the postage, so the letter costs more than it carries.
--
--  Only a warning: nothing is blocked. Items with no vendor price (their worth
--  is unknown) and a cash on delivery mail are never judged.
--
--  Taint: nothing of Blizzard's is written; our own frame is anchored under
--  the Send Mail window and its OnShow / OnHide and the recipient box are only
--  hooked. While off no event is registered; on, MAIL_SHOW / MAIL_CLOSED
--  follow the mailbox and the send events are listened to only while it is
--  open.
-------------------------------------------------------------------------------
local EUI = EllesmereUI

local SEND_EVENTS = { "MAIL_SEND_INFO_UPDATE", "SEND_MAIL_MONEY_CHANGED",
    "SEND_MAIL_COD_CHANGED", "GET_ITEM_INFO_RECEIVED" }

local ev = CreateFrame("Frame")
local panel, label
local hooked

local function On()
    return EllesmereUIDB ~= nil and EllesmereUIDB.mailPostageWarn == true
end

local function Money(copper)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(copper)
    end
    return GetCoinTextureString(copper)
end

-- The warning text, or nil when there is nothing to say.
local function Evaluate()
    if not On() or not GetSendMailPrice then return nil end
    local price = GetSendMailPrice() or 0
    if price <= 0 then return nil end
    if (GetSendMailCOD and GetSendMailCOD() or 0) > 0 then return nil end

    local value, count = 0, 0
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do
        local _, itemID, _, n = GetSendMailItem(i)
        if itemID then
            count = count + 1
            local sell = select(11, C_Item.GetItemInfo(itemID))
            if not sell then
                C_Item.RequestLoadItemDataByID(itemID)
                return nil -- not loaded yet: GET_ITEM_INFO_RECEIVED comes back here
            end
            if sell <= 0 then return nil end -- no vendor price: no judgement
            value = value + sell * (n or 1)
        end
    end
    if count == 0 then return nil end
    value = value + (GetSendMailMoney and GetSendMailMoney() or 0)
    if value >= price then return nil end
    return EllesmereUI.Lf("These items sell for %s to a vendor, less than the postage (%s).",
        Money(value), Money(price))
end

local function Update()
    if not panel then return end
    local msg = Evaluate()
    if msg and SendMailFrame:IsShown() then
        label:SetText(msg)
        panel:Show()
    else
        panel:Hide()
    end
end

-- Our own frame, anchored under the Send Mail window.
local function Ensure()
    if panel or not _G.SendMailFrame then return end
    panel = CreateFrame("Frame", nil, UIParent)
    panel:SetSize(320, 40)
    panel:SetPoint("TOPLEFT", SendMailFrame, "BOTTOMLEFT", 16, 8)
    panel:SetFrameStrata("HIGH")
    label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetAllPoints()
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    label:SetTextColor(1, 0.7, 0.2)
    panel:Hide()
    SendMailFrame:HookScript("OnShow", Update)
    SendMailFrame:HookScript("OnHide", function() panel:Hide() end)
end

local function Watch(on)
    for _, e in ipairs(SEND_EVENTS) do
        if on then ev:RegisterEvent(e) else ev:UnregisterEvent(e) end
    end
end

ev:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SHOW" then
        Ensure()
        Watch(true)
        -- The recipient is typed with no event of its own.
        if not hooked and _G.SendMailNameEditBox then
            hooked = true
            SendMailNameEditBox:HookScript("OnTextChanged", Update)
        end
        Update()
    elseif event == "MAIL_CLOSED" then
        Watch(false)
        if panel then panel:Hide() end
    else
        Update()
    end
end)

-- Options entry point: takes effect at once, both ways.
local function Apply()
    if On() then
        ev:RegisterEvent("MAIL_SHOW")
        ev:RegisterEvent("MAIL_CLOSED")
        if _G.MailFrame and MailFrame:IsShown() then
            Ensure()
            Watch(true)
            Update()
        end
    else
        ev:UnregisterEvent("MAIL_SHOW")
        ev:UnregisterEvent("MAIL_CLOSED")
        Watch(false)
        if panel then panel:Hide() end
    end
end
_G._EUI_ApplyMailPostage = Apply

Apply()
