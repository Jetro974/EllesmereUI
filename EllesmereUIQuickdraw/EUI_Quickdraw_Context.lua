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
--  knows there is something under the key right now.
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
--  The aura's icon with the key under it, at a fixed spot below the middle of
--  the screen. Click-through: it is a reminder of the key, not a button.
--  Made here in the main chunk so its cost is billed to this addon.
-------------------------------------------------------------------------------
local HINT_SIZE = 36
local hint = CreateFrame("Frame", "EUIQuickdrawContextHint", UIParent)
hint:SetSize(HINT_SIZE, HINT_SIZE)
hint:SetPoint("CENTER", UIParent, "CENTER", 0, -170)
hint:SetFrameStrata("MEDIUM")
hint:EnableMouse(false)
hint:Hide()
local hintIcon = hint:CreateTexture(nil, "ARTWORK")
hintIcon:SetAllPoints()
hintIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
local hintKey = hint:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hintKey:SetPoint("TOP", hint, "BOTTOM", 0, -3)

-- The first context menu the player can reach right now and the key that
-- opens it, or nil.
local function ReachableContextMenu()
    for i = 1, PaletteCount() do
        local key = ns.PaletteContext(i)
        if key and active[key] and ns.PaletteActive(i) then
            local holder = ns.ShareOwner(i) or i
            local k1 = GetBindingKey(BINDING_PREFIX .. holder)
            if k1 then return i, key, k1 end
        end
    end
    return nil
end

local function UpdateHint()
    local p = P()
    local i, key, k1
    if p and p.enabled and not fighting then i, key, k1 = ReachableContextMenu() end
    if not i then
        hint:Hide()
        return
    end
    hintIcon:SetTexture(CONTEXTS[key].icon)
    hintKey:SetText(GetBindingText and GetBindingText(k1) or k1)
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
