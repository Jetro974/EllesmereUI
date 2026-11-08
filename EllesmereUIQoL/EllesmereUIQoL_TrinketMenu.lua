if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIQoL_TrinketMenu.lua
--  Trinket Menu: your two trinket slots as buttons on screen (click = use the
--  trinket, key bindings under EllesmereUI) and, on hover, a menu of every
--  trinket you carry (click = equip it into the hovered slot). The same menu
--  opens on an action bar button that holds a worn trinket (or a /use 13|14
--  macro), and a trinket placed on a bar follows the slot when you swap.
--
--  The game refuses armour changes in combat (and while dead or casting), so a
--  trinket picked then waits on its slot (its icon in the corner) and goes on
--  as soon as it can. Picking the trinket already worn cancels the wait.
--
--  Auto swap (per character, per slot): right-click trinkets in the menu to
--  rank them. Out of combat, when the worn trinket is on cooldown or a trinket
--  ranked above it is ready, the first ready one goes on. Ready = 30 seconds
--  or less left: equipping a trinket starts a 30-second cooldown anyway.
--
--  Zero cost while off: no frame, no event, no hook.
-------------------------------------------------------------------------------

local _, ns = ...
local EllesmereUI = _G.EllesmereUI

local SLOTS = { INVSLOT_TRINKET1 or 13, INVSLOT_TRINKET2 or 14 }
local OTHER = { [SLOTS[1]] = SLOTS[2], [SLOTS[2]] = SLOTS[1] }
local BUTTON_NAMES = { "EllesmereUITrinketTop", "EllesmereUITrinketBottom" }
local EMPTY_ICON = 136528   -- Interface\PaperDoll\UI-PaperDoll-Slot-Trinket
local GAP = 4
local MENU_ROWS = 6         -- trinkets per menu column
local READY_LEFT = 30       -- seconds: the cooldown any trinket gets when equipped
local MAX_ACTION = 180

local defaults = {
    profile = {
        trinketMenu = {
            enabled  = false,
            showBar  = true,    -- the two buttons on screen (bindings work either way)
            onBars   = true,    -- the menu on action bar trinkets, which follow swaps
            iconSize = 36,
            pos      = nil,     -- { centerX, centerY } after the first move
        },
    },
}

local db
local function P() return db and db.profile and db.profile.trinketMenu end

local function IsSecret(v) return EllesmereUI.IsSecret and EllesmereUI.IsSecret(v) end

local bar, menu
local slotBtns, menuBtns = {}, {}
local queue = {}          -- [invSlot] = itemID waiting to be equipped
local worn = {}           -- [invSlot] = itemID last seen, to follow swaps on the bars
local events = CreateFrame("Frame")
local Flush, Apply, autoTicker, hooked
local autoWait = 0        -- GetTime() before which auto swap lets the last swap land

-------------------------------------------------------------------------------
--  Auto swap ranks: EllesmereUIDB.trinketAuto["Name-Realm"][invSlot] = { ids }
-------------------------------------------------------------------------------
local function AutoList(invSlot, create)
    if not EllesmereUIDB then return nil end
    local key = UnitName("player") .. "-" .. (GetNormalizedRealmName() or "")
    local all = EllesmereUIDB.trinketAuto
    if not all then
        if not create then return nil end
        all = {}
        EllesmereUIDB.trinketAuto = all
    end
    local mine = all[key]
    if not mine then
        if not create then return nil end
        mine = {}
        all[key] = mine
    end
    if create and not mine[invSlot] then mine[invSlot] = {} end
    return mine[invSlot]
end

local function Rank(invSlot, id)
    local list = AutoList(invSlot)
    if not list then return nil end
    for i, v in ipairs(list) do
        if v == id then return i end
    end
end

local function AnyAuto()
    for _, s in ipairs(SLOTS) do
        local list = AutoList(s)
        if list and #list > 0 then return true end
    end
    return false
end

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

-- Seconds left on a cooldown; nil when unknown (secret).
local function Left(start, dur)
    if IsSecret(start) or IsSecret(dur) then return nil end
    if not (start and dur) or start == 0 or dur == 0 then return 0 end
    return math.max(0, start + dur - GetTime())
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

local function Owned(id)
    return ((C_Item.GetItemCount and C_Item.GetItemCount(id)) or 0) > 0 or C_Item.IsEquippedItem(id)
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
            if GetInventoryItemID("player", invSlot) ~= id and Owned(id) then
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
    SyncWaitEvents()
    Flush()
    RefreshSlots()
end

-------------------------------------------------------------------------------
--  Auto swap
-------------------------------------------------------------------------------
-- Seconds left on a trinket wherever it is (worn or in the bags).
local function ItemLeft(id)
    for _, s in ipairs(SLOTS) do
        if GetInventoryItemID("player", s) == id then return Left(GetInventoryItemCooldown("player", s)) end
    end
    return Left(C_Container.GetItemCooldown(id))
end

local function AutoCheck()
    if not CanEquip() or next(queue) or GetTime() < autoWait then return end
    for _, invSlot in ipairs(SLOTS) do
        local list = AutoList(invSlot)
        if list and #list > 0 then
            local cur = GetInventoryItemID("player", invSlot)
            local curLeft = 0
            if cur then curLeft = ItemLeft(cur) end
            local curReady = curLeft ~= nil and curLeft <= READY_LEFT
            local other = GetInventoryItemID("player", OTHER[invSlot])
            -- An unranked trinket (a hand pick) stays on while it is ready.
            if curLeft ~= nil and not (curReady and cur and not Rank(invSlot, cur)) then
                for _, id in ipairs(list) do
                    if id == cur then
                        if curReady then break end   -- nothing ranked above it is ready
                    else
                        local left = ItemLeft(id)
                        if id ~= other and Owned(id) and left and left <= READY_LEFT then
                            autoWait = GetTime() + 2
                            Pick(invSlot, id)
                            return
                        end
                    end
                end
            end
        end
    end
end

local function SyncAuto()
    local want = P() and P().enabled and AnyAuto()
    if want and not autoTicker then
        autoTicker = C_Timer.NewTicker(1, AutoCheck)
    elseif not want and autoTicker then
        autoTicker:Cancel()
        autoTicker = nil
    end
end

local function ToggleAuto(invSlot, id)
    local list = AutoList(invSlot, true)
    local r = Rank(invSlot, id)
    if r then table.remove(list, r) else list[#list + 1] = id end
    SyncAuto()
end

-------------------------------------------------------------------------------
--  Action bars: a trinket on a bar follows its slot
-------------------------------------------------------------------------------
local function UseSlotOfMacro(index)
    local body = GetMacroBody and GetMacroBody(index)
    if type(body) ~= "string" or IsSecret(body) then return nil end
    for line in body:gmatch("[^\n]+") do
        local cmd, n = line:match("^%s*(/%S+)%s+(%d+)%s*$")
        if cmd then
            cmd = cmd:lower()
            for i = 1, 4 do
                local use = _G["SLASH_USE" .. i]
                if use and use:lower() == cmd and OTHER[tonumber(n)] then return tonumber(n) end
            end
        end
    end
end

local function SlotOfAction(action)
    if not action or IsSecret(action) then return nil end
    local kind, id = GetActionInfo(action)
    if IsSecret(kind) or IsSecret(id) then return nil end
    if kind == "item" then
        for _, s in ipairs(SLOTS) do
            if GetInventoryItemID("player", s) == id then return s end
        end
    elseif kind == "macro" then
        return UseSlotOfMacro(id)
    end
end

-- The swapped-out trinket's buttons get the new one, unless the new one is
-- already somewhere on the bars. Out of combat only, never over a held cursor.
local function FollowOnBars(old, new)
    if InCombatLockdown() or GetCursorInfo() or C_Item.IsEquippedItem(old) then return end
    local slots = {}
    for a = 1, MAX_ACTION do
        if HasAction(a) then
            local kind, id = GetActionInfo(a)
            if kind == "item" and id == new then return end
            if kind == "item" and id == old then slots[#slots + 1] = a end
        end
    end
    for _, a in ipairs(slots) do
        C_Item.PickupItem(new)
        PlaceAction(a)
        ClearCursor()
    end
end

-------------------------------------------------------------------------------
--  Menu: every trinket you carry
-------------------------------------------------------------------------------
-- The hovered slot's trinket first, then the other slot's, then the bags.
local function AllTrinkets(invSlot)
    local list = {}
    for _, s in ipairs({ invSlot, OTHER[invSlot] }) do
        local id = GetInventoryItemID("player", s)
        if id then list[#list + 1] = { id = id, inv = s } end
    end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and select(4, C_Item.GetItemInfoInstant(id)) == "INVTYPE_TRINKET" then
                list[#list + 1] = { id = id, bag = bag, slot = slot }
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
    b.worn = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.worn:SetAllPoints()
    b.worn:SetTexture([[Interface\Buttons\CheckButtonHilight]])
    b.worn:SetBlendMode("ADD")
    b.rank = b.cd:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.rank:SetPoint("TOPRIGHT", -2, -2)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" then
            ToggleAuto(menu.invSlot, self.entry.id)
            menu.refresh()
        else
            Pick(menu.invSlot, self.entry.id)
            menu:Hide()
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip_SetDefaultAnchor(GameTooltip, self)
        local e = self.entry
        if e.inv then GameTooltip:SetInventoryItem("player", e.inv) else GameTooltip:SetBagItem(e.bag, e.slot) end
        GameTooltip:AddLine(EllesmereUI.L("Right-click: rank it for this slot's auto swap."), 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    menuBtns[i] = b
    return b
end

local function ShowMenu(owner, invSlot)
    local list = AllTrinkets(invSlot)
    if not (list[#list] and list[#list].inv ~= invSlot) then
        if menu then menu:Hide() end   -- nothing but the worn one: nothing to put on
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
        menu.refresh = function() ShowMenu(menu.owner, menu.invSlot) end
    end
    local size = P().iconSize
    local up = select(2, owner:GetCenter()) < UIParent:GetHeight() / 2
    menu.owner, menu.invSlot = owner, invSlot
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
        if e.inv then
            SetCD(b.cd, GetInventoryItemCooldown("player", e.inv))
        else
            SetCD(b.cd, C_Container.GetContainerItemCooldown(e.bag, e.slot))
        end
        b.worn:SetShown(e.inv == invSlot)
        b.rank:SetText(Rank(invSlot, e.id) or "")
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

-- Any action button (EllesmereUI's, Blizzard's or another bar addon's) shows
-- its tooltip through GameTooltip:SetAction. Hooked on the first enable.
local function HookActionBars()
    if hooked or not GameTooltip then return end
    hooked = true
    hooksecurefunc(GameTooltip, "SetAction", function(tip, action)
        local p = P()
        if not (p and p.enabled and p.onBars) then return end
        local s = SlotOfAction(action)
        local owner = s and tip:GetOwner()
        if owner then ShowMenu(owner, s) end
    end)
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
        local b = CreateFrame("Button", BUTTON_NAMES[i], bar, "SecureActionButtonTemplate")
        b.invSlot = invSlot
        b:SetAttribute("type", "item")
        b:SetAttribute("item", tostring(invSlot))
        -- Both edges: the secure handler acts on exactly one of them (the
        -- ActionButtonUseKeyDown one), for clicks and key bindings alike.
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
            ShowMenu(self, self.invSlot)
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        slotBtns[i] = b
    end
end

local function Layout()
    local p = P()
    local size = p.iconSize
    bar:SetSize(size * 2 + GAP, size)
    for i, b in ipairs(slotBtns) do
        b:SetSize(size, size)
        b:ClearAllPoints()
        b:SetPoint("LEFT", bar, "LEFT", (i - 1) * (size + GAP), 0)
        b.waiting:SetSize(size * 0.45, size * 0.45)
        -- Hidden bar: parked invisible but live, so a key binding still reaches it.
        b:EnableMouse(p.showBar)
    end
    bar:SetAlpha(p.showBar and 1 or 0)
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
        SyncAuto()
        return
    end
    Build()
    Layout()
    ApplyPosition()
    bar:Show()
    if p.onBars then HookActionBars() end
    for _, s in ipairs(SLOTS) do worn[s] = GetInventoryItemID("player", s) end
    events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    events:RegisterEvent("BAG_UPDATE_COOLDOWN")
    events:RegisterEvent("BAG_UPDATE_DELAYED")
    SyncWaitEvents()
    SyncAuto()
    RefreshSlots()
end
_G._EUI_TrinketMenu_Apply = Apply

function _G._EUI_TrinketMenu_Reset()
    local prof = db and db.profile
    if not prof then return end
    prof.trinketMenu = {}
    EllesmereUI.Lite.DeepMergeDefaults(prof, defaults.profile)
    if EllesmereUIDB then EllesmereUIDB.trinketAuto = nil end
    Apply()
end

events:SetScript("OnEvent", function(_, event, arg1)
    if not (bar and bar:IsShown()) then return end
    if event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE_COOLDOWN" then
        if event == "BAG_UPDATE_COOLDOWN" then RefreshSlots() end
        if menu and menu:IsShown() then menu.refresh() end
        return
    end
    if event == "PLAYER_EQUIPMENT_CHANGED" and OTHER[arg1] then
        local old, new = worn[arg1], GetInventoryItemID("player", arg1)
        worn[arg1] = new
        if P().onBars and old and new and old ~= new then FollowOnBars(old, new) end
        if menu and menu:IsShown() then menu.refresh() end
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
            isHidden = function() local p = P(); return not (p and p.enabled and p.showBar) end,
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
    -- Key binding names (Bindings.xml); translations exist from here on.
    _G.BINDING_HEADER_EUI_TRINKETS = EllesmereUI.L("Trinket Menu")
    _G["BINDING_NAME_CLICK " .. BUTTON_NAMES[1] .. ":LeftButton"] = EllesmereUI.L("Use Top Trinket")
    _G["BINDING_NAME_CLICK " .. BUTTON_NAMES[2] .. ":LeftButton"] = EllesmereUI.L("Use Bottom Trinket")
    Apply()
    RegisterUnlock()
end)
