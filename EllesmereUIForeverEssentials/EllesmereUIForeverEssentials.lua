if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials.lua  (WoW Forever only)
--  Essential tools for WoW Forever. Each feature lives in its own file, listed
--  after this one in the TOC; this file publishes the module.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if not (EllesmereUI and EllesmereUI._ModuleNS and EllesmereUI._Pool and EllesmereUI.NewFeature) then EUI_CLIENT_BLOCKED = true; return end -- stale-parent guard: a partially updated install (old parent, new child) goes dormant via the line-1 failsafe instead of erroring
EllesmereUI._ModuleNS[ADDON_NAME] = ns  -- LOD options files read this module ns via the registry

-- Lifecycle object (OnInitialize / OnEnable) for features that need one. No
-- per-profile DB: every feature so far keeps account-wide settings.
ns.addon = EllesmereUI.Lite.NewAddon(ADDON_NAME)

-------------------------------------------------------------------------------
--  Feature kit: the core's EllesmereUI.NewFeature (EllesmereUI_Feature.lua),
--  with this module's unlock mode group and folder.
-------------------------------------------------------------------------------
local FE_OWNER = { group = "Forever Essentials", folder = "EllesmereUIForeverEssentials" }
function ns.Feature(dbKey, defaults, defaultPos)
    return EllesmereUI.NewFeature(dbKey, defaults, defaultPos, FE_OWNER)
end
