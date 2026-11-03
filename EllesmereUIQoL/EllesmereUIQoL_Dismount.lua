if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_Dismount.lua
--  Dismount When Needed: when the game refuses an action because the player
--  is mounted (a spell, gathering, an attack, a flight path), the player gets
--  off the mount. Never while flying, and never in combat.
--
--  The refusal is read from UI_ERROR_MESSAGE and matched against the game's
--  own "you are mounted" texts (so any client language works). A secret
--  message is ignored. UI_ERROR_MESSAGE is registered only while the toggle
--  is on.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local IsSecret = EUI.IsSecret

local frame
local mountedTexts

local function BuildTexts()
    mountedTexts = {}
    for _, key in ipairs({ "ERR_ATTACK_MOUNTED", "ERR_NOT_WHILE_MOUNTED",
        "ERR_TAXIPLAYERALREADYMOUNTED", "SPELL_FAILED_NOT_MOUNTED" }) do
        local text = _G[key]
        if type(text) == "string" then mountedTexts[text] = true end
    end
end

local function OnEvent(_, _, _, message)
    if IsSecret(message) or not mountedTexts[message] then return end
    if InCombatLockdown() or not IsMounted() or IsFlying() then return end
    Dismount()
end

local function Apply()
    local on = EllesmereUIDB and EllesmereUIDB.dismountWhenNeeded
    if on and not frame then
        BuildTexts()
        frame = CreateFrame("Frame")
        frame:SetScript("OnEvent", OnEvent)
    end
    if not frame then return end
    if on then
        frame:RegisterEvent("UI_ERROR_MESSAGE")
    else
        frame:UnregisterEvent("UI_ERROR_MESSAGE")
    end
end
EUI._applyDismount = Apply

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    Apply()
end)
