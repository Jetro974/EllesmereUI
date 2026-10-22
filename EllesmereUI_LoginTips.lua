if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUI_LoginTips.lua
--
--  EUI Tips: one short chat line at login pointing at a feature the user has
--  never used, with a [Show Me] link that opens it. Never a popup: a chat
--  line cannot collide with the login popups, so only the install sessions
--  (module picker, then style picker) stay tip-free.
--
--  API (EllesmereUI.LoginTips):
--    Register(id, def) -- def = {
--        modes   = { retail = true, forever = true }  (nil = both),
--        addon   = "EllesmereUIActionBars"             (optional; must be loaded),
--        text    = function() return <localized line> end,
--        unused  = function() return true end          (true = still worth telling),
--        show    = function() ... end                  (the [Show Me] action),
--      }
--    ShowNext(force)   -- print the next eligible tip (force skips login gates)
--
--  "Unused" is read from saved settings only (a feature that is still off);
--  nothing is tracked or hooked. A tip with no setting to read (a slash
--  command) simply shows once.
--
--  MODES: WoW Forever (EllesmereUI.IS_FOREVER) and retail are told apart for
--  every tip, never mixed: Forever runs a different module set (no Mythic+
--  Tools, its own Forever Essentials) and a different spec model, so a tip
--  names only what exists in the mode the player is in right now.
--
--  When a tip prints (all must hold):
--    * a real login (isInitialLogin), never a /reload;
--    * not an install session (first-install or style picker pending);
--    * out of combat and outside instances;
--    * the user has not turned tips off (EllesmereUIDB.loginTips ~= false).
--  One tip per login at most. A printed tip is stamped seen and never repeats;
--  /euitips reset clears that.
--
--  State (per account): EllesmereUIDB.loginTipsState = { seen = { [id] = true } }
-------------------------------------------------------------------------------

local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

-- Suite-only: tips point at suite surfaces (options pages, Unlock Mode).
local EUI_HOST_ADDON = ...
local IS_STANDALONE = type(EUI_HOST_ADDON) == "string" and EUI_HOST_ADDON:find("Standalone") ~= nil
if IS_STANDALONE then return end

local PRINT_DELAY = 8       -- seconds after login: lets the login burst of chat lines settle
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

-- A module's live profile table (defaults merged at load), or {} when absent.
local function ModuleProfile(folder)
    local prof = EllesmereUI.GetActiveProfileData()
    return prof and type(prof.addons) == "table" and prof.addons[folder] or {}
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

-- The two install sessions: the module picker, then the style picker on the
-- next login. A brand-new user meets the suite there, not in tips.
local function InstallSession()
    return EllesmereUI._firstInstallPending or EllesmereUI._styleChoicePending
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
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(self, _, isInitialLogin, isReloadingUi)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    if not isInitialLogin or isReloadingUi then return end
    if not Enabled() or InstallSession() then return end
    C_Timer.After(PRINT_DELAY, function()
        if InCombatLockdown() or IsInInstance() then return end
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

local function AtMaxLevel()
    local maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()
    return not maxLevel or UnitLevel("player") >= maxLevel
end

-- [Show Me] that deep-links an options row (section/row optional: page top).
local function Goto(module, page, section, row)
    return function() EllesmereUI:NavigateToElementSettings(module, page, section, nil, row) end
end

-- Tips, most useful first. Modes interleave: each player walks only the
-- tips of the mode they are in (no "modes" = both).

Register("unlock_mode", {
    text = function()
        return EllesmereUI.L("Type /unlock to drag, anchor and size-match any EllesmereUI element.")
    end,
    unused = function()
        -- Stamped by Unlock Mode's own how-to tip on its first open.
        return not (EllesmereUIDB and EllesmereUIDB.unlockTipSeen)
    end,
    show = function() SlashCmdList.EUIUNLOCK() end,
})

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
    show = Goto("EllesmereUIForeverEssentials", "General", "SPELL RANKS", "Auto Uprank Spells"),
})

Register("hovercast", {
    addon = "EllesmereUIRaidFrames",
    text = function()
        return EllesmereUI.L("HoverCast: bind spells to mouse clicks on your raid and party frames, no Clique needed.")
    end,
    unused = function()
        if AddonLoaded("Clique") then return false end   -- the page disables itself then
        local cc = EllesmereUIDB and EllesmereUIDB.clickCast
        return not (cc and cc.enabled)
    end,
    show = Goto("EllesmereUIRaidFrames", "HoverCast"),
})

Register("run_summary", {
    modes = RETAIL,
    addon = "EllesmereUIMythicTimer",
    text = function()
        return EllesmereUI.L("Turn on Run Summary for a full recap of your group after each Mythic+ key (/ov).")
    end,
    unused = function()
        if not AtMaxLevel() then return false end
        -- Off by default; /ov only answers once it is on.
        local rs = ModuleProfile("EllesmereUIMythicTimer").runSummary
        return not (rs and rs.enabled == true)
    end,
    show = Goto("EllesmereUIMythicTimer", "Run Summary", "RUN SUMMARY", "Enable Run Summary"),
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
    show = Goto("EllesmereUIForeverEssentials", "Threat"),
})

Register("cdm_keybind", {
    addon = "EllesmereUICooldownManager",
    text = function()
        return EllesmereUI.L("Show Keybind prints each ability's key on its Cooldown Manager icon.")
    end,
    unused = function()
        local bars = (ModuleProfile("EllesmereUICooldownManager").cdmBars or {}).bars or {}
        for _, bar in ipairs(bars) do
            if bar.barType ~= "buffs" and bar.showKeybind == true then return false end
        end
        return true
    end,
    show = Goto("EllesmereUICooldownManager", "CDM Bars", "EXTRAS", "Show Keybind"),
})

Register("out_of_range", {
    addon = "EllesmereUIActionBars",
    text = function()
        return EllesmereUI.L("Out of Range Coloring tints an action button red while your target is out of range.")
    end,
    unused = function()
        if not (C_ActionBar and C_ActionBar.EnableActionRangeCheck) then return false end
        for _, bar in pairs(ModuleProfile("EllesmereUIActionBars").bars or {}) do
            if type(bar) == "table" and bar.outOfRangeColoring == true then return false end
        end
        return true
    end,
    show = Goto("EllesmereUIActionBars", "Bar Display", "ICON EFFECTS", "Out of Range Coloring"),
})

Register("targeted_spell_bars", {
    modes = RETAIL,
    addon = "EllesmereUIMythicTimer",
    text = function()
        return EllesmereUI.L("Targeted Spell Bars list every enemy cast in one place, with its target and timer.")
    end,
    unused = function()
        if not AtMaxLevel() then return false end
        local tsb = ModuleProfile("EllesmereUIMythicTimer").tsb
        return not (tsb and tsb.enabled == true)
    end,
    show = Goto("EllesmereUIMythicTimer", "Targeted Spell Bars", "TARGETED SPELL BARS", "Enable Targeted Spell Bars"),
})

Register("loot_feed", {
    modes = FOREVER,
    addon = "EllesmereUIForeverEssentials",
    text = function()
        return EllesmereUI.L("Loot Feed shows items, gold, reputation and skill-ups on screen as you gain them.")
    end,
    unused = function()
        local c = EllesmereUIDB and EllesmereUIDB.lootFeed
        return not (c and c.enabled == true)
    end,
    show = Goto("EllesmereUIForeverEssentials", "Loot", "LOOT FEED", "Enable Loot Feed"),
})

Register("auto_logging", {
    addon = "EllesmereUIQoL",
    text = function()
        return EllesmereUI.L("Auto Combat Logging starts and stops the combat log for you in raids and dungeons, ready for Warcraft Logs.")
    end,
    unused = function()
        local c = EllesmereUIDB and EllesmereUIDB.autoLogging
        return not (c and c.enabled == true)
    end,
    show = Goto("EllesmereUIQoL", "QoL", "AUTO COMBAT LOGGING", "Enable Auto Logging"),
})

Register("talent_reminders", {
    modes = RETAIL,
    addon = "EllesmereUIAuraBuffReminders",
    text = function()
        return EllesmereUI.L("Talent Reminders warn you per dungeon or raid when a talent you want there is not picked.")
    end,
    unused = function()
        if not AtMaxLevel() then return false end
        local t = ModuleProfile("EllesmereUIAuraBuffReminders").talentReminders
        return not t or #t == 0
    end,
    show = Goto("EllesmereUIAuraBuffReminders", "Talent Reminders"),
})

-- Melee and hunters: the classes whose damage rides the swing.
local SWING_CLASSES = { WARRIOR = true, ROGUE = true, PALADIN = true, HUNTER = true, SHAMAN = true }

Register("swing_timer", {
    modes = FOREVER,
    addon = "EllesmereUIResourceBars",
    text = function()
        return EllesmereUI.L("The Swing Timer shows the time to your next auto attack, with a Heroic Strike / Maul queue highlight.")
    end,
    unused = function()
        if not C_SwingTimer or not SWING_CLASSES[select(2, UnitClass("player"))] then return false end
        local st = ModuleProfile("EllesmereUIResourceBars").swingTimer
        return not (st and st.enabled == true)
    end,
    show = Goto("EllesmereUIResourceBars", "Swing Timer", "LAYOUT", "Enable Swing Timer"),
})

Register("quick_keybind", {
    addon = "EllesmereUIActionBars",
    text = function()
        return EllesmereUI.L("Type /kb to bind keys by hovering an action button and pressing a key.")
    end,
    unused = function() return true end,   -- nothing to read: shows once
    show = function() SlashCmdList.EABQUICKKEYBIND() end,
})

Register("raid_tools", {
    addon = "EllesmereUIQoL",
    text = function()
        return EllesmereUI.L("Raid Tools: ready check, pull timer and raid markers in one panel when you lead or assist.")
    end,
    unused = function()
        local rt = ModuleProfile("EllesmereUIQoL").raidTools
        return not rt or rt.mode == nil or rt.mode == "never"
    end,
    show = Goto("EllesmereUIQoL", "Raid Tools", "GENERAL", "Show Raid Tools"),
})

Register("heal_prediction", {
    modes = RETAIL,
    addon = "EllesmereUIUnitFrames",
    text = function()
        return EllesmereUI.L("Heal Prediction shows incoming heals on your unit frames' health bars.")
    end,
    unused = function()
        local p = ModuleProfile("EllesmereUIUnitFrames")
        for _, unit in ipairs({ "player", "target", "focus" }) do
            if p[unit] and p[unit].healPrediction == true then return false end
        end
        return true
    end,
    show = Goto("EllesmereUIUnitFrames", "Main Frames", "ABSORBS AND HEALS", "Heal Prediction"),
})

Register("cast_latency", {
    addon = "EllesmereUIResourceBars",
    text = function()
        return EllesmereUI.L("The Latency Overlay shades the end of your cast bar, so you know when to queue the next spell.")
    end,
    unused = function()
        local cb = ModuleProfile("EllesmereUIResourceBars").castBar
        return cb ~= nil and cb.enabled ~= false and cb.latencyEnabled ~= true
    end,
    show = Goto("EllesmereUIResourceBars", "Cast Bar", "LATENCY", "Enable Latency Overlay"),
})

Register("nameplate_range", {
    addon = "EllesmereUINameplates",
    text = function()
        return EllesmereUI.L("Nameplates can show your distance to the target in yards (15+, 30+...).")
    end,
    unused = function() return ModuleProfile("EllesmereUINameplates").rangeTextEnabled ~= true end,
    show = Goto("EllesmereUINameplates", "General", "TARGET AND FOCUS EFFECTS", "Distance to Target Text (Range)"),
})

Register("databars", {
    addon = "EllesmereUIDataBars",
    text = function()
        if EllesmereUI.IS_FOREVER then
            return EllesmereUI.L("DataBars: build an info bar (clock, gold, durability, micro menu...) from a one-click template.")
        end
        return EllesmereUI.L("DataBars: build an info bar (clock, gold, durability, Great Vault...) from a one-click template.")
    end,
    unused = function()
        local bars = ModuleProfile("EllesmereUIDataBars").bars
        return not bars or #bars == 0
    end,
    show = Goto("EllesmereUIDataBars", "DataBars"),
})

Register("quick_signup", {
    modes = RETAIL,
    addon = "EllesmereUIQoL",
    text = function()
        return EllesmereUI.L("Quick Signup: double-click a premade group to sign up instantly.")
    end,
    unused = function() return not (EllesmereUIDB and EllesmereUIDB.quickSignup) end,
    show = Goto("EllesmereUIQoL", "QoL", "GROUP FINDER", "Quick Signup"),
})

Register("clock_hover", {
    addon = "EllesmereUIMinimap",
    text = function()
        if EllesmereUI.IS_FOREVER then
            return EllesmereUI.L("Hovering the minimap clock can show your instance lockouts.")
        end
        return EllesmereUI.L("Hovering the minimap clock can show your instance lockouts or Great Vault progress.")
    end,
    unused = function()
        local mp = ModuleProfile("EllesmereUIMinimap").minimap
        if not mp then return false end
        local mode = mp.clockMode
        if mode == nil then mode = (mp.showClock == false) and "none" or "inside" end
        if mode == "none" then return false end   -- the row is disabled without a clock
        return mp.clockHoverTooltip == nil or mp.clockHoverTooltip == "none"
    end,
    show = Goto("EllesmereUIMinimap", "Minimap", "TEXT", "Show on Clock Hover"),
})

Register("bank_sidebar", {
    addon = "EllesmereUIBags",
    text = function()
        return EllesmereUI.L("The bank Category Sidebar lets you browse your bank by item type instead of tab by tab.")
    end,
    unused = function() return ModuleProfile("EllesmereUIBags").bankCategorySidebar ~= true end,
    show = Goto("EllesmereUIBags", "Bank", "SIDEBAR", "Category Sidebar"),
})

Register("quest_item_hotkey", {
    addon = "EllesmereUIQuestTracker",
    text = function()
        return EllesmereUI.L("Bind a Quest Item Hotkey to use your current quest's item with one key.")
    end,
    unused = function()
        local qt = ModuleProfile("EllesmereUIQuestTracker").questTracker
        return not qt or qt.questItemHotkey == nil or qt.questItemHotkey == ""
    end,
    -- The hotkey row is hand-built (no matchable label): land on its section.
    show = Goto("EllesmereUIQuestTracker", "Quest Tracker", "EXTRAS"),
})

Register("movement_alert", {
    addon = "EllesmereUIQoL",
    text = function()
        return EllesmereUI.L("Movement Cooldown Alert counts down your mobility spell (Blink, Disengage, Roll...) on screen.")
    end,
    unused = function()
        local classes = (ModuleProfile("EllesmereUIQoL").movementAlert or {}).enabledClasses
        return not (classes and classes[select(2, UnitClass("player"))])
    end,
    show = Goto("EllesmereUIQoL", "MoveAlert", "MOVEMENT COOLDOWN ALERT", "Enable Movement Alerts"),
})

Register("party_targets", {
    addon = "EllesmereUIRaidFrames",
    text = function()
        return EllesmereUI.L("Party Targets shows each party member's target beside their frame; click it to assist.")
    end,
    unused = function() return ModuleProfile("EllesmereUIRaidFrames").partyShowTargets ~= true end,
    show = Goto("EllesmereUIRaidFrames", "Party", "PARTY TARGETS", "Enable Party Targets"),
})

Register("spell_history", {
    addon = "EllesmereUIDamageMeters",
    text = function()
        return EllesmereUI.L("Spell History shows your recent casts, including failed and interrupted ones.")
    end,
    unused = function()
        local sh = (ModuleProfile("EllesmereUIDamageMeters").dm or {}).spellHistory
        return not (sh and (sh.iconEnabled == true or sh.barEnabled == true))
    end,
    show = Goto("EllesmereUIDamageMeters", "Spell History", "ICON HISTORY", "Enable Icon History"),
})

Register("friend_invites", {
    modes = RETAIL,
    addon = "EllesmereUIFriends",
    text = function()
        return EllesmereUI.L("Group invites from your friends can be accepted automatically.")
    end,
    unused = function()
        local f = ModuleProfile("EllesmereUIFriends").friends
        return f ~= nil and f.enabled ~= false and f.autoAcceptFriendInvites ~= true
    end,
    show = Goto("EllesmereUIFriends", "Friends", "DISPLAY", "Auto-Accept Friend Invites"),
})

Register("auto_open_containers", {
    addon = "EllesmereUIQoL",
    text = function()
        return EllesmereUI.L("Auto Open Containers opens bags, boxes and parcels as soon as they land in your inventory.")
    end,
    unused = function() return not (EllesmereUIDB and EllesmereUIDB.autoOpenContainers == true) end,
    show = Goto("EllesmereUIQoL", "QoL", "UI", "Auto Open Containers"),
})

Register("macro_factory", {
    modes = RETAIL,
    addon = "EllesmereUIQoL",
    text = function()
        return EllesmereUI.L("Macro Factory creates smart macros (potions, healing, food, trinkets, focus) and keeps them up to date.")
    end,
    unused = function()
        if not GetMacroIndexByName then return false end
        for _, name in ipairs({ "EUI_Potion", "EUI_Health", "EUI_Food", "EUI_Trinket1", "EUI_Trinket2", "EUI_Focus" }) do
            if GetMacroIndexByName(name) ~= 0 then return false end
        end
        return true
    end,
    -- First thing on the QoL page; its rows stay out of the search index.
    show = Goto("EllesmereUIQoL", "QoL"),
})
