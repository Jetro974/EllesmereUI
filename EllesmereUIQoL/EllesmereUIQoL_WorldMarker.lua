if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_WorldMarker.lua  (WoW Forever only)
--  Replaces Blizzard's in-game navigation marker (SuperTrackedFrame) with our
--  own copy: Blizzard's icons (the corpse gets retail's tombstone, Forever's
--  own is drawn from its retail sheet through StockAtlas), distance and time
--  to arrival in the EllesmereUI font under it, an arrow on an ellipse around
--  the screen centre while the destination is off screen, and a short pulse
--  on arrival instead of the icon just vanishing.
--
--  The icon follows the engine's navigation frame (C_Navigation.GetFrame),
--  which only exists while In-Game Navigation (showInGameNavigation) is on:
--  enabling the option holds that CVar on, disabling hands it back.
--
--  Taint: read-only C_Navigation / C_SuperTrack getters. Blizzard's frame is
--  only reparented to a hidden holder (it is not protected and nothing secure
--  reads it), so its own arrival handling keeps running untouched.
--  Off by default; while off nothing below is built or registered.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
if not EUI.IS_FOREVER then return end

local CVAR  = "showInGameNavigation"
local OWNER = "EllesmereUIQoL"

local FONT_SIZE   = 13
local ETA_SIZE    = 11
local ARRIVE_YARDS  = 40   -- a frame lost closer than this is an arrival
local TEXT_INTERVAL = 0.1
local ETA_INTERVAL  = 0.25

-- Blizzard's own icon per tracking type (SuperTrackedFrame's iconLookup).
local ICON_DEFAULT = "Navigation-Tracked-Icon"
local ICON_PIN     = "Waypoint-MapPin-Tracked"
local ICON_CORPSE  = "Navigation-Tombstone-Icon"
local ICON_ARROW   = "Navigation-Tracked-Arrow"

-- Created in the main chunk so their handlers bill to this addon.
local ev  = CreateFrame("Frame")
local Drv = EUI.Tick.NewDriver(CreateFrame("Frame"))

local function Cfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.waypointCmd = EllesmereUIDB.waypointCmd or {}
    return EllesmereUIDB.waypointCmd
end
local function IsEnabled() return Cfg().worldMarker == true end

-------------------------------------------------------------------------------
--  Marker frame (built on first enable)
-------------------------------------------------------------------------------
local marker, body, pin, arrow, distText, etaText, pulse
local navFrame
local isClamped, lastDist, alpha = nil, nil, 0
local textAcc, etaAcc, etaDist, speed = 0, 0, nil, 0

local function IconFor()
    local st = Enum.SuperTrackingType
    local t = st and C_SuperTrack.GetHighestPrioritySuperTrackingType()
    if not t then return ICON_DEFAULT end
    if t == st.Corpse then return ICON_CORPSE end
    if t == st.UserWaypoint or t == st.Content then return ICON_PIN end
    return ICON_DEFAULT
end

-- An atlas at its own size times the pin size setting.
local function PaintAtlas(tex, name, s)
    EUI.StockAtlas(tex, name)
    local info = EUI.StockAtlasInfo(name)
    if info then tex:SetSize(info.width * s, info.height * s) end
end

local function Scale() return (Cfg().markerScale or 100) / 100 end

local function UpdateIcon()
    if not marker then return end
    PaintAtlas(pin, IconFor(), Scale())
end

local function ApplyLayout()
    if not marker then return end
    local c = Cfg()
    local s = Scale()
    PaintAtlas(pin, IconFor(), s)
    PaintAtlas(arrow, ICON_ARROW, s)
    local font = (EUI.GetFontPath("extras")) or STANDARD_TEXT_FONT
    local flag = (EUI.GetFontOutlineFlag and EUI.GetFontOutlineFlag("qol")) or "OUTLINE"
    distText:SetFont(font, math.floor(FONT_SIZE * s + 0.5), flag)
    etaText:SetFont(font, math.floor(ETA_SIZE * s + 0.5), flag)
    distText:SetShown(c.markerDistance ~= false)
    etaText:SetShown(not isClamped and c.markerETA ~= false)
end

local function BuildMarker()
    if marker then return end
    marker = CreateFrame("Frame", nil, UIParent)
    marker:SetFrameStrata("BACKGROUND")
    marker:SetSize(1, 1)
    marker:Hide()

    -- Everything the arrival pulse scales and fades.
    body = CreateFrame("Frame", nil, marker)
    body:SetAllPoints()

    -- Centred on the navigation frame, as Blizzard draws it.
    pin = body:CreateTexture(nil, "ARTWORK")
    pin:SetPoint("CENTER", marker, "CENTER")

    arrow = body:CreateTexture(nil, "ARTWORK")
    arrow:Hide()

    distText = body:CreateFontString(nil, "OVERLAY")
    distText:SetPoint("TOP", pin, "BOTTOM", 0, -4)
    distText:SetTextColor(1, 0.82, 0)
    etaText = body:CreateFontString(nil, "OVERLAY")
    etaText:SetPoint("TOP", distText, "BOTTOM", 0, -1)
    etaText:SetTextColor(0.8, 0.8, 0.8)

    pulse = body:CreateAnimationGroup()
    local grow = pulse:CreateAnimation("Scale")
    grow:SetScaleFrom(1, 1)
    grow:SetScaleTo(1.6, 1.6)
    grow:SetDuration(0.6)
    grow:SetSmoothing("OUT")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(0.6)
    pulse:SetScript("OnFinished", function()
        marker:Hide()
        body:SetAlpha(1)
    end)

    ApplyLayout()
end

-------------------------------------------------------------------------------
--  Placement
-------------------------------------------------------------------------------
-- On screen: on the navigation frame. Clamped: on an ellipse around the
-- screen centre, the arrow outside it pointing at the destination.
local function SetClamped(clamped)
    isClamped = clamped
    if not clamped then
        marker:ClearAllPoints()
        marker:SetPoint("CENTER", navFrame, "CENTER")
    end
    arrow:SetShown(clamped)
    etaText:SetShown(not clamped and Cfg().markerETA ~= false)
end

local function PlaceClamped()
    local nx, ny = navFrame:GetCenter()
    if not nx then return end
    local us = UIParent:GetEffectiveScale()
    local ns = navFrame:GetEffectiveScale() / us
    local cx, cy = UIParent:GetCenter()
    local dx, dy = nx * ns - cx, ny * ns - cy
    local w, h = UIParent:GetSize()
    local a, b = w * 0.4, h * 0.36
    local den = math.sqrt(a * a * dy * dy + b * b * dx * dx)
    if den == 0 then return end
    local k = a * b / den
    marker:ClearAllPoints()
    marker:SetPoint("CENTER", UIParent, "CENTER", dx * k, dy * k)

    local len = math.sqrt(dx * dx + dy * dy)
    local ux, uy = dx / len, dy / len
    local off = math.max(pin:GetSize())
    arrow:ClearAllPoints()
    arrow:SetPoint("CENTER", marker, "CENTER", ux * off, uy * off)
    arrow:SetRotation(math.atan2(dy, dx) - math.pi / 2)
end

local function FormatDistance(d)
    local s = d < 1000 and tostring(d) or (AbbreviateNumbers and AbbreviateNumbers(d) or tostring(d))
    return (IN_GAME_NAVIGATION_RANGE or "%s yds"):format(s)
end

-- Time to arrival from the closing speed (distance lost per second), so it
-- holds on mounts, flight paths and detours alike; hidden while not closing.
local function UpdateETA(d, elapsed)
    if etaDist and math.abs(etaDist - d) < 200 then
        local v = (etaDist - d) / elapsed
        speed = speed * 0.6 + v * 0.4
    else
        speed = 0
    end
    etaDist = d
    if speed > 1 and d / speed < 6000 then
        local t = math.floor(d / speed + 0.5)
        etaText:SetFormattedText("%d:%02d", math.floor(t / 60), t % 60)
    else
        etaText:SetText("")
    end
end

local function TargetAlpha()
    if not C_Navigation.HasValidScreenPosition() then return 0 end
    local state = C_Navigation.GetTargetState()
    local ns = Enum.NavigationState
    if state == ns.Occluded then return 0.6 end
    if state == ns.InRange then return 1 end
    -- Close to the destination the engine may report Disabled while it still
    -- places the frame: keep the pin up there instead of dropping it.
    if state == ns.Disabled and lastDist and lastDist <= ARRIVE_YARDS then return 1 end
    return 0
end

local function OnTick(dt)
    if not navFrame then return end
    local clamped = C_Navigation.WasClampedToScreen() and true or false
    if clamped ~= isClamped then SetClamped(clamped) end
    if clamped then PlaceClamped() end

    alpha = alpha + (TargetAlpha() - alpha) * math.min(1, dt * 10)
    marker:SetAlpha(alpha)

    textAcc = textAcc + dt
    if textAcc >= TEXT_INTERVAL then
        local d = math.floor((C_Navigation.GetDistance() or 0) + 0.5)
        if d ~= lastDist then
            lastDist = d
            distText:SetText(FormatDistance(d))
        end
        etaAcc = etaAcc + textAcc
        if etaAcc >= ETA_INTERVAL then
            if not clamped and Cfg().markerETA ~= false then UpdateETA(d, etaAcc) end
            etaAcc = 0
        end
        textAcc = 0
    end
end

-------------------------------------------------------------------------------
--  Navigation frame lifecycle
-------------------------------------------------------------------------------
local function Attach()
    local f = C_Navigation.GetFrame()
    if not f then return end
    navFrame = f
    BuildMarker()
    pulse:Stop()
    body:SetAlpha(1)
    isClamped, lastDist, etaDist, speed = nil, nil, nil, 0
    textAcc, etaAcc, alpha = TEXT_INTERVAL, 0, 0
    marker:SetAlpha(0)
    etaText:SetText("")
    UpdateIcon()
    SetClamped(false)
    marker:Show()
    Drv.Add("worldMarker", OnTick)
end

-- A destination reached (Blizzard clears the tracking) pulses where the pin
-- stood; anything else just hides it.
local function Detach()
    Drv.Remove("worldMarker")
    local wasNear = navFrame and not isClamped and alpha > 0.3 and lastDist and lastDist <= ARRIVE_YARDS
    navFrame = nil
    if not marker then return end
    local x, y = marker:GetCenter()
    if wasNear and x then
        marker:ClearAllPoints()
        marker:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        etaText:SetText("")
        pulse:Play()
    else
        marker:Hide()
    end
end

-------------------------------------------------------------------------------
--  Blizzard's marker
-------------------------------------------------------------------------------
local hider
local function HideBlizzard(hide)
    local f = SuperTrackedFrame
    if not f then return end
    if hide then
        hider = hider or CreateFrame("Frame")
        hider:Hide()
        if f:GetParent() ~= hider then f:SetParent(hider) end
    elseif hider and f:GetParent() == hider then
        f:SetParent(UIParent)
    end
end

-------------------------------------------------------------------------------
--  Enable / disable
-------------------------------------------------------------------------------
local active

-- fromOptions: the player flipped the setting now, so the CVar is taken or
-- handed back; at login it is left as the player last set it.
local function Apply(fromOptions)
    local c = Cfg()
    if IsEnabled() then
        if fromOptions and GetCVar(CVAR) ~= "1" then
            c.worldMarkerCVar = GetCVar(CVAR)
            EUI.HoldCVar(CVAR, "1", OWNER)
        end
        HideBlizzard(true)
        if not active then
            active = true
            ev:RegisterEvent("NAVIGATION_FRAME_CREATED")
            ev:RegisterEvent("NAVIGATION_FRAME_DESTROYED")
            ev:RegisterEvent("SUPER_TRACKING_CHANGED")
            if not SuperTrackedFrame then ev:RegisterEvent("ADDON_LOADED") end
            Attach()
        else
            ApplyLayout()
        end
    else
        if fromOptions and c.worldMarkerCVar then
            if GetCVar(CVAR) ~= c.worldMarkerCVar then EUI.ReleaseCVar(CVAR, c.worldMarkerCVar, OWNER) end
            c.worldMarkerCVar = nil
        end
        if active then
            active = nil
            ev:UnregisterEvent("NAVIGATION_FRAME_CREATED")
            ev:UnregisterEvent("NAVIGATION_FRAME_DESTROYED")
            ev:UnregisterEvent("SUPER_TRACKING_CHANGED")
            ev:UnregisterEvent("ADDON_LOADED")
            Drv.Remove("worldMarker")
            navFrame = nil
            if marker then pulse:Stop() marker:Hide() end
        end
        HideBlizzard(false)
    end
end
_G._EUI_ApplyWorldMarker = Apply

ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "NAVIGATION_FRAME_CREATED" then
        Attach()
    elseif event == "NAVIGATION_FRAME_DESTROYED" then
        Detach()
    elseif event == "SUPER_TRACKING_CHANGED" then
        UpdateIcon()
    elseif event == "ADDON_LOADED" then
        if SuperTrackedFrame then
            self:UnregisterEvent("ADDON_LOADED")
            HideBlizzard(true)
        end
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        if IsEnabled() then Apply(false) end
    end
end)
