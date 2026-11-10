if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_CharacterHighlight.lua  (WoW Forever only)
--  Character Highlight: the game's own self highlight (circle, outline, icon)
--  picked per situation: In Combat, On a Flight Path, then the shared
--  situations (module.SITUATION_ORDER), then Elsewhere. The first one that
--  applies, top to bottom, decides; "Same as Below" hands over to the next.
--
--  It holds the game's account-wide findYourself* CVars through the parent's
--  CVar record (HoldCVar / ReleaseCVar), so turning the option or the module
--  off, or Uninstall, gives them back. Their values from before are also kept
--  in saved. A CVar the client lacks is skipped. Combat end comes through the
--  parent's combat queue (no raw PLAYER_REGEN_ENABLED).
-------------------------------------------------------------------------------
local _, module = ...
local OWNER = "EllesmereUIForeverEssentials"

-- Settings live in EllesmereUIDB.charHighlight; unset keys read these.
--   rules[situation]   a STYLES key, or "pass" (Same as Below)
--   hoursFrom, hoursTo the Between Hours range (game clock)
--   saved              the game's CVars from before ours
-- Test bundle only (never in the PR): the QoL test build kept charHighlight as
-- a plain switch with flat keys beside it; fold them into the feature table.
do
    local db = EllesmereUIDB
    if db and ((db.charHighlight ~= nil and type(db.charHighlight) ~= "table")
        or db.charHighlightSaved or db.charHighlightRules) then
        local t = type(db.charHighlight) == "table" and db.charHighlight or {}
        if db.charHighlight == true then t.enabled = true end
        t.rules = t.rules or db.charHighlightRules
        t.hoursFrom = t.hoursFrom or db.charHighlightFrom
        t.hoursTo = t.hoursTo or db.charHighlightTo
        t.saved = t.saved or db.charHighlightSaved
        db.charHighlight = t
        db.charHighlightRules, db.charHighlightFrom = nil, nil
        db.charHighlightTo, db.charHighlightSaved = nil, nil
    end
end
local F = module.Feature("charHighlight", { enabled = false,
    hoursFrom = module.HOURS_FROM, hoursTo = module.HOURS_TO })

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
-- Elsewhere decides outside instances too, so the game's own instance and
-- combat-only switches stay off while the option is on.
local ALWAYS = {
    findYourselfAnywhereOnlyInCombat = "0",
    findYourselfInBG = "0", findYourselfInBGOnlyInCombat = "0",
    findYourselfInRaid = "0", findYourselfInRaidOnlyInCombat = "0",
}
local DEFAULT_WORLD = "circle"

local inCombat = false

-- Top to bottom: { key, label, test(s) }. s: module.SituationState.
local SITUATIONS = {
    { key = "combat", label = "In Combat",        test = function() return inCombat end },
    { key = "taxi",   label = "On a Flight Path", test = function() return UnitOnTaxi("player") end },
}
for _, key in ipairs(module.SITUATION_ORDER) do
    local sit = module.SITUATIONS[key]
    SITUATIONS[#SITUATIONS + 1] = { key = key, label = sit.label, test = sit.test }
end
SITUATIONS[#SITUATIONS + 1] = { key = "world", label = "Elsewhere" }

local function Rule(key)
    local rules = F.Get("rules")
    local v = rules and rules[key]
    if v and STYLES[v] then return v end
    return key == "world" and DEFAULT_WORLD or "pass"
end

local function Decide()
    local s = module.SituationState(F.Get("hoursFrom"), F.Get("hoursTo"))
    for _, sit in ipairs(SITUATIONS) do
        local v = Rule(sit.key)
        if v ~= "pass" and (not sit.test or sit.test(s)) then return v end
    end
    return DEFAULT_WORLD
end

local function Write(name, value)
    local cur = C_CVar.GetCVar(name)
    if cur ~= nil and cur ~= value then EllesmereUI.HoldCVar(name, value, OWNER) end
end

local function Evaluate()
    if not F.Enabled() then return end
    for name, value in pairs(ALWAYS) do Write(name, value) end
    for name, value in pairs(STYLES[Decide()]) do Write(name, value) end
end

local function Save()
    local saved = {}
    for _, name in ipairs(CVARS) do saved[name] = C_CVar.GetCVar(name) end
    F.Cfg().saved = saved
end

local function Restore()
    local saved = F.Read().saved
    if not saved then return end
    for name, was in pairs(saved) do EllesmereUI.ReleaseCVar(name, was, OWNER) end
    F.Cfg().saved = nil
end

local ev = CreateFrame("Frame")
local ticker
local EVENTS = { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "PLAYER_UPDATE_RESTING", "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_DISABLED",
    "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED" }

ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        EllesmereUI.CombatQueue.Defer("FE_CharHighlight", function()
            inCombat = false
            Evaluate()
        end)
    elseif event == "PLAYER_CONTROL_LOST" then
        -- A flight path takes control first; the taxi flag can follow a moment later.
        C_Timer.After(1, Evaluate)
    end
    Evaluate()
end)

-- Login and the options; takes effect at once.
local function Apply()
    if F.Enabled() then
        if not F.Read().saved then Save() end
        for _, e in ipairs(EVENTS) do ev:RegisterEvent(e) end
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
        ev:UnregisterAllEvents()
        if ticker then ticker:Cancel(); ticker = nil end
        Restore()
    end
end

-- Options-page entry points.
EllesmereUI._CharHighlight = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
    Situations = SITUATIONS,
}

F.Start(Apply)
