if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_Fishing.lua
--  Fishing helpers, each its own opt-in setting (all off by default):
--
--  Fishing Sounds   For a fishing session, music and ambience are muted and
--                   sound effects raised (kept on in the background); the
--                   previous values come back after it, through
--                   EllesmereUI.HoldCVar / ReleaseCVar, so a reload
--                   mid-session restores them at the next login.
--  Double-Click     Double right-click in the world casts Fishing, through a
--                   secure button and a one-shot override binding set out of
--                   combat only (WorldFrame:HookScript reads the clicks).
--                   On WoW Forever without a pole in hand, it equips the
--                   best pole in the bags first.
--  Lure Reminder    While fishing with a pole in the main hand and no lure on
--                   it (WoW Forever), a secure button applies the best lure
--                   in the bags. Retail has no pole in the main hand, so it
--                   never shows there.
--  Fishing Log      Fishing loot counted per zone; /euifish prints it with
--                   the fishing skill.
--
--  A session starts with a Fishing channel and ends when the player moves,
--  enters combat or changes zone. Fishing is one spell by name on every
--  client (ranks on WoW Forever, one spell plus a channel on retail), so the
--  channel is matched by name. Events, hooks and frames only exist once a
--  feature has been on.
-------------------------------------------------------------------------------
local OWNER = "EllesmereUIQoL"
local DOUBLE_CLICK_TIME = 0.4

-- Fishing spells, most likely first: retail, then the WoW Forever ranks.
local FISHING_SPELLS = { 131474, 18248, 7732, 7731, 7620 }

-- Lures, best first (item ID): Aquadynamic Fish Attractor, Bright Baubles,
-- Flesh Eating Worm, Aquadynamic Fish Lens, Nightcrawlers, Shiny Bauble.
local LURES = { 6533, 6532, 7307, 6811, 6530, 6529 }

-- The session's sound CVars and their values.
local SOUND_HOLDS = {
    { "Sound_EnableMusic", "0" },
    { "Sound_EnableAmbience", "0" },
    { "Sound_SFXVolume", "1" },
    { "Sound_EnableSoundWhenGameIsInBG", "1" },
}

-- Settings live on the shared EllesmereUIDB (lazy-init, never re-init at scope).
local function FishCfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.fishing = EllesmereUIDB.fishing or {}
    return EllesmereUIDB.fishing
end

local function On(key) return FishCfg()[key] == true end
local function AnyOn()
    return On("sound") or On("doubleClick") or On("lure") or On("log")
end

local ev = CreateFrame("Frame")
local fishingID, fishingName  -- the Fishing spell known (nil: none)
local inSession = false
local heldWas                  -- [cvar] = value before the session (nil: none held)
local castButton, lureButton   -- secure buttons, built out of combat on first use
local pendingBuild = false

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

-- A fishing pole in the main hand (WoW Forever; retail keeps it elsewhere).
local function PoleInMainHand()
    local id = GetInventoryItemID("player", INVSLOT_MAINHAND)
    if not id then return false end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
    return classID == Enum.ItemClass.Weapon and subClassID == Enum.ItemWeaponSubclass.Fishingpole
end

-- The best fishing pole in the bags (highest item level), or nil.
local function PoleInBags()
    local best, bestLevel
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id then
                local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
                if classID == Enum.ItemClass.Weapon and subClassID == Enum.ItemWeaponSubclass.Fishingpole then
                    local level = select(4, C_Item.GetItemInfo(id)) or 0
                    if not best or level > bestLevel then best, bestLevel = id, level end
                end
            end
        end
    end
    return best
end

-- Fishing can be cast: WoW Forever needs the pole in the main hand.
local function CanFish()
    if not fishingID then return false end
    if EllesmereUI.IS_FOREVER then return PoleInMainHand() end
    return true
end

local function IsFishingChannel()
    local name = UnitChannelInfo("player")
    return fishingName ~= nil and name == fishingName
end

-------------------------------------------------------------------------------
--  Fishing Sounds
-------------------------------------------------------------------------------
local function HoldSounds()
    if heldWas then return end
    heldWas = {}
    for i = 1, #SOUND_HOLDS do
        local name, value = SOUND_HOLDS[i][1], SOUND_HOLDS[i][2]
        local cur = C_CVar.GetCVar(name)
        if cur ~= nil and cur ~= value then
            heldWas[name] = cur
            EllesmereUI.HoldCVar(name, value, OWNER)
        end
    end
end

local function ReleaseSounds()
    if not heldWas then return end
    for name, was in pairs(heldWas) do
        EllesmereUI.ReleaseCVar(name, was, OWNER)
    end
    heldWas = nil
end

-------------------------------------------------------------------------------
--  Secure buttons (Double-Click cast, Lure Reminder)
-------------------------------------------------------------------------------
local function BestLure()
    for i = 1, #LURES do
        if C_Item.GetItemCount(LURES[i]) > 0 then return LURES[i] end
    end
end

local function UpdateLureButton()
    if not lureButton or InCombatLockdown() then return end
    local show = false
    if On("lure") and inSession and PoleInMainHand() and not GetWeaponEnchantInfo() then
        local lure = BestLure()
        if lure then
            show = true
            lureButton:SetAttribute("macrotext",
                "/use item:" .. lure .. "\n/use " .. INVSLOT_MAINHAND)
            lureButton.icon:SetTexture(C_Item.GetItemIconByID(lure))
            lureButton.count:SetText(C_Item.GetItemCount(lure))
        end
    end
    lureButton:SetShown(show)
end

local function BuildButtons()
    if InCombatLockdown() then
        pendingBuild = true
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingBuild = false
    if not castButton then
        castButton = CreateFrame("Button", "EllesmereUIFishingCastButton", UIParent,
            "SecureActionButtonTemplate")
        castButton:RegisterForClicks("AnyUp", "AnyDown")
        castButton:SetAttribute("type", "spell")
        castButton:Hide()
        -- One cast per double-click: the binding goes as soon as it fired.
        castButton:SetScript("PostClick", function()
            if not InCombatLockdown() then ClearOverrideBindings(castButton) end
        end)
    end
    if not lureButton then
        lureButton = CreateFrame("Button", "EllesmereUIFishingLureButton", UIParent,
            "SecureActionButtonTemplate")
        lureButton:RegisterForClicks("AnyUp", "AnyDown")
        lureButton:SetAttribute("type", "macro")
        lureButton:SetSize(40, 40)
        lureButton:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
        lureButton.icon = lureButton:CreateTexture(nil, "ARTWORK")
        lureButton.icon:SetAllPoints()
        lureButton.count = lureButton:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        lureButton.count:SetPoint("BOTTOMRIGHT", -2, 2)
        local label = lureButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOP", lureButton, "BOTTOM", 0, -4)
        label:SetText(EllesmereUI.L("Apply Lure"))
        lureButton:Hide()
    end
end

-- Double right-click: the first press arms nothing; a second one within
-- DOUBLE_CLICK_TIME binds the right button to the cast button, so its
-- release casts Fishing. On WoW Forever without a pole in hand, it equips
-- the best pole in the bags instead; the next double-click fishes.
local lastRightDown = 0
local function OnWorldMouseDown(_, button)
    if button ~= "RightButton" or not On("doubleClick") or not castButton then return end
    local now = GetTime()
    local double = now - lastRightDown < DOUBLE_CLICK_TIME
    lastRightDown = double and 0 or now
    if not double or InCombatLockdown() or IsMounted() or IsFishingChannel()
       or not fishingID then
        return
    end
    if CanFish() then
        castButton:SetAttribute("type", "spell")
        castButton:SetAttribute("spell", fishingID)
    else
        local pole = EllesmereUI.IS_FOREVER and PoleInBags()
        if not pole then return end
        castButton:SetAttribute("type", "item")
        castButton:SetAttribute("item", "item:" .. pole)
    end
    SetOverrideBindingClick(castButton, true, "BUTTON2", castButton:GetName())
    -- A release that never reaches the button (over a window) must not leave
    -- the right button casting Fishing.
    C_Timer.After(1, function()
        if not InCombatLockdown() then ClearOverrideBindings(castButton) end
    end)
end

local worldHooked = false
local function HookWorld()
    if worldHooked then return end
    worldHooked = true
    WorldFrame:HookScript("OnMouseDown", OnWorldMouseDown)
end

-------------------------------------------------------------------------------
--  Fishing Log
-------------------------------------------------------------------------------
local function RecordLoot()
    if not IsFishingLoot() then return end
    local cfg = FishCfg()
    local log = cfg.catches
    if not log then log = { total = 0, zones = {} }; cfg.catches = log end
    local mapID = C_Map.GetBestMapForUnit("player") or 0
    local zone = log.zones[mapID]
    if not zone then zone = {}; log.zones[mapID] = zone end
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local itemID = link and C_Item.GetItemInfoInstant(link)
        if itemID then
            local _, _, quantity = GetLootSlotInfo(slot)
            quantity = quantity or 1
            zone[itemID] = (zone[itemID] or 0) + quantity
            log.total = log.total + quantity
        end
    end
end

-- Fishing skill: the profession API where it exists, the skill lines else.
local function FishingSkill()
    if GetProfessions then
        local _, _, _, fishing = GetProfessions()
        if fishing then
            local name, _, rank, maxRank = GetProfessionInfo(fishing)
            return name, rank, maxRank
        end
    end
    if not GetNumSkillLines then return end
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        if not isHeader and name == fishingName then return name, rank, maxRank end
    end
end

local PREFIX = "|cff0CD29DEllesmereUI:|r "

local function PrintLog()
    local say = EllesmereUI.Print
    local name, rank, maxRank = FishingSkill()
    if name then say(PREFIX .. name .. " " .. rank .. "/" .. maxRank) end
    local log = FishCfg().catches
    if not log or log.total == 0 then
        say(PREFIX .. EllesmereUI.L("No catch recorded yet."))
        return
    end
    say(PREFIX .. EllesmereUI.Lf("%1$d fish and items caught.", log.total))
    for mapID, items in pairs(log.zones) do
        local info = C_Map.GetMapInfo(mapID)
        say("   |cffffd100" .. (info and info.name or "?") .. "|r")
        for itemID, count in pairs(items) do
            local itemName = C_Item.GetItemNameByID(itemID) or ("item:" .. itemID)
            say("      " .. count .. " x " .. itemName)
        end
    end
end

SLASH_EUIFISH1 = "/euifish"
SlashCmdList["EUIFISH"] = function(msg)
    if strtrim(msg or ""):lower() == "reset" then
        FishCfg().catches = nil
        EllesmereUI.Print(PREFIX .. EllesmereUI.L("Fishing log cleared."))
        return
    end
    PrintLog()
end

-------------------------------------------------------------------------------
--  Session and events
-------------------------------------------------------------------------------
local function EndSession()
    if not inSession then return end
    inSession = false
    ev:UnregisterEvent("PLAYER_STARTED_MOVING")
    ReleaseSounds()
    UpdateLureButton()
end

local function StartSession()
    if inSession then
        UpdateLureButton()
        return
    end
    inSession = true
    ev:RegisterEvent("PLAYER_STARTED_MOVING")
    if On("sound") then HoldSounds() end
    UpdateLureButton()
end

ev:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        if fishingName and spellID and C_Spell.GetSpellName(spellID) == fishingName then
            StartSession()
        end
    elseif event == "LOOT_OPENED" then
        if On("log") then RecordLoot() end
    elseif event == "SPELLS_CHANGED" then
        ResolveFishing()
    elseif event == "UNIT_INVENTORY_CHANGED" or event == "BAG_UPDATE_DELAYED" then
        UpdateLureButton()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingBuild then BuildButtons() end
        if not pendingBuild then ev:UnregisterEvent("PLAYER_REGEN_ENABLED") end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Before lockdown: the lure button can still be hidden.
        if lureButton then lureButton:Hide() end
        EndSession()
    else
        -- PLAYER_STARTED_MOVING, PLAYER_LEAVING_WORLD
        EndSession()
    end
end)

local FEATURE_EVENTS = { "SPELLS_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_LEAVING_WORLD" }

-- Login and the options toggles; takes effect immediately in both directions.
local function ApplyFishing()
    if not AnyOn() then
        EndSession()
        ev:UnregisterAllEvents()
        if castButton and not InCombatLockdown() then ClearOverrideBindings(castButton) end
        return
    end
    ResolveFishing()
    ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    for i = 1, #FEATURE_EVENTS do ev:RegisterEvent(FEATURE_EVENTS[i]) end
    if On("log") then ev:RegisterEvent("LOOT_OPENED") else ev:UnregisterEvent("LOOT_OPENED") end
    if On("lure") then
        ev:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
        ev:RegisterEvent("BAG_UPDATE_DELAYED")
    else
        ev:UnregisterEvent("UNIT_INVENTORY_CHANGED")
        ev:UnregisterEvent("BAG_UPDATE_DELAYED")
    end
    if On("doubleClick") or On("lure") then BuildButtons() end
    if On("doubleClick") then HookWorld() end
    if not On("sound") then ReleaseSounds() elseif inSession then HoldSounds() end
    UpdateLureButton()
end
_G._EUI_ApplyFishing = ApplyFishing

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if AnyOn() then ApplyFishing() end
end)
