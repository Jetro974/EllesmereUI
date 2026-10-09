if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_AmmoCounter.lua  (WoW Forever only)
--  Hunters: the equipped ammo's icon and how many are left (the ammo slot
--  counts that type across the bags), orange under the warning threshold and
--  red under a quarter of it. Placed by unlock mode.
--
--  Event driven: bag and equipment changes (each shot takes ammo from a bag).
--  Nothing is built for other classes or while the setting is off.
-------------------------------------------------------------------------------
local _, module = ...

local ICON_SIZE = 22
local PAD = 4
local NO_AMMO_ICON = "Interface\\Icons\\INV_Ammo_Arrow_02"

-- Settings live in EllesmereUIDB.ammoCounter; unset keys read these.
local F = module.Feature("ammoCounter", { enabled = false, width = 80, warn = 200 },
    { point = "CENTER", relPoint = "CENTER", x = 0, y = -200 })
local Get = F.Get

local IS_HUNTER = select(2, UnitClass("player")) == "HUNTER"
local frame, events

local function Update()
    if not frame then return end
    local count = GetInventoryItemCount("player", INVSLOT_AMMO) or 0
    frame.icon:SetTexture(GetInventoryItemTexture("player", INVSLOT_AMMO) or NO_AMMO_ICON)
    frame.icon:SetDesaturated(count == 0)
    local warn = Get("warn")
    if count < warn / 4 then
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
        Update()
    else
        events:UnregisterAllEvents()
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
