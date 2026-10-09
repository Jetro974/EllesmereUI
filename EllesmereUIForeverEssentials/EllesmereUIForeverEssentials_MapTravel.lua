if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_MapTravel.lua  (WoW Forever only)
--  Travel pins on the world map, each set its own toggle (all off by default):
--   - Transports: boats, zeppelins and the tram, with where each one goes.
--   - Zone exits: an arrow on each road out of the zone, toward the zone it
--     leads to.
--   - Instance entrances: dungeons and raids.
--   - Flight points: the game's own list for the map, undiscovered ones
--     included (the map only draws them where the game asks it to).
--   - Town services (banker, auctioneer, flight master, mailbox, innkeeper,
--     repair, stable master, battlemaster, class and profession trainers):
--     learned where the player uses them (PLAYER_INTERACTION_MANAGER_FRAME_SHOW
--     and the player's map position), each kind its own cog toggle.
--  Hovering a pin names it; pins never take clicks (moving the map from our
--  code would leave its state tainted), so the map's own clicks go through
--  them. A continent map stays clean: no pins, the zone under the cursor lists
--  its transports, instances and flight points in a tooltip.
--
--  Taint: nothing of Blizzard's map is hooked and no pin comes from its pools.
--  A data provider (the map's extension point, which the canvas only calls
--  through secureexecuterange) reports map changes, shows and zoom; the pins
--  are frames of our own on a frame of ours, child of the canvas. On a
--  continent, another frame of ours reads the cursor and the canvas geometry
--  through widget API (as Zone Levels does) to find the hovered zone.
--  Places: EllesmereUIForeverEssentials_MapTravelData.lua.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.mapTravel; unset keys read these.
-- learned: uiMapID = { { kind, x, y, label }, ... } (town services met).
-- svc: kind = false for a service kind hidden in the cog.
local F = module.Feature("mapTravel", { transports = false, exits = false, instances = false,
    flights = false, services = false })

local PIN_SIZE   = 22
local ARROW_SIZE = 20
local INSTANCE_SIZE = 32  -- the portal art leaves a wide margin in its atlas
local SAME_SPOT  = 0.03  -- a service met again this close (map fraction) is the same one

local KIND_ATLAS = {
    boat      = "flightmasterferry",
    zeppelin  = "vehicle-air-horde",
    tram      = "vehicle-alliancecart",
    skycutter = "vehicle-air-alliance",
    portal    = "mageportalalliance",
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

local data, provider, layer, waiter, recorder, taxiWatch, watcher
local added = false
local pins, used = {}, 0
local shownKey  -- what the pins show (map and toggles); nil when cleared

local function AnyOn()
    return F.Get("transports") or F.Get("exits") or F.Get("instances") or F.Get("flights")
        or F.Get("services")
end

local function ServiceShown(kind)
    local svc = F.Get("svc")
    return not svc or svc[kind] ~= false
end

-- Pins that touch on screen (it depends on the zoom) share one tooltip: the
-- hovered pin's first, then each one touching it. Offsets and sizes are both
-- in the pins' own (scaled) units, as Anchor sets them.
local function PinOnEnter(self)
    local canvas = layer:GetParent()
    local w, h = canvas:GetSize()
    local cs = canvas:GetScale()
    local tip = self.tip
    for i = 1, used do
        local p = pins[i]
        if p ~= self then
            local reach = (p.size + self.size) / 2
            if math.abs(p.x - self.x) * w * cs < reach and math.abs(p.y - self.y) * h * cs < reach then
                tip = tip .. "\n\n" .. p.tip
            end
        end
    end
    EllesmereUI.ShowWidgetTooltip(self, tip)
end

local function PinOnLeave()
    EllesmereUI.HideWidgetTooltip()
end

local function Clear()
    for i = 1, used do pins[i]:Hide() end
    used = 0
    shownKey = nil
    if watcher then watcher:Hide() end
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
    p.x, p.y, p.size = x, y, size
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
    -- The place alone ("Orgrimmar"), its zone when the area has no name.
    local area = C_Map.GetAreaInfo(t[5])
    local where = area and area ~= "" and area or ZoneName(t[4])
    if t[3] == "boat" then return EllesmereUI.Lf("Boat to %s", where) end
    if t[3] == "zeppelin" then return EllesmereUI.Lf("Zeppelin to %s", where) end
    if t[3] == "skycutter" then return EllesmereUI.Lf("Skycutter to %s", where) end
    if t[3] == "portal" then return EllesmereUI.Lf("Portal to %s", where) end
    return EllesmereUI.Lf("Tram to %s", where)
end

-- The instance's name, the entrance or wings it opens on, then its kind.
local function InstanceTip(i)
    local tip = GetRealZoneText(i[3])
    if i[5] then tip = tip .. "\n|cffffffff" .. EllesmereUI.L(i[5]) .. "|r" end
    return tip .. "\n" .. (i[4] and EllesmereUI.L("Raid") or EllesmereUI.L("Dungeon"))
end

-- The arrow's angle toward the destination zone's middle, read on the continent.
local function ExitRotation(zone, x, y, dest)
    local info = C_Map.GetMapInfo(zone)
    local continent = info and info.parentMapID
    if not continent or continent == 0 then return 0 end
    local zl, zr, zt, zb = C_Map.GetMapRectOnMap(zone, continent)
    local l, r, t, b = C_Map.GetMapRectOnMap(dest, continent)
    if not (zl and l) then return 0 end
    local px, py = zl + x * (zr - zl), zt + y * (zb - zt)
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
        -- Each destination on its own line, led by its transport's icon.
        local line = ("|A:%s:16:16|a %s"):format(KIND_ATLAS[t[3]], TransportTip(t))
        if g then
            g.tip = g.tip .. "\n" .. line
            g.count = g.count + 1
        else
            groups[#groups + 1] = { x = t[1], y = t[2], atlas = KIND_ATLAS[t[3]], tip = line, count = 1 }
        end
    end
    transportGroups[zone] = groups
    return groups
end

-- A zone map's pins.
local function DrawZone(zone)
    if F.Get("transports") then
        local groups = TransportGroups(zone)
        for i = 1, #groups do
            local g = groups[i]
            Place(g.x / 100, g.y / 100, g.atlas, PIN_SIZE, g.tip, nil, g.count)
        end
    end
    if F.Get("instances") then
        local list = data.instances[zone]
        if list then
            for i = 1, #list do
                local e = list[i]
                Place(e[1] / 100, e[2] / 100, e[4] and "raid" or "dungeon", INSTANCE_SIZE, InstanceTip(e))
            end
        end
    end
    if F.Get("exits") then
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
    if F.Get("services") then
        local learned = F.Get("learned")
        local list = learned and learned[zone]
        if list then
            for i = 1, #list do
                local s = list[i]
                local svc = SERVICE_BY_KIND[s[1]]
                if svc and ServiceShown(s[1]) then
                    local tip = EllesmereUI.L(svc.name)
                    if s[4] then tip = tip .. "\n|cffffffff" .. s[4] .. "|r" end
                    Place(s[2], s[3], svc.icon, PIN_SIZE, tip)
                end
            end
        end
    end
end

-- The flight masters standing on a map (the game also lists those of the rest
-- of the continent, off its edges), the other faction's and the retired ones
-- ("zz" names) left out; none where the map draws its own.
local function FlightNodes(mapID)
    if C_TaxiMap.ShouldMapShowTaxiNodes(mapID) then return nil end
    local nodes = C_TaxiMap.GetTaxiNodesForMap(mapID)
    if not nodes then return nil end
    local Faction = Enum.FlightPathFaction
    local mine = UnitFactionGroup("player") == "Horde" and Faction.Horde or Faction.Alliance
    local list = {}
    for i = 1, #nodes do
        local n = nodes[i]
        local x, y = n.position.x, n.position.y
        if (n.faction == Faction.Neutral or n.faction == mine) and not n.name:find("^zz")
            and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            if n.isUndiscovered then
                n.note = n.faction == Faction.Neutral and UNDISCOVERED_NEUTRAL_FLIGHTPOINT
                    or UNDISCOVERED_FACTION_FLIGHTPOINT:format(mine == Faction.Horde and FACTION_HORDE or FACTION_ALLIANCE)
            end
            if n.atlasName == "" then n.atlasName = "flightmaster" end
            list[#list + 1] = n
        end
    end
    return list
end

local function DrawFlights(mapID)
    local list = FlightNodes(mapID)
    if not list then return end
    for i = 1, #list do
        local n = list[i]
        local tip = n.note and (n.name .. "\n|cff808080" .. n.note .. "|r") or n.name
        Place(n.position.x, n.position.y, n.atlasName, PIN_SIZE, tip)
    end
end

-- A continent keeps its art clean: no pins, and the zone under the cursor
-- lists its points in a tooltip, each line led by its pin's icon.
local function ZoneList(zone)
    local lines = {}
    if F.Get("transports") then
        local groups = TransportGroups(zone)
        for i = 1, #groups do lines[#lines + 1] = groups[i].tip end
    end
    if F.Get("instances") then
        -- Each instance once, whatever its number of entrances.
        local list, seen = data.instances[zone], {}
        for i = 1, list and #list or 0 do
            local e = list[i]
            if not seen[e[3]] then
                seen[e[3]] = true
                lines[#lines + 1] = ("|A:%s:16:16|a %s"):format(e[4] and "raid" or "dungeon", GetRealZoneText(e[3]))
            end
        end
    end
    if F.Get("flights") then
        local list = FlightNodes(zone)
        for i = 1, list and #list or 0 do
            local n = list[i]
            -- "Ratchet, The Barrens": the zone already heads the list.
            local name = n.name:match("^[^,]+")
            if n.note then name = "|cff808080" .. name .. "|r" end
            lines[#lines + 1] = ("|A:%s:16:16|a %s"):format(n.atlasName, name)
        end
    end
    if #lines == 0 then return nil end
    return "|cffffd100" .. ZoneName(zone) .. "|r\n" .. table.concat(lines, "\n")
end

-- The zone (child map) under the cursor, or nil: the map's own label lookup,
-- with the cursor normalized against the canvas by widget API only.
local function HoveredZone(scroll)
    if not scroll:IsMouseOver() then return nil end
    local canvas = scroll.Child
    local left, top = canvas:GetLeft(), canvas:GetTop()
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    if not (left and top) or width == 0 or height == 0 then return nil end
    local cx, cy = GetCursorPosition()
    local scale = canvas:GetEffectiveScale()
    local mapID = WorldMapFrame:GetMapID()
    local info = C_Map.GetMapInfoAtPosition(mapID, (cx / scale - left) / width, (top - cy / scale) / height)
    if info and info.mapID ~= mapID then return info.mapID end
end

local UPDATE_INTERVAL = 0.15
local function WatchUpdate(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed < UPDATE_INTERVAL then return end
    self.elapsed = 0
    local zone = HoveredZone(self:GetParent())
    if zone == self.zone then return end
    self.zone = zone
    local text = zone and ZoneList(zone)
    if text then
        EllesmereUI.ShowWidgetTooltip(self, text, { anchor = "cursor", justify = "LEFT" })
        self.showing = true
    elseif self.showing then
        EllesmereUI.HideWidgetTooltip()
        self.showing = false
    end
end

local function WatchHide(self)
    self.zone = nil
    if self.showing then
        EllesmereUI.HideWidgetTooltip()
        self.showing = false
    end
end

-- The map redraws its providers often (shows, quest and area updates): the
-- pins are rebuilt only when the map or the toggles changed, so a hovered
-- pin keeps its tooltip.
local function Refresh(force)
    local mapID = WorldMapFrame:GetMapID()
    local key = mapID and (mapID .. (F.Get("transports") and "t" or "")
        .. (F.Get("instances") and "i" or "") .. (F.Get("exits") and "e" or "")
        .. (F.Get("flights") and "f" or "")
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
        -- Zone exits have nothing to list there.
        watcher:SetShown(F.Get("transports") or F.Get("instances") or F.Get("flights"))
        return
    end
    if F.Get("flights") then DrawFlights(mapID) end
    DrawZone(mapID)
end

local function Build()
    data = module.MapTravelData()
    module.MapTravelData = nil

    layer = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer.Child)
    layer:SetAllPoints()
    -- Above the map's own points of interest (a city's pin must not take the
    -- mouse from a dock or a tower beside it).
    layer:SetFrameLevel(WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_MAP_LINK"))

    -- Reads the hovered zone while a continent shows (hidden otherwise, and
    -- with the map, so it only updates then).
    watcher = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer)
    watcher.elapsed = 0
    watcher:Hide()
    watcher:SetScript("OnUpdate", WatchUpdate)
    watcher:SetScript("OnHide", WatchHide)

    provider = CreateFromMixins(MapCanvasDataProviderMixin)
    provider.OnMapChanged = function() Refresh() end
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
        return "class", (UnitClass("player"))
    end
end

-- A service used where the player stands: stored for the map the player is
-- on, the same kind and label met again close by moving the existing one.
local function Learn(_, _, interaction)
    local kind, label = ServiceOf(interaction)
    if not kind then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    local cfg = F.Cfg()
    cfg.learned = cfg.learned or {}
    local list = cfg.learned[mapID]
    if not list then list = {}; cfg.learned[mapID] = list end
    for i = 1, #list do
        local s = list[i]
        if s[1] == kind and s[4] == label
            and math.abs(s[2] - x) < SAME_SPOT and math.abs(s[3] - y) < SAME_SPOT then
            s[2], s[3] = x, y
            return
        end
    end
    list[#list + 1] = { kind, x, y, label }
    if WorldMapFrame and WorldMapFrame:IsShown() then Refresh(true) end
end

-- Listening only while Town Services is on.
local function SyncRecorder()
    local on = F.Get("services")
    if on and not recorder then
        recorder = CreateFrame("Frame")
        recorder:SetScript("OnEvent", Learn)
    end
    if not recorder then return end
    if on then
        recorder:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    else
        recorder:UnregisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
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
        if taxiWatch then taxiWatch:UnregisterEvent("TAXI_NODE_STATUS_CHANGED") end
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
    -- A flight point found: the next draw rebuilds the pins.
    if F.Get("flights") then
        if not taxiWatch then
            taxiWatch = CreateFrame("Frame")
            taxiWatch:SetScript("OnEvent", function() shownKey = nil end)
        end
        taxiWatch:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
    elseif taxiWatch then
        taxiWatch:UnregisterEvent("TAXI_NODE_STATUS_CHANGED")
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
