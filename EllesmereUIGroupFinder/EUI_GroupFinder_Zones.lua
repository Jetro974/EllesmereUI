if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
-- EUI_GroupFinder_Zones.lua: Show Player Zones. The zone a group's leader is
-- in, when the game sends it with the listing (areaName) but its own list never
-- shows it: on the group's row and in the group's tooltip.
-------------------------------------------------------------------------------
local _, ns = ...

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end

local hooked = false
-- Result row -> our zone FontString.
local zoneText = setmetatable({}, { __mode = "k" })

-- The leader's zone, or nil (setting off, none sent, or secret).
local function Zone(resultID)
    if not ns.Cfg().playerZones or resultID == nil or IsSecret(resultID) then return nil end
    local leader = C_LFGList.GetSearchResultLeaderInfo(resultID)
    if not leader or IsSecret(leader) or (canaccesstable and not canaccesstable(leader)) then return nil end
    local area = leader.areaName
    if type(area) ~= "string" or IsSecret(area) or area == "" then return nil end
    return area
end

-- Row: on the playstyle line, after the playstyle, short of the activity
-- name's width.
local function UpdateRow(row)
    local fs = zoneText[row]
    local zone = Zone(row.resultID)
    local playstyle, activity = row.Playstyle, row.ActivityName
    if not (zone and playstyle and activity) then
        if fs then fs:Hide() end
        return
    end
    if not fs then
        fs = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmallLeft")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        zoneText[row] = fs
    end
    local text = playstyle:GetText()
    local gap = (type(text) == "string" and not IsSecret(text) and text ~= "") and 8 or 0
    local used, width = playstyle:GetStringWidth(), activity:GetWidth()
    local room = (type(used) == "number" and type(width) == "number" and not IsSecret(used) and not IsSecret(width))
        and width - used - gap or 0
    if room < 24 then
        fs:Hide()
        return
    end
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", playstyle, "RIGHT", gap, 0)
    fs:SetText(zone)
    fs:SetWidth(0)
    if fs:GetStringWidth() > room then fs:SetWidth(room) end
    fs:Show()
end

local function UpdateTooltip(tip, resultID)
    if not (tip and tip.IsShown and tip:IsShown()) then return end
    local zone = Zone(resultID)
    if not zone then return end
    tip:AddLine(EllesmereUI.L("Leader Zone:") .. " " .. zone, 1, 0.82, 0, true)
    tip:Show()
end

-- hooksecurefunc cannot be undone: hooked once, the hooks follow the setting.
function ns.Zones_Apply()
    if hooked or not ns.Cfg().playerZones or not ns.Enabled() then return end
    if not (LFGListSearchEntry_Update and LFGListUtil_SetSearchEntryTooltip) then return end
    hooked = true
    hooksecurefunc("LFGListSearchEntry_Update", UpdateRow)
    hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", UpdateTooltip)
end

-- Setting or profile changed: hook if needed and repaint the visible rows.
function ns.Zones_Refresh()
    ns.Zones_Apply()
    local panel = LFGListFrame and LFGListFrame.SearchPanel
    local box = panel and panel.ScrollBox
    if box and box.ForEachFrame and panel:IsVisible() then box:ForEachFrame(UpdateRow) end
end
