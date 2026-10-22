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

-------------------------------------------------------------------------------
--  Group roster: the other players, class-colored with their role. A secret
--  name (12.0.5+ instanced maps) only ever goes straight to SetText; a secret
--  class or role is left out (uncolored, no icon).
-------------------------------------------------------------------------------
local ROLE_ATLAS = {
    TANK    = "UI-LFG-RoleIcon-Tank-Micro-GroupFinder",
    HEALER  = "UI-LFG-RoleIcon-Healer-Micro-GroupFinder",
    DAMAGER = "UI-LFG-RoleIcon-DPS-Micro-GroupFinder",
}
local COL_W, ROW_H, ROLE_S, PER_COL = 118, 16, 12, 5
local issecretvalue = issecretvalue or function() return false end
local roster
local slots = {}                   -- { role, name } region pairs, reused
local units, groups, perGroup, colOf = {}, {}, {}, {}

local function Known(v, kind) return not issecretvalue(v) and type(v) == kind end

local function Slot(i)
    local s = slots[i]
    if not s then
        s = { role = roster:CreateTexture(nil, "ARTWORK"), name = roster:CreateFontString(nil, "OVERLAY") }
        s.role:SetSize(ROLE_S, ROLE_S)
        s.name:SetJustifyH("LEFT")
        s.name:SetWordWrap(false)
        s.name:SetWidth(COL_W - ROLE_S - 8)
        slots[i] = s
    end
    return s
end

-- The other members now: units[1..n], groups[i] = raid subgroup or nil.
local function ReadRoster()
    local raid = IsInRaid()
    local count = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
    if not Known(count, "number") then return 0, raid end
    local me = raid and UnitInRaid("player")
    if not Known(me, "number") then me = nil end
    local n = 0
    for i = 1, count do
        local unit = (raid and "raid" or "party") .. i
        local skip = false
        if raid then
            if me then
                skip = i == me
            else
                local isMe = UnitIsUnit(unit, "player")
                skip = not issecretvalue(isMe) and isMe == true
            end
        end
        if not skip then
            n = n + 1
            units[n] = unit
            local sub
            if raid then
                local _, _, g = GetRaidRosterInfo(i)
                if Known(g, "number") and g >= 1 and g <= 8 then sub = g end
            end
            groups[n] = sub
        end
    end
    return n, raid
end

function Card.ShowRoster()
    local n, raid = ReadRoster()
    if n == 0 then return end
    if not roster then
        roster = CreateFrame("Frame", nil, WorldFrame)
        roster:SetFrameStrata("TOOLTIP")
        roster:EnableMouse(false)
        local bg = roster:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.05, 0.7)
        roster.bar = roster:CreateTexture(nil, "ARTWORK")
        roster.bar:SetPoint("TOPLEFT")
        roster.bar:SetPoint("BOTTOMLEFT")
        roster.bar:SetWidth(3)
        roster.title = roster:CreateFontString(nil, "OVERLAY")
        roster.title:SetPoint("TOPLEFT", PAD, -10)
    end
    Card.Scale(roster)
    local r, g, b = EUI.GetAccentColor()
    roster.bar:SetColorTexture(r, g, b)
    EUI.ApplyModuleFont(roster.title, nil, 13, "extras")
    roster.title:SetTextColor(r, g, b)
    roster.title:SetText(raid and RAID or PARTY)

    -- Columns: one per raid subgroup in use, members of an unknown subgroup
    -- packed after them; a party is one column.
    for i = 1, 8 do perGroup[i] = 0; colOf[i] = nil end
    for i = 1, n do
        local sub = groups[i]
        if sub then perGroup[sub] = perGroup[sub] + 1 end
    end
    local cols = 0
    for i = 1, 8 do
        if perGroup[i] > 0 then cols = cols + 1; colOf[i] = cols end
    end
    local rowsIn, extra, maxRows = {}, 0, 0
    local top = -10 - roster.title:GetStringHeight() - 6
    for i = 1, n do
        local col, row
        if not raid then
            col, row = 1, i
        elseif groups[i] then
            col = colOf[groups[i]]
            rowsIn[col] = (rowsIn[col] or 0) + 1
            row = rowsIn[col]
        else
            col = cols + 1 + math.floor(extra / PER_COL)
            row = extra % PER_COL + 1
            extra = extra + 1
        end
        if row > maxRows then maxRows = row end
        local unit = units[i]
        local s = Slot(i)
        local x, y = PAD + (col - 1) * COL_W, top - (row - 1) * ROW_H
        local role = EUI.UnitEffectiveRole(unit)
        local atlas = Known(role, "string") and ROLE_ATLAS[role]
        s.role:ClearAllPoints()
        s.role:SetPoint("TOPLEFT", x, y - 1)
        if atlas then s.role:SetAtlas(atlas); s.role:Show() else s.role:Hide() end
        EUI.ApplyModuleFont(s.name, nil, 12, "extras")
        s.name:ClearAllPoints()
        s.name:SetPoint("TOPLEFT", x + ROLE_S + 4, y)
        s.name:SetText((UnitName(unit)))
        local _, class = UnitClass(unit)
        if Known(class, "string") then
            local c = EUI.GetClassColor(class)
            s.name:SetTextColor(c.r, c.g, c.b)
        else
            s.name:SetTextColor(1, 1, 1)
        end
        s.name:Show()
    end
    for i = n + 1, #slots do slots[i].role:Hide(); slots[i].name:Hide() end
    if raid and extra > 0 then cols = cols + math.ceil(extra / PER_COL) end
    if not raid then cols = 1 end
    roster:SetSize(2 * PAD + cols * COL_W - 8, -top + maxRows * ROW_H + 10)
    roster:ClearAllPoints()
    roster:SetPoint("BOTTOMLEFT", WorldFrame, "BOTTOMLEFT", 30, 30)
    roster:Show()
end

function Card.Hide()
    if card then card:Hide() end
    if roster then roster:Hide() end
end
