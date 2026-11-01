if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EllesmereUI.IS_FOREVER then return end -- Forever Essentials has its own
-------------------------------------------------------------------------------
--  EllesmereUIQoL_MapFade.lua  (retail)
--  Fade Map While Moving: turns on the game's own map fade (mapFade CVar),
--  held while on and given back after. The map's background is covered by
--  Transparent World Map Sidebars.
-------------------------------------------------------------------------------
local OWNER = "EllesmereUIQoL"

-- Settings live in EllesmereUIDB.worldMapFade; unset keys read these.
-- mapFadeWas: the game's mapFade before ours.
local F = EllesmereUI.NewFeature("worldMapFade", { enabled = false }, nil,
    { group = "Quality of Life", folder = OWNER })

-- The game's fade on while ours is; back to what it was after.
local function Apply()
    local cfg = F.Read()
    local cur = C_CVar.GetCVar("mapFade")
    if F.Enabled() then
        cfg = F.Cfg()
        if cfg.mapFadeWas == nil then cfg.mapFadeWas = cur end
        if cur and cur ~= "1" then EllesmereUI.HoldCVar("mapFade", "1", OWNER) end
    elseif cfg.mapFadeWas ~= nil then
        local was = cfg.mapFadeWas
        cfg.mapFadeWas = nil
        if was and cur ~= was then EllesmereUI.ReleaseCVar("mapFade", was, OWNER) end
    end
end

-- Options-page entry points.
EllesmereUI._MapFade = {
    Get = F.Get,
    Cfg = F.Cfg,
    Apply = Apply,
}

F.Start(Apply)
