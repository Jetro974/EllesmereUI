if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_TrinketMenu.lua
--  Trinket Menu: your two trinket slots as buttons on screen (click = use the
--  trinket) and, on hover, a menu of the trinkets in your bags (click = equip
--  it into the hovered slot).
--
--  The game refuses armour changes in combat (and while dead or casting), so a
--  trinket picked then waits on its slot (its icon in the corner) and goes on
--  as soon as it can. Picking the trinket already worn cancels the wait.
--
--  Zero cost while off: no frame, no event.
-------------------------------------------------------------------------------

local _, ns = ...
local EllesmereUI = _G.EllesmereUI

local SLOTS = { INVSLOT_TRINKET1 or 13, INVSLOT_TRINKET2 or 14 }
local EMPTY_ICON = 136528   -- Interface\PaperDoll\UI-PaperDoll-Slot-Trinket
local GAP = 4
local MENU_ROWS = 6         -- trinkets per menu column

local defaults = {
    profile = {
        trinketMenu = {
            enabled  = false,
            iconSize = 36,
            pos      = nil,   -- { centerX, centerY } after the first move
        },
    },
}

local db
local function P() return db and db.profile and db.profile.trinketMenu end

local function IsSecret(v) return EllesmereUI.IsSecret and EllesmereUI.IsSecret(v) end

local bar, menu
local slotBtns, menuBtns = {}, {}
local queue = {}          -- [invSlot] = itemID waiting to be equipped
local events = CreateFrame("Frame")
local Flush

-------------------------------------------------------------------------------
--  Buttons
-------------------------------------------------------------------------------
-- Cooldown values can come back secret in combat: they go to the widget as
-- they are and are never compared here.
local function SetCD(cd, start, dur, enable)
    if IsSecret(start) or IsSecret(dur) or IsSecret(enable) then
        pcall(cd.SetCooldown, cd, start, dur)
    elseif enable and enable ~= 0 and start and start > 0 and dur and dur > 0 then
        cd:SetCooldown(start, dur)
    else
        cd:Clear()
    end
end

local function Dress(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    b.cd:SetDrawEdge(false)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    local PP = EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(b, 0, 0, 0, 1, 1, "OVERLAY", 2) end
end

local function ItemCount(id)
    return (C_Item.GetItemCount and C_Item.GetItemCount(id)) or 0
end

local function RefreshSlots()
    for i, invSlot in ipairs(SLOTS) do
        local b = slotBtns[i]
        if b then
            local tex = GetInventoryItemTexture("player", invSlot)
            b.icon:SetTexture(tex or EMPTY_ICON)
            b.icon:SetDesaturated(not tex)
            SetCD(b.cd, GetInventoryItemCooldown("player", invSlot))
            local q = queue[invSlot]
            b.waiting:SetShown(q ~= nil)
            if q then b.waiting:SetTexture(C_Item.GetItemIconByID(q)) end
        end
    end
end

-------------------------------------------------------------------------------
--  Equipping (now, or once the game allows it)
-------------------------------------------------------------------------------
local function CanEquip()
    return not InCombatLockdown() and not UnitAffectingCombat("player")
        and not UnitIsDeadOrGhost("player")
        and not UnitCastingInfo("player") and not UnitChannelInfo("player")
end

-- The "can equip again" signals are listened to only while something waits;
-- the end of combat comes through the module's combat queue.
local function SyncWaitEvents()
    local waiting = next(queue) ~= nil
    for _, e in ipairs({ "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
        if waiting then events:RegisterEvent(e) else events:UnregisterEvent(e) end
    end
    for _, e in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
        if waiting then events:RegisterUnitEvent(e, "player") else events:UnregisterEvent(e) end
    end
    if waiting and InCombatLockdown() then ns.CombatQueue.Defer("TrinketMenuSwap", Flush) end
end

-- One slot per call: the swap fires PLAYER_EQUIPMENT_CHANGED, which calls
-- this again for the other slot.
function Flush()
    if not CanEquip() then return end
    for _, invSlot in ipairs(SLOTS) do
        local id = queue[invSlot]
        if id then
            queue[invSlot] = nil
            if GetInventoryItemID("player", invSlot) ~= id and ItemCount(id) > 0 then
                C_Item.EquipItemByName(id, invSlot)
                break
            end
        end
    end
    SyncWaitEvents()
    RefreshSlots()
end

local function Pick(invSlot, id)
    for _, s in ipairs(SLOTS) do
        if queue[s] == id then queue[s] = nil end
    end
    if GetInventoryItemID("player", invSlot) ~= id then queue[invSlot] = id end
    if menu then menu:Hide() end
    SyncWaitEvents()
    Flush()
    RefreshSlots()
end

-------------------------------------------------------------------------------
--  Menu: the trinkets in the bags
-------------------------------------------------------------------------------
local function BagTrinkets()
    local list = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and select(4, C_Item.GetItemInfoInstant(id)) == "INVTYPE_TRINKET" then
                list[#list + 1] = { bag = bag, slot = slot, id = id }
            end
        end
    end
    return list
end

local function MenuButton(i)
    local b = menuBtns[i]
    if b then return b end
    b = CreateFrame("Button", nil, menu)
    Dress(b)
    b:RegisterForClicks("AnyUp")
    b:SetScript("OnClick", function(self) Pick(menu.invSlot, self.entry.id) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip_SetDefaultAnchor(GameTooltip, self)
        GameTooltip:SetBagItem(self.entry.bag, self.entry.slot)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    menuBtns[i] = b
    return b
end

local function ShowMenu(owner)
    local list = BagTrinkets()
    if #list == 0 then
        if menu then menu:Hide() end
        return
    end
    if not menu then
        menu = CreateFrame("Frame", nil, UIParent)
        menu:SetFrameStrata("DIALOG")
        menu:SetClampedToScreen(true)
        -- Closes once the cursor leaves both the menu and the button that opened it.
        menu:SetScript("OnUpdate", function(self)
            if not (self:IsMouseOver(GAP, -GAP, -GAP, GAP) or (self.owner and self.owner:IsMouseOver())) then
                self:Hide()
            end
        end)
    end
    local size = P().iconSize
    local up = select(2, owner:GetCenter()) < UIParent:GetHeight() / 2
    menu.owner, menu.invSlot = owner, owner.invSlot
    menu:ClearAllPoints()
    if up then
        menu:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, GAP)
    else
        menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -GAP)
    end
    for i, e in ipairs(list) do
        local b = MenuButton(i)
        b.entry = e
        b:SetSize(size, size)
        b.icon:SetTexture(C_Item.GetItemIconByID(e.id))
        SetCD(b.cd, C_Container.GetContainerItemCooldown(e.bag, e.slot))
        local col, row = math.floor((i - 1) / MENU_ROWS), (i - 1) % MENU_ROWS
        b:ClearAllPoints()
        b:SetPoint(up and "BOTTOMLEFT" or "TOPLEFT", menu, up and "BOTTOMLEFT" or "TOPLEFT",
            col * (size + GAP), (up and 1 or -1) * row * (size + GAP))
        b:Show()
    end
    for i = #list + 1, #menuBtns do menuBtns[i]:Hide() end
    local cols, rows = math.ceil(#list / MENU_ROWS), math.min(#list, MENU_ROWS)
    menu:SetSize(cols * (size + GAP) - GAP, rows * (size + GAP) - GAP)
    menu:Show()
end

-------------------------------------------------------------------------------
--  Bar: the two slot buttons
-------------------------------------------------------------------------------
local function Build()
    if bar then return end
    bar = CreateFrame("Frame", "EllesmereUITrinketMenu", UIParent)
    bar:SetFrameStrata("MEDIUM")
    bar:Hide()
    for i, invSlot in ipairs(SLOTS) do
        local b = CreateFrame("Button", nil, bar, "SecureActionButtonTemplate")
        b.invSlot = invSlot
        b:SetAttribute("type", "item")
        b:SetAttribute("item", tostring(invSlot))
        b:RegisterForClicks("AnyUp", "AnyDown")
        Dress(b)
        b.waiting = b:CreateTexture(nil, "OVERLAY", nil, 3)
        b.waiting:SetPoint("BOTTOMRIGHT", -1, 1)
        b.waiting:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.waiting:Hide()
        b:SetScript("OnEnter", function(self)
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
            GameTooltip:SetInventoryItem("player", self.invSlot)
            GameTooltip:Show()
            ShowMenu(self)
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        slotBtns[i] = b
    end
end

local function Layout()
    local size = P().iconSize
    bar:SetSize(size * 2 + GAP, size)
    for i, b in ipairs(slotBtns) do
        b:SetSize(size, size)
        b:ClearAllPoints()
        b:SetPoint("LEFT", bar, "LEFT", (i - 1) * (size + GAP), 0)
        b.waiting:SetSize(size * 0.45, size * 0.45)
    end
end

local function ApplyPosition()
    local pos = P().pos
    local cx, cy = (pos and pos.centerX) or 0, (pos and pos.centerY) or -150
    local PP = EllesmereUI.PP
    if PP and PP.SnapCenterForDim then
        cx = PP.SnapCenterForDim(cx, bar:GetWidth())
        cy = PP.SnapCenterForDim(cy, bar:GetHeight())
    end
    bar:ClearAllPoints()
    bar:SetPoint("CENTER", UIParent, "CENTER", cx, cy)
end

-- The bar holds secure buttons: it is built, moved, shown and hidden out of
-- combat only (a change made in combat applies when it ends).
local Apply
function Apply()
    local p = P()
    if not p then return end
    if InCombatLockdown() then
        ns.CombatQueue.Defer("TrinketMenu", Apply)
        return
    end
    if not p.enabled then
        if bar then bar:Hide() end
        if menu then menu:Hide() end
        wipe(queue)
        events:UnregisterAllEvents()
        return
    end
    Build()
    Layout()
    ApplyPosition()
    bar:Show()
    events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    events:RegisterEvent("BAG_UPDATE_COOLDOWN")
    events:RegisterEvent("BAG_UPDATE_DELAYED")
    SyncWaitEvents()
    RefreshSlots()
end
_G._EUI_TrinketMenu_Apply = Apply

function _G._EUI_TrinketMenu_Reset()
    local prof = db and db.profile
    if not prof then return end
    prof.trinketMenu = {}
    EllesmereUI.Lite.DeepMergeDefaults(prof, defaults.profile)
    Apply()
end

events:SetScript("OnEvent", function(_, event)
    if not (bar and bar:IsShown()) then return end
    if event == "BAG_UPDATE_DELAYED" then
        if menu and menu:IsShown() then ShowMenu(menu.owner) end
        return
    end
    if event == "BAG_UPDATE_COOLDOWN" then
        RefreshSlots()
        if menu and menu:IsShown() then ShowMenu(menu.owner) end
        return
    end
    Flush()   -- equipment changed or the game allows equipping again
end)

-------------------------------------------------------------------------------
--  Unlock Mode
-------------------------------------------------------------------------------
local function RegisterUnlock()
    local MK = EllesmereUI.MakeUnlockElement
    if not (EllesmereUI.RegisterUnlockElements and MK) then return end
    local loadPos, clearPos = ns.CenterPosFns(P)
    EllesmereUI:RegisterUnlockElements({
        MK({
            key   = "EUI_TrinketMenu",
            label = "Trinket Menu",
            group = "Quality of Life",
            order = 610,
            noAnchorTarget = true,
            isHidden = function() local p = P(); return not (p and p.enabled) end,
            getFrame = function() Build(); return bar end,
            getSize = function()
                local s = (P() or defaults.profile.trinketMenu).iconSize
                return s * 2 + GAP, s
            end,
            savePos = function(_, _, _, x, y)
                local p = P(); if p then p.pos = { centerX = x, centerY = y } end
            end,
            loadPos = loadPos,
            clearPos = clearPos,
            applyPos = function() if bar and not InCombatLockdown() then ApplyPosition() end end,
        }),
    })
end
_G._EUI_TrinketMenu_RegisterUnlock = RegisterUnlock

-------------------------------------------------------------------------------
--  Init
-------------------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if not (EllesmereUI.Lite and EllesmereUI.Lite.NewDB) then return end
    db = EllesmereUI.Lite.NewDB("EllesmereUIQoLDB", defaults, true)
    _G._EUI_TrinketMenu_DB = function() return db end
    Apply()
    RegisterUnlock()
end)
