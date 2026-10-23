if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverHardcore_DeathAlerts.lua  (WoW Forever only)
--  Death alerts: the game announces each Hardcore death (HARDCORE_DEATHS) as
--  red text in the middle of the screen, silent and gone in seconds. Each
--  half here is opt-in: a sound when one arrives, and the same line in chat
--  to read later. The event is registered only on a Hardcore character with
--  one of them on; the game's own alert is left as it is.
-------------------------------------------------------------------------------
local _, module = ...

-- Settings live in EllesmereUIDB.hcDeathAlerts; unset keys read these.
local F = module.Feature("hcDeathAlerts", { sound = false, soundKey = "none", chat = false })
local Get = F.Get

-- The red of the game's own death alert (Blizzard_RaidWarning).
local DEATH_COLOR = "|cffff3333"
-- Seconds between two sounds, so a burst of deaths (a group wipe) plays one.
local SOUND_GAP = 3

local events = CreateFrame("Frame")
local lastSound = 0

local soundPaths, soundNames, soundOrder
local function Sounds()
    if not soundPaths then
        soundPaths, soundNames, soundOrder = EllesmereUI.BuildAlertSoundTables()
        EllesmereUI.AppendSharedMediaSounds(soundPaths, soundNames, soundOrder)
    end
    return soundPaths, soundNames, soundOrder
end

-- Chat lines from a fight: EllesmereUI.Print drops lines in raid and PvP
-- combat, so they wait for the fight to end.
local held = {}
local function PrintHeld()
    local lines = held
    held = {}
    for i = 1, #lines do EllesmereUI.Print(lines[i]) end
end

-- message: the game's sentence, printed as it comes; force (the test) skips
-- the gap between sounds.
local function Alert(message, force)
    if Get("sound") then
        local now = GetTime()
        if force or now - lastSound >= SOUND_GAP then
            lastSound = now
            EllesmereUI.PlaySoundPath(Sounds()[Get("soundKey")])
        end
    end
    if Get("chat") and type(message) == "string" and not issecretvalue(message) then
        local line = EllesmereUI.COLOR_CODES.BRAND .. "EllesmereUI:|r " .. DEATH_COLOR .. message .. "|r"
        if InCombatLockdown() then
            held[#held + 1] = line
            module.CombatQueue.Defer("hcDeathChat", PrintHeld)
        else
            EllesmereUI.Print(line)
        end
    end
end

events:SetScript("OnEvent", function(_, _, message)
    Alert(message)
end)

local function Apply()
    if (Get("sound") or Get("chat")) and module.IsHardcore() then
        events:RegisterEvent("HARDCORE_DEATHS")
    else
        events:UnregisterAllEvents()
    end
end

-- Options-page entry points.
module.DeathAlerts = {
    Get = Get,
    Cfg = F.Cfg,
    Apply = Apply,
    Sounds = Sounds,
    Test = function()
        Alert(EllesmereUI.L("Death alert test: a Hardcore death shows like this."), true)
    end,
}

F.Start(Apply)
