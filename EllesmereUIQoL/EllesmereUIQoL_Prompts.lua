if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_Prompts.lua
--  Answers three of the game's prompts for the player, each one an opt-in
--  toggle:
--    Accept Summons                 a warlock or mage summon is accepted
--    Release in Battlegrounds       dying in a battleground releases the spirit
--    Confirm Bind on Pickup Solo    no "will bind to you" box outside a group
--
--  The game's own functions answer, the same ones its dialogs call. Nothing
--  is hooked and no Blizzard frame is written to: the popup left on screen is
--  closed with StaticPopup_Hide. Events are registered only while the toggle
--  that needs them is on. A summon that arrives in combat, or while the game
--  would refuse it, is left to the player.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local IsSecret = EUI.IsSecret

local frame

local function OnEvent(_, event, ...)
    local db = EllesmereUIDB
    if not db then return end

    if event == "CONFIRM_SUMMON" then
        if not db.acceptSummons or InCombatLockdown() or not PlayerCanTeleport() then return end
        C_SummonInfo.ConfirmSummon()
        StaticPopup_Hide("CONFIRM_SUMMON")

    elseif event == "PLAYER_DEAD" then
        if not db.releaseInBG then return end
        local _, instanceType = IsInInstance()
        if instanceType ~= "pvp" or HasSoulstone() then return end
        RepopMe()

    elseif event == "LOOT_BIND_CONFIRM" then
        if not db.confirmBopSolo or IsInGroup() then return end
        local slot = ...
        if IsSecret(slot) or not slot then return end
        ConfirmLootSlot(slot)
        StaticPopup_Hide("LOOT_BIND")
    end
end

local function Apply()
    local db = EllesmereUIDB
    local anyOn = db and (db.acceptSummons or db.releaseInBG or db.confirmBopSolo)
    if anyOn and not frame then
        frame = CreateFrame("Frame")
        frame:SetScript("OnEvent", OnEvent)
    end
    if not frame then return end
    local function Set(event, on)
        if on then frame:RegisterEvent(event) else frame:UnregisterEvent(event) end
    end
    Set("CONFIRM_SUMMON", db and db.acceptSummons)
    Set("PLAYER_DEAD", db and db.releaseInBG)
    Set("LOOT_BIND_CONFIRM", db and db.confirmBopSolo)
end
EUI._applyPrompts = Apply

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    Apply()
end)
