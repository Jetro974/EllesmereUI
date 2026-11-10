if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_CharacterHighlight.lua
--  Character Highlight: the game's own self highlight (circle, outline, icon)
--  chosen per situation. Situations are read top to bottom and the first one
--  that applies decides; "Same as Below" hands over to the next one, and
--  Elsewhere always decides.
--
--  It drives the game's account-wide findYourself* CVars. Their values from
--  before the option was turned on are kept in EllesmereUIDB.charHighlightSaved
--  and put back when it is turned off. A CVar the client lacks is skipped.
--  Combat end comes through the QoL combat queue (no raw PLAYER_REGEN_ENABLED).
-------------------------------------------------------------------------------
local _, ns = ...
local EUI = EllesmereUI

local CVARS = {
    "findYourselfAnywhere", "findYourselfAnywhereOnlyInCombat",
    "findYourselfInBG", "findYourselfInBGOnlyInCombat",
    "findYourselfInRaid", "findYourselfInRaidOnlyInCombat",
    "findYourselfMode",
    "findYourselfModeCircle", "findYourselfModeOutline", "findYourselfModeIcon",
}

-- Each style as CVar values. findYourselfMode is the older single setting
-- (0 circle, 1 circle and outline, 2 outline); the icon has no value there.
local STYLES = {
    none    = { findYourselfAnywhere = "0" },
    circle  = { findYourselfAnywhere = "1", findYourselfMode = "0",
                findYourselfModeCircle = "1", findYourselfModeOutline = "0", findYourselfModeIcon = "0" },
    outline = { findYourselfAnywhere = "1", findYourselfMode = "2",
                findYourselfModeCircle = "0", findYourselfModeOutline = "1", findYourselfModeIcon = "0" },
    both    = { findYourselfAnywhere = "1", findYourselfMode = "1",
                findYourselfModeCircle = "1", findYourselfModeOutline = "1", findYourselfModeIcon = "0" },
    icon    = { findYourselfAnywhere = "1",
                findYourselfModeCircle = "0", findYourselfModeOutline = "0", findYourselfModeIcon = "1" },
}
-- While the option is on, Elsewhere decides outside instances too, so the
-- game's own instance and combat-only switches stay off.
local ALWAYS = {
    findYourselfAnywhereOnlyInCombat = "0",
    findYourselfInBG = "0", findYourselfInBGOnlyInCombat = "0",
    findYourselfInRaid = "0", findYourselfInRaidOnlyInCombat = "0",
}

local inCombat = false

local function Cfg() return EllesmereUIDB or {} end

local function InHours()
    local db = Cfg()
    local from, to = db.charHighlightFrom or 20, db.charHighlightTo or 6
    local h = GetGameTime()
    if from == to then return false end
    if from < to then return h >= from and h < to end
    return h >= from or h < to
end

-- Most specific first. The options page lists them in this order.
local SITUATIONS = {
    { key = "combat",    label = "In Combat",       test = function() return inCombat end },
    { key = "taxi",      label = "On a Flight Path", test = function() return UnitOnTaxi("player") end },
    { key = "dungeon",   label = "Dungeons",        test = function() return EUI.IsInDungeon() end },
    { key = "raid",      label = "Raids",           test = function(t) return t == "raid" end },
    { key = "pvp",       label = "Battlegrounds",   test = function(t) return t == "pvp" end },
    { key = "arena",     label = "Arenas",          test = function(t) return t == "arena" end },
    { key = "rest",      label = "Cities and Inns", test = function() return IsResting() end },
    { key = "hours",     label = "Between Hours",   test = InHours },
    { key = "raidgroup", label = "In a Raid Group", test = function() return IsInRaid() end },
    { key = "group",     label = "In a Group",      test = function() return IsInGroup() end },
    { key = "world",     label = "Elsewhere" },
}
local DEFAULT_WORLD = "circle"

local function Rule(key)
    local rules = Cfg().charHighlightRules
    local v = rules and rules[key]
    if key == "world" then return (v and STYLES[v]) and v or DEFAULT_WORLD end
    return (v and STYLES[v]) and v or "pass"
end

local function Decide()
    local _, iType = GetInstanceInfo()
    for _, s in ipairs(SITUATIONS) do
        local v = Rule(s.key)
        if v ~= "pass" and (not s.test or s.test(iType)) then return v end
    end
    return DEFAULT_WORLD
end

local function Write(name, value)
    local cur = C_CVar.GetCVar(name)
    if cur ~= nil and cur ~= value then C_CVar.SetCVar(name, value) end
end

local function Evaluate()
    if not Cfg().charHighlight then return end
    for name, value in pairs(ALWAYS) do Write(name, value) end
    for name, value in pairs(STYLES[Decide()]) do Write(name, value) end
end

local function Save()
    local saved = {}
    for _, name in ipairs(CVARS) do saved[name] = C_CVar.GetCVar(name) end
    EllesmereUIDB.charHighlightSaved = saved
end

local function Restore()
    local saved = EllesmereUIDB and EllesmereUIDB.charHighlightSaved
    if not saved then return end
    for name, value in pairs(saved) do Write(name, value) end
    EllesmereUIDB.charHighlightSaved = nil
end

local frame = CreateFrame("Frame")
local ticker
local EVENTS = { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "PLAYER_UPDATE_RESTING", "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_DISABLED",
    "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED" }

frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        ns.CombatQueue.Defer("CharHighlight", function()
            inCombat = false
            Evaluate()
        end)
    elseif event == "PLAYER_CONTROL_LOST" then
        -- A flight path takes control first; the taxi flag can follow a moment later.
        C_Timer.After(1, Evaluate)
    end
    Evaluate()
end)

local function Apply()
    local on = EllesmereUIDB and EllesmereUIDB.charHighlight
    if on then
        if not EllesmereUIDB.charHighlightSaved then Save() end
        for _, e in ipairs(EVENTS) do frame:RegisterEvent(e) end
        inCombat = InCombatLockdown()
        -- The hour range is the only situation that changes on its own.
        local wantTicker = Rule("hours") ~= "pass"
        if wantTicker and not ticker then
            ticker = C_Timer.NewTicker(60, Evaluate)
        elseif not wantTicker and ticker then
            ticker:Cancel(); ticker = nil
        end
        Evaluate()
    else
        frame:UnregisterAllEvents()
        if ticker then ticker:Cancel(); ticker = nil end
        Restore()
    end
end
EUI._applyCharHighlight = Apply
EUI._charHighlightSituations = SITUATIONS

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    Apply()
end)
