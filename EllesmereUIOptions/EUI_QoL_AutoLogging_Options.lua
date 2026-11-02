if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_QoL_AutoLogging_Options.lua
--  Options page for the Auto Combat Logging feature.
-------------------------------------------------------------------------------

-- Must match TRIGGER_DEFAULTS in the runtime.
if not EllesmereUI._ModuleNS["EllesmereUIQoL"] then return end  -- module disabled: no options page

local TRIGGER_DEFAULTS = {
    logMythic   = true,
    logHeroic   = true,
    logNormal   = true,
    logLFR      = true,
    log5pp      = true,
    logArena    = true,
    logScenario = false,
    delaystop   = true,
}

local TRIGGER_ITEMS = {
    { key = "logMythic",   label = "Mythic Raid" },
    { key = "logHeroic",   label = "Heroic Raid" },
    { key = "logNormal",   label = "Normal Raid" },
    { key = "logLFR",      label = "LFR" },
    { key = "log5pp",      label = "Mythic+ Dungeons" },
    { key = "logArena",    label = "Arena" },
    { key = "logScenario", label = "Scenarios" },
}
-- WoW Forever: every raid instance logs on the Raids trigger (the Normal Raid
-- key and its default) and every dungeon on the Dungeons trigger (a key only
-- that client offers, off until the player turns it on). The retail
-- difficulty, Mythic+, arena and scenario rows have nothing to match there.
if EllesmereUI.IS_FOREVER then
    TRIGGER_ITEMS = {
        { key = "logNormal",  label = "Raids" },
        { key = "logDungeon", label = "Dungeons" },
    }
end

local function Cfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.autoLogging = EllesmereUIDB.autoLogging or {}
    return EllesmereUIDB.autoLogging
end

local function Recheck()
    if _G._EUI_AutoLogging_Check then _G._EUI_AutoLogging_Check() end
end

local function KeysCfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.keystonePopup = EllesmereUIDB.keystonePopup or {}
    return EllesmereUIDB.keystonePopup
end

local function TeleCfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.teleportPrompt = EllesmereUIDB.teleportPrompt or {}
    return EllesmereUIDB.teleportPrompt
end

-- Read-only: the /way table appears on the first write, so viewing the page
-- saves nothing.
local NO_WAY_CFG = {}
local function WayCfg()
    return EllesmereUIDB and EllesmereUIDB.waypointCmd or NO_WAY_CFG
end

local function SetWay(key, value)
    if not EllesmereUIDB then return end
    EllesmereUIDB.waypointCmd = EllesmereUIDB.waypointCmd or {}
    EllesmereUIDB.waypointCmd[key] = value
end

-- Built as the tail of the Quality of Life page (chained from BuildQoLPage),
-- not as its own tab. Lays out from yOffset and returns the height used,
-- like every other section builder.
local function BuildAutoLoggingPage(pageName, parent, yOffset)
    local W  = EllesmereUI.Widgets
    local PP = EllesmereUI.PanelPP
    local y  = yOffset
    local _, h

    parent._showRowDivider = true

    ---------------------------------------------------------------------------
    --  KEYSTONE CHECK POPUP (no keystones on WoW Forever: the section and the
    --  /keys file behind it do not exist there)
    ---------------------------------------------------------------------------
    if not EllesmereUI.IS_FOREVER then
    _, h = W:SectionHeader(parent, "KEYSTONE CHECK POPUP", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type    = "toggle",
          text    = "Enable /keys Popup (or /ekeys)",
          tooltip = "Shows a popup with party and guild keystones when typing /keys.",
          -- DependentSetValue: the Window Scale row below is hidden while the
          -- popup is off; the flip forces the full rebuild.
          setValue = EllesmereUI.DependentSetValue(
              function() return KeysCfg().enabled ~= false end,
              function(v)
                  KeysCfg().enabled = v
                  EllesmereUI:RefreshPage()
                  EllesmereUI:ShowConfirmPopup({
                      title = "Reload Required",
                      message = "Changing the /keys popup requires a reload to update slash command registration.",
                      confirmText = "Reload",
                      cancelText = "Later",
                      reload    = true,
                  })
              end),
          getValue = function() return KeysCfg().enabled ~= false end },
        { type    = "slider",
          text    = "Text Size",
          min     = 8, max = 16, step = 1,
          disabled = function() return KeysCfg().enabled == false end,
          disabledTooltip = "/keys Popup",
          tooltip = "Font size for keystone entries in the popup (does not affect the header).",
          getValue = function() return KeysCfg().textSize or 11 end,
          setValue = function(v)
              KeysCfg().textSize = v
              if _G._EUI_RefreshKeystonePopup then _G._EUI_RefreshKeystonePopup() end
          end }
    ); y = y - h

    -- Window Scale row: HIDDEN entirely while the /keys popup is off.
    if KeysCfg().enabled ~= false then
    _, h = W:DualRow(parent, y,
        { type    = "slider",
          text    = "Window Scale",
          min     = 50, max = 150, step = 5,
          tooltip = "Scale of the /keys popup window.",
          getValue = function() return math.floor((KeysCfg().scale or 1.05) * 100 + 0.5) end,
          setValue = function(v)
              KeysCfg().scale = v / 100
              local popup = _G.EUIKeysPopup
              if popup then popup:SetScale(v / 100) end
          end },
        { type = "label", text = "" }
    ); y = y - h
    end   -- close /keys popup hidden-while-disabled gate

    _, h = W:Spacer(parent, y, 20); y = y - h
    end -- not IS_FOREVER

    ---------------------------------------------------------------------------
    --  LFG REMINDER (no dungeon teleports on WoW Forever: the section and the
    --  reminder runtime behind it do not exist there)
    ---------------------------------------------------------------------------
    if not EllesmereUI.IS_FOREVER then
    _, h = W:SectionHeader(parent, "LFG REMINDER", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type    = "toggle",
          text    = "Enable LFG Reminder",
          tooltip = "When you join a Group Finder group for a dungeon that has a teleport, shows a small movable popup with the dungeon name and a one-click teleport button. It hides when you enter the dungeon, leave the group, or enter combat.",
          getValue = function() return TeleCfg().enabled ~= false end,
          -- DependentSetValue: the Show 'Disable Feature' Text row below is
          -- hidden while the reminder is off; the flip forces the rebuild.
          setValue = EllesmereUI.DependentSetValue(
              function() return TeleCfg().enabled ~= false end,
              function(v)
                  TeleCfg().enabled = v
                  EllesmereUI:RefreshPage()
                  -- Applies live in both directions: enable builds the popup and
                  -- registers events, disable hides and unregisters.
                  if _G._EUI_ApplyTeleportPrompt then _G._EUI_ApplyTeleportPrompt() end
              end) },
        { type    = "slider",
          text    = "Window Scale",
          min     = 50, max = 150, step = 5,
          disabled = function() return TeleCfg().enabled == false end,
          disabledTooltip = "LFG Reminder",
          tooltip = "Scale of the LFG Reminder popup window.",
          getValue = function() return math.floor((TeleCfg().scale or 1.05) * 100 + 0.5) end,
          setValue = function(v)
              TeleCfg().scale = v / 100
              if _G._EUI_RefreshTeleportPrompt then _G._EUI_RefreshTeleportPrompt() end
          end }
    ); y = y - h

    -- Show 'Disable Feature' Text row: HIDDEN while the reminder is off.
    if TeleCfg().enabled ~= false then
    _, h = W:DualRow(parent, y,
        { type    = "toggle",
          text    = "Show 'Disable Feature' Text",
          tooltip = "Shows the 'Disable Feature' text below the teleport button. When off, the text is hidden and the window is 20px shorter.",
          getValue = function() return TeleCfg().showDisable ~= false end,
          setValue = function(v)
              TeleCfg().showDisable = v
              if _G._EUI_RefreshTeleportPrompt then _G._EUI_RefreshTeleportPrompt() end
          end },
        { type = "label", text = "" }
    ); y = y - h
    end   -- close LFG Reminder hidden-while-disabled gate

    _, h = W:Spacer(parent, y, 20); y = y - h
    end -- not IS_FOREVER

    ---------------------------------------------------------------------------
    --  WAYPOINT COMMAND (/way, runtime in EllesmereUIQoL_Waypoint.lua)
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "WAYPOINT COMMAND", y); y = y - h

    local wayRow
    wayRow, h = W:DualRow(parent, y,
        { type    = "toggle",
          text    = "Enable /way Command",
          tooltip = "Adds /way, which prints a map pin link.",
          -- Off by default.
          getValue = function() return WayCfg().enabled == true end,
          setValue = function(v)
              SetWay("enabled", v or nil)
              EllesmereUI:RefreshPage()
              EllesmereUI:ShowConfirmPopup({
                  title = "Reload Required",
                  message = "Changing the /way command requires a reload to update slash command registration.",
                  confirmText = "Reload",
                  cancelText = "Later",
                  reload    = true,
              })
          end },
        EllesmereUI.BlankRowCfg()
    ); y = y - h

    -- The arrival message for hand-placed pins (off by default). The runtime
    -- reads it live and listens for arrivals only while it or a /way list
    -- needs them, so a change re-syncs that listener.
    EllesmereUI.BuildInlineCog(wayRow._leftRegion, {
        title = "/way Command",
        disabled = function() return WayCfg().enabled ~= true end,
        disabledTooltip = "Enable /way Command",
        rows = {
            { type="toggle", label="Hand-Placed Pin Arrival",
              tooltip="Also announces arrival at pins you place.",
              get=function() return WayCfg().manualArrival == true end,
              set=function(v)
                  SetWay("manualArrival", v or nil)
                  local sync = EllesmereUI._ModuleNS["EllesmereUIQoL"].WaypointArrivalSync
                  if sync then sync() end
              end },
        },
    })

    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  FISHING (runtime in EllesmereUIQoL_Fishing.lua)
    ---------------------------------------------------------------------------
    local FI = EllesmereUI._Fishing
    local function SetFish(key, v)
        FI.Cfg()[key] = v
        FI.Apply()
    end

    local hdr
    hdr, h = W:SectionHeader(parent, "FISHING", y);  y = y - h
    -- The Bobber Indicator's mover exists only while the indicator can show:
    -- the Fishing Key bound with Reel In and Bobber Indicator on (the cog's
    -- rows), so the button names whichever of the three is missing.
    EllesmereUI.BuildSectionUnlockJump(hdr, { key = "EUI_FishingBobber",
        disabled = function() return FI.Get("key") == nil or not FI.Get("reel") or not FI.Get("indicator") end,
        disabledTooltip = function()
            if FI.Get("key") == nil then return "Fishing Key" end
            if not FI.Get("reel") then return "Reel In With the Key" end
            return "Bobber Indicator"
        end })

    -- Fishing Key (keybind, its options in the cog) | Double-Click to Cast
    local fishKeyRow
    fishKeyRow, h = W:DualRow(parent, y,
        { type = "label", text = "Fishing Key",
          tooltip = EllesmereUI.IS_FOREVER
              and "One key casts your line, equipping your best fishing pole first. Use the cog for reeling in, the bobber indicator and lures."
              or "One key casts your line, equipping your best fishing pole first. Use the cog for reeling in and the bobber indicator." },
        { type = "toggle", text = "Double-Click to Cast",
          tooltip = "With a fishing pole in hand, double right-click the world to cast.",
          disabled = function() return EllesmereUI.PadGamepadUI() end,
          disabledTooltip = "This option does not work with the Gamepad interface style.",
          getValue = function() return FI.Get("doubleClick") end,
          setValue = function(v)
              SetFish("doubleClick", v)
              EllesmereUI:RefreshPage()  -- the cog's disabled state
          end }
    );  y = y - h
    if not EllesmereUI._prebuilding then
        local rgn = fishKeyRow._leftRegion
        local kbBtn, refresh = EllesmereUI.BuildKeybindButton(rgn, {
            w = 140, h = 30, font = 13,
            get = function() return FI.Get("key") end,
            set = function(v)
                SetFish("key", v)
                EllesmereUI:RefreshPage()  -- the cog's disabled state
            end,
            tooltip = "Left-click to set a keybind.\nRight-click to unbind.",
        })
        EllesmereUI.PanelPP.Point(kbBtn, "RIGHT", rgn, "RIGHT", -20, 0)
        EllesmereUI.RegisterWidgetRefresh(refresh)

        local function fishRow(label, tooltip, key)
            return { type = "toggle", label = label, tooltip = tooltip,
                get = function() return FI.Get(key) end,
                set = function(v) SetFish(key, v) end }
        end
        -- A label half has no control: the cog sits left of the keybind
        -- button, which also bounds the label.
        local keyRows = {
            fishRow("Reel In With the Key", "Once the bobber bites and is on screen, the Fishing Key reels it in.", "reel"),
            fishRow("Bobber Indicator", "Shows whether the key will reel in. Place it in Unlock Mode.", "indicator"),
        }
        -- Lures are weapon enchants on the pole: WoW Forever only.
        if EllesmereUI.IS_FOREVER then
            keyRows[#keyRows + 1] = fishRow("Apply Lure", "With no lure on your pole, the key applies your best lure first.", "lure")
        end
        EllesmereUI.BuildInlineCog(rgn, {
            title = "Fishing Key",
            rows = keyRows,
            anchorTo = kbBtn,
            disabled = function() return FI.Get("key") == nil end,
            disabledTooltip = "Fishing Key",
        })
        if EllesmereUI.IS_FOREVER then
            EllesmereUI.BuildInlineCog(fishKeyRow._rightRegion, {
                title = "Double-Click to Cast",
                rows = { fishRow("Apply Lure", "With no lure on your pole, a double-click applies your best lure first.", "clickLure") },
                disabled = function() return EllesmereUI.PadGamepadUI() or not FI.Get("doubleClick") end,
                disabledTooltip = function()
                    if EllesmereUI.PadGamepadUI() then return "This option does not work with the Gamepad interface style." end
                    return "Double-Click to Cast"
                end,
            })
        end
    end

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Fishing Sounds",
          tooltip = "While you fish: music and ambience down, effects up, sound on in the background.",
          getValue = function() return FI.Get("sound") end,
          setValue = function(v) SetFish("sound", v) end },
        EllesmereUI.BlankRowCfg()
    );  y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  COMPANION PETS (runtime in EllesmereUIQoL_PetSummon.lua)
    ---------------------------------------------------------------------------
    local PS = EllesmereUI._PetSummon
    if PS and C_PetJournal then
        _, h = W:SectionHeader(parent, "COMPANION PETS", y);  y = y - h

        _, h = W:DualRow(parent, y,
            { type = "toggle", text = "Auto Summon Pet",
              tooltip = "Brings a random favorite pet back after loading screens, flights and deaths; a pet you dismiss stays away.",
              getValue = function() return PS.Get("enabled") end,
              setValue = function(v)
                  PS.Cfg().enabled = v
                  PS.Apply(v)  -- turning it on also ends an earlier dismissal
                  EllesmereUI:RefreshPage()  -- Favorites per Character's disabled state
              end },
            { type = "toggle", text = "Favorites per Character",
              tooltip = "Pick this character's favorites from a pet's right-click menu in the Pet Journal.",
              disabled = function() return not PS.Get("enabled") end,
              disabledTooltip = "Auto Summon Pet",
              -- This character's own setting, read without creating its table.
              getValue = function()
                  local chars, guid = PS.Get("chars"), UnitGUID("player")
                  return chars ~= nil and guid ~= nil and chars[guid] ~= nil and chars[guid].own == true
              end,
              setValue = function(v)
                  local guid = UnitGUID("player")
                  if not guid then return end
                  local cfg = PS.Cfg()
                  cfg.chars = cfg.chars or {}
                  cfg.chars[guid] = cfg.chars[guid] or {}
                  cfg.chars[guid].own = v or nil
                  PS.RefreshJournal()
              end }
        );  y = y - h

        _, h = W:Spacer(parent, y, 20); y = y - h
    end


    ---------------------------------------------------------------------------
    --  QUEST REWARDS (runtime in EllesmereUIQoL_QuestRewards.lua)
    ---------------------------------------------------------------------------
    local QR = EllesmereUI._QuestRewards
    _, h = W:SectionHeader(parent, "QUEST REWARDS", y);  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Most Valuable Reward",
          tooltip = EllesmereUI.IS_FOREVER
              and "Among a quest's reward choices, a money bag marks the one that sells for most, its count included."
              or "Among a quest's reward choices, a gold coin marks the one that sells for most, its count included.",
          getValue = function() return QR.Get("enabled") end,
          setValue = function(v)
              QR.Cfg().enabled = v
              QR.Apply()
          end },
        EllesmereUI.BlankRowCfg()
    );  y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h


    ---------------------------------------------------------------------------
    --  AUTO COMBAT LOGGING
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "AUTO COMBAT LOGGING", y); y = y - h

    local trigRow, trigH = W:DualRow(parent, y,
        { type    = "toggle",
          text    = "Enable Auto Logging",
          tooltip = "Automatically starts and stops combat logging when entering or leaving a loggable instance.",
          getValue = function() return Cfg().enabled == true end,
          -- DependentSetValue: the Warcraft Recorder row below is hidden
          -- while auto logging is off; the flip forces the full rebuild.
          setValue = EllesmereUI.DependentSetValue(
              function() return Cfg().enabled == true end,
              function(v)
                  Cfg().enabled = v or nil
                  Recheck()
                  EllesmereUI:RefreshPage()
              end) },
        { type    = "dropdown", text = "Auto-Log Triggers",
          values  = { __placeholder = "..." }, order = { "__placeholder" },
          getValue = function() return "__placeholder" end,
          setValue = function() end }
    ); y = y - trigH

    -- Replace dummy dropdown with a checkbox dropdown.
    do
        local rightRgn = trigRow._rightRegion
        if rightRgn._control then rightRgn._control:Hide() end

        local cbDD, cbDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
            rightRgn,
            210,
            rightRgn:GetFrameLevel() + 2,
            TRIGGER_ITEMS,
            function(k)
                local v = Cfg()[k]
                if v == nil then return TRIGGER_DEFAULTS[k] end
                return v
            end,
            function(k, v) Cfg()[k] = v; Recheck() end
        )
        PP.Point(cbDD, "RIGHT", rightRgn, "RIGHT", -20, 0)
        rightRgn._control = cbDD
        rightRgn._lastInline = nil

        EllesmereUI.RegisterWidgetRefresh(cbDDRefresh)

        -- Gray + block the triggers dropdown (and its label) while Auto
        -- Logging is off; the CB dropdown has no native disabled handling.
        local function UpdateTrigDisabled()
            local off = Cfg().enabled ~= true
            cbDD:SetAlpha(off and 0.3 or 1)
            cbDD:EnableMouse(not off)
            if rightRgn._label then rightRgn._label:SetAlpha(off and 0.3 or 1) end
        end
        UpdateTrigDisabled()
        EllesmereUI.RegisterWidgetRefresh(UpdateTrigDisabled)
    end

    -- Warcraft Recorder row: HIDDEN entirely while Auto Logging is off.
    if Cfg().enabled == true then
    _, h = W:DualRow(parent, y,
        { type    = "toggle",
          text    = "Warcraft Recorder Compatibility",
          tooltip = "Delays stopping combat logging by 30 seconds after leaving an instance. Recommended for Warcraft Recorder compatibility.",
          getValue = function()
              local v = Cfg().delaystop
              if v == nil then return TRIGGER_DEFAULTS.delaystop end
              return v
          end,
          setValue = function(v)
              Cfg().delaystop = v
          end },
        { type = "label", text = "" }
    ); y = y - h
    end   -- close Auto Logging hidden-while-disabled gate

    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  ALERTS (Combat Alert, Potion Ready, Unspent Talents; one shared anchor)
    ---------------------------------------------------------------------------
    if _G._EUI_BuildAlertsSection then
        local alertsH = _G._EUI_BuildAlertsSection(parent, y, W, EllesmereUI.PP)
        y = y - alertsH
    end

    ---------------------------------------------------------------------------
    --  BATTLE RES (no shared battle res charges on WoW Forever: the indicator
    --  runtime builds nothing there and the section is not built)
    ---------------------------------------------------------------------------
    if _G._EUI_BuildBattleResSection and not EllesmereUI.IS_FOREVER then
        local brezH = _G._EUI_BuildBattleResSection(parent, y, W, EllesmereUI.PP)
        y = y - brezH
    end

    ---------------------------------------------------------------------------
    --  BLOODLUST TRACKER (no raid-wide lust on WoW Forever: the tracker
    --  runtime returns at load there and the section is not built)
    ---------------------------------------------------------------------------
    if _G._EUI_BuildBloodlustSection and not EllesmereUI.IS_FOREVER then
        local lustH = _G._EUI_BuildBloodlustSection(parent, y, W, EllesmereUI.PP)
        y = y - lustH
    end

    return math.abs(y - yOffset)
end

_G._EUI_BuildAutoLoggingPage = BuildAutoLoggingPage
