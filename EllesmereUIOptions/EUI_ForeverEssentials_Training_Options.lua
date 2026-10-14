if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_ForeverEssentials_Training_Options.lua
--  Builds the Training page of Forever Essentials: the Training Planner's
--  list of what a class trainer teaches, by level, with each ability's cost
--  once a trainer of that class was visited. The player's own class also
--  shows what this character has trained and what it can train now; any
--  other class can be picked.
-------------------------------------------------------------------------------
local ROW_H = 26
local ICON = 20

local shownClass  -- the class the list shows; the player's own until picked

local function Coins(copper)
    return copper and copper > 0 and C_CurrencyInfo.GetCoinTextureString(copper) or ""
end

local function ClassName(class)
    local name = LOCALIZED_CLASS_NAMES_MALE[class] or class
    local c = C_ClassColor.GetClassColor(class)
    return c and c:WrapTextInColorCode(name) or name
end

local function RowEnter(row)
    local e = row.entry
    local tip = e.name
    if e.rank then tip = tip .. " |cffaaaaaa(" .. e.rank .. ")|r" end
    tip = tip .. "\n" .. EllesmereUI.Lf("Level %d", e.level)
    if e.cost and e.cost > 0 then tip = tip .. "\n" .. Coins(e.cost) end
    EllesmereUI.ShowWidgetTooltip(row, tip)
end

local function RowLeave()
    EllesmereUI.HideWidgetTooltip()
end

-- One ability: icon, name and rank, its state (own class) and its cost.
local function Row(parent, y, e, fontPath, playerLevel)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 30, y)
    row:SetPoint("RIGHT", parent, "RIGHT", -30, 0)
    row:SetHeight(ROW_H)
    row.entry = e
    row:EnableMouseMotion(true)
    row:SetScript("OnEnter", RowEnter)
    row:SetScript("OnLeave", RowLeave)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON, ICON)
    icon:SetPoint("LEFT")
    icon:SetTexture(e.icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local cost = row:CreateFontString(nil, "OVERLAY")
    cost:SetFont(fontPath, 12, "")
    cost:SetPoint("RIGHT")
    cost:SetText(Coins(e.cost))

    local state = row:CreateFontString(nil, "OVERLAY")
    state:SetFont(fontPath, 12, "")
    state:SetPoint("RIGHT", cost, "LEFT", -16, 0)

    local name = row:CreateFontString(nil, "OVERLAY")
    name:SetFont(fontPath, 13, "")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", state, "LEFT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetText(e.rank and (e.name .. " |cffaaaaaa(" .. e.rank .. ")|r") or e.name)

    if e.known then
        icon:SetDesaturated(true)
        name:SetTextColor(0.55, 0.55, 0.55)
        state:SetTextColor(0.55, 0.55, 0.55)
        state:SetText(EllesmereUI.L("Trained"))
        cost:SetText("")
    elseif e.own and e.level <= playerLevel then
        name:SetTextColor(0.25, 1, 0.25)
        state:SetTextColor(0.25, 1, 0.25)
        state:SetText(EllesmereUI.L("Trainable now"))
    else
        name:SetTextColor(1, 1, 1)
    end
    return ROW_H
end

-- A level's line: the level and what its abilities cost together.
local function LevelHeader(parent, y, level, total, fontPath)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(fontPath, 13, "")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y - 10)
    fs:SetTextColor(1, 0.82, 0)
    fs:SetText(EllesmereUI.Lf("Level %d", level) .. (total > 0 and ("   |cffffffff" .. Coins(total) .. "|r") or ""))
    return 32
end

local function Note(parent, y, text, fontPath)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(fontPath, 13, "")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y - 8)
    fs:SetPoint("RIGHT", parent, "RIGHT", -22, 0)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(1, 1, 1, 0.7)
    fs:SetText(text)
    return fs:GetStringHeight() + 16
end

_G._EUI_BuildForeverTrainingPage = function(pageName, parent, yOffset)
    local TP = EllesmereUI._TrainingPlanner
    if EllesmereUI._prebuilding or not TP then return 0 end
    local fontPath = EllesmereUI.GetFontPath("essentials") or EllesmereUI.EXPRESSWAY

    if not TP.Get("enabled") then
        local sf = EllesmereUI._scrollFrame
        local height = math.floor((sf and sf:GetHeight() or 680) - 36)
        local cover = CreateFrame("Frame", nil, parent)
        cover:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset + 6)
        cover:SetSize(parent:GetWidth(), height)
        local _, btn = EllesmereUI.BuildActivationOverlay(cover, {
            fontPath = fontPath, width = parent:GetWidth(),
            title = EllesmereUI.L("Training Planner"),
            text = EllesmereUI.L("Lists what each class trainer teaches, by level: what you can train now and what comes next. Each visit to your class trainer adds the costs."),
            buttonLabel = EllesmereUI.L("Enable Training Planner"),
        })
        btn:SetScript("OnClick", function()
            TP.Cfg().enabled = true
            TP.Apply()
            EllesmereUI:InvalidateModulePageCache("EllesmereUIForeverEssentials")
            EllesmereUI:RefreshPage(true)
        end)
        return height
    end

    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h
    parent._showRowDivider = true

    local classes = TP.Classes()
    if not shownClass or not tContains(classes, shownClass) then shownClass = classes[1] end
    local values = {}
    for _, class in ipairs(classes) do values[class] = ClassName(class) end

    _, h = W:SectionHeader(parent, "TRAINING PLANNER", y);  y = y - h
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Training Planner",
          tooltip = "Lists what each class trainer teaches; visits to your trainer add the costs.",
          getValue = function() return TP.Get("enabled") end,
          setValue = function(v)
              TP.Cfg().enabled = v
              TP.Apply()
              EllesmereUI:InvalidateModulePageCache("EllesmereUIForeverEssentials")
              EllesmereUI:RefreshPage(true)
          end },
        { type = "dropdown", text = "Class", values = values, order = classes,
          tooltip = "The class whose abilities the list shows.",
          getValue = function() return shownClass end,
          setValue = function(v)
              shownClass = v
              EllesmereUI:RefreshPage(true)
          end }
    );  y = y - h

    local list = shownClass and TP.List(shownClass) or {}
    if #list == 0 then return math.abs(y) end
    local costs = false
    for _, e in ipairs(list) do
        if e.cost then costs = true break end
    end
    if not costs then
        y = y - Note(parent, y, EllesmereUI.L("Costs show once a character of this class visits its trainer."), fontPath)
    end

    -- Own class: what can be trained now, and its cost.
    local playerLevel = UnitLevel("player")
    if list[1].own then
        local count, cost = 0, 0
        for _, e in ipairs(list) do
            if not e.known and e.level <= playerLevel then
                count = count + 1
                cost = cost + (e.cost or 0)
            end
        end
        local text = count > 0 and EllesmereUI.Lf("Trainable now: %d (%s)", count, Coins(cost))
            or EllesmereUI.L("Nothing to train at your level.")
        y = y - Note(parent, y, text, fontPath)
    end

    local i = 1
    while list[i] do
        local level, total, j = list[i].level, 0, i
        while list[j] and list[j].level == level do
            if not list[j].known then total = total + (list[j].cost or 0) end
            j = j + 1
        end
        y = y - LevelHeader(parent, y, level, total, fontPath)
        for k = i, j - 1 do
            y = y - Row(parent, y, list[k], fontPath, playerLevel)
        end
        i = j
    end
    return math.abs(y) + 10
end
