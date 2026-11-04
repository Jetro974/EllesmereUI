if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_QoL_Alerts_Options.lua
--  ALERTS section: Combat Alert, Potion Ready Alert, Unspent Talents Alert,
--  Craft Ready Alert, World Events and Rare Mob Alerts (WoW Forever) and Announce Group Deaths. The first three share one movable anchor (Unlock Mode:
--  Alerts) and have their own text, size and color; their runtime is
--  EllesmereUIQoL_Alerts.lua. Group Deaths keeps its own overlay (EllesmereUIQoL.lua).
-------------------------------------------------------------------------------

if not EllesmereUI._ModuleNS["EllesmereUIQoL"] then return end  -- module disabled: no options page

-- Text, size, color and class-color rows for the Potion / Talent alerts
-- (keys: <prefix>Text / TextSize / Color / UseClassColor; defaults come from
-- the alert itself so the swatch always shows the real default).
local function AlertCogRows(prefix, applyFrame, preview)
    local D = (EllesmereUI.Alerts and EllesmereUI.Alerts.DEFAULTS[prefix])
        or { text = "", color = { r = 1, g = 1, b = 1 } }
    local function db(k) return EllesmereUIDB and EllesmereUIDB[prefix .. k] end
    local function put(k, v)
        if not EllesmereUIDB then EllesmereUIDB = {} end
        EllesmereUIDB[prefix .. k] = v
    end
    return {
        { type="input", label="Text", inputWidth=130,
          get=function() return db("Text") or D.text end,
          set=function(v) put("Text", v); if EllesmereUI[preview] then EllesmereUI[preview]() end end },
        { type="slider", label="Text Size", min=14, max=64, step=1,
          get=function() return db("TextSize") or 22 end,
          set=function(v)
            put("TextSize", v)
            if EllesmereUI[applyFrame] then EllesmereUI[applyFrame]() end
            if EllesmereUI[preview] then EllesmereUI[preview]() end
          end },
        { type="colorpicker", label="Color",
          disabled=function() return db("UseClassColor") end,
          disabledTooltip="Disable Class Color to pick a custom color.", rawTooltip=true,
          get=function()
            local c = db("Color") or D.color
            return c.r, c.g, c.b
          end,
          set=function(r, g, b)
            put("Color", { r=r, g=g, b=b })
            if EllesmereUI[preview] then EllesmereUI[preview]() end
          end },
        { type="toggle", label="Class Color",
          get=function() return db("UseClassColor") end,
          set=function(v) put("UseClassColor", v); if EllesmereUI[preview] then EllesmereUI[preview]() end end },
    }
end

_G._EUI_BuildAlertsSection = function(parent, yOffset, W, PP)
    local y = yOffset
    local _, h, hdr

    hdr, h = W:SectionHeader(parent, "ALERTS", y); y = y - h
    -- One anchor carries the Combat, Potion Ready and Unspent Talents alerts,
    -- each with its own enable, so the button has no single requirement.
    EllesmereUI.BuildSectionUnlockJump(hdr, { key = "EUI_CombatAlert" })

    local row1
    row1, h = W:DualRow(parent, y,
        { type="toggle", text="Combat Alert",
          tooltip="Shows a large on-screen text when you enter and/or leave combat (e.g. \"+Combat\" / \"-Combat\"). Use the cog to set the display text, size, colors and which transitions are shown; use Unlock Mode to reposition the alert.",
          getValue=function()
              return EllesmereUIDB and EllesmereUIDB.combatAlertEnabled or false
          end,
          setValue=function(v)
              if not EllesmereUIDB then EllesmereUIDB = {} end
              EllesmereUIDB.combatAlertEnabled = v
              if EllesmereUI._applyCombatAlert then EllesmereUI._applyCombatAlert() end
              EllesmereUI:RefreshPage()
          end },
        { type="toggle", text="Potion Ready Alert",
          tooltip="Shows on-screen text when a potion you used is off cooldown again. Use the cog to set the text, size and color; use Unlock Mode to reposition the alerts.",
          getValue=function()
              return EllesmereUIDB and EllesmereUIDB.potionAlertEnabled or false
          end,
          setValue=function(v)
              if not EllesmereUIDB then EllesmereUIDB = {} end
              EllesmereUIDB.potionAlertEnabled = v
              if EllesmereUI._applyPotionAlert then EllesmereUI._applyPotionAlert() end
              EllesmereUI:RefreshPage()
          end }
    );  y = y - h

    local row2
    row2, h = W:DualRow(parent, y,
        { type="toggle", text="Unspent Talents Alert",
          tooltip="Shows on-screen text while you have unspent talent points. It stays up until you spend them or open your talents, and returns after a level-up. Use the cog to set the text, size and color; use Unlock Mode to reposition the alerts.",
          getValue=function()
              return EllesmereUIDB and EllesmereUIDB.talentAlertEnabled or false
          end,
          setValue=function(v)
              if not EllesmereUIDB then EllesmereUIDB = {} end
              EllesmereUIDB.talentAlertEnabled = v
              if EllesmereUI._applyTalentAlert then EllesmereUI._applyTalentAlert() end
              EllesmereUI:RefreshPage()
          end },
        { type="toggle", text="Announce Group Deaths",
          tooltip="Shows a large on-screen alert (e.g. \"Player DIED!\") whenever a party or raid member dies, so you immediately notice deaths during dungeons and raids. Use Unlock Mode to reposition the alert.",
          getValue=function()
              return EllesmereUIDB and EllesmereUIDB.announceGroupDeaths or false
          end,
          setValue=function(v)
              if not EllesmereUIDB then EllesmereUIDB = {} end
              EllesmereUIDB.announceGroupDeaths = v
              if EllesmereUI._applyAnnounceGroupDeaths then EllesmereUI._applyAnnounceGroupDeaths() end
              EllesmereUI:RefreshPage()
          end }
    );  y = y - h

    local row3
    row3, h = W:DualRow(parent, y,
        { type="toggle", text="Craft Ready Alert",
          tooltip="Shows on-screen text when a craft with a cooldown (a transmutation, a cloth of the day) is ready again. A craft is known once its profession window has been opened. Use the cog to set the text, size and color; use Unlock Mode to reposition the alerts.",
          getValue=function()
              return EllesmereUIDB and EllesmereUIDB.craftAlertEnabled or false
          end,
          setValue=function(v)
              if not EllesmereUIDB then EllesmereUIDB = {} end
              EllesmereUIDB.craftAlertEnabled = v
              if EllesmereUI._applyCraftAlert then EllesmereUI._applyCraftAlert() end
              EllesmereUI:RefreshPage()
          end },
        EllesmereUI.IS_FOREVER and { type="toggle", text="World Events Alert",
          tooltip="Shows on-screen text for the last minutes before a world event of the server clock: the Gurubashi Arena Chest and the Stranglethorn Fishing Extravaganza. Use the cog to pick the events and how early; use Unlock Mode to reposition the alerts.",
          getValue=function()
              return EllesmereUIDB and EllesmereUIDB.worldEventAlertEnabled or false
          end,
          setValue=function(v)
              if not EllesmereUIDB then EllesmereUIDB = {} end
              EllesmereUIDB.worldEventAlertEnabled = v
              if EllesmereUI._applyWorldEventAlert then EllesmereUI._applyWorldEventAlert() end
              EllesmereUI:RefreshPage()
          end } or EllesmereUI.BlankRowCfg()
    );  y = y - h

    local rowRare
    if EllesmereUI.IS_FOREVER then
        rowRare, h = W:DualRow(parent, y,
            { type="toggle", text="Rare Mob Alert",
              tooltip="Shows on-screen text with a sound when a living rare comes into view: its nameplate shows, or you target or mouse over it. Each rare shows once, then not again for ten minutes. Use the cog to set the text, size, color and sound; use Unlock Mode to reposition the alerts.",
              getValue=function()
                  return EllesmereUIDB and EllesmereUIDB.rareAlertEnabled or false
              end,
              setValue=function(v)
                  if not EllesmereUIDB then EllesmereUIDB = {} end
                  EllesmereUIDB.rareAlertEnabled = v
                  if EllesmereUI._applyRareAlert then EllesmereUI._applyRareAlert() end
                  EllesmereUI:RefreshPage()
              end },
            EllesmereUI.BlankRowCfg()
        );  y = y - h
    end

    -- Inline cog (text, size, colors, mode) on the Combat Alert toggle.
    if not EllesmereUI._prebuilding then
        local leftRgn = row1._leftRegion
        local function caOff()
            return not (EllesmereUIDB and EllesmereUIDB.combatAlertEnabled)
        end
        local function enterClassOn()
            return EllesmereUIDB and EllesmereUIDB.combatAlertEnterUseClassColor
        end
        local function leaveClassOn()
            return EllesmereUIDB and EllesmereUIDB.combatAlertLeaveUseClassColor
        end

        local caModeValues = {
            both  = "Enter & Leave",
            enter = "Enter Only",
            leave = "Leave Only",
        }
        local caModeOrder = { "both", "enter", "leave" }

        EllesmereUI.BuildInlineCog(leftRgn, {
            title = "Combat Alert Settings",
            minWidth = 300,
            rows = {
                { type="dropdown", label="Show On",
                  values=caModeValues, order=caModeOrder,
                  get=function() return (EllesmereUIDB and EllesmereUIDB.combatAlertMode) or "both" end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertMode = v
                  end },
                { type="slider", label="Text Size",
                  min=14, max=64, step=1,
                  get=function()
                    return (EllesmereUIDB and EllesmereUIDB.combatAlertTextSize) or 22
                  end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertTextSize = v
                    if EllesmereUI._applyCombatAlertFrame then EllesmereUI._applyCombatAlertFrame() end
                    if EllesmereUI._combatAlertPreview then EllesmereUI._combatAlertPreview("enter") end
                  end },
                { type="input", label="Enter Text", inputWidth=90,
                  get=function()
                    return (EllesmereUIDB and EllesmereUIDB.combatAlertEnterText) or "+Combat"
                  end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertEnterText = v
                    if EllesmereUI._combatAlertPreview then EllesmereUI._combatAlertPreview("enter") end
                  end },
                { type="colorpicker", label="Enter Color",
                  disabled=enterClassOn,
                  disabledTooltip="Disable Class Color to pick a custom color.", rawTooltip=true,
                  get=function()
                    local c = (EllesmereUIDB and EllesmereUIDB.combatAlertEnterColor) or { r=1.00, g=1.00, b=1.00 }
                    return c.r, c.g, c.b
                  end,
                  set=function(r, g, b)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertEnterColor = { r=r, g=g, b=b }
                    if EllesmereUI._combatAlertPreview then EllesmereUI._combatAlertPreview("enter") end
                  end },
                { type="toggle", label="Enter Class Color",
                  get=function() return enterClassOn() end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertEnterUseClassColor = v
                    if EllesmereUI._combatAlertPreview then EllesmereUI._combatAlertPreview("enter") end
                  end },
                { type="input", label="Leave Text", inputWidth=90,
                  get=function()
                    return (EllesmereUIDB and EllesmereUIDB.combatAlertLeaveText) or "-Combat"
                  end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertLeaveText = v
                    if EllesmereUI._combatAlertPreview then EllesmereUI._combatAlertPreview("leave") end
                  end },
                { type="colorpicker", label="Leave Color",
                  disabled=leaveClassOn,
                  disabledTooltip="Disable Class Color to pick a custom color.", rawTooltip=true,
                  get=function()
                    local c = (EllesmereUIDB and EllesmereUIDB.combatAlertLeaveColor) or { r=1.00, g=1.00, b=1.00 }
                    return c.r, c.g, c.b
                  end,
                  set=function(r, g, b)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertLeaveColor = { r=r, g=g, b=b }
                    if EllesmereUI._combatAlertPreview then EllesmereUI._combatAlertPreview("leave") end
                  end },
                { type="toggle", label="Leave Class Color",
                  get=function() return leaveClassOn() end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.combatAlertLeaveUseClassColor = v
                    if EllesmereUI._combatAlertPreview then EllesmereUI._combatAlertPreview("leave") end
                  end },
            },
            footer = { unlockKey = "EUI_CombatAlert" },
            gap = 9, disabled = caOff, disabledTooltip = "Combat Alert",
        })
    end


    if not EllesmereUI._prebuilding then
        EllesmereUI.BuildInlineCog(row1._rightRegion, {
            title = "Potion Ready Alert Settings",
            minWidth = 300,
            rows = AlertCogRows("potionAlert", "_potionAlertFrame", "_potionAlertPreview"),
            footer = { unlockKey = "EUI_CombatAlert" },
            gap = 9,
            disabled = function() return not (EllesmereUIDB and EllesmereUIDB.potionAlertEnabled) end,
            disabledTooltip = "Potion Ready Alert",
        })
        EllesmereUI.BuildInlineCog(row2._leftRegion, {
            title = "Unspent Talents Alert Settings",
            minWidth = 300,
            rows = AlertCogRows("talentAlert", "_talentAlertFrame", "_talentAlertPreview"),
            footer = { unlockKey = "EUI_CombatAlert" },
            gap = 9,
            disabled = function() return not (EllesmereUIDB and EllesmereUIDB.talentAlertEnabled) end,
            disabledTooltip = "Unspent Talents Alert",
        })

        EllesmereUI.BuildInlineCog(row3._leftRegion, {
            title = "Craft Ready Alert Settings",
            minWidth = 300,
            rows = AlertCogRows("craftAlert", "_craftAlertFrame", "_craftAlertPreview"),
            footer = { unlockKey = "EUI_CombatAlert" },
            gap = 9,
            disabled = function() return not (EllesmereUIDB and EllesmereUIDB.craftAlertEnabled) end,
            disabledTooltip = "Craft Ready Alert",
        })
        if EllesmereUI.IS_FOREVER then
            local WD = (EllesmereUI.Alerts and EllesmereUI.Alerts.WORLD_EVENT_DEFAULTS) or {}
            local function wget(k)
                local v = EllesmereUIDB and EllesmereUIDB[k]
                if v == nil then return WD[k] end
                return v
            end
            local function wset(k, v)
                if not EllesmereUIDB then EllesmereUIDB = {} end
                EllesmereUIDB[k] = v
                if EllesmereUI._applyWorldEventAlert then EllesmereUI._applyWorldEventAlert() end
            end
            local rows = {
                { type="toggle", label="Gurubashi Arena Chest",
                  get=function() return wget("worldEventArena") end, set=function(v) wset("worldEventArena", v) end },
                { type="toggle", label="Only in Stranglethorn Vale",
                  get=function() return wget("worldEventArenaZoneOnly") end, set=function(v) wset("worldEventArenaZoneOnly", v) end },
                { type="slider", label="Arena: Minutes Before", min=1, max=30, step=1,
                  get=function() return wget("worldEventArenaLead") end, set=function(v) wset("worldEventArenaLead", v) end },
                { type="toggle", label="Stranglethorn Fishing Extravaganza",
                  get=function() return wget("worldEventFishing") end, set=function(v) wset("worldEventFishing", v) end },
                { type="slider", label="Fishing: Minutes Before", min=5, max=120, step=5,
                  get=function() return wget("worldEventFishingLead") end, set=function(v) wset("worldEventFishingLead", v) end },
            }
            for i, row in ipairs(AlertCogRows("worldEventAlert", "_worldEventAlertFrame", "_worldEventAlertPreview")) do
                if i > 1 then rows[#rows + 1] = row end   -- (size and colors: the text is the event's own)
            end
            EllesmereUI.BuildInlineCog(row3._rightRegion, {
                title = "World Events Alert Settings",
                minWidth = 300,
                rows = rows,
                footer = { unlockKey = "EUI_CombatAlert" },
                gap = 9,
                disabled = function() return not (EllesmereUIDB and EllesmereUIDB.worldEventAlertEnabled) end,
                disabledTooltip = "World Events Alert",
            })
        end
        if rowRare then
            local rows = AlertCogRows("rareAlert", "_rareAlertFrame", "_rareAlertPreview")
            rows[#rows + 1] = { type="toggle", label="Play Sound",
                get=function() return not (EllesmereUIDB and EllesmereUIDB.rareAlertSound == false) end,
                set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.rareAlertSound = v
                end }
            EllesmereUI.BuildInlineCog(rowRare._leftRegion, {
                title = "Rare Mob Alert Settings",
                minWidth = 300,
                rows = rows,
                footer = { unlockKey = "EUI_CombatAlert" },
                gap = 9,
                disabled = function() return not (EllesmereUIDB and EllesmereUIDB.rareAlertEnabled) end,
                disabledTooltip = "Rare Mob Alert",
            })
        end

        -- Inline cog (Text Size, Sound) on the Announce Group Deaths toggle
        local function deathOff()
            return not (EllesmereUIDB and EllesmereUIDB.announceGroupDeaths)
        end

        -- Sound dropdown: the group death sounds with a click-to-preview
        -- speaker icon on each row.
        local gdSoundValues, gdSoundOrder = EllesmereUI.BuildSoundDropdownValues()

        EllesmereUI.BuildInlineCog(row2._rightRegion, {
            title = "Group Death Alert Settings",
            rows = {
                { type="slider", label="Text Size",
                  min=14, max=64, step=1,
                  get=function()
                    return (EllesmereUIDB and EllesmereUIDB.groupDeathTextSize) or 34
                  end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.groupDeathTextSize = v
                    if EllesmereUI._applyGroupDeathAlert then EllesmereUI._applyGroupDeathAlert() end
                    if EllesmereUI._groupDeathShowVisual then EllesmereUI._groupDeathShowVisual() end
                  end },
                { type="dropdown", label="Sound",
                  values=gdSoundValues, order=gdSoundOrder,
                  get=function()
                    return (EllesmereUIDB and EllesmereUIDB.groupDeathSoundKey) or "none"
                  end,
                  set=function(v)
                    if not EllesmereUIDB then EllesmereUIDB = {} end
                    EllesmereUIDB.groupDeathSoundKey = v
                    if v ~= "none" and EllesmereUI._groupDeathPlaySound then
                        EllesmereUI._groupDeathPlaySound()
                    end
                  end },
            },
            gap = 9, disabled = deathOff, disabledTooltip = "Announce Group Deaths",
        })
    end

    _, h = W:Spacer(parent, y, 20); y = y - h

    return math.abs(y - yOffset)
end
