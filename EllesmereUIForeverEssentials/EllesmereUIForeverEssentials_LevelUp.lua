if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_LevelUp.lua  (WoW Forever only)
--  A toast on level up, on the loot feed's toast plate: the new level, the
--  health, power and stats gained, new talent points and the abilities the
--  level brings. It fades out after a while; hovering it holds it. Unlock mode
--  places it.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.levelUpToast; unset keys read these.
local F = module.Feature("levelUpToast", { enabled = false, width = 320, duration = 10 },
    { point = "TOP", relPoint = "TOP", x = 0, y = -260 })
local Get, Enabled = F.Get, F.Enabled

local ICON = 40
local SPELL_ICON = 24
local PAD = 10
local FADE_IN, FADE_OUT = 0.35, 0.8

-- PLAYER_LEVEL_UP payload: the stat deltas' positions and their names.
local STATS = {
    { 6, "SPELL_STAT1_NAME" },  -- strength
    { 7, "SPELL_STAT2_NAME" },  -- agility
    { 8, "SPELL_STAT3_NAME" },  -- stamina
    { 9, "SPELL_STAT4_NAME" },  -- intellect
}

local anchor, toast, events

local function Font(fs, size)
    EllesmereUI.ApplyModuleFont(fs, nil, size, "essentials")
end

local function Text(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetJustifyH("LEFT")
    Font(fs, size)
    return fs
end

-- Waits Duration, fades out, hides; hovering holds it.
local function ArmFade()
    if toast.show:IsPlaying() then return end
    toast.fade:Stop()
    toast:SetAlpha(1)
    if not toast:IsMouseOver() then toast.fade:Play() end
end

local function SpellEnter(b)
    toast.fade:Stop()
    toast:SetAlpha(1)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetSpellByID(b.spellID)
    GameTooltip:Show()
end

local function SpellLeave(b)
    if GameTooltip:IsOwned(b) then GameTooltip:Hide() end
    ArmFade()
end

local function SpellButton(i)
    local b = toast.spells[i]
    if b then return b end
    b = CreateFrame("Frame", nil, toast)
    b:SetSize(SPELL_ICON, SPELL_ICON)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    EllesmereUI.PP.CreateBorder(b, 0, 0, 0, 1, 1, "OVERLAY", 1)
    b:EnableMouseMotion(true)
    b:SetScript("OnEnter", SpellEnter)
    b:SetScript("OnLeave", SpellLeave)
    toast.spells[i] = b
    return b
end

local function Anim(g, kind, order, secs, smoothing)
    local a = g:CreateAnimation(kind)
    a:SetOrder(order)
    a:SetDuration(secs)
    if smoothing then a:SetSmoothing(smoothing) end
    return a
end

local function ApplyStyle()
    if not anchor then return end
    anchor:SetSize(Get("width"), ICON + PAD * 2)
    toast:SetWidth(Get("width"))
end

local function Build()
    if anchor then return end
    local plate = module.ToastPlate
    anchor = CreateFrame("Frame", nil, UIParent)
    anchor:SetFrameStrata("MEDIUM")
    F.Place(anchor)

    -- The plate hangs from the anchor's top and grows down with its lines.
    toast = CreateFrame("Frame", nil, anchor)
    toast:SetPoint("TOP")
    toast:Hide()
    toast.bg = toast:CreateTexture(nil, "BACKGROUND")
    toast.bg:SetAllPoints()
    toast.bg:SetColorTexture(1, 1, 1, 1)
    toast.bg:SetGradient("VERTICAL", CreateColor(plate.bottom[1], plate.bottom[2], plate.bottom[3], 0.9),
        CreateColor(plate.top[1], plate.top[2], plate.top[3], 0.9))
    EllesmereUI.PP.CreateBorder(toast, plate.gold[1], plate.gold[2], plate.gold[3], 1, 1, "OVERLAY", 2)
    plate.Chrome(toast)

    toast.iconBg = toast:CreateTexture(nil, "ARTWORK")
    toast.iconBg:SetColorTexture(plate.gold[1], plate.gold[2], plate.gold[3], 1)
    toast.icon = toast:CreateTexture(nil, "ARTWORK", nil, 1)
    toast.icon:SetSize(ICON, ICON)
    toast.icon:SetPoint("TOPLEFT", PAD, -PAD)
    toast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    toast.iconBg:SetPoint("TOPLEFT", toast.icon, -2, 2)
    toast.iconBg:SetPoint("BOTTOMRIGHT", toast.icon, 2, -2)
    toast.level = toast:CreateFontString(nil, "OVERLAY")
    Font(toast.level, 14)
    toast.level:SetPoint("BOTTOMRIGHT", toast.icon, 2, -1)

    toast.title = Text(toast, 15)
    toast.title:SetTextColor(1, 0.82, 0)
    toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 10, 0)
    toast.title:SetPoint("RIGHT", -PAD, 0)
    toast.lines = Text(toast, 12)
    toast.lines:SetSpacing(2)
    toast.lines:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -4)
    toast.lines:SetPoint("RIGHT", -PAD, 0)
    toast.spells = {}

    toast:EnableMouseMotion(true)
    toast:SetScript("OnEnter", function()
        if not toast.show:IsPlaying() then
            toast.fade:Stop()
            toast:SetAlpha(1)
        end
    end)
    toast:SetScript("OnLeave", ArmFade)
    toast.show = toast:CreateAnimationGroup()
    local appear = Anim(toast.show, "Alpha", 1, FADE_IN, "OUT")
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    toast.show:SetScript("OnFinished", ArmFade)
    toast.fade = toast:CreateAnimationGroup()
    toast.fade.alpha = Anim(toast.fade, "Alpha", 1, FADE_OUT, "IN_OUT")
    toast.fade.alpha:SetFromAlpha(1)
    toast.fade.alpha:SetToAlpha(0)
    toast.fade:SetScript("OnFinished", function() toast:Hide() end)
    ApplyStyle()
end

-- What the level brought, one line each: health, power and stats; talent
-- points; then the abilities as icons under a label.
local function Show(level, health, power, talents, ...)
    Build()
    local deltas = { ... }
    local gains = {}
    if health > 0 then gains[#gains + 1] = ("+%d %s"):format(health, HEALTH) end
    local _, token = UnitPowerType("player")
    if power > 0 then gains[#gains + 1] = ("+%d %s"):format(power, _G[token] or token) end
    for i = 1, #STATS do
        local d = deltas[STATS[i][1] - 5]
        if d and d > 0 then gains[#gains + 1] = ("+%d %s"):format(d, _G[STATS[i][2]]) end
    end
    local lines = { table.concat(gains, ", ") }
    if talents > 0 then lines[#lines + 1] = EllesmereUI.Lf("Talent points: +%d", talents) end
    local spells = C_SpellBook.GetCurrentLevelSpells(level) or {}
    if #spells > 0 then lines[#lines + 1] = "|cffffffff" .. EllesmereUI.L("New abilities:") .. "|r" end

    local _, class = UnitClass("player")
    toast.icon:SetTexture(EllesmereUI.ForeverClassIcon(class))
    toast.level:SetText(level)
    toast.title:SetText(EllesmereUI.Lf("Level %d", level))
    toast.lines:SetText(table.concat(lines, "\n"))

    for i = 1, #spells do
        local b = SpellButton(i)
        b.spellID = spells[i]
        b.icon:SetTexture(C_Spell.GetSpellTexture(spells[i]))
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", toast.lines, "BOTTOMLEFT", (i - 1) * (SPELL_ICON + 4), -6)
        b:Show()
    end
    for i = #spells + 1, #toast.spells do toast.spells[i]:Hide() end

    local textH = toast.title:GetStringHeight() + 4 + toast.lines:GetStringHeight()
    if #spells > 0 then textH = textH + 6 + SPELL_ICON end
    toast:SetHeight(math.max(ICON, textH) + PAD * 2)

    toast.fade.alpha:SetStartDelay(Get("duration"))
    toast.fade:Stop()
    toast:SetAlpha(0)
    toast:Show()
    toast.show:Play()
end

local function OnEvent(_, _, level, health, power, talents, _, ...)
    Show(level, health, power, talents, ...)
end

local function Apply()
    if not Enabled() then
        if events then events:UnregisterEvent("PLAYER_LEVEL_UP") end
        if toast then toast:Hide() end
        return
    end
    Build()
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", OnEvent)
    end
    events:RegisterEvent("PLAYER_LEVEL_UP")
end

-- Options-page entry points.
EllesmereUI._LevelUpToast = {
    Get = Get,
    Cfg = F.Cfg,
    Apply = Apply,
    -- A sample: the current level with typical gains.
    Preview = function() Show(UnitLevel("player"), 52, 38, 1, 1, 0, 2, 1) end,
}

F.Start(Apply, {
    key = "EUI_LevelUpToast", label = "Level Up Toast", order = 733, minWidth = 260,
    frame = function(build)
        if build then Build() end
        return anchor
    end,
    height = function() return ICON + PAD * 2 end,
    applyStyle = ApplyStyle,
})
