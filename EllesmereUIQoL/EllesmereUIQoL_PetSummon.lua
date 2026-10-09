if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_PetSummon.lua
--  Keeps a companion pet out: once the game takes it away (death, loading
--  screen, taxi, vehicle...), summons one again a moment later, the last one
--  the player had out, a random favorite or any random pet. A pet the player
--  dismisses stays dismissed until they summon one again.
--
--  Summoning is plain API, refused in combat only; it goes to the server, so
--  no Blizzard code runs inside our call. The player's own dismissals are
--  read from hooksecurefunc on the two dismiss calls. Events and hooks only
--  exist once the feature has been on.
-------------------------------------------------------------------------------
local DELAY = 2  -- seconds after a trigger: lets a load, landing or resurrection settle

-- Settings live on the shared EllesmereUIDB (lazy-init, never re-init at scope).
local function PetCfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.petSummon = EllesmereUIDB.petSummon or {}
    return EllesmereUIDB.petSummon
end

local function IsEnabled()
    return PetCfg().enabled == true  -- default OFF
end

local ev = CreateFrame("Frame")
local timer
local hooked = false
local userDismissed = false  -- the player put the pet away themselves

local function CanSummonNow()
    if InCombatLockdown() or UnitIsDeadOrGhost("player") or UnitOnTaxi("player")
       or UnitInVehicle("player") or IsMounted() or IsStealthed() then
        return false
    end
    local _, kind = IsInInstance()
    if kind == "pvp" or kind == "arena" then return false end
    if (kind == "party" or kind == "raid" or kind == "scenario")
       and PetCfg().instances ~= true then
        return false
    end
    return true
end

local Queue

-- Each blocker above has an event that queues again once it lifts.
local function Summon()
    timer = nil
    if not IsEnabled() or userDismissed or C_PetJournal.GetSummonedPetGUID() then return end
    if not CanSummonNow() then return end
    if UnitCastingInfo("player") or UnitChannelInfo("player") then
        Queue()
        return
    end
    local cfg = PetCfg()
    if cfg.mode == "favorite" then
        -- As the journal's random pet button: all pets while none is a favorite.
        C_PetJournal.SummonRandomPet(C_PetJournal.HasFavoritePets())
    elseif cfg.mode == "random" then
        C_PetJournal.SummonRandomPet(false)
    else
        local guid = cfg.lastGUID
        if guid and C_PetJournal.PetIsSummonable(guid) then
            C_PetJournal.SummonPetByGUID(guid)
        end
    end
end

Queue = function()
    if timer then timer:Cancel() end
    timer = C_Timer.NewTimer(DELAY, Summon)
end

-- After which a missing pet may come back.
local EVENTS = {
    "COMPANION_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_ALIVE",
    "PLAYER_UNGHOST", "PLAYER_CONTROL_GAINED", "UNIT_EXITED_VEHICLE",
    "UPDATE_STEALTH", "PLAYER_MOUNT_DISPLAY_CHANGED", "PLAYER_REGEN_ENABLED",
}

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "COMPANION_UPDATE" then
        if arg1 == "MOUNT" then return end
        local guid = C_PetJournal.GetSummonedPetGUID()
        if guid then
            PetCfg().lastGUID = guid
            userDismissed = false
            return
        end
    elseif event == "UNIT_EXITED_VEHICLE" and arg1 ~= "player" then
        return
    end
    if not userDismissed then Queue() end
end)

-- The player's own dismissals: DismissSummonedPet, or SummonPetByGUID on the
-- pet already out (the journal's toggle). Post-hooks, so the pet still reads
-- as out here.
local function OnDismiss() userDismissed = true end
local function OnSummonByGUID(guid)
    if guid and guid == C_PetJournal.GetSummonedPetGUID() then userDismissed = true end
end

-- Login and the options toggle; takes effect immediately in both directions.
local function ApplyPetSummon()
    local on = IsEnabled()
    for i = 1, #EVENTS do
        if on then ev:RegisterEvent(EVENTS[i]) else ev:UnregisterEvent(EVENTS[i]) end
    end
    if not on then
        if timer then timer:Cancel(); timer = nil end
        return
    end
    if not hooked then
        hooked = true
        hooksecurefunc(C_PetJournal, "DismissSummonedPet", OnDismiss)
        hooksecurefunc(C_PetJournal, "SummonPetByGUID", OnSummonByGUID)
    end
    -- The pet out right now becomes the remembered one.
    local guid = C_PetJournal.GetSummonedPetGUID()
    if guid then PetCfg().lastGUID = guid end
    userDismissed = false
    Queue()
end
_G._EUI_ApplyPetSummon = ApplyPetSummon

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if IsEnabled() then ApplyPetSummon() end
end)
