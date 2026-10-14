if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Training.lua  (WoW Forever only)
--  Training Planner: a panel beside the spellbook listing what the class
--  trainer still has to teach, by level, from the trainer data
--  (TrainerData.lua): what can be trained now (green) and what comes next,
--  with each ability's cost. Costs are not in the client's data: each visit
--  to a class trainer records them for the account, under the visitor's
--  class.
--
--  The panel is a frame of our own anchored to the spellbook's side; the
--  spellbook's OnShow/OnHide (HookScript) show and hide it. Nothing of
--  Blizzard's is written.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.trainingPlanner; unset keys read these.
-- costs: classFile = { "Name|Rank" = copper }
local F = module.Feature("trainingPlanner", { enabled = false })

local PANEL_W = 290
local PAD = 12
local ICON = 20
local ROW_H = 24
local HEADER_H = 26
local TOP = 62         -- the title and summary above the list

local events, waiter, hooked, panel
local rows, headers = {}, {}

local function Key(name, rank)
    return rank and (name .. "|" .. rank) or name
end

local function Rank(spellID)
    local rank = C_Spell.GetSpellSubtext(spellID)
    if rank ~= "" then return rank end
end

local function Coins(copper)
    return copper and copper > 0 and C_CurrencyInfo.GetCoinTextureString(copper) or ""
end

-- What the player's trainer asks for spellID; nil until a visit recorded it.
local function Cost(spellID)
    local _, class = UnitClass("player")
    local all = F.Get("costs")
    local costs = all and all[class]
    local name = costs and C_Spell.GetSpellName(spellID)
    if name then return costs[Key(name, Rank(spellID))] end
end

-- A class trainer's costs (professions and pet trainers left out).
local function Capture()
    if IsTradeskillTrainer() or C_Trainer.GetTrainerType() ~= Enum.TrainerType.General then return end
    local cfg = F.Cfg()
    local _, class = UnitClass("player")
    cfg.costs = cfg.costs or {}
    local costs = cfg.costs[class] or {}
    cfg.costs[class] = costs
    for i = 1, GetNumTrainerServices() do
        local name, _, _, _, rank = GetTrainerServiceInfo(i)
        if name and name ~= "" then
            if rank == "" then rank = nil end
            costs[Key(name, rank)] = GetTrainerServiceCost(i) or 0
        end
    end
end

-- The abilities the player has not trained yet, by level then name.
local function Upcoming()
    local out = {}
    local _, class = UnitClass("player")
    for level, spells in pairs(module.TrainerSpells(class)) do
        for i = 1, #spells do
            local id = spells[i]
            local name = not IsPlayerSpell(id) and C_Spell.GetSpellName(id)
            if name then
                out[#out + 1] = { spellID = id, name = name, rank = Rank(id), level = level,
                    icon = C_Spell.GetSpellTexture(id), cost = Cost(id) }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        if a.name ~= b.name then return a.name < b.name end
        return (a.rank or "") < (b.rank or "")
    end)
    return out
end

-------------------------------------------------------------------------------
--  The panel
-------------------------------------------------------------------------------
local function Font(fs, size)
    EllesmereUI.ApplyModuleFont(fs, nil, size, "essentials")
end

local function Accent()
    local c = EllesmereUI.ELLESMERE_GREEN
    if c then return c.r, c.g, c.b end
    return 0.05, 0.82, 0.62
end

-- A row's tooltip: the spell's own, with its cost when recorded.
local function RowEnter(row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetSpellByID(row.spellID)
    if row.cost and row.cost > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(COSTS_LABEL .. " " .. Coins(row.cost), 1, 1, 1)
    end
    GameTooltip:Show()
end

local function RowLeave(row)
    if GameTooltip:IsOwned(row) then GameTooltip:Hide() end
end

local function Row(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, panel.content)
    row:SetHeight(ROW_H)
    row:EnableMouseMotion(true)
    row:SetScript("OnEnter", RowEnter)
    row:SetScript("OnLeave", RowLeave)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON, ICON)
    row.icon:SetPoint("LEFT")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.cost = row:CreateFontString(nil, "OVERLAY")
    Font(row.cost, 11)
    row.cost:SetPoint("RIGHT")
    row.name = row:CreateFontString(nil, "OVERLAY")
    Font(row.name, 12)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row.cost, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    rows[i] = row
    return row
end

local function Header(i)
    local fs = headers[i]
    if fs then return fs end
    fs = panel.content:CreateFontString(nil, "OVERLAY")
    Font(fs, 12)
    fs:SetTextColor(1, 0.82, 0)
    headers[i] = fs
    return fs
end

local function Refresh()
    if not (panel and panel:IsShown()) then return end
    local list = Upcoming()
    local playerLevel = UnitLevel("player")
    local count, total = 0, 0
    for _, e in ipairs(list) do
        if e.level <= playerLevel then
            count = count + 1
            total = total + (e.cost or 0)
        end
    end
    panel.summary:SetText(count > 0 and EllesmereUI.Lf("Trainable now: %d (%s)", count, Coins(total))
        or EllesmereUI.L("Nothing to train at your level."))

    local y, nRows, nHeaders, i = 0, 0, 0, 1
    while list[i] do
        local level, sum, j = list[i].level, 0, i
        while list[j] and list[j].level == level do
            sum = sum + (list[j].cost or 0)
            j = j + 1
        end
        nHeaders = nHeaders + 1
        local h = Header(nHeaders)
        h:ClearAllPoints()
        h:SetPoint("BOTTOMLEFT", panel.content, "TOPLEFT", 0, -(y + HEADER_H - 6))
        h:SetText(EllesmereUI.Lf("Level %d", level) .. (sum > 0 and ("   |cffffffff" .. Coins(sum) .. "|r") or ""))
        h:Show()
        y = y + HEADER_H
        for k = i, j - 1 do
            local e = list[k]
            nRows = nRows + 1
            local row = Row(nRows)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", panel.content, "RIGHT")
            row.spellID, row.cost = e.spellID, e.cost
            row.icon:SetTexture(e.icon)
            row.name:SetText(e.rank and (e.name .. " |cffaaaaaa(" .. e.rank .. ")|r") or e.name)
            if e.level <= playerLevel then
                row.name:SetTextColor(0.25, 1, 0.25)
            else
                row.name:SetTextColor(1, 1, 1)
            end
            row.cost:SetText(Coins(e.cost))
            row:Show()
            y = y + ROW_H
        end
        i = j
    end
    for k = nRows + 1, #rows do rows[k]:Hide() end
    for k = nHeaders + 1, #headers do headers[k]:Hide() end
    panel.content:SetHeight(math.max(1, y))
    local scroll = panel.scroll
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), math.max(0, y - scroll:GetHeight())))
end

local function OnScroll(scroll, delta)
    local max = math.max(0, panel.content:GetHeight() - scroll:GetHeight())
    scroll:SetVerticalScroll(math.min(max, math.max(0, scroll:GetVerticalScroll() - delta * ROW_H * 3)))
end

local function Build()
    local book = PlayerSpellsFrame
    panel = CreateFrame("Frame", nil, UIParent)
    panel:SetFrameStrata(book:GetFrameStrata())
    panel:SetWidth(PANEL_W)
    panel:SetPoint("TOPLEFT", book, "TOPRIGHT", 4, 0)
    panel:SetPoint("BOTTOMLEFT", book, "BOTTOMRIGHT", 4, 0)
    panel:EnableMouse(true)
    panel:Hide()
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.94)
    EllesmereUI.PP.CreateBorder(panel, 0, 0, 0, 1, 1, "OVERLAY", 1)
    local r, g, b = Accent()
    local rule = panel:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT")
    rule:SetPoint("TOPRIGHT")
    rule:SetHeight(2)
    rule:SetColorTexture(r, g, b, 1)

    local title = panel:CreateFontString(nil, "OVERLAY")
    Font(title, 15)
    title:SetTextColor(r, g, b)
    title:SetPoint("TOPLEFT", PAD, -PAD)
    title:SetText(EllesmereUI.L("Training Planner"))
    panel.summary = panel:CreateFontString(nil, "OVERLAY")
    Font(panel.summary, 12)
    panel.summary:SetTextColor(1, 1, 1, 0.8)
    panel.summary:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    panel.summary:SetPoint("RIGHT", -PAD, 0)
    panel.summary:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", PAD, -TOP)
    scroll:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", OnScroll)
    panel.content = CreateFrame("Frame", nil, scroll)
    panel.content:SetSize(PANEL_W - PAD * 2, 1)
    scroll:SetScrollChild(panel.content)
    panel.scroll = scroll

    -- Learning or levelling while it is open updates it.
    panel:SetScript("OnShow", function(self)
        self:RegisterEvent("SPELLS_CHANGED")
        self:RegisterEvent("PLAYER_LEVEL_UP")
        Refresh()
    end)
    panel:SetScript("OnHide", function(self)
        self:UnregisterAllEvents()
    end)
    panel:SetScript("OnEvent", Refresh)
end

local function ShowPanel()
    if not F.Enabled() then return end
    if not panel then Build() end
    panel:Show()
end

local function HidePanel()
    if panel then panel:Hide() end
end

local function Hook()
    hooked = true
    local book = PlayerSpellsFrame.SpellBookFrame
    book:HookScript("OnShow", ShowPanel)
    book:HookScript("OnHide", HidePanel)
    if book:IsVisible() then ShowPanel() end
end

-------------------------------------------------------------------------------
--  Apply
-------------------------------------------------------------------------------
-- Off: no events, the panel hidden and the hooks returning at once. The
-- spellbook loads on demand, so hooking it may wait.
local function Apply()
    if not F.Enabled() then
        if events then events:UnregisterAllEvents() end
        if waiter then waiter:UnregisterAllEvents() end
        HidePanel()
        return
    end
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", function()
            Capture()
            Refresh()
        end)
    end
    events:RegisterEvent("TRAINER_SHOW")
    events:RegisterEvent("TRAINER_UPDATE")
    events:RegisterEvent("TRAINER_SERVICE_INFO_NAME_UPDATE")
    if hooked then
        if PlayerSpellsFrame.SpellBookFrame:IsVisible() then ShowPanel() end
        return
    end
    if C_AddOns.IsAddOnLoaded("Blizzard_PlayerSpells") then Hook() return end
    if not waiter then
        waiter = CreateFrame("Frame")
        waiter:SetScript("OnEvent", function(self, _, name)
            if name ~= "Blizzard_PlayerSpells" then return end
            self:UnregisterAllEvents()
            Hook()
        end)
    end
    waiter:RegisterEvent("ADDON_LOADED")
end

-- Options-page and Level Up Toast entry points.
EllesmereUI._TrainingPlanner = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
    Cost = Cost,
}

F.Start(Apply)
