if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBlizzardSkin_IgnorePanel.lua
--  The Account Ignore List (EllesmereUIQoL_AccountIgnore.lua) beside the
--  game's Ignore window (FriendsFrame.IgnoreListWindow, retail and WoW
--  Forever): every player on the account list, a header per realm when there
--  are several. The wheel scrolls it; a right click on a player removes them;
--  the + in the title adds one by name. Built only while the list is on.
--
--  Zero taint: the panel is a child of the Ignore window, so it shows and
--  hides with it, and no frame of ours under it carries an OnShow, OnHide or
--  OnSizeChanged script. It is repainted by our own list changes and by a
--  post-hook on IgnoreList_Update (the window's own refresh, returning at
--  once while the list is off). Nothing of Blizzard's is written.
--
--  The look follows the Friends List card (winKey "socialui"), latched at the
--  build: EllesmereUI and Modern draw the window theme, Blizz Default draws
--  Blizzard's DefaultPanelTemplate.
-------------------------------------------------------------------------------
local _, ns = ...
local WSkin = ns.WSkin
if not WSkin then return end
local EUI = EllesmereUI
local Theme = WSkin.Theme

local PANEL_W   = 180
local ROW_H     = 20
local LIST_PAD  = 4
local EMPTY_PAD = 10
local EUI_TOP, EUI_INSET, EUI_GAP       = 25, 1, 4
local BLIZZ_TOP, BLIZZ_INSET, BLIZZ_GAP = 21, 8, 6
local SHELL_ART = "Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png"

local panel, title, emptyNote, addBtn
local bgArt, bgShade, bgFlat
local rows = {}
local lines = {}          -- what the list shows: { header = realm } or an entry
local offset = 0          -- the first line shown
local blizzLook, topH, inset, gap
local hooked
local menuKey
local MENU

local function AI() return EUI._AccountIgnore end
local function On() local a = AI(); return a ~= nil and a.Enabled() end

-------------------------------------------------------------------------------
--  Rows
-------------------------------------------------------------------------------
local function RowEnter(self)
    if not self._key then return end
    EUI.ShowWidgetTooltip(self, self._key .. "\n" .. EUI.COLOR_CODES.DIM
        .. EllesmereUI.L("Right-click to remove from your account ignore list.") .. "|r",
        { anchor = "right", justify = "LEFT" })
end

local function RowLeave() EUI.HideWidgetTooltip() end

local function RowClick(self, button)
    if button ~= "RightButton" or not self._key then return end
    menuKey = self._key
    EUI.ShowContextMenu(self, MENU)
end

local function NewRow(i)
    local r = CreateFrame("Button", nil, panel)
    r:SetHeight(ROW_H)
    r:RegisterForClicks("RightButtonUp")
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    if blizzLook then
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetVertexColor(0.196, 0.388, 0.8)
    else
        hl:SetColorTexture(1, 1, 1, 0.08)
    end
    r._hl = hl
    local text = r:CreateFontString(nil, "OVERLAY", blizzLook and "GameFontHighlightSmall" or nil)
    if not blizzLook then WSkin.Font(text, nil, nil, nil, 12) end
    text:SetPoint("LEFT", r, "LEFT", 8, 0)
    text:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    r._text = text
    r:SetScript("OnClick", RowClick)
    r:SetScript("OnEnter", RowEnter)
    r:SetScript("OnLeave", RowLeave)
    local y = -(topH + LIST_PAD + (i - 1) * ROW_H)
    r:SetPoint("TOPLEFT", panel, "TOPLEFT", inset, y)
    r:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -inset, y)
    rows[i] = r
    return r
end

-------------------------------------------------------------------------------
--  Paint
-------------------------------------------------------------------------------
local function Capacity()
    local h = panel:GetHeight() or 0
    if h <= 0 then return 12 end
    return math.max(1, math.floor((h - topH - LIST_PAD * 2 - (blizzLook and 2 or 0)) / ROW_H))
end

local function Collect()
    wipe(lines)
    local entries = AI().Entries()
    local own = AI().OwnRealm()
    local several = false
    for _, e in ipairs(entries) do
        if e.realm ~= own then several = true break end
    end
    local last
    for _, e in ipairs(entries) do
        if several and e.realm ~= last then
            last = e.realm
            lines[#lines + 1] = { header = e.realm }
        end
        lines[#lines + 1] = e
    end
    return #entries
end

local function Paint()
    if not panel then return end
    if not On() then panel:Hide() return end
    panel:Show()
    local count = Collect()
    title:SetText(EllesmereUI.Lf("Account (%d)", count))
    local cap = Capacity()
    offset = math.max(0, math.min(offset, #lines - cap))
    local n = math.min(cap, #lines - offset)
    for i = 1, n do
        local line = lines[offset + i]
        local r = rows[i] or NewRow(i)
        if line.header then
            r._key = nil
            r._text:SetText(line.header)
            r._text:SetTextColor(0.6, 0.6, 0.6)
            r._hl:SetAlpha(0)
        else
            r._key = line.key
            r._text:SetText(line.name)
            r._text:SetTextColor(1, 1, 1)
            r._hl:SetAlpha(1)
        end
        r:Show()
    end
    for i = n + 1, #rows do
        rows[i]:Hide()
        rows[i]._key = nil
    end
    if count == 0 then
        emptyNote:SetText(EllesmereUI.L("Players you ignore on any character are listed here and blocked on all of them."))
        emptyNote:Show()
    else
        emptyNote:Hide()
    end
end

local function PaintBackdrop()
    if blizzLook or not panel then return end
    local modern = WSkin.GetStyle("socialui") == "modern"
    bgArt:SetAlpha(modern and 0 or 1)
    bgShade:SetAlpha(modern and 0 or 1)
    if modern then
        bgFlat:SetColorTexture(WSkin.GetModernBG())
    else
        bgFlat:SetColorTexture(0, 0, 0, 0)
    end
end

-------------------------------------------------------------------------------
--  The panel
-------------------------------------------------------------------------------
local function AddPlayer()
    EUI:ShowInputPopup({
        title = "Add Player",
        message = "Name, or Name-Realm for another realm.",
        maxLetters = 64,
        confirmText = "Add",
        onConfirm = function(text) AI().AddTyped(text) end,
    })
end

local function Build(win)
    if not Theme.fontPath then WSkin.ResolveTheme() end
    blizzLook = WSkin.GetStyle("socialui") == "off"
    if blizzLook then
        topH, inset, gap = BLIZZ_TOP, BLIZZ_INSET, BLIZZ_GAP
        panel = CreateFrame("Frame", "EllesmereUIAccountIgnoreList", win, "DefaultPanelTemplate")
        panel:SetTitleOffsets(6, -6)
        title = panel:GetTitleText()
    else
        topH, inset, gap = EUI_TOP, EUI_INSET, EUI_GAP
        panel = CreateFrame("Frame", "EllesmereUIAccountIgnoreList", win)
        bgArt = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
        bgArt:SetTexture(SHELL_ART)
        bgArt:SetAllPoints()
        bgShade = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
        bgShade:SetColorTexture(0, 0, 0, 0.62)
        bgShade:SetAllPoints()
        bgFlat = panel:CreateTexture(nil, "BACKGROUND", nil, -6)
        bgFlat:SetAllPoints()
        local band = panel:CreateTexture(nil, "BACKGROUND", nil, -5)
        band:SetColorTexture(0, 0, 0, 0.5)
        band:SetPoint("TOPLEFT")
        band:SetPoint("TOPRIGHT")
        band:SetHeight(topH)
        WSkin.AddBorder(panel)
        title = panel:CreateFontString(nil, "OVERLAY")
        WSkin.Font(title, 1, 1, 1, 12)
        title:SetPoint("CENTER", band, "CENTER", 0, 0)
        PaintBackdrop()
        WSkin.OnStylesChanged(PaintBackdrop)
    end
    panel:SetWidth(PANEL_W)
    -- As tall as the Ignore window, from anchors (no size script of ours).
    panel:SetPoint("TOPLEFT", win, "TOPRIGHT", gap, 0)
    panel:SetPoint("BOTTOMLEFT", win, "BOTTOMRIGHT", gap, 0)
    panel:EnableMouse(true)
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta * 3
        Paint()
    end)

    addBtn = CreateFrame("Button", nil, panel)
    addBtn:SetSize(16, 16)
    addBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -(inset + 6), -((topH - 16) / 2) - (blizzLook and 2 or 0))
    addBtn:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
    addBtn:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
    addBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    addBtn:SetScript("OnClick", AddPlayer)
    addBtn:SetScript("OnEnter", function(self)
        EUI.ShowWidgetTooltip(self, EllesmereUI.L("Add Player"), { anchor = "right" })
    end)
    addBtn:SetScript("OnLeave", RowLeave)

    emptyNote = panel:CreateFontString(nil, "OVERLAY", blizzLook and "GameFontDisableSmall" or nil)
    if not blizzLook then WSkin.Font(emptyNote, 0.6, 0.6, 0.6, 11) end
    emptyNote:SetWidth(PANEL_W - EMPTY_PAD * 2)
    emptyNote:SetPoint("TOP", panel, "TOP", 0, -(topH + EMPTY_PAD))
    emptyNote:SetJustifyH("CENTER")
    emptyNote:SetSpacing(2)
end

MENU = {
    { text = "Remove Player",
      tooltip = "Takes this player off your account ignore list, on every character.",
      onClick = function()
          if menuKey then AI().SetListed(menuKey, false) end
      end },
}

-------------------------------------------------------------------------------
--  Install
-------------------------------------------------------------------------------
local function Refresh()
    if not On() then
        if panel then panel:Hide() end
        return
    end
    local win = FriendsFrame and FriendsFrame.IgnoreListWindow
    if not win then return end
    if not panel then Build(win) end
    Paint()
    if not hooked and type(_G.IgnoreList_Update) == "function" then
        hooked = true
        hooksecurefunc("IgnoreList_Update", function()
            if panel and On() then Paint() end
        end)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    local a = AI()
    if not a then return end
    a.OnChange(Refresh)
    Refresh()
end)
