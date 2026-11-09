if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Fishing.lua  (WoW Forever only)
--  Fishing helpers, each its own setting (all off by default):
--  Fishing Key      one key casts; it first equips a pole when none is in
--                   hand and applies a lure (cog). With Reel In (cog), once
--                   soft interact targets the bobber the key reels in; the
--                   Bobber Indicator (cog) shows whether it does.
--  Double-Click     a pole in hand: a quick second right-click on the world
--                   casts (its own Apply Lure in its cog).
--  Fishing Sounds   music and ambience down, effects up, for the session.
--  Fishing Outfit   (the key's cog) an Equipment Manager set the key puts on
--                   before it casts.
--  Put Gear Back    (the key's cog) when the session ends, what the pole or
--                   the outfit replaced goes back on: weapons at once, even
--                   in combat, the rest when the fight ends.
--  Auto Loot        the game's Auto Loot on for the session.
--  Bags Full        a warning while fishing once one free bag slot is left.
--  The Catch Log (EllesmereUIForeverEssentials_FishingLog.lua) follows the
--  session through module.fishingListeners.
--
--  Every action is a real key press or click on a secure button, bound out
--  of combat only. A session starts with a cast and ends on moving, combat
--  or a load; the CVars it changes go through EllesmereUI.HoldCVar, their
--  values from before saved and put back at the next login after a reload.
-------------------------------------------------------------------------------
local _, module = ...
local BUTTON_NAME = "EllesmereUIFishingCastButton"

-- Settings live in EllesmereUIDB.fishing; unset keys read these. key: the
-- Fishing Key (nil: none); held: [set] = { [cvar] = the value before };
-- pos: where Unlock Mode put the Bobber Indicator.
-- outfit: the Fishing Outfit's set ID (nil: none); gear: [slot] = the item
-- link worn there before the session (false: empty), for Put Gear Back.
local F = module.Feature("fishing", {
    reel = true, indicator = true, lure = true,
    doubleClick = false, clickLure = false, sound = false,
    gearBack = false, autoLoot = false, bagAlert = false,
}, { point = "CENTER", relPoint = "CENTER", x = 0, y = -180 })

-- fn(on) for each listener when a session starts (true) or ends (false).
module.fishingListeners = module.fishingListeners or {}

-- The Fishing ranks, highest first.
local FISHING_SPELLS = { 18248, 7732, 7731, 7620 }

-- Lures, best first (item ID): Aquadynamic Fish Attractor, Bright Baubles,
-- Flesh Eating Worm, Nightcrawlers, Aquadynamic Fish Lens, Shiny Bauble.
local LURES = { 6533, 6532, 7307, 6530, 6811, 6529 }

-- The bobber (game object ID).
local BOBBER = 35591

-- The slots a pole takes, and the ones the game lets change in combat.
local POLE_SLOTS = { INVSLOT_MAINHAND, INVSLOT_OFFHAND }
local WEAPON_SLOTS = { [INVSLOT_MAINHAND] = true, [INVSLOT_OFFHAND] = true, [INVSLOT_RANGED or 18] = true }

local DOUBLE_CLICK_DELAY = 0.4  -- seconds at most between the two right-clicks
local DISARM_DELAY = 1          -- no release by then: the right-click goes back to the game

-- CVars held for the session: name = its value then, from the value before.
-- Soft interact on, wide and far enough to target the bobber by itself.
local REEL_CVARS = {
    SoftTargetInteract = function() return 3 end,
    SoftTargetInteractRange = function() return 30 end,
    SoftTargetInteractArc = function() return 2 end,
    SoftTargetInteractRangeIsHard = function() return 0 end,
}
-- The splash of the bobber over the music.
local SOUND_CVARS = {
    Sound_MusicVolume = function(before) return before * 0.3 end,
    Sound_AmbienceVolume = function(before) return before * 0.3 end,
    Sound_SFXVolume = function(before) return math.max(before, 0.8) end,
    Sound_EnableSoundWhenGameIsInBG = function() return 1 end,
}
local LOOT_CVARS = {
    autoLootDefault = function() return 1 end,
}

local function KeyOn() return F.Get("key") ~= nil end
local function ReelOn() return KeyOn() and F.Get("reel") end
local function IndicatorOn() return ReelOn() and F.Get("indicator") end
local function AnyOn()
    return KeyOn() or F.Get("doubleClick") or F.Get("sound") or F.Get("autoLoot") or F.Get("bagAlert")
        or (module.FishingLogWanted ~= nil and module.FishingLogWanted())
end

local ev = CreateFrame("Frame")
local clickOwner = CreateFrame("Frame")  -- holds the double-click's binding
local castButton, indicator
local fishingID, fishingName  -- the Fishing rank known (nil: none)
local inSession = false
local lineOut = false         -- the Fishing channel runs
local reeling = false         -- the key is bound to Interact With Target
local clickArmed = false      -- the right-click is bound to the button
local lastRightClick = 0
local armedAt = 0             -- when the right-click was bound to the button
local worldHooked = false
local outfitTried = false     -- the outfit was looked at for this session
local bagWarned = false       -- Bags Full spoke for this low

-------------------------------------------------------------------------------
--  Helpers
-------------------------------------------------------------------------------
local function ResolveFishing()
    fishingID, fishingName = nil, nil
    for i = 1, #FISHING_SPELLS do
        local id = FISHING_SPELLS[i]
        if IsPlayerSpell(id) then
            fishingID, fishingName = id, C_Spell.GetSpellName(id)
            return
        end
    end
end

local function IsPole(id)
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
    return classID == Enum.ItemClass.Weapon and subClassID == Enum.ItemWeaponSubclass.Fishingpole
end

-- WoW Forever fishes with the pole in the main hand.
local function PoleInHand()
    local id = GetInventoryItemID("player", INVSLOT_MAINHAND)
    return id ~= nil and IsPole(id)
end

-- The best fishing pole in the bags (highest item level), or nil.
local function PoleInBags()
    local best, bestLevel
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and IsPole(id) then
                local level = select(4, C_Item.GetItemInfo(id)) or 0
                if not best or level > bestLevel then best, bestLevel = id, level end
            end
        end
    end
    return best
end

local function BestLure()
    for i = 1, #LURES do
        if C_Item.GetItemCount(LURES[i]) > 0 then return LURES[i] end
    end
end

-------------------------------------------------------------------------------
--  Fishing Outfit and Put Gear Back
-------------------------------------------------------------------------------
-- The Fishing Outfit's set ID while that set still exists.
local function Outfit()
    local id = F.Get("outfit")
    if id and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetInfo(id) then return id end
end

-- The slots a set fills, from its item IDs: GetItemLocations crashes the WoW
-- Forever client for some sets (see BuildSetGearLookup in Bags).
local function OutfitSlots(id)
    local slots, items = {}, C_EquipmentSet.GetItemIDs(id) or {}
    local ignored = C_EquipmentSet.GetIgnoredSlots(id) or {}
    for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
        local item = items[slot]
        if not ignored[slot] and item and item > 0 then slots[#slots + 1] = slot end
    end
    return slots
end

-- What is worn in the slots about to change, kept in the settings so a
-- reload mid-session still finds it. A slot already kept holds on to what
-- was there before the first change.
local function NoteGear(slots)
    if not F.Get("gearBack") then return end
    local cfg = F.Cfg()
    local gear = cfg.gear or {}
    for i = 1, #slots do
        local slot = slots[i]
        if gear[slot] == nil then gear[slot] = GetInventoryItemLink("player", slot) or false end
    end
    cfg.gear = gear
end

-- Puts back what NoteGear kept. A slot that was empty stays as it is. In
-- combat the game takes weapon changes only: the rest waits for its end.
local function GearBack()
    outfitTried = false
    local gear = F.Read().gear
    if not gear then return end
    local combat, left = InCombatLockdown(), false
    for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
        local link = gear[slot]
        if link ~= nil then
            if combat and not WEAPON_SLOTS[slot] then
                left = true
            else
                if link and GetInventoryItemLink("player", slot) ~= link then C_Item.EquipItemByName(link, slot) end
                gear[slot] = nil
            end
        end
    end
    if left then
        EllesmereUI.CombatQueue.Defer("FishingGear", GearBack)
    else
        F.Cfg().gear = nil
    end
end

-- The key's first press of a session puts the outfit on when it is not
-- worn yet; true when it did (that press casts nothing). Out of combat.
local function WearOutfit()
    local id = KeyOn() and Outfit()
    if not id or outfitTried then return false end
    outfitTried = true
    if select(4, C_EquipmentSet.GetEquipmentSetInfo(id)) then return false end
    NoteGear(OutfitSlots(id))
    C_EquipmentSet.UseEquipmentSet(id)
    return true
end

-------------------------------------------------------------------------------
--  Bags Full
-------------------------------------------------------------------------------
-- Free slots in the bags fish can go to (no profession bags).
local function FreeSlots()
    local free = 0
    for bag = 0, NUM_BAG_SLOTS do
        local n, family = C_Container.GetContainerNumFreeSlots(bag)
        if family == 0 then free = free + (n or 0) end
    end
    return free
end

-- Once per low: a free slot back above one lets it speak again.
local function CheckBags()
    local free = FreeSlots()
    if free > 1 then
        bagWarned = false
        return
    end
    if bagWarned then return end
    bagWarned = true
    local text = free == 0 and "Bags full: the next catch is lost." or "One free bag slot left."
    UIErrorsFrame:AddMessage(EllesmereUI.L(text), 1, 0.1, 0.1)
    PlaySound(SOUNDKIT.RAID_WARNING)
end

-- The game object ID in a "GameObject-0-...-35591-..." GUID, or nil.
local function ObjectID(guid)
    if not guid or issecretvalue(guid) then return nil end
    -- Only the object's ID field is read: the server and spawn fields before
    -- and after it may be obfuscated.
    return tonumber(guid:match("^GameObject%-[^-]*%-[^-]*%-[^-]*%-[^-]*%-(%d+)%-"))
end

-------------------------------------------------------------------------------
--  Held CVars
-------------------------------------------------------------------------------
local function CVarText(v) return v % 1 == 0 and tostring(v) or ("%.2f"):format(v) end

local function Hold(set, cvars)
    local cfg = F.Cfg()
    cfg.held = cfg.held or {}
    if cfg.held[set] then return end
    local was = {}
    for name, value in pairs(cvars) do
        local cur = C_CVar.GetCVar(name)
        local want = cur and CVarText(value(tonumber(cur) or 0))
        if cur ~= nil and cur ~= want and EllesmereUI.HoldCVar(name, want, "EllesmereUIForeverEssentials") then
            was[name] = cur
        end
    end
    cfg.held[set] = was
end

local function Release(set)
    local held = F.Read().held
    local was = held and held[set]
    if not was then return end
    for name, value in pairs(was) do
        EllesmereUI.ReleaseCVar(name, value, "EllesmereUIForeverEssentials")
    end
    held[set] = nil
end

-------------------------------------------------------------------------------
--  Bobber Indicator: while the line is in the water, an icon with a green
--  border when the key reels in, red when the bobber is not targeted; the key
--  sits on it and the full sentence is its tooltip. Placed in Unlock Mode.
-------------------------------------------------------------------------------
local INDICATOR_SIZE = 40
local ICON = "Interface\\Icons\\Trade_Fishing"  -- the Fishing profession

local function IndicatorTip()
    if reeling then return EllesmereUI.Lf("Bobber found: %s reels in", GetBindingText(F.Get("key"))) end
    return EllesmereUI.L("Bobber not found: keep it on screen, cast again, or right-click it to reel in.")
end

local function BuildIndicator()
    if indicator then return end
    local PP = EllesmereUI.PP
    indicator = CreateFrame("Frame", nil, UIParent)
    indicator:SetSize(INDICATOR_SIZE, INDICATOR_SIZE)
    indicator:SetFrameStrata("HIGH")
    -- Hover for the sentence; clicks go through to the world.
    indicator:SetMouseMotionEnabled(true)
    indicator:SetMouseClickEnabled(false)
    indicator:Hide()
    local icon = indicator:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    indicator.icon = icon
    PP.CreateBorder(indicator, 1, 0.2, 0.2, 1, 2, "OVERLAY", 2)
    -- The key, clipped to the icon's width.
    local key = indicator:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    key:SetPoint("BOTTOM", 0, 3)
    key:SetWidth(INDICATOR_SIZE - 4)
    key:SetWordWrap(false)
    indicator.key = key
    indicator:SetScript("OnEnter", function(self) EllesmereUI.ShowWidgetTooltip(self, IndicatorTip()) end)
    indicator:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
    F.Place(indicator)
end

local function UpdateIndicator()
    if not (lineOut and IndicatorOn()) then
        if indicator then indicator:Hide() end
        return
    end
    BuildIndicator()
    local r, g, b = 1, 0.2, 0.2
    if reeling then r, g, b = 0.2, 1, 0.3 end
    EllesmereUI.PP.SetBorderColor(indicator, r, g, b, 1)
    indicator.icon:SetDesaturated(not reeling)
    indicator.key:SetText(GetBindingText(F.Get("key"), true))
    indicator:Show()
    if indicator:IsMouseOver() then EllesmereUI.ShowWidgetTooltip(indicator, IndicatorTip()) end
end

-------------------------------------------------------------------------------
--  The key and the double-click
-------------------------------------------------------------------------------
-- What the next press does (viaClick: the double-click's, which has its own
-- Apply Lure). Out of combat only.
local function UpdateCastButton(viaClick)
    if not castButton then return end
    if InCombatLockdown() then
        EllesmereUI.CombatQueue.Defer("FishingButton", UpdateCastButton)
        return
    end
    if not PoleInHand() then
        local pole = PoleInBags()
        if pole then
            castButton:SetAttribute("type", "item")
            castButton:SetAttribute("item", "item:" .. pole)
            return
        end
    elseif F.Get(viaClick and "clickLure" or "lure") and not GetWeaponEnchantInfo() then
        local lure = BestLure()
        if lure then
            castButton:SetAttribute("type", "macro")
            castButton:SetAttribute("macrotext", "/use item:" .. lure .. "\n/use " .. INVSLOT_MAINHAND)
            return
        end
    end
    castButton:SetAttribute("type", "spell")
    castButton:SetAttribute("spell", fishingID)
end

-- The key on the button (casts). Out of combat only.
local function BindCast()
    if not castButton then return end
    if InCombatLockdown() then
        EllesmereUI.CombatQueue.Defer("FishingBind", BindCast)
        return
    end
    ClearOverrideBindings(castButton)
    local key = F.Get("key")
    if key then SetOverrideBindingClick(castButton, true, key, BUTTON_NAME) end
end

local function StopReel()
    if not reeling then return end
    reeling = false
    BindCast()
    UpdateIndicator()
end

-- The right-click back to the game. Out of combat only.
local function Disarm()
    if clickArmed and not InCombatLockdown() then
        ClearOverrideBindings(clickOwner)
        clickArmed = false
        UpdateCastButton()  -- back to what the key does
    end
end

-------------------------------------------------------------------------------
--  Session
-------------------------------------------------------------------------------
local function Notify(on)
    local listeners = module.fishingListeners
    for i = 1, #listeners do listeners[i](on) end
end

local function StartSession()
    if ReelOn() then Hold("reel", REEL_CVARS) end
    if F.Get("sound") then Hold("sound", SOUND_CVARS) end
    if F.Get("autoLoot") then Hold("loot", LOOT_CVARS) end
    if inSession then return end
    inSession = true
    ev:RegisterEvent("PLAYER_STARTED_MOVING")
    if ReelOn() then ev:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED") end
    if F.Get("bagAlert") then
        ev:RegisterEvent("BAG_UPDATE_DELAYED")
        bagWarned = false
        CheckBags()
    end
    Notify(true)
end

-- loading: a loading screen is starting, the gear goes back after it
-- (PLAYER_ENTERING_WORLD).
local function EndSession(loading)
    StopReel()
    Release("reel")
    Release("sound")
    Release("loot")
    if loading then outfitTried = false else GearBack() end
    if not inSession then return end
    inSession = false
    ev:UnregisterEvent("PLAYER_STARTED_MOVING")
    ev:UnregisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
    ev:UnregisterEvent("BAG_UPDATE_DELAYED")
    Notify(false)
end

-- Built out of combat (the caller checks).
local function BuildButton()
    if castButton then return end
    castButton = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
    -- Acts on the release: the session starts just before a cast, and the
    -- double-click's second right-click casts as it comes up.
    castButton:RegisterForClicks("AnyUp", "AnyDown")
    castButton:SetAttribute("useOnKeyDown", false)
    castButton:Hide()
    -- The key's press sets what its release does (pole, lure or cast), out of
    -- combat; in combat the release does what was set last.
    castButton:SetScript("PreClick", function(self, _, down)
        if InCombatLockdown() then return end
        if down then
            -- The key's first press dresses in the outfit; the next one casts.
            if not clickArmed and WearOutfit() then
                self:SetAttribute("type", nil)
                return
            end
            -- An armed double-click keeps reading its own Apply Lure, not the key's.
            UpdateCastButton(clickArmed)
            if self:GetAttribute("type") == "item" then NoteGear(POLE_SLOTS) end
        elseif self:GetAttribute("type") == "spell" then
            StartSession()
        end
    end)
    castButton:SetScript("PostClick", function(_, _, down)
        if not down then Disarm() end
    end)
end

-- The safety net: no release reached the button within DISARM_DELAY of the
-- arming (an older timer finds a newer arming and leaves it).
local function DisarmLate()
    if clickArmed and GetTime() - armedAt >= DISARM_DELAY - 0.05 then Disarm() end
end

-- A second right-click on the world soon after the first: bound to the
-- button just for this click.
local function OnWorldMouseDown(_, button)
    if button ~= "RightButton" or not F.Get("doubleClick") or EllesmereUI.PadGamepadUI() then return end
    local now = GetTime()
    local double = now - lastRightClick < DOUBLE_CLICK_DELAY
    lastRightClick = double and 0 or now
    if not double or not castButton or InCombatLockdown() or UnitChannelInfo("player")
       or UnitExists("mouseover") or not PoleInHand() then
        return
    end
    UpdateCastButton(true)
    SetOverrideBindingClick(clickOwner, true, "BUTTON2", BUTTON_NAME)
    clickArmed = true
    armedAt = GetTime()
    C_Timer.After(DISARM_DELAY, DisarmLate)
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
ev:SetScript("OnEvent", function(_, event, _, arg2, arg3)
    if event == "PLAYER_SOFT_INTERACT_CHANGED" then
        -- arg2: the new soft interact target. The bobber with the line in the
        -- water: the key reels in. Anything else: it casts again.
        if InCombatLockdown() then return end
        if ReelOn() and lineOut and ObjectID(arg2) == BOBBER then
            if not reeling then
                reeling = true
                ClearOverrideBindings(castButton)
                SetOverrideBinding(castButton, true, F.Get("key"), "INTERACTTARGET")
                UpdateIndicator()
            end
        else
            StopReel()
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        -- arg3: the spell ID
        if not (fishingName and arg3) or issecretvalue(arg3) then return end
        if C_Spell.GetSpellName(arg3) == fishingName then
            lineOut = true
            StartSession()
            UpdateIndicator()
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        lineOut = false
        StopReel()
        UpdateIndicator()
    elseif event == "SPELLS_CHANGED" then
        ResolveFishing()
    elseif event == "BAG_UPDATE_DELAYED" then
        CheckBags()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- What a session left on when a loading screen ended it.
        if not inSession and not InCombatLockdown() then GearBack() end
    else
        -- PLAYER_STARTED_MOVING, PLAYER_REGEN_DISABLED (bindings can still
        -- change), PLAYER_LEAVING_WORLD
        if event == "PLAYER_REGEN_DISABLED" then
            ClearOverrideBindings(clickOwner)
            clickArmed = false
        end
        lineOut = false
        EndSession(event == "PLAYER_LEAVING_WORLD")
        UpdateIndicator()
    end
end)

local FEATURE_EVENTS = { "SPELLS_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_LEAVING_WORLD", "PLAYER_ENTERING_WORLD" }

-- Login and the options; takes effect immediately in both directions. The
-- button and the bindings only change out of combat: in combat the apply
-- waits for its end.
local booted = false
local function Apply()
    if InCombatLockdown() then
        EllesmereUI.CombatQueue.Defer("Fishing", Apply)
        return
    end
    if not booted then
        -- What a reload or a disconnect mid-session left held goes back.
        booted = true
        local held = F.Read().held
        if held then
            for set in pairs(held) do Release(set) end
        end
    end
    -- Put Gear Back turned off: nothing kept goes back any more.
    if F.Read().gear and not F.Get("gearBack") then F.Cfg().gear = nil end
    EndSession()
    Disarm()
    if castButton then ClearOverrideBindings(castButton) end
    UpdateIndicator()
    if not AnyOn() then
        ev:UnregisterAllEvents()
        return
    end
    BuildButton()
    ResolveFishing()
    if IndicatorOn() then BuildIndicator() end  -- placed in Unlock Mode before the first cast
    for i = 1, #FEATURE_EVENTS do ev:RegisterEvent(FEATURE_EVENTS[i]) end
    ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
    -- Never under the Gamepad interface style: a hook on a Blizzard frame
    -- there can run inside its secure navigation.
    if F.Get("doubleClick") and not worldHooked and not EllesmereUI.PadGamepadUI() then
        worldHooked = true
        WorldFrame:HookScript("OnMouseDown", OnWorldMouseDown)
    end
    UpdateCastButton()
    BindCast()
end

-- Options-page entry points.
EllesmereUI._Fishing = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply, {
    key = "EUI_FishingBobber", label = "Bobber Indicator", order = 60,
    shown = IndicatorOn,
    frame = function(build)
        if build then BuildIndicator() end
        return indicator
    end,
    size = function() return INDICATOR_SIZE, INDICATOR_SIZE end,
})
