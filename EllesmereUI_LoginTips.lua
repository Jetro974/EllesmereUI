if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUI_LoginTips.lua
--
--  EUI Tips: one short chat line at login with general advice about
--  EllesmereUI, like a loading screen tip, and an optional [Show Me] link
--  that opens the matching options. Never a popup: a chat line cannot
--  collide with the login popups. Off by default (General > Login Tips).
--
--  A tip is advice, not a reminder: it may cover a feature that is already
--  on (a shortcut, a hidden trick, how to use it well), so nothing is read
--  from the settings to decide whether to show it.
--
--  LISTS: one per game mode, never mixed, because WoW Forever and retail run
--  different module sets.
--    forever  EllesmereUI_LoginTips_Forever.lua
--    retail   none yet. To add one, create EllesmereUI_LoginTips_Retail.lua
--             (copy the Forever file's shape, register "retail"), list it in
--             EllesmereUI.toc after this file, and add its strings to the
--             locales. Until then retail shows no tips, hides the General
--             option and registers nothing at login.
--
--  API (EllesmereUI.LoginTips):
--    Register(mode, build)  -- build() returns the ordered tips:
--        { id = "unlock",                     (stable: the seen state keys on it)
--          addon = "EllesmereUIActionBars",   (optional: shown only while loaded)
--          text  = EllesmereUI.L("..."),
--          show  = function() ... end },      (optional: the [Show Me] action)
--      build runs when a tip prints, never at file load: locale strings only
--      exist from ADDON_LOADED on.
--    Goto(module, page, section)  -- a [Show Me] action opening that page
--      (and section). Rows are not targeted: their labels change too often.
--    HasTips()  -- true when the current mode has a list
--    ShowNext() -- print the next tip now
--
--  ROTATION: one tip per login, in list order, skipping the ones already
--  printed; once every tip was printed the round starts over.
--
--  When a tip prints at login (all must hold): a real login, never a
--  /reload; not an install session (module or style picker); out of combat
--  and outside instances; EllesmereUIDB.loginTips == true.
--
--  State (per account): EllesmereUIDB.loginTipsState = { seen = { [id] = true } }
-------------------------------------------------------------------------------

local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

-- Suite-only: tips point at suite surfaces (options pages, Unlock Mode).
local EUI_HOST_ADDON = ...
if type(EUI_HOST_ADDON) == "string" and EUI_HOST_ADDON:find("Standalone") then return end

local PRINT_DELAY = 8       -- seconds after login: lets the login burst of chat lines settle
local LINK_PREFIX = "addon:EllesmereUI:tip:"

local builders = {}         -- [mode] = build function
local shown = {}            -- [id] = show action of a printed tip (for its link)

local function Mode()
    return EllesmereUI.IS_FOREVER and "forever" or "retail"
end

local function Seen()
    if not EllesmereUIDB then return {} end
    local s = EllesmereUIDB.loginTipsState
    if type(s) ~= "table" then
        s = {}
        EllesmereUIDB.loginTipsState = s
    end
    s.seen = s.seen or {}
    return s.seen
end

local function Loaded(folder)
    return not folder or (C_AddOns.IsAddOnLoaded(folder) and true or false)
end

-- The next tip of the round; a finished round starts over.
local function NextTip()
    local build = builders[Mode()]
    if not build then return nil end
    local list, seen, first = build(), Seen(), nil
    for _, tip in ipairs(list) do
        if Loaded(tip.addon) then
            if not seen[tip.id] then return tip end
            first = first or tip
        end
    end
    if first then wipe(seen) end
    return first
end

local function Link(id, action, label, color)
    return color .. "|H" .. LINK_PREFIX .. action .. ":" .. id .. "|h[" .. label .. "]|h|r"
end

local function ShowNext()
    local tip = NextTip()
    if not tip then return false end
    local L, CC = EllesmereUI.L, EllesmereUI.COLOR_CODES
    local line = CC.BRAND .. L("EUI Tip:") .. "|r " .. tip.text
    if tip.show then
        shown[tip.id] = tip.show
        line = line .. " " .. Link(tip.id, "show", L("Show Me"), CC.BRAND)
    end
    EllesmereUI.Print(line .. " " .. Link(tip.id, "off", L("Turn Off Tips"), CC.DIM))
    Seen()[tip.id] = true
    return true
end

local function SetEnabled(on)
    if EllesmereUIDB then EllesmereUIDB.loginTips = on end
    EllesmereUI.Print(EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r " .. (on
        and EllesmereUI.L("Login tips turned on.")
        or EllesmereUI.L("Login tips turned off. Type /euitips on to turn them back on.")))
end

-------------------------------------------------------------------------------
--  Login, chat links and /euitips: set up by the current mode's first
--  Register, so a mode without a list registers nothing.
-------------------------------------------------------------------------------
local function Setup()
    hooksecurefunc("SetItemRef", function(link)
        if not link or (issecretvalue and issecretvalue(link)) then return end
        local action, id = link:match("^" .. LINK_PREFIX .. "(%a+):(.+)$")
        if not action then return end
        -- Deferred one frame: keeps option panel builds out of the click's execution.
        C_Timer.After(0, function()
            if action == "off" then
                SetEnabled(false)
            elseif action == "show" and shown[id] then
                shown[id]()   -- NavigateToElementSettings refuses in combat itself
            end
        end)
    end)

    -- /euitips: the next tip now; /euitips on | off: login tips on / off.
    SLASH_EUITIPS1 = "/euitips"
    SlashCmdList.EUITIPS = function(msg)
        local cmd = (msg or ""):lower():match("^%s*(.-)%s*$")
        C_Timer.After(0, function()
            if cmd == "on" or cmd == "off" then SetEnabled(cmd == "on") else ShowNext() end
        end)
    end

    local loader = CreateFrame("Frame")
    loader:RegisterEvent("PLAYER_ENTERING_WORLD")
    loader:SetScript("OnEvent", function(self, _, isInitialLogin, isReloadingUi)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if not isInitialLogin or isReloadingUi then return end
        if not (EllesmereUIDB and EllesmereUIDB.loginTips == true) then return end
        if EllesmereUI._firstInstallPending or EllesmereUI._styleChoicePending
           or EllesmereUIDB.styleChoicePending then return end
        C_Timer.After(PRINT_DELAY, function()
            if InCombatLockdown() or IsInInstance() then return end
            ShowNext()
        end)
    end)
end

EllesmereUI.LoginTips = {
    -- A list for another mode is ignored: each client keeps only its own.
    Register = function(mode, build)
        if mode ~= Mode() then return end
        if not builders[mode] then Setup() end
        builders[mode] = build
    end,
    HasTips  = function() return builders[Mode()] ~= nil end,
    ShowNext = ShowNext,
    Goto = function(module, page, section)
        return function() EllesmereUI:NavigateToElementSettings(module, page, section) end
    end,
}
