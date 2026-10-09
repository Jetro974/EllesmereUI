if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_AmmoCounter.lua  (WoW Forever only)
--  Hunters: the equipped ammo's icon and how many are left (the ammo slot
--  counts that type across the bags), orange under the warning threshold and
--  red under half of it. Placed by unlock mode. An optional alert shows
--  on screen when the count falls under the threshold, and at zero.
--
--  Event driven: bag and inventory changes (each shot takes ammo from a bag;
--  equipping other ammo only fires UNIT_INVENTORY_CHANGED).
--  Nothing is built for other classes or while the setting is off.
-------------------------------------------------------------------------------
local _, module = ...

local ICON_SIZE = 22
local PAD = 4
local NO_AMMO_ICON = "Interface\\Icons\\INV_Ammo_Arrow_02"

-- Settings live in EllesmereUIDB.ammoCounter; unset keys read these.
local F = module.Feature("ammoCounter", { enabled = false, width = 80, warn = 200, alert = false },
    { point = "CENTER", relPoint = "CENTER", x = 0, y = -200 })
local Get = F.Get

local IS_HUNTER = select(2, UnitClass("player")) == "HUNTER"
local frame, events
local alert, lastCount

-- Low Ammo Alert: a large line at the top of the screen and the raid warning
-- sound, once when the count falls under the threshold and once at zero.
local function Alert(text, r, g, b)
    if not alert then
        alert = UIParent:CreateFontString(nil, "OVERLAY")
        alert:SetFont(EllesmereUI.GetFontPath(), 30, EllesmereUI.SlugFlag("OUTLINE, SLUG"))
        alert:SetPoint("TOP", UIParent, "TOP", 0, -170)
        alert.fade = alert:CreateAnimationGroup()
        local hold = alert.fade:CreateAnimation("Alpha")
        hold:SetFromAlpha(1)
        hold:SetToAlpha(1)
        hold:SetDuration(2.5)
        local out = alert.fade:CreateAnimation("Alpha")
        out:SetFromAlpha(1)
        out:SetToAlpha(0)
        out:SetStartDelay(2.5)
        out:SetDuration(1)
        alert.fade:SetScript("OnFinished", function() alert:Hide() end)
    end
    alert:SetText(text)
    alert:SetTextColor(r, g, b)
    alert:Show()
    alert.fade:Stop()
    alert.fade:Play()
    PlaySound(SOUNDKIT.RAID_WARNING)
end

local function CheckAlert(count)
    local was = lastCount
    lastCount = count
    if not (was and Get("alert")) or count >= was then return end
    if count == 0 then
        Alert(EllesmereUI.L("Out of ammo!"), 1, 0.25, 0.25)
    elseif count < Get("warn") and was >= Get("warn") then
        Alert(EllesmereUI.Lf("Low ammo: %d left", count), 1, 0.6, 0.1)
    end
end

local function Update()
    if not frame then return end
    local count = GetInventoryItemCount("player", INVSLOT_AMMO) or 0
    CheckAlert(count)
    frame.icon:SetTexture(GetInventoryItemTexture("player", INVSLOT_AMMO) or NO_AMMO_ICON)
    frame.icon:SetDesaturated(count == 0)
    local warn = Get("warn")
    if count < warn / 2 then
        frame.count:SetTextColor(1, 0.25, 0.25)
    elseif count < warn then
        frame.count:SetTextColor(1, 0.6, 0.1)
    else
        frame.count:SetTextColor(1, 1, 1)
    end
    frame.count:SetText(count)
end

local function ApplyStyle()
    if not frame then return end
    frame:SetSize(Get("width"), ICON_SIZE + 2 * PAD)
end

local function Build()
    frame = CreateFrame("Frame", "EllesmereUIAmmoCounter", UIParent)
    frame:SetFrameStrata("MEDIUM")
    local bg = EllesmereUI.SolidTex(frame, "BACKGROUND", 0, 0, 0, 0.6)
    bg:SetAllPoints()
    EllesmereUI.MakeBorder(frame, 0, 0, 0, 1)
    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetSize(ICON_SIZE, ICON_SIZE)
    frame.icon:SetPoint("LEFT", PAD, 0)
    frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    frame.count = frame:CreateFontString(nil, "OVERLAY")
    frame.count:SetFont(EllesmereUI.GetFontPath(), 14, EllesmereUI.SlugFlag("OUTLINE, SLUG"))
    frame.count:SetPoint("LEFT", frame.icon, "RIGHT", PAD + 2, 0)
    frame.count:SetPoint("RIGHT", -PAD, 0)
    frame.count:SetJustifyH("CENTER")
    ApplyStyle()
    F.Place(frame)

    events = CreateFrame("Frame")
    events:SetScript("OnEvent", Update)
end

-- Off (or not a hunter): hidden and deaf. On: built once, then shown and
-- listening.
local function Apply()
    local on = IS_HUNTER and F.Enabled()
    if on and not frame then Build() end
    if not frame then return end
    frame:SetShown(on)
    if on then
        events:RegisterEvent("BAG_UPDATE_DELAYED")
        events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        events:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
        Update()
    else
        events:UnregisterAllEvents()
        lastCount = nil  -- turned back on, the first count is not a drop
    end
end

-- Options-page entry points.
EllesmereUI._AmmoCounter = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
    Update = Update,
    isHunter = IS_HUNTER,
}

F.Start(Apply, IS_HUNTER and {
    key = "EUI_AmmoCounter", label = "Ammo Counter", order = 740, minWidth = 50,
    frame = function(build)
        if build and not frame then Build() end
        return frame
    end,
    height = function() return ICON_SIZE + 2 * PAD end,
    applyStyle = ApplyStyle,
} or nil)
