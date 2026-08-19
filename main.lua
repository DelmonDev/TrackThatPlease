local api = require("api")
local BuffSettingsWindow = require("TrackThatPlease/buff_settings_wnd")
local helpers = require("TrackThatPlease/util/helpers")
local BuffsLogger = require("TrackThatPlease/util/buff_logger")
local Store = require("TrackThatPlease/util/settings_store")

-- ========================= UI-scale space model ==============================
-- This build is the shipped 3.0 with exactly three grafts - the UI-scale
-- sizing fix, the outline fix, and the private settings store - and nothing
-- else: every runtime system (positioning, calibration, anchoring, gates)
-- is 3.0 byte-for-byte.
--
-- The client scales the whole UI tree by one factor (UIParent:GetUIScale());
-- every anchor offset and extent is in UI units, but GetScreenWidth/
-- GetScreenHeight return DEVICE pixels. The client's own code divides
-- whenever a screen dimension meets an anchor or extent
-- (globalui/loading/loading_view.lua:96, x2ui/baselib/ui_management.lua:129,
-- both via CalcDontApplyUIScale); the projection functions already return
-- anchor-space values. Mixing the two spaces is what shifted the
-- nametag-mode bar HARD at any UI scale other than 100. Read live on every
-- use, never cached at load: the option's scale is not in effect yet while
-- addons load, and the player can change it mid-session. The old per-scale
-- nudge table this replaces was a band-aid over the same space mix.
local function GetUIScaleSafe()
    local scale = api.Interface:GetUIScale()
    if type(scale) ~= "number" or scale <= 0 then return 1 end
    return scale
end
-- Screen size in the space the PROJECTION functions speak. Divided by the
-- scale, exactly as shipped 3.1 - this is the field-verified UI-scale graft
-- and it is only ever compared against GetUnitScreenPosition output.
--
-- Do NOT "correct" this from the fixed-bar measurement. Those are two
-- different spaces and conflating them cost a regression: raising the
-- nametag X pin from (1920/1.1)/2 = 873 to 1920/2 = 960 pushed the
-- above-head bar off to the RIGHT. 3.1's value is right for this path.
-- The measured device space (see the drag handlers) governs the SAVED
-- fixed-bar offsets and nothing else here.
local function ScreenUIWidth()
    return api.Interface:GetScreenWidth() / GetUIScaleSafe()
end
local function ScreenUIHeight()
    return api.Interface:GetScreenHeight() / GetUIScaleSafe()
end

-- Keeps a saved fixed-bar position reachable.
--
-- PINNED-BAR POSITIONING = DAWNSDROP'S, exactly (Addon/dawnsdrop - a
-- shipping addon whose window holds position across reloads and scales):
--   * one positioning function: bare TOPLEFT AddAnchor, raw values
--     (SetPinnedPosition below = its SetWndPosition);
--   * drag with anchors ON, save GetOffset raw+floored at DragStop, then
--     IMMEDIATELY re-apply the saved values - screen state == saved state
--     from the moment the mouse releases;
--   * the session's FIRST anchor happens on the first UPDATE tick, never
--     during load. Dawnsdrop's source says why, verbatim: "for some reason
--     if UI Scaling is in effect we cannot set the Anchor in Load()". That
--     engine quirk is the misplaced-until-poked behaviour we chased for a
--     day ("clicking Move bar snaps it back").
--   * NO scale arithmetic anywhere in the position path, in either
--     direction. Px()/UI_SCALING.md govern extents and thicknesses only.
--
-- HARD-LEARNED: never build a coordinate model from reading offsets back
-- after AddAnchor - GetOffset/GetEffectiveOffset flip between pre- and
-- post-layout values with timing (one dump caught eff echoing 508 AND 660.4
-- for the same anchored 508). Three rework rounds came from trusting those
-- echoes. The reads are only trustworthy immediately after
-- StopMovingOrSizing, which is the one moment dawnsdrop reads them.
--
-- The margins keep a grabbable corner of the bar on screen; the clamp is
-- TTP's one addition to the dawnsdrop pattern (dawnsdrop only floors), so a
-- stale save can never strand a bar off screen. Raw device dims: readable
-- at load, no scale term.
local FIXED_BAR_MARGIN_X = 160
local FIXED_BAR_MARGIN_Y = 40
local function ClampToScreen(x, y)
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    local maxX = math.max(0, api.Interface:GetScreenWidth() - FIXED_BAR_MARGIN_X)
    local maxY = math.max(0, api.Interface:GetScreenHeight() - FIXED_BAR_MARGIN_Y)
    if x < 0 then x = 0 elseif x > maxX then x = maxX end
    if y < 0 then y = 0 elseif y > maxY then y = maxY end
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

-- Fix a size in DEVICE pixels (the client's CalcDontApplyUIScale arithmetic,
-- BetterBars' Px rule): the buff bars are a world overlay, so icon size 30
-- means the same 30 screen pixels at 80% and at 160%. Identity at 100%.
local function Px(n)
    return n / GetUIScaleSafe()
end

-- NaN/Inf frame guard, the fourth and final graft. The screen-projection
-- functions can return NaN or Inf for a frame when the unit mounts or
-- dismounts (reported by Draygo, 2026-08-10). NaN passes a plain truthy
-- check, and one poisoned sample corrupts every running average it touches
-- permanently (x + NaN is NaN forever) - the nametag calibration would
-- never recover for the rest of the session. Rejecting the frame instead
-- holds the bar at its last good position until the reading recovers.
local function isFiniteNumber(n)
    return type(n) == "number" and n == n
        and n ~= math.huge and n ~= -math.huge
end
-- =============================================================================

-- Addon Information
local TargetBuffTrackerAddon = {
    name = "TrackThatPlease",
    author = "Dehling",
    version = BuffSettingsWindow.ADDON_VERSION,
    desc = "Tracks buffs/debuffs on target, with UI"
}

--FORK Idea by @mykeew to implement targeting for Target and Self (Player), now properly implemented

-- UI Elements
local playerBuffCanvas
local targetBuffCanvas
-- The static bar: a second player bar that only ever uses the fixed-screen
-- anchoring, so none of the projection/nametag machinery below applies to it
local staticBuffCanvas
local playerBuffIcons = {}
local playerBuffLabels = {}
local targetBuffIcons = {}
local targetBuffLabels = {}
local playerBuffStackLabels = {}
local targetBuffStackLabels = {}
local staticBuffIcons = {}
local staticBuffLabels = {}
local staticBuffStackLabels = {}

-- Variables
local previousPlayerXYZString = "0,0,0"
local previousPlayerXYZSmothed = {x = 0, y = 0, z = 0}
local previousTargetXYZString = "0,0,0"
local previousTargetXYZSmothed = {x = 0, y = 0, z = 0}
local staleHideHandler
local lastPlayerBuffSig = ""
local lastTargetBuffSig = ""
local lastStaticBuffSig = ""
local playerBarUnlocked = false
local staticBarUnlocked = false
-- Pinned-bar settle gate. Anchors laid while the client is still loading
-- resolve wrong under UI scaling, so the pinned bars re-anchor per frame -
-- but ONLY until the world has been LIVE for PIN_SETTLE_MS. Every
-- wall-clock timer failed at this (the loading screen's own UPDATE ticks
-- advance them), so this clock advances only on frames where the player
-- projection returns finite values, i.e. the world is demonstrably
-- rendering. Once it fills, the last anchor was laid on a settled tree and
-- anchoring drops to on-change only: the post-settle steady state is two
-- number compares per bar per frame, no anchor calls, no allocations.
local PIN_SETTLE_MS = 5000
local pinSettleMs = 0
local pinSettled = false
-- Last-applied anchor per pinned bar; numbers, so the per-frame check
-- allocates nothing
local lastStaticAppliedX, lastStaticAppliedY
local lastFixedAppliedX, lastFixedAppliedY
-- Nametag-compensated height follows the head, but only re-samples it when the CAMERA
-- moves - which is what separates the two kinds of vertical movement:
--
--   zooming  changes the camera distance a lot and permanently
--   jumping  changes it slightly and transiently (measured 12.71 -> 13.51, ~6%,
--            then straight back)
--
-- So the bar re-reads the true head position whenever 1/distance has moved more
-- than a step from where it was last sampled, and otherwise holds still. That
-- tracks zoom exactly at every level - no curve to fit, and a trace showed the
-- head travels ~890px across the zoom range in a way no 1/z model matched - while
-- jumps never accumulate enough camera movement to trigger a re-sample.
local NAMETAG_ZOOM_STEP = 0.012

-- Camera-settling window. Measuring movement only against the LAST SAMPLE has a
-- blind spot: one big camera move (a teleport skill yanking the view out, z
-- 20.5 -> 34.4 in a frame) re-samples once, and every following frame then
-- compares against that new distance - reading ~0.0004 while the camera is
-- still swinging back. The bar held a stale height for 200ms and 85px, exactly
-- when the camera was moving fastest.
--
-- So movement is also measured against the PREVIOUS FRAME, and any camera
-- motion opens a window during which every frame re-samples. The bar then
-- tracks the head throughout the camera's travel and settles with it. A jump
-- moves the camera far too little to open the window, so it still freezes.
-- Measured on a teleport capture: worst error 166px -> 25px.
local NAMETAG_CAMERA_FRAME_EPS = 0.0015
local NAMETAG_SETTLE_MS = 400
local nametagSettleMs = 0
local nametagPrevZ

-- De-bobbing. Running bobs the head up and down, and while the camera holds a
-- steady distance the settling window stays shut - so the bar keeps whichever
-- height the LAST latch happened to catch. Latch on a bob peak and the bar sits
-- slightly high until something re-samples, which is why it only sometimes
-- looked off against the offset setting.
--
-- A running average of the head is kept alongside, and adopted at the moment
-- the window closes: while the camera moves the bar still tracks the head
-- exactly (averaging throughout would lag a fast zoom - measured worst error
-- 25px -> 61px), and the height it settles on is a bob average rather than one
-- arbitrary frame. Measured on the teleport capture: worst error 25px -> 21px.
local NAMETAG_HEAD_AVG_SPEED = 15
local nametagHeadAvg
local nametagWasSettling = false

-- Stuck recovery. The gate can latch a bad height: a skill that flings the
-- character makes the camera swing (a re-sample fires mid-flight, capturing a
-- displaced head), then the camera goes still and nothing re-samples again - the
-- bar hangs where the flight was. A jump deviates for well under a second and
-- returns; only a deviation that OUTLASTS that window is treated as a bad latch.
-- The wait sits just above a jump's airtime (~0.8s); recovery itself is an
-- effective snap (~95% in 30ms) - once we are sure it is a bad latch there is
-- no reason to linger. Lowering the wait further risks jumps triggering.
-- Source plausibility. After some abrupt movement skills the game's own
-- reported position (the nameplate anchor) can itself hang far too high and
-- stay there - recovery then faithfully converges the bar onto a wrong value,
-- which is how the bar ended up stuck near the top of the screen. At any
-- normal camera distance the head never legitimately sits in the top fifth of
-- the screen (a measured jump peak reached 30% height; the bogus values sit
-- near the top edge), so such readings are ignored outright: nothing latches
-- them and nothing recovers toward them. Full zoom-in is exempt because
-- extreme heights ARE legitimate there.
local NAMETAG_PLAUSIBLE_MIN_Z = 2.5
local NAMETAG_PLAUSIBLE_TOP = 0.2 -- fraction of screen height

-- 8px, not 25: the coarse threshold only caught gross strandings. A mount
-- lifting the character, or a teleport leaving a small residual offset, both
-- change the character's height while the camera stays put - the settling
-- window never opens, and a deviation too small to trip a coarse trigger sat
-- there permanently, reading as the bar resting slightly above the offset
-- setting. The timing window (below), not the size, is what protects jumps from
-- triggering this, so the size can be tight.
local NAMETAG_STUCK_PX = 8
local NAMETAG_STUCK_AFTER_MS = 900
local NAMETAG_STUCK_RECOVER_SPEED = 100
local nametagStuckMs = 0

-- Slow drift correction. Measured: the bar can latch a height and hold it for
-- seconds while the head settles a few pixels below - a mount lifting the
-- character, or a teleport landing at an odd offset, changes the character's
-- height without moving the camera, so the settling window never opens. The
-- residue is only 3-6px, far below any stuck threshold that stays safe for
-- jumps, and the walking bob keeps dipping back under the threshold and zeroing
-- the timer. So this reads the drift off a second, slower average of the head
-- and eases the latch toward it.
-- The gate is what keeps jumps out: during a jump the fast (200ms) and slow
-- (660ms) averages diverge far past it and correction suspends itself, so the
-- bar still freezes for jumps and abrupt skills. Ungated, a jump leaked 10.5px.
-- 2.5, up from the shipped 1.5 (field-tuned 2026-08-15): this is the slow
-- average the drift correction CHASES, and at ~660ms of lag it had become
-- the bottleneck once the correction itself was sped to 7 - the fast
-- correction spent its first ~0.7s chasing a target still in transit. At
-- 2.5 the target arrives in ~400ms and the whole small-residue reposition
-- lands in about half a second end to end. Watch-item: the jump gate below
-- compares the fast (200ms) and THIS average - going much faster shrinks
-- their mid-jump divergence toward the 12px gate and jumps could start
-- leaking pixels into the drift path.
local NAMETAG_DRIFT_AVG_SPEED = 2.5
local NAMETAG_DRIFT_PX = 2
-- 7, up from the shipped 1.5 (field-tuned 2026-08-15, via 3 and 5): the
-- correction settles a residue in ~0.2s - effectively a soft snap. Safe to
-- raise: the GATE above is what keeps jumps out of this path, not the speed.
local NAMETAG_DRIFT_SPEED = 7
local NAMETAG_DRIFT_GATE_PX = 12
local nametagDriftAvg

local nametagCalibZ
local nametagCalibY

-- Far bound on the anchor distance (see where it is used)
local MAX_ANCHOR_DISTANCE = 300


--ICON BACKGROUNDS IF BUFF OR DEBUFF
--------------------------------------------------------------------------------------------------------------------------------------------
local BUFF = {
    path = TEXTURE_PATH.HUD,
    coords = {
        685,
        130,
        7,
        8
    },
    inset = {
        3,
        3,
        3,
        3
    },
    color = {
        0,
        1,
        0,
        1
    }
}

local DEBUFF = {
    path = TEXTURE_PATH.HUD,
    coords = {
        685,
        130,
        7,
        8
    },
    inset = {
        3,
        3,
        3,
        3
    },
    color = {
        1,
        0,
        0,
        1
    }
}
--------------------------------------------------------------------------------------------------------------------------------------------
local buffBlinkSpeed = 5 -- Speed of the blink effect
local function GetBlinkAlpha(minAlpha, maxAlpha, timer)
    local amplitude = (maxAlpha - minAlpha) / 2
    local mid = (maxAlpha + minAlpha) / 2
    return mid + amplitude * math.sin(timer * buffBlinkSpeed)
end

-- Function to check if a buff is being watched for player or target
local function IsWatchedBuff(buffId, isPlayer)
    buffId = math.floor(tonumber(buffId) or 0)
    if isPlayer then
        return BuffSettingsWindow.IsPlayerBuffWatched(buffId)
    else
        return BuffSettingsWindow.IsTargetBuffWatched(buffId)
    end
end

-- Same normalization for the static bar's own list
local function IsStaticWatchedBuff(buffId)
    buffId = math.floor(tonumber(buffId) or 0)
    return BuffSettingsWindow.IsStaticBuffWatched(buffId)
end

-- Function to create buff icon and label
local function CreateBuffElement(index, canvas)
    local icon = CreateItemIconButton("buffIcon" .. index, canvas)
    icon:Clickable(false)
    icon:SetExtent(Px(BuffSettingsWindow.settings.iconSize), Px(BuffSettingsWindow.settings.iconSize))
    icon:Show(false)

    -- Skinless icon with ONE owned border (BetterBars discipline; dawnsdrop's
    -- icons prove CreateItemIconButton needs no slot skin). The engine skin
    -- is a texture, so its frame scales with the UI and can never be held at
    -- one device pixel - it is gone entirely, and the four edges below are
    -- the single border: laid ON the icon's edge, one device pixel at every
    -- scale, green for buffs / red for debuffs (ApplyBuffSkins colours them,
    -- same palette as the settings list's category edges). Full alpha, so
    -- the corner overlap between edges composites invisibly.
    icon.edges = {
        icon:CreateColorDrawable(1, 1, 1, 0, "overlay"),
        icon:CreateColorDrawable(1, 1, 1, 0, "overlay"),
        icon:CreateColorDrawable(1, 1, 1, 0, "overlay"),
        icon:CreateColorDrawable(1, 1, 1, 0, "overlay"),
    }

    -- Re-run whenever the icon extent changes (PositionBuffs) - the
    -- thickness is live Px(1), and creation runs while the scale reads 1
    function icon:UpdateEdges()
        local t = Px(1)
        local w, h = self:GetWidth(), self:GetHeight()
        local points = {
            { "TOPLEFT", w, t },
            { "BOTTOMLEFT", w, t },
            { "TOPLEFT", t, h },
            { "TOPRIGHT", t, h },
        }
        for i, spec in ipairs(points) do
            local d = self.edges[i]
            d:SetExtent(spec[2], spec[3])
            d:RemoveAllAnchors()
            d:AddAnchor(spec[1], self, spec[1], 0, 0)
        end
    end
    icon:UpdateEdges()

    function icon:SetEdgeColor(r, g, b, a)
        for _, d in ipairs(self.edges) do
            d:SetColor(r, g, b, a)
        end
    end

    ----------------------------------------------------------------

    -- Create time label -------------------------------------
    local timeLabel
    timeLabel = canvas:CreateChildWidget("label", "buffTimeLeftLabel" .. index, 0, true)
    timeLabel:SetText("")
    timeLabel:AddAnchor("CENTER", icon, "CENTER", 0, 0)
    timeLabel.style:SetFontSize(Px(BuffSettingsWindow.settings.fontSize))
    --timeLabel.style:SetFont("ui/font/yoon_firedgothic_b.ttf", BuffSettingsWindow.settings.fontSize)
    timeLabel.style:SetAlign(ALIGN.CENTER)
    timeLabel.style:SetShadow(true)
    timeLabel.style:SetOutline(true)
    timeLabel:Show(false)
    timeLabel.style:SetColor(1, 1, 1, 1)

    local stackLabel = canvas:CreateChildWidget("label", "buffStackLabel" .. index, 0, true)
    local stackFontSize = Px(math.floor(BuffSettingsWindow.settings.fontSize * 0.65 + 0.5))
    stackLabel:SetText("")
    stackLabel:AddAnchor("TOPLEFT", icon, "TOPLEFT", Px(2), Px(6))
    -- ui/font/SD_LeeyagiL.ttf
    -- ui/font/yoon_firedgothic_b.ttf
    --stackLabel.style:SetFont("ui/font/yoon_firedgothic_b.ttf", BuffSettingsWindow.settings.fontSize - 4) -- another font for stacks
    stackLabel.style:SetFontSize(stackFontSize)
    stackLabel.style:SetAlign(ALIGN.LEFT)
    stackLabel.style:SetShadow(true)
    stackLabel.style:SetOutline(true)
    stackLabel.style:SetColor(0.97, 0.91, 0.81, 0.9)
    stackLabel:SetAlpha(0.80) 

    stackLabel:Show(false)

    return icon, timeLabel, stackLabel
end

-- Function to position buffs with whole bar centered
-- iconSizeSetting is per bar since the player/target size split: the caller
-- passes settings.iconSize (player), settings.targetIconSize (target) or
-- settings.staticIconSize (static bar)
local function PositionBuffs(watchedBuffs, canvas, icons, labels, stackLabels, iconSizeSetting, constantFootprint)
    local maxBuffsToDisplay = math.min(#watchedBuffs, BuffSettingsWindow.settings.maxBuffsShown)
    -- Device pixels (Px): the sliders' numbers mean on-screen pixels at every
    -- UI scale. Layout is otherwise exactly 3.0 (CENTER-anchored icons).
    local iconSize = Px(iconSizeSetting)
    local iconSpacing = Px(BuffSettingsWindow.settings.iconSpacing)
    local fontSize = Px(BuffSettingsWindow.settings.fontSize)
    local stackFontSize = Px(BuffSettingsWindow.settings.fontSize - 3)

    -- Icons stay CENTRE-anchored (shipped 3.0/3.1 layout, untouched). The one
    -- change is the canvas FOOTPRINT for bars pinned to a screen point.
    --
    -- Measured, from ttp_posdump.txt: the saved position round-trips exactly
    -- (stored 1331,745 -> eff 1331,745) and the bar STILL moved, because the
    -- canvas resizes with the buff count - 213.636 wide with four icons,
    -- 159.091 with three. A canvas anchored TOPLEFT that narrows by 54.5
    -- slides its centre, and every icon with it, 27px left. That is the
    -- "keeps shifting": a layout effect no saved coordinate could ever fix.
    --
    -- Sizing for maxBuffsShown regardless of how many buffs are up makes the
    -- extent constant, so nothing moves when a buff lands or drops. This is
    -- deliberately the ONLY change: the icons are not re-anchored (doing that
    -- relocated the bars last time) and there is no arithmetic assuming
    -- extents and anchor offsets share a space - a constant cannot be in the
    -- wrong space. The head bar keeps content-sized extents: it re-anchors
    -- every frame about a BOTTOM-centre anchor, where resizes are symmetric.
    local slots = maxBuffsToDisplay
    if constantFootprint then
        slots = math.max(maxBuffsToDisplay, BuffSettingsWindow.settings.maxBuffsShown)
    end
    local newWidth = iconSize * slots + (slots - 1) * iconSpacing
    local newHeight = iconSize

    -- Update the canvas size
    canvas:SetExtent(newWidth, newHeight)

    -- Icons centre on the canvas centre, exactly as before
    local shownWidth = iconSize * maxBuffsToDisplay + (maxBuffsToDisplay - 1) * iconSpacing
    local startX = -shownWidth / 2 + iconSize / 2

    for i = 1, maxBuffsToDisplay do
        local icon = icons[i]
        local offsetX = startX + (i - 1) * (iconSize + iconSpacing)
        local label = labels[i]
        local stackLabel = stackLabels[i]

        label.style:SetFontSize(fontSize)
        stackLabel.style:SetFontSize(stackFontSize) -- Update stack label font size
        -- The stack label's inset is device-fixed too, and its creation-time
        -- anchor was laid at load, when the scale is not yet readable
        stackLabel:RemoveAllAnchors()
        stackLabel:AddAnchor("TOPLEFT", icon, "TOPLEFT", Px(2), Px(6))
        icon:SetExtent(iconSize, iconSize)
        icon:UpdateEdges()
        icon:RemoveAllAnchors()
        icon:AddAnchor("CENTER", canvas, "CENTER", offsetX, 0)
    end
end

-- Dawnsdrop's SetWndPosition, verbatim (dawnsdrop_view.lua:8-11): the ONE
-- way a pinned canvas is ever positioned. Bare TOPLEFT anchor, raw values,
-- no scale arithmetic, dawnsdrop's own 4-arg AddAnchor form. Every pinned
-- anchor call in this file goes through here.
local function SetPinnedPosition(canvas, x, y)
    canvas:RemoveAllAnchors()
    canvas:AddAnchor("TOPLEFT", "UIParent", x, y)
end

-- Make a fixed bar's canvas safe to drag: extent to the real footprint
-- (live Px - the creation-time extent was computed while the scale still
-- read 1), then the pinned anchor from the stored position. Guarantees
-- StartMoving updates a TOPLEFT-to-UIParent anchor, whatever state the bar
-- was in - the canvases are born anchorless, and the player bar coming out
-- of head mode still carries head mode's BOTTOM anchor (saving THAT
-- anchor's offset as a TOPLEFT position was the bottom-right jump at
-- "Done moving"). Dawnsdrop never needs this because its canvas is anchored
-- from creation and never re-anchored by another mode; this is the same
-- always-anchored guarantee, arrived at on unlock.
local function PrepareFixedBarDrag(canvas, storedPos, iconSizeSetting)
    if not canvas then return end
    local s = BuffSettingsWindow.settings
    local iconSize = Px(iconSizeSetting)
    local spacing = Px(s.iconSpacing)
    local slots = math.max(1, s.maxBuffsShown)
    canvas:SetExtent(iconSize * slots + (slots - 1) * spacing, iconSize)
    local pos = storedPos or { 0, 0 }
    local ax, ay = ClampToScreen(pos[1], pos[2])
    SetPinnedPosition(canvas, ax, ay)
end

-- Function to collect all watched buffs and debuffs
local function CollectWatchedBuffsAndDebuffs()
    local playerBuffs = {}
    local targetBuffs = {}
    local staticBuffs = {}

    -- Helper function to collect buffs and debuffs from a unit. staticList
    -- rides the player pass so the engine's buff array is only walked once:
    -- the same buff table can land in both lists (both writers set the same
    -- isBuff value, so sharing the table is safe).
    local function CollectBuffsAndDebuffs(unit, buffList, isPlayer, staticList)
        -- Check buffs
        local buffCount = api.Unit:UnitBuffCount(unit) or 0
        for i = 1, buffCount do
            local buff = api.Unit:UnitBuff(unit, i)
            if buff then
                if IsWatchedBuff(buff.buff_id, isPlayer) then
                    buff.isBuff = true
                    table.insert(buffList, buff)
                end
                if staticList and IsStaticWatchedBuff(buff.buff_id) then
                    buff.isBuff = true
                    table.insert(staticList, buff)
                end
            end
        end

        -- Check debuffs
        local debuffCount = api.Unit:UnitDeBuffCount(unit) or 0
        for i = 1, debuffCount do
            local debuff = api.Unit:UnitDeBuff(unit, i)
            if debuff then
                if IsWatchedBuff(debuff.buff_id, isPlayer) then
                    debuff.isBuff = false
                    table.insert(buffList, debuff)
                end
                if staticList and IsStaticWatchedBuff(debuff.buff_id) then
                    debuff.isBuff = false
                    table.insert(staticList, debuff)
                end
            end
        end
    end

    -- The engine's buff array is not stably ordered: when one expires the rest
    -- shift index, and a new one can arrive anywhere in the list. Appending in API
    -- order therefore hands PositionBuffs a different sequence for the SAME set of
    -- buffs, so it re-anchors every icon and they visibly swap places.
    --
    -- Sorting by id gives each buff a fixed place for as long as it is active.
    -- Buffs are kept ahead of debuffs so the two groups do not interleave.
    local function stableOrder(a, b)
        if a.isBuff ~= b.isBuff then
            return a.isBuff -- buffs first
        end
        return (a.buff_id or 0) < (b.buff_id or 0)
    end

    -- Collect buffs and debuffs from the player. The static list is only
    -- filled while its bar is enabled, so a disabled bar costs nothing here.
    local staticEnabled = BuffSettingsWindow.settings.staticBarEnabled == true
    CollectBuffsAndDebuffs("player", playerBuffs, true,
        staticEnabled and staticBuffs or nil)

    -- Collect buffs and debuffs from the target
    CollectBuffsAndDebuffs("target", targetBuffs, false)

    table.sort(playerBuffs, stableOrder)
    table.sort(targetBuffs, stableOrder)
    table.sort(staticBuffs, stableOrder)

    return playerBuffs, targetBuffs, staticBuffs
end

-- Function to clear all buff icons and labels
local function ClearAllBuffs()
    for i = 1, BuffSettingsWindow.MAX_BUFFS_COUNT do
        if playerBuffIcons[i] then
            playerBuffIcons[i]:Show(false)
        end
        if playerBuffLabels[i] then
            playerBuffLabels[i]:Show(false)
        end
        if playerBuffStackLabels[i] then
            playerBuffStackLabels[i]:Show(false)
        end
        if targetBuffIcons[i] then
            targetBuffIcons[i]:Show(false)
        end
        if targetBuffLabels[i] then
            targetBuffLabels[i]:Show(false)
        end
        if targetBuffStackLabels[i] then
            targetBuffStackLabels[i]:Show(false)
        end
        if staticBuffIcons[i] then
            staticBuffIcons[i]:Show(false)
        end
        if staticBuffLabels[i] then
            staticBuffLabels[i]:Show(false)
        end
        if staticBuffStackLabels[i] then
            staticBuffStackLabels[i]:Show(false)
        end
    end
end

-- Icon texture/edge colour only change when the displayed buff list
-- changes, so they are applied on demand (see BuildBuffSignature) instead
-- of every frame. The icon's single border is the owned Px(1) edge ring
-- (see CreateBuffElement); no slot skin is applied at all.
local function ApplyBuffSkins(buffs, icons, maxBuffsToDisplay)
    for i = 1, maxBuffsToDisplay do
        local buff = buffs[i]
        local icon = icons[i]

        F_SLOT.SetIconBackGround(icon, buff.path)

        -- Same palette as the settings list's category edges
        if buff.isBuff then
            icon:SetEdgeColor(0.15, 0.85, 0.30, 0.95)
        else
            icon:SetEdgeColor(0.90, 0.22, 0.22, 0.95)
        end

        icon:Show(true)
    end
end

-- Signature of what is currently displayed; anchor/skin work reruns only when it changes.
-- The live UI scale is part of it: geometry is in device pixels now, so a
-- mid-session scale change must re-lay-out even though no setting changed.
-- iconSize is passed per bar (player/target sizes split).
local function BuildBuffSignature(buffs, maxBuffsToDisplay, iconSize)
    local s = BuffSettingsWindow.settings
    local parts = { iconSize, s.iconSpacing, s.fontSize, s.maxBuffsShown, GetUIScaleSafe() }
    for i = 1, maxBuffsToDisplay do
        parts[#parts + 1] = buffs[i].buff_id or 0
        parts[#parts + 1] = buffs[i].isBuff and 1 or 0
    end
    return table.concat(parts, ",")
end

local function UpdateBuffIconsAndTimers(buffs, icons, timeLabels, stackLabels, maxBuffsToDisplay, blinkTimer)
    local shoudShowStacks = BuffSettingsWindow.settings.shouldShowStacks

    for i = 1, maxBuffsToDisplay do
        local buff = buffs[i]
        local icon = icons[i]
        local timeLabel = timeLabels[i]
        local stackLabel = stackLabels[i]

        -- Buff indication logic
        if buff.timeLeft and buff.timeLeft > 0 then
            -- Timers ----------------------------------------------------------------
            local timerText = ""
            local warnTime = (buff.isBuff and BuffSettingsWindow.settings.buffWarnTime) 
                or (not buff.isBuff and BuffSettingsWindow.settings.debuffWarnTime)

            if buff.timeLeft > 5940000 then -- More than 99 minutes (99 * 60 * 1000 ms)
                timerText = string.format("%dh", math.floor(buff.timeLeft / 3600000)) -- Convert to hours
            elseif buff.timeLeft > 60000 then -- More than 1 minute but less than 99 minutes
                timerText = string.format("%dm", math.floor(buff.timeLeft / 60000))
            elseif buff.timeLeft >= warnTime then
                timerText = string.format("%ds", math.floor(buff.timeLeft / 1000))
            else -- Less than warnTime
                timerText = string.format("%.1f", buff.timeLeft / 1000)
            end
            timeLabel:SetText(timerText)
            timeLabel:Show(true)

            -- Stacks -------------------------------------------------------------------------------
            -- shoudShowStacks
            if shoudShowStacks and buff.stack and buff.stack > 1 then
                -- Format stack number
                local stackText
                local thousands
                if buff.stack >= 1000 then
                    thousands = buff.stack / 1000
                    if thousands == math.floor(thousands) then
                        stackText = string.format("%dk", thousands)
                    else
                        stackText = string.format("%.1fk", thousands)
                    end
                else
                    stackText = tostring(buff.stack)
                end
                
                --stackLabel:SetText("x" .. (buff.stack >= 1000 and " " or "") .. stackText)
                stackLabel:SetText("x" .. stackText)
                stackLabel:Show(true)
            else
                stackLabel:Show(false)
            end

            -- Blink effect -----------------------------------------------------------------
            local shouldBlink = (
                (buff.isBuff and buff.timeLeft <= BuffSettingsWindow.settings.buffWarnTime) or
                (not buff.isBuff and buff.timeLeft <= BuffSettingsWindow.settings.debuffWarnTime)
            )

            if shouldBlink then
                local alpha = GetBlinkAlpha(0.45, 1, blinkTimer)
                icon:SetAlpha(alpha)
                timeLabel:SetAlpha(alpha)
                stackLabel:SetAlpha(alpha)
            else
                timeLabel:SetAlpha(1)
                icon:SetAlpha(1)
                stackLabel:SetAlpha(1)
            end
        else
            timeLabel:SetText("")
            timeLabel:Show(false)
            stackLabel:SetText("")
            stackLabel:Show(false)
            -- Alpha is per SLOT, not per buff: if an expiring buff was blinking
            -- in this slot and a permanent buff shifts into it, the slot keeps
            -- its mid-blink alpha unless reset here - the permanent buff then
            -- pulses forever. Only the timed branch above resets it otherwise.
            icon:SetAlpha(1)
            timeLabel:SetAlpha(1)
            stackLabel:SetAlpha(1)
        end
    end
end

local function HideUnusedBuffSlots(buffIcons, buffLabels, stackLabels, maxBuffsToDisplay)
    -- Hide unused buff slots
    for i = maxBuffsToDisplay + 1, BuffSettingsWindow.MAX_BUFFS_COUNT do
        buffIcons[i]:Show(false)
        if buffLabels[i] then buffLabels[i]:Show(false) end
        if stackLabels[i] then stackLabels[i]:Show(false) end
    end
end

local function UpdateBuffsPosition(unitType, dt)
    local s = BuffSettingsWindow.settings

    -- Fixed-screen mode for the player bar: the character sits at an
    -- effectively constant screen position, so skip projection entirely.
    -- This eliminates both the per-frame jitter and the jump caused by the
    -- nameplate shifting the unit's overhead anchor point.
    if unitType == "player" and s.playerBarMode == "fixed" then
        if playerBarUnlocked then return end -- drag owns the anchors while moving
        local pos = s.playerBarPos or { 0, 0 }
        -- Settle-gated re-anchor, mirroring UpdateStaticBarPosition exactly
        local ax, ay = ClampToScreen(pos[1], pos[2])
        previousPlayerXYZString = "" -- head mode must re-anchor if re-enabled
        if not pinSettled or ax ~= lastFixedAppliedX or ay ~= lastFixedAppliedY then
            lastFixedAppliedX, lastFixedAppliedY = ax, ay
            SetPinnedPosition(playerBuffCanvas, ax, ay)
        end
        playerBuffCanvas:Show(true)
        return
    end


    local x, y, z = api.Unit:GetUnitScreenPosition(unitType)

    if isFiniteNumber(x) and isFiniteNumber(y) and isFiniteNumber(z) then
        local currentPos = {x = x, y = y, z = z}

        -- Nameplate compensation. Fixed mode has already returned above, so
        -- reaching here means Above Head. With the player's own nameplate
        -- enabled, the reported X
        -- deviates from where the character actually is (measured: pinned to
        -- exact screen centre with the nameplate off, wandering 1239..1327 with
        -- it on). Applying that deviation inverted cancels it, which algebra
        -- collapses to holding the position on the camera's centre: the camera
        -- follows the player, so centre IS where the character sits on screen.
        -- Y is cancelled the same way, so jumps and gliding no longer move the
        -- bar either - the Player offset slider still sets the resting height.
        -- (Idle head height measured ~727 on a 1440 screen, so half-height is
        -- within a few px; the offset slider absorbs the difference.)
        if unitType == "player" and s.nametagEnabled == true then
            currentPos.x = ScreenUIWidth() / 2

            -- Y is pinned too, but a constant would sit wrong once the camera
            -- zooms: the character grows on screen as it nears, so the bar has to
            -- rise with it. Under perspective the on-screen size scales as
            -- 1/distance, and z here is the camera distance, so the lift is taken
            -- against the distance at calibration - zero drift at that distance,
            -- rising as you zoom in, settling back as you zoom out. Anchoring the
            -- rest position to the head's own height at calibration also means
            -- entering the mode does not jump the bar.
            if nametagCalibZ == nil and currentPos.z and currentPos.z > 0 then
                nametagCalibZ = currentPos.z
                nametagCalibY = currentPos.y
            end
            if nametagCalibZ and currentPos.z and currentPos.z > 0 then
                local rawY = currentPos.y
                local moved = math.abs((1 / currentPos.z) - (1 / nametagCalibZ))

                -- Source plausibility (see the constants above): an implausible
                -- reading updates nothing - the bar holds its last good height
                -- until the game's own anchor recovers
                local plausible = currentPos.z <= NAMETAG_PLAUSIBLE_MIN_Z
                    or rawY > ScreenUIHeight() * NAMETAG_PLAUSIBLE_TOP

                -- Any camera motion this frame, or enough accumulated drift,
                -- opens the settling window (see the constants above)
                local frameMoved = math.abs((1 / currentPos.z)
                    - (1 / (nametagPrevZ or currentPos.z)))
                if moved > NAMETAG_ZOOM_STEP
                    or frameMoved > NAMETAG_CAMERA_FRAME_EPS then
                    nametagSettleMs = NAMETAG_SETTLE_MS
                end
                nametagPrevZ = currentPos.z

                -- Running average of the head, for de-bobbing (see constants)
                if plausible then
                    if nametagHeadAvg == nil then
                        nametagHeadAvg = rawY
                    else
                        local avgFactor = 1 - math.exp(-NAMETAG_HEAD_AVG_SPEED * ((dt or 0) / 1000))
                        nametagHeadAvg = nametagHeadAvg
                            + (rawY - nametagHeadAvg) * avgFactor
                    end
                    if nametagDriftAvg == nil then
                        nametagDriftAvg = rawY
                    else
                        local driftFactor = 1 - math.exp(-NAMETAG_DRIFT_AVG_SPEED * ((dt or 0) / 1000))
                        nametagDriftAvg = nametagDriftAvg
                            + (rawY - nametagDriftAvg) * driftFactor
                    end
                end

                local settling = nametagSettleMs > 0
                local resampled = false
                if plausible and settling then
                    nametagCalibZ = currentPos.z
                    nametagCalibY = rawY
                    nametagDriftAvg = rawY
                    resampled = true
                elseif plausible and nametagWasSettling then
                    -- Camera just settled: adopt the bob average, not the last frame
                    nametagCalibY = nametagHeadAvg
                    nametagDriftAvg = nametagHeadAvg
                end
                nametagWasSettling = settling
                if settling then
                    nametagSettleMs = nametagSettleMs - (dt or 0)
                end

                -- Stuck recovery (see the constants above)
                if resampled or not plausible then
                    nametagStuckMs = 0
                elseif math.abs((nametagHeadAvg or rawY) - nametagCalibY)
                    > NAMETAG_STUCK_PX then
                    nametagStuckMs = nametagStuckMs + (dt or 0)
                    if nametagStuckMs > NAMETAG_STUCK_AFTER_MS then
                        -- Recover toward the bob average, not one frame of it,
                        -- so recovery cannot itself land on a bob peak
                        local recover = 1 - math.exp(-NAMETAG_STUCK_RECOVER_SPEED * ((dt or 0) / 1000))
                        nametagCalibY = nametagCalibY
                            + ((nametagHeadAvg or rawY) - nametagCalibY) * recover
                    end
                else
                    nametagStuckMs = 0
                end

                -- Slow drift correction (see the constants above)
                if plausible and not settling and nametagDriftAvg
                    and nametagHeadAvg
                    and math.abs(nametagHeadAvg - nametagDriftAvg)
                        < NAMETAG_DRIFT_GATE_PX
                    and math.abs(nametagDriftAvg - nametagCalibY)
                        > NAMETAG_DRIFT_PX then
                    local driftEase = 1 - math.exp(-NAMETAG_DRIFT_SPEED * ((dt or 0) / 1000))
                    nametagCalibY = nametagCalibY
                        + (nametagDriftAvg - nametagCalibY) * driftEase
                end

                currentPos.y = nametagCalibY
            else
                currentPos.y = ScreenUIHeight() / 2
            end
        end

        local previousXYZSmoothed, previousXYZString, canvas, baseOffsetY

        if unitType == "player" then
            previousXYZSmoothed = previousPlayerXYZSmothed
            previousXYZString = previousPlayerXYZString
            canvas = playerBuffCanvas
            baseOffsetY = s.playerBuffVerticalOffset
        else -- target
            previousXYZSmoothed = previousTargetXYZSmothed
            previousXYZString = previousTargetXYZString
            canvas = targetBuffCanvas
            baseOffsetY = s.targetBuffVerticalOffset
        end

        -- Positions are used raw. Smoothing used to sit here, trading lag for
        -- less jitter on the player bar; nameplate compensation removes the
        -- jitter at its source instead, so there is nothing left to smooth.
        local smoothPos = currentPos

        -- Snap to whole pixels and re-anchor only on >= 1px movement:
        -- sub-pixel anchor churn is what caused the constant shimmer.
        -- 3.0 anchoring otherwise untouched; the only sizing grafts here are
        -- the offset slider meaning DEVICE pixels (identity at 100%) and the
        -- removal of the per-scale nudge table, which was a band-aid over
        -- the space mix the ScreenUI* pins above now fix at the source.
        local ax = math.floor(smoothPos.x + 0.5)
        local ay = math.floor(smoothPos.y + Px(baseOffsetY) + 0.5)

        -- Reject positions that are off screen BEFORE anchoring to them.
        -- GetUnitScreenPosition's projection blows up as a unit approaches the
        -- camera plane, and z stays positive while x/y run away: a measured trace
        -- had target anchors ranging from -12733 to 90218 on a 2560px screen,
        -- 1576px of movement per frame. Anchoring to those is what makes the bar
        -- appear to jump violently. The client's own chat bubble bounds-checks
        -- the same way before anchoring (scriptsbin\x2ui\chat\chatbubble.lua:165);
        -- only its z > 0 half was adopted here originally.
        local canvasW, canvasH = canvas:GetExtent()
        canvasW = canvasW or 0
        canvasH = canvasH or 0
        local onScreen = ax > -canvasW
            and ax < ScreenUIWidth() + canvasW
            and ay > -canvasH
            and ay < ScreenUIHeight() + canvasH
        if not onScreen then
            canvas:Show(false)
            return
        end

        local posKey = ax .. "," .. ay

        if previousXYZString ~= posKey then
            canvas:RemoveAllAnchors()
            canvas:AddAnchor("BOTTOM", "UIParent", "TOPLEFT", ax, ay)

            if unitType == "player" then
                previousPlayerXYZString = posKey
            else -- target
                previousTargetXYZString = posKey
            end
        end

        previousXYZSmoothed.x = smoothPos.x
        previousXYZSmoothed.y = smoothPos.y
        previousXYZSmoothed.z = smoothPos.z

        -- z is camera-to-unit distance, so the camera's own set-back counts
        -- toward it: a 100 cap cut the bar off at roughly 80m of actual target
        -- range. The far bound is not what keeps the anchor sane - the
        -- projection degenerates at the near plane, not at distance, and the
        -- off-screen bounds check above already rejects runaway anchors - so it
        -- only needs to sit past any range you can hold a target at. The near
        -- half does matter: it rejects units behind the camera.
        canvas:Show(previousXYZSmoothed.z >= 0
            and previousXYZSmoothed.z <= MAX_ANCHOR_DISTANCE)
    end
end

-- The static bar is fixed-screen ONLY: the same anchoring as the player bar's
-- fixed mode above, with its own saved position and unlock flag, and none of
-- the projection machinery - nothing in the world can move it.
local function UpdateStaticBarPosition()
    if staticBarUnlocked then return end -- drag owns the anchors while moving
    local pos = BuffSettingsWindow.settings.staticBarPos or { 0, 0 }
    local ax, ay = ClampToScreen(pos[1], pos[2])
    -- Per frame until the session settles, on-change after (see the settle
    -- gate declaration). Anchors laid during the loading screen resolve
    -- wrong under UI scaling and every one-shot scheme fired too early, so
    -- the bar keeps re-anchoring - the head bar's own self-heal - until the
    -- world has been live for PIN_SETTLE_MS; from then on the target only
    -- changes when a drag saves a new position.
    if not pinSettled or ax ~= lastStaticAppliedX or ay ~= lastStaticAppliedY then
        lastStaticAppliedX, lastStaticAppliedY = ax, ay
        SetPinnedPosition(staticBuffCanvas, ax, ay)
    end
    staticBuffCanvas:Show(true)
end


local blinkTimer = 0
local BLINK_CYCLE = math.pi * 2 -- Full cycle for sin()

--- Function to update the blink timer based on player, target and static buffs
local function UpdateBlinkTimer(playerBuffs, targetBuffs, staticBuffs, dt)
    if #playerBuffs > 0 or #targetBuffs > 0 or #staticBuffs > 0 then
        blinkTimer = blinkTimer + dt / 1000
        
        if blinkTimer >= BLINK_CYCLE then
            blinkTimer = blinkTimer - BLINK_CYCLE
        end
    else
        blinkTimer = 0 
    end
end

local recordingIconAnimation = {
    isActive = false,
    currentAlpha = 1.0,
    targetAlpha = 0.1,
    direction = -1,
    animationSpeed = 0.08,
    stepDelay = 100
}

-- Function to show recording animation
local function AnimateRecordingIcon()
    if not recordingIconAnimation.isActive then
        return
    end
    
    local icon = BuffSettingsWindow.GetRecordingIcon()
    if not icon then
        recordingIconAnimation.isActive = false
        return
    end

    -- Update current alpha
    recordingIconAnimation.currentAlpha = recordingIconAnimation.currentAlpha + 
        (recordingIconAnimation.animationSpeed * recordingIconAnimation.direction)
    
    -- Перевірити межі та змінити напрямок
    if recordingIconAnimation.currentAlpha <= 0.1 then
        recordingIconAnimation.currentAlpha = 0.1
        recordingIconAnimation.direction = 1 -- Start increasing
    elseif recordingIconAnimation.currentAlpha >= 1.0 then
        recordingIconAnimation.currentAlpha = 1.0
        recordingIconAnimation.direction = -1 -- Start decreasing
    end
    
    -- Aplly alpha
    icon:SetColor(1, 1, 1, recordingIconAnimation.currentAlpha)
    
    -- Plann next animation
    if recordingIconAnimation.isActive then
        api:DoIn(recordingIconAnimation.stepDelay, AnimateRecordingIcon)
    end
end

-- Update event to handle buff/debuff updates
local function OnUpdate(dt)
    -- Advance the pinned-bar settle clock only while the world renders:
    -- one projection read per frame, and none at all once settled
    if not pinSettled then
        local wx, wy, wz = api.Unit:GetUnitScreenPosition("player")
        if isFiniteNumber(wx) and isFiniteNumber(wy) and isFiniteNumber(wz) then
            pinSettleMs = pinSettleMs + (dt or 0)
            if pinSettleMs >= PIN_SETTLE_MS then
                pinSettled = true
            end
        end
    end

    -- If active will track buffs
    BuffsLogger.Track(dt)


    -- Check if player is targeting themselves
    local playerUnitId = api.Unit:GetUnitId("player")
    local targetUnitId = api.Unit:GetUnitId("target")
    local isSelfTarget = (playerUnitId == targetUnitId)

    -- Collect all watched buffs and debuffs
    local playerBuffs, targetBuffs, staticBuffs = CollectWatchedBuffsAndDebuffs()
    -- Update blink timer
    UpdateBlinkTimer(playerBuffs, targetBuffs, staticBuffs, dt)

    -- ## PLAYER Update position and show player buffs/debuffs ##------
    if #playerBuffs > 0 then
        local maxPlayerBuffsToDisplay = math.min(#playerBuffs, BuffSettingsWindow.settings.maxBuffsShown)

        local sig = BuildBuffSignature(playerBuffs, maxPlayerBuffsToDisplay, BuffSettingsWindow.settings.iconSize)
        if sig ~= lastPlayerBuffSig then
            lastPlayerBuffSig = sig
            -- Constant footprint only when pinned to a screen point; head
            -- mode re-anchors every frame and must stay content-sized
            PositionBuffs(playerBuffs, playerBuffCanvas, playerBuffIcons, playerBuffLabels, playerBuffStackLabels, BuffSettingsWindow.settings.iconSize,
                BuffSettingsWindow.settings.playerBarMode == "fixed")
            ApplyBuffSkins(playerBuffs, playerBuffIcons, maxPlayerBuffsToDisplay)
            HideUnusedBuffSlots(playerBuffIcons, playerBuffLabels, playerBuffStackLabels, maxPlayerBuffsToDisplay)
        end
        UpdateBuffIconsAndTimers(playerBuffs, playerBuffIcons, playerBuffLabels, playerBuffStackLabels, maxPlayerBuffsToDisplay, blinkTimer)
        UpdateBuffsPosition("player", dt)
    else
        lastPlayerBuffSig = ""
        -- Keep the canvas visible while the user is drag-placing the bar
        if not playerBarUnlocked then
            playerBuffCanvas:Show(false)
        end
    end
    -- ##--------------------------------------------------------------------------------- ## -----

    -- ## TARGET Update position and show target buffs/debuffs (only if not self-targeting) ##------
    if not isSelfTarget and #targetBuffs > 0 then
        local maxTargetBuffsToDisplay = math.min(#targetBuffs, BuffSettingsWindow.settings.maxBuffsShown)

        local sig = BuildBuffSignature(targetBuffs, maxTargetBuffsToDisplay, BuffSettingsWindow.settings.targetIconSize)
        if sig ~= lastTargetBuffSig then
            lastTargetBuffSig = sig
            PositionBuffs(targetBuffs, targetBuffCanvas, targetBuffIcons, targetBuffLabels, targetBuffStackLabels, BuffSettingsWindow.settings.targetIconSize)
            ApplyBuffSkins(targetBuffs, targetBuffIcons, maxTargetBuffsToDisplay)
            HideUnusedBuffSlots(targetBuffIcons, targetBuffLabels, targetBuffStackLabels, maxTargetBuffsToDisplay)
        end
        UpdateBuffIconsAndTimers(targetBuffs, targetBuffIcons, targetBuffLabels, targetBuffStackLabels, maxTargetBuffsToDisplay, blinkTimer)
        UpdateBuffsPosition("target", dt)
    else
        lastTargetBuffSig = ""
        targetBuffCanvas:Show(false)
    end
    -- ##---------------------------------------------------------------------------------

    -- ## STATIC bar: the player's second, fixed bar ##------
    -- staticBuffs is only populated while the bar is enabled (see the collect
    -- pass), so a disabled bar always lands in the else-hide here. Sized by
    -- its own slider (staticIconSize, in the Configure popup) since the bars
    -- stopped sharing the player size.
    if #staticBuffs > 0 then
        local maxStaticBuffsToDisplay = math.min(#staticBuffs, BuffSettingsWindow.settings.maxBuffsShown)

        local sig = BuildBuffSignature(staticBuffs, maxStaticBuffsToDisplay, BuffSettingsWindow.settings.staticIconSize)
        if sig ~= lastStaticBuffSig then
            lastStaticBuffSig = sig
            -- Always pinned to a screen point, so always a constant footprint
            PositionBuffs(staticBuffs, staticBuffCanvas, staticBuffIcons, staticBuffLabels, staticBuffStackLabels, BuffSettingsWindow.settings.staticIconSize, true)
            ApplyBuffSkins(staticBuffs, staticBuffIcons, maxStaticBuffsToDisplay)
            HideUnusedBuffSlots(staticBuffIcons, staticBuffLabels, staticBuffStackLabels, maxStaticBuffsToDisplay)
        end
        UpdateBuffIconsAndTimers(staticBuffs, staticBuffIcons, staticBuffLabels, staticBuffStackLabels, maxStaticBuffsToDisplay, blinkTimer)
        UpdateStaticBarPosition()
    else
        lastStaticBuffSig = ""
        -- Keep the canvas visible while the user is drag-placing the bar
        if not staticBarUnlocked then
            staticBuffCanvas:Show(false)
        end
    end
    -- ##---------------------------------------------------------------------------------
end


local function HandleChatCommand(channel, unit, isHostile, name, message, speakerInChatBound, specifyName, factionName, trialPosition)
    local playerName = api.Unit:GetUnitNameById(api.Unit:GetUnitId("player"))
    if playerName ~= name then return end
    if message == "ttp" then
        BuffSettingsWindow.ToggleBuffSelectionWindow()
    end
end

local function OnNewBuffLogged()
    BuffSettingsWindow.RefreshLoggedBuffs()
end
local function OnBuffsLoggingStarted()
    local icon = BuffSettingsWindow.GetRecordingIcon()
    if not icon then
        return
    end
    if not recordingIconAnimation.isActive then
        icon:SetVisible(true)
        recordingIconAnimation.isActive = true
        recordingIconAnimation.currentAlpha = 1.0
        recordingIconAnimation.direction = -1
        AnimateRecordingIcon()
    end
end
local function OnBuffsLoggingStopped()
    recordingIconAnimation.isActive = false
    local icon = BuffSettingsWindow.GetRecordingIcon()
    if icon then
        icon:SetVisible(false)
        icon:SetColor(1, 1, 1, 1.0)
    end
end

-- Toggled from the settings window ("Move bar" button). While unlocked the
-- player bar shows a colored backdrop and can be dragged; the dropped position
-- is saved and used by fixed-screen mode.
-- The compensated resting height is calibrated from the camera distance at the
-- moment it is entered, so a mode change has to invalidate it
local function OnBarModeChanged()
    nametagCalibZ = nil
    nametagCalibY = nil
    nametagStuckMs = 0
    nametagSettleMs = 0
    nametagPrevZ = nil
    nametagHeadAvg = nil
    nametagDriftAvg = nil
    nametagWasSettling = false
end

local function OnPlayerBarUnlockToggle()
    if not playerBuffCanvas then
        playerBarUnlocked = false
        return
    end
    playerBarUnlocked = not playerBarUnlocked

    if playerBarUnlocked then
        -- Dragging only makes sense for a fixed screen position
        BuffSettingsWindow.settings.playerBarMode = "fixed"
        -- Guarantee the TOPLEFT anchor StartMoving will update: coming out
        -- of head mode the canvas still carries head mode's BOTTOM anchor,
        -- and saving THAT anchor's offset as a TOPLEFT position is the
        -- half-width-right, full-height-down jump at "Done moving"
        PrepareFixedBarDrag(playerBuffCanvas, BuffSettingsWindow.settings.playerBarPos,
            BuffSettingsWindow.settings.iconSize)
        if not playerBuffCanvas.dragBackdrop then
            local bd = playerBuffCanvas:CreateColorDrawable(0, 0.75, 0.75, 0.35, "background")
            bd:AddAnchor("TOPLEFT", playerBuffCanvas, 0, 0)
            bd:AddAnchor("BOTTOMRIGHT", playerBuffCanvas, 0, 0)
            playerBuffCanvas.dragBackdrop = bd
        end
        playerBuffCanvas.dragBackdrop:SetVisible(true)
        playerBuffCanvas:Clickable(true)
        if playerBuffCanvas.EnableDrag then playerBuffCanvas:EnableDrag(true) end
        playerBuffCanvas:Show(true)
    else
        if playerBuffCanvas.dragBackdrop then
            playerBuffCanvas.dragBackdrop:SetVisible(false)
        end
        playerBuffCanvas:Clickable(false)
        if playerBuffCanvas.EnableDrag then playerBuffCanvas:EnableDrag(false) end
        BuffSettingsWindow.SaveSettings()
    end
end

-- Mirror of OnPlayerBarUnlockToggle for the static bar, minus the mode
-- forcing: the static bar has no head mode to leave.
local function OnStaticBarUnlockToggle()
    if not staticBuffCanvas then
        staticBarUnlocked = false
        return
    end
    staticBarUnlocked = not staticBarUnlocked

    if staticBarUnlocked then
        if not staticBuffCanvas.dragBackdrop then
            -- Violet like the settings window's static accents, so the two
            -- drag boxes cannot be confused when both bars are unlocked
            local bd = staticBuffCanvas:CreateColorDrawable(0.55, 0.42, 0.80, 0.35, "background")
            bd:AddAnchor("TOPLEFT", staticBuffCanvas, 0, 0)
            bd:AddAnchor("BOTTOMRIGHT", staticBuffCanvas, 0, 0)
            staticBuffCanvas.dragBackdrop = bd
        end
        -- Guarantee the TOPLEFT anchor StartMoving will update: a bar whose
        -- list has never had buffs while locked has NEVER been anchored -
        -- the canvases are born anchorless - and dragging an anchorless
        -- widget is what poisoned the save in the place-it-first workflow
        PrepareFixedBarDrag(staticBuffCanvas, BuffSettingsWindow.settings.staticBarPos,
            BuffSettingsWindow.settings.staticIconSize)
        staticBuffCanvas.dragBackdrop:SetVisible(true)
        staticBuffCanvas:Clickable(true)
        if staticBuffCanvas.EnableDrag then staticBuffCanvas:EnableDrag(true) end
        staticBuffCanvas:Show(true)
    else
        if staticBuffCanvas.dragBackdrop then
            staticBuffCanvas.dragBackdrop:SetVisible(false)
        end
        staticBuffCanvas:Clickable(false)
        if staticBuffCanvas.EnableDrag then staticBuffCanvas:EnableDrag(false) end
        BuffSettingsWindow.SaveSettings()
    end
end

-- ===== Shared ESC-menu "Addon Options" panel =====
-- Layout of the flat shell TrackThatPlease imposes on the panel, whether it built
-- it or adopted one another addon created.
-- Wide enough for longer addon names than the ones that happened to be
-- installed here: the entry button is ESC_PANEL_W - 12 and its label
-- ESC_PANEL_W - 16, so everything follows from this one number.
local ESC_PANEL_W = 160
-- Gap between the panel's right edge and the config frame. The panel is anchored
-- off the frame's left edge, so its own width pushes it left and only this sets
-- how close it sits.
local ESC_PANEL_GAP = 5
local ESC_HEADER_H = 26
local ESC_ROW_H = 24
local ESC_ROW_GAP = 4
local ESC_FIRST_ROW_Y = ESC_HEADER_H + 4

-- Paints the flat shell onto the panel's header label. Drawables created here are
-- added after any the original builder made, so they render on top of them.
local function styleEscPanelShell(mc)
    mc:SetExtent(ESC_PANEL_W, ESC_HEADER_H)
    pcall(function()
        mc.style:SetFontSize(13)
        mc.style:SetAlign(ALIGN.CENTER)
        mc.style:SetColor(1, 0.84, 0, 1)
    end)

    -- An adopted panel already has a background; make it transparent rather than
    -- trying to remove it, so the original owner can keep resizing it harmlessly.
    if mc.bg then
        pcall(function() mc.bg:SetColor(0, 0, 0, 0) end)
    end

    mc.ttpOutline = mc:CreateColorDrawable(0, 0, 0, 0.96, "background")
    mc.ttpBody = mc:CreateColorDrawable(0.06, 0.06, 0.068, 0.96, "background")
    local header = mc:CreateColorDrawable(0.09, 0.09, 0.11, 0.98, "background")
    header:AddAnchor("TOPLEFT", mc, 1, 1)
    header:AddAnchor("BOTTOMRIGHT", mc, -1, -1)
    local accent = mc:CreateColorDrawable(0, 0.75, 0.75, 0.85, "background")
    accent:SetExtent(3, ESC_HEADER_H - 2)
    accent:AddAnchor("TOPLEFT", mc, 1, 1)
end

-- Restyles one entry button. The button keeps its own OnClick, so an adopted
-- entry still opens whichever addon registered it.
local function styleEscButton(btn, title)
    if not btn or btn.ttpStyled then return end
    btn.ttpStyled = true

    btn:SetExtent(ESC_PANEL_W - 12, ESC_ROW_H)
    pcall(function() btn:SetText("") end)

    local border = btn:CreateColorDrawable(0, 0, 0, 0.92, "background")
    border:AddAnchor("TOPLEFT", btn, 0, 0)
    border:AddAnchor("BOTTOMRIGHT", btn, 0, 0)
    local fill = btn:CreateColorDrawable(0.14, 0.14, 0.16, 0.95, "background")
    fill:AddAnchor("TOPLEFT", btn, 1, 1)
    fill:AddAnchor("BOTTOMRIGHT", btn, -1, -1)

    local label = btn:CreateChildWidget("label", "ttpEscLbl_" .. tostring(title), 0, true)
    label:SetExtent(ESC_PANEL_W - 16, 14)
    label:AddAnchor("CENTER", btn, 0, 0)
    label:SetText(title)
    label.style:SetFontSize(12)
    label.style:SetAlign(ALIGN.CENTER)
    label.style:SetColor(0.88, 0.90, 0.93, 1)
    label:Clickable(false)

    -- OnEnter/OnLeave only drove the original hover skin, so taking them over
    -- costs nothing; OnClick is deliberately left alone.
    btn:SetHandler("OnEnter", function() fill:SetColor(0.17, 0.17, 0.20, 1) end)
    btn:SetHandler("OnLeave", function() fill:SetColor(0.14, 0.14, 0.16, 0.95) end)
    btn:Show(true)
end

-- Repositions every entry onto our row pitch and resizes the shell to match. The
-- original builder anchors new buttons on its own spacing, so this runs after
-- each AddAddon to put them back on ours.
local function relayoutEscPanel(mc)
    local titles = {}
    for title in pairs(mc.addons or {}) do table.insert(titles, title) end
    table.sort(titles) -- registration order is load order, which is not stable

    for index, title in ipairs(titles) do
        local btn = mc.addons[title]
        if btn then
            pcall(function()
                btn:RemoveAllAnchors()
                btn:AddAnchor("TOPLEFT", mc, 6,
                    ESC_FIRST_ROW_Y + (index - 1) * (ESC_ROW_H + ESC_ROW_GAP))
            end)
        end
    end

    local extra = ESC_FIRST_ROW_Y + #titles * (ESC_ROW_H + ESC_ROW_GAP) - ESC_HEADER_H
    if mc.ttpOutline then
        pcall(function()
            mc.ttpOutline:RemoveAllAnchors()
            mc.ttpOutline:AddAnchor("TOPLEFT", mc, 0, 0)
            mc.ttpOutline:AddAnchor("BOTTOMRIGHT", mc, 0, extra)
        end)
    end
    if mc.ttpBody then
        pcall(function()
            mc.ttpBody:RemoveAllAnchors()
            mc.ttpBody:AddAnchor("TOPLEFT", mc, 1, 1)
            mc.ttpBody:AddAnchor("BOTTOMRIGHT", mc, -1, extra - 1)
        end)
    end
end

-- Builds the panel if it does not exist, otherwise takes over the styling of the
-- one already there. Either way TrackThatPlease ends up owning how it looks.
local function adoptEscMenuPanel(configMenu)
    local mc = configMenu.michaelClient

    if not mc then
        mc = configMenu:CreateChildWidget("label", "mc_TrackThatPlease", 0, true)
        mc:AddAnchor("TOPLEFT", configMenu, -(ESC_PANEL_W + ESC_PANEL_GAP), 5)
        mc:SetText("Addon Options")
        configMenu.michaelClient = mc
        mc.addons = {}
        mc.addonCount = 0
        styleEscPanelShell(mc)
        mc.ttpStyled = true

        function mc:AddAddon(title, callback)
            local existing = self.addons[title]
            if existing then
                existing:SetHandler("OnClick", function() callback() end)
                existing:Show(true)
                return
            end
            self.addonCount = self.addonCount + 1
            local btn = self:CreateChildWidget("button", "ttp_addon_" .. tostring(self.addonCount), 0, true)
            btn:SetHandler("OnClick", function() callback() end)
            self.addons[title] = btn
            styleEscButton(btn, title)
            relayoutEscPanel(self)
        end

        relayoutEscPanel(mc)
        return
    end

    if mc.ttpStyled then return end
    mc.ttpStyled = true

    -- Adopting a panel another addon built. Re-anchor it too: the original sits
    -- close enough to the config frame to overlap its border.
    pcall(function()
        mc:RemoveAllAnchors()
        mc:AddAnchor("TOPLEFT", configMenu, -(ESC_PANEL_W + ESC_PANEL_GAP), 5)
    end)
    styleEscPanelShell(mc)
    for title, btn in pairs(mc.addons or {}) do
        styleEscButton(btn, title)
    end

    -- Later registrations still go through the original AddAddon, keeping its
    -- bookkeeping intact, then get restyled and re-laid out on the way out.
    local originalAddAddon = mc.AddAddon
    if originalAddAddon then
        mc.AddAddon = function(self, title, callback)
            originalAddAddon(self, title, callback)
            styleEscButton(self.addons and self.addons[title], title)
            relayoutEscPanel(self)
        end
    end

    relayoutEscPanel(mc)
end
-- Load function to initialize the UI elements
local function OnLoad()
    -- load setttings------------------------
    BuffsLogger.Initialize()
    BuffSettingsWindow.Initialize(BuffsLogger)
    -------------------------------------

    playerBuffCanvas = api.Interface:CreateEmptyWindow("playerBuffCanvas")
    -- Px is best effort here (the scale is not readable at load time); the
    -- first PositionBuffs pass re-sizes with the real scale
    playerBuffCanvas:SetExtent(Px(BuffSettingsWindow.settings.iconSize * BuffSettingsWindow.settings.maxBuffsShown + (BuffSettingsWindow.settings.maxBuffsShown - 1) * BuffSettingsWindow.settings.iconSpacing), Px(BuffSettingsWindow.settings.iconSize))
    -- Anchored from creation, like dawnsdrop's canvas (dawnsdrop_view.lua:2
    -- anchors right after CreateEmptyWindow). A widget whose FIRST-ever
    -- anchor comes later - especially while hidden - is what resolves
    -- wrong; every later SetPinnedPosition is then a RE-anchor of an
    -- already-resolved widget, the operation that demonstrably works
    -- ("Move bar" always landed right). Head mode re-anchors per frame, so
    -- seeding the player canvas here is harmless in that mode.
    do
        local pp = BuffSettingsWindow.settings.playerBarPos or { 0, 0 }
        SetPinnedPosition(playerBuffCanvas, ClampToScreen(pp[1], pp[2]))
    end
    playerBuffCanvas:Show(false)
    playerBuffCanvas:Clickable(false)

    targetBuffCanvas = api.Interface:CreateEmptyWindow("targetBuffCanvas")
    targetBuffCanvas:SetExtent(Px(BuffSettingsWindow.settings.targetIconSize * BuffSettingsWindow.settings.maxBuffsShown + (BuffSettingsWindow.settings.maxBuffsShown - 1) * BuffSettingsWindow.settings.iconSpacing), Px(BuffSettingsWindow.settings.targetIconSize))
    targetBuffCanvas:Show(false)
    targetBuffCanvas:Clickable(false)

    -- Sized by its own staticIconSize (best effort at load, like the others)
    staticBuffCanvas = api.Interface:CreateEmptyWindow("staticBuffCanvas")
    staticBuffCanvas:SetExtent(Px(BuffSettingsWindow.settings.staticIconSize * BuffSettingsWindow.settings.maxBuffsShown + (BuffSettingsWindow.settings.maxBuffsShown - 1) * BuffSettingsWindow.settings.iconSpacing), Px(BuffSettingsWindow.settings.staticIconSize))
    -- Anchored from creation; see playerBuffCanvas above
    do
        local sp = BuffSettingsWindow.settings.staticBarPos or { 0, 0 }
        SetPinnedPosition(staticBuffCanvas, ClampToScreen(sp[1], sp[2]))
    end
    staticBuffCanvas:Show(false)
    staticBuffCanvas:Clickable(false)

    -- Create buff canvases
    for i = 1, BuffSettingsWindow.MAX_BUFFS_COUNT do
        playerBuffIcons[i], playerBuffLabels[i], playerBuffStackLabels[i] = CreateBuffElement(i, playerBuffCanvas)
        targetBuffIcons[i], targetBuffLabels[i], targetBuffStackLabels[i] = CreateBuffElement(i, targetBuffCanvas)
        staticBuffIcons[i], staticBuffLabels[i], staticBuffStackLabels[i] = CreateBuffElement(i, staticBuffCanvas)
    end
    
    -- Drag-to-place for the player bar (active only while unlocked)
    playerBuffCanvas:SetHandler("OnDragStart", function(self)
        if not playerBarUnlocked then return end
        -- NO RemoveAllAnchors here. StartMoving on a still-anchored widget
        -- updates that widget's ANCHOR OFFSET, which is what keeps GetOffset
        -- and AddAnchor speaking the same space - the pairing every working
        -- addon relies on (CooldawnBuffTracker/canvas_factory.lua:245,
        -- power_ranger_on/node_tracker.lua:890, sticky_ui). Stripping the
        -- anchors first, which TTP has always done here, leaves the widget
        -- positioned by another mechanism: GetOffset then reports the
        -- scale-divided value the dump caught, and saving it drifted the bar
        -- on every placement. The unlock handler has already re-anchored
        -- TOPLEFT (PrepareFixedBarDrag), so the anchor being updated is the
        -- one the restore writes back.
        self:StartMoving()
        api.Cursor:ClearCursor()
        api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end)
    playerBuffCanvas:SetHandler("OnDragStop", function(self)
        if not playerBarUnlocked then return end
        self:StopMovingOrSizing()
        api.Cursor:ClearCursor()
        -- Dawnsdrop's save (dawnsdrop_view.lua:59 + UpdatePos): GetOffset
        -- raw, floored, saved, immediately re-applied through
        -- SetPinnedPosition. What is on screen after the drop IS the saved
        -- position; a mismatch would show at mouse release, not next reload.
        local ox, oy = self:GetOffset()
        local px, py = ClampToScreen(ox, oy)
        BuffSettingsWindow.settings.playerBarPos = { px, py }
        BuffSettingsWindow.SaveSettings()
        SetPinnedPosition(self, px, py)
        lastFixedAppliedX, lastFixedAppliedY = px, py
    end)

    -- Drag-to-place for the static bar, the same pair as above with its own
    -- unlock flag and saved position
    staticBuffCanvas:SetHandler("OnDragStart", function(self)
        if not staticBarUnlocked then return end
        -- Anchors stay on through the drag; see the player handler above
        self:StartMoving()
        api.Cursor:ClearCursor()
        api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end)
    staticBuffCanvas:SetHandler("OnDragStop", function(self)
        if not staticBarUnlocked then return end
        self:StopMovingOrSizing()
        api.Cursor:ClearCursor()
        -- Dawnsdrop's save, verbatim (dawnsdrop_view.lua:59 + main.lua
        -- UpdatePos): GetOffset raw, floored, saved, then IMMEDIATELY
        -- re-applied through the same SetPinnedPosition the restores use -
        -- so what is on screen after the drop IS the saved position, and
        -- any save/anchor mismatch would be visible the instant the mouse
        -- releases instead of surfacing on the next reload.
        local ox, oy = self:GetOffset()
        local px, py = ClampToScreen(ox, oy)
        BuffSettingsWindow.settings.staticBarPos = { px, py }
        BuffSettingsWindow.SaveSettings()
        SetPinnedPosition(self, px, py)
        lastStaticAppliedX, lastStaticAppliedY = px, py
    end)

    api.On("UPDATE", OnUpdate)
    api.On("CHAT_MESSAGE", HandleChatCommand)
    api.On("TTP_NEW_BUFF_LOGGED", OnNewBuffLogged)
    api.On("TTP_BUFFS_LOGGING_STARTED", OnBuffsLoggingStarted)
    api.On("TTP_BUFFS_LOGGING_STOPPED", OnBuffsLoggingStopped)
    api.On("TTP_PLAYERBAR_UNLOCK", OnPlayerBarUnlockToggle)
    api.On("TTP_STATICBAR_UNLOCK", OnStaticBarUnlockToggle)
    api.On("TTP_BARMODE_CHANGED", OnBarModeChanged)

    -- The floating "TrackThatPls" button is gone: the window is opened from the
    -- ESC menu (registered below), the addon manager gear (OnSettingToggle), or
    -- by typing "ttp" in chat. The recording indicator moved onto the logging
    -- button inside the settings window.

    -- /reload does NOT fire OnUnload, and CreateEmptyWindow widgets are invisible
    -- to FindWidget, so a fresh instance cannot find the old HUD. Each load bumps
    -- a session counter; a HUD born under an older counter hides and unregisters
    -- itself on its next UPDATE tick.
    local root = Store.Root()
    root.hudSession = (root.hudSession or 0) + 1
    local mySession = root.hudSession
    Store.Save()

    local hudWidgets = { playerBuffCanvas, targetBuffCanvas, staticBuffCanvas }
    if BuffSettingsWindow.GetWindow then
        local settingsWnd = BuffSettingsWindow.GetWindow()
        if settingsWnd then table.insert(hudWidgets, settingsWnd) end
    end
    staleHideHandler = function()
        local r = Store.Root()
        if (r.hudSession or 0) == mySession then return end
        for _, w in ipairs(hudWidgets) do
            pcall(function() w:Show(false) end)
            pcall(function() w:RemoveAllAnchors() end)
            pcall(function() w:AddAnchor("TOPLEFT", "UIParent", -10000, -10000) end)
            pcall(function() w:SetExtent(1, 1) end)
        end
        if api.Off then pcall(function() api.Off("UPDATE", staleHideHandler) end) end
    end
    api.On("UPDATE", staleHideHandler)

    BuffSettingsWindow.RefreshLoggedBuffs()

    -- Register in the ESC menu "Addon Options" panel. This panel is shared with
    -- other addons (BetterBars, CustomUI) through the michaelClient convention:
    -- whichever addon loads first builds it, the rest just call AddAddon on it.
    --
    -- TrackThatPlease owns the styling either way. If the panel does not exist we
    -- build it; if another addon built it first we adopt it - painting our shell
    -- over theirs, restyling the entries already registered, and wrapping AddAddon
    -- so later entries get the same treatment. Restyling an existing button keeps
    -- its own OnClick closure, so no other addon's code or callbacks are touched.
    pcall(function()
        local configMenu = ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME)
        if not configMenu then return end

        adoptEscMenuPanel(configMenu)

        if configMenu.michaelClient.AddAddon then
            configMenu.michaelClient:AddAddon("TrackThatPlease", function()
                BuffSettingsWindow.ToggleBuffSelectionWindow()
            end)
        end
    end)

    -- Native ESCMenu registration (the queue is read by the ESCMenu addon's
    -- two-phase loader; safe no-op when ESCMenu is not installed)
    pcall(function()
        ESCMenu = ESCMenu or {}
        ESCMenu.queue = ESCMenu.queue or {}
        table.insert(ESCMenu.queue, {
            name = "TrackThatPlease",
            callback = function() BuffSettingsWindow.ToggleBuffSelectionWindow() end,
            category = "Combat",
        })
    end)

    api.Log:Info("TrackThatPlease had been loaded. Open it from the ESC menu (Addon Options), \n the addon manager, or by typing - ttp - in chat")
end

-- Unload function to clean up
local function OnUnload()
    -- api.On is additive: re-binding a no-op does NOT unbind, so detach the
    -- actual handler references with api.Off
    if api.Off then
        pcall(function() api.Off("UPDATE", OnUpdate) end)
        pcall(function() api.Off("CHAT_MESSAGE", HandleChatCommand) end)
        pcall(function() api.Off("TTP_NEW_BUFF_LOGGED", OnNewBuffLogged) end)
        pcall(function() api.Off("TTP_BUFFS_LOGGING_STARTED", OnBuffsLoggingStarted) end)
        pcall(function() api.Off("TTP_BUFFS_LOGGING_STOPPED", OnBuffsLoggingStopped) end)
        pcall(function() api.Off("TTP_PLAYERBAR_UNLOCK", OnPlayerBarUnlockToggle) end)
        pcall(function() api.Off("TTP_STATICBAR_UNLOCK", OnStaticBarUnlockToggle) end)
        if staleHideHandler then
            pcall(function() api.Off("UPDATE", staleHideHandler) end)
        end
    end
    staleHideHandler = nil

    -- Stop the recording-icon DoIn animation loop
    recordingIconAnimation.isActive = false

    -- Hide our entry in the shared ESC-menu Addon Options panel (the panel
    -- itself is shared with other addons, so only our button is touched)
    pcall(function()
        local configMenu = ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME)
        if configMenu and configMenu.michaelClient and configMenu.michaelClient.addons then
            local entry = configMenu.michaelClient.addons["TrackThatPlease"]
            if entry then entry:Show(false) end
        end
    end)

    -- Cleanup BuffSettingsWindow first (saves settings)
    if BuffSettingsWindow and BuffSettingsWindow.Cleanup then
        BuffSettingsWindow.Cleanup()
    end
    BuffsLogger.CleanUp()

    -- Clean up player buff UI elements
    if playerBuffCanvas then
        playerBuffCanvas:Show(false)
        pcall(function() api.Interface:Free(playerBuffCanvas) end)
        playerBuffCanvas = nil
    end

    -- Clean up target buff UI elements
    if targetBuffCanvas then
        targetBuffCanvas:Show(false)
        pcall(function() api.Interface:Free(targetBuffCanvas) end)
        targetBuffCanvas = nil
    end

    -- Clean up static bar UI elements
    if staticBuffCanvas then
        staticBuffCanvas:Show(false)
        pcall(function() api.Interface:Free(staticBuffCanvas) end)
        staticBuffCanvas = nil
    end

end

local function OnSettingToggle()
    BuffSettingsWindow.ToggleBuffSelectionWindow()
end

TargetBuffTrackerAddon.OnLoad = OnLoad
TargetBuffTrackerAddon.OnUnload = OnUnload
TargetBuffTrackerAddon.OnSettingToggle = OnSettingToggle

return TargetBuffTrackerAddon