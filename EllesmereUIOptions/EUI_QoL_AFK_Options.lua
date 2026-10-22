if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_QoL_AFK_Options.lua
--  Options page for the AFK screen (Quality of Life > AFK tab). Settings live
--  in EllesmereUIDB.afkScreen; defaults come from EllesmereUI.AFK_DEFAULTS
--  (owned by the runtime in EllesmereUIQoL_AFK.lua).
-------------------------------------------------------------------------------
if not EllesmereUI._ModuleNS["EllesmereUIQoL"] then return end  -- module disabled: no options page

local IS_FOREVER = EllesmereUI.IS_FOREVER

local function Cfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.afkScreen = EllesmereUIDB.afkScreen or {}
    return EllesmereUIDB.afkScreen
end

local function Get(key)
    local v = Cfg()[key]
    if v == nil then
        local d = EllesmereUI.AFK_DEFAULTS
        return d and d[key]
    end
    return v
end

local function Apply()
    if _G._EUI_ApplyAFKScreen then _G._EUI_ApplyAFKScreen() end
end

local function Off() return Get("enabled") ~= true end

local function Toggle(key, text, tooltip, disabled)
    return { type = "toggle", text = text, tooltip = tooltip,
             disabled = disabled or Off, disabledTooltip = "AFK Screen",
             getValue = function() return Get(key) == true end,
             setValue = function(v) Cfg()[key] = v; Apply() end }
end

local BLANK = { type = "label", text = "" }

local WHERE_VALUES = { always = "Everywhere", resting = "Rested Areas Only" }
local WHERE_ORDER = { "always", "resting" }
local SCENE_VALUES = { cinema = "Cinema", portrait = "Portrait", seasons = "Seasons", forever = "Forever" }
local SCENE_ORDER = { "cinema", "portrait", "seasons", "forever" }
local SEASON_VALUES = { auto = "Automatic", spring = "Spring", summer = "Summer", fall = "Fall", winter = "Winter" }
local SEASON_ORDER = { "auto", "spring", "summer", "fall", "winter" }
local CAMERA_VALUES = { orbit = "Orbit", pullback = "Pull Back", sway = "Sway", fixed = "Fixed" }
local CAMERA_ORDER = { "orbit", "pullback", "sway", "fixed" }

local function BuildAFKPage(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    parent._showRowDivider = true
    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  GENERAL
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "AFK SCREEN", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enable AFK Screen",
          tooltip = "When you go AFK the interface fades out, the camera slowly turns around your character and a screen with your character, your week and the messages you receive takes over. Moving or pressing a key brings everything back.",
          getValue = function() return Get("enabled") == true end,
          setValue = function(v) Cfg().enabled = v; Apply(); EllesmereUI:RefreshPage() end },
        { type = "dropdown", text = "Show In", values = WHERE_VALUES, order = WHERE_ORDER,
          disabled = Off, disabledTooltip = "AFK Screen",
          tooltip = "Everywhere, or only in rested areas (cities and inns). It never opens in combat, in an instance, in a vehicle, on a flight path, in a pet battle, during a cinematic, while casting or with a merchant, bank, mailbox, auction house or trade window open.",
          getValue = function() return Get("where") end,
          setValue = function(v) Cfg().where = v; Apply() end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Delay (sec)", min = 0, max = 300, step = 5,
          disabled = Off, disabledTooltip = "AFK Screen",
          tooltip = "How long you stay AFK before the screen opens.",
          getValue = function() return Get("delay") or 0 end,
          setValue = function(v) Cfg().delay = v end },
        { type = "slider", text = "Scale", min = 60, max = 150, step = 5,
          disabled = Off, disabledTooltip = "AFK Screen",
          tooltip = "Size of the text and cards on the AFK screen.",
          getValue = function() return math.floor((Get("scale") or 1) * 100 + 0.5) end,
          setValue = function(v) Cfg().scale = v / 100; Apply() end }
    ); y = y - h

    -- Preview: opens the real screen with sample content; any key or the
    -- Back button closes it (the options window comes back with the UI).
    _, h = W:Spacer(parent, y, 8); y = y - h
    _, h = W:WideButton(parent, "Preview AFK Screen", y, function()
        if _G._EUI_AFKScreenPreview then _G._EUI_AFKScreenPreview(true) end
    end); y = y - h
    _, h = W:Spacer(parent, y, 12); y = y - h

    ---------------------------------------------------------------------------
    --  SCENE
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "SCENE", y); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Scene", values = SCENE_VALUES, order = SCENE_ORDER,
          disabled = Off, disabledTooltip = "AFK Screen",
          tooltip = "Cinema: black bars at the top and bottom. Portrait: a large character over a dark side. Seasons: drifting petals, sun motes, leaves or snow. Forever: gold accents and the game font.",
          getValue = function() return Get("scene") end,
          setValue = function(v) Cfg().scene = v; Apply() end },
        { type = "dropdown", text = "Season", values = SEASON_VALUES, order = SEASON_ORDER,
          disabled = function() return Off() or Get("scene") ~= "seasons" end,
          disabledTooltip = "Requires the Seasons scene",
          tooltip = "Automatic follows the current month.",
          getValue = function() return Get("season") end,
          setValue = function(v) Cfg().season = v; Apply() end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Camera", values = CAMERA_VALUES, order = CAMERA_ORDER,
          disabled = Off, disabledTooltip = "AFK Screen",
          tooltip = "Orbit: a slow turn around your character. Pull Back: the camera backs away, then turns slowly. Sway: turns one way, then the other. Fixed: the camera does not move.",
          getValue = function() return Get("camera") end,
          setValue = function(v) Cfg().camera = v end },
        { type = "slider", text = "Camera Speed", min = 1, max = 10, step = 1,
          disabled = function() return Off() or Get("camera") == "fixed" end,
          disabledTooltip = "Requires a moving camera",
          getValue = function() return Get("cameraSpeed") or 3 end,
          setValue = function(v) Cfg().cameraSpeed = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("restoreCamera", "Restore Camera",
            "Puts the camera back where it was when you return. Uses saved camera view 5."),
        Toggle("showModel", "Show Character",
            "Shows your character on the side of the screen, playing a random emote every now and then.")
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("modelReactions", "Character Reactions",
            "Your character waves when you get a whisper, applauds when a friend logs in and falls asleep after ten minutes.",
            function() return Off() or not Get("showModel") end),
        Toggle("showPet", "Show Companion",
            "Shows your summoned battle pet next to your character.",
            function() return Off() or not Get("showModel") end)
    ); y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  CARDS
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "CARDS", y); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("showIdentity", "Identity",
            "Name, title, specialization, item level, Mythic+ score, guild and zone."),
        IS_FOREVER and Toggle("showTimers", "Timers", "Daily and weekly reset countdowns and today's holidays.")
            or Toggle("showWeek", "This Week", "Great Vault progress, your keystone and your crests.")
    ); y = y - h

    if not IS_FOREVER then
        _, h = W:DualRow(parent, y,
            Toggle("showKeys", "Keystones", "Your keystone and the keystones of your party and guild."),
            Toggle("showTimers", "Timers", "Daily and weekly reset countdowns and today's holidays.")
        ); y = y - h
    end

    _, h = W:DualRow(parent, y,
        Toggle("showGains", "While Away", "Rested XP and gold gained since the screen opened, and a new Great Vault option."),
        Toggle("showSocial", "Social", "Friends and guild members online, and who logged in while you were away.")
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("showTips", "EllesmereUI Tips", "Shows a tip about an EllesmereUI feature at the bottom of the screen."),
        BLANK
    ); y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  MESSAGES & ALERTS
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "MESSAGES & ALERTS", y); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("showMessages", "Message Feed",
            "Lists the whispers and Battle.net whispers you receive while away. Click one to leave the screen and reply."),
        Toggle("msgGuild", "Include Guild Chat",
            "Adds guild chat messages to the feed.",
            function() return Off() or not Get("showMessages") end)
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("alertQueue", "Queue Ready",
            "A dungeon, raid, battleground or pet battle queue pops: the screen closes with a countdown."),
        Toggle("alertReadyCheck", "Ready Check", "A ready check starts: the screen closes.")
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("alertSummon", "Summon", "Someone summons you: the screen closes."),
        Toggle("alertInvite", "Group Invites", "A group invite or a Group Finder invite arrives: the screen closes.")
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("alertAuction", "Auction Sold", "An auction sells: a line in the feed, the screen stays."),
        Toggle("alertMail", "New Mail", "New mail arrives: a line in the feed, the screen stays.")
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("alertSound", "Alert Sound", "Plays a sound for every alert."),
        Toggle("flashIcon", "Flash Taskbar Icon", "Flashes the game icon in your taskbar for every alert.")
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("logoutWarning", "Logout Warning",
            "Shows an estimate of the time left before the game logs you out for inactivity, and closes the screen when the logout countdown starts."),
        Toggle("returnSummary", "Return Summary",
            "When you come back, a card sums up your time away: messages, friends who logged in, rested XP, gold and a new Great Vault option. Click a message to reply.")
    ); y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  EXTRAS
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "EXTRAS", y); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("ecoMode", "Eco Mode",
            "Caps the frame rate while the AFK screen is up to save power and heat. Your frame rate setting comes back when you return."),
        { type = "slider", text = "Eco FPS", min = 10, max = 60, step = 5,
          disabled = function() return Off() or not Get("ecoMode") end,
          disabledTooltip = "Requires Eco Mode",
          getValue = function() return Get("ecoFPS") or 30 end,
          setValue = function(v) Cfg().ecoFPS = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("streamer", "Streamer Mode",
            "Hides your name, guild, zone, gold, the names of other players and the text of messages on the AFK screen."),
        BLANK
    ); y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h

    return math.abs(y)
end

_G._EUI_BuildAFKPage = BuildAFKPage
