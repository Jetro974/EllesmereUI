if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_AccountIgnore.lua
--  Account Ignore List, off by default (EllesmereUIDB.accountIgnore): one
--  ignore list for every character, of any length, that blocks on its own.
--
--  A player on it is blocked on every character, whatever the game's own list
--  (per character, 50 names) holds:
--   - their chat lines are hidden: whispers, say, yell, emotes, channels,
--     party, raid and instance chat (guild and officer chat are left alone);
--   - their group invites, guild invites, duels and trades are declined.
--  The game's list feeds it: a player ignored through the game (the Ignore
--  window, a right click, /ignore) joins it, also once the game's list is
--  full; one removed from the game's list leaves it. Nothing is written onto
--  the game's lists; a player removed from the account list leaves the game's
--  list of each character as it logs in (EllesmereUIDB.accountIgnore.gone).
--  Warn About Ignored Players (EllesmereUIDB.ignoredAlertEnabled) shows an
--  EllesmereUIQoL_Alerts line when someone on the list invites you (the
--  invite is still declined) or is in your group.
--
--  Taint: nothing of Blizzard's is written. The chat filter only returns true
--  for a line to hide; the declines call the game's own functions from our
--  event handlers; the two hooks only read the name of a request. A secret
--  name is never judged. While off, no event is registered and the filter and
--  hooks return on their first line.
-------------------------------------------------------------------------------
local EUI = EllesmereUI

-- Reading never creates the table, so nothing is saved while unused.
local EMPTY = {}
local function Cfg()
    local db = EllesmereUIDB
    return db and db.accountIgnore or EMPTY
end
local function CfgW()
    local db = EllesmereUIDB
    db.accountIgnore = db.accountIgnore or {}
    local c = db.accountIgnore
    c.list = c.list or {}  -- key = time it was added
    c.gone = c.gone or {}  -- key = time it was removed from the account list
    return c
end
local function Enabled() return Cfg().enabled == true end
local function AlertOn() return Enabled() and EllesmereUIDB.ignoredAlertEnabled == true end

local ev = CreateFrame("Frame")
local seen             -- the game list at the last read; nil until the first this session
local hooked, filtered
local warned = {}      -- group members already warned about
local listeners = {}   -- called when the list changes (the Ignore window's panel)

local function IsSecret(v) return issecretvalue and issecretvalue(v) end

-------------------------------------------------------------------------------
--  Names: "Name-Realm" on the list
-------------------------------------------------------------------------------
-- nil: nothing usable (secret, or a name the game has not resolved).
local function Key(name, realm)
    if IsSecret(name) or IsSecret(realm) or type(name) ~= "string" or name == ""
       or name == UNKNOWNOBJECT or name == UNKNOWN then
        return
    end
    if type(realm) == "string" and realm ~= "" then return name .. "-" .. realm:gsub("[%s%-]", "") end
    if name:find("-", 1, true) then return name end
    local own = GetNormalizedRealmName()
    return own and (name .. "-" .. own)
end

-- A typed name as the game writes it.
local function FromTyped(text)
    if IsSecret(text) or type(text) ~= "string" then return end
    local name, realm = strtrim(text):match("^([^-]+)%-?(.*)$")
    if not name then return end
    return Key(name:sub(1, 1):upper() .. name:sub(2):lower(), realm)
end

local function Split(key)
    return key:match("^(.-)%-(.+)$")
end

-- What the game takes: the plain name on this character's realm.
local function GameName(key)
    local name, realm = Split(key)
    return realm == GetNormalizedRealmName() and name or key
end

local function Listed(key)
    return key ~= nil and Enabled() and (Cfg().list or EMPTY)[key] ~= nil
end

local function Changed()
    for _, fn in ipairs(listeners) do fn() end
end

-------------------------------------------------------------------------------
--  The game's list feeds the account list
-------------------------------------------------------------------------------
-- The game list by key. nil: a name has not resolved yet.
local function ReadGameList()
    local list = {}
    for i = 1, C_FriendList.GetNumIgnores() or 0 do
        local key = Key(C_FriendList.GetIgnoreName(i))
        if not key then return end
        list[key] = true
    end
    return list
end

local function Sync()
    if not Enabled() then return end
    local game = ReadGameList()
    if not game then return end   -- the next update reads it again
    local c, now, changed = CfgW(), GetServerTime(), false
    for key in pairs(game) do
        if not c.list[key] then
            if c.gone[key] and not (seen and not seen[key]) then
                -- Removed from the account list while this character still
                -- held it: it leaves this character's list too.
                C_FriendList.DelIgnore(GameName(key))
            else
                -- Just ignored through the game.
                c.list[key] = now
                c.gone[key] = nil
                changed = true
            end
        end
    end
    -- One name gone at once is the player's removal; several at once is the
    -- game reloading its list.
    if seen then
        local lost, lostCount = nil, 0
        for key in pairs(seen) do
            if not game[key] then lost, lostCount = key, lostCount + 1 end
        end
        if lostCount == 1 and c.list[lost] then
            c.list[lost] = nil
            c.gone[lost] = now
            changed = true
        end
    end
    seen = game
    if changed then Changed() end
end

-- The options' and the panel's way in.
local function SetListed(key, on)
    if not key then return end
    local c = CfgW()
    if on then
        c.list[key] = c.list[key] or GetServerTime()
        c.gone[key] = nil
    else
        c.list[key] = nil
        c.gone[key] = GetServerTime()
        -- Off the game's list of this character too, or the next read brings it back.
        if seen and seen[key] then
            seen[key] = nil
            C_FriendList.DelIgnore(GameName(key))
        end
    end
    Changed()
end

local function AddTyped(text)
    local key = FromTyped(text)
    if key and key ~= Key(UnitFullName("player")) then SetListed(key, true) end
end

-- The game refuses a name once its list is full and sends no update, so the
-- account list takes it from the request.
local function OnIgnoreRequest(name)
    if not Enabled() or (C_FriendList.GetNumIgnores() or 0) < 50 then return end
    local key = FromTyped(name)
    if not key or (Cfg().list or EMPTY)[key] then return end
    SetListed(key, true)
    UIErrorsFrame:AddMessage(EllesmereUI.Lf("%s added to your account ignore list.", (Split(key))), 1, 0.82, 0, 1)
end

-------------------------------------------------------------------------------
--  Blocking
-------------------------------------------------------------------------------
local CHAT_EVENTS = {
    "CHAT_MSG_WHISPER", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE",
    "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_CHANNEL", "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
}

local function ChatFilter(_, _, _, author)
    if not Enabled() or IsSecret(author) then return false end
    return Listed(Key(author))
end

local function InstallFilter()
    if filtered then return end
    filtered = true
    for _, e in ipairs(CHAT_EVENTS) do ChatFrame_AddMessageEventFilter(e, ChatFilter) end
end

-------------------------------------------------------------------------------
--  Alert
-------------------------------------------------------------------------------
local function Warn(key)
    EUI.Alerts.Line("ignored").Show(EllesmereUI.Lf("%s is on your ignore list", (Split(key))), 1, 0.25, 0.25)
end

-- Once per stay in the group.
local function CheckGroup()
    if not (AlertOn() and IsInGroup()) then
        wipe(warned)
        return
    end
    local raid = IsInRaid()
    local present = {}
    for i = 1, raid and GetNumGroupMembers() or GetNumSubgroupMembers() do
        local key = Key(UnitFullName((raid and "raid" or "party") .. i))
        if Listed(key) then
            present[key] = true
            if not warned[key] then Warn(key) end
        end
    end
    warned = present
end

-------------------------------------------------------------------------------
--  Events and live apply
-------------------------------------------------------------------------------
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "IGNORELIST_UPDATE" then
        Sync()
    elseif event == "GROUP_ROSTER_UPDATE" then
        CheckGroup()
    elseif event == "PARTY_INVITE_REQUEST" then
        local key = Key((...))
        if Listed(key) then
            DeclineGroup()
            StaticPopup_Hide("PARTY_INVITE")
            if AlertOn() then Warn(key) end
        end
    elseif event == "GUILD_INVITE_REQUEST" then
        if Listed(Key((...))) then
            DeclineGuild()
            StaticPopup_Hide("GUILD_INVITE")
        end
    elseif event == "DUEL_REQUESTED" then
        if Listed(Key((...))) then
            CancelDuel()
            StaticPopup_Hide("DUEL_REQUESTED")
        end
    elseif event == "TRADE_SHOW" then
        if Listed(Key(UnitFullName("NPC"))) then CancelTrade() end
    elseif event == "PLAYER_LOGIN" then
        ev:UnregisterEvent(event)
        Sync()
        CheckGroup()
    end
end)

local EVENTS = { "IGNORELIST_UPDATE", "PARTY_INVITE_REQUEST", "GUILD_INVITE_REQUEST",
    "DUEL_REQUESTED", "TRADE_SHOW" }

local function Apply()
    local on = Enabled()
    for _, e in ipairs(EVENTS) do
        if on then ev:RegisterEvent(e) else ev:UnregisterEvent(e) end
    end
    if AlertOn() then ev:RegisterEvent("GROUP_ROSTER_UPDATE") else ev:UnregisterEvent("GROUP_ROSTER_UPDATE") end
    if on then
        InstallFilter()
        if not hooked then
            hooked = true
            hooksecurefunc(C_FriendList, "AddIgnore", OnIgnoreRequest)
            hooksecurefunc(C_FriendList, "AddOrDelIgnore", OnIgnoreRequest)
        end
        if IsLoggedIn() then Sync() end
    else
        seen = nil
    end
    if IsLoggedIn() then CheckGroup() end
    Changed()
end

local function SetEnabled(on)
    local c = CfgW()
    c.enabled = on or nil
    c.fails = nil   -- left by the first version of this list
    Apply()
end

-------------------------------------------------------------------------------
--  Entry points: the options and the Ignore window's panel
-------------------------------------------------------------------------------
-- Every listed player, sorted by realm then name.
local function Entries()
    local out = {}
    for key in pairs(Cfg().list or EMPTY) do
        local name, realm = Split(key)
        out[#out + 1] = { key = key, name = name or key, realm = realm or "" }
    end
    table.sort(out, function(a, b)
        if a.realm ~= b.realm then return a.realm < b.realm end
        return a.name < b.name
    end)
    return out
end

-- The options' checkbox dropdown: a header per realm.
local function Items()
    local items, lastRealm = {}, nil
    for _, e in ipairs(Entries()) do
        if e.realm ~= lastRealm then
            lastRealm = e.realm
            items[#items + 1] = { isHeader = true, label = e.realm }
        end
        items[#items + 1] = { key = e.key, label = e.name }
    end
    return items
end

EUI._AccountIgnore = {
    Enabled = Enabled,
    SetEnabled = SetEnabled,
    Apply = Apply,
    Items = Items,
    Entries = Entries,
    OwnRealm = function() return GetNormalizedRealmName() end,
    IsListed = function(key) return (Cfg().list or EMPTY)[key] ~= nil end,
    SetListed = SetListed,
    AddTyped = AddTyped,
    OnChange = function(fn) listeners[#listeners + 1] = fn end,
}

Apply()
if Enabled() and not IsLoggedIn() then ev:RegisterEvent("PLAYER_LOGIN") end
