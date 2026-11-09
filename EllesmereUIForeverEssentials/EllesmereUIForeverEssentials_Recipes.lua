if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_Recipes.lua  (WoW Forever only)
--  Recipes in Tooltips (off by default): a recipe's tooltip (pattern, plans,
--  formula...) says which of your characters already know it, which can
--  learn it and which are below its skill, each name colored by what the
--  recipe would do for that character's skill, as the profession window
--  colors recipes: orange, yellow, green, grey; red when the skill is too low.
--
--  Recipes come from the client (RecipeData.lua). Each character's skills
--  and known recipes are kept for the account in EllesmereUIDB.recipeTips
--  .chars, by player GUID, read at login and whenever a skill or a recipe
--  changes, only while the setting is on: a character shows up once it has
--  logged in with it on. The character playing is always read live.
-------------------------------------------------------------------------------
local _, module = ...

local F = module.Feature("recipeTips", { enabled = false })

local recipes        -- [item ID] = { skill, need, spell, yellow, grey }, read on first use
local spellsBySkill  -- [skill line] = { spell, ... }
local ev = CreateFrame("Frame")
local hooked = false

local function Load()
    if recipes then return end
    recipes, spellsBySkill = {}, {}
    for item, skill, need, spell, yellow, grey in (module.RECIPE_DATA or ""):gmatch("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)") do
        skill, spell = tonumber(skill), tonumber(spell)
        recipes[tonumber(item)] = { skill, tonumber(need), spell, tonumber(yellow), tonumber(grey) }
        local list = spellsBySkill[skill]
        if not list then
            list = {}
            spellsBySkill[skill] = list
        end
        list[#list + 1] = spell
    end
end

-- The playing character's skills: [skill line] = rank.
local function Skills()
    local out = {}
    for _, index in ipairs({ GetProfessions() }) do
        if index then
            local _, _, rank, _, _, _, line = GetProfessionInfo(index)
            if line and rank then out[line] = rank end
        end
    end
    return out
end

-- The playing character's entry, read again.
local function Record()
    local guid = UnitGUID("player")
    if not guid or issecretvalue(guid) then return end
    Load()
    local cfg = F.Cfg()
    cfg.chars = cfg.chars or {}
    local old = cfg.chars[guid]
    -- What the profession window said stays (see ReadWindow).
    local skills, known = Skills(), (old and old.known) or {}
    for line in pairs(skills) do
        for _, spell in ipairs(spellsBySkill[line] or {}) do
            if IsPlayerSpell(spell) then known[spell] = true end
        end
    end
    local _, class = UnitClass("player")
    cfg.chars[guid] = { name = UnitName("player"), class = class, skills = skills, known = known }
end

-------------------------------------------------------------------------------
--  The tooltip
-------------------------------------------------------------------------------
-- The color a recipe has for a skill (the profession window's).
local function Color(rank, r)
    local need, yellow, grey = r[2], r[4], r[5]
    if rank < need then return "ff4040" end
    if grey == 0 then return "ffffff" end
    if rank < yellow then return "ff8040" end
    if rank < (yellow + grey) / 2 then return "ffff00" end
    if rank < grey then return "40bf40" end
    return "808080"
end

local function ByName(a, b) return a.name < b.name end

local function OnItemTooltip(tooltip, data)
    if not F.Enabled() or not data then return end
    local id = data.id
    if not id or issecretvalue(id) then return end
    Load()
    local r = recipes[id]
    if not r then return end
    local chars = F.Read().chars or {}
    local me = UnitGUID("player")
    local known, learn, low = {}, {}, {}
    for guid, c in pairs(chars) do
        local skills, knows = c.skills, c.known
        if guid == me then skills = Skills() end
        local rank = skills and skills[r[1]]
        if rank then
            local isKnown
            if guid == me then isKnown = IsPlayerSpell(r[3]) else isKnown = knows and knows[r[3]] end
            local e = { name = c.name or "?", rank = rank }
            if isKnown then
                known[#known + 1] = e
            elseif rank >= r[2] then
                learn[#learn + 1] = e
            else
                low[#low + 1] = e
            end
        end
    end
    local function Names(list, withRank)
        table.sort(list, ByName)
        local parts = {}
        for i, e in ipairs(list) do
            parts[i] = "|cff" .. Color(e.rank, r) .. e.name .. (withRank and (" " .. e.rank .. "/" .. r[2]) or "") .. "|r"
        end
        return table.concat(parts, ", ")
    end
    if #known > 0 then tooltip:AddLine(EllesmereUI.L("Known by:") .. " " .. Names(known), 0.6, 0.6, 0.6, true) end
    if #learn > 0 then tooltip:AddLine(EllesmereUI.L("Can learn it:") .. " " .. Names(learn), 0.6, 0.6, 0.6, true) end
    if #low > 0 then tooltip:AddLine(EllesmereUI.L("Skill too low:") .. " " .. Names(low, true), 0.6, 0.6, 0.6, true) end
end

-------------------------------------------------------------------------------
--  Events and the switch
-------------------------------------------------------------------------------
-- The profession window's list: its learned recipes (a recipe ID is its
-- spell ID), in case the client does not answer IsPlayerSpell for them.
local function ReadWindow()
    local api = C_TradeSkillUI
    if not (api and api.GetAllRecipeIDs and api.GetRecipeInfo) then return end
    if api.IsTradeSkillLinked and api.IsTradeSkillLinked() then return end
    if api.IsTradeSkillGuild and api.IsTradeSkillGuild() then return end
    local guid = UnitGUID("player")
    local entry = guid and not issecretvalue(guid) and F.Read().chars and F.Read().chars[guid]
    if not entry then return end
    for _, id in ipairs(api.GetAllRecipeIDs() or {}) do
        local info = api.GetRecipeInfo(id)
        if info and info.learned then entry.known[id] = true end
    end
end

ev:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SKILL_LIST_UPDATE" then ReadWindow() else Record() end
end)

-- Events a WoW Forever client may not know are registered with care.
local function TryRegister(event) pcall(ev.RegisterEvent, ev, event) end

local function Apply()
    if not F.Enabled() then
        ev:UnregisterAllEvents()
        return
    end
    ev:RegisterEvent("SKILL_LINES_CHANGED")
    ev:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
    TryRegister("NEW_RECIPE_LEARNED")
    TryRegister("TRADE_SKILL_LIST_UPDATE")
    Record()
    if not hooked and TooltipDataProcessor then
        hooked = true
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
    end
end

-- Options-page entry points.
EllesmereUI._RecipeTips = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply)
