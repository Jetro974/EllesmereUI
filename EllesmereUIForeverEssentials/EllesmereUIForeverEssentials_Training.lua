if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Training.lua  (WoW Forever only)
--  Training Planner: what a class trainer teaches, kept for the account. Each
--  visit to a trainer records every ability it lists (the ones not trainable
--  yet included) with its level and cost, under the visitor's class, and what
--  that character has already trained. The Training page lists them by level;
--  any of the account's classes can be picked there.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.trainingPlanner; unset keys read these.
-- classes: classFile = { key = { name, rank, icon, level, cost } }
-- known: "Name-Realm" = { key = true }, what that character has trained.
local F = module.Feature("trainingPlanner", { enabled = false })

local events

local function CharKey()
    return UnitName("player") .. "-" .. GetNormalizedRealmName()
end

local function Sub(cfg, key)
    local t = cfg[key]
    if not t then
        t = {}
        cfg[key] = t
    end
    return t
end

-- A class trainer's whole list (professions and pet trainers left out).
local function Capture()
    if IsTradeskillTrainer() or C_Trainer.GetTrainerType() ~= Enum.TrainerType.General then return end
    local cfg = F.Cfg()
    local _, class = UnitClass("player")
    local list = Sub(Sub(cfg, "classes"), class)
    local known = Sub(Sub(cfg, "known"), CharKey())
    for i = 1, GetNumTrainerServices() do
        local name, kind, icon, level, rank = GetTrainerServiceInfo(i)
        if name and name ~= "" then
            if rank == "" then rank = nil end
            local key = rank and (name .. "|" .. rank) or name
            local e = list[key]
            if not e then
                e = {}
                list[key] = e
            end
            e.name, e.rank, e.icon, e.level = name, rank, icon, level or 1
            e.cost = GetTrainerServiceCost(i) or 0
            if kind == "used" then known[key] = true end
        end
    end
end

local function Apply()
    if not F.Enabled() then
        if events then events:UnregisterAllEvents() end
        return
    end
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", Capture)
    end
    events:RegisterEvent("TRAINER_SHOW")
    events:RegisterEvent("TRAINER_UPDATE")
    events:RegisterEvent("TRAINER_SERVICE_INFO_NAME_UPDATE")
end

-- The classes with a recorded list, the player's own first.
local function Classes()
    local _, mine = UnitClass("player")
    local out = {}
    local classes = F.Get("classes")
    if classes then
        for class in pairs(classes) do
            if class ~= mine then out[#out + 1] = class end
        end
    end
    table.sort(out)
    if classes and classes[mine] then table.insert(out, 1, mine) end
    return out
end

-- class's abilities by level then name; known is set for the player's own
-- class (what this character has trained).
local function List(class)
    local out = {}
    local classes = F.Get("classes")
    local list = classes and classes[class]
    if not list then return out end
    local _, mine = UnitClass("player")
    local knownAll = F.Get("known")
    local known = class == mine and knownAll and knownAll[CharKey()]
    for key, e in pairs(list) do
        out[#out + 1] = { name = e.name, rank = e.rank, icon = e.icon, level = e.level, cost = e.cost,
            known = known and known[key] or nil, own = class == mine }
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        if a.name ~= b.name then return a.name < b.name end
        return (a.rank or "") < (b.rank or "")
    end)
    return out
end

-- Options-page entry points.
EllesmereUI._TrainingPlanner = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
    Classes = Classes,
    List = List,
}

F.Start(Apply)
