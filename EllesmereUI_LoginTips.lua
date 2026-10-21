if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUI_LoginTips.lua
--
--  EUI Tips: one short chat line at login pointing at a feature the user has
--  never used, with a [Show Me] link that opens it. Never a popup: the login
--  popups (first install, style picker, announcements, conflict check) keep
--  the screen to themselves, and a tip only prints on a login none of them
--  claimed.
--
--  API (EllesmereUI.LoginTips):
--    Register(id, def) -- def = {
--        modes   = { retail = true, forever = true }  (nil = both),
--        addon   = "EllesmereUIActionBars"             (optional; must be loaded),
--        text    = function() return <localized line> end,
--        unused  = function() return true end          (true = still worth telling),
--        show    = function() ... end                  (the [Show Me] action),
--      }
--    MarkUsed(key)     -- feature used; tips that check UsedKey(key) stand down
--    ShowNext(force)   -- print the next eligible tip (force skips login gates)
--
--  MODES: WoW Forever (EllesmereUI.IS_FOREVER) and retail are told apart for
--  every tip, never mixed: Forever runs a different module set (no Mythic+
--  Tools, its own Forever Essentials) and a different spec model, so a tip
--  names only what exists in the mode the player is in right now.
--
--  When a tip prints (all must hold):
--    * a real login (isInitialLogin), never a /reload;
--    * at least MIN_LOGINS logins counted, so a new user's first sessions
--      stay quiet (the counter starts at this build, so upgrades wait too);
--    * no login popup pending (the _*Pending flags the conflict check reads);
--    * out of combat and outside instances;
--    * the user has not turned tips off (EllesmereUIDB.loginTips ~= false).
--  One tip per login at most. A printed tip is stamped seen and never repeats;
--  /euitips reset clears that.
--
--  State (per account): EllesmereUIDB.loginTipsState = {
--    logins = n, seen = { [id] = true }, used = { [key] = true } }
-------------------------------------------------------------------------------

local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

-- Suite-only: tips point at suite surfaces (options pages, Unlock Mode).
local EUI_HOST_ADDON = ...
local IS_STANDALONE = type(EUI_HOST_ADDON) == "string" and EUI_HOST_ADDON:find("Standalone") ~= nil
if IS_STANDALONE then return end

local MIN_LOGINS = 3
local PRINT_DELAY = 8       -- seconds after login: lets the login popups claim the screen first
local LINK_PREFIX = "addon:EllesmereUI:tip:"

local tips, order = {}, {}

local function State()
    if not EllesmereUIDB then return nil end
    local s = EllesmereUIDB.loginTipsState
    if type(s) ~= "table" then
        s = {}
        EllesmereUIDB.loginTipsState = s
    end
    s.seen = s.seen or {}
    s.used = s.used or {}
    s.logins = s.logins or 0
    return s
end

local function CurrentMode()
    return EllesmereUI.IS_FOREVER and "forever" or "retail"
end

local function Enabled()
    return not (EllesmereUIDB and EllesmereUIDB.loginTips == false)
end

local function AddonLoaded(folder)
    return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(folder) and true or false
end

local function UsedKey(key)
    local s = State()
    return s and s.used[key] == true or false
end

local function MarkUsed(key)
    local s = State()
    if s then s.used[key] = true end
end

-- A tip is eligible when it belongs to the current mode, its module is
-- loaded, it was never printed, and its feature is still unused.
local function Eligible(id)
    local def = tips[id]
    if not def then return false end
    if def.modes and not def.modes[CurrentMode()] then return false end
    if def.addon and not AddonLoaded(def.addon) then return false end
    local s = State()
    if not s or s.seen[id] then return false end
    local ok, unused = pcall(def.unused)
    return ok and unused == true
end

local function NextTip()
    for _, id in ipairs(order) do
        if Eligible(id) then return id end
    end
    return nil
end

local function LoginPopupPending()
    return EllesmereUI._firstInstallPending or EllesmereUI._styleChoicePending
        or EllesmereUI._raidFramesIntroPending or EllesmereUI._patchNotesIntroPending
        or EllesmereUI._windowSkinsIntroPending or EllesmereUI._specOvIntroPending
        or EllesmereUI._ptrManagersIntroPending or EllesmereUI._launchVideoIntroPending
        or EllesmereUI._styleLaunchIntroPending
        or (EllesmereUIDB and EllesmereUIDB.styleChoicePending)
end

local function Link(id, action, label, color)
    return color .. "|H" .. LINK_PREFIX .. action .. ":" .. id .. "|h[" .. label .. "]|h|r"
end

local function PrintTip(id)
    local def = tips[id]
    local CC = EllesmereUI.COLOR_CODES
    EllesmereUI.Print(CC.BRAND .. EllesmereUI.L("EUI Tip:") .. "|r " .. def.text()
        .. " " .. Link(id, "show", EllesmereUI.L("Show Me"), CC.BRAND)
        .. " " .. Link(id, "off", EllesmereUI.L("Turn Off Tips"), CC.DIM))
    State().seen[id] = true
end

local function ShowNext(force)
    if not force and not Enabled() then return false end
    local id = NextTip()
    if not id then return false end
    PrintTip(id)
    return true
end

-------------------------------------------------------------------------------
--  Chat link clicks
-------------------------------------------------------------------------------
hooksecurefunc("SetItemRef", function(link)
    if not link then return end
    if _G.issecretvalue and _G.issecretvalue(link) then return end
    local action, id = link:match("^" .. LINK_PREFIX .. "(%a+):(.+)$")
    if not action then return end
    -- Deferred one frame: keeps option panel builds out of the click's execution.
    C_Timer.After(0, function()
        if action == "off" then
            if EllesmereUIDB then EllesmereUIDB.loginTips = false end
            EllesmereUI.Print(EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r "
                .. EllesmereUI.L("Login tips turned off. Type /euitips on to turn them back on."))
        elseif action == "show" then
            local def = tips[id]
            if not def then return end
            if InCombatLockdown() then
                EllesmereUI.PrintError(EllesmereUI.L("Cannot open options during combat."))
                return
            end
            def.show()
        end
    end)
end)

-------------------------------------------------------------------------------
--  Login driver
-------------------------------------------------------------------------------
-- Slash commands whose first use means the matching feature is known.
-- Hooked at PLAYER_ENTERING_WORLD: child modules register some of these
-- from their own login handlers.
local USAGE_SLASH = {
    EABQUICKKEYBIND = "kb",
    EUIUNLOCK       = "unlock",
    EUIMPLUS        = "runSummary",
}

local function HookUsage()
    for cmd, key in pairs(USAGE_SLASH) do
        if SlashCmdList[cmd] then
            hooksecurefunc(SlashCmdList, cmd, function() MarkUsed(key) end)
        end
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(self, _, isInitialLogin, isReloadingUi)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    HookUsage()
    if not isInitialLogin or isReloadingUi then return end
    local s = State()
    if not s then return end
    s.logins = s.logins + 1
    if s.logins <= MIN_LOGINS or not Enabled() then return end
    -- A login that opened with a popup pending belongs to that popup.
    if LoginPopupPending() then return end
    C_Timer.After(PRINT_DELAY, function()
        if LoginPopupPending() or InCombatLockdown() or IsInInstance() then return end
        ShowNext(false)
    end)
end)

-------------------------------------------------------------------------------
--  /euitips            print the next tip now
--  /euitips on | off   turn login tips on / off
--  /euitips reset      forget which tips were shown
-------------------------------------------------------------------------------
SLASH_EUITIPS1 = "/euitips"
SlashCmdList.EUITIPS = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(.-)%s*$")
    C_Timer.After(0, function()
        local BRAND = EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r "
            if cmd == "on" or cmd == "off" then
            if EllesmereUIDB then EllesmereUIDB.loginTips = (cmd == "on") end
            EllesmereUI.Print(BRAND .. (cmd == "on" and EllesmereUI.L("Login tips turned on.")
                or EllesmereUI.L("Login tips turned off. Type /euitips on to turn them back on.")))
        elseif cmd == "reset" then
            local s = State()
            if s then s.seen = {} end
            EllesmereUI.Print(BRAND .. EllesmereUI.L("Login tips reset."))
        elseif not ShowNext(true) then
            EllesmereUI.Print(BRAND .. EllesmereUI.L("No new tips: you already use everything they cover."))
        end
    end)
end

EllesmereUI.LoginTips = {
    Register = function(id, def)
        if not tips[id] then order[#order + 1] = id end
        tips[id] = def
    end,
    MarkUsed = MarkUsed,
    ShowNext = ShowNext,
}

-------------------------------------------------------------------------------
--  Tips, in the order they are offered
-------------------------------------------------------------------------------
local Register = EllesmereUI.LoginTips.Register
local RETAIL  = { retail = true }
local FOREVER = { forever = true }

local CORE_ADDONS = {
    "EllesmereUIActionBars", "EllesmereUINameplates", "EllesmereUIUnitFrames",
    "EllesmereUICooldownManager", "EllesmereUIResourceBars", "EllesmereUIRaidFrames",
}
local function FirstLoadedCoreModule()
    for _, folder in ipairs(CORE_ADDONS) do
        if AddonLoaded(folder) then return folder end
    end
    return nil
end

-- Both modes ------------------------------------------------------------------

Register("unlock_mode", {
    text = function()
        return EllesmereUI.L("Type /unlock to drag, anchor and size-match any EllesmereUI element.")
    end,
    unused = function()
        return not (EllesmereUIDB and EllesmereUIDB.unlockTipSeen) and not UsedKey("unlock")
    end,
    show = function()
        MarkUsed("unlock")
        SlashCmdList.EUIUNLOCK()
    end,
})

Register("quick_keybind", {
    addon = "EllesmereUIActionBars",
    text = function()
        return EllesmereUI.L("Type /kb to bind keys by hovering an action button and pressing a key.")
    end,
    unused = function() return not UsedKey("kb") end,
    show = function()
        MarkUsed("kb")
        SlashCmdList.EABQUICKKEYBIND()
    end,
})

-- Retail ----------------------------------------------------------------------

Register("spec_overrides", {
    modes = RETAIL,
    text = function()
        return EllesmereUI.L("Spec Overrides give a setting a different value per spec, without a second profile.")
    end,
    unused = function()
        if not FirstLoadedCoreModule() then return false end
        if (GetNumSpecializations and GetNumSpecializations() or 0) < 2 then return false end
        -- Per-spec profiles already cover the same need.
        if EllesmereUIDB and type(EllesmereUIDB.specProfiles) == "table"
           and next(EllesmereUIDB.specProfiles) then return false end
        local prof = EllesmereUI.GetActiveProfileData()
        return not (prof and type(prof.specOverrideGroups) == "table" and next(prof.specOverrideGroups))
    end,
    show = function()
        -- Same landing as the Spec Overrides announcement: the user's first core
        -- module, with the overrides glyph pulsed once the panel has built.
        EllesmereUI:ShowModule(FirstLoadedCoreModule())
        C_Timer.After(0.1, function()
            if EllesmereUI.SpecOverrides_PulseButton then EllesmereUI.SpecOverrides_PulseButton() end
        end)
    end,
})

Register("run_summary", {
    modes = RETAIL,
    addon = "EllesmereUIMythicTimer",
    text = function()
        return EllesmereUI.L("After a Mythic+ key, /ov opens a full run summary of your group.")
    end,
    unused = function()
        local maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()
        if maxLevel and UnitLevel("player") < maxLevel then return false end
        return not UsedKey("runSummary")
    end,
    show = function()
        MarkUsed("runSummary")
        EllesmereUI:NavigateToElementSettings("EllesmereUIMythicTimer", "Run Summary")
    end,
})

-- WoW Forever -----------------------------------------------------------------

Register("auto_uprank", {
    modes = FOREVER,
    addon = "EllesmereUIForeverEssentials",
    text = function()
        return EllesmereUI.L("Auto Uprank Spells swaps each new spell rank onto your action bars for you.")
    end,
    unused = function()
        local c = EllesmereUIDB and EllesmereUIDB.spellUprank
        return not (c and c.enabled)
    end,
    show = function()
        EllesmereUI:NavigateToElementSettings("EllesmereUIForeverEssentials", "General",
            "SPELL RANKS", nil, "Auto Uprank Spells")
    end,
})

Register("threat_meter", {
    modes = FOREVER,
    addon = "EllesmereUIForeverEssentials",
    text = function()
        return EllesmereUI.L("EllesmereUI has a built-in threat meter, off until you turn it on.")
    end,
    unused = function()
        local c = EllesmereUIDB and EllesmereUIDB.threatMeter
        return not (c and c.enabled)
    end,
    show = function()
        EllesmereUI:NavigateToElementSettings("EllesmereUIForeverEssentials", "Threat")
    end,
})
