if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIForeverHardcore.lua  (WoW Forever only)
--  Hardcore companion for WoW Forever. Each feature lives in its own file,
--  listed after this one in the TOC; this file publishes the module.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if not (EllesmereUI and EllesmereUI._ModuleNS and EllesmereUI._Pool and EllesmereUI.NewFeatureKit) then EUI_CLIENT_BLOCKED = true; return end -- stale-parent guard: a partially updated install (old parent, new child) goes dormant via the line-1 failsafe instead of erroring
EllesmereUI._ModuleNS[ADDON_NAME] = ns  -- LOD options files read this module ns via the registry

-- Account-wide settings and the login boot for every feature (the shared
-- feature kit, EllesmereUI_SharedHelpers.lua).
ns.Feature = EllesmereUI.NewFeatureKit(ADDON_NAME, "Forever Hardcore")

-- Work that waits for the end of combat (EllesmereUI_Ticker.lua); idle, it
-- registers nothing.
ns.CombatQueue = EllesmereUI.NewCombatQueue(CreateFrame("Frame"))

-- Whether this character plays the Hardcore ruleset. Every feature listens to
-- its events only while this is true, so the module costs nothing elsewhere.
function ns.IsHardcore()
    return C_GameRules.IsHardcoreActive() == true
end
