if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  ResourceBars_Options\MirrorTimerPage_Options.lua
--  Resource Bars options: Mirror Timers page (breath, fatigue, feign death).
--  Definitions only; the shared helpers come from ns._ERB_OptEnv (filled by
--  EUI_ResourceBars_Options.lua). Same widget set as the Swing Timer page.
-------------------------------------------------------------------------------
local ns = EllesmereUI._ModuleNS["EllesmereUIResourceBars"]
if not ns then return end  -- module disabled: no options page

function ns.ERB_BuildMirrorTimerPage(pageName, parent, yOffset)
    local env = ns._ERB_OptEnv
    local DB = env.DB
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    parent._showRowDivider = true

    EllesmereUI.AppendSharedMediaTextures(
        _G._ERB_BarTextureNames or {},
        _G._ERB_BarTextureOrder or {},
        nil,
        _G._ERB_BarTextures
    )
    local texValues, texOrder = {}, {}
    do
        local texNames = _G._ERB_BarTextureNames or {}
        local texOrder2 = _G._ERB_BarTextureOrder or {}
        local texLookup = _G._ERB_BarTextures or {}
        for _, key in ipairs(texOrder2) do
            if key ~= "---" then texValues[key] = texNames[key] or key end
            texOrder[#texOrder + 1] = key
        end
        texValues._menuOpts = { itemHeight = 28, background = function(key) return texLookup[key] end }
    end

    local MT_TIP = "Mirror Timers"
    local function C() local p = DB(); return p and p.mirrorTimer end
    local mtOff = function() local c = C(); return c and not c.enabled end

    local function RefreshMT()
        if _G._ERB_Apply then _G._ERB_Apply() end
        if EllesmereUI.NotifyElementResized then
            EllesmereUI.NotifyElementResized("ERB_MirrorTimer")
        end
    end

    local function Set(key)
        return function(v) local c = C(); if not c then return end; c[key] = v; RefreshMT() end
    end

    _, h = W:SectionHeader(parent, "LAYOUT", y);  y = y - h

    -- Row: Enable Mirror Timers (+ position cog) | Frame Strata
    local enableRow
    enableRow, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enable Mirror Timers",
          tooltip = "Your own bars for breath, fatigue and feign death, one per running timer.",
          getValue = function() local c = C(); return c and c.enabled end,
          setValue = function(v)
              local c = C(); if not c then return end
              c.enabled = v; RefreshMT(); EllesmereUI:RefreshPage()
          end },
        { type = "dropdown", text = "Frame Strata",
          tooltip = "Controls the order that overlapping elements display in. Set higher to show above other elements.",
          disabled = mtOff, disabledTooltip = MT_TIP,
          values = EllesmereUI.FRAME_STRATA_LABELS, order = EllesmereUI.FRAME_STRATA_ORDER_BASE,
          getValue = function() local c = C(); return c and c.frameStrata or "MEDIUM" end,
          setValue = Set("frameStrata") }
    );  y = y - h
    if not EllesmereUI._prebuilding then
        local function PosGet(axis, default)
            return function()
                local c = C(); if not c then return 0 end
                if c.unlockPos and c.unlockPos.point then return c.unlockPos[axis] or 0 end
                local v = c[axis == "x" and "anchorX" or "anchorY"]
                if v == nil then return default end
                return v
            end
        end
        local function PosSet(axis)
            return function(v)
                local c = C(); if not c then return end
                if c.unlockPos and c.unlockPos.point then c.unlockPos[axis] = v
                else c[axis == "x" and "anchorX" or "anchorY"] = v end
                RefreshMT()
            end
        end
        EllesmereUI.BuildInlineCog(enableRow._leftRegion, { icon = EllesmereUI.DIRECTIONS_ICON,
            disabled = mtOff, disabledTooltip = MT_TIP,
            title = "Mirror Timers Position",
            rows = {
                { type = "slider", label = "X Offset", min = -600, max = 600, step = 1,
                  get = PosGet("x", 0), set = PosSet("x") },
                { type = "slider", label = "Y Offset", min = -600, max = 600, step = 1,
                  get = PosGet("y", 300), set = PosSet("y") },
            },
            footer = { unlockKey = "ERB_MirrorTimer" },
        })
    end

    -- Row: Row Height | Width. Height is per row; the mover reports the whole stack.
    local shDis, shTip, shRaw = EllesmereUI.MatchGuard("ERB_MirrorTimer", "Height", mtOff, MT_TIP)
    local swDis, swTip, swRaw = EllesmereUI.MatchGuard("ERB_MirrorTimer", "Width", mtOff, MT_TIP)
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Row Height", min = 4, max = 60, step = 1,
          tooltip = "Height of each timer bar.",
          disabled = shDis, disabledTooltip = shTip, rawTooltip = shRaw,
          getValue = function() local c = C(); return c and c.height or 16 end,
          setValue = Set("height") },
        { type = "slider", text = "Width", min = 50, max = 800, step = 1,
          disabled = swDis, disabledTooltip = swTip, rawTooltip = swRaw,
          getValue = function() local c = C(); return c and c.width or 220 end,
          setValue = Set("width") }
    );  y = y - h

    -- Row: Row Spacing | Text Size
    _, h = W:DualRow(parent, y,
        { type = "slider", pixel = true, text = "Row Spacing", min = 0, max = 20, step = 1,
          tooltip = "Gap between the timer bars when more than one runs.",
          disabled = mtOff, disabledTooltip = MT_TIP,
          getValue = function() local c = C(); return c and c.rowSpacing or 2 end,
          setValue = Set("rowSpacing") },
        { type = "slider", text = "Text Size", min = 6, max = 24, step = 1,
          disabled = mtOff, disabledTooltip = MT_TIP,
          getValue = function() local c = C(); return c and c.textSize or 11 end,
          setValue = Set("textSize") }
    );  y = y - h

    _, h = W:SectionHeader(parent, "DISPLAY", y);  y = y - h

    local function Swatch(prefix, tip)
        return { tooltip = tip, hasAlpha = true,
            getValue = function()
                local c = C(); if not c then return 1, 1, 1, 1 end
                return c[prefix .. "R"], c[prefix .. "G"], c[prefix .. "B"], c[prefix .. "A"]
            end,
            setValue = function(r, g, b, a)
                local c = C(); if not c then return end
                c[prefix .. "R"], c[prefix .. "G"], c[prefix .. "B"], c[prefix .. "A"] = r, g, b, a
                RefreshMT()
            end }
    end

    -- Row: Color (breath / fatigue / feign death) | Background
    _, h = W:DualRow(parent, y,
        { type = "multiSwatch", text = "Color",
          disabled = mtOff, disabledTooltip = MT_TIP,
          swatches = {
              Swatch("breath",  "Breath Color"),
              Swatch("fatigue", "Fatigue Color"),
              Swatch("feign",   "Feign Death Color"),
          } },
        { type = "slider", text = "Background", min = 0, max = 100, step = 1,
          disabled = mtOff, disabledTooltip = MT_TIP,
          getValue = function() local c = C(); return math.floor(((c and c.bgA or 0.7) * 100) + 0.5) end,
          setValue = function(v) local c = C(); if not c then return end; c.bgA = v / 100; RefreshMT() end }
    );  y = y - h

    -- Row: Bar Texture | Border Size
    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Bar Texture",
          disabled = mtOff, disabledTooltip = MT_TIP,
          values = texValues, order = texOrder,
          getValue = function() local c = C(); return c and c.texture or "none" end,
          setValue = Set("texture") },
        { type = "slider", pixel = true, text = "Border Size", min = 0, max = 4, step = 1,
          disabled = mtOff, disabledTooltip = MT_TIP,
          getValue = function() local c = C(); return c and c.borderSize or 1 end,
          setValue = Set("borderSize") }
    );  y = y - h

    -- Row: Show Label | Show Time
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Show Label",
          tooltip = "The game's own name for the timer, on the left of the bar.",
          disabled = mtOff, disabledTooltip = MT_TIP,
          getValue = function() local c = C(); return c and c.showLabel ~= false end,
          setValue = Set("showLabel") },
        { type = "toggle", text = "Show Time",
          tooltip = "The seconds left, on the right of the bar.",
          disabled = mtOff, disabledTooltip = MT_TIP,
          getValue = function() local c = C(); return c and c.showTime ~= false end,
          setValue = Set("showTime") }
    );  y = y - h

    -- Row: Hide Blizzard Bars | Border Color
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Hide Blizzard Bars",
          tooltip = "Makes Blizzard's own breath and fatigue bars invisible while these are on.",
          disabled = mtOff, disabledTooltip = MT_TIP,
          getValue = function() local c = C(); return c and c.hideBlizzard ~= false end,
          setValue = Set("hideBlizzard") },
        { type = "multiSwatch", text = "Border Color",
          disabled = mtOff, disabledTooltip = MT_TIP,
          swatches = { Swatch("border", "Border Color") } }
    );  y = y - h

    return math.abs(y)
end
