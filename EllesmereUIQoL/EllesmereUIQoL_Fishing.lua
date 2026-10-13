if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_Fishing.lua
--  One-Button Fishing: one key of the player's choice does the whole loop.
--    - WoW Forever, no pole in the main hand: equips the best pole in the bags;
--    - WoW Forever, a pole with no lure (Apply Lure option): applies the best
--      lure in the bags;
--    - otherwise: casts Fishing;
--    - line in the water (Reel In option): once the game's soft interact
--      targets the bobber, the key interacts with it, which reels the line in.
--      The line out of the water, the key casts again.
--
--  Every action comes from a real key press: the key is an override binding
--  on a secure button, changed out of combat only. Reeling needs soft
--  interact on, so its CVars are held (EllesmereUI.HoldCVar) from the first
--  cast until the session ends (the player moves, enters combat or leaves the
--  world). The values from before are saved, so a reload mid-session puts
--  them back at the next login. The bobber must stay on screen: looking
--  away, soft interact targets something else and the key casts again.
--  Fishing is one spell by name on every client (ranks on WoW Forever), so
--  the channel is matched by name. Events, the button and the binding only
--  exist once a key has been set.
-------------------------------------------------------------------------------
local ns = select(2, ...)
local OWNER = "EllesmereUIQoL"
local BUTTON_NAME = "EllesmereUIFishingCastButton"

-- Fishing spells, most likely first: retail, then the WoW Forever ranks.
local FISHING_SPELLS = { 131474, 18248, 7732, 7731, 7620 }

-- Lures, best first (item ID): Aquadynamic Fish Attractor, Bright Baubles,
-- Flesh Eating Worm, Nightcrawlers, Aquadynamic Fish Lens, Shiny Bauble.
local LURES = { 6533, 6532, 7307, 6530, 6811, 6529 }

-- The bobber (game object ID).
local BOBBER = 35591

-- Soft interact on, wide and far enough to target the bobber by itself.
local REEL_CVARS = {
    SoftTargetInteract = "3",
    SoftTargetInteractRange = "30",
    SoftTargetInteractArc = "2",
    SoftTargetInteractRangeIsHard = "0",
}

-- Settings live on the shared EllesmereUIDB (lazy-init, never re-init at scope).
local function FishCfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.fishing = EllesmereUIDB.fishing or {}
    return EllesmereUIDB.fishing
end

local function ReelOn() return FishCfg().reel ~= false end  -- default ON
local function LureOn()                                      -- default ON, WoW Forever only
    return EllesmereUI.IS_FOREVER and FishCfg().lure ~= false
end

local ev = CreateFrame("Frame")
local castButton
local fishingID, fishingName  -- the Fishing spell known (nil: none)
local inSession = false
local reeling = false         -- the key is bound to Interact With Target

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

-- A fishing pole in the main hand (WoW Forever; retail keeps it elsewhere).
local function PoleInMainHand()
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

-- The game object ID in a "GameObject-0-...-35591-..." GUID, or nil.
local function ObjectID(guid)
    if not guid or (issecretvalue and issecretvalue(guid)) then return nil end
    return tonumber(guid:match("^GameObject%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
end

-------------------------------------------------------------------------------
--  The key
-------------------------------------------------------------------------------
-- What the next press does. Out of combat only.
local function UpdateCastButton()
    if not castButton then return end
    if InCombatLockdown() then
        ns.CombatQueue.Defer("FishingButton", UpdateCastButton)
        return
    end
    if EllesmereUI.IS_FOREVER then
        if not PoleInMainHand() then
            local pole = PoleInBags()
            if pole then
                castButton:SetAttribute("type", "item")
                castButton:SetAttribute("item", "item:" .. pole)
                return
            end
        elseif LureOn() and not GetWeaponEnchantInfo() then
            local lure = BestLure()
            if lure then
                castButton:SetAttribute("type", "macro")
                castButton:SetAttribute("macrotext", "/use item:" .. lure .. "\n/use " .. INVSLOT_MAINHAND)
                return
            end
        end
    end
    castButton:SetAttribute("type", "spell")
    castButton:SetAttribute("spell", fishingID)
end

-- The key on the button (casts). Out of combat only.
local function BindCast()
    if not castButton then return end
    if InCombatLockdown() then
        ns.CombatQueue.Defer("FishingBind", BindCast)
        return
    end
    ClearOverrideBindings(castButton)
    local key = FishCfg().key
    if key then SetOverrideBindingClick(castButton, true, key, BUTTON_NAME) end
end

local function StopReel()
    if not reeling then return end
    reeling = false
    BindCast()
end

-------------------------------------------------------------------------------
--  Session: soft interact held while fishing
-------------------------------------------------------------------------------
local function HoldReel()
    local cfg = FishCfg()
    if cfg.reelWas then return end
    local was = {}
    for name, value in pairs(REEL_CVARS) do
        local cur = C_CVar.GetCVar(name)
        if cur ~= nil and cur ~= value and EllesmereUI.HoldCVar(name, value, OWNER) then
            was[name] = cur
        end
    end
    cfg.reelWas = was
end

local function ReleaseReel()
    local cfg = FishCfg()
    local was = cfg.reelWas
    if not was then return end
    for name, value in pairs(was) do
        EllesmereUI.ReleaseCVar(name, value, OWNER)
    end
    cfg.reelWas = nil
end

local function StartSession()
    if ReelOn() then HoldReel() end
    if inSession then return end
    inSession = true
    ev:RegisterEvent("PLAYER_STARTED_MOVING")
    if ReelOn() then ev:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED") end
end

local function EndSession()
    StopReel()
    ReleaseReel()
    if not inSession then return end
    inSession = false
    ev:UnregisterEvent("PLAYER_STARTED_MOVING")
    ev:UnregisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
end

-- Built out of combat (the caller checks).
local function BuildButton()
    if castButton then return end
    castButton = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
    -- Acts on the key's release: the session starts just before a cast.
    castButton:RegisterForClicks("AnyUp", "AnyDown")
    castButton:SetAttribute("useOnKeyDown", false)
    castButton:Hide()
    castButton:SetScript("PreClick", function(self, _, down)
        if not down and self:GetAttribute("type") == "spell" and not InCombatLockdown() then
            StartSession()
        end
    end)
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "PLAYER_SOFT_INTERACT_CHANGED" then
        -- arg2: the new soft interact target. The bobber with the line in the
        -- water: the key reels in. Anything else: it casts again.
        if InCombatLockdown() then return end
        local key = FishCfg().key
        if key and ReelOn() and ObjectID(arg2) == BOBBER and UnitChannelInfo("player") then
            if not reeling then
                reeling = true
                ClearOverrideBindings(castButton)
                SetOverrideBinding(castButton, true, key, "INTERACTTARGET")
            end
        else
            StopReel()
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        -- arg3: the spell ID
        if not (fishingName and arg3) or (issecretvalue and issecretvalue(arg3)) then return end
        if C_Spell.GetSpellName(arg3) == fishingName then StartSession() end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        StopReel()
    elseif event == "SPELLS_CHANGED" then
        ResolveFishing()
        UpdateCastButton()
    elseif event == "UNIT_INVENTORY_CHANGED" or event == "BAG_UPDATE_DELAYED" then
        UpdateCastButton()
    else
        -- PLAYER_STARTED_MOVING, PLAYER_REGEN_DISABLED (bindings can still
        -- change), PLAYER_LEAVING_WORLD
        EndSession()
    end
end)

local FEATURE_EVENTS = { "SPELLS_CHANGED", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_DISABLED", "PLAYER_LEAVING_WORLD" }

-- Login and the options; takes effect immediately in both directions. The
-- button and the binding only change out of combat: in combat the apply
-- waits for its end.
local function ApplyFishing()
    if InCombatLockdown() then
        ns.CombatQueue.Defer("Fishing", ApplyFishing)
        return
    end
    EndSession()
    if castButton then ClearOverrideBindings(castButton) end
    if not FishCfg().key then
        ev:UnregisterAllEvents()
        return
    end
    BuildButton()
    ResolveFishing()
    for i = 1, #FEATURE_EVENTS do ev:RegisterEvent(FEATURE_EVENTS[i]) end
    ev:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
    ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
    UpdateCastButton()
    BindCast()
end
_G._EUI_ApplyFishing = ApplyFishing

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    -- What a reload or a disconnect mid-session left held goes back.
    ReleaseReel()
    if FishCfg().key then ApplyFishing() end
end)
