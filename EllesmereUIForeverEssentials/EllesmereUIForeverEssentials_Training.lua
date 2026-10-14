if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Training.lua  (WoW Forever only)
--  Training Planner: what each class trainer teaches, by level, from the
--  trainer data (TrainerData.lua), with what the player has trained. Costs
--  are not in the client's data: each visit to a class trainer records them
--  for the account, under the visitor's class.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.trainingPlanner; unset keys read these.
-- costs: classFile = { "Name|Rank" = copper }
local F = module.Feature("trainingPlanner", { enabled = false })

local events

local function Key(name, rank)
    return rank and (name .. "|" .. rank) or name
end

-- A class trainer's costs (professions and pet trainers left out).
local function Capture()
    if IsTradeskillTrainer() or C_Trainer.GetTrainerType() ~= Enum.TrainerType.General then return end
    local cfg = F.Cfg()
    local _, class = UnitClass("player")
    cfg.costs = cfg.costs or {}
    local costs = cfg.costs[class] or {}
    cfg.costs[class] = costs
    for i = 1, GetNumTrainerServices() do
        local name, _, _, _, rank = GetTrainerServiceInfo(i)
        if name and name ~= "" then
            if rank == "" then rank = nil end
            costs[Key(name, rank)] = GetTrainerServiceCost(i) or 0
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

-- Every class, the player's own first.
local function Classes()
    local _, mine = UnitClass("player")
    local out = { mine }
    for _, class in ipairs(module.TrainerClasses()) do
        if class ~= mine then out[#out + 1] = class end
    end
    return out
end

-- class's abilities by level then name; cost is nil until a trainer of that
-- class was visited; known is set for the player's own class.
local function List(class)
    local out = {}
    local _, mine = UnitClass("player")
    local own = class == mine
    local all = F.Get("costs")
    local costs = all and all[class]
    for level, spells in pairs(module.TrainerSpells(class)) do
        for i = 1, #spells do
            local id = spells[i]
            local name = C_Spell.GetSpellName(id)
            if name then
                local rank = C_Spell.GetSpellSubtext(id)
                if rank == "" then rank = nil end
                out[#out + 1] = { spellID = id, name = name, rank = rank, level = level,
                    icon = C_Spell.GetSpellTexture(id), cost = costs and costs[Key(name, rank)],
                    known = own and IsPlayerSpell(id) or nil, own = own }
            end
        end
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
