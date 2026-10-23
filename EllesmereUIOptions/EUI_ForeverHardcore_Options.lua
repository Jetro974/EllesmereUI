if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_ForeverHardcore_Options.lua
--  Registers the Forever Hardcore sidebar addon (WoW Forever only) with its
--  tabs:
--    * Deaths -- death alerts (built by EUI_ForeverHardcore_Deaths_Options.lua)
-------------------------------------------------------------------------------
-- Page names are DEEP-LINK IDENTIFIERS: every NavigateToElementSettings tuple
-- and What's New nav carries them as strings and fails SILENTLY on a mismatch.
if not EllesmereUI._ModuleNS["EllesmereUIForeverHardcore"] then return end  -- module disabled: no options page

local PAGE_DEATHS = "Deaths"

-- Page reuse: a frame this file builds goes through the options frame pool
-- (EllesmereUI_FramePool.lua, the options addon's first file), which hands a
-- kept page its previous build's frames back reset to new; on any other
-- parent it is the plain CreateFrame. The buildPage below only hands each
-- tab to its own page file.
local CreateFrame = EllesmereUI._Pool.CreateFrame

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    EllesmereUI:RegisterModule("EllesmereUIForeverHardcore", {
        title       = "Forever Hardcore",
        description = "Hardcore companion for WoW Forever.",
        pages       = { PAGE_DEATHS },
        searchTerms = { "hardcore", "hc", "death", "deaths", "death alert", "death alerts", "permadeath" },
        buildPage   = function(pageName, parent, yOffset)
            if pageName == PAGE_DEATHS and _G._EUI_BuildHardcoreDeathsPage then
                return _G._EUI_BuildHardcoreDeathsPage(pageName, parent, yOffset)
            end
        end,
        resetScope = "account",
        onReset = function()
            if EllesmereUIDB then
                EllesmereUIDB.hcDeathAlerts = nil
            end
            local module = EllesmereUI._ModuleNS["EllesmereUIForeverHardcore"]
            if module.DeathAlerts then module.DeathAlerts.Apply() end
            EllesmereUI:InvalidatePageCache()
        end,
    })
end)
-- LoadOnDemand: this addon loads after PLAYER_LOGIN, so the event above will never fire; run the init now.
if IsLoggedIn() then initFrame:GetScript("OnEvent")(initFrame) end
