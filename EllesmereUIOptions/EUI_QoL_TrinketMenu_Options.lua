if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_QoL_TrinketMenu_Options.lua
--  Options page for the Trinket Menu (registered under EllesmereUIQoL).
-------------------------------------------------------------------------------

if not EllesmereUI._ModuleNS["EllesmereUIQoL"] then return end  -- module disabled: no options page

local function P()
    local fn = _G._EUI_TrinketMenu_DB
    local d = fn and fn()
    return d and d.profile and d.profile.trinketMenu
end

local function Get(key)
    local p = P()
    return p and p[key]
end

local function Set(key, v)
    local p = P()
    if p then p[key] = v end
    if _G._EUI_TrinketMenu_Apply then _G._EUI_TrinketMenu_Apply() end
end

local function BuildTrinketMenuPage(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local hdr, h

    if EllesmereUI.ClearContentHeader then EllesmereUI:ClearContentHeader() end
    parent._showRowDivider = true

    hdr, h = W:SectionHeader(parent, "TRINKET MENU", y); y = y - h
    local function off() return Get("enabled") ~= true end
    EllesmereUI.BuildSectionUnlockJump(hdr, { key = "EUI_TrinketMenu", disabled = off, disabledTooltip = "Trinket Menu" })

    _, h = W:DualRow(parent, y,
        { type="toggle", text="Trinket Menu",
          tooltip="Your two trinkets as buttons: click one to use it, hover it for the trinkets in your bags and click one to equip it there. In combat the swap waits until combat ends. Move it in Unlock Mode.",
          getValue=function() return not off() end,
          setValue=EllesmereUI.SectionToggleSetValue(function(v) Set("enabled", v) end) },
        { type="slider", text="Icon Size", min=20, max=64, step=1,
          disabled=off, disabledTooltip="Trinket Menu",
          getValue=function() return Get("iconSize") or 36 end,
          setValue=function(v) Set("iconSize", v) end })
    y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h
    return math.abs(y - yOffset)
end
_G._EUI_BuildTrinketMenuPage = BuildTrinketMenuPage
