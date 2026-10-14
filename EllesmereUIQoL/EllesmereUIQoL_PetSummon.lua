if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_PetSummon.lua
--  Auto Summon Pet: once the game takes the companion pet away (death,
--  loading screen, taxi, vehicle...), summons one again a moment later: a
--  random favorite, or any random pet while none is a favorite, as the
--  journal's random pet button. A pet the player dismisses stays dismissed
--  until they summon one again. Never in combat, dungeons, raids, PvP,
--  stealth or while mounted.
--
--  Favorites per Character (a per-character setting): this character picks
--  among its own favorites instead of the account's. They are chosen from a
--  pet's right-click menu in the Pet Journal and marked with a blue star in
--  its list. While it has none, the account's favorites are used.
--
--  Summoning is plain API, refused in combat only; it goes to the server, so
--  no Blizzard code runs inside our call. The player's own dismissals are
--  read from hooksecurefunc on the two dismiss calls. Events and hooks only
--  exist once the feature has been on.
-------------------------------------------------------------------------------
local ns = select(2, ...)
local DELAY = 2  -- seconds after a trigger: lets a load, landing or resurrection settle
local STAR = "PetJournal-FavoritesIcon"   -- the journal's favorite star, tinted blue below

-- Settings live on the shared EllesmereUIDB (lazy-init, never re-init at scope):
--   enabled                 Auto Summon Pet (off by default)
--   chars[player GUID]      own = Favorites per Character, favorites = { [pet GUID] = true }
local function PetCfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.petSummon = EllesmereUIDB.petSummon or {}
    return EllesmereUIDB.petSummon
end

local function IsEnabled()
    return PetCfg().enabled == true  -- default OFF
end

-- This character's settings; nil until written, unless create.
local function CharCfg(create)
    local cfg = PetCfg()
    local guid = UnitGUID("player")
    if not guid then return nil end
    if create then
        cfg.chars = cfg.chars or {}
        cfg.chars[guid] = cfg.chars[guid] or {}
    end
    return cfg.chars and cfg.chars[guid]
end

local function OwnOn()
    local c = CharCfg()
    return c ~= nil and c.own == true  -- default OFF
end

local function IsOwnFavorite(petGUID)
    local c = CharCfg()
    return petGUID ~= nil and c ~= nil and c.favorites ~= nil and c.favorites[petGUID] == true
end

local function SetOwnFavorite(petGUID, on)
    local c = CharCfg(true)
    c.favorites = c.favorites or {}
    c.favorites[petGUID] = on or nil
end

-- This character's favorites that can be summoned (empty: use the account's).
local function OwnFavorites()
    local list = {}
    local c = CharCfg()
    if not (c and c.own and c.favorites) then return list end
    for petGUID in pairs(c.favorites) do
        if C_PetJournal.PetIsSummonable(petGUID) then list[#list + 1] = petGUID end
    end
    return list
end

local ev = CreateFrame("Frame")
local timer
local hooked = false
local userDismissed = false  -- the player put the pet away themselves

local function CanSummonNow()
    if UnitIsDeadOrGhost("player") or UnitOnTaxi("player")
       or UnitInVehicle("player") or IsMounted() or IsStealthed() then
        return false
    end
    local _, kind = IsInInstance()
    return kind ~= "party" and kind ~= "raid" and kind ~= "pvp" and kind ~= "arena"
end

local Queue

-- Each blocker above has an event that queues again once it lifts; combat
-- waits for its end on the combat queue.
local function Summon()
    timer = nil
    if not IsEnabled() or userDismissed or C_PetJournal.GetSummonedPetGUID() then return end
    if InCombatLockdown() then
        ns.CombatQueue.Defer("PetSummon", Queue)
        return
    end
    if not CanSummonNow() then return end
    if UnitCastingInfo("player") or UnitChannelInfo("player") then
        Queue()
        return
    end
    local own = OwnFavorites()
    if #own > 0 then
        C_PetJournal.SummonPetByGUID(own[math.random(#own)])
    else
        -- As the journal's random pet button: all pets while none is a favorite.
        C_PetJournal.SummonRandomPet(C_PetJournal.HasFavoritePets())
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
    "UPDATE_STEALTH", "PLAYER_MOUNT_DISPLAY_CHANGED",
}

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "COMPANION_UPDATE" then
        if arg1 == "MOUNT" then return end
        if C_PetJournal.GetSummonedPetGUID() then
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

-------------------------------------------------------------------------------
--  Pet Journal: this character's favorites
-------------------------------------------------------------------------------
local function ShowsOwn() return IsEnabled() and OwnOn() end

-- The blue star on a list button, beside the journal's own.
local function MarkListButton(button)
    local drag = button and button.dragButton
    if not drag then return end
    local on = ShowsOwn() and IsOwnFavorite(button.petID)
    if on and not drag._euiCharStar then
        local star = drag:CreateTexture(nil, "OVERLAY", nil, 2)
        star:SetAtlas(STAR, true)
        star:SetVertexColor(0.45, 0.8, 1)
        star:SetPoint("TOPRIGHT", 8, 8)
        drag._euiCharStar = star
    end
    if drag._euiCharStar then drag._euiCharStar:SetShown(on) end
end

local function RefreshJournal()
    if PetJournal_UpdatePetList and PetJournal and PetJournal:IsShown() then PetJournal_UpdatePetList() end
end

-- A pet's right-click menu. The owner is its list button or the pet card,
-- whose petID is the owned pet's GUID, or the list button's icon, whose
-- parent holds it (PetJournal_ShowPetDropdown; the menu passes no context).
local function AddMenuEntry(owner, root)
    local petGUID = owner and (owner.petID or (owner.GetParent and owner:GetParent()
        and owner:GetParent().petID))
    if not (petGUID and ShowsOwn()) then return end
    root:CreateDivider()
    root:CreateCheckbox(EllesmereUI.L("Favorite for This Character"),
        function() return IsOwnFavorite(petGUID) end,
        function()
            SetOwnFavorite(petGUID, not IsOwnFavorite(petGUID))
            RefreshJournal()
        end)
end

local journalHooked = false
local function HookJournal()
    if journalHooked or not PetJournal_InitPetButton then return end
    journalHooked = true
    hooksecurefunc("PetJournal_InitPetButton", MarkListButton)
end

local function HookPetJournal()
    if Menu and Menu.ModifyMenu then
        Menu.ModifyMenu("MENU_PET_COLLECTION_PET", AddMenuEntry)
    end
    -- The journal loads on demand (Blizzard_Collections).
    if PetJournal_InitPetButton then
        HookJournal()
    else
        local f = CreateFrame("Frame")
        f:RegisterEvent("ADDON_LOADED")
        f:SetScript("OnEvent", function(self, _, name)
            if name ~= "Blizzard_Collections" then return end
            self:UnregisterAllEvents()
            HookJournal()
        end)
    end
end

-------------------------------------------------------------------------------
--  Apply
-------------------------------------------------------------------------------
-- Login and the options toggles; takes effect immediately in both directions.
local function ApplyPetSummon()
    if not C_PetJournal then return end
    RefreshJournal()
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
        HookPetJournal()
    end
    userDismissed = false
    Queue()
end
_G._EUI_ApplyPetSummon = ApplyPetSummon
-- Favorites per Character changed: only the journal's stars and menu follow.
_G._EUI_RefreshPetJournal = RefreshJournal

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if C_PetJournal and IsEnabled() then ApplyPetSummon() end
end)
