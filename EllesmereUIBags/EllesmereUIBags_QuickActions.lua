if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBags_QuickActions.lua
--  Quick Actions: a header icon (Bag Top Bar Icons, off by default) toggles a
--  mode that dims every bag item but the ones a spell of the player can work
--  on (Disenchant, Pick Lock, Milling, Prospecting), each marked with that
--  spell's icon. A click on a marked item casts the spell on it.
--
--  Taint: the cast goes through one SecureActionButtonTemplate button of our
--  own (type "spell" with target-bag / target-slot, Blizzard's own item
--  targeting). It is created, moved and shown out of combat only, over the
--  hovered slot, and hidden when combat starts. Nothing of Blizzard's is
--  hooked or written to; the slots are ours (the item overlay extension point).
--  While the icon is off nothing here is built; while the mode is off no
--  painter is registered.
-------------------------------------------------------------------------------
local ns = select(2, ...)
if not (ns and ns.GetSelection) then return end

local EUI = EllesmereUI
local _emptyP = {}
local function BP() return (EUI._bagsDB and EUI._bagsDB.profile) or _emptyP end

local DISENCHANT, PICK_LOCK, MILLING, PROSPECTING = 13262, 1804, 51005, 31252
local IC_WEAPON, IC_ARMOR, IC_TRADEGOODS, IC_MISC = 2, 4, 7, 15
local SUB_METAL_STONE, SUB_HERB, SUB_COSMETIC = 7, 9, 5
local MILL_STACK = 5           -- milling and prospecting take five at a time
local LAST_BAG = EUI.IS_FOREVER and 4 or 5  -- backpack, bags and retail's reagent bag
local SHADE_ALPHA = 0.7
local ICON = "Interface\\AddOns\\EllesmereUI\\media\\icons\\flashlight.png"

local active      -- the mode is on (true or nil)
local castBtn     -- the secure button, built on the first hover of a marked item
local combatWatch
local actions = setmetatable({}, { __mode = "k" })  -- slot button -> { spell, bag, slot }
local marks   = setmetatable({}, { __mode = "k" })  -- slot button -> { shade, spell }
local hooked  = setmetatable({}, { __mode = "k" })

local function Known(spellID) return C_SpellBook.IsSpellKnown(spellID) end

-- Whether the bag item's tooltip has a line reading exactly text.
local function TooltipHas(bag, slot, text)
    if not text then return false end
    local tip = C_TooltipInfo.GetBagItem(bag, slot)
    if not (tip and tip.lines) then return false end
    for _, line in ipairs(tip.lines) do
        if line.leftText == text then return true end
    end
    return false
end

-- The spell the player can cast on this bag item, or nil. Equipment set gear
-- is never offered to Disenchant.
local function SpellFor(bag, slot, info)
    local _, _, _, _, _, classID, subID = C_Item.GetItemInfoInstant(info.itemID)
    if classID == IC_WEAPON or classID == IC_ARMOR then
        local q = info.quality or 0
        if q >= 2 and q <= 4 and subID ~= SUB_COSMETIC and Known(DISENCHANT)
            and not C_Container.GetContainerItemEquipmentSetInfo(bag, slot) then
            return DISENCHANT
        end
    elseif classID == IC_TRADEGOODS then
        if (info.stackCount or 0) < MILL_STACK then return nil end
        if subID == SUB_HERB and Known(MILLING) and TooltipHas(bag, slot, ITEM_MILLABLE) then
            return MILLING
        end
        if subID == SUB_METAL_STONE and Known(PROSPECTING) and TooltipHas(bag, slot, ITEM_PROSPECTABLE) then
            return PROSPECTING
        end
    elseif (classID == IC_MISC or info.hasLoot) and Known(PICK_LOCK)
        and TooltipHas(bag, slot, LOCKED) then
        return PICK_LOCK
    end
end

-------------------------------------------------------------------------------
--  The secure cast button
-------------------------------------------------------------------------------
local function HideCast()
    if castBtn and not InCombatLockdown() then
        if GameTooltip:IsOwned(castBtn) then GameTooltip:Hide() end
        castBtn:Hide()
        castBtn:ClearAllPoints()
        castBtn.owner = nil
    end
end

local function CastOnEnter(self)
    local a = self.owner and actions[self.owner]
    if not a then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(a.bag, a.slot)
    GameTooltip:AddLine(EllesmereUI.Lf("Click: %s", C_Spell.GetSpellName(a.spell) or ""), 0.047, 0.824, 0.616)
    GameTooltip:Show()
end

local function CastOnLeave()
    GameTooltip:Hide()
    HideCast()
end

local function BuildCast()
    castBtn = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    castBtn:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
    castBtn:SetAttribute("type1", "spell")
    local hl = castBtn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    castBtn:SetScript("OnEnter", CastOnEnter)
    castBtn:SetScript("OnLeave", CastOnLeave)
    castBtn:Hide()
end

-- Puts the cast button over a marked slot, set for its spell and item.
local function OnSlotEnter(btn)
    if not active or InCombatLockdown() then return end
    local a = actions[btn]
    if not a then return end
    if not castBtn then BuildCast() end
    castBtn:ClearAllPoints()
    castBtn:SetAllPoints(btn)
    castBtn:SetFrameStrata(btn:GetFrameStrata())
    castBtn:SetFrameLevel(btn:GetFrameLevel() + 10)
    castBtn:SetAttribute("spell", a.spell)
    castBtn:SetAttribute("target-bag", a.bag)
    castBtn:SetAttribute("target-slot", a.slot)
    castBtn.owner = btn
    castBtn:Show()
end

-------------------------------------------------------------------------------
--  The painter (EUI_Bags.RunItemOverlays), registered while the mode is on
-------------------------------------------------------------------------------
-- The marks live on btn._textOverlay (it covers the item icon): the spell icon
-- in a corner, or a shade over the icon. The slot button itself is untouched.
local function Marks(btn)
    local m = marks[btn]
    if m then return m end
    local host = btn._textOverlay or btn
    m = {}
    m.shade = host:CreateTexture(nil, "OVERLAY", nil, 6)
    m.shade:SetAllPoints(host)
    m.shade:SetColorTexture(0, 0, 0, SHADE_ALPHA)
    m.spell = host:CreateTexture(nil, "OVERLAY", nil, 7)
    m.spell:SetSize(16, 16)
    m.spell:SetPoint("TOPRIGHT", host, "TOPRIGHT", -1, -1)
    m.spell:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    marks[btn] = m
    return m
end

local function HideMarks(btn)
    local m = marks[btn]
    if m then m.shade:Hide(); m.spell:Hide() end
end

local function Paint(btn, data)
    local bag = data.bag
    if not (bag and bag >= 0 and bag <= LAST_BAG) then  -- the bank keeps its look
        HideMarks(btn)
        actions[btn] = nil
        return
    end
    local spell = data.info and data.info.itemID and SpellFor(bag, data.slot, data.info)
    local m = Marks(btn)
    if spell then
        local a = actions[btn] or {}
        a.spell, a.bag, a.slot = spell, bag, data.slot
        actions[btn] = a
        m.shade:Hide()
        m.spell:SetTexture(C_Spell.GetSpellTexture(spell))
        m.spell:Show()
        if not hooked[btn] then
            hooked[btn] = true
            btn:HookScript("OnEnter", OnSlotEnter)
        end
    else
        actions[btn] = nil
        m.spell:Hide()
        m.shade:Show()
    end
    -- The item under the cast button changed: follow it, or let it go.
    if castBtn and castBtn.owner == btn then
        if spell then OnSlotEnter(btn) else HideCast() end
    end
end

-------------------------------------------------------------------------------
--  The mode and its header icon
-------------------------------------------------------------------------------
-- The bank keeps its look, so only the bag window repaints (while shown).
local function Repaint()
    EUI_Bags:RefreshInventory()
end

local function SyncIconLook()
    local b = EUI_Bags._quickBtn
    if not b then return end
    if active then
        local r, g, bl = 0.047, 0.824, 0.616
        if EUI.GetAccentColor then r, g, bl = EUI.GetAccentColor() end
        b.icon:SetVertexColor(r, g, bl)
    else
        b.icon:SetVertexColor(1, 1, 1)
    end
end

local function SetActive(on)
    on = on and true or false
    if on == (active or false) then return end
    active = on or nil
    if on then
        EUI_Bags.RegisterItemOverlayIcon("EUI_QuickActions", Paint)
        if not combatWatch then
            combatWatch = CreateFrame("Frame")
            combatWatch:SetScript("OnEvent", HideCast)
        end
        -- Combat lockdown starts after this event: the cast button can still hide.
        combatWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
    else
        EUI_Bags.UnregisterItemOverlayIcon("EUI_QuickActions")
        combatWatch:UnregisterEvent("PLAYER_REGEN_DISABLED")
        HideCast()
        for btn in pairs(marks) do HideMarks(btn) end
        wipe(actions)
    end
    SyncIconLook()
    Repaint()
end

local function BuildIcon()
    local header = EUI_Bags._bagsBtn:GetParent()
    local b = CreateFrame("Button", nil, header)
    b:SetSize(22, 22)
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetTexture(ICON)
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER")
    b.icon:SetAlpha(0.9)
    b:SetScript("OnEnter", function(self)
        self.icon:SetAlpha(1)
        EUI.ShowWidgetTooltip(self, active
            and EllesmereUI.L("Leave Quick Actions.")
            or EllesmereUI.L("Quick Actions: dims every item but the ones you can disenchant, unlock, mill or prospect. Click one to cast the spell on it."))
    end)
    b:SetScript("OnLeave", function(self)
        self.icon:SetAlpha(0.9)
        EUI.HideWidgetTooltip()
    end)
    b:SetScript("OnClick", function()
        EUI.HideWidgetTooltip()
        SetActive(not active)
    end)
    EUI_Bags._quickBtn = b
    -- Closing the bags ends the mode.
    EUI_Bags:HookScript("OnHide", function() SetActive(false) end)
end

-- Called by EUI_Bags:SyncHeaderIcons: places the icon left of prev while the
-- Quick Actions Icon is on. Returns it when shown.
function ns.SyncQuickActionsIcon(prev, gap)
    local on = BP().bagShowQuickIcon == true
    if on and not EUI_Bags._quickBtn then BuildIcon() end
    local b = EUI_Bags._quickBtn
    if not b then return nil end
    b:ClearAllPoints()
    b:SetPoint("RIGHT", prev, "LEFT", -gap, 0)
    b:SetShown(on)
    if not on then SetActive(false) end
    return on and b or nil
end
