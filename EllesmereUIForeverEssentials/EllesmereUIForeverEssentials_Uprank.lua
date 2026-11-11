if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Uprank.lua  (WoW Forever only)
--  When you or your pet get a higher rank of a spell, swaps every lower rank
--  of that spell on the action bars for the new one and reports it in chat
--  (the pet bar follows the pet's spellbook by itself). The highest rank of
--  each spell is remembered per character and per pet, so a rank learned
--  while the option was off or the pet was away is caught at the next check.
--  A character's first check upranks everything; after that a lower rank
--  placed on purpose stays.
--
--  Cost: nothing while off. While on, every event only marks what to read and
--  one check per frame reads it: the player's whole spellbook at the first
--  check after login and when the option is turned on, otherwise just the
--  spells LEARNED_SPELL_IN_SKILL_LINE names; the pet's spellbook (a few slots)
--  on SPELLS_CHANGED (the only event a pet learning a rank fires), UNIT_PET and
--  PET_BAR_UPDATE. The 180 action slots are walked only when a rank went up.
--
--  Place New Spells (its cog): a class spell learned for the first time also
--  goes on the first empty slot of the main action bar, since the WoW Forever
--  client never places learned spells itself. Only a spell the spellbook
--  shows under a class tab goes: passives, higher ranks, the General tab,
--  profession spells (a lure, a campfire) and spells already on a bar are
--  left alone. A spell the spellbook does not list yet waits for its next
--  update. It goes on the page the bar shows (stances and forms page it) and
--  its icon glides there from the trainer.
-------------------------------------------------------------------------------
local _, module = ...

local MAX_ACTION_SLOT = 180
local MAIN_BAR_SLOTS = 12
local GENERAL_SKILL_LINE = 1 -- the spellbook's General tab (professions and the like)
local PLAYER, PET = Enum.SpellBookSpellBank.Player, Enum.SpellBookSpellBank.Pet

-- Settings live in EllesmereUIDB.spellUprank; unset keys read these.
local F = module.Feature("spellUprank", { enabled = false, placeNew = false })

local events, flusher
local booted        -- the login apply has run
local firstScan     -- the first SPELLS_CHANGED after login reads the player's spellbook whole
local wantPlayer, wantPet = false, false  -- what the next check reads
local learned = {}  -- spell IDs learned since the last check
local pending = { player = {}, pet = {} } -- spell names to uprank once out of combat with an empty cursor
local placeQueue = {} -- { id } first-time spells for Place New Spells, same wait
local bookWait = {}   -- the ones the spellbook did not list yet: tried again at its next update
-- Read tables, reused by every read
local playerTop, petTop, petSlots, counts = {}, {}, {}, {}

local function Plain(v, kind)
    if not issecretvalue(v) and type(v) == (kind or "number") then return v end
end

-------------------------------------------------------------------------------
--  Spellbooks: the highest rank per spell name
-------------------------------------------------------------------------------
local function ReadPlayerTop()
    wipe(playerTop)
    for line = 1, (C_SpellBook.GetNumSpellBookSkillLines() or 0) do
        local li = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if li and not li.offSpecID then
            for slot = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                if C_SpellBook.GetSpellBookItemType(slot, PLAYER) == Enum.SpellBookItemType.Spell
                   and not C_SpellBook.IsSpellBookItemPassive(slot, PLAYER)
                   and not C_SpellBook.IsSpellBookItemLowRank(slot, PLAYER) then
                    local info = C_SpellBook.GetSpellBookItemInfo(slot, PLAYER)
                    if info and info.spellID and info.name then playerTop[info.name] = info.spellID end
                end
            end
        end
    end
    return playerTop
end

-- The pet's highest rank per name, and the spellbook slot of every rank it
-- knows; false when the pet has no spells (none out, or not loaded yet).
local function ReadPetTop()
    wipe(petTop)
    wipe(petSlots)
    local n = C_SpellBook.HasPetSpells()
    if not n or n == 0 then return false end
    for slot = 1, n do
        -- Pet spells are PetAction items; the stances and commands among them carry no spell ID.
        local info = C_SpellBook.GetSpellBookItemInfo(slot, PET)
        if info and info.spellID and info.name and not info.isPassive then
            petSlots[info.spellID] = slot
            if not C_SpellBook.IsSpellBookItemLowRank(slot, PET) then petTop[info.name] = info.spellID end
        end
    end
    return true
end

-- Family and name: a hunter's two cats stay apart, a warlock's demon keeps its own.
local function PetKey()
    local family, name = Plain(UnitCreatureFamily("pet"), "string"), Plain(UnitName("pet"), "string")
    if name == UNKNOWNOBJECT then return end -- the name loads a moment after the pet
    return family and name and (family .. ":" .. name)
end

-- The highest ranks seen, per character (by GUID: a WoW Forever first name is
-- not unique) and per pet: account data outside the settings, kept out of
-- full exports (EllesmereUI_Profiles.lua's FULL_EXPORT_EXCLUDED).
local function Known()
    local all = EllesmereUIDB.spellUprankChars
    if type(all) ~= "table" then
        all = {}
        EllesmereUIDB.spellUprankChars = all
    end
    local guid = UnitGUID("player")
    local mine = all[guid]
    if not mine then
        mine = { player = {}, pets = {} }
        all[guid] = mine
    end
    return mine
end

-- Marks every name whose highest rank is not the remembered one, then remembers it.
local function Diff(now, was, into)
    for name, id in pairs(now) do
        if was[name] ~= id then
            into[name] = true
            was[name] = id
        end
    end
end

-- The spells learned since the last check, each on its own; false when one is
-- not in the spellbook yet, so the check reads the whole book instead.
local function ProbeLearned(known)
    for id in pairs(learned) do
        local name = C_Spell.GetSpellName(id)
        local slot, bank = C_SpellBook.FindSpellBookSlotForSpell(id)
        if not (name and slot) then return false end
        if bank == PLAYER and not C_SpellBook.IsSpellBookItemPassive(slot, PLAYER)
           and not C_SpellBook.IsSpellBookItemLowRank(slot, PLAYER) and known.player[name] ~= id then
            known.player[name] = id
            pending.player[name] = true
        end
    end
    return true
end

-------------------------------------------------------------------------------
--  Place New Spells
-------------------------------------------------------------------------------
-- A rank above 1 ("Rank 3", in any language: its number) upgrades a spell
-- the player already had: never a new one.
local function RankAboveOne(id)
    local text = C_Spell.GetSpellSubtext(id)
    if type(text) ~= "string" or issecretvalue(text) then return false end
    local n = tonumber(text:match("%d+"))
    return n ~= nil and n > 1
end

-- Whether a spellbook slot sits under a class tab: past the General tab
-- (1), and before the profession blocks, which follow every tab.
local function InClassTab(slot)
    for line = GENERAL_SKILL_LINE + 1, (C_SpellBook.GetNumSpellBookSkillLines() or 0) do
        local li = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if li and slot > li.itemIndexOffset and slot <= li.itemIndexOffset + li.numSpellBookItems then
            return true
        end
    end
    return false
end

local function OnBars(id)
    local slots = C_ActionBar.FindSpellActionButtons(id)
    return slots ~= nil and #slots > 0
end

local function Say(msg)
    EllesmereUI.Print(EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r " .. msg)
end

-- The main bar's shown buttons and the slots they show right now: a stance,
-- form or stealth pages the bar (a warrior never shows slots 1-12), so the
-- slot is read off the button (EUI's bars, then Blizzard's), up to the last
-- button the bar holds (EUI's can hold fewer than 12). An empty button is
-- hidden unless empty buttons are shown, so it counts while its bar is shown.
-- In a vehicle, or with another bar addon: slots 1-12 and no button.
local function OnShownBar(btn)
    local bar = btn and btn:GetParent()
    return bar ~= nil and bar:IsVisible()
end

local function MainBar()
    local list = {}
    local vehicle = (HasVehicleActionBar and HasVehicleActionBar())
        or (HasOverrideActionBar and HasOverrideActionBar())
    if not vehicle then
        for i = 1, MAIN_BAR_SLOTS do
            local btn, slot = _G["EABButton" .. i], nil
            -- eab-withincutoff 0: past the number of buttons the bar shows.
            if OnShownBar(btn) and btn:GetAttribute("eab-withincutoff") ~= 0 then
                slot = Plain(btn:GetAttribute("action"))
            else
                btn = _G["ActionButton" .. i]
                if OnShownBar(btn) then slot = Plain(btn.action) end
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
local APPEAR, TRAVEL, LAND = 0.25, 1.1, 0.35 -- seconds
local flyers, flights = {}, 0

-- anyShown: the frame may be hidden (a button just filled shows a frame later).
local function Center(frame, anyShown)
    if not (frame and (anyShown or frame:IsVisible())) then return end
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
    local hold = Step(path, "Alpha", 1, APPEAR)
    hold:SetFromAlpha(1); hold:SetToAlpha(1)
    f.move = Step(path, "Translation", 2, TRAVEL)
    f.move:SetSmoothing("IN_OUT")
    -- Landed: the button's own icon comes back as this one pops over it.
    f.move:SetScript("OnFinished", function() f.Land() end)
    hold = Step(path, "Alpha", 3, LAND)
    hold:SetFromAlpha(1); hold:SetToAlpha(1)
    function f.Land()
        if f.target then f.target:SetAlpha(1) end
        f.target = nil
    end
    local function Done()
        f.Land()
        f:Hide()
        flyers[#flyers + 1] = f
    end
    path:SetScript("OnFinished", Done)
    path:SetScript("OnStop", Done)

    local look = inner:CreateAnimationGroup()
    look:SetToFinalAlpha(true)
    local fadeIn = Step(look, "Alpha", 1, APPEAR)
    fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1)
    f.shrink = Step(look, "Scale", 2, TRAVEL)
    f.shrink:SetSmoothing("IN_OUT")
    local pop = Step(look, "Scale", 3, LAND)
    pop:SetScaleFrom(1, 1); pop:SetScaleTo(1.35, 1.35)
    local fadeOut = Step(look, "Alpha", 3, LAND)
    fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0)

    f.path, f.look = path, look
    return f
end

local function Fly(spellID, button)
    local sx, sy = Center(ClassTrainerTrainButton)
    if not sx then sx, sy = Center(ClassTrainerFrame) end
    if not sx then sx, sy = Center(PlayerSpellsFrame or SpellBookFrame) end
    if not sx then sx, sy = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2 end
    -- The spell is already on the button: its icon waits for this one to land.
    local target = button.icon or button.Icon
    if target then target:SetAlpha(0) end
    flights = flights + 1
    C_Timer.After((flights - 1) * 0.3, function()
        -- Read when it flies: the button it lands on may only now be laid out.
        local tx, ty, tw = Center(button, true)
        if not tx or tw <= 0 then
            if target then target:SetAlpha(1) end
            return
        end
        local f = table.remove(flyers) or NewFlyer()
        f.target = target
        f.icon:SetTexture(C_Spell.GetSpellTexture(spellID))
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", sx, sy)
        f:SetSize(tw, tw)
        f.move:SetOffset(tx - sx, ty - sy)
        local r = FLY_SIZE / tw
        f.shrink:SetScaleFrom(r, r); f.shrink:SetScaleTo(1, 1)
        f:Show()
        f.path:Play()
        f.look:Play()
    end)
end

-- The first empty slot of the main action bar gets the new spell.
-- Returns "later" while the spellbook does not list the spell yet: the learn
-- event can come first, and a profession's spell only shows its block then.
local function PlaceNew(newID)
    if not F.Get("placeNew") then return end
    local slot, bank = C_SpellBook.FindSpellBookSlotForSpell(newID)
    if not slot then return "later" end
    if bank ~= PLAYER or not InClassTab(slot) then return end
    local spell = C_Spell.GetSpellLink(newID) or C_Spell.GetSpellName(newID) or "?"
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
                Say(EllesmereUI.Lf("Placed %1$s on action slot %2$d.", spell, item.index))
            end
            return
        end
    end
end

-------------------------------------------------------------------------------
--  Swapping
-------------------------------------------------------------------------------
-- A pet keeps only its highest rank, so any other rank of its spell is an old
-- one. A bar spell the player knows is the player's (a lower rank still reads
-- known); a pet spell reads unknown.
local function UprankPending()
    local hasPlayer = next(pending.player) ~= nil
    local hasPet = next(pending.pet) ~= nil and ReadPetTop()
    if hasPlayer then ReadPlayerTop() end
    wipe(counts)

    for action = 1, MAX_ACTION_SLOT do
        local kind, id = GetActionInfo(action)
        id = kind == "spell" and Plain(id)
        local name = id and C_Spell.GetSpellName(id)
        if name then
            local petNew = hasPet and pending.pet[name] and petTop[name]
            local playerNew = hasPlayer and pending.player[name] and playerTop[name]
            if petNew and petNew ~= id and not C_SpellBook.IsSpellKnown(id) then
                C_SpellBook.PickupSpellBookItem(petSlots[petNew], PET)
                PlaceAction(action)
                ClearCursor()
                counts[petNew] = (counts[petNew] or 0) + 1
            elseif playerNew and playerNew ~= id and C_SpellBook.IsSpellKnown(id) then
                C_Spell.PickupSpell(playerNew)
                PlaceAction(action)
                ClearCursor()
                counts[playerNew] = (counts[playerNew] or 0) + 1
            end
        end
    end

    wipe(pending.player)
    wipe(pending.pet)
    -- Quiet: the game already prints the spell learned and the button shows the new rank.
end

-- Placing actions needs no combat and an empty cursor; waits for both.
local function Flush()
    if not (next(pending.player) or next(pending.pet) or placeQueue[1]) then return end
    if InCombatLockdown() then
        EllesmereUI.CombatQueue.Defer("SpellUprank", Flush)
        return
    end
    if GetCursorInfo() then
        events:RegisterEvent("CURSOR_CHANGED")
        return
    end
    events:UnregisterEvent("CURSOR_CHANGED")
    if next(pending.player) or next(pending.pet) then UprankPending() end
    local list = placeQueue
    placeQueue = {}
    flights = 0
    for _, item in ipairs(list) do
        if PlaceNew(item.id) == "later" and not item.waited then
            item.waited = true
            bookWait[#bookWait + 1] = item
        end
    end
end

-------------------------------------------------------------------------------
--  Checks: one per frame, reading only what the events asked for
-------------------------------------------------------------------------------
local function Check()
    flusher:Hide()
    local known = Known()
    if next(learned) then
        if not wantPlayer and not ProbeLearned(known) then wantPlayer = true end
        wipe(learned)
    end
    if wantPlayer then Diff(ReadPlayerTop(), known.player, pending.player) end
    if wantPet then
        local key = PetKey()
        if key and ReadPetTop() then
            local was = known.pets[key]
            if not was then
                was = {}
                known.pets[key] = was
            end
            Diff(petTop, was, pending.pet)
        end
    end
    wantPlayer, wantPet = false, false
    Flush()
end

-- The next frame runs one check for every event of this one.
local function Queue()
    if not flusher then
        flusher = CreateFrame("Frame")
        flusher:Hide()
        flusher:SetScript("OnUpdate", Check)
    end
    flusher:Show()
end

local function OnEvent(_, event, spellID, _, isGuildPerkSpell)
    if event == "CURSOR_CHANGED" then
        Flush()
        return
    end
    if event == "LEARNED_SPELL_IN_SKILL_LINE" then
        spellID = Plain(spellID)
        if not spellID then return end
        learned[spellID] = true
        if F.Get("placeNew") and not isGuildPerkSpell then
            placeQueue[#placeQueue + 1] = { id = spellID }
            -- Placed in the event itself, as before the uprank moved to a check
            -- on the next frame: by then the slot may be filled and the fly-in lost.
            Flush()
        end
    elseif event == "SPELLS_CHANGED" then
        for _, item in ipairs(bookWait) do placeQueue[#placeQueue + 1] = item end
        wipe(bookWait)
        if firstScan then
            firstScan = false
            wantPlayer = true
        end
        wantPet = true
    else
        -- UNIT_PET, PET_BAR_UPDATE: the pet came, went or filled its bar
        wantPet = true
    end
    Queue()
end

local function Apply()
    if events then events:UnregisterAllEvents() end
    if flusher then flusher:Hide() end
    local login = not booted
    booted = true
    wipe(learned)
    wantPlayer, wantPet, firstScan = false, false, false
    if not F.Enabled() then
        wipe(pending.player)
        wipe(pending.pet)
        placeQueue = {}
        wipe(bookWait)
        return
    end
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", OnEvent)
    end
    events:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
    events:RegisterEvent("SPELLS_CHANGED")
    events:RegisterEvent("PET_BAR_UPDATE")
    events:RegisterUnitEvent("UNIT_PET", "player")
    if login then
        -- At login the spellbook is not ready yet: the SPELLS_CHANGED that follows reads it.
        firstScan = true
    else
        wantPlayer, wantPet = true, true
        Queue()
    end
end

-- Options-page entry points.
EllesmereUI._SpellUprank = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply)
