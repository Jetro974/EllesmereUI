if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EllesmereUI.IS_FOREVER then return end -- Forever Essentials has its own planner
-------------------------------------------------------------------------------
--  EllesmereUIQoL_TalentPlannerRetail.lua
--  Talent Planner: plan the order in which to learn talents on the game's
--  class and specialization tree; a level up then learns the next planned
--  talent it can pay for.
--
--  Plan Talents (under the talent window) turns plan mode on: a click on a
--  talent plans its next rank (a choice node asks which choice), a
--  right-click takes its last planned rank back. Each planned talent shows
--  its place in the order, 1 being the next to learn. The plan is kept per
--  specialization, in order, as node ids: there is no level formula.
--
--  Learning: at level up (once the new point reaches the tree), at login and
--  when plan mode ends, the first planned talent that is open and paid for is
--  staged with C_Traits (a choice node with SetSelection, any other with
--  PurchaseRank), again for every point left, and the lot is applied with one
--  C_ClassTalents.CommitConfig, as the Apply Changes button does. Only out of
--  combat, and never over talent changes the player has not applied yet, the
--  Starter Build, or a commit that is still running: the planner says so in
--  chat and waits.
--
--  The marks are frames of our own, children of the game's talent buttons
--  (read through EnumerateAllTalentButtons, never written); they take clicks
--  only in plan mode.
-------------------------------------------------------------------------------
-- Settings live in EllesmereUIDB.talentPlannerRetail; unset keys read these.
--   plans   [specID] = { { n = nodeID, r = rank, e = entryID (choice nodes) }, ... }
local F = EllesmereUI.NewFeature("talentPlannerRetail", { enabled = false }, nil,
    { group = "Quality of Life", folder = "EllesmereUIQoL" })

local queue = EllesmereUI.NewCombatQueue(CreateFrame("Frame"))
local marks = setmetatable({}, { __mode = "k" }) -- talent button -> our mark (buttons are pooled)
local events, waiter, layer, planMode
local scheduled, learning
local awaiting   -- a level up whose point has not reached the tree yet
local waitData   -- login: the talent data is not loaded yet
local waiting    -- held back by talent changes the player has not applied
local committing -- the links of the commit we started, until it lands or fails
local told = {}  -- hold-back reasons already said in chat

local function Say(msg)
    EllesmereUI.Print(EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r " .. msg)
end

local function SayOnce(reason, msg)
    if told[reason] or not msg then return end
    told[reason] = true
    Say(msg)
end

-------------------------------------------------------------------------------
--  The plan
-------------------------------------------------------------------------------
local function SpecID()
    local index = C_SpecializationInfo.GetSpecialization()
    local id = index and index > 0 and C_SpecializationInfo.GetSpecializationInfo(index)
    return id and id > 0 and id or nil
end

-- The active specialization's plan; create: make it.
local function Plan(create)
    local specID = SpecID()
    if not specID then return nil end
    local cfg = create and F.Cfg() or F.Read()
    if create then
        cfg.plans = cfg.plans or {}
        cfg.plans[specID] = cfg.plans[specID] or {}
    end
    return cfg.plans and cfg.plans[specID]
end

-- The combat config and the tree of the active specialization; nil until the
-- talent data is loaded.
local function Active(specID)
    local configID = C_ClassTalents.GetActiveConfigID()
    local treeID = specID and C_ClassTalents.GetTraitTreeForSpec(specID)
    return configID, treeID
end

local function EntrySpell(configID, entryID)
    local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
    local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
    return def and def.spellID, def and def.overrideName
end

-- The entry a node shows: the planned choice, the chosen one, else its first.
local function ShownEntry(info, item)
    return (item and item.e) or (info.activeEntry and info.activeEntry.entryID)
        or (info.entryIDs and info.entryIDs[1])
end

local function EntryName(configID, entryID)
    local spellID, name = EntrySpell(configID, entryID)
    if name and name ~= "" then return name end
    return spellID and C_Spell.GetSpellName(spellID) or ("#" .. tostring(entryID))
end

local function NodeLink(configID, item)
    local info = C_Traits.GetNodeInfo(configID, item.n)
    local spellID = info and EntrySpell(configID, ShownEntry(info, item))
    return spellID and C_Spell.GetSpellLink(spellID) or ("#" .. item.n)
end

local function IsChoice(info)
    return info.type == Enum.TraitNodeType.Selection
end

-- The planned items not learned yet become numbers, 1 being the next:
-- node id -> { its numbers }.
local function Numbers(plan, configID)
    local out, n = {}, 0
    for _, item in ipairs(plan) do
        local info = C_Traits.GetNodeInfo(configID, item.n)
        if info and (info.ranksPurchased or 0) < item.r then
            n = n + 1
            local list = out[item.n]
            if not list then
                list = {}
                out[item.n] = list
            end
            list[#list + 1] = n
        end
    end
    return out
end

-------------------------------------------------------------------------------
--  Learning
-------------------------------------------------------------------------------
local function Currencies(configID, treeID)
    local money, any = {}, false
    for _, c in ipairs(C_Traits.GetTreeCurrencyInfo(configID, treeID, false) or {}) do
        money[c.traitCurrencyID] = c.quantity
        if c.quantity > 0 then any = true end
    end
    return money, any
end

local function CanPay(configID, nodeID, money)
    for _, cost in ipairs(C_Traits.GetNodeCost(configID, nodeID) or {}) do
        if (money[cost.ID] or 0) < cost.amount then return false end
    end
    return true
end

-- "done" (learned already), "ready" (the game takes it now) or nil.
local function Check(configID, item, money)
    local info = C_Traits.GetNodeInfo(configID, item.n)
    if not info then return nil end
    if (info.ranksPurchased or 0) >= item.r then return "done" end
    if not info.meetsEdgeRequirements then return nil end
    if IsChoice(info) then
        local entry = item.e and C_Traits.GetEntryInfo(configID, item.e)
        if not (entry and entry.isAvailable and info.isAvailable) then return nil end
    elseif not info.canPurchaseRank then
        return nil
    end
    return CanPay(configID, item.n, money) and "ready" or nil
end

local function Buy(configID, item)
    local info = C_Traits.GetNodeInfo(configID, item.n)
    if info and IsChoice(info) then
        return C_Traits.SetSelection(configID, item.n, item.e)
    end
    return C_Traits.PurchaseRank(configID, item.n)
end

-- Stages the first ready planned item, again while a currency has points,
-- each pass reading the tree afresh: a learned talent opens the next ones.
local function Stage(configID, treeID, plan, out)
    for _ = 1, #plan do
        local money, any = Currencies(configID, treeID)
        if not any then return true end
        local pick
        for _, item in ipairs(plan) do
            if Check(configID, item, money) == "ready" then
                pick = item
                break
            end
        end
        if not pick then return true end
        if not Buy(configID, pick) then return false end
        out[#out + 1] = pick
    end
    return true
end

-- A talent commit is a cast; the game refuses another change until it ends.
local function CommitCastRunning()
    local spellID = select(9, UnitCastingInfo("player"))
    if spellID == nil or issecretvalue(spellID) then return false end
    return spellID == Constants.TraitConsts.COMMIT_COMBAT_TRAIT_CONFIG_CHANGES_SPELL_ID
end

-- The events each flag waits on.
local function Sync()
    if not events then return end
    local function Set(event, on)
        if on then events:RegisterEvent(event) else events:UnregisterEvent(event) end
    end
    Set("TRAIT_TREE_CURRENCY_INFO_UPDATED", awaiting)
    Set("PLAYER_TALENT_UPDATE", waitData)
    Set("TRAIT_CONFIG_UPDATED", waiting or committing)
    Set("CONFIG_COMMIT_FAILED", committing)
end

local function Rollback(configID)
    if InCombatLockdown() then
        queue.Defer("TalentPlannerRollback", function() C_Traits.RollbackConfig(configID) end)
    else
        C_Traits.RollbackConfig(configID)
    end
end

local function Hold(reason, msg, wait)
    waiting = wait
    Sync()
    SayOnce(reason, msg)
end

-- Learns the planned talents the points allow. Waits out combat.
local function Learn()
    if not F.Enabled() or learning then return end
    if InCombatLockdown() then
        queue.Defer("TalentPlanner", Learn)
        return
    end
    local specID = SpecID()
    local configID, treeID = Active(specID)
    waitData = not (configID and treeID)
    Sync()
    if waitData then return end
    if committing then
        -- The commit landed without us hearing of it: nothing is staged any more.
        if C_Traits.ConfigHasStagedChanges(configID) ~= false or CommitCastRunning() then return end
        committing = nil
        Sync()
    end
    local plan = Plan()
    if not (plan and #plan > 0) then return end
    local _, any = Currencies(configID, treeID)
    if not any then return end
    awaiting = false
    waiting = false
    Sync()

    if C_ClassTalents.GetStarterBuildActive() then
        return Hold("starter", EllesmereUI.L("Talent Planner: the Starter Build is active. Pick a loadout of your own and the plan continues."), true)
    end
    if C_Traits.ConfigHasStagedChanges(configID) ~= false then
        return Hold("staged", EllesmereUI.L("Talent Planner: you have talent changes that are not applied. Apply them and the plan continues."), true)
    end
    if CommitCastRunning() then return Hold("cast", nil, true) end
    local canEdit, why = C_ClassTalents.CanEditTalents()
    if not canEdit then
        return Hold("edit", EllesmereUI.Lf("Talent Planner: talents cannot be changed right now. %s", why or ""), false)
    end

    local learned = {}
    learning = true
    local ok, staged = pcall(Stage, configID, treeID, plan, learned)
    learning = false
    if not ok then
        Rollback(configID)
        geterrorhandler()(staged)
        return
    end
    if #learned == 0 then
        if not staged then SayOnce("refused", EllesmereUI.L("Talent Planner: the game did not take a planned talent. Check your plan.")) end
        return
    end
    local canChange, canAdd, changeError = C_ClassTalents.CanChangeTalents()
    local loadoutID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
    if not tContains(C_ClassTalents.GetConfigIDsBySpecID(specID) or {}, loadoutID) then loadoutID = nil end
    if (canChange or canAdd) and C_ClassTalents.CommitConfig(loadoutID) then
        local links = {}
        for i, item in ipairs(learned) do links[i] = NodeLink(configID, item) end
        committing = links
        told = {}
        Sync()
    else
        Rollback(configID)
        SayOnce("commit", EllesmereUI.Lf("Talent Planner: talents cannot be changed right now. %s", changeError or ""))
    end
end

-- Changes come in bursts, and some arrive inside the game's own talent code:
-- act on the next frame, once.
local function Soon()
    if scheduled then return end
    scheduled = true
    C_Timer.After(0, function()
        scheduled = false
        Learn()
    end)
end

local function Landed(configID)
    if issecretvalue(configID) or configID ~= C_ClassTalents.GetActiveConfigID() then return end
    Say(EllesmereUI.Lf("Talents learned: %s", table.concat(committing, " ")))
    committing = nil
    Sync()
end

local function Failed(configID)
    if issecretvalue(configID) then return end
    local activeID = C_ClassTalents.GetActiveConfigID()
    if activeID then Rollback(activeID) end
    committing = nil
    Sync()
    Say(EllesmereUI.L("Talent Planner: the talent change was interrupted. It is tried again at your next level up, at login or when you leave plan mode."))
end

local function OnEvent(_, event, a, b)
    if event == "PLAYER_LEVEL_UP" then
        awaiting = true
        Sync()
        Soon()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Login and reload only: a point may have come while the addon was off.
        if a or b then
            committing = nil
            Sync()
            Soon()
        end
    elseif event == "TRAIT_CONFIG_UPDATED" then
        if committing then Landed(a) else Soon() end
    elseif event == "CONFIG_COMMIT_FAILED" then
        if committing then Failed(a) end
    else
        Soon()
    end
end

-------------------------------------------------------------------------------
--  The marks on the talent tree
-------------------------------------------------------------------------------
local function Accent()
    local c = EllesmereUI.ELLESMERE_GREEN
    if c then return c.r, c.g, c.b end
    return 0.05, 0.82, 0.62
end

local function NumbersText(list, full)
    if not list or #list == 0 then return nil end
    if full or #list <= 3 then return table.concat(list, ", ") end
    return list[1] .. "-" .. list[#list]
end

local Refresh

local function MarkEnter(mark)
    local configID = C_ClassTalents.GetActiveConfigID()
    local info = configID and C_Traits.GetNodeInfo(configID, mark.nodeID)
    if not info then return end
    local plan = Plan() or {}
    local planned
    for _, item in ipairs(plan) do
        if item.n == mark.nodeID then planned = item end
    end
    GameTooltip:SetOwner(mark, "ANCHOR_RIGHT")
    if IsChoice(info) and not (planned or info.activeEntry) then
        local names = {}
        for i, entryID in ipairs(info.entryIDs) do names[i] = EntryName(configID, entryID) end
        GameTooltip:SetText(table.concat(names, " / "))
    else
        local spellID = EntrySpell(configID, ShownEntry(info, planned))
        if spellID then GameTooltip:SetSpellByID(spellID) end
    end
    local text = NumbersText(Numbers(plan, configID)[mark.nodeID], true)
    if text then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(EllesmereUI.Lf("Planned: %s", text), Accent())
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(EllesmereUI.L("Left-click: plan the next rank, or pick the choice. Right-click: take the last planned rank back."),
        0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function MarkLeave(mark)
    if GameTooltip:IsOwned(mark) then GameTooltip:Hide() end
end

-- The planned items of a node, in plan order.
local function NodeItems(plan, nodeID)
    local out = {}
    for i, item in ipairs(plan) do
        if item.n == nodeID then out[#out + 1] = i end
    end
    return out
end

local function PlanChoice(mark, info, configID)
    MenuUtil.CreateContextMenu(mark, function(_, root)
        for _, entryID in ipairs(info.entryIDs) do
            root:CreateButton(EntryName(configID, entryID), function()
                local plan = Plan(true)
                if not plan then return end
                local at = NodeItems(plan, mark.nodeID)[1]
                if at then
                    plan[at].e = entryID
                else
                    plan[#plan + 1] = { n = mark.nodeID, r = 1, e = entryID }
                end
                Refresh()
            end)
        end
    end)
end

local function MarkClick(mark, button)
    local configID = C_ClassTalents.GetActiveConfigID()
    local info = configID and C_Traits.GetNodeInfo(configID, mark.nodeID)
    local plan = info and Plan(true)
    if not plan then return end
    local at = NodeItems(plan, mark.nodeID)
    if button == "RightButton" then
        if #at > 0 then table.remove(plan, at[#at]) end
    else
        local top = #at > 0 and plan[at[#at]].r or 0
        if math.max(top, info.ranksPurchased or 0) >= (info.maxRanks or 1) then return end
        if IsChoice(info) then
            PlanChoice(mark, info, configID)
            return
        end
        plan[#plan + 1] = { n = mark.nodeID, r = math.max(top, info.ranksPurchased or 0) + 1 }
    end
    Refresh()
    MarkEnter(mark)
end

local function Mark(talentButton)
    local mark = marks[talentButton]
    if mark then return mark end
    mark = CreateFrame("Button", nil, talentButton)
    mark:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mark:SetScript("OnClick", MarkClick)
    mark:SetScript("OnEnter", MarkEnter)
    mark:SetScript("OnLeave", MarkLeave)
    mark.hover = mark:CreateTexture(nil, "OVERLAY")
    mark.hover:SetAllPoints()
    mark.hover:SetColorTexture(1, 1, 1, 0.15)
    mark.hover:SetBlendMode("ADD")
    mark:SetHighlightTexture(mark.hover)
    mark.text = mark:CreateFontString(nil, "OVERLAY")
    EllesmereUI.ApplyModuleFont(mark.text, nil, 12, "extras", "OUTLINE")
    mark.text:SetPoint("BOTTOM", mark, "BOTTOM", 0, -6)
    marks[talentButton] = mark
    return mark
end

local function HideMarks()
    for _, mark in pairs(marks) do mark:Hide() end
end

-- Every talent button gets its mark: the numbers always, the clicks in plan
-- mode only.
function Refresh()
    local talents = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not (layer and talents and talents:IsVisible()) then return end
    local configID = C_ClassTalents.GetActiveConfigID()
    local inspecting = talents:IsInspecting()
    if inspecting and planMode then planMode = false end
    layer.plan:SetShown(not inspecting and configID ~= nil)
    layer.plan:SetText(planMode and EllesmereUI.L("Done") or EllesmereUI.L("Plan Talents"))
    layer.clear:SetShown(planMode)
    if inspecting or not configID then
        HideMarks()
        return
    end
    local numbers = Numbers(Plan() or {}, configID)
    local r, g, b = Accent()
    for talentButton in talents:EnumerateAllTalentButtons() do
        local nodeID = talentButton:GetNodeID()
        local info = nodeID and talentButton:GetNodeInfo()
        if not (info and (info.maxRanks or 0) > 0) then
            if marks[talentButton] then marks[talentButton]:Hide() end
        else
            local mark = Mark(talentButton)
            mark.nodeID = nodeID
            mark:SetAllPoints(talentButton)
            mark.text:SetTextColor(r, g, b)
            local text = NumbersText(numbers[nodeID])
            mark.text:SetText(text or "")
            mark:EnableMouse(planMode)
            mark:SetShown(planMode or text ~= nil)
        end
    end
end

local function SetPlanMode(on)
    planMode = on
    Refresh()
    if not on then Soon() end
end

local function TextButton(parent, text)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(120, 22)
    b:SetText(text)
    return b
end

local function OnButtonsUpdated(_, treeID)
    local talents = PlayerSpellsFrame.TalentsFrame
    if treeID == talents:GetTalentTreeID() then Refresh() end
end

local function Build()
    local talents = PlayerSpellsFrame.TalentsFrame
    layer = CreateFrame("Frame", nil, talents)
    layer:SetAllPoints()
    layer:SetFrameLevel(talents:GetFrameLevel() + 5)
    -- Plan Talents and Clear Plan sit under the window, out of the tree's way.
    layer.plan = TextButton(layer, EllesmereUI.L("Plan Talents"))
    layer.plan:SetPoint("TOPRIGHT", PlayerSpellsFrame, "BOTTOMRIGHT", -8, -2)
    layer.plan:SetScript("OnClick", function() SetPlanMode(not planMode) end)
    layer.clear = TextButton(layer, EllesmereUI.L("Clear Plan"))
    layer.clear:SetPoint("RIGHT", layer.plan, "LEFT", -6, 0)
    layer.clear:SetScript("OnClick", function()
        EllesmereUI:ShowConfirmPopup({
            title = "Clear Plan",
            message = "Clear the talent plan of this specialization?",
            confirmText = "Clear",
            cancelText = "Cancel",
            onConfirm = function()
                local plan = Plan(true)
                if not plan then return end
                for i = #plan, 1, -1 do plan[i] = nil end
                Refresh()
            end,
        })
    end)
    layer:SetScript("OnShow", function(self)
        EventRegistry:RegisterCallback("TalentFrameBase.ButtonsUpdated", OnButtonsUpdated, self)
        Refresh()
    end)
    layer:SetScript("OnHide", function(self)
        EventRegistry:UnregisterCallback("TalentFrameBase.ButtonsUpdated", self)
        HideMarks()
        if planMode then SetPlanMode(false) end
    end)
end

local function Hook()
    if not layer then Build() end
    layer:SetShown(F.Enabled())
end

-------------------------------------------------------------------------------
--  Apply
-------------------------------------------------------------------------------
-- Off: no events, no marks. The talent window loads on demand, so the marks
-- may wait for it.
local function Apply()
    if not F.Enabled() then
        if events then events:UnregisterAllEvents() end
        if waiter then waiter:UnregisterAllEvents() end
        awaiting, waitData, waiting, committing, planMode = nil, nil, nil, nil, nil
        if layer then layer:Hide() end
        return
    end
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", OnEvent)
    end
    events:RegisterEvent("PLAYER_LEVEL_UP")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    if layer then
        layer:Show()
    elseif C_AddOns.IsAddOnLoaded("Blizzard_PlayerSpells") then
        Hook()
    else
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
end

-- Options-page entry points.
EllesmereUI._TalentPlannerRetail = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply)
