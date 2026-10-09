if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_MapTravel.lua  (WoW Forever only)
--  Travel pins on the world map, each set its own toggle (all off by default):
--   - Transports: boats, zeppelins and the tram, with where each one goes.
--   - Zone exits: an arrow on each road out of the zone, toward the zone it
--     leads to.
--   - Instance entrances: dungeons and raids.
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
local F = module.Feature("mapTravel", { transports = false, exits = false, instances = false })

local PIN_SIZE   = 22
local ARROW_SIZE = 20

local KIND_ATLAS = {
    boat     = "flightmasterferry",
    zeppelin = "vehicle-air-horde",
    tram     = "vehicle-alliancecart",
}

local data, provider, layer, waiter
local added = false
local pins, used = {}, 0

local function AnyOn()
    return F.Get("transports") or F.Get("exits") or F.Get("instances")
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
        p:SetScript("OnEnter", PinOnEnter)
        p:SetScript("OnLeave", PinOnLeave)
        pins[used] = p
    end
    return p
end

-- A pin at (x, y) of the canvas (0..1), kept the same size on screen at any zoom.
local function Place(x, y, atlas, size, tip, rotation)
    local canvas = layer:GetParent()
    local w, h = canvas:GetSize()
    local s = size / canvas:GetScale()
    local p = NextPin()
    p:SetSize(s, s)
    p:ClearAllPoints()
    p:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
    p.tex:SetAtlas(atlas)
    p.tex:SetRotation(rotation or 0)
    p.tip = tip
    p:Show()
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

local function DrawZone(zone, shown, isZone)
    if F.Get("transports") then
        local list = data.transports[zone]
        if list then
            for i = 1, #list do
                local t = list[i]
                local x, y = Project(zone, shown, t[1] / 100, t[2] / 100)
                if x then Place(x, y, KIND_ATLAS[t[3]], PIN_SIZE, TransportTip(t)) end
            end
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
end

local function Refresh()
    Clear()
    local mapID = WorldMapFrame:GetMapID()
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
    layer:SetFrameLevel(WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_DUNGEON_ENTRANCE"))

    provider = CreateFromMixins(MapCanvasDataProviderMixin)
    provider.OnMapChanged = Refresh
    provider.RefreshAllData = Refresh
    provider.RemoveAllData = Clear
    provider.OnCanvasScaleChanged = Refresh
    provider.OnGlobalAlphaChanged = function(self) layer:SetAlpha(self:GetMap():GetGlobalAlpha()) end
end

-- Nothing exists until a toggle is first on; all off, the provider is removed.
-- The world map loads on demand, so building may wait for it.
local function Apply()
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
    if WorldMapFrame:IsShown() then Refresh() end
end

-- Options-page entry points.
EllesmereUI._MapTravel = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply)
