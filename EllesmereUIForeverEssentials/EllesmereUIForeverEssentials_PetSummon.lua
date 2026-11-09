if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_PetSummon.lua  (WoW Forever only)
--  Auto Summon Pet: once the game takes the companion pet away (death,
--  loading screen, taxi, vehicle...), summons one again a moment later. A pet
--  the player dismisses (Dismiss, or its journal toggle) stays dismissed until
--  they summon one again. Never in combat, stealth or while mounted.
--
--  Which pet: the first circumstance (RULES, most specific first) whose rule
--  is not "next" decides: its chosen pets, the favorites, or none. The
--  defaults keep the original behavior: favorites, none in instances. Rules
--  are set from a cog on the Pet Journal, and a pet's right-click menu adds
--  it to a circumstance. On entering a "chosen" circumstance a pet out that is
--  not one of its pets is swapped; on entering a "none" one it is put away.
--
--  Favorites: a random favorite, or any random pet while none is a favorite,
--  as the journal's random pet button. Favorites per Character (a
--  per-character setting): this character picks among its own favorites,
--  chosen from a pet's right-click menu and marked with a blue star.
--
--  Summoning is plain API, refused in combat only. The player's dismissals
--  are the two calls read from hooksecurefunc. Events and hooks only exist
--  once the feature has been on.
-------------------------------------------------------------------------------
local _, module = ...
local DELAY = 2  -- seconds after a trigger: lets a load, landing or resurrection settle
local STAR = "PetJournal-FavoritesIcon"   -- the journal's favorite star, tinted blue below
local NIGHT_FROM, NIGHT_TO = 21, 6         -- game-clock hours that count as night

-- Settings live in EllesmereUIDB.petSummon; unset keys read these.
--   enabled                 Auto Summon Pet
--   chars[player GUID]      own = Favorites per Character, favorites = { [pet GUID] = true },
--                           dismissed = the player put the pet away (until they summon one)
--   rules[key]              mode = "next" | "favorites" | "chosen" | "none", pets = { [pet GUID] = true }
local F = module.Feature("petSummon", { enabled = false })
local IsEnabled = F.Enabled

-------------------------------------------------------------------------------
--  Circumstances
-------------------------------------------------------------------------------
-- Holidays by their calendar ids (the client's Holidays table on WoW Forever).
local HOLIDAYS = {
    { key = "holiday:lunar",     name = "Lunar Festival",          ids = { [327] = true } },
    { key = "holiday:love",      name = "Love is in the Air",      ids = { [335] = true } },
    { key = "holiday:noble",     name = "Noblegarden",             ids = { [181] = true } },
    { key = "holiday:children",  name = "Children's Week",         ids = { [201] = true } },
    { key = "holiday:midsummer", name = "Midsummer Fire Festival", ids = { [341] = true } },
    { key = "holiday:fireworks", name = "Fireworks Spectacular",   ids = { [62] = true } },
    { key = "holiday:harvest",   name = "Harvest Festival",        ids = { [321] = true } },
    { key = "holiday:hallow",    name = "Hallow's End",            ids = { [324] = true } },
    { key = "holiday:winter",    name = "Feast of Winter Veil",    ids = { [141] = true } },
    { key = "holiday:darkmoon",  name = "Darkmoon Faire",          ids = { [263] = true, [264] = true } },
    { key = "holiday:fishing",   name = "Stranglethorn Fishing Extravaganza", ids = { [301] = true } },
}

local function IsNight()
    local h = GetGameTime()
    return h >= NIGHT_FROM or h < NIGHT_TO
end

-- The circumstances; holidays come after the instances.
-- s: the state read once per decision (Snapshot).
local RULES = {
    { key = "dungeon",   name = "Dungeons",        default = "none", test = function(s) return s.inst == "party" end },
    { key = "raid",      name = "Raids",           default = "none", test = function(s) return s.inst == "raid" end },
    { key = "pvp",       name = "Battlegrounds",   default = "none", test = function(s) return s.inst == "pvp" end },
    { key = "arena",     name = "Arenas",          default = "none", test = function(s) return s.inst == "arena" end },
    { holidays = true },
    { key = "raidgroup", name = "In a Raid Group", group = true, test = function() return IsInRaid() end },
    { key = "group",     name = "In a Group",      group = true, test = function() return IsInGroup() end },
    { key = "rest",      name = "Cities and Inns", test = function() return IsResting() end },
    { key = "night",     name = "At Night",        test = function(s) return s.night end },
    { key = "day",       name = "By Day",          test = function(s) return not s.night end },
    { key = "world",     name = "Open World",      default = "favorites", test = function() return true end },
}
local DEFAULT_MODE = {}
for _, r in ipairs(RULES) do
    if r.key then DEFAULT_MODE[r.key] = r.default or "next" end
end

local function Rule(key, create)
    local rules = create and F.Cfg() or F.Read()
    if create then
        rules.rules = rules.rules or {}
        rules.rules[key] = rules.rules[key] or {}
    end
    return rules.rules and rules.rules[key]
end

local function ModeOf(key)
    local r = Rule(key)
    return (r and r.mode) or DEFAULT_MODE[key] or "next"
end

local function SetMode(key, mode)
    Rule(key, true).mode = mode
end

local function HasPet(key, petGUID)
    local r = Rule(key)
    return r ~= nil and r.pets ~= nil and r.pets[petGUID] == true
end

local function SetPet(key, petGUID, on)
    local r = Rule(key, true)
    r.pets = r.pets or {}
    r.pets[petGUID] = on or nil
end

-- A rule's pets that can be summoned now.
local function ChosenPets(key)
    local list = {}
    local r = Rule(key)
    if not (r and r.pets) then return list end
    for petGUID in pairs(r.pets) do
        if C_PetJournal.PetIsSummonable(petGUID) then list[#list + 1] = petGUID end
    end
    return list
end

-- Whether any rule of a kind is in use (decides which events are worth having).
local function AnyRule(match)
    local rules = F.Read().rules
    if not rules then return false end
    for key, r in pairs(rules) do
        if r.mode and r.mode ~= "next" and match(key) then return true end
    end
    return false
end
local function UsesHolidays() return AnyRule(function(k) return k:find("^holiday:") ~= nil end) end
local function UsesGroups() return AnyRule(function(k) return k == "group" or k == "raidgroup" end) end

-- Today's holidays from the game calendar: { [holiday key] = true }. The
-- calendar may show another month: today is read at its offset from it.
local function ActiveHolidays()
    local out = {}
    if not (C_Calendar and C_DateAndTime) then return out end
    local now = C_DateAndTime.GetCurrentCalendarTime()
    local shown = C_Calendar.GetMonthInfo(0)
    if not (now and shown) then return out end
    local offset = (now.year - shown.year) * 12 + (now.month - shown.month)
    for i = 1, C_Calendar.GetNumDayEvents(offset, now.monthDay) do
        local e = C_Calendar.GetDayEvent(offset, now.monthDay, i)
        local id = e and e.eventID
        local kind = e and e.calendarType
        if kind and not issecretvalue(kind) and kind == "HOLIDAY" and id and not issecretvalue(id) then
            for _, h in ipairs(HOLIDAYS) do
                if h.ids[id] then out[h.key] = true end
            end
        end
    end
    return out
end

local function Snapshot()
    local _, inst = IsInInstance()
    return { inst = inst, night = IsNight() }
end

-- The deciding circumstance: its key and mode ("favorites", "chosen" with
-- its summonable pets, or "none"). A "chosen" rule with no pet it can
-- summon passes to the next one.
local function Resolve()
    local function Try(key)
        local mode = ModeOf(key)
        if mode == "next" then return nil end
        if mode == "chosen" then
            local list = ChosenPets(key)
            if #list == 0 then return nil end
            return key, mode, list
        end
        return key, mode
    end
    local s = Snapshot()
    local holidays
    for _, r in ipairs(RULES) do
        if r.holidays then
            if UsesHolidays() then
                holidays = holidays or ActiveHolidays()
                for _, h in ipairs(HOLIDAYS) do
                    if holidays[h.key] then
                        local key, mode, list = Try(h.key)
                        if key then return key, mode, list end
                    end
                end
            end
        elseif r.test(s) then
            local key, mode, list = Try(r.key)
            if key then return key, mode, list end
        end
    end
    return "world", "favorites"
end

-------------------------------------------------------------------------------
--  Favorites
-------------------------------------------------------------------------------
-- This character's settings; nil until written, unless create.
local function CharCfg(create)
    local cfg = create and F.Cfg() or F.Read()
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

-------------------------------------------------------------------------------
--  Summoning
-------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local timer
local hooked = false
local userDismissed = false  -- the player put the pet away themselves (also kept per character)
local current          -- the pet we last saw out (nil: none)
local lastKey          -- the circumstance the last decision was made in
local ownCall = false  -- our own summon or dismissal is running (the hooks skip it)

-- The dismissal outlives a reload or a relog: written only when it changes.
local function SetDismissed(on)
    if userDismissed == on then return end
    userDismissed = on
    local c = CharCfg(on)
    if c then c.dismissed = on or nil end
end

local function CanSummonNow()
    return not (UnitIsDeadOrGhost("player") or UnitOnTaxi("player")
        or UnitInVehicle("player") or IsMounted() or IsStealthed())
end

local function SummonGUID(petGUID)
    ownCall = true
    C_PetJournal.SummonPetByGUID(petGUID)
    ownCall = false
end

local function SummonFavorite()
    local own = OwnFavorites()
    if #own > 0 then
        SummonGUID(own[math.random(#own)])
    else
        -- As the journal's random pet button: all pets while none is a favorite.
        C_PetJournal.SummonRandomPet(C_PetJournal.HasFavoritePets())
    end
end

-- Whether a pet out may stay on entering a circumstance: any pet under
-- "favorites" (as before rules), one of its pets under "chosen".
local function Allowed(petGUID, mode, list)
    if mode == "none" then return false end
    if mode == "chosen" then
        for i = 1, #list do
            if list[i] == petGUID then return true end
        end
        return false
    end
    return true
end

local Queue

-- Each blocker above has an event that queues again once it lifts; combat
-- waits for its end on the combat queue.
local function Summon()
    timer = nil
    if not IsEnabled() or userDismissed then return end
    if InCombatLockdown() then
        EllesmereUI.CombatQueue.Defer("PetSummon", Queue)
        return
    end
    if not CanSummonNow() then return end
    -- A cast or a channel (a fishing line): again once it stops.
    if UnitCastingInfo("player") or UnitChannelInfo("player") then
        ev:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
        ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
        return
    end
    local key, mode, list = Resolve()
    local out = C_PetJournal.GetSummonedPetGUID()
    local entered = key ~= lastKey
    lastKey = key
    if out then
        -- A pet out stays unless this circumstance just began and does not allow it.
        if not entered or Allowed(out, mode, list) then return end
        if mode == "none" then
            ownCall = true
            C_PetJournal.DismissSummonedPet()
            ownCall = false
            return
        end
    elseif mode == "none" then
        return
    end
    if mode == "chosen" then
        SummonGUID(list[math.random(#list)])
    else
        SummonFavorite()
    end
end

Queue = function()
    if timer then timer:Cancel() end
    timer = C_Timer.NewTimer(DELAY, Summon)
end

-- After which a missing pet may come back (COMPANION_UPDATE: the pet out),
-- or a new circumstance begins.
local EVENTS = {
    "COMPANION_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_ALIVE",
    "PLAYER_UNGHOST", "PLAYER_CONTROL_GAINED", "UNIT_EXITED_VEHICLE",
    "UPDATE_STEALTH", "PLAYER_MOUNT_DISPLAY_CHANGED",
    "ZONE_CHANGED_NEW_AREA", "PLAYER_UPDATE_RESTING",
}

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "COMPANION_UPDATE" then
        if arg1 == "MOUNT" then return end
        -- Also fires for other players' pets: only ours is read.
        local guid = C_PetJournal.GetSummonedPetGUID()
        current = guid
        if guid then SetDismissed(false) end
        return
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        ev:UnregisterEvent("UNIT_SPELLCAST_STOP")
        ev:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    elseif event == "UNIT_EXITED_VEHICLE" and arg1 ~= "player" then
        return
    end
    if not userDismissed then Queue() end
end)

-- The player's own dismissals: DismissSummonedPet, or SummonPetByGUID on the
-- pet out (the journal's toggle). The pet out is the one we last saw: the
-- post-hook may run once it is gone.
local function OnDismiss()
    if not ownCall then SetDismissed(true) end
end
local function OnSummonByGUID(guid)
    if not ownCall and guid and guid == current then SetDismissed(true) end
end

-- The events a rule in use needs: groups and the calendar (opened once).
local calendarOpened = false
local function SyncRuleEvents()
    local on = IsEnabled()
    if on and UsesGroups() then ev:RegisterEvent("GROUP_ROSTER_UPDATE") else ev:UnregisterEvent("GROUP_ROSTER_UPDATE") end
    if on and UsesHolidays() then
        ev:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
        if not calendarOpened then
            calendarOpened = true
            C_Calendar.OpenCalendar()
        end
    else
        ev:UnregisterEvent("CALENDAR_UPDATE_EVENT_LIST")
    end
end

-- A rule changed: the next decision starts afresh.
local function RulesChanged()
    SyncRuleEvents()
    lastKey = nil
    if IsEnabled() and not userDismissed then Queue() end
end

-------------------------------------------------------------------------------
--  Pet Journal: favorites, circumstances
-------------------------------------------------------------------------------
local function ShowsOwn() return IsEnabled() and OwnOn() end
local L = EllesmereUI.L

-- The blue star on a list button, beside the journal's own; kept in a weak
-- table, nothing is stored on the journal's buttons.
local stars = setmetatable({}, { __mode = "k" })
local function MarkListButton(button)
    local drag = button and button.dragButton
    if not drag then return end
    local on = ShowsOwn() and IsOwnFavorite(button.petID)
    local star = stars[drag]
    if on and not star then
        star = drag:CreateTexture(nil, "OVERLAY", nil, 2)
        star:SetAtlas(STAR, true)
        star:SetVertexColor(0.45, 0.8, 1)
        star:SetPoint("TOPRIGHT", 8, 8)
        stars[drag] = star
    end
    if star then star:SetShown(on) end
end

-- The stars of the buttons on screen, read from the list without asking the
-- journal to rebuild it.
local function RefreshJournal()
    local scroll = PetJournal and PetJournal:IsShown() and PetJournal.ScrollBox
    if scroll and scroll.ForEachFrame then scroll:ForEachFrame(MarkListButton) end
end

-- Every circumstance a pet can be added to, in decision order: { key, name }.
local function Circumstances()
    local out = {}
    for _, r in ipairs(RULES) do
        if r.holidays then
            for _, h in ipairs(HOLIDAYS) do out[#out + 1] = { key = h.key, name = L(h.name), holiday = true } end
        else
            out[#out + 1] = { key = r.key, name = L(r.name) }
        end
    end
    return out
end

-- A pet's right-click menu. The owner is its list button or the pet card,
-- whose petID is the owned pet's GUID, or the list button's icon, whose
-- parent holds it (PetJournal_ShowPetDropdown; the menu passes no context).
local function AddMenuEntry(owner, root)
    local petGUID = owner and (owner.petID or (owner.GetParent and owner:GetParent()
        and owner:GetParent().petID))
    if not (petGUID and IsEnabled()) then return end
    root:CreateDivider()
    if OwnOn() then
        root:CreateCheckbox(L("Favorite for This Character"),
            function() return IsOwnFavorite(petGUID) end,
            function()
                SetOwnFavorite(petGUID, not IsOwnFavorite(petGUID))
                RefreshJournal()
            end)
    end
    -- Ticking a circumstance makes it use its chosen pets.
    local sub = root:CreateButton(L("Auto Summon In"))
    local events
    local function Check(parent, key, name)
        parent:CreateCheckbox(name,
            function() return HasPet(key, petGUID) end,
            function()
                local on = not HasPet(key, petGUID)
                SetPet(key, petGUID, on)
                if on then SetMode(key, "chosen") end
                RulesChanged()
            end)
    end
    for _, c in ipairs(Circumstances()) do
        if c.holiday then
            events = events or sub:CreateButton(L("Seasonal Events"))
            Check(events, c.key, c.name)
        else
            Check(sub, c.key, c.name)
        end
    end
end

-- The journal's cog: every circumstance and its rule.
local MODES = { "next", "favorites", "chosen", "none" }
local MODE_NAMES = { next = "Next Rule", favorites = "Favorites", chosen = "Chosen Pets", none = "None" }

local function ModeMenu(parent, key, name, active)
    local label = name
    local mode = ModeOf(key)
    if mode ~= "next" then label = label .. "  |cff888888(" .. L(MODE_NAMES[mode]) .. ")|r" end
    if active then label = label .. "  |cff0cd29d" .. L("(now)") .. "|r" end
    local sub = parent:CreateButton(label)
    for _, m in ipairs(MODES) do
        local text = L(MODE_NAMES[m])
        if m == "chosen" then
            local r = Rule(key)
            local n = 0
            if r and r.pets then for _ in pairs(r.pets) do n = n + 1 end end
            text = text .. " (" .. n .. ")"
        end
        sub:CreateRadio(text, function() return ModeOf(key) == m end, function()
            SetMode(key, m)
            RulesChanged()
        end)
    end
    return sub
end

local function BuildRulesMenu(_, root)
    root:CreateTitle(L("Auto Summon Pet"))
    local holidays = UsesHolidays() and ActiveHolidays() or {}
    local eventsMenu
    for _, c in ipairs(Circumstances()) do
        if c.holiday then
            eventsMenu = eventsMenu or root:CreateButton(L("Seasonal Events"))
            ModeMenu(eventsMenu, c.key, c.name, holidays[c.key])
        else
            ModeMenu(root, c.key, c.name)
        end
    end
end

local cog
local function BuildCog()
    if cog or not (PetJournal and PetJournal.SummonRandomPetSpellFrame and MenuUtil) then return end
    cog = CreateFrame("Button", nil, PetJournal)
    cog:SetSize(24, 24)
    cog:SetPoint("RIGHT", PetJournal.SummonRandomPetSpellFrame, "LEFT", -8, 0)
    local tex = cog:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(EllesmereUI.COGS_ICON)
    cog:SetAlpha(0.7)
    cog:SetScript("OnEnter", function(self)
        self:SetAlpha(1)
        EllesmereUI.ShowWidgetTooltip(self, L("Auto Summon Pet: which pets come out where."))
    end)
    cog:SetScript("OnLeave", function(self)
        self:SetAlpha(0.7)
        EllesmereUI.HideWidgetTooltip()
    end)
    cog:SetScript("OnClick", function(self) MenuUtil.CreateContextMenu(self, BuildRulesMenu) end)
    cog:SetShown(IsEnabled())
end

local journalHooked = false
local function HookJournal()
    if journalHooked or not PetJournal_InitPetButton then return end
    journalHooked = true
    hooksecurefunc("PetJournal_InitPetButton", MarkListButton)
    BuildCog()
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
-- fresh: the player just turned it on, which also ends an earlier dismissal.
local function ApplyPetSummon(fresh)
    if not C_PetJournal then return end
    RefreshJournal()
    local on = IsEnabled()
    if cog then cog:SetShown(on) end
    for i = 1, #EVENTS do
        if on then ev:RegisterEvent(EVENTS[i]) else ev:UnregisterEvent(EVENTS[i]) end
    end
    SyncRuleEvents()
    if not on then
        ev:UnregisterEvent("UNIT_SPELLCAST_STOP")
        ev:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
        if timer then timer:Cancel(); timer = nil end
        return
    end
    if not hooked then
        hooked = true
        hooksecurefunc(C_PetJournal, "DismissSummonedPet", OnDismiss)
        hooksecurefunc(C_PetJournal, "SummonPetByGUID", OnSummonByGUID)
        HookPetJournal()
    end
    current = C_PetJournal.GetSummonedPetGUID()
    lastKey = nil
    -- A dismissal from an earlier session holds until a pet is out again.
    local c = CharCfg()
    if c and c.dismissed and (current or fresh) then c.dismissed = nil end
    userDismissed = (c and c.dismissed) and true or false
    Queue()
end
-- Options-page entry points. Favorites per Character changed: only the
-- journal's stars and menu follow (RefreshJournal).
EllesmereUI._PetSummon = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = ApplyPetSummon,
    RefreshJournal = RefreshJournal,
}

F.Start(ApplyPetSummon)
