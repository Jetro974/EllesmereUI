if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_QoL_AutoScreenshot_Options.lua
--  AUTO SCREENSHOTS section of the Quality of Life page. Runtime:
--  EllesmereUIQoL_AutoScreenshot.lua (defaults must match it).
-------------------------------------------------------------------------------

if not EllesmereUI._ModuleNS["EllesmereUIQoL"] then return end  -- module disabled: no options page

local function Get(k, def)
    local v = EllesmereUIDB and EllesmereUIDB[k]
    if v == nil then return def end
    return v
end

local function Set(k, v)
    if not EllesmereUIDB then EllesmereUIDB = {} end
    EllesmereUIDB[k] = v
    if EllesmereUI._applyAutoScreenshot then EllesmereUI._applyAutoScreenshot() end
end

local function Toggle(text, key, def, tooltip)
    return { type="toggle", text=text, tooltip=tooltip,
      getValue=function() return Get(key, def) == true end,
      setValue=function(v) Set(key, v) end }
end

local function Cog(rgn, title, offKey, offDef, rows)
    if EllesmereUI._prebuilding then return end
    EllesmereUI.BuildInlineCog(rgn, {
        title = title, rows = rows, gap = 9,
        disabled = function() return Get(offKey, offDef) ~= true end,
        disabledTooltip = title,
    })
end

local DEATH_WHERE = { all = "Everywhere", instance = "Instances Only", world = "Open World Only" }
local DEATH_ORDER = { "all", "instance", "world" }

_G._EUI_BuildAutoScreenshotSection = function(parent, yOffset, W)
    local y = yOffset
    local _, h, row

    _, h = W:SectionHeader(parent, "AUTO SCREENSHOTS", y); y = y - h

    local on = Get("autoShot", false) == true
    local master = { type="toggle", text="Auto Screenshots",
      tooltip="Takes a screenshot on the events picked below. /euishot takes one with the interface hidden right away.",
      getValue=function() return Get("autoShot", false) == true end,
      -- The trigger rows below are hidden while off; the flip forces the rebuild.
      setValue=EllesmereUI.DependentSetValue(
          function() return Get("autoShot", false) == true end,
          function(v)
              Set("autoShot", v or nil)
              EllesmereUI:RefreshPage()
          end) }

    if not on then
        _, h = W:DualRow(parent, y, master, EllesmereUI.BlankRowCfg()); y = y - h
        return math.abs(y - yOffset)
    end

    _, h = W:DualRow(parent, y, master,
        { type="slider", text="Delay (sec)", min=0, max=5, step=0.5, isPercent=false,
          tooltip="Waits this long after the event before the screenshot, so on-screen effects can play.",
          getValue=function() return Get("autoShotDelay", 1) end,
          setValue=function(v) Set("autoShotDelay", v) end }
    ); y = y - h

    row, h = W:DualRow(parent, y,
        Toggle("Level Up", "autoShotLevelUp", true),
        Toggle("Achievement Earned", "autoShotAchievement", true,
            "Your own achievements only: guild achievements and those already earned on your account are skipped.")
    ); y = y - h
    Cog(row._leftRegion, "Level Up", "autoShotLevelUp", true, {
        { type="toggle", label="Max Level Only",
          get=function() return Get("autoShotLevelMaxOnly", false) == true end,
          set=function(v) Set("autoShotLevelMaxOnly", v or nil) end },
    })

    row, h = W:DualRow(parent, y,
        Toggle("Boss Kill", "autoShotBoss", true,
            "Dungeon, raid and other encounter bosses defeated."),
        Toggle("Death", "autoShotDeath", false)
    ); y = y - h
    Cog(row._leftRegion, "Boss Kill", "autoShotBoss", true, {
        { type="toggle", label="First Kill Only (per difficulty)",
          tooltip="Only the first kill of each boss on each difficulty, remembered per character.",
          get=function() return Get("autoShotBossFirstOnly", true) == true end,
          set=function(v) Set("autoShotBossFirstOnly", v) end },
        { type="slider", label="Wait For Combat End (sec)", min=0, max=10, step=1,
          tooltip="When still in combat, waits up to this long for combat to end so the interface can be hidden.",
          get=function() return Get("autoShotBossWait", 3) end,
          set=function(v) Set("autoShotBossWait", v) end },
    })
    Cog(row._rightRegion, "Death", "autoShotDeath", false, {
        { type="dropdown", label="Where", values=DEATH_WHERE, order=DEATH_ORDER,
          get=function() return Get("autoShotDeathWhere", "all") end,
          set=function(v) Set("autoShotDeathWhere", v) end },
    })

    -- No Mythic+ or rated PvP on WoW Forever.
    if not EllesmereUI.IS_FOREVER then
        row, h = W:DualRow(parent, y,
            Toggle("Mythic+ Completed", "autoShotMythicPlus", false),
            Toggle("PvP Victory", "autoShotPvP", false, "Arena and battleground matches won.")
        ); y = y - h
        Cog(row._leftRegion, "Mythic+ Completed", "autoShotMythicPlus", false, {
            { type="toggle", label="Timed Runs Only",
              get=function() return Get("autoShotMythicPlusTimed", true) == true end,
              set=function(v) Set("autoShotMythicPlusTimed", v) end },
        })
    end

    row, h = W:DualRow(parent, y,
        Toggle("Hide Interface", "autoShotHideUI", true,
            "Hides the interface for the screenshot and shows it again right after. In combat the screenshot keeps the interface."),
        Toggle("Chat Message", "autoShotChat", true, "Prints a line in chat for each screenshot taken.")
    ); y = y - h
    Cog(row._leftRegion, "Hide Interface", "autoShotHideUI", true, {
        { type="toggle", label="Caption",
          tooltip="Adds a card to the screenshot: the event, your character, the date and zone, and the details of that event.",
          get=function() return Get("autoShotCaption", true) == true end,
          set=function(v) Set("autoShotCaption", v) end },
        { type="toggle", label="Group Roster",
          tooltip="Lists the other players of your group, with class colors and roles, on boss kills, Mythic+ and first raid entries, and on any screenshot taken in a group inside a dungeon or raid.",
          get=function() return Get("autoShotRoster", true) == true end,
          set=function(v) Set("autoShotRoster", v) end },
    })

    return math.abs(y - yOffset)
end
