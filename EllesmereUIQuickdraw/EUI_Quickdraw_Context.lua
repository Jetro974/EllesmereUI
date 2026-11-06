if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_Quickdraw_Context.lua
--
--  Contexts: a menu that loads only while the game says the player is in some
--  situation -- standing by a campfire, so far -- and that takes over the key
--  it shares for as long as it lasts. Nothing new to learn: the player holds
--  the key they always hold, and gets the menu that fits where they are.
--
--  palette.context names one entry of CONTEXTS; nil is "always". A context
--  menu shares another menu's key (palette.keyShare, the same share Assign to
--  Spec uses) and KeyTarget hands the key to it first while its context is on.
--  A small hint icon shows while a context menu is reachable, so the player
--  knows there is something under the key right now. Clicking it opens the
--  menu's actions as a row of buttons above it, so a context menu works with
--  no key bound at all.
--
--  The signal is an AURA the game puts on the player: no position, no polling.
--  Out of combat only. Auras are not readable in combat on every client, and
--  the override bindings cannot move there anyway, so a fight drops every
--  context at PLAYER_REGEN_DISABLED (which still allows the rebind) and the
--  key is back on its everyday menu for the whole of it.
--
--  Reads the earlier Quickdraw files through ns and ns._qdInternals.
-------------------------------------------------------------------------------
local _, ns = ...
local I = ns._qdInternals
-- EllesmereUIQuickdraw.lua or an earlier Quickdraw file failed to load.
if not I or I.broken then return end
I.broken = true

local type, pairs = type, pairs
local InCombatLockdown = InCombatLockdown
local GetBindingKey = GetBindingKey

local P, PaletteCount, RequestPush = I.P, I.PaletteCount, I.RequestPush
local PA, UsableSlots = I.PA, I.UsableSlots
local ResolveAction, FireInsecure, SlotDisplay = I.ResolveAction, I.FireInsecure, I.SlotDisplay
local BINDING_PREFIX = I.BINDING_PREFIX

-------------------------------------------------------------------------------
--  The contexts
--
--  aura   the spell ID of the player aura that says the context is on
--  icon   the hint's texture (the aura's own icon)
--  label  the options dropdown's name for it
--  seed   what a still-empty menu is given when the context is picked; the
--         player fills it from there like any other menu
-------------------------------------------------------------------------------
local CONTEXTS = {
    campfire = {
        -- The aura every campfire gives the players standing by it
        -- (measured on WoW Forever, 2026-11-05).
        aura  = 1283391,
        icon  = 7808147,
        label = "Near a Campfire",
        seed  = {
            { kind = "emote", token = "SIT" },
            { kind = "emote", token = "HELLO" },
            -- Purple Dust Pouch, the toy that turns a campfire purple. Hidden
            -- by Hide Unavailable Actions for a player who does not own it.
            { kind = "toy", id = 289439 },
        },
    },
}
local CONTEXT_ORDER = { "campfire" }
ns.CONTEXTS, ns.CONTEXT_ORDER = CONTEXTS, CONTEXT_ORDER

-- Which contexts are on right now: key -> true.
local active = {}
local fighting = false

function ns.ContextActive(key)
    return active[key] == true
end

local function Measure(def)
    local get = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    return get and get(def.aura) ~= nil or false
end

-------------------------------------------------------------------------------
--  The hint
--
--  The aura's icon with the key under it (when the menu has one), at a fixed
--  spot below the middle of the screen. A click opens the menu's actions
--  above it (the flyout below); a second click closes them.
--  Made here in the main chunk so its cost is billed to this addon.
-------------------------------------------------------------------------------
local HINT_SIZE = 36
local hint = CreateFrame("Button", "EUIQuickdrawContextHint", UIParent)
hint:SetSize(HINT_SIZE, HINT_SIZE)
hint:SetPoint("CENTER", UIParent, "CENTER", 0, -170)
hint:SetFrameStrata("MEDIUM")
hint:RegisterForClicks("LeftButtonUp")
hint:Hide()
local hintIcon = hint:CreateTexture(nil, "ARTWORK")
hintIcon:SetAllPoints()
hintIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
local hintKey = hint:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hintKey:SetPoint("TOP", hint, "BOTTOM", 0, -3)
hint:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

-------------------------------------------------------------------------------
--  The flyout: the context menu's actions as plain secure buttons in a row
--  above the hint, set up the way the menu's own cells fire (ResolveAction,
--  FireInsecure for the kinds with no secure action). Built and filled out of
--  combat only; every context drops at PLAYER_REGEN_DISABLED, and the flyout
--  with it.
-------------------------------------------------------------------------------
local FLY_SIZE, FLY_GAP = 32, 4
local flyout = CreateFrame("Frame", nil, hint)
flyout:SetPoint("BOTTOM", hint, "TOP", 0, 6)
flyout:SetSize(1, FLY_SIZE)
flyout:Hide()
local flyButtons = {}
local flyFor -- the palette index the flyout shows

local function FlyButton(n)
    local b = flyButtons[n]
    if b then return b end
    b = CreateFrame("Button", nil, flyout, "SecureActionButtonTemplate")
    b:SetSize(FLY_SIZE, FLY_SIZE)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("useOnKeyDown", false)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("BOTTOM", b, "BOTTOM", 0, 2)
    b.text:SetWidth(FLY_SIZE + 8)
    b.text:SetWordWrap(false)
    -- Kinds with no secure action fire from here; every click closes the row.
    b:SetScript("PostClick", function(self, _, down)
        if down then return end
        if self.insecure then FireInsecure(self.insecure) end
        if not InCombatLockdown() then flyout:Hide() end
    end)
    b:SetScript("OnEnter", function(self)
        if not self.name then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.name)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    flyButtons[n] = b
    return b
end

local function FillFlyout(index)
    if InCombatLockdown() then return false end
    local p = P()
    local palette = p and p.palettes and p.palettes[index]
    local view = PA(index)
    local slots = palette and UsableSlots(palette, view) or {}
    local n = 0
    for _, slot in ipairs(slots) do
        if slot.kind ~= "palette" then
            n = n + 1
            local b = FlyButton(n)
            local t, key, value, clear = ResolveAction(slot, view)
            b:SetAttribute("type", t)
            if t and key then b:SetAttribute(key, value) end
            if clear then b:SetAttribute(clear, nil) end
            b.insecure = (not t) and slot or nil
            local icon, name = SlotDisplay(slot)
            if type(icon) == "table" and icon.atlas then b.icon:SetAtlas(icon.atlas) else b.icon:SetTexture(icon) end
            b.name = name
            b.text:SetText(slot.kind == "emote" and name or "")
            b:ClearAllPoints()
            b:SetPoint("LEFT", flyout, "LEFT", (n - 1) * (FLY_SIZE + FLY_GAP), 0)
            b:Show()
        end
    end
    for i = n + 1, #flyButtons do flyButtons[i]:Hide() end
    flyout:SetWidth(math.max(1, n * (FLY_SIZE + FLY_GAP) - FLY_GAP))
    flyFor = index
    return n > 0
end

hint:SetScript("OnClick", function(self)
    if InCombatLockdown() then return end
    if flyout:IsShown() then
        flyout:Hide()
    elseif self.palette and FillFlyout(self.palette) then
        flyout:Show()
    end
end)
hint:SetScript("OnEnter", function(self)
    if not self.contextKey then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(EllesmereUI.L(CONTEXTS[self.contextKey].label))
    GameTooltip:AddLine(EllesmereUI.L("Click for this menu's actions."), 1, 1, 1, true)
    GameTooltip:Show()
end)
hint:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- The first context menu the player can reach right now, its context and the
-- key that opens it (nil when it has none: the hint's click opens it then).
local function ReachableContextMenu()
    for i = 1, PaletteCount() do
        local key = ns.PaletteContext(i)
        if key and active[key] and ns.PaletteActive(i) then
            local holder = ns.ShareOwner(i) or i
            return i, key, GetBindingKey(BINDING_PREFIX .. holder)
        end
    end
    return nil
end

local function UpdateHint()
    if InCombatLockdown() then return end -- the flyout's buttons are secure
    local p = P()
    local i, key, k1
    if p and p.enabled and not fighting then i, key, k1 = ReachableContextMenu() end
    if not i then
        flyout:Hide()
        hint.palette, hint.contextKey = nil, nil
        hint:Hide()
        return
    end
    if flyout:IsShown() and flyFor ~= i then flyout:Hide() end
    hint.palette, hint.contextKey = i, key
    hintIcon:SetTexture(CONTEXTS[key].icon)
    hintKey:SetText(k1 and (GetBindingText and GetBindingText(k1) or k1) or "")
    hint:Show()
end
ns.UpdateContextHint = UpdateHint

-------------------------------------------------------------------------------
--  Following the signal
-------------------------------------------------------------------------------
local function Evaluate()
    local changed = false
    local readable = not fighting and not InCombatLockdown()
    for key, def in pairs(CONTEXTS) do
        local on = readable and Measure(def) or false
        if (active[key] == true) ~= on then
            active[key] = on or nil
            changed = true
        end
    end
    if changed then
        -- KeyTarget reads ns.PaletteActive, which reads the contexts: the
        -- binding signature moves with them, so this rebinds only on a flip.
        ns.UpdateBindings()
        RequestPush()
    end
    UpdateHint()
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        fighting = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        fighting = false
    end
    Evaluate()
end)

-- Wanted only while the module is on and some menu names a context: a
-- profile without one never sees a single UNIT_AURA.
local eventsOn = false
local function Wanted()
    local p = P()
    if not (p and p.enabled) then return false end
    for i = 1, PaletteCount() do
        if ns.PaletteContext(i) then return true end
    end
    return false
end

-- Reached from ns.Refresh and OnEnable.
function ns.ContextRefresh()
    local on = Wanted()
    if on ~= eventsOn then
        eventsOn = on
        if on then
            eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
            eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
            eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
            eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
            fighting = InCombatLockdown() and true or false
        else
            eventFrame:UnregisterAllEvents()
            for key in pairs(active) do active[key] = nil end
            ns.UpdateBindings()
        end
    end
    if on then Evaluate() else UpdateHint() end
end

I.broken = false
