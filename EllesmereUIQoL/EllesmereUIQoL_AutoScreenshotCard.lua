if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_AutoScreenshotCard.lua
--  The Auto Screenshots card: a header (event, character, date, zone) and the
--  event's own lines, shown only while a screenshot is taken with the
--  interface hidden. Addon frames on WorldFrame, which stays drawn while
--  UIParent is invisible; built on the first shot that shows them.
-------------------------------------------------------------------------------
local ns  = select(2, ...)
local EUI = EllesmereUI

local Card = {}
ns.AutoShotCard = Card

local PAD, ICON, MAXW, GAP = 14, 40, 380, 4
local DIM = 0.75

local card
local pool = {}

local function Build()
    card = CreateFrame("Frame", nil, WorldFrame)
    card:SetFrameStrata("TOOLTIP")
    card:EnableMouse(false)
    card:Hide()
    local bg = card:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.7)
    card.bar = card:CreateTexture(nil, "ARTWORK")
    card.bar:SetPoint("TOPLEFT")
    card.bar:SetPoint("BOTTOMLEFT")
    card.bar:SetWidth(3)
    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(ICON, ICON)
    card.icon:SetPoint("TOPLEFT", PAD, -PAD)
    card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.sep = card:CreateTexture(nil, "ARTWORK")
    card.sep:SetHeight(1)
end

local function Line(i)
    local fs = pool[i]
    if not fs then
        fs = card:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        pool[i] = fs
    end
    return fs
end

-- "Name - Realm" in the class color, and the date.
local function Who()
    local _, class = UnitClass("player")
    local c = EUI.GetClassColor(class)
    return EUI.HexColor(c.r, c.g, c.b) .. UnitName("player") .. " - " .. GetRealmName() .. "|r   "
        .. date("%Y-%m-%d %H:%M")
end

local function Where()
    local zone, sub = GetRealZoneText(), GetSubZoneText()
    if sub and sub ~= "" and sub ~= zone then return zone .. " - " .. sub end
    return zone
end

-- UIParent's scale on a WorldFrame child, like Blizzard's ActionStatus.
function Card.Scale(f)
    f:SetScale(UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale())
end

-- data: { title, icon, lines = { { text, r, g, b, big }, ... } }
function Card.Show(job)
    if not card then Build() end
    local data = job.card or {}
    Card.Scale(card)
    local r, g, b = EUI.GetAccentColor()
    card.bar:SetColorTexture(r, g, b)
    card.sep:SetColorTexture(r, g, b, 0.5)

    local rows, n = {}, 0
    local function add(text, size, cr, cg, cb)
        if type(text) ~= "string" or text == "" then return end
        n = n + 1
        local fs = Line(n)
        EUI.ApplyModuleFont(fs, nil, size, "extras")
        fs:SetWidth(MAXW)
        fs:SetText(text)
        fs:SetTextColor(cr or 1, cg or 1, cb or 1)
        rows[n] = fs
    end
    add(data.title or job.label, 17, r, g, b)
    add(Who(), 12)
    add(Where(), 12, DIM, DIM, DIM)
    local header = n
    for _, l in ipairs(data.lines or {}) do
        add(l[1], l[5] and 15 or 12, l[2], l[3], l[4])
    end
    for i = n + 1, #pool do pool[i]:Hide() end

    local left = PAD
    if data.icon then
        card.icon:SetTexture(data.icon)
        card.icon:Show()
        left = PAD + ICON + 10
    else
        card.icon:Hide()
    end
    local w = 0
    for i = 1, n do
        local sw = rows[i]:GetUnboundedStringWidth()
        if sw > w then w = sw end
    end
    w = math.min(math.ceil(w) + 2, MAXW)
    local y = -PAD
    for i = 1, n do
        local fs = rows[i]
        fs:SetWidth(w)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", left, y)
        fs:Show()
        y = y - fs:GetStringHeight() - GAP
        if i == header and n > header then
            y = y - 4
            card.sep:ClearAllPoints()
            card.sep:SetPoint("TOPLEFT", left, y)
            card.sep:SetWidth(w)
            card.sep:Show()
            y = y - 7
        end
    end
    if n == header then card.sep:Hide() end
    local h = -y - GAP + PAD
    if data.icon and h < ICON + 2 * PAD then h = ICON + 2 * PAD end
    card:SetSize(left + w + PAD, h)
    card:ClearAllPoints()
    card:SetPoint("BOTTOMRIGHT", WorldFrame, "BOTTOMRIGHT", -30, 30)
    card:Show()
end

function Card.Hide()
    if card then card:Hide() end
end
