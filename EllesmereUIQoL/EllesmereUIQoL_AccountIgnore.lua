if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_AccountIgnore.lua
--  Account Ignore List, off by default (EllesmereUIDB.accountIgnore): one list
--  for every character, of any length.
--
--  The game's own list, per character and capped, is what blocks a player, so
--  this file only feeds it:
--   - a name ignored or removed on one character reaches the others at their
--     next login. A removal stays in gone, or a character still holding the
--     name would bring it back.
--   - a name that no longer fits stays on the account list. It blocks nothing
--     on that character, but the alert still sees it.
--   - a character's own names are never dropped to make room.
--  Warn About Ignored Players (EllesmereUIDB.ignoredAlertEnabled) shows an
--  EllesmereUIQoL_Alerts line when someone on the list invites you or is in
--  your group. Chat is never filtered.
--
--  Taint: nothing of Blizzard's is written. The two hooks only read the name
--  of a request, and exist from the first enable on. While off, no event is
--  registered and the hooks return on their first line.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local NATIVE_CAP = 50  -- the game's limit per character
local MAX_TRIES = 3    -- logins a name is tried on a character before it is left alone
local SETTLE = 5       -- seconds after login before an empty list counts as read

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
    c.gone = c.gone or {}  -- key = time it was removed
    return c
end
local function Enabled() return Cfg().enabled == true end
local function AlertOn() return Enabled() and EllesmereUIDB.ignoredAlertEnabled == true end

local ev = CreateFrame("Frame")
local seen             -- the game list at the last read; nil until the first this session
local fed              -- the account list reached this character this session
local settled          -- the login settle has passed: an empty list is really empty
local hooked
local warned = {}      -- group members already warned about

local function IsSecret(v) return issecretvalue and issecretvalue(v) end

-------------------------------------------------------------------------------
--  Names: "Name-Realm" on every list
-------------------------------------------------------------------------------
-- nil: nothing usable yet (secret, or a name the game has not resolved).
local function Key(name, realm)
    if IsSecret(name) or IsSecret(realm) or type(name) ~= "string" or name == ""
       or name == UNKNOWNOBJECT or name == UNKNOWN then
        return
    end
    if realm and realm ~= "" then return name .. "-" .. realm end
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

-------------------------------------------------------------------------------
--  Sync with the game's list
-------------------------------------------------------------------------------
-- The game list by key and its size. nil: a name has not resolved yet.
local function ReadGameList()
    local count, list = C_FriendList.GetNumIgnores() or 0, {}
    for i = 1, count do
        local key = Key(C_FriendList.GetIgnoreName(i))
        if not key then return end
        list[key] = true
    end
    return list, count
end

-- Names that never landed on this character, so they stop being retried.
local function Fails(write)
    local c, guid = Cfg(), UnitGUID("player")
    local byChar = c.fails
    if write and not byChar then
        byChar = {}
        c.fails = byChar
    end
    if not byChar then return EMPTY end
    if write and not byChar[guid] then byChar[guid] = {} end
    return byChar[guid] or EMPTY
end

local function ClearFails(game)
    local fails = Fails()
    if fails == EMPTY then return end
    for key in pairs(game) do fails[key] = nil end
    if not next(fails) then Cfg().fails[UnitGUID("player")] = nil end
end

-- The account list onto this character: what was removed elsewhere goes, then
-- what fits comes in, newest first.
local function Feed(game, count)
    local c = CfgW()
    for key in pairs(game) do
        if c.gone[key] then
            C_FriendList.DelIgnore(GameName(key))
            count = count - 1
        end
    end
    local free = NATIVE_CAP - count
    if free <= 0 then return end

    local me, fails = Key(UnitFullName("player")), Fails()
    local wanted = {}
    for key in pairs(c.list) do
        if not game[key] and key ~= me and (fails[key] or 0) < MAX_TRIES
           and not C_FriendList.GetFriendInfo(GameName(key)) then
            wanted[#wanted + 1] = key
        end
    end
    if #wanted == 0 then return end
    table.sort(wanted, function(a, b) return c.list[a] > c.list[b] end)
    fails = Fails(true)
    for i = 1, math.min(free, #wanted) do
        local key = wanted[i]
        fails[key] = (fails[key] or 0) + 1
        C_FriendList.AddIgnore(GameName(key))
    end
end

local function Sync()
    if not Enabled() then return end
    local game, count = ReadGameList()
    if not game then return end                  -- the next update reads it again
    if not seen and count == 0 and not settled then return end

    local c, now = CfgW(), GetServerTime()
    if seen then
        -- One name lost is the player's choice; several at once is the game
        -- reloading its list.
        local lost, lostCount = nil, 0
        for key in pairs(seen) do
            if not game[key] then lost, lostCount = key, lostCount + 1 end
        end
        if lostCount == 1 then
            c.list[lost] = nil
            c.gone[lost] = now
        end
        for key in pairs(game) do
            if not seen[key] then
                c.list[key] = c.list[key] or now
                c.gone[key] = nil
            end
        end
    else
        -- First read: nothing can be taken for a removal yet.
        for key in pairs(game) do
            if not c.list[key] and not c.gone[key] then c.list[key] = now end
        end
    end
    ClearFails(game)
    seen = game

    if not fed then
        fed = true
        Feed(game, count)
    end
end

-- The options' way in: on the list or not, on this character at once.
local function SetListed(key, on)
    local c = CfgW()
    if on then
        c.list[key] = GetServerTime()
        c.gone[key] = nil
        if seen and not seen[key] and (C_FriendList.GetNumIgnores() or 0) < NATIVE_CAP then
            C_FriendList.AddIgnore(GameName(key))
        end
    else
        c.list[key] = nil
        c.gone[key] = GetServerTime()
        if seen and seen[key] then C_FriendList.DelIgnore(GameName(key)) end
    end
end

local function AddTyped(text)
    local key = FromTyped(text)
    if key and key ~= Key(UnitFullName("player")) then SetListed(key, true) end
end

-- The game refuses a name once its list is full and sends no update, so the
-- account list takes it from the request.
local function OnIgnoreRequest(name)
    if not Enabled() or (C_FriendList.GetNumIgnores() or 0) < NATIVE_CAP then return end
    local key = FromTyped(name)
    if not key or (seen and seen[key]) or Cfg().list[key] then return end
    SetListed(key, true)
    UIErrorsFrame:AddMessage(EllesmereUI.Lf("%s kept on your account ignore list.", (Split(key))), 1, 0.82, 0, 1)
end

-------------------------------------------------------------------------------
--  Alert
-------------------------------------------------------------------------------
local function Warn(key)
    EUI.Alerts.Line("ignored").Show(EllesmereUI.Lf("%s is on your ignore list", (Split(key))), 1, 0.25, 0.25)
end

-- Once per stay in the group.
local function CheckGroup()
    local list = Cfg().list
    if not (list and IsInGroup()) then
        wipe(warned)
        return
    end
    local raid = IsInRaid()
    local present = {}
    for i = 1, raid and GetNumGroupMembers() or GetNumSubgroupMembers() do
        local key = Key(UnitFullName((raid and "raid" or "party") .. i))
        if key and list[key] then
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
        local key, list = Key((...)), Cfg().list
        if key and list and list[key] then Warn(key) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        ev:UnregisterEvent(event)
        C_Timer.After(SETTLE, function()
            settled = true
            Sync()
        end)
    end
end)

local function SetEvent(event, on)
    if on then ev:RegisterEvent(event) else ev:UnregisterEvent(event) end
end

local function Apply()
    local on, alert = Enabled(), AlertOn()
    SetEvent("IGNORELIST_UPDATE", on)
    SetEvent("GROUP_ROSTER_UPDATE", alert)
    SetEvent("PARTY_INVITE_REQUEST", alert)
    if on and not hooked then
        hooked = true
        hooksecurefunc(C_FriendList, "AddIgnore", OnIgnoreRequest)
        hooksecurefunc(C_FriendList, "AddOrDelIgnore", OnIgnoreRequest)
    end
    if not on then seen, fed = nil, nil end
    if not alert then
        wipe(warned)
    elseif IsLoggedIn() then
        CheckGroup()
    end
end

local function SetEnabled(on)
    CfgW().enabled = on or nil
    Apply()
    if on then
        settled = true
        Sync()
    end
end

-------------------------------------------------------------------------------
--  Options entry points
-------------------------------------------------------------------------------
-- Every listed player, a header per realm (rebuilt on each open).
local function Items()
    local entries = {}
    for key in pairs(Cfg().list or EMPTY) do
        local name, realm = Split(key)
        entries[#entries + 1] = { key = key, name = name, realm = realm }
    end
    table.sort(entries, function(a, b)
        if a.realm ~= b.realm then return a.realm < b.realm end
        return a.name < b.name
    end)
    local items, lastRealm = {}, nil
    for _, e in ipairs(entries) do
        if e.realm ~= lastRealm then
            lastRealm = e.realm
            items[#items + 1] = { isHeader = true, label = e.realm }
        end
        items[#items + 1] = {
            key = e.key,
            label = e.name,
            tooltip = seen and not seen[e.key]
                and EllesmereUI.L("Not on this character's game list: the alert sees this player, the game does not block them.") or nil,
        }
    end
    return items
end

EUI._AccountIgnore = {
    Enabled = Enabled,
    SetEnabled = SetEnabled,
    Apply = Apply,
    Items = Items,
    IsListed = function(key) return (Cfg().list or EMPTY)[key] ~= nil end,
    SetListed = SetListed,
    AddTyped = AddTyped,
}

Apply()
if Enabled() and not IsLoggedIn() then ev:RegisterEvent("PLAYER_ENTERING_WORLD") end
