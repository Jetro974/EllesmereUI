if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end -- Forever Hardcore loads on WoW Forever only
-------------------------------------------------------------------------------
--  EUI_ForeverHardcore_Deaths_Options.lua
--  Builds the "Deaths" page inside the Forever Hardcore module: whether this
--  character plays Hardcore, then the death alerts. Reads go through Get
--  (saved value, else the default); writes create only the key they change.
-------------------------------------------------------------------------------
local module = EllesmereUI._ModuleNS["EllesmereUIForeverHardcore"]
local DA = module and module.DeathAlerts
if not DA then return end  -- module disabled: no options page

_G._EUI_BuildHardcoreDeathsPage = function(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    local BLANK = EllesmereUI.BlankRowCfg
    local Get = DA.Get
    local y = yOffset
    local _, h
    parent._showRowDivider = true

    -- A toggle: the write, the event registration, then the rows it greys out.
    local function SetToggle(key, v)
        DA.Cfg()[key] = v
        DA.Apply()
        EllesmereUI:RefreshPage()
    end

    ---------------------------------------------------------------------------
    --  HARDCORE (whether this character plays the Hardcore ruleset)
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "HARDCORE", y);  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "label",
          text = module.IsHardcore() and "Hardcore Active on This Character" or "Hardcore Not Active on This Character",
          tooltip = "These settings are shared by all your characters and work on your Hardcore ones." },
        BLANK()
    );  y = y - h

    ---------------------------------------------------------------------------
    --  DEATH ALERTS (EllesmereUIForeverHardcore_DeathAlerts.lua)
    ---------------------------------------------------------------------------
    _, h = W:Spacer(parent, y, 20);  y = y - h
    _, h = W:SectionHeader(parent, "DEATH ALERTS", y);  y = y - h

    local sndValues, sndOrder = EllesmereUI.BuildSoundDropdownValues(DA.Sounds())
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Death Alert Sound",
          tooltip = "Plays a sound when the game announces a Hardcore death. A burst of deaths plays it once.",
          getValue = function() return Get("sound") end,
          setValue = function(v) SetToggle("sound", v) end },
        { type = "dropdown", text = "Sound", values = sndValues, order = sndOrder,
          disabled = function() return not Get("sound") end, disabledTooltip = "Death Alert Sound",
          getValue = function() return Get("soundKey") end,
          setValue = function(v) DA.Cfg().soundKey = v end }
    );  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Death Alerts in Chat",
          tooltip = "Also writes each Hardcore death the game announces to your chat, to read later. During a fight, once it ends.",
          getValue = function() return Get("chat") end,
          setValue = function(v) SetToggle("chat", v) end },
        { type = "labeledButton", text = "Test Alert", buttonText = "Test", width = 130,
          disabled = function() return not (Get("sound") or Get("chat")) end,
          disabledTooltip = "Death Alert Sound or Death Alerts in Chat",
          onClick = function() DA.Test() end }
    );  y = y - h

    return math.abs(y)
end
