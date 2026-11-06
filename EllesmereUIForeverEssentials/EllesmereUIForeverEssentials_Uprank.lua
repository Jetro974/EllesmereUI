if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Uprank.lua  (WoW Forever only)
--  When a new spell rank is learned, swaps every lower rank of that spell on
--  the action bars for the new one and reports it in chat.
--  Place New Spells (its cog): a class spell learned for the first time also
--  goes on the first empty slot of the main action bar, since the WoW Forever
--  client never places learned spells itself. Passives, higher ranks and
--  spells already on a bar are left alone. It goes on the page the bar shows
--  (stances and forms page it) and its icon glides there from the trainer.
-------------------------------------------------------------------------------
local _, module = ...

local MAX_ACTION_SLOT = 180
local MAIN_BAR_SLOTS = 12
local GENERAL_SKILL_LINE = 1 -- the spellbook's General tab (professions and the like)

-- Settings live in EllesmereUIDB.spellUprank; unset keys read these.
local F = module.Feature("spellUprank", { enabled = false, placeNew = false })

local events
local pending = {} -- { id, line } learned spells waiting for combat / the cursor to clear

local function Plain(v)
    if not issecretvalue(v) and type(v) == "number" then return v end
end

-- A rank above 1 ("Rank 3", in any language: its number) upgrades a spell
-- the player already had: never a new one.
local function RankAboveOne(id)
    local text = C_Spell.GetSpellSubtext(id)
    if type(text) ~= "string" or issecretvalue(text) then return false end
    local n = tonumber(text:match("%d+"))
    return n ~= nil and n > 1
end

local function OnBars(id)
    local slots = C_ActionBar.FindSpellActionButtons(id)
    return slots ~= nil and #slots > 0
end

local function Report(msg)
    EllesmereUI.Print(EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r " .. msg)
end

-- The main bar's shown buttons and the slots they show right now: a stance,
-- form or stealth pages the bar (a warrior never shows slots 1-12), so the
-- slot is read off the button (EUI's bars, then Blizzard's), up to the last
-- button shown (a bar can show fewer than 12). In a vehicle, or with another
-- bar addon: slots 1-12 and no button.
local function MainBar()
    local list = {}
    local vehicle = (HasVehicleActionBar and HasVehicleActionBar())
        or (HasOverrideActionBar and HasOverrideActionBar())
    if not vehicle then
        for i = 1, MAIN_BAR_SLOTS do
            local btn, slot = _G["EABButton" .. i], nil
            if btn and btn:IsVisible() then
                slot = Plain(btn:GetAttribute("action"))
            else
                btn = _G["ActionButton" .. i]
                if btn and btn:IsVisible() then slot = Plain(btn.action) end
            end
            if not slot then break end
            list[i] = { index = i, slot = slot, button = btn }
        end
    end
    if #list == 0 then
        for i = 1, MAIN_BAR_SLOTS do list[i] = { index = i, slot = i } end
    end
    return list
end

-- Fly-in: the spell's icon glides from the trainer (wherever its window is),
-- else the spellbook, else the screen's middle, onto its button, then pops
-- and fades. Our own frames only (pooled); Blizzard's are only read for
-- their position. Several spells learned at once fly one after the other.
local FLY_SIZE = 44
local flyers, flights = {}, 0

local function Center(frame)
    if not (frame and frame:IsVisible()) then return end
    local x, y = frame:GetCenter()
    if not x then return end
    local s = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return x * s, y * s, frame:GetWidth() * s
end

local function Step(g, kind, order, secs)
    local a = g:CreateAnimation(kind)
    a:SetOrder(order)
    a:SetDuration(secs)
    return a
end

-- The outer frame only moves; the inner one only scales and fades, so the
-- scaling never bends the path and the icon lands exactly on the button.
local function NewFlyer()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:Hide()
    local inner = CreateFrame("Frame", nil, f)
    inner:SetAllPoints()
    f.icon = inner:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local path = f:CreateAnimationGroup()
    -- Alpha 1 -> 1: holds the frame while the icon appears, then while it pops.
    local hold = Step(path, "Alpha", 1, 0.15)
    hold:SetFromAlpha(1); hold:SetToAlpha(1)
    f.move = Step(path, "Translation", 2, 0.6)
    f.move:SetSmoothing("IN_OUT")
    hold = Step(path, "Alpha", 3, 0.25)
    hold:SetFromAlpha(1); hold:SetToAlpha(1)
    path:SetScript("OnFinished", function()
        f:Hide()
        flyers[#flyers + 1] = f
    end)

    local look = inner:CreateAnimationGroup()
    look:SetToFinalAlpha(true)
    local fadeIn = Step(look, "Alpha", 1, 0.15)
    fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1)
    f.shrink = Step(look, "Scale", 2, 0.6)
    f.shrink:SetSmoothing("IN_OUT")
    local pop = Step(look, "Scale", 3, 0.25)
    pop:SetScaleFrom(1, 1); pop:SetScaleTo(1.35, 1.35)
    local fadeOut = Step(look, "Alpha", 3, 0.25)
    fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0)

    f.path, f.look = path, look
    return f
end

local function Fly(spellID, button)
    local tx, ty, tw = Center(button)
    if not tx then return end
    local sx, sy = Center(ClassTrainerTrainButton)
    if not sx then sx, sy = Center(ClassTrainerFrame) end
    if not sx then sx, sy = Center(PlayerSpellsFrame or SpellBookFrame) end
    if not sx then sx, sy = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2 end
    local f = table.remove(flyers) or NewFlyer()
    f.icon:SetTexture(C_Spell.GetSpellTexture(spellID))
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", sx, sy)
    f:SetSize(tw, tw)
    f.move:SetOffset(tx - sx, ty - sy)
    local r = FLY_SIZE / tw
    f.shrink:SetScaleFrom(r, r); f.shrink:SetScaleTo(1, 1)
    flights = flights + 1
    C_Timer.After((flights - 1) * 0.2, function()
        f:Show()
        f.path:Play()
        f.look:Play()
    end)
end

-- The first empty slot of the main action bar gets the new spell.
local function PlaceNew(newID, line, spell)
    if not F.Get("placeNew") or line == GENERAL_SKILL_LINE then return end
    if C_Spell.IsSpellPassive(newID) or RankAboveOne(newID) or OnBars(newID) then return end
    for _, item in ipairs(MainBar()) do
        if not HasAction(item.slot) then
            C_Spell.PickupSpell(newID)
            if GetCursorInfo() ~= "spell" then ClearCursor(); return end
            PlaceAction(item.slot)
            ClearCursor()
            if not HasAction(item.slot) then return end
            -- The fly-in already shows where it went; chat only says so when
            -- there is no button to fly to (vehicle, another bar addon). The
            -- button's number on the bar, not the paged slot (73 in a stance).
            if item.button then
                Fly(newID, item.button)
            else
                Report(EllesmereUI.Lf("Placed %1$s on action slot %2$d.", spell, item.index))
            end
            return
        end
    end
end

local function Uprank(newID, line)
    local name = C_Spell.GetSpellName(newID)
    if not name then return end
    local slot, bank = C_SpellBook.FindSpellBookSlotForSpell(newID)
    if not slot or C_SpellBook.IsSpellBookItemLowRank(slot, bank) then return end
    local count = 0
    for action = 1, MAX_ACTION_SLOT do
        local kind, id = GetActionInfo(action)
        id = kind == "spell" and Plain(id)
        -- Same name, both in the spellbook, new one highest: a lower rank.
        if id and id ~= newID and C_Spell.GetSpellName(id) == name
           and C_SpellBook.FindSpellBookSlotForSpell(id, true) then
            C_Spell.PickupSpell(newID)
            PlaceAction(action)
            ClearCursor()
            count = count + 1
        end
    end
    local rank = C_Spell.GetSpellSubtext(newID)
    local spell = (C_Spell.GetSpellLink(newID) or name) .. (rank and rank ~= "" and " (" .. rank .. ")" or "")
    if count > 0 then
        Report(count == 1 and EllesmereUI.Lf("Upranked %s on 1 action slot.", spell)
            or EllesmereUI.Lf("Upranked %1$s on %2$d action slots.", spell, count))
    else
        PlaceNew(newID, line, spell)
    end
end

-- Placing actions needs no combat and an empty cursor; waits for both.
local function Flush()
    if InCombatLockdown() or GetCursorInfo() then
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        events:RegisterEvent("CURSOR_CHANGED")
        return
    end
    events:UnregisterEvent("PLAYER_REGEN_ENABLED")
    events:UnregisterEvent("CURSOR_CHANGED")
    local list = pending
    pending = {}
    flights = 0
    for _, item in ipairs(list) do Uprank(item.id, item.line) end
end

local function OnEvent(_, event, spellID, skillLineIndex, isGuildPerkSpell)
    if event == "LEARNED_SPELL_IN_SKILL_LINE" then
        spellID = Plain(spellID)
        if not spellID or isGuildPerkSpell then return end
        pending[#pending + 1] = { id = spellID, line = Plain(skillLineIndex) }
    end
    Flush()
end

local function Apply()
    if events then events:UnregisterAllEvents() end
    if not F.Enabled() then
        pending = {}
        return
    end
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", OnEvent)
    end
    events:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
end

-- Options-page entry points.
EllesmereUI._SpellUprank = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply)
