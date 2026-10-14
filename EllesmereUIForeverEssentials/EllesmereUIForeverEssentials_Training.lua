if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Training.lua  (WoW Forever only)
--  Training Planner: a panel beside the spellbook listing what a class
--  trainer teaches from level 1 to the last, from the trainer data
--  (TrainerData.lua), with each ability's cost. The player's class shows
--  what is trained (grey), what can be trained now (green) and what comes
--  next; a class picker shows any other class. Weapon skills come first,
--  with the cities whose weapon master teaches them; a click on one writes
--  its weapon masters' map links to the chat. Costs are not in the client's
--  data: each visit to a class trainer or weapon master records them for the
--  account, under the visitor's class and by spell, along with whatever it
--  teaches that the trainer data lacks.
--
--  The panel is a frame of our own anchored to the spellbook's side; the
--  spellbook's OnShow/OnHide (HookScript) show and hide it. Nothing of
--  Blizzard's is written.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.trainingPlanner; unset keys read these.
-- prices: classFile = { [spellID] = copper }
-- unlisted: classFile = { [spellID] = level }, taught but not in the data
local F = module.Feature("trainingPlanner", { enabled = false })

local PANEL_W = 290
local PAD = 12
local ICON = 20
local ROW_H = 24
local HEADER_H = 26
local TOP = 62         -- the title and summary above the list

local events, waiter, hooked, panel, shownClass, reloading
local rows, headers = {}, {}

local function PlayerClass()
    local _, class = UnitClass("player")
    return class
end

local function Rank(spellID)
    local rank = C_Spell.GetSpellSubtext(spellID)
    if rank ~= "" then return rank end
end

local function Coins(copper)
    return copper and copper > 0 and C_CurrencyInfo.GetCoinTextureString(copper) or ""
end

-- What class's trainer asks for spellID (the player's class by default);
-- nil until a visit recorded it.
local function Cost(spellID, class)
    local all = F.Get("prices")
    local prices = all and all[class or PlayerClass()]
    return prices and prices[spellID]
end

local function Sub(t, key)
    t[key] = t[key] or {}
    return t[key]
end

-- A class trainer's or weapon master's list (professions and pet trainers
-- left out): each service's cost under its spell, read from the service's
-- own tooltip data, and what the trainer data lacks.
local function Capture()
    if IsTradeskillTrainer() or C_Trainer.GetTrainerType() ~= Enum.TrainerType.General then return end
    local class = PlayerClass()
    local listed = {}
    for _, spells in pairs(module.TrainerSpells(class)) do
        for i = 1, #spells do listed[spells[i]] = true end
    end
    for _, w in ipairs(module.WeaponSkills(class)) do listed[w.spellID] = true end
    local cfg = F.Cfg()
    local prices = Sub(Sub(cfg, "prices"), class)
    local unlisted = Sub(Sub(cfg, "unlisted"), class)
    for i = 1, GetNumTrainerServices() do
        local _, kind, _, level = GetTrainerServiceInfo(i)
        local info = kind ~= "header" and C_TooltipInfo.GetTrainerService(i)
        local id = info and info.id
        if id then
            prices[id] = GetTrainerServiceCost(i) or 0
            if not listed[id] then unlisted[id] = level or 0 end
        end
    end
end

-- class's abilities by level then name; known is set for the player's own
-- class. A spell whose data the client has not loaded yet is asked for and
-- left out; missing tells the caller to look again once it comes.
local function List(class)
    local out, missing = {}, false
    local own = class == PlayerClass()
    for level, spells in pairs(module.TrainerSpells(class)) do
        for i = 1, #spells do
            local id = spells[i]
            local name = C_Spell.GetSpellName(id)
            if name then
                out[#out + 1] = { spellID = id, name = name, rank = Rank(id), level = level,
                    icon = C_Spell.GetSpellTexture(id), cost = Cost(id, class),
                    known = own and IsPlayerSpell(id) or nil }
            else
                C_Spell.RequestLoadSpellData(id)
                missing = true
            end
        end
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        if a.name ~= b.name then return a.name < b.name end
        return (a.rank or "") < (b.rank or "")
    end)
    return out, missing
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

local function CityName(map)
    local info = C_Map.GetMapInfo(map)
    return info and info.name or ""
end

-- A weapon skill's masters of the player's faction as map links in chat,
-- the link /way prints (x, y travel as 0..10000). A line printed in combat
-- taints chat history, so it waits for the end of combat.
local function PrintMasters(masters)
    local CC = EllesmereUI.COLOR_CODES
    local faction = UnitFactionGroup("player")
    for _, m in ipairs(masters) do
        if m.faction == faction then
            local link = ("|cffffff00|Hworldmap:%d:%d:%d|h[%s]|h|r"):format(m.map,
                math.floor(m.x * 100 + 0.5), math.floor(m.y * 100 + 0.5), MAP_PIN_HYPERLINK)
            EllesmereUI.Print(CC.BRAND .. "EllesmereUI:|r " .. link .. " " .. CC.WHITE .. EllesmereUI.L(m.name)
                .. "|r " .. CC.DIM .. CityName(m.map) .. ("  %.1f, %.1f"):format(m.x, m.y) .. "|r")
        end
    end
end

local function RowClick(row, button)
    if button ~= "LeftButton" or not row.masters then return end
    local masters = row.masters
    if InCombatLockdown() then
        EllesmereUI.CombatQueue.Defer("TrainingPlannerLink", function() PrintMasters(masters) end)
    else
        PrintMasters(masters)
    end
end

-- A row's tooltip: the spell's own, with its cost when recorded, or for a
-- weapon skill the weapon masters of both factions.
local function RowEnter(row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetSpellByID(row.spellID)
    if row.copper and row.copper > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(COSTS_LABEL .. " " .. Coins(row.copper), 1, 1, 1)
    end
    if row.masters then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(EllesmereUI.L("Weapon Masters"), 1, 0.82, 0)
        for _, faction in ipairs({ "Alliance", "Horde" }) do
            for _, m in ipairs(row.masters) do
                if m.faction == faction then
                    GameTooltip:AddDoubleLine(EllesmereUI.L(m.name), CityName(m.map) .. " (" .. _G["FACTION_" .. faction:upper()] .. ")",
                        1, 1, 1, 0.7, 0.7, 0.7)
                end
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(EllesmereUI.L("Click for your faction's weapon masters on the map."), 0.6, 0.6, 0.6)
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
    row:SetScript("OnMouseUp", RowClick)
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

local function ClassName(class)
    local name = LOCALIZED_CLASS_NAMES_MALE[class] or class
    local c = C_ClassColor.GetClassColor(class)
    return c and c:WrapTextInColorCode(name) or name
end

local function Refresh()
    if not (panel and panel:IsShown()) then return end
    shownClass = shownClass or PlayerClass()
    panel.class.text:SetText(ClassName(shownClass))
    panel.class:SetWidth(panel.class.text:GetStringWidth() + 18)
    local list, missing = List(shownClass)
    panel.missing = missing
    local playerLevel = UnitLevel("player")
    local own = shownClass == PlayerClass()
    local count, total = 0, 0
    for _, e in ipairs(list) do
        if own and not e.known and e.level <= playerLevel then
            count = count + 1
            total = total + (e.cost or 0)
        end
    end
    if not own then
        panel.summary:SetText("")
    elseif count > 0 then
        panel.summary:SetText(EllesmereUI.Lf("Trainable now: %d (%s)", count, Coins(total)))
    else
        panel.summary:SetText(EllesmereUI.L("Nothing to train at your level."))
    end

    local y, nRows, nHeaders, i = 0, 0, 0, 1
    local function PlaceHeader(text)
        nHeaders = nHeaders + 1
        local h = Header(nHeaders)
        h:ClearAllPoints()
        h:SetPoint("BOTTOMLEFT", panel.content, "TOPLEFT", 0, -(y + HEADER_H - 6))
        h:SetText(text)
        h:Show()
        y = y + HEADER_H
    end
    local function PlaceRow(e, color, right, masters)
        nRows = nRows + 1
        local row = Row(nRows)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", panel.content, "RIGHT")
        row.spellID, row.copper, row.masters = e.spellID, not e.known and e.cost or nil, masters
        row:SetMouseClickEnabled(masters ~= nil)
        row.icon:SetTexture(e.icon)
        row.icon:SetDesaturated(e.known or false)
        row.name:SetText(e.rank and (e.name .. " |cffaaaaaa(" .. e.rank .. ")|r") or e.name)
        row.name:SetTextColor(color[1], color[2], color[3])
        row.cost:SetText(right)
        row:Show()
        y = y + ROW_H
    end
    local GREY, GREEN, WHITE = { 0.5, 0.5, 0.5 }, { 0.25, 1, 0.25 }, { 1, 1, 1 }

    -- Weapon skills, with the cities of the player's faction that teach them.
    local weapons = module.WeaponSkills(shownClass)
    if #weapons > 0 then
        PlaceHeader(EllesmereUI.L("Weapon Skills"))
        local faction = UnitFactionGroup("player")
        for _, w in ipairs(weapons) do
            local name = C_Spell.GetSpellName(w.spellID)
            if name then
                local cities, seen = {}, {}
                for _, m in ipairs(w.masters) do
                    if m.faction == faction and not seen[m.map] then
                        seen[m.map] = true
                        cities[#cities + 1] = CityName(m.map)
                    end
                end
                local known = own and IsPlayerSpell(w.spellID)
                PlaceRow({ spellID = w.spellID, name = name, icon = C_Spell.GetSpellTexture(w.spellID), known = known,
                    cost = Cost(w.spellID, shownClass) },
                    known and GREY or WHITE, known and "" or "|cffaaaaaa" .. table.concat(cities, ", ") .. "|r", w.masters)
            else
                C_Spell.RequestLoadSpellData(w.spellID)
                panel.missing = true
            end
        end
    end

    while list[i] do
        local level, sum, j = list[i].level, 0, i
        while list[j] and list[j].level == level do
            if not list[j].known then sum = sum + (list[j].cost or 0) end
            j = j + 1
        end
        PlaceHeader(EllesmereUI.Lf("Level %d", level) .. (sum > 0 and ("   |cffffffff" .. Coins(sum) .. "|r") or ""))
        for k = i, j - 1 do
            local e = list[k]
            local color = e.known and GREY or (own and e.level <= playerLevel) and GREEN or WHITE
            PlaceRow(e, color, e.known and "" or Coins(e.cost))
        end
        i = j
    end
    for k = nRows + 1, #rows do rows[k]:Hide() end
    for k = nHeaders + 1, #headers do headers[k]:Hide() end
    panel.content:SetHeight(math.max(1, y))
    local scroll = panel.scroll
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), math.max(0, y - scroll:GetHeight())))
end

-- Spell data asked for comes one spell at a time: one look again for the lot.
local function OnSpellData()
    if reloading or not panel.missing then return end
    reloading = true
    C_Timer.After(0.2, function()
        reloading = false
        Refresh()
    end)
end

local function ClassMenu(button)
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle(EllesmereUI.L("Class"))
        for _, class in ipairs(CLASS_SORT_ORDER) do
            if next(module.TrainerSpells(class)) then
                root:CreateRadio(ClassName(class), function() return shownClass == class end, function()
                    shownClass = class
                    panel.scroll:SetVerticalScroll(0)
                    Refresh()
                end)
            end
        end
    end)
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
    -- The class picker, top right: the class's name and an arrow.
    panel.class = CreateFrame("Button", nil, panel)
    panel.class:SetHeight(18)
    panel.class:SetPoint("TOPRIGHT", -PAD, -PAD + 1)
    panel.class.text = panel.class:CreateFontString(nil, "OVERLAY")
    Font(panel.class.text, 12)
    panel.class.text:SetPoint("LEFT")
    local arrow = panel.class:CreateTexture(nil, "ARTWORK")
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", 0, -3)
    panel.class:SetScript("OnClick", ClassMenu)
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
        self:RegisterEvent("SPELL_DATA_LOAD_RESULT")
        Refresh()
    end)
    panel:SetScript("OnHide", function(self)
        self:UnregisterAllEvents()
    end)
    panel:SetScript("OnEvent", function(_, event)
        if event == "SPELL_DATA_LOAD_RESULT" then OnSpellData() else Refresh() end
    end)
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
