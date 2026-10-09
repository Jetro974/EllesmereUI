if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_MapTravel.lua  (WoW Forever only)
--  Travel pins on the world map, each set its own toggle (all off by default):
--   - Transports: boats, zeppelins and the tram, with where each one goes.
--   - Zone exits: an arrow on each road out of the zone, toward the zone it
--     leads to.
--   - Instance entrances: dungeons and raids.
--   - Town services (banker, auctioneer, flight master, mailbox, innkeeper,
--     repair, stable master, battlemaster, class and profession trainers):
--     learned where the player uses them (PLAYER_INTERACTION_MANAGER_FRAME_SHOW
--     and the player's map position), each kind its own cog toggle, and
--     shared with the guild and group when the cog says so.
--  Transports and instances also show on the continent maps. Hovering a pin
--  names it; pins never take clicks (moving the map from our code would leave
--  its state tainted), so the map's own clicks go through them.
--
--  Taint: nothing of Blizzard's map is hooked and no pin comes from its pools.
--  A data provider (the map's extension point, which the canvas only calls
--  through secureexecuterange) reports map changes, shows and zoom; the pins
--  are frames of our own on a frame of ours, child of the canvas.
--  Places: EllesmereUIForeverEssentials_MapTravelData.lua.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.mapTravel; unset keys read these.
-- learned: uiMapID = { { kind, x, y, label }, ... } (town services met).
-- svc: kind = false for a service kind hidden in the cog.
local F = module.Feature("mapTravel", { transports = false, exits = false, instances = false, services = false, share = false })

local PIN_SIZE   = 22
local ARROW_SIZE = 20
local SAME_SPOT  = 0.03  -- a service met again this close (map fraction) is the same one

local KIND_ATLAS = {
    boat     = "flightmasterferry",
    zeppelin = "vehicle-air-horde",
    tram     = "vehicle-alliancecart",
}

-- Town services, in cog order: kind, icon (atlas or file), name.
local SERVICES = {
    { kind = "bank",    icon = "banker",       name = "Banker" },
    { kind = "auction", icon = "auctioneer",   name = "Auctioneer" },
    { kind = "flight",  icon = "flightmaster", name = "Flight Master" },
    { kind = "mail",    icon = "mailbox",      name = "Mailbox" },
    { kind = "inn",     icon = "innkeeper",    name = "Innkeeper" },
    { kind = "repair",  icon = "repair",       name = "Repair" },
    { kind = "stable",  icon = "Interface\\Cursor\\Crosshair\\StableMaster", name = "Stable Master" },
    { kind = "battle",  icon = "battlemaster", name = "Battlemaster" },
    { kind = "class",   icon = "class",        name = "Class Trainer" },
    { kind = "prof",    icon = "profession",   name = "Profession Trainer" },
}
local SERVICE_BY_KIND = {}
for i = 1, #SERVICES do SERVICE_BY_KIND[SERVICES[i].kind] = SERVICES[i] end

local data, provider, layer, waiter, recorder
local AskAbout  -- defined with the sharing code below
local added = false
local pins, used = {}, 0
local shownKey  -- what the pins show (map and toggles); nil when cleared

local function AnyOn()
    return F.Get("transports") or F.Get("exits") or F.Get("instances") or F.Get("services")
end

local function ServiceShown(kind)
    local svc = F.Get("svc")
    return not svc or svc[kind] ~= false
end

local function PinOnEnter(self)
    EllesmereUI.ShowWidgetTooltip(self, self.tip)
end

local function PinOnLeave()
    EllesmereUI.HideWidgetTooltip()
end

local function Clear()
    for i = 1, used do pins[i]:Hide() end
    used = 0
    shownKey = nil
end

-- The next pin from our pool: hover only, clicks go through to the map.
local function NextPin()
    used = used + 1
    local p = pins[used]
    if not p then
        p = CreateFrame("Frame", nil, layer)
        p:SetMouseMotionEnabled(true)
        p:SetMouseClickEnabled(false)
        p.tex = p:CreateTexture(nil, "ARTWORK")
        p.tex:SetAllPoints()
        p.count = p:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        p.count:SetPoint("BOTTOMRIGHT", 4, -2)
        p:SetScript("OnEnter", PinOnEnter)
        p:SetScript("OnLeave", PinOnLeave)
        pins[used] = p
    end
    return p
end

-- Pins are scaled against the canvas, so they keep one size on screen at any
-- zoom; their offsets are in their own (scaled) units.
local function Anchor(p)
    local canvas = layer:GetParent()
    local w, h = canvas:GetSize()
    local cs = canvas:GetScale()
    p:SetScale(1 / cs)
    p:ClearAllPoints()
    p:SetPoint("CENTER", canvas, "TOPLEFT", p.x * w * cs, -p.y * h * cs)
end

-- A pin at (x, y) of the canvas (0..1); count > 1 shows as a badge.
local function Place(x, y, atlas, size, tip, rotation, count)
    local p = NextPin()
    p.x, p.y = x, y
    p:SetSize(size, size)
    Anchor(p)
    if atlas:find("\\", 1, true) then p.tex:SetTexture(atlas) else p.tex:SetAtlas(atlas) end
    p.tex:SetRotation(rotation or 0)
    p.count:SetText(count and count > 1 and count or "")
    p.tip = tip
    p:Show()
end

-- A zoom: the same pins, rescaled (rebuilding them would drop the tooltip).
local function Rescale()
    for i = 1, used do Anchor(pins[i]) end
end

local function ZoneName(uiMapID)
    local info = C_Map.GetMapInfo(uiMapID)
    return info and info.name or ""
end

local function TransportTip(t)
    local area = C_Map.GetAreaInfo(t[5])
    local zone = ZoneName(t[4])
    local where = area and area ~= zone and (area .. ", " .. zone) or zone
    if t[3] == "boat" then return EllesmereUI.Lf("Boat to %s", where) end
    if t[3] == "zeppelin" then return EllesmereUI.Lf("Zeppelin to %s", where) end
    return EllesmereUI.Lf("Tram to %s", where)
end

local function InstanceTip(i)
    return GetRealZoneText(i[3]) .. "\n" .. (i[4] and EllesmereUI.L("Raid") or EllesmereUI.L("Dungeon"))
end

-- Where a zone point lands on the shown map: the zone itself, or a map that
-- contains it (the continent).
local function Project(zone, shown, x, y)
    if zone == shown then return x, y end
    local left, right, top, bottom = C_Map.GetMapRectOnMap(zone, shown)
    if not left then return nil end
    return left + x * (right - left), top + y * (bottom - top)
end

-- The arrow's angle toward the destination zone's middle, read on the continent.
local function ExitRotation(zone, x, y, dest)
    local info = C_Map.GetMapInfo(zone)
    local continent = info and info.parentMapID
    if not continent or continent == 0 then return 0 end
    local px, py = Project(zone, continent, x, y)
    local l, r, t, b = C_Map.GetMapRectOnMap(dest, continent)
    if not (px and l) then return 0 end
    local dx, dy = (l + r) / 2 - px, (t + b) / 2 - py
    return math.atan2(-dx, -dy)  -- the atlas points up; screen y grows down
end

-- A zone's transports, those of one place (a dock's boats, a tower's
-- zeppelins) sharing one pin whose tooltip lists them all. Built once per zone.
local GROUP_DIST = 7  -- percent of the zone map
local transportGroups = {}
local function TransportGroups(zone)
    local groups = transportGroups[zone]
    if groups then return groups end
    groups = {}
    local list = data.transports[zone] or {}
    for i = 1, #list do
        local t = list[i]
        local g
        for j = 1, #groups do
            local h = groups[j]
            if math.abs(h.x - t[1]) < GROUP_DIST and math.abs(h.y - t[2]) < GROUP_DIST then
                g = h
                break
            end
        end
        if g then
            g.tip = g.tip .. "\n" .. TransportTip(t)
            g.count = g.count + 1
        else
            groups[#groups + 1] = { x = t[1], y = t[2], atlas = KIND_ATLAS[t[3]], tip = TransportTip(t), count = 1 }
        end
    end
    -- A shared pin says how many it holds before listing them.
    for i = 1, #groups do
        local g = groups[i]
        if g.count > 1 then
            g.tip = "|cffffd100" .. EllesmereUI.Lf("%d transports", g.count) .. "|r\n" .. g.tip
        end
    end
    transportGroups[zone] = groups
    return groups
end

local function DrawZone(zone, shown, isZone)
    if F.Get("transports") then
        local groups = TransportGroups(zone)
        for i = 1, #groups do
            local g = groups[i]
            local x, y = Project(zone, shown, g.x / 100, g.y / 100)
            if x then Place(x, y, g.atlas, PIN_SIZE, g.tip, nil, g.count) end
        end
    end
    if F.Get("instances") then
        local list = data.instances[zone]
        if list then
            for i = 1, #list do
                local e = list[i]
                local x, y = Project(zone, shown, e[1] / 100, e[2] / 100)
                if x then Place(x, y, e[4] and "raid" or "dungeon", PIN_SIZE, InstanceTip(e)) end
            end
        end
    end
    if isZone and F.Get("exits") then
        local list = data.exits[zone]
        if list then
            for i = 1, #list do
                local e = list[i]
                local x, y = e[1] / 100, e[2] / 100
                Place(x, y, "poi-traveldirections-arrow", ARROW_SIZE, ZoneName(e[3]),
                    ExitRotation(zone, x, y, e[3]))
            end
        end
    end
    if isZone and F.Get("services") then
        local learned = F.Get("learned")
        local list = learned and learned[zone]
        if list then
            for i = 1, #list do
                local s = list[i]
                local svc = SERVICE_BY_KIND[s[1]]
                if svc and ServiceShown(s[1]) then
                    local tip = EllesmereUI.L(svc.name)
                    local label = s[1] == "class" and LOCALIZED_CLASS_NAMES_MALE[s[4]] or s[4]
                    if label then tip = tip .. "\n|cffffffff" .. label .. "|r" end
                    Place(s[2], s[3], svc.icon, PIN_SIZE, tip)
                end
            end
        end
    end
end

-- The map redraws its providers often (shows, quest and area updates): the
-- pins are rebuilt only when the map or the toggles changed, so a hovered
-- pin keeps its tooltip.
local function Refresh(force)
    local mapID = WorldMapFrame:GetMapID()
    local key = mapID and (mapID .. (F.Get("transports") and "t" or "")
        .. (F.Get("instances") and "i" or "") .. (F.Get("exits") and "e" or "")
        .. (F.Get("services") and "s" or ""))
    if key and key == shownKey and force ~= true then
        Rescale()
        return
    end
    Clear()
    shownKey = key
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info then return end
    if info.mapType == Enum.UIMapType.Continent then
        local children = C_Map.GetMapChildrenInfo(mapID)
        if not children then return end
        for i = 1, #children do
            DrawZone(children[i].mapID, mapID, false)
        end
    else
        DrawZone(mapID, mapID, true)
    end
end

local function Build()
    data = module.MapTravelData()
    module.MapTravelData = nil

    layer = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer.Child)
    layer:SetAllPoints()
    -- Above the map's own points of interest (a city's pin must not take the
    -- mouse from a dock or a tower beside it).
    layer:SetFrameLevel(WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_MAP_LINK"))

    provider = CreateFromMixins(MapCanvasDataProviderMixin)
    provider.OnMapChanged = function(self)
        Refresh()
        -- A town or zone opened: the guild and the group may know its services.
        local mapID = self:GetMap():GetMapID()
        local info = mapID and C_Map.GetMapInfo(mapID)
        if info and info.mapType >= Enum.UIMapType.Zone then AskAbout(mapID) end
    end
    provider.RefreshAllData = function() Refresh() end
    provider.RemoveAllData = Clear
    provider.OnCanvasScaleChanged = Rescale
    provider.OnGlobalAlphaChanged = function(self) layer:SetAlpha(self:GetMap():GetGlobalAlpha()) end
end

-- Which town service an NPC window opened for, and its label (the trainer's
-- class or profession), or nil.
local function ServiceOf(interaction)
    local T = Enum.PlayerInteractionType
    if interaction == T.Banker then return "bank" end
    if interaction == T.Auctioneer then return "auction" end
    if interaction == T.TaxiNode then return "flight" end
    if interaction == T.MailInfo then return "mail" end
    if interaction == T.Binder then return "inn" end
    if interaction == T.StableMaster then return "stable" end
    if interaction == T.BattleMaster then return "battle" end
    if interaction == T.Merchant then return CanMerchantRepair() and "repair" or nil end
    if interaction == T.Trainer then
        if IsTradeskillTrainer() then
            return "prof", GetTrainerServiceSkillLine(1) or UnitName("npc")
        end
        return "class", (select(2, UnitClass("player")))  -- the class token, the same in every language
    end
end

-- A service stored for a map: the same kind and label met again close by
-- moves the existing one. Returns true when the map gained an entry.
local function Store(mapID, kind, x, y, label)
    local cfg = F.Cfg()
    cfg.learned = cfg.learned or {}
    local list = cfg.learned[mapID]
    if not list then list = {}; cfg.learned[mapID] = list end
    for i = 1, #list do
        local s = list[i]
        if s[1] == kind and s[4] == label
            and math.abs(s[2] - x) < SAME_SPOT and math.abs(s[3] - y) < SAME_SPOT then
            s[2], s[3] = x, y
            return false
        end
    end
    list[#list + 1] = { kind, x, y, label }
    if WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame:GetMapID() == mapID then
        Refresh(true)
    end
    return true
end

-------------------------------------------------------------------------------
--  Sharing (Share Town Services, off by default): what one player learns
--  reaches the guild and the group through addon messages, and a town opened
--  on the map asks them for what they know there. One player answers a
--  question: each waits a random moment and stays quiet once another's
--  answer has started. Everything received is checked (map, kind, position,
--  label) before it is stored; sends are spaced out.
-------------------------------------------------------------------------------
local PREFIX       = "EUIMapSvc"
local SEND_GAP     = 0.25  -- seconds between two of our messages
local ANSWER_DELAY = 4     -- an answer waits up to this many seconds
local MAX_LABEL    = 40

local outbox, sending = {}, false
local asked = {}     -- mapID = true once asked this session
local answering = {} -- mapID = channel while our answer waits
local me

local function Sharing()
    return F.Get("services") and F.Get("share")
end

-- The channels a message goes to: the guild, and the group.
local function Channels()
    local guild = IsInGuild() and "GUILD" or nil
    local group = IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT"
        or IsInRaid() and "RAID" or IsInGroup() and "PARTY" or nil
    return guild, group
end

local function Drain()
    local msg = table.remove(outbox, 1)
    if not msg then
        sending = false
        return
    end
    C_ChatInfo.SendAddonMessage(PREFIX, msg[1], msg[2])
    C_Timer.After(SEND_GAP, Drain)
end

local function Send(text, channel)
    if not channel then return end
    outbox[#outbox + 1] = { text, channel }
    if not sending then
        sending = true
        Drain()
    end
end

local function EntryText(mapID, s)
    return ("L|%d|%s|%d|%d|%s"):format(mapID, s[1], math.floor(s[2] * 1000 + 0.5),
        math.floor(s[3] * 1000 + 0.5), s[4] or "")
end

local function Broadcast(text)
    local guild, group = Channels()
    Send(text, guild)
    Send(text, group)
end

-- A town opened on the map: ask the guild and the group once a session.
function AskAbout(mapID)
    if not Sharing() or asked[mapID] then return end
    asked[mapID] = true
    local learned = F.Get("learned")
    local n = learned and learned[mapID] and #learned[mapID] or 0
    Broadcast(("Q|%d|%d"):format(mapID, n))
end

local function Answer(mapID, channel)
    answering[mapID] = nil
    local learned = F.Get("learned")
    local list = learned and learned[mapID]
    if not list then return end
    for i = 1, #list do Send(EntryText(mapID, list[i]), channel) end
end

local function Receive(_, _, prefix, text, channel, sender)
    if prefix ~= PREFIX or sender == me or not Sharing() then return end
    local tag, a, b, c, d, e = strsplit("|", text, 6)
    local mapID = tonumber(a)
    if not (mapID and C_Map.GetMapInfo(mapID)) then return end
    if tag == "L" then
        -- Someone answers about this map: ours is not needed.
        answering[mapID] = nil
        local x, y = tonumber(c), tonumber(d)
        if not (SERVICE_BY_KIND[b] and x and y and x >= 0 and x <= 1000 and y >= 0 and y <= 1000) then
            return
        end
        local label = e and e:gsub("[|\r\n]", ""):sub(1, MAX_LABEL) or ""
        Store(mapID, b, x / 1000, y / 1000, label ~= "" and label or nil)
    elseif tag == "Q" then
        local theirs = tonumber(b) or 0
        local learned = F.Get("learned")
        local mine = learned and learned[mapID] and #learned[mapID] or 0
        if mine <= theirs or answering[mapID] then return end
        answering[mapID] = channel
        C_Timer.After(math.random() * ANSWER_DELAY, function()
            if answering[mapID] == channel then Answer(mapID, channel) end
        end)
    end
end

-- A service used where the player stands: stored, and shared when on.
local function Learn(_, _, interaction)
    local kind, label = ServiceOf(interaction)
    if not kind then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if Store(mapID, kind, x, y, label) and Sharing() then
        Broadcast(EntryText(mapID, { kind, x, y, label }))
    end
end

-- Listening only while Town Services is on; the addon channel only while it
-- is shared.
local function SyncRecorder()
    local on = F.Get("services")
    if on and not recorder then
        recorder = CreateFrame("Frame")
        recorder:SetScript("OnEvent", function(self, event, ...)
            if event == "CHAT_MSG_ADDON" then Receive(self, event, ...) else Learn(self, event, ...) end
        end)
    end
    if not recorder then return end
    if on then
        recorder:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    else
        recorder:UnregisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    end
    if Sharing() then
        me = me or (UnitName("player") .. "-" .. GetNormalizedRealmName())
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        recorder:RegisterEvent("CHAT_MSG_ADDON")
    else
        recorder:UnregisterEvent("CHAT_MSG_ADDON")
    end
end

-- Nothing exists until a toggle is first on; all off, the provider is removed.
-- The world map loads on demand, so building may wait for it.
local function Apply()
    SyncRecorder()
    if not AnyOn() then
        if added then
            WorldMapFrame:RemoveDataProvider(provider)
            added = false
        end
        if waiter then waiter:UnregisterEvent("ADDON_LOADED") end
        return
    end
    if not provider then
        if not C_AddOns.IsAddOnLoaded("Blizzard_WorldMap") then
            if not waiter then
                waiter = CreateFrame("Frame")
                waiter:SetScript("OnEvent", function(self, _, name)
                    if name ~= "Blizzard_WorldMap" then return end
                    self:UnregisterEvent("ADDON_LOADED")
                    Apply()
                end)
            end
            waiter:RegisterEvent("ADDON_LOADED")
            return
        end
        Build()
    end
    if not added then
        WorldMapFrame:AddDataProvider(provider)
        added = true
    end
    if WorldMapFrame:IsShown() then Refresh(true) end
end

-- Options-page entry points.
EllesmereUI._MapTravel = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
    services = SERVICES,
    ServiceShown = ServiceShown,
}

F.Start(Apply)
