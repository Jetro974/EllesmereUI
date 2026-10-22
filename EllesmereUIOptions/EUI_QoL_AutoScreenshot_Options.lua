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
local ZONE_MODES = { capitals = "Capitals Only", zones = "Zones", all = "Every Discovery" }
local ZONE_ORDER = { "capitals", "zones", "all" }
local QUALITIES = { ["2"] = "Uncommon", ["3"] = "Rare", ["4"] = "Epic", ["5"] = "Legendary" }
local QUALITY_ORDER = { "2", "3", "4", "5" }
local FORMATS = { game = "Game Setting", jpeg = "JPEG", png = "PNG", tga = "TGA" }
local FORMAT_ORDER = { "game", "jpeg", "png", "tga" }
local SOUNDS = { none = "Off", camera = "Camera Shutter", ready = "Ready Check", quest = "Quest Complete",
                 ping = "Map Ping", epic = "Epic Loot" }
local SOUND_ORDER = { "none", "camera", "ready", "quest", "ping", "epic" }

-- Collection triggers, each its own key, offered where the client has the event.
local COLLECTIONS = {
    { key = "autoShotMount",  label = "Mounts",        event = "NEW_MOUNT_ADDED" },
    { key = "autoShotPet",    label = "Battle Pets",   event = "NEW_PET_ADDED" },
    { key = "autoShotToy",    label = "Toys",          event = "NEW_TOY_ADDED" },
    { key = "autoShotRecipe", label = "Recipes",       event = "NEW_RECIPE_LEARNED" },
    { key = "autoShotDecor",  label = "Housing Decor", event = "NEW_HOUSING_ITEM_ACQUIRED" },
}

local function CogRow(title, key, def, rows)
    return function(rgn) Cog(rgn, title, key, def, rows) end
end

-- A checkbox dropdown in place of a placeholder dropdown (keys default to
-- def), grayed while offKey is off when given.
local function CheckboxDropdown(items, def, offKey)
    return function(rgn)
        if rgn._control then rgn._control:Hide() end
        local dd, refresh = EllesmereUI.BuildVisOptsCBDropdown(rgn, 210, rgn:GetFrameLevel() + 2, items,
            function(k) return Get(k, def) == true end,
            function(k, v) Set(k, v) end)
        EllesmereUI.PanelPP.Point(dd, "RIGHT", rgn, "RIGHT", -20, 0)
        rgn._control = dd
        rgn._lastInline = nil
        EllesmereUI.RegisterWidgetRefresh(refresh)
        if offKey then
            local function Gray()
                local off = Get(offKey, false) ~= true
                dd:SetAlpha(off and 0.3 or 1)
                dd:EnableMouse(not off)
                if rgn._label then rgn._label:SetAlpha(off and 0.3 or 1) end
            end
            Gray()
            EllesmereUI.RegisterWidgetRefresh(Gray)
        end
    end
end

local function Placeholder(text, tooltip)
    return { type="dropdown", text=text, tooltip=tooltip,
             values={ __placeholder = "..." }, order={ "__placeholder" },
             getValue=function() return "__placeholder" end, setValue=function() end }
end

-- The trigger and option slots, in order, each { cfg, post(region) }. They
-- are paired two to a row; only the last row may keep an empty slot.
local function Slots()
    local IS_FOREVER = EllesmereUI.IS_FOREVER
    local list = {}
    local function add(cfg, post) list[#list + 1] = { cfg, post } end

    add(Toggle("Level Up", "autoShotLevelUp", true,
            "On level up. The card adds the time played at the previous level and in total once a /played report is known for this character."),
        CogRow("Level Up", "autoShotLevelUp", true, {
            { type="toggle", label="Max Level Only",
              get=function() return Get("autoShotLevelMaxOnly", false) == true end,
              set=function(v) Set("autoShotLevelMaxOnly", v or nil) end },
        }))
    add(Toggle("Achievement Earned", "autoShotAchievement", true,
            "Achievements you earn. Use the cog to also include guild achievements and those already earned on another character."),
        CogRow("Achievement Earned", "autoShotAchievement", true, {
            { type="toggle", label="Guild Achievements",
              get=function() return Get("autoShotAchGuild", false) == true end,
              set=function(v) Set("autoShotAchGuild", v or nil) end },
            { type="toggle", label="Already Earned on Another Character",
              get=function() return Get("autoShotAchAccount", false) == true end,
              set=function(v) Set("autoShotAchAccount", v or nil) end },
        }))
    add(Toggle("Boss Kill", "autoShotBoss", true, "Dungeon, raid and other encounter bosses defeated."),
        CogRow("Boss Kill", "autoShotBoss", true, {
            { type="toggle", label="First Kill Only (per difficulty)",
              tooltip="Only the first kill of each boss on each difficulty, remembered per character.",
              get=function() return Get("autoShotBossFirstOnly", true) == true end,
              set=function(v) Set("autoShotBossFirstOnly", v) end },
            { type="slider", label="Wait For Combat End (sec)", min=0, max=10, step=1,
              tooltip="When still in combat, waits up to this long for combat to end so the interface can be hidden.",
              get=function() return Get("autoShotBossWait", 3) end,
              set=function(v) Set("autoShotBossWait", v) end },
        }))
    add(Toggle("Boss Wipe", "autoShotWipe", false, "An encounter that ends without the kill."),
        CogRow("Boss Wipe", "autoShotWipe", false, {
            { type="toggle", label="Raids Only",
              get=function() return Get("autoShotWipeRaidsOnly", true) == true end,
              set=function(v) Set("autoShotWipeRaidsOnly", v) end },
        }))
    add(Toggle("Death", "autoShotDeath", false),
        CogRow("Death", "autoShotDeath", false, {
            { type="dropdown", label="Where", values=DEATH_WHERE, order=DEATH_ORDER,
              get=function() return Get("autoShotDeathWhere", "all") end,
              set=function(v) Set("autoShotDeathWhere", v) end },
        }))
    add(Toggle("First Raid Entry", "autoShotRaidEntry", true,
            "The first time this character enters each raid. Raids visited before you turn this on are not known, so the first visit after you turn this on also counts."))
    -- No Mythic+, rated PvP, world bosses or Traveler's Log on WoW Forever.
    if not IS_FOREVER then
        add(Toggle("Mythic+ Completed", "autoShotMythicPlus", false),
            CogRow("Mythic+ Completed", "autoShotMythicPlus", false, {
                { type="toggle", label="Timed Runs Only",
                  get=function() return Get("autoShotMythicPlusTimed", true) == true end,
                  set=function(v) Set("autoShotMythicPlusTimed", v) end },
            }))
        add(Toggle("PvP Victory", "autoShotPvP", false, "Arena and battleground matches won."))
        add(Toggle("World Boss Kill", "autoShotWorldBoss", false, "A boss killed outside an instance."))
        add(Toggle("Traveler's Log", "autoShotTravel", false, "A Traveler's Log activity completed."))
    end
    add(Toggle("Zone Discovery", "autoShotZone", false,
            "When you discover a new area. Use the cog to pick capitals only, each zone once, or every discovery. Each place counts once per character."),
        CogRow("Zone Discovery", "autoShotZone", false, {
            { type="dropdown", label="Discoveries", values=ZONE_MODES, order=ZONE_ORDER,
              get=function() return Get("autoShotZoneMode", "capitals") end,
              set=function(v) Set("autoShotZoneMode", v) end },
        }))
    add(Toggle("Reputation", "autoShotRep", false,
            "A new reputation rank, friendship rank or renown level. Ranks are learned as they change: the first change of each faction after you turn this on only records it."),
        CogRow("Reputation", "autoShotRep", false, {
            { type="toggle", label="Exalted / Max Rank Only",
              get=function() return Get("autoShotRepMaxOnly", false) == true end,
              set=function(v) Set("autoShotRepMaxOnly", v or nil) end },
        }))
    local lootRows = {
        { type="dropdown", label="Minimum Quality", values=QUALITIES, order=QUALITY_ORDER,
          get=function() return tostring(Get("autoShotLootQuality", "4")) end,
          set=function(v) Set("autoShotLootQuality", v) end },
    }
    if not IS_FOREVER then
        lootRows[2] = { type="toggle", label="Money and Currency",
          tooltip="Also money and currency loot toasts.",
          get=function() return Get("autoShotLootMoney", false) == true end,
          set=function(v) Set("autoShotLootMoney", v or nil) end }
    end
    add(Toggle("Special Loot", "autoShotLoot", false, "An item you loot at or above the picked quality."),
        CogRow("Special Loot", "autoShotLoot", false, lootRows))

    local items = {}
    local valid = C_EventUtils and C_EventUtils.IsEventValid
    for _, c in ipairs(COLLECTIONS) do
        if valid and valid(c.event) then items[#items + 1] = { key = c.key, label = c.label } end
    end
    if #items > 0 then
        -- A placeholder dropdown the post step swaps for a checkbox dropdown.
        add(Placeholder("Collections", "Something new in your collections: pick which kinds."),
            CheckboxDropdown(items, false))
    end
    add(Toggle("Duel", "autoShotDuel", false,
            "A duel you fought. No API tells the winner, so every duel counts; a declined request does not."))
    add(Toggle("Login", "autoShotLogin", false, "Once per session, after the first loading screen."))
    add(Toggle("Interval Screenshots", "autoShotInterval", false,
            "Every few minutes, out of combat only. Skipped while dead, AFK or in a cinematic."),
        CogRow("Interval Screenshots", "autoShotInterval", false, {
            { type="slider", label="Every (min)", min=5, max=120, step=5,
              get=function() return Get("autoShotIntervalMin", 30) end,
              set=function(v) Set("autoShotIntervalMin", v) end },
        }))
    add(Toggle("Hide Interface", "autoShotHideUI", true,
            "Hides the interface for the screenshot and shows it again right after. In combat the screenshot keeps the interface."),
        CogRow("Hide Interface", "autoShotHideUI", true, {
            { type="toggle", label="Caption",
              tooltip="Adds a card to the screenshot: the event, your character, the date and zone, and the details of that event.",
              get=function() return Get("autoShotCaption", true) == true end,
              set=function(v) Set("autoShotCaption", v) end },
            { type="toggle", label="Group Roster",
              tooltip="Lists the other players of your group, with class colors and roles, on boss kills, Mythic+ and first raid entries, and on any screenshot taken in a group inside a dungeon or raid.",
              get=function() return Get("autoShotRoster", true) == true end,
              set=function(v) Set("autoShotRoster", v) end },
        }))
    add(Toggle("Chat Message", "autoShotChat", true, "Prints a line in chat for each screenshot taken."))
    add({ type="dropdown", text="Sound", values=SOUNDS, order=SOUND_ORDER,
          tooltip="A sound once a screenshot is saved.",
          getValue=function() return Get("autoShotSound", "none") end,
          setValue=function(v) Set("autoShotSound", v ~= "none" and v or nil) end })
    add({ type="dropdown", text="Image Format", values=FORMATS, order=FORMAT_ORDER,
          tooltip="The file format of these screenshots (and /euishot). The game setting is switched only for the shot, out of combat, and put back right after.",
          getValue=function() return Get("autoShotFormat", "game") end,
          setValue=function(v) Set("autoShotFormat", v ~= "game" and v or nil) end },
        function(rgn)
            if EllesmereUI._prebuilding then return end
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Image Format", gap = 9,
                rows = {
                    { type="slider", label="JPEG Quality", min=1, max=10, step=1,
                      get=function() return Get("autoShotQuality", 9) end,
                      set=function(v) Set("autoShotQuality", v) end },
                },
                disabled = function() return Get("autoShotFormat", "game") ~= "jpeg" end,
                disabledTooltip = "This option requires Image Format to be set to JPEG",
            })
        end)
    return list
end

local PROF_KINDS = {
    { key = "autoShotProfCraft",  label = "Crafting" },
    { key = "autoShotProfGather", label = "Gathering" },
    { key = "autoShotProfSecond", label = "Secondary" },
}

-- FISHING & PROFESSIONS slots.
local function FishSlots()
    local list = {}
    local function add(cfg, post) list[#list + 1] = { cfg, post } end
    add(Toggle("Profession Milestones", "autoShotProf", false,
            "A profession reaching the top of its rank or expansion tier, or a new rank learned. Each milestone counts once per character."),
        CogRow("Profession Milestones", "autoShotProf", false, {
            { type="toggle", label="Max Rank Only",
              get=function() return Get("autoShotProfMaxOnly", false) == true end,
              set=function(v) Set("autoShotProfMaxOnly", v or nil) end },
        }))
    add(Placeholder("Professions", "Which professions count for Profession Milestones."),
        CheckboxDropdown(PROF_KINDS, true, "autoShotProf"))
    return list
end

-- Lays slots out two to a row.
local function PairRows(parent, y, W, slots)
    for i = 1, #slots, 2 do
        local left, right = slots[i], slots[i + 1]
        local row, h = W:DualRow(parent, y, left[1], right and right[1] or EllesmereUI.BlankRowCfg())
        y = y - h
        if left[2] then left[2](row._leftRegion) end
        if right and right[2] then right[2](row._rightRegion) end
    end
    return y
end

_G._EUI_BuildAutoScreenshotSection = function(parent, yOffset, W)
    local y = yOffset
    local _, h

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

    y = PairRows(parent, y, W, Slots())

    _, h = W:Spacer(parent, y, 20); y = y - h
    _, h = W:SectionHeader(parent, "FISHING & PROFESSIONS", y); y = y - h
    y = PairRows(parent, y, W, FishSlots())

    return math.abs(y - yOffset)
end
