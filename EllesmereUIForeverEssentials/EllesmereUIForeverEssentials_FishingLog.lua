if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_FishingLog.lua  (WoW Forever only)
--  Two fishing helpers that share one small window, shown while you fish
--  (the session of the Fishing file, followed through
--  module.fishingListeners). Both off by default.
--  Catch Log           what you have fished at this spot (zone and subzone):
--                      each catch counted, with its share; one new to the
--                      spot this session is marked. A fish's tooltip says
--                      where you caught it.
--  Fishing Extravaganza  during the Stranglethorn Fishing Extravaganza (the
--                      calendar's holiday), the Speckled Tastyfish you carry
--                      out of the 40 the contest asks for and the time left;
--                      at 40, a line in the chat and a sound.
--  The window is placed in Unlock Mode. Catches are only read from a loot
--  window the game marks as fishing loot, during a session.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.fishingLog: enabled (Catch Log), contest,
-- pos (Unlock Mode) and spots["<mapID>/<subzone>"] = { zone, sub, n (catches),
-- items = { [itemID] = count } }.
local F = module.Feature("fishingLog", { enabled = false, contest = false },
    { point = "CENTER", relPoint = "CENTER", x = 230, y = -180 })

local TASTYFISH, TASTYFISH_GOAL = 19807, 40  -- Speckled Tastyfish, and the contest's count
local CONTEST_HOLIDAY = 301                   -- Stranglethorn Fishing Extravaganza (Holidays.db2)
local WIDTH, ROW_H, MAX_ROWS, PAD = 230, 16, 8, 8

local ev = CreateFrame("Frame")
local frame, title, contestLine
local rows = {}
local fishing = false
local newHere = {}        -- [itemID] = true: first caught at this spot this session
local lastLoot            -- the loot source GUID last counted (one catch, one count)
local contestEnd          -- the contest's last minute of the day while it runs, or nil
local tastyWarned = false
local calendarAsked, hooked = false, false

local function Plain(v)
    if v == nil or issecretvalue(v) then return nil end
    return v
end

local function LogOn() return F.Enabled() end
local function ContestOn() return F.Get("contest") end

-- Where you stand: its key, the zone's name and the subzone's.
local function Spot()
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    local zone = (info and info.name) or GetZoneText() or ""
    local sub = GetSubZoneText() or ""
    return (mapID or 0) .. "/" .. sub, zone, sub
end

-------------------------------------------------------------------------------
--  The contest, from the calendar
-------------------------------------------------------------------------------
local function MinuteOfDay(t) return t.hour * 60 + t.minute end

local function ReadContest()
    contestEnd = nil
    if not (ContestOn() and C_Calendar and C_DateAndTime) then return end
    local now = C_DateAndTime.GetCurrentCalendarTime()
    local view = C_Calendar.GetMonthInfo(0)
    if not (now and view) then return end
    local offset = (now.year - view.year) * 12 + (now.month - view.month)
    local minute = MinuteOfDay(now)
    for i = 1, C_Calendar.GetNumDayEvents(offset, now.monthDay) do
        local e = C_Calendar.GetDayEvent(offset, now.monthDay, i)
        if e and Plain(e.calendarType) == "HOLIDAY" and Plain(e.eventID) == CONTEST_HOLIDAY then
            local st, en = e.startTime, e.endTime
            local from = (st and st.monthDay == now.monthDay) and MinuteOfDay(st) or 0
            local to = (en and en.monthDay == now.monthDay) and MinuteOfDay(en) or 24 * 60
            if minute >= from and minute < to then contestEnd = to end
        end
    end
end

local function ContestText()
    local now = C_DateAndTime.GetCurrentCalendarTime()
    local left = math.max(0, contestEnd - MinuteOfDay(now)) * 60
    local name = C_Item.GetItemNameByID(TASTYFISH) or EllesmereUI.L("Speckled Tastyfish")
    return EllesmereUI.Lf("%1$d/%2$d %3$s, ends in %4$s", C_Item.GetItemCount(TASTYFISH), TASTYFISH_GOAL,
        name, SecondsToTime(left, true))
end

local function CheckTastyfish()
    if not contestEnd then return end
    local count = C_Item.GetItemCount(TASTYFISH)
    if count < TASTYFISH_GOAL then
        tastyWarned = false
        return
    end
    if tastyWarned then return end
    tastyWarned = true
    EllesmereUI.Print(EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r "
        .. EllesmereUI.Lf("%1$d %2$s: take them to Booty Bay to win the contest.", count,
            C_Item.GetItemNameByID(TASTYFISH) or EllesmereUI.L("Speckled Tastyfish")))
    PlaySound(SOUNDKIT.RAID_WARNING)
end

-------------------------------------------------------------------------------
--  The window
-------------------------------------------------------------------------------
local function Build()
    if frame then return end
    local PP = EllesmereUI.PP
    frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(WIDTH, 40)
    frame:SetFrameStrata("MEDIUM")
    frame:EnableMouse(false)
    frame:Hide()
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.75)
    PP.CreateBorder(frame, 0, 0, 0, 1, 1, "OVERLAY", 2)
    title = EllesmereUI.MakeFont(frame, 12, nil, 1, 1, 1)
    title:SetPoint("TOPLEFT", PAD, -PAD)
    title:SetPoint("TOPRIGHT", -PAD, -PAD)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    contestLine = EllesmereUI.MakeFont(frame, 11, nil, 1, 0.82, 0)
    contestLine:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    contestLine:SetPoint("TOPRIGHT", title, "BOTTOMRIGHT", 0, -4)
    contestLine:SetJustifyH("LEFT")
    contestLine:SetWordWrap(false)
    F.Place(frame)
end

local function Row(i)
    local r = rows[i]
    if r then return r end
    r = {}
    r.icon = frame:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 2, ROW_H - 2)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.pct = EllesmereUI.MakeFont(frame, 11, nil, 0.7, 0.7, 0.7)
    r.pct:SetWidth(36)
    r.pct:SetJustifyH("RIGHT")
    r.count = EllesmereUI.MakeFont(frame, 11, nil, 1, 1, 1)
    r.count:SetWidth(32)
    r.count:SetJustifyH("RIGHT")
    r.name = EllesmereUI.MakeFont(frame, 11)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    rows[i] = r
    return r
end

local loading = {}  -- [itemID] = true while its name loads
local Redraw

local function ItemName(id)
    local name = C_Item.GetItemNameByID(id)
    if name then return name end
    if not loading[id] then
        loading[id] = true
        Item:CreateFromItemID(id):ContinueOnItemLoad(function()
            loading[id] = nil
            Redraw()
        end)
    end
    return "..."
end

local sorted = {}
local function ByCount(a, b) return a.count > b.count end

Redraw = function()
    if not frame or not frame:IsShown() then return end
    local y = PAD
    local key, zone, sub = Spot()
    local spot = LogOn() and F.Read().spots and F.Read().spots[key]
    local where = sub ~= "" and sub or zone
    if LogOn() then
        title:SetText(spot and (where .. "  |cff999999" .. EllesmereUI.Lf("%d catches", spot.n) .. "|r")
            or (where .. "  |cff999999" .. EllesmereUI.L("nothing caught here yet") .. "|r"))
    else
        title:SetText(EllesmereUI.L("Fishing Extravaganza"))
    end
    y = y + 14
    if contestEnd then
        contestLine:SetText(ContestText())
        contestLine:Show()
        y = y + 15
    else
        contestLine:Hide()
    end
    wipe(sorted)
    if spot then
        for id, count in pairs(spot.items) do sorted[#sorted + 1] = { id = id, count = count } end
        table.sort(sorted, ByCount)
    end
    local total = 0
    for i = 1, #sorted do total = total + sorted[i].count end
    local shown = math.min(#sorted, MAX_ROWS)
    if shown > 0 then y = y + 4 end
    for i = 1, shown do
        local e, r = sorted[i], Row(i)
        r.icon:ClearAllPoints()
        r.icon:SetPoint("TOPLEFT", PAD, -y - 1)
        r.icon:SetTexture(C_Item.GetItemIconByID(e.id))
        r.pct:ClearAllPoints()
        r.pct:SetPoint("TOPRIGHT", -PAD, -y - 2)
        r.pct:SetText(("%d%%"):format(math.floor(e.count / total * 100 + 0.5)))
        r.count:ClearAllPoints()
        r.count:SetPoint("RIGHT", r.pct, "LEFT", -4, 0)
        r.count:SetText(e.count)
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
        r.name:SetPoint("RIGHT", r.count, "LEFT", -4, 0)
        local q = C_Item.GetItemQualityByID(e.id)
        local c = ITEM_QUALITY_COLORS[q or 1] or ITEM_QUALITY_COLORS[1]
        r.name:SetText(ItemName(e.id) .. (newHere[e.id] and ("  |cff33ff66" .. EllesmereUI.L("new") .. "|r") or ""))
        r.name:SetTextColor(c.r, c.g, c.b)
        r.icon:Show(); r.pct:Show(); r.count:Show(); r.name:Show()
        y = y + ROW_H
    end
    for i = shown + 1, #rows do
        local r = rows[i]
        r.icon:Hide(); r.pct:Hide(); r.count:Hide(); r.name:Hide()
    end
    frame:SetHeight(y + PAD)
end

-- Shown while you fish, for the Catch Log or a running contest.
local function UpdateShown()
    local want = fishing and (LogOn() or (ContestOn() and contestEnd ~= nil))
    if not want then
        if frame then frame:Hide() end
        return
    end
    Build()
    frame:Show()
    Redraw()
end

-------------------------------------------------------------------------------
--  Catches
-------------------------------------------------------------------------------
local function OnLoot()
    if not IsFishingLoot() then return end
    local source = GetLootSourceInfo and Plain(GetLootSourceInfo(1))
    if source then
        if source == lastLoot then return end
        lastLoot = source
    end
    local key, zone, sub = Spot()
    local cfg = F.Cfg()
    cfg.spots = cfg.spots or {}
    local spot = cfg.spots[key]
    if not spot then
        spot = { zone = zone, sub = sub, n = 0, items = {} }
        cfg.spots[key] = spot
    end
    spot.n = spot.n + 1
    for i = 1, GetNumLootItems() do
        if GetLootSlotType(i) == Enum.LootSlotType.Item then
            local link = Plain(GetLootSlotLink(i))
            local id = link and C_Item.GetItemInfoInstant(link)
            if id then
                local qty = Plain(select(3, GetLootSlotInfo(i)))
                if not spot.items[id] then newHere[id] = true end
                spot.items[id] = (spot.items[id] or 0) + (type(qty) == "number" and qty or 1)
            end
        end
    end
    Redraw()
end

-- A fish's tooltip: the three spots it was caught at most.
local function OnItemTooltip(tooltip, data)
    if not LogOn() or not data then return end
    local id = Plain(data.id)
    local spots = id and F.Read().spots
    if not spots then return end
    local found = {}
    for _, spot in pairs(spots) do
        local count = spot.items[id]
        if count then
            found[#found + 1] = { name = spot.sub ~= "" and spot.sub or spot.zone, count = count }
        end
    end
    if #found == 0 then return end
    table.sort(found, ByCount)
    local parts = {}
    for i = 1, math.min(3, #found) do parts[i] = found[i].name .. " (" .. found[i].count .. ")" end
    tooltip:AddLine(EllesmereUI.L("Fished at:") .. " " .. table.concat(parts, ", "), 0.4, 0.8, 1, true)
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
ev:SetScript("OnEvent", function(_, event)
    if event == "LOOT_OPENED" then
        OnLoot()
    elseif event == "BAG_UPDATE_DELAYED" then
        CheckTastyfish()
        Redraw()
    elseif event == "CALENDAR_UPDATE_EVENT_LIST" then
        ReadContest()
        UpdateShown()
    end
end)

module.fishingListeners = module.fishingListeners or {}
table.insert(module.fishingListeners, function(on)
    fishing = on
    if on then
        wipe(newHere)
        ReadContest()
        if LogOn() then ev:RegisterEvent("LOOT_OPENED") end
        if contestEnd then
            ev:RegisterEvent("BAG_UPDATE_DELAYED")
            CheckTastyfish()
        end
    else
        ev:UnregisterEvent("LOOT_OPENED")
        ev:UnregisterEvent("BAG_UPDATE_DELAYED")
    end
    UpdateShown()
end)

-- The Fishing file follows sessions while either helper is on.
function module.FishingLogWanted() return LogOn() or ContestOn() end

local function Apply()
    if ContestOn() then
        ev:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
        if not calendarAsked and C_Calendar then
            calendarAsked = true
            C_Calendar.OpenCalendar()
        end
    else
        ev:UnregisterEvent("CALENDAR_UPDATE_EVENT_LIST")
        contestEnd = nil
    end
    if LogOn() and not hooked and TooltipDataProcessor then
        hooked = true
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
    end
    if not LogOn() then ev:UnregisterEvent("LOOT_OPENED") end
    -- Its session events follow FishingLogWanted.
    if EllesmereUI._Fishing then EllesmereUI._Fishing.Apply() end
    UpdateShown()
end

-- Options-page entry points.
EllesmereUI._FishingLog = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply, {
    key = "EUI_FishingLog", label = "Catch Log", order = 61,
    shown = function() return LogOn() or ContestOn() end,
    frame = function(build)
        if build then Build() end
        return frame
    end,
    size = function() return WIDTH, frame and frame:GetHeight() or 60 end,
})
