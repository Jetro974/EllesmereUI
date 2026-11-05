if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-- EUI_ResourceBars_MirrorTimer.lua
-- Mirror Timers: the breath, fatigue and feign death bars, on EUI's own frames.
--
-- Blizzard calls them mirror timers (Blizzard_MirrorTimer): up to three at once,
-- each started by MIRROR_TIMER_START(timer, value, maxValue, scale, paused,
-- label), paused by MIRROR_TIMER_PAUSE(timer, paused) and ended by
-- MIRROR_TIMER_STOP(timer). Blizzard's own bars read GetMirrorTimerProgress on
-- every frame for as long as one runs, which is also what follows a breath bar
-- refilling once the player surfaces. This file reads the same call at 20 Hz,
-- only while an unpaused timer is up; nothing at all runs the rest of the time.
--
-- One frame, one ROW per running timer, stacked top to bottom in a fixed order
-- (breath, fatigue, feign death, death). Each row: bg, PP border, a StatusBar
-- in a clip frame and two FontStrings (the game's own label on the left, the
-- seconds left on the right).
--
-- Blizzard's bars are only made invisible (alpha 0) while this one is on and
-- Hide Blizzard Bars is set; they keep running untouched, and get their alpha
-- back the moment either is turned off. Off by default: nothing is built,
-- registered or hidden until it is turned on.

local _, ns = ...
local EllesmereUI = _G.EllesmereUI

if not (GetMirrorTimerProgress and GetMirrorTimerInfo) then return end

local UNLOCK_KEY = "ERB_MirrorTimer"
local MAX_TIMERS = 3   -- the client runs at most three at once

-- Display order, top to bottom. `key` is the colour-key prefix in the store
-- (breathR/G/B/A, ...). DEATH shares the feign death colour, as Blizzard's does.
local TIMERS = {
    BREATH     = { order = 1, key = "breath" },
    EXHAUSTION = { order = 2, key = "fatigue" },
    FEIGNDEATH = { order = 3, key = "feign" },
    DEATH      = { order = 4, key = "feign" },
}

-- Shell + ticker host at FILE SCOPE (attribution rule, see _erbEventFrame in the
-- main file): the OnEvent and OnLoop work bills ResourceBars. Children stay lazy.
local shell = CreateFrame("Frame", "ERB_MirrorTimerFrame", UIParent)
shell:Hide()
local tickFrame = CreateFrame("Frame")

-- built, rows[i], active[timer] = { row, max, paused, label }, sample (unlock
-- mode preview on), unlockHooked, blizzHidden, events
local S = { rows = {}, active = {} }

-------------------------------------------------------------------------------
--  Settings access
-------------------------------------------------------------------------------

local function P()
    local ERB = ns.ERB
    local db = ERB and ERB.db
    local p = db and db.profile
    return p and p.mirrorTimer or nil
end

-- A restricted answer is no answer: the row keeps what it last showed.
local function Plain(v)
    return not (issecretvalue and issecretvalue(v))
end

local function ActiveCount()
    if S.sample then return 2 end
    local n = 0
    for _ in pairs(S.active) do n = n + 1 end
    return n
end

-- Frame size: width x (rows * height + gaps), one row at least for the mover.
local function Size(cfg)
    cfg = cfg or P()
    if not cfg then return 220, 16 end
    local n = math.max(ActiveCount(), 1)
    local h = cfg.height or 16
    local sp = cfg.rowSpacing or 2
    return cfg.width or 220, n * h + (n - 1) * sp
end

local function TimerColor(cfg, timer)
    local def = TIMERS[timer] or TIMERS.EXHAUSTION
    local k = def.key
    return cfg[k .. "R"] or 1, cfg[k .. "G"] or 1, cfg[k .. "B"] or 1, cfg[k .. "A"] or 1
end

-------------------------------------------------------------------------------
--  Rows
-------------------------------------------------------------------------------

local function BuildRow()
    local row = CreateFrame("Frame", nil, shell)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    row._bg = bg

    local bdr = CreateFrame("Frame", nil, row)
    bdr:SetAllPoints(row)
    bdr:SetFrameLevel(row:GetFrameLevel() + 5)
    row._border = bdr
    local PP = EllesmereUI.PP
    if PP then PP.CreateBorder(bdr, 0, 0, 0, 1, 1) end

    local clip = CreateFrame("Frame", nil, row)
    clip:SetClipsChildren(true)
    row._clip = clip

    local bar = CreateFrame("StatusBar", nil, clip)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    row._bar = bar

    local textFrame = CreateFrame("Frame", nil, row)
    textFrame:SetAllPoints(row)
    textFrame:SetFrameLevel(bar:GetFrameLevel() + 3)
    -- Font before any SetText (a FontString with no font errors on SetText).
    local label = textFrame:CreateFontString(nil, "OVERLAY")
    ns.SetRBFont(label, ns.GetRBFont(), 11)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText("")
    row._label = label
    local time = textFrame:CreateFontString(nil, "OVERLAY")
    ns.SetRBFont(time, ns.GetRBFont(), 11)
    time:SetJustifyH("RIGHT")
    time:SetWordWrap(false)
    time:SetText("")
    row._time = time

    row:Hide()
    return row
end

local function ApplyRowLook(row, cfg)
    local PP = EllesmereUI.PP
    local bs = cfg.borderSize or 1
    local bdr = row._border
    if not bdr:GetLeft() then bdr:SetAllPoints(row) end
    EllesmereUI.ApplyBorderStyle(bdr, bs,
        cfg.borderR or 0, cfg.borderG or 0, cfg.borderB or 0, cfg.borderA or 1,
        "solid", nil, nil, nil, nil, "resourcebars", bs)

    local clip, bar = row._clip, row._bar
    local inset = (bs > 0 and PP and PP.mult) or 0
    clip:ClearAllPoints()
    clip:SetPoint("TOPLEFT", row, "TOPLEFT", inset, -inset)
    clip:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -inset, inset)
    clip:SetFrameLevel(row:GetFrameLevel() + 1)
    bar:ClearAllPoints()
    bar:SetAllPoints(clip)

    local texPath = EllesmereUI.ResolveTexturePath(_G._ERB_BarTextures, cfg.texture, "Interface\\Buttons\\WHITE8x8")
    bar:SetStatusBarTexture(texPath)
    bar:SetOrientation("HORIZONTAL")
    row._bg:SetTexture(nil)
    row._bg:SetColorTexture(cfg.bgR or 0, cfg.bgG or 0, cfg.bgB or 0, cfg.bgA or 0.7)
    if row._timer then bar:SetStatusBarColor(TimerColor(cfg, row._timer)) end

    local size = cfg.textSize or 11
    ns.SetRBFont(row._label, ns.GetRBFont(), size)
    ns.SetRBFont(row._time, ns.GetRBFont(), size)
    row._label:ClearAllPoints()
    row._label:SetPoint("LEFT", row, "LEFT", 4, 0)
    row._time:ClearAllPoints()
    row._time:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    if cfg.showLabel ~= false then row._label:Show() else row._label:Hide() end
    if cfg.showTime ~= false then row._time:Show() else row._time:Hide() end
end

-- Paints one row's fill and seconds from a value in milliseconds.
local function PaintValue(row, ms)
    if not (Plain(ms) and type(ms) == "number") then return end
    row._bar:SetValue(ms / 1000)
    row._time:SetText(string.format("%d", math.max(0, math.floor(ms / 1000 + 0.5))))
end

-------------------------------------------------------------------------------
--  Layout and position
-------------------------------------------------------------------------------

-- The running timers in display order.
local function Ordered()
    local list = {}
    for timer in pairs(S.active) do list[#list + 1] = timer end
    table.sort(list, function(a, b)
        return (TIMERS[a] and TIMERS[a].order or 9) < (TIMERS[b] and TIMERS[b].order or 9)
    end)
    return list
end

local function Layout(cfg)
    local h = cfg.height or 16
    local sp = cfg.rowSpacing or 2
    local w = cfg.width or 220
    for i = 1, MAX_TIMERS do S.rows[i]:Hide() end
    local list
    if S.sample then
        list = { "BREATH", "EXHAUSTION" }
    else
        list = Ordered()
    end
    for i = 1, math.min(#list, MAX_TIMERS) do
        local timer = list[i]
        local row = S.rows[i]
        row._timer = timer
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", shell, "TOPLEFT", 0, -(i - 1) * (h + sp))
        row:SetSize(w, h)
        row:Show()
        ApplyRowLook(row, cfg)
        local a = S.active[timer]
        if S.sample then
            row._bar:SetMinMaxValues(0, 60)
            row._label:SetText(timer == "BREATH" and (BREATH_LABEL or "Breath") or (EXHAUSTION_LABEL or "Fatigue"))
            PaintValue(row, timer == "BREATH" and 60000 or 36000)
        elseif a then
            a.row = row
            row._bar:SetMinMaxValues(0, math.max(a.max / 1000, 0.001))
            row._label:SetText(a.label or "")
            PaintValue(row, a.value)
        end
    end
    local n = math.max(math.min(#list, MAX_TIMERS), 1)
    local newH = n * h + (n - 1) * sp
    local changed = S.lastH ~= newH
    S.lastH = newH
    shell:SetSize(w, newH)
    if changed and EllesmereUI.NotifyElementResized then
        EllesmereUI.NotifyElementResized(UNLOCK_KEY)
    end
end

-- Position: the unlock anchor chain first, then a saved unlock position, then
-- the CENTER offsets (the GCD bar's three-way split).
local function ApplyPosition(cfg)
    local w, h = Size(cfg)
    shell:SetSize(w, h)
    if EllesmereUI._TryOverrideAnchor and EllesmereUI._TryOverrideAnchor(UNLOCK_KEY, shell) then
        return
    end
    if EllesmereUI._unlockActive then return end
    local pos = cfg.unlockPos
    if pos and pos.point then
        local anchored = EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored(UNLOCK_KEY)
        if anchored and shell:GetLeft() then return end
        local rp = pos.relPoint or pos.point
        local sx, sy = ns.SnapXY(pos.x or 0, pos.y or 0, shell, pos)
        shell:ClearAllPoints()
        shell:SetPoint(pos.point, UIParent, rp, sx, sy)
    else
        shell:ClearAllPoints()
        shell:SetPoint("CENTER", UIParent, "CENTER", cfg.anchorX or 0, cfg.anchorY or 300)
    end
end

-------------------------------------------------------------------------------
--  Following the timers
-------------------------------------------------------------------------------

local function UpdateVisibility()
    if not S.built then return end
    EllesmereUI.SetElementVisibility(shell, S.sample or next(S.active) ~= nil)
end

local function AnyRunning()
    for _, a in pairs(S.active) do
        if not a.paused then return true end
    end
    return false
end

local ticker = EllesmereUI.Tick.NewAnimTicker(tickFrame, function()
    local running = false
    for timer, a in pairs(S.active) do
        if not a.paused then
            running = true
            local ms = GetMirrorTimerProgress(timer)
            if Plain(ms) and type(ms) == "number" then
                a.value = ms
                if a.row and not S.sample then PaintValue(a.row, ms) end
            end
        end
    end
    return running
end, 0.05)

local function Restart()
    if AnyRunning() then ticker.Start() else ticker.Stop() end
end

local function StartTimer(cfg, timer, value, maxValue, paused, label)
    if not (Plain(timer) and Plain(value) and Plain(maxValue) and Plain(paused) and Plain(label)) then return end
    if type(timer) ~= "string" or timer == "UNKNOWN" or type(maxValue) ~= "number" then return end
    S.active[timer] = {
        value = value, max = maxValue, label = label,
        paused = (paused == true or (type(paused) == "number" and paused > 0)),
    }
    Layout(cfg)
    UpdateVisibility()
    Restart()
end

-- The timers already running when the bar comes up (a /reload under water).
local function Resync(cfg)
    for timer in pairs(S.active) do S.active[timer] = nil end
    for i = 1, MAX_TIMERS do
        local timer, value, maxValue, _, paused, label = GetMirrorTimerInfo(i)
        if Plain(timer) and timer and timer ~= "UNKNOWN" then
            StartTimer(cfg, timer, value, maxValue, paused, label)
        end
    end
    Layout(cfg)
    UpdateVisibility()
    Restart()
end

shell:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5, a6)
    local cfg = P()
    if not (cfg and cfg.enabled and S.built) then return end
    if event == "MIRROR_TIMER_START" then
        -- timer, value, maxValue, scale, paused, label
        StartTimer(cfg, a1, a2, a3, a5, a6)
    elseif event == "MIRROR_TIMER_PAUSE" then
        local a = Plain(a1) and S.active[a1]
        if a and Plain(a2) then
            a.paused = (a2 == true or (type(a2) == "number" and a2 > 0))
            Restart()
        end
    elseif event == "MIRROR_TIMER_STOP" then
        if Plain(a1) and S.active[a1] then
            S.active[a1] = nil
            Layout(cfg)
            UpdateVisibility()
            Restart()
        end
    else -- PLAYER_ENTERING_WORLD
        Resync(cfg)
    end
end)

local function RegisterEvents()
    if S.events then return end
    S.events = true
    shell:RegisterEvent("MIRROR_TIMER_START")
    shell:RegisterEvent("MIRROR_TIMER_PAUSE")
    shell:RegisterEvent("MIRROR_TIMER_STOP")
    shell:RegisterEvent("PLAYER_ENTERING_WORLD")
end

-- Blizzard's bars: alpha only, never a reparent or an unregister, so turning
-- the option off (or the whole bar) hands them straight back.
local function ApplyBlizzard(cfg)
    local blizz = _G.MirrorTimerContainer
    if not blizz then return end
    local hide = cfg and cfg.enabled and cfg.hideBlizzard ~= false
    if hide then
        blizz:SetAlpha(0)
        S.blizzHidden = true
    elseif S.blizzHidden then
        blizz:SetAlpha(1)
        S.blizzHidden = nil
    end
end

-------------------------------------------------------------------------------
--  Build / apply
-------------------------------------------------------------------------------

local function EnsureBuilt()
    if S.built then return end
    S.built = true
    shell:SetFrameLevel(15)
    for i = 1, MAX_TIMERS do S.rows[i] = BuildRow() end
end

function ns.MT_Apply()
    local cfg = P()
    ApplyBlizzard(cfg)
    if not cfg or not cfg.enabled then
        if S.built then
            if S.events then shell:UnregisterAllEvents(); S.events = nil end
            ticker.Stop()
            for timer in pairs(S.active) do S.active[timer] = nil end
            EllesmereUI.SetElementVisibility(shell, false)
        end
        return
    end
    local first = not S.built
    EnsureBuilt()
    shell:SetFrameStrata(cfg.frameStrata or "MEDIUM")
    shell:Show()
    if not S.events then
        RegisterEvents()
        first = true
    end
    if first then
        Resync(cfg)
    else
        Layout(cfg)
    end
    ApplyPosition(cfg)
    UpdateVisibility()
end

-------------------------------------------------------------------------------
--  Unlock element
-------------------------------------------------------------------------------

function ns.MT_MakeUnlockElement(MK, Rebuild)
    if not MK then return nil end
    local PP = EllesmereUI.PP

    if not S.unlockHooked and EllesmereUI.RegisterUnlockModeListener then
        S.unlockHooked = true
        EllesmereUI:RegisterUnlockModeListener(UNLOCK_KEY, function(active)
            -- Two sample rows while the movers are up, so there is something to
            -- drag out of the water; MT_Apply restores the real state on exit.
            S.sample = active and true or nil
            if ns.MT_Apply then ns.MT_Apply() end
        end)
    end

    local function save(_, point, relPoint, x, y)
        if not point then return end
        local cfg = P(); if not cfg then return end
        cfg.unlockPos = { point = point, relPoint = relPoint or point, x = x, y = y }
        if not EllesmereUI._unlockActive and S.built then
            shell:ClearAllPoints()
            shell:SetPoint(point, UIParent, relPoint or point, x, y)
        end
    end
    local function load()
        local cfg = P()
        local pos = cfg and cfg.unlockPos
        if not pos then return nil end
        return { point = pos.point, relPoint = pos.relPoint or pos.point, x = pos.x, y = pos.y }
    end
    local function clear()
        local cfg = P(); if not cfg then return end
        cfg.unlockPos = nil
        cfg.anchorX = 0; cfg.anchorY = 300
    end
    local function apply()
        local cfg = P()
        local pos = cfg and cfg.unlockPos
        if not (pos and S.built) then return end
        local sx, sy = ns.SnapXY(pos.x, pos.y, shell, pos)
        shell:ClearAllPoints()
        shell:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, sx, sy)
    end

    return MK({
        key = UNLOCK_KEY, label = "Mirror Timers", group = "Resource Bars", order = 509,
        getFrame = function() return S.built and shell or nil end,
        isHidden = function() local cfg = P(); return not (cfg and cfg.enabled) end,
        getSize  = function() return Size(P()) end,
        setWidth = function(_, w)
            local cfg = P(); if not cfg then return end
            cfg.width = PP.Snap(math.max(w, 10))
            Rebuild()
        end,
        -- The mover resizes the whole stack; the per-row height is what is stored.
        setHeight = function(_, h)
            local cfg = P(); if not cfg then return end
            local n = math.max(ActiveCount(), 1)
            local sp = cfg.rowSpacing or 2
            cfg.height = PP.Snap(math.max((h - (n - 1) * sp) / n, 4))
            Rebuild()
        end,
        savePos = save, loadPos = load, clearPos = clear, applyPos = apply,
    })
end
