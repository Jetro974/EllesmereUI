if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_Requests.lua
--  Answers the requests nobody wants to read, each one an opt-in toggle:
--    Decline Duels, Decline Guild Invitations, Decline Group Invitations
--    (from anyone who is not a friend or a guild member) and Invite on
--    Whisper (whoever whispers the keyword is invited).
--
--  The game's own functions answer, the same ones its dialogs call. Nothing
--  is hooked and no Blizzard frame is written to: the popup left on screen is
--  closed with StaticPopup_Hide / StaticPopupSpecial_Hide. Events are
--  registered only while at least one toggle needs them.
--  Group Finder invitations (a role is offered) are always left to the player.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local IsSecret = EUI.IsSecret

local frame

local function Db()
    return EllesmereUIDB
end

-- A friend (character or Battle.net) or a guild member.
local function IsKnown(guid)
    if not guid or guid == "" or IsSecret(guid) then return false end
    if C_FriendList.IsFriend(guid) or IsGuildMember(guid) then return true end
    return C_BattleNet.GetGameAccountInfoByGUID(guid) ~= nil
end

local function OnEvent(_, event, ...)
    local db = Db()
    if not db then return end

    if event == "DUEL_REQUESTED" then
        if db.declineDuels then
            CancelDuel()
            StaticPopup_Hide("DUEL_REQUESTED")
        end

    elseif event == "GUILD_INVITE_REQUEST" then
        if db.declineGuildInvites then
            DeclineGuild()
            if GuildInviteFrame then StaticPopupSpecial_Hide(GuildInviteFrame) end
        end

    elseif event == "PARTY_INVITE_REQUEST" then
        if not db.declineGroupInvites then return end
        local _, tank, healer, damage, _, _, guid = ...
        if IsSecret(tank) or IsSecret(healer) or IsSecret(damage) then return end
        if tank or healer or damage then return end
        if IsKnown(guid) then return end
        DeclineGroup()
        StaticPopup_Hide("PARTY_INVITE")

    elseif event == "CHAT_MSG_WHISPER" then
        if not db.inviteOnWhisper then return end
        local text, sender = ...
        if IsSecret(text) or IsSecret(sender) or not text or not sender then return end
        local keyword = strtrim(db.inviteKeyword or "inv"):lower()
        if keyword == "" or strtrim(text):lower() ~= keyword then return end
        if db.inviteKnownOnly ~= false and not IsKnown(select(12, ...)) then return end
        -- Only a leader or an assistant invites into a group.
        if IsInGroup() and not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then return end
        C_PartyInfo.InviteUnit(sender)
    end
end

local function Apply()
    local db = Db()
    local anyOn = db and (db.declineDuels or db.declineGuildInvites or db.declineGroupInvites or db.inviteOnWhisper)
    if anyOn and not frame then
        frame = CreateFrame("Frame")
        frame:SetScript("OnEvent", OnEvent)
    end
    if not frame then return end
    local function Set(event, on)
        if on then frame:RegisterEvent(event) else frame:UnregisterEvent(event) end
    end
    Set("DUEL_REQUESTED", db and db.declineDuels)
    Set("GUILD_INVITE_REQUEST", db and db.declineGuildInvites)
    Set("PARTY_INVITE_REQUEST", db and db.declineGroupInvites)
    Set("CHAT_MSG_WHISPER", db and db.inviteOnWhisper)
end
EUI._applyRequests = Apply

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    Apply()
end)
