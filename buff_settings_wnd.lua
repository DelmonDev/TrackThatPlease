local api = require("api")
local BuffList = require("TrackThatPlease/buff_helper")
local helpers = require("TrackThatPlease/util/helpers")
local Store = require("TrackThatPlease/util/settings_store")
local BuffsLogger

local BuffSettingsWindow = {}
BuffSettingsWindow.settings = {}
-- Upper bound of the "Max buffs" slider and the number of icon slots created
BuffSettingsWindow.MAX_BUFFS_COUNT = 13
-- Single source for the version: main.lua's addon table and the settings-window
-- footer both read this, so they cannot disagree.
BuffSettingsWindow.ADDON_VERSION = "3.2.2"
-- Blinking "recording" indicator shown left of the logging button
local RECORDING_ICON_PATH = "../Addon/TrackThatPlease/icons/rec-button.png"

-- Settings storage (schema v2)
--
--   root = {
--     schemaVersion = 2,
--     enabled       = true,   -- owned by the addon manager
--     hudSession    = N,      -- owned by main.lua
--     global     = { <all display settings>, playerWatchedBuffs, targetWatchedBuffs },
--     characters = { ["name"] = { useCharacterBuffs, playerWatchedBuffs, targetWatchedBuffs } },
--   }
--
-- Display settings are always global. Watched lists come from `global` unless the
-- character has opted into its own lists via useCharacterBuffs.
local SCHEMA_VERSION = 2

local settingsRoot = {}
local globalSettings = {}
local characterSettings = {}
local currentCharacterKey = "unknown"
-- Attempts made to resolve the character name after load (see retryCharacterKeyLoad)
local characterKeyRetries = 0

-- Root keys that are not display settings and must survive migration untouched
local RESERVED_ROOT_KEYS = {
    enabled = true,        -- read by the addon manager to enable/disable the addon
    hudSession = true,     -- /reload stale-HUD counter, owned by main.lua
    schemaVersion = true,
    global = true,
    characters = true,
    legacyBackupV1 = true,
    infoCardSeen = true,   -- one-time welcome card; per install, not per character
}

-- v0 keys that no code reads any more; dropped during migration
local LEGACY_DEAD_KEYS = {
    playerBuffHorizontalOffset = true,
    targetBuffHorizontalOffset = true,
    showAbovePlayerUnitFrame = true,
    showAboveTargetUnitFrame = true,
    buffBlinkSpeed = true,
}

-- Ranges enforced on load. Old files predate the current limits (a v0 file can
-- carry maxBuffsShown = 25 while only MAX_BUFFS_COUNT icon slots exist, which
-- would index past the end of the icon arrays in main.lua).
local SETTING_CLAMPS = {
    fontSize = { 10, 36 },
    -- 10..60: the old floor of 25 was well above what a compact bar wants.
    -- Widened rather than shifted, so every stored size stays valid and
    -- nothing needs migrating. The floor is 10 rather than lower because the
    -- timer and stack text have their own size sliders and do not shrink with
    -- the icon - below ~10 they simply overflow it.
    iconSize = { 10, 60 },
    targetIconSize = { 10, 60 },
    staticIconSize = { 10, 60 },
    iconSpacing = { 1, 10 },
    maxBuffsShown = { 3, BuffSettingsWindow.MAX_BUFFS_COUNT },
    buffWarnTime = { 0, 10000 },
    debuffWarnTime = { 0, 10000 },
    -- Positive values sit the bar BELOW the head anchor; the old -60..-20 band
    -- only allowed heights above it
    playerBuffVerticalOffset = { -100, 100 },
    targetBuffVerticalOffset = { -100, 100 },
}

local function clampNumber(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- The live UI scale, defensively: not readable while addons load (falls back
-- to 1, the old behaviour), and never trusted as a divisor without a check.
local function uiScaleOrOne()
    local uiScale = api.Interface:GetUIScale()
    if type(uiScale) ~= "number" or uiScale <= 0 then return 1 end
    return uiScale
end

-- Fix a size in DEVICE pixels (main.lua's Px rule; the reasoning lives in
-- BetterBars' UI_SCALING.md): a thin line built from a colour drawable must
-- not scale, or at 85% a 1-unit line is 0.85 device pixels and rasterises to
-- nothing along part of its length. Identity at 100%. Read live on every use,
-- never cached at load: the option's scale is not readable while addons load.
local function Px(n)
    return n / uiScaleOrOne()
end

-- ===================== Live-scale line geometry ==============================
-- Every thin line in this window - border+fill rings, checkbox rings, slider
-- fills, header strips, the triangle glyphs - must be laid in DEVICE pixels
-- (UI_SCALING.md), but the window is built at OnLoad, when the scale still
-- reads 1, so every build-time thickness is provisional. Each construct
-- registers a refresher; RefreshPxGeometry re-runs them with the live scale
-- when the window or the info card is shown and the scale has changed since
-- the last pass. (The buff-list rows do the same per fill through
-- UpdatePxGeometry.) Registration runs the refresher once immediately, so
-- anything built AFTER load - the info card - is correct from creation.
local pxRefreshers = {}
local lastPxScale = 0
local function RegisterPxRefresher(fn)
    table.insert(pxRefreshers, fn)
    pcall(fn)
end
local function RefreshPxGeometry()
    local scale = uiScaleOrOne()
    if scale == lastPxScale then return end
    lastPxScale = scale
    for _, fn in ipairs(pxRefreshers) do
        pcall(fn)
    end
end
-- The commonest shape: a fill sitting one device pixel inside its parent so
-- the parent's border drawable shows as a one-pixel ring. extendRight
-- preserves the scrollbar's engine-rounding extension (see TRACK_RIGHT_EXTEND).
local function RegisterPxInset(fill, parent, extendRight)
    local ext = extendRight or 0
    RegisterPxRefresher(function()
        local b = Px(1)
        fill:RemoveAllAnchors()
        fill:AddAnchor("TOPLEFT", parent, b, b)
        fill:AddAnchor("BOTTOMRIGHT", parent, ext - b, -b)
    end)
end

-- Saved fixed-bar positions (playerBarPos, staticBarPos) are deliberately NOT
-- clamped here. They are raw DEVICE-pixel effective offsets (skill
-- ui-toolkit.md: what you persist after a drag); main.lua clamps them at
-- APPLY time in device space and performs the single device->units division
-- right at the AddAnchor call (anchor offsets are UI units - see
-- ClampToScreen's note there). A clamp here once divided the screen bounds
-- by the scale, which pulled correctly placed bars toward the top-left on
-- the next login ("the bar moves on reload").

local function getCurrentCharacterKey()
    local playerId = api.Unit:GetUnitId("player")
    local playerInfo = api.Unit:GetUnitInfoById(playerId)
    local playerName = playerInfo and playerInfo.name or "Unknown"
    if type(playerName) ~= "string" or playerName == "" then
        playerName = "unknown"
    end
    return string.lower(playerName)
end

-- v0 stored settings flat at the root; v1 added per-character buckets alongside
-- them. A character bucket is a hash (string keys); every v0 table-valued
-- setting is an array (btnSettingsPos, the watched-buff lists).
local function isCharacterBucket(value)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do
        if type(key) == "string" then return true end
    end
    return false
end

-- Migrates v0 (flat) and v1 (per-character) layouts to v2. Runs once, guarded by
-- schemaVersion. The structural half does not need the character name; only the
-- choice of global-settings baseline does, and that falls back when unresolved.
local function migrateSettings(root)
    if type(root) ~= "table" then return end
    if tonumber(root.schemaVersion) == SCHEMA_VERSION then return end

    -- One-time recoverable snapshot of the pre-migration shape
    if root.legacyBackupV1 == nil then
        local backup = {}
        for key, value in pairs(root) do
            backup[key] = value
        end
        root.legacyBackupV1 = backup
    end

    local flatSettings = {}
    local flatPlayerBuffs, flatTargetBuffs
    local charBuckets = {}

    -- Clearing an existing key during pairs() is allowed in Lua; adding is not.
    for key, value in pairs(root) do
        if RESERVED_ROOT_KEYS[key] then -- leave alone
        elseif LEGACY_DEAD_KEYS[key] then
            root[key] = nil
        elseif key == "playerWatchedBuffs" then
            flatPlayerBuffs = value
            root[key] = nil
        elseif key == "targetWatchedBuffs" then
            flatTargetBuffs = value
            root[key] = nil
        elseif isCharacterBucket(value) then
            charBuckets[key] = value
            root[key] = nil
        else
            flatSettings[key] = value
            root[key] = nil
        end
    end

    -- Global settings baseline, lowest priority first: the flat v0 values, then
    -- the misfiled "unknown" bucket, then the active character's own bucket.
    local global = {}
    local function layer(bucket)
        if type(bucket) ~= "table" then return end
        for key, value in pairs(bucket) do
            if key ~= "playerWatchedBuffs" and key ~= "targetWatchedBuffs"
                and key ~= "useCharacterBuffs" and not LEGACY_DEAD_KEYS[key] then
                global[key] = value
            end
        end
    end
    layer(flatSettings)
    layer(charBuckets["unknown"])

    local activeKey = getCurrentCharacterKey()
    if charBuckets[activeKey] then
        layer(charBuckets[activeKey])
    else
        -- Name not resolved yet: only unambiguous when a single real bucket exists
        local onlyKey, count = nil, 0
        for key in pairs(charBuckets) do
            if key ~= "unknown" then
                onlyKey = key
                count = count + 1
            end
        end
        if count == 1 then layer(charBuckets[onlyKey]) end
    end

    -- The v0 root lists were the shared, pre-character-era lists
    global.playerWatchedBuffs = flatPlayerBuffs or {}
    global.targetWatchedBuffs = flatTargetBuffs or {}

    -- Existing characters keep their own lists rather than being forced onto the
    -- new global default; the toggle lets them opt in later without data loss.
    local characters = {}
    for name, bucket in pairs(charBuckets) do
        if name ~= "unknown" then
            characters[name] = {
                useCharacterBuffs = true,
                playerWatchedBuffs = bucket.playerWatchedBuffs or {},
                targetWatchedBuffs = bucket.targetWatchedBuffs or {},
            }
        end
    end

    root.global = global
    root.characters = characters
    root.schemaVersion = SCHEMA_VERSION
    api.Log:Info("TrackThatPlease: settings migrated to schema v" .. SCHEMA_VERSION)
end

-- The root now comes from the private settings store (util/settings_store),
-- not api.GetSettings - see the header there for why. Store.Root() always
-- returns the same session-lifetime table and folds early writes into the
-- persisted content itself, which is what the old detached-root dance here
-- used to do by hand.
local function ensureRoot()
    settingsRoot = Store.Root()
    return settingsRoot
end

local function ensureBuckets()
    local root = ensureRoot()
    migrateSettings(root)

    if type(root.global) ~= "table" then root.global = {} end
    globalSettings = root.global

    -- "experimental" was a third player-bar mode before it became the Nametag
    -- toggle. Anyone who had it selected wanted nameplate compensation, so carry
    -- that across rather than dropping them back to plain Above Head. Idempotent:
    -- once it runs the stored mode is "head", so it cannot fire twice.
    if globalSettings.playerBarMode == "experimental" then
        globalSettings.playerBarMode = "head"
        globalSettings.nametagEnabled = true
    end
    globalSettings.smoothingEnabled = nil -- smoothing was removed
    -- UIScale was a load-time snapshot of api.Interface:GetUIScale() persisted
    -- as a setting - but the scale is not even readable while addons load, and
    -- its only consumer was a hand-tuned per-scale nudge table that correct
    -- anchor-space math (see main.lua's screen helpers) made obsolete. Scrub
    -- the stale key so old saves come out clean.
    globalSettings.UIScale = nil

    if type(root.characters) ~= "table" then root.characters = {} end
    currentCharacterKey = getCurrentCharacterKey()
    if currentCharacterKey ~= "unknown" then
        if type(root.characters[currentCharacterKey]) ~= "table" then
            root.characters[currentCharacterKey] = { useCharacterBuffs = false }
        end
        characterSettings = root.characters[currentCharacterKey]
    else
        -- Never persist an "unknown" bucket; work on a scratch table until the
        -- real character name resolves.
        characterSettings = { useCharacterBuffs = false }
    end
    return root
end

local function usesCharacterBuffs()
    return characterSettings.useCharacterBuffs == true
end

local function getBuffBucket()
    if usesCharacterBuffs() then return characterSettings end
    return globalSettings
end

-- UI elements
local buffSelectionWindow
local buffScrollList
local searchEditBox
local categoryDropdown
local trackTypeDropdown
local filteredCountLabel
local selectAllButton
local recordAllButton

-- Settings
local playerWatchedBuffs = {}
local targetWatchedBuffs = {}
-- The static bar's own list. Fully independent of the player list: the same
-- buff can be on both, or on either alone.
local staticWatchedBuffs = {}

local filteredBuffs = {}
local currentTrackType = 1  -- 1 = Player, 2 = Target, 3 = Both, 4 = Static bar
local isSelectedAll = false

local buffScrollListWidth

-- Scroll and pagination
local pageSize = 50
local categories = {"All static buffs", "All logged buffs", "Watched buffs"}
local trackTypes = {"Player", "Target", "Both", "Static bar"}
local TRACK_TYPE_PLAYER = 1
local TRACK_TYPE_TARGET = 2
-- "Both" keeps the two lists separate on disk and applies every action to each
-- of them; a buff counts as watched only when it is on both. It spans Player
-- and Target only - the static bar's list is always addressed on its own.
local TRACK_TYPE_BOTH = 3
local TRACK_TYPE_STATIC = 4
-- Category types
local CATEGORY_TYPE_ALL = 1
local CATEGORY_TYPE_LOGGED = 2
local CATEGORY_TYPE_WATCHED = 3
-- defaults
local currentCategory = CATEGORY_TYPE_WATCHED  -- as default

-- Helper functions for number serialization
local function SerializeNumber(num)
    return string.format("%.0f", num)
end

local function DeserializeNumber(str)
    return tonumber(str)
end


--============================ ### Settings section ### ==============================--

function BuffSettingsWindow.SaveSettings()
    -- Convert hash tables to serialized arrays for storage. Tracked and merely
    -- listed buffs are stored separately so that unticking one survives a reload
    -- without it reappearing as tracked.
    local serializedPlayerBuffs, serializedPlayerDisabled = {}, {}
    local serializedTargetBuffs, serializedTargetDisabled = {}, {}
    local serializedStaticBuffs, serializedStaticDisabled = {}, {}

    for buffId, enabled in pairs(playerWatchedBuffs) do
        table.insert(enabled and serializedPlayerBuffs or serializedPlayerDisabled,
            SerializeNumber(buffId))
    end

    for buffId, enabled in pairs(targetWatchedBuffs) do
        table.insert(enabled and serializedTargetBuffs or serializedTargetDisabled,
            SerializeNumber(buffId))
    end

    for buffId, enabled in pairs(staticWatchedBuffs) do
        table.insert(enabled and serializedStaticBuffs or serializedStaticDisabled,
            SerializeNumber(buffId))
    end

    ensureBuckets()

    -- Display and behaviour settings are shared by every character
    for key, value in pairs(BuffSettingsWindow.settings) do
        globalSettings[key] = value
    end

    -- Until the character name resolves we cannot know which bucket owns the
    -- lists, and writing them to global would be silently undone once it does.
    -- Settings still save; only the lists wait. Once the retries are exhausted
    -- we stop waiting, otherwise a name that never resolves could never save.
    if currentCharacterKey ~= "unknown" or characterKeyRetries >= 10 then
        local bucket = getBuffBucket()
        bucket.playerWatchedBuffs = serializedPlayerBuffs
        bucket.targetWatchedBuffs = serializedTargetBuffs
        bucket.playerDisabledBuffs = serializedPlayerDisabled
        bucket.targetDisabledBuffs = serializedTargetDisabled
        bucket.staticWatchedBuffs = serializedStaticBuffs
        bucket.staticDisabledBuffs = serializedStaticDisabled
    end


    -- Persist through the private store (never api.SaveSettings - see
    -- util/settings_store.lua). Save() cannot throw; no pcall needed.
    Store.Save()
end

-- Slider drags fire a change per tick; debounce the full settings flush
local savePending = false
local function queueSave()
    if savePending then return end
    savePending = true
    api:DoIn(600, function()
        savePending = false
        BuffSettingsWindow.SaveSettings()
    end)
end

local loadSettings

-- Assigned in Initialize, once the scroll list and its widgets exist. Lets the
-- character-key retry below refresh the UI without forward-declaring every widget.
local refreshWatchedUI = function() end
local refreshBuffScopeButton = function() end
-- Custom pager (the engine page control is hidden); assigned in Initialize
local refreshPager = function() end
local currentTotalPages = 1

local function buildDefaultSettings()
    -- btnSettingsPos is gone: the floating HUD button it positioned was removed in
    -- favour of the ESC menu entry. Any stale value left in a settings file is
    -- simply ignored.
    return {
        fontSize = 16,
        targetBuffVerticalOffset = -46,
        playerBuffVerticalOffset = -46,
        -- iconSize is the PLAYER bars' size (kept under its old name so
        -- existing files load unchanged); the target bar has its own. The
        -- static bar is a player bar, so it follows iconSize.
        iconSize = 30,
        targetIconSize = 30,
        iconSpacing = 5,
        maxBuffsShown = 10,
        debuffWarnTime = 7000,
        buffWarnTime = 7000,
        shouldShowStacks = true,
        -- Whether the player has their own nameplate turned on. With it on the
        -- game's overhead anchor wanders and the bar has to compensate; with it
        -- off, plain Above Head tracking is already correct.
        --
        -- On by default because most players run with their nameplate showing.
        -- Anyone who does not should turn it off: it corrects a wander that is
        -- not there for them, and leaving it on is a small regression.
        nametagEnabled = true,
        playerBarMode = "head", -- "head" follows the character; "fixed" pins to screen
        -- Raw DEVICE pixels, the same space the persisted drag offsets use;
        -- main.lua converts device->units once, at the AddAnchor call (see
        -- ClampToScreen's note). Screen dims are readable at load, so no
        -- load-time caveat here.
        playerBarPos = { math.floor(api.Interface:GetScreenWidth() / 2 - 80),
                         math.floor(api.Interface:GetScreenHeight() * 0.6) },
        -- The second, always-fixed player bar. Off by default; its list starts
        -- empty, so even enabled it shows nothing until buffs are added to it.
        staticBarEnabled = false,
        -- Its own icon size (the slider lives in the Configure popup); the
        -- other display settings stay shared with the main bars
        staticIconSize = 30,
        -- Below the default playerBarPos so the two do not stack when both
        -- are first placed. Same device space as playerBarPos.
        staticBarPos = { math.floor(api.Interface:GetScreenWidth() / 2 - 80),
                         math.floor(api.Interface:GetScreenHeight() * 0.7) },
    }
end

local function ensureType(value, defaultValue)
    if type(defaultValue) == "number" then
        -- numbers
        return tonumber(value) or defaultValue
    elseif type(defaultValue) == "boolean" then
        -- boolean
        if type(value) == "boolean" then return value end
        if type(value) == "string" then return value == "true" end
        return defaultValue
    else
        -- string and tables
        return type(value) == type(defaultValue) and value or defaultValue
    end
end

local function applyClamps(settings)
    for key, range in pairs(SETTING_CLAMPS) do
        if type(settings[key]) == "number" then
            settings[key] = clampNumber(settings[key], range[1], range[2])
        end
    end
    -- playerBarPos/staticBarPos: clamped at apply time in main.lua, see the
    -- note above getCurrentCharacterKey
end

-- Reads the watched lists out of whichever bucket is active for this character.
-- Files written before the listed/tracked split simply have no disabled arrays,
-- so everything in them loads as tracked, exactly as before.
local function loadWatchedBuffs()
    local bucket = getBuffBucket()

    local function fill(target, enabledKey, disabledKey)
        for _, idString in ipairs(bucket[enabledKey] or {}) do
            local buffId = DeserializeNumber(idString)
            if buffId then
                target[buffId] = true
            end
        end
        for _, idString in ipairs(bucket[disabledKey] or {}) do
            local buffId = DeserializeNumber(idString)
            if buffId and target[buffId] == nil then
                target[buffId] = false
            end
        end
    end

    playerWatchedBuffs = {}
    fill(playerWatchedBuffs, "playerWatchedBuffs", "playerDisabledBuffs")

    targetWatchedBuffs = {}
    fill(targetWatchedBuffs, "targetWatchedBuffs", "targetDisabledBuffs")

    -- Absent in every pre-static file, so this loads as an empty list there
    staticWatchedBuffs = {}
    fill(staticWatchedBuffs, "staticWatchedBuffs", "staticDisabledBuffs")
end

-- Display settings are global, so they load immediately. Only the watched lists
-- depend on the character name, which is not always resolvable at OnLoad time -
-- retry until it is, then swap just the lists into place.
local function retryCharacterKeyLoad()
    if getCurrentCharacterKey() ~= "unknown" then
        ensureBuckets()
        loadWatchedBuffs()
        refreshBuffScopeButton()
        refreshWatchedUI()
    elseif characterKeyRetries < 10 then
        characterKeyRetries = characterKeyRetries + 1
        api:DoIn(1000, retryCharacterKeyLoad)
    end
end

loadSettings = function()
    local defaultSettings = buildDefaultSettings()

    ensureBuckets()

    -- Safe initialization of settings
    BuffSettingsWindow.settings = {}
    for k, defaultValue in pairs(defaultSettings) do
        BuffSettingsWindow.settings[k] = ensureType(globalSettings[k], defaultValue)
    end

    -- Files from before the player/target size split carry only iconSize. Seed
    -- the target size from it rather than the default, so a player who ran
    -- icon size 35 keeps a 35 target bar instead of it snapping back to 30.
    if globalSettings.targetIconSize == nil then
        BuffSettingsWindow.settings.targetIconSize = BuffSettingsWindow.settings.iconSize
    end

    applyClamps(BuffSettingsWindow.settings)

    loadWatchedBuffs()

    -- Character name not available yet: schedule a reload of the watched lists
    if currentCharacterKey == "unknown" and characterKeyRetries < 10 then
        characterKeyRetries = characterKeyRetries + 1
        api:DoIn(1000, retryCharacterKeyLoad)
    end
end

-- Switches this character between the shared global lists and its own. The first
-- switch to per-character seeds from the global list so nothing visibly changes;
-- switching back leaves the character list on disk, so the toggle is lossless.
function BuffSettingsWindow.SetUseCharacterBuffs(useCharacter)
    ensureBuckets()
    if currentCharacterKey == "unknown" then return false end

    -- Flush the lists currently in memory to the bucket they came from
    BuffSettingsWindow.SaveSettings()

    if useCharacter and characterSettings.playerWatchedBuffs == nil
        and characterSettings.targetWatchedBuffs == nil then
        for _, key in ipairs({ "playerWatchedBuffs", "targetWatchedBuffs",
                               "playerDisabledBuffs", "targetDisabledBuffs",
                               "staticWatchedBuffs", "staticDisabledBuffs" }) do
            local seed = {}
            for _, id in ipairs(globalSettings[key] or {}) do
                table.insert(seed, id)
            end
            characterSettings[key] = seed
        end
    end

    characterSettings.useCharacterBuffs = useCharacter and true or false
    loadWatchedBuffs()
    Store.Save()
    return true
end

-- Replaces the shared global lists with this character's lists, making them the
-- baseline every other character inherits. Copies the entries rather than sharing
-- the tables, so later per-character edits do not leak into global.
-- Returns false if there is no character list to promote.
function BuffSettingsWindow.PromoteCharacterBuffsToGlobal()
    ensureBuckets()
    if currentCharacterKey == "unknown" then return false end
    if not usesCharacterBuffs() then return false end

    -- Flush what is in memory to the character bucket before copying it out
    BuffSettingsWindow.SaveSettings()

    for _, key in ipairs({ "playerWatchedBuffs", "targetWatchedBuffs",
                           "playerDisabledBuffs", "targetDisabledBuffs",
                           "staticWatchedBuffs", "staticDisabledBuffs" }) do
        local promoted = {}
        for _, id in ipairs(characterSettings[key] or {}) do
            table.insert(promoted, id)
        end
        globalSettings[key] = promoted
    end

    Store.Save()
    return true
end

-- Mirror of PromoteCharacterBuffsToGlobal: overwrites this character's stored
-- lists with the shared global ones. Entries are copied, not shared by reference.
-- Returns false if there is no resolved character to copy into.
function BuffSettingsWindow.CopyGlobalBuffsToCharacter()
    ensureBuckets()
    if currentCharacterKey == "unknown" then return false end

    -- Flush what is in memory to whichever bucket currently owns it
    BuffSettingsWindow.SaveSettings()

    for _, key in ipairs({ "playerWatchedBuffs", "targetWatchedBuffs",
                           "playerDisabledBuffs", "targetDisabledBuffs",
                           "staticWatchedBuffs", "staticDisabledBuffs" }) do
        local copied = {}
        for _, id in ipairs(globalSettings[key] or {}) do
            table.insert(copied, id)
        end
        characterSettings[key] = copied
    end

    -- Only changes what is on screen if this character reads from its own list
    if usesCharacterBuffs() then
        loadWatchedBuffs()
    end

    Store.Save()
    return true
end

function BuffSettingsWindow.IsUsingCharacterBuffs()
    return usesCharacterBuffs()
end

-- ===== Sharing =====
-- api.File round-trips plain strings (see util/buff_logger.lua), so the exchange
-- format is readable text rather than a serialized table - it can be sent as a
-- file or just pasted into chat:
--
--   TTP-WATCHLIST v1
--   player=14743,715,6601
--   target=6422,6430
--
-- Export and import share one filename so a received list can be dropped in and
-- imported without renaming. The cost is that exporting overwrites a list someone
-- sent you, so the previous contents are kept in SHARE_BACKUP_PATH.
local SHARE_PATH = "TrackThatPlease/watchlist.txt"
local SHARE_BACKUP_PATH = "TrackThatPlease/watchlist_previous.txt"

BuffSettingsWindow.SHARE_PATH = SHARE_PATH
BuffSettingsWindow.SHARE_BACKUP_PATH = SHARE_BACKUP_PATH

-- Writes the lists this character is currently using. Returns the two counts,
-- plus true when an existing different list was moved aside first.
-- Returns nil if the file could not be written.
function BuffSettingsWindow.ExportWatchedBuffs()
    ensureBuckets()
    BuffSettingsWindow.SaveSettings()

    -- Untracked-but-listed entries travel too, on their own lines, so a shared
    -- list arrives with the same layout the sender curated.
    local playerIds, targetIds, staticIds = {}, {}, {}
    local playerOff, targetOff, staticOff = {}, {}, {}
    for buffId, enabled in pairs(playerWatchedBuffs) do
        table.insert(enabled and playerIds or playerOff, SerializeNumber(buffId))
    end
    for buffId, enabled in pairs(targetWatchedBuffs) do
        table.insert(enabled and targetIds or targetOff, SerializeNumber(buffId))
    end
    for buffId, enabled in pairs(staticWatchedBuffs) do
        table.insert(enabled and staticIds or staticOff, SerializeNumber(buffId))
    end

    -- Still v1: the static lines are additive, and importers match section names
    -- rather than counting lines, so a 3.1 build reads this file and simply
    -- never looks at the static sections. Naming note: mergeSection matches
    -- "<name>=" unanchored, so no section name may be another name with extra
    -- characters glued on the FRONT ("mystatic=" would satisfy a "static="
    -- match); suffixes like "staticoff" are safe because the "=" ends the match.
    local content = table.concat({
        "TTP-WATCHLIST v1",
        "player=" .. table.concat(playerIds, ","),
        "target=" .. table.concat(targetIds, ","),
        "playeroff=" .. table.concat(playerOff, ","),
        "targetoff=" .. table.concat(targetOff, ","),
        "static=" .. table.concat(staticIds, ","),
        "staticoff=" .. table.concat(staticOff, ","),
    }, "\n")

    -- Preserve whatever was there, so exporting over a received list is recoverable
    local backedUp = false
    local readOk, existing = pcall(function() return api.File:Read(SHARE_PATH) end)
    if readOk and type(existing) == "string" and existing ~= "" and existing ~= content then
        backedUp = pcall(function() api.File:Write(SHARE_BACKUP_PATH, existing) end)
    end

    local ok = pcall(function() api.File:Write(SHARE_PATH, content) end)
    if not ok then return nil end
    return #playerIds, #targetIds, backedUp
end

-- Merges a shared list into the lists this character is using. Additive on
-- purpose: importing never drops buffs the user already watches. Returns the
-- number of newly added ids, or nil if the file is missing or unreadable.
function BuffSettingsWindow.ImportWatchedBuffs()
    ensureBuckets()

    local ok, data = pcall(function() return api.File:Read(SHARE_PATH) end)
    if not ok or type(data) ~= "string" or data == "" then return nil end

    local function mergeSection(name, target, enabled)
        local added = 0
        local list = data:match(name .. "=([^\n\r]*)")
        if not list then return 0 end
        -- Match digit runs rather than splitting on separators: api.File:Write
        -- serialises the string, so a raw read can leave a trailing escape on the
        -- line ("...,674\") and splitting would drop the last id of every line.
        for idString in list:gmatch("%d+") do
            local buffId = DeserializeNumber(idString)
            -- Only fill gaps: an entry the user already listed keeps its own
            -- tracked/untracked state rather than being overwritten by the import.
            if buffId and target[buffId] == nil then
                target[buffId] = enabled
                added = added + 1
            end
        end
        return added
    end

    local addedPlayer = mergeSection("player", playerWatchedBuffs, true)
    local addedTarget = mergeSection("target", targetWatchedBuffs, true)
    addedPlayer = addedPlayer + mergeSection("playeroff", playerWatchedBuffs, false)
    addedTarget = addedTarget + mergeSection("targetoff", targetWatchedBuffs, false)
    -- Static entries ride the player count for the summary message: files from
    -- 3.1 and earlier simply have no static sections, so this adds zero there.
    addedPlayer = addedPlayer + mergeSection("static", staticWatchedBuffs, true)
    addedPlayer = addedPlayer + mergeSection("staticoff", staticWatchedBuffs, false)

    BuffSettingsWindow.SaveSettings()
    return addedPlayer, addedTarget
end

function BuffSettingsWindow.GetCharacterKey()
    return currentCharacterKey
end

-- The recording indicator lives next to the logging button inside this window;
-- main.lua owns the blink animation and reaches it through here.
function BuffSettingsWindow.GetRecordingIcon()
    return recordAllButton and recordAllButton.recordingIndicationIcon or nil
end
--============================ ### End ### ==============================--

--============================ ### Track-type helpers ### ==============================--
-- Every action in the list obeys the Track type dropdown. Centralised here so the
-- Player/Target/Both rule is stated once instead of at each of the seven call sites.

-- The watched-buff sets the current track type acts on
local function activeWatchSets()
    if currentTrackType == TRACK_TYPE_TARGET then
        return { targetWatchedBuffs }
    elseif currentTrackType == TRACK_TYPE_BOTH then
        return { playerWatchedBuffs, targetWatchedBuffs }
    elseif currentTrackType == TRACK_TYPE_STATIC then
        return { staticWatchedBuffs }
    end
    return { playerWatchedBuffs }
end

-- The watched sets map buffId -> boolean, where the KEY's presence means "on the
-- list" and the VALUE means "currently tracked". Unchecking a buff sets it to
-- false and keeps it listed, so it stays in the Watched view ready to be ticked
-- again; only the row's X button removes the key outright.

-- Under "Both" a buff only reads as watched when it is tracked on both lists, so
-- a single click can bring a half-watched buff to a consistent state.
local function isWatchedForCurrentType(buffId)
    for _, set in ipairs(activeWatchSets()) do
        if set[buffId] ~= true then return false end
    end
    return true
end

local function setWatchedForCurrentType(buffId, watched)
    for _, set in ipairs(activeWatchSets()) do
        set[buffId] = watched and true or false
    end
end

-- Drops the buff from the list entirely (the row's X button)
local function removeFromListForCurrentType(buffId)
    for _, set in ipairs(activeWatchSets()) do
        set[buffId] = nil
    end
end

--============================ ### Scroll list functions ### ==============================--
local function updateSelectAllButton()
    if selectAllButton then

        if #filteredBuffs == 0 then
            selectAllButton:Show(false)
            return
        else
            selectAllButton:Show(true)
        end

        -- Check if there are too many buffs (performance protection)
        local tooManyBuffs = #filteredBuffs > 200

        if tooManyBuffs then
            -- Disable button when too many buffs
            if selectAllButton.Enable then selectAllButton:Enable(false) end
            selectAllButton:SetFlatText("Too many buffs")
            selectAllButton:SetFlatTextColor(0.5, 0.5, 0.5, 1) -- Gray text
        else
            -- Enable button and check selection state
            if selectAllButton.Enable then selectAllButton:Enable(true) end
            selectAllButton:SetFlatTextColor(1, 1, 1, 1) -- Normal text color

            local allSelected = false
            if #filteredBuffs > 0 then
                allSelected = true
                for _, buff in ipairs(filteredBuffs) do
                    if not isWatchedForCurrentType(buff.id) then
                        allSelected = false
                        break
                    end
                end
            end

            selectAllButton:SetFlatText(allSelected and "Unselect All" or "Select All")
        end
    end
end

-- Update the appearance of a buff icon
local function UpdateBuffSelectedAppearance(subItem, buffId)
    if not subItem.checkFill then return end
    if isWatchedForCurrentType(buffId) then
        subItem.checkFill:SetColor(0, 0.75, 0.75, 1)      -- cyan accent = tracked
    else
        subItem.checkFill:SetColor(0.14, 0.14, 0.16, 1)   -- listed but not tracked
    end
end

local function updatePageCount(totalItems)
    local maxPages = math.ceil(totalItems / pageSize)
    if maxPages < 1 then maxPages = 1 end
    buffScrollList:SetPageByItemCount(totalItems, pageSize)
    buffScrollList.pageControl:SetPageCount(maxPages)
    if buffScrollList.curPageIdx and buffScrollList.curPageIdx > maxPages then
        -- Keep the addon's own index in step with the engine's, or the next
        -- refresh reads the stale one straight back
        buffScrollList.curPageIdx = maxPages
        buffScrollList:SetCurrentPage(maxPages)
    end
    currentTotalPages = maxPages
    refreshPager()
end

-- Fill buff data for the scroll list
local function fillBuffData(buffScrollList, pageIndex, searchText)
    local startingIndex = ((pageIndex - 1) * pageSize) + 1 
    buffScrollList:DeleteAllDatas()
    
    local count = 1
    filteredBuffs = {}
    
    -- Search matches the NAME or the ID. The id is stringified with "%.0f"
    -- (never tostring - see buff_logger: this client's tostring renders ~6
    -- significant figures, so an 8-digit id becomes "9.53429e+07"), so the
    -- number the logger announces in chat is exactly what can be typed here.
    --
    -- All matching is PLAIN (find's 4th arg) and the prefix tests use sub()
    -- rather than a "^" pattern: the search box is free text, and a player
    -- typing "(" or "%" used to hand string.find a malformed pattern, which
    -- raises an error rather than simply not matching.
    local function addBuff(buff)
        local relevanceScore = 0
        local matched = (searchText == "")

        if not matched then
            local lowerName = (buff.name or ""):lower()
            local lowerSearch = searchText:lower()
            local idText = string.format("%.0f", tonumber(buff.id) or 0)

            -- ID first: an all-digit search is almost certainly an id lookup,
            -- and an exact id hit should outrank every name hit.
            if idText == searchText then
                matched, relevanceScore = true, 2000
            elseif idText:sub(1, #searchText) == searchText then
                matched, relevanceScore = true, 1500
            elseif string.find(idText, searchText, 1, true) then
                matched, relevanceScore = true, 1200
            elseif lowerName == lowerSearch then
                matched, relevanceScore = true, 1000
            elseif lowerName:sub(1, #lowerSearch) == lowerSearch then
                matched, relevanceScore = true, 500
            elseif string.find(lowerName, lowerSearch, 1, true) then
                -- Shorter names with match get higher score
                matched, relevanceScore = true, 100 + (100 - string.len(buff.name or ""))
            end
        end

        if matched then
            -- Add relevance score to buff data
            local buffWithScore = {
                id = buff.id,
                name = buff.name,
                iconPath = buff.iconPath,
                description = buff.description,
                relevanceScore = relevanceScore
            }
            table.insert(filteredBuffs, buffWithScore)
        end
    end

    if currentCategory == CATEGORY_TYPE_ALL then
        for _, buff in ipairs(BuffList.AllBuffs) do
            addBuff(buff)
        end
    elseif currentCategory == CATEGORY_TYPE_WATCHED then
        -- Under "Both" this is the union of the two lists, so a buff watched on
        -- only one of them stays visible and can still be removed.
        local seen = {}
        for _, set in ipairs(activeWatchSets()) do
            for buffId, _ in pairs(set) do
                if not seen[buffId] then
                    seen[buffId] = true
                    local buff = BuffList.AllBuffsIndex[buffId]
                    if buff then
                        addBuff(buff)
                    end
                end
            end
        end
    elseif currentCategory == CATEGORY_TYPE_LOGGED then
        local loggedBuffs = BuffsLogger.GetBuffsSetCopy()

        for buffId, buff in pairs(loggedBuffs) do
            addBuff(buff)
        end
    end
    
    -- Re-clamp the page against the list that actually came back. Callers that
    -- rebuild the list - switching category, searching, changing track type -
    -- pass page 1, but curPageIdx is the addon's own field and only the pager
    -- ever wrote it, so it stayed parked on whatever deep page the previous
    -- category was showing. Every later refresh reads it back (see its callers),
    -- so a 1-page list viewed after page 5 of the static index came up empty.
    -- Clamping before updatePageCount also stops it from calling SetCurrentPage,
    -- which would re-enter this through OnPageChangedProc.
    local maxPages = math.max(1, math.ceil(#filteredBuffs / pageSize))
    if pageIndex > maxPages then pageIndex = maxPages end
    if pageIndex < 1 then pageIndex = 1 end
    buffScrollList.curPageIdx = pageIndex
    startingIndex = ((pageIndex - 1) * pageSize) + 1

    updatePageCount(#filteredBuffs)

    -- Update count label
    if filteredCountLabel then
        if #filteredBuffs > pageSize then
            -- Show pagination format when more than one page
            local currentPage = pageIndex
            local startIndex = ((currentPage - 1) * pageSize) + 1
            local endIndex = math.min(startIndex + pageSize - 1, #filteredBuffs)
            filteredCountLabel:SetText(string.format("Displayed: %d-%d / %d", startIndex, endIndex, #filteredBuffs))
        else
            -- Show simple count when one page or less
            filteredCountLabel:SetText(string.format("Displayed: %d", #filteredBuffs))
        end
    end
    
    -- Update select all button text
    updateSelectAllButton()

    if #filteredBuffs <= 400 and #filteredBuffs > 0 then
        -- Sort by relevance score (highest first), then alphabetically
        table.sort(filteredBuffs, function(a, b)
            if a.relevanceScore ~= b.relevanceScore then
                return a.relevanceScore > b.relevanceScore  -- Higher score first
            else
                return string.lower(a.name) < string.lower(b.name)  -- Alphabetical as tiebreaker
            end
        end)
    end

    for i = startingIndex, math.min(startingIndex + pageSize - 1, #filteredBuffs) do
        local buff = filteredBuffs[i]
        if buff then
            -- The logged category yields entries straight from the logger file,
            -- which carries no classification, so fall back to the index for it.
            local indexed = BuffList.AllBuffsIndex and BuffList.AllBuffsIndex[buff.id]
            local buffData = {
                id = buff.id,
                name = buff.name,
                iconPath = buff.iconPath,
                description = buff.description,
                category = buff.category or (indexed and indexed.category),
                isViewData = true,
                isAbstention = false
            }
            buffScrollList:InsertData(count, 1, buffData, false)
            count = count + 1
        end
    end
end

-- Set data for each buff item in the list
local function DataSetFunc(subItem, data, setValue)
    if setValue then
        -- Border thicknesses use the LIVE scale (see UpdatePxGeometry): row
        -- creation ran at load, when the scale still reads 1, so the device-
        -- pixel geometry is re-applied on every fill
        if subItem.UpdatePxGeometry then subItem:UpdatePxGeometry() end

        local id = data.id
        subItem.id = id
        subItem.description = data.description

        local formattedText = string.format(
            "%s |cFFFFE4B5[%d]|r",
            data.name,
            data.id
        )

        -- Buff or debuff, on the icon border. The classification comes from the
        -- client dump, so it is known for entries that have never been seen in
        -- play - the live isBuff flag only exists for a buff actually on a unit.
        -- Same green/red the tracked bar icons use.
        if subItem.catBorders then
            local r, g, b, a = 1, 1, 1, 0 -- unclassified: let the skin's frame show
            if data.category == "Buff" then
                r, g, b, a = 0.15, 0.85, 0.30, 0.95
            elseif data.category == "Debuff" then
                r, g, b, a = 0.90, 0.22, 0.22, 0.95
            end
            for _, d in ipairs(subItem.catBorders) do
                d:SetColor(r, g, b, a)
            end
        end
        
        subItem.textbox:SetText(formattedText)
        F_SLOT.SetIconBackGround(subItem.subItemIcon, data.iconPath)

        -- Removing only applies to the curated Watched list (see LayoutSetFunc)
        if subItem.removeBtn then
            subItem.removeBtn:Show(currentCategory == CATEGORY_TYPE_WATCHED)
        end

        UpdateBuffSelectedAppearance(subItem, id)
    end
end

-- Create layout for each buff item in the list
local function LayoutSetFunc(frame, rowIndex, colIndex, subItem)
    local rowHeight = 80
    subItem:SetExtent(buffScrollListWidth - 150, rowHeight) 

    -- Row background. The game atlas sprite this used to draw followed whichever
    -- in-game UI skin the player had selected, so it is replaced by the same flat
    -- border+fill the panels and buttons use.
    --
    -- The old sprite spanned TOPLEFT +4 to BOTTOMRIGHT +4, i.e. the full slot
    -- height shifted down, which left neighbouring rows touching. Insetting the
    -- fill top and bottom puts a gap between rows instead: 4px each side, so 8px
    -- of clear space, which keeps neighbouring icons from crowding each other.
    local bgBorder = subItem:CreateColorDrawable(0, 0, 0, 0.92, "background")
    bgBorder:AddAnchor("TOPLEFT", subItem, -70, 4)
    bgBorder:AddAnchor("BOTTOMRIGHT", subItem, -70, -4)
    local bgFill = subItem:CreateColorDrawable(0.085, 0.085, 0.10, 0.96, "background")
    bgFill:AddAnchor("TOPLEFT", subItem, -69, 5)
    bgFill:AddAnchor("BOTTOMRIGHT", subItem, -71, -5)

    -- Icon ----------------------
    -- Sized to leave clearance inside the row slot, and vertically centred: the
    -- checkmark and the remove button both anchor off this icon, so the old +2
    -- nudge pushed all three of them below the row's centre line.
    local iconSize = 30
    local subItemIcon = CreateItemIconButton("subItemIcon", subItem)
    subItemIcon:SetExtent(iconSize, iconSize)
    subItemIcon:Show(true)
    -- Skinless on purpose (dawnsdrop's icons prove CreateItemIconButton needs
    -- no slot skin): the skin's pale frame scales in UI units and cannot be
    -- recoloured, which forced the buff/debuff edges below to be a >=2-unit
    -- COVER over it - the reason they went chunky above 100% scale. With no
    -- skin there is nothing to cover, and the edges can be a true one device
    -- pixel at every scale, the BetterBars discipline.
    subItemIcon:AddAnchor("LEFT", subItem, 5, 0)

    -- Buff/debuff border: four drawables on the overlay layer, each with a
    -- single anchor and a fixed extent, laid ON the icon's edge. DataSetFunc
    -- sets the colour per row; an unclassified row leaves them at alpha 0.
    local borderSize = 1
    local function edge(point, w, h)
        local d = subItemIcon:CreateColorDrawable(1, 1, 1, 0, "overlay")
        d:SetExtent(w, h)
        d:AddAnchor(point, subItemIcon, point, 0, 0)
        return d
    end
    subItem.catBorders = {
        edge("TOPLEFT", iconSize, borderSize),
        edge("BOTTOMLEFT", iconSize, borderSize),
        edge("TOPLEFT", borderSize, iconSize),
        edge("TOPRIGHT", borderSize, iconSize),
    }

    -- Setup tooltip ---------------------------------
    function subItemIcon:OnEnter()
        if not subItem.description or string.len(subItem.description) == 0 then
            return
        end
        -- get back line carriages
        local formattedDescription = string.gsub(subItem.description, "\\n", "\n")

        local PosX, PosY = self:GetOffset()
        api.Interface:SetTooltipOnPos(formattedDescription, subItem.subItemIcon, PosX, PosY + 5)
    end
    function subItemIcon:OnLeave()
        local PosX, PosY = self:GetOffset()
        api.Interface:SetTooltipOnPos(nil, subItem.subItemIcon, PosX, PosY + 5)
    end
    subItemIcon:SetHandler("OnEnter", subItemIcon.OnEnter)
    subItemIcon:SetHandler("OnLeave", subItemIcon.OnLeave)
    -- -------------------------------------------------
 

    subItem.subItemIcon = subItemIcon

    -- textbox for name --------------------------------
    local nameTextbox = subItem:CreateChildWidget("textbox", "nameTextbox", 0, true)
    nameTextbox:AddAnchor("LEFT", subItemIcon, "RIGHT", 5, 0)  -- after icon
    nameTextbox:AddAnchor("RIGHT", subItem, -80, 0)
    nameTextbox.style:SetAlign(ALIGN.LEFT)
    nameTextbox.style:SetFontSize(14)
    ApplyTextColor(nameTextbox, FONT_COLOR.WHITE)
    nameTextbox:SetAutoWordwrap(true)
    nameTextbox:SetLineSpace(2)
    subItem.textbox = nameTextbox

    -- Tracked indicator. Was a sprite from the game HUD atlas, which changed with
    -- the player's UI skin; now a flat box whose fill carries the state.
    -- 1px outline, matching the remove button's border weight
    local checkBorder = subItem:CreateColorDrawable(0, 0, 0, 0.92, "overlay")
    checkBorder:SetExtent(14, 14)
    checkBorder:AddAnchor("LEFT", subItemIcon, "RIGHT", buffScrollListWidth - 145, 0)
    local checkFill = subItem:CreateColorDrawable(0.14, 0.14, 0.16, 1, "overlay")
    checkFill:SetExtent(12, 12)
    checkFill:AddAnchor("LEFT", subItemIcon, "RIGHT", buffScrollListWidth - 144, 0)
    subItem.checkFill = checkFill

    local clickOverlay = subItem:CreateChildWidget("button", "clickOverlay", 0, true)
    clickOverlay:AddAnchor("TOPLEFT", subItem, 45, 0)  -- Відступ 45 пікселів зліва
    clickOverlay:AddAnchor("BOTTOMRIGHT", subItem, 0, 0)

    function clickOverlay:OnClick()
        local buffId = subItem.id
        BuffSettingsWindow.ToggleBuffWatch(buffId)
        UpdateBuffSelectedAppearance(subItem, buffId)
        -- The row deliberately stays put when unticked, so the buff can be ticked
        -- again without hunting for it a second time. The X button removes it.
        updateSelectAllButton()
        BuffSettingsWindow.SaveSettings()
    end
    clickOverlay:SetHandler("OnClick", clickOverlay.OnClick)

    -- Remove-from-list button. Only meaningful in the Watched category: "All
    -- static buffs" is the immutable index, and the logged list is rebuilt on
    -- reload, so there is nothing to remove from in either.
    --
    -- Positioned just past the checkmark, using the same subItemIcon-relative
    -- offset the checkmark itself uses. subItem is only
    -- (buffScrollListWidth - 150) wide while the row's visible content runs past
    -- it, so anchoring to subItem's right edge lands in dead space; and the
    -- checkmark is a drawable, which is not a valid anchor target for a widget.
    local removeBtn = subItem:CreateChildWidget("button", "removeBtn", 0, true)
    removeBtn:SetExtent(18, 18)
    removeBtn:AddAnchor("LEFT", subItemIcon, "RIGHT", buffScrollListWidth - 97, 0)
    removeBtn:SetText("")
    local removeBorder = removeBtn:CreateColorDrawable(0, 0, 0, 0.92, "background")
    removeBorder:AddAnchor("TOPLEFT", removeBtn, 0, 0)
    removeBorder:AddAnchor("BOTTOMRIGHT", removeBtn, 0, 0)
    local removeFill = removeBtn:CreateColorDrawable(0.38, 0.12, 0.12, 0.95, "background")
    removeFill:AddAnchor("TOPLEFT", removeBtn, 1, 1)
    removeFill:AddAnchor("BOTTOMRIGHT", removeBtn, -1, -1)
    local removeLabel = removeBtn:CreateChildWidget("label", "removeBtnLabel", 0, true)
    removeLabel:SetExtent(16, 14)
    removeLabel:AddAnchor("CENTER", removeBtn, 0, 0)
    removeLabel:SetText("x")
    removeLabel.style:SetFontSize(13)
    removeLabel.style:SetAlign(ALIGN.CENTER)
    removeLabel.style:SetColor(1, 1, 1, 1)
    removeLabel:Clickable(false)
    subItem.removeBtn = removeBtn
    removeBtn:Show(currentCategory == CATEGORY_TYPE_WATCHED)

    function removeBtn:OnClick()
        local buffId = subItem.id
        if not buffId then return end
        removeFromListForCurrentType(buffId)
        BuffSettingsWindow.SaveSettings()
        -- This one does re-fill: the entry is gone, so the row must go with it
        fillBuffData(buffScrollList, buffScrollList.curPageIdx or 1, searchEditBox:GetText())
    end
    removeBtn:SetHandler("OnClick", removeBtn.OnClick)

    -- Device-pixel geometry (UI_SCALING.md rules). Everything above laid the
    -- row out in UI units with 1-unit border rings and a 2-unit category
    -- cover; this re-applies those thicknesses through the LIVE scale. It
    -- cannot run just once here: rows are built at OnLoad, when the scale is
    -- not yet readable (reads 1), so DataSetFunc re-runs it on every fill -
    -- the window cannot become visible without one, and a mid-session scale
    -- change is picked up on the next refresh the same way.
    function subItem:UpdatePxGeometry()
        local b = Px(1)

        -- Row outline: outer rect stays in UI units (it is layout, anchored
        -- to the row slot); the ring is held at one device pixel by insetting
        -- the fill by the live Px(1) off the same offsets
        bgFill:RemoveAllAnchors()
        bgFill:AddAnchor("TOPLEFT", subItem, -70 + b, 4 + b)
        bgFill:AddAnchor("BOTTOMRIGHT", subItem, -70 - b, -4 - b)

        -- Buff/debuff edge: one device pixel at every scale. The old
        -- max(Px(2), 2) sizing existed only to cover the slot skin's pale
        -- frame, and the icon is skinless now (see LayoutSetFunc).
        local t = Px(1)
        subItem.catBorders[1]:SetExtent(iconSize, t)
        subItem.catBorders[2]:SetExtent(iconSize, t)
        subItem.catBorders[3]:SetExtent(t, iconSize)
        subItem.catBorders[4]:SetExtent(t, iconSize)

        -- Checkbox ring at one device pixel each side. The LEFT anchor
        -- centres the fill vertically, so the shrunken height carries the
        -- top/bottom ring on its own; only the x offset needs the inset.
        checkFill:SetExtent(14 - 2 * b, 14 - 2 * b)
        checkFill:RemoveAllAnchors()
        checkFill:AddAnchor("LEFT", subItemIcon, "RIGHT", buffScrollListWidth - 145 + b, 0)

        -- Remove-button ring, same treatment
        removeFill:RemoveAllAnchors()
        removeFill:AddAnchor("TOPLEFT", removeBtn, b, b)
        removeFill:AddAnchor("BOTTOMRIGHT", removeBtn, -b, -b)
    end
    subItem:UpdatePxGeometry()
end
--============================ ### End ### ==============================--

--============================ ### BuffWatchWindow external functions ### ==============================--
-- Drop a buff from the list the current track type covers (the row's X button)
function BuffSettingsWindow.RemoveBuffFromList(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    removeFromListForCurrentType(buffId)
end

-- Toggle a buff's watched status based on current tracking type
function BuffSettingsWindow.ToggleBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))

    -- Under "Both", a buff on only one list is completed onto both by the first
    -- click; a second click clears it from both.
    setWatchedForCurrentType(buffId, not isWatchedForCurrentType(buffId))
end

-- Toggle a player buff's watched status
function BuffSettingsWindow.TogglePlayerBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    -- Untracking keeps the buff on the list (value false) so it stays visible in
    -- the Watched view; use RemoveBuffFromList to drop it entirely.
    playerWatchedBuffs[buffId] = playerWatchedBuffs[buffId] ~= true
end

-- Toggle a target buff's watched status
function BuffSettingsWindow.ToggleTargetBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    -- See TogglePlayerBuffWatch: untracking keeps the entry listed
    targetWatchedBuffs[buffId] = targetWatchedBuffs[buffId] ~= true
end

-- Check if a player buff is being watched
function BuffSettingsWindow.IsPlayerBuffWatched(buffId)
    -- not needed
    --buffId = DeserializeNumber(SerializeNumber(buffId))
    return playerWatchedBuffs[buffId] == true
end

-- Check if a target buff is being watched
function BuffSettingsWindow.IsTargetBuffWatched(buffId)
    -- not needed
    --buffId = DeserializeNumber(SerializeNumber(buffId))
    return targetWatchedBuffs[buffId] == true
end

-- Check if a buff is on the static bar's list (main.lua's collection pass)
function BuffSettingsWindow.IsStaticBuffWatched(buffId)
    return staticWatchedBuffs[buffId] == true
end

-- Toggle the buff selection window visibility

-- ===================================================================
-- One-time welcome card
-- ===================================================================
-- Shown on first load only. The flag lives on the settings ROOT rather than in
-- the display settings, because it is a property of the install rather than of
-- a character, and RESERVED_ROOT_KEYS keeps it through the schema migration.
local infoCardWindow

local function showInfoCard()
    RefreshPxGeometry()
    if infoCardWindow then
        infoCardWindow:Show(true)
        return
    end

    local w, h = 380, 168
    infoCardWindow = api.Interface:CreateEmptyWindow("ttpInfoCard", "UIParent")
    infoCardWindow:SetExtent(w, h)
    infoCardWindow:AddAnchor("CENTER", "UIParent", "CENTER", 0, -60)

    local outline = infoCardWindow:CreateColorDrawable(0, 0, 0, 0.96, "background")
    outline:AddAnchor("TOPLEFT", infoCardWindow, 0, 0)
    outline:AddAnchor("BOTTOMRIGHT", infoCardWindow, 0, 0)

    local body = infoCardWindow:CreateColorDrawable(0.06, 0.06, 0.068, 0.96, "background")
    body:AddAnchor("TOPLEFT", infoCardWindow, 1, 1)
    body:AddAnchor("BOTTOMRIGHT", infoCardWindow, -1, -1)
    RegisterPxInset(body, infoCardWindow)

    local header = infoCardWindow:CreateColorDrawable(0.09, 0.09, 0.11, 0.98, "background")
    header:SetExtent(w - 2, 30)
    header:AddAnchor("TOPLEFT", infoCardWindow, 1, 1)

    local accent = infoCardWindow:CreateColorDrawable(0, 0.75, 0.75, 0.85, "background")
    accent:SetExtent(4, 30)
    accent:AddAnchor("TOPLEFT", infoCardWindow, 1, 1)
    RegisterPxRefresher(function()
        local b = Px(1)
        header:SetExtent(w - 2 * b, 30)
        header:RemoveAllAnchors()
        header:AddAnchor("TOPLEFT", infoCardWindow, b, b)
        accent:RemoveAllAnchors()
        accent:AddAnchor("TOPLEFT", infoCardWindow, b, b)
    end)

    local function label(id, text, x, y, width, size, r, g, b)
        local l = infoCardWindow:CreateChildWidget("label", id, 0, true)
        l:SetExtent(width, 16)
        l:AddAnchor("TOPLEFT", infoCardWindow, x, y)
        l:SetText(text)
        l.style:SetAlign(ALIGN.LEFT)
        l.style:SetFontSize(size)
        l.style:SetColor(r, g, b, 1)
        l:Clickable(false)
        return l
    end

    label("ttpInfoTitle", "TrackThatPlease", 16, 7, 240, 15, 1, 0.84, 0)
    label("ttpInfoL1", "This addon is completely free.", 20, 46, w - 40, 13, 1, 1, 1)
    label("ttpInfoL2", "If you find it useful, in-game donations are appreciated",
          20, 68, w - 40, 13, 0.5, 0.5, 0.5)
    label("ttpInfoL3", "but never expected.", 20, 86, w - 40, 13, 0.5, 0.5, 0.5)
    label("ttpInfoL4", "Character:  Dehling", 20, 110, w - 40, 14, 1, 0.84, 0)

    -- Close button, built inline: createFlatButton is local to Initialize and
    -- this runs before that.
    local btn = infoCardWindow:CreateChildWidget("button", "ttpInfoClose", 0, true)
    btn:SetExtent(96, 26)
    btn:AddAnchor("TOPLEFT", infoCardWindow, w - 116, h - 40)
    btn:SetText("")
    local bBorder = btn:CreateColorDrawable(0, 0, 0, 0.92, "background")
    bBorder:AddAnchor("TOPLEFT", btn, 0, 0)
    bBorder:AddAnchor("BOTTOMRIGHT", btn, 0, 0)
    local bFill = btn:CreateColorDrawable(0.16, 0.21, 0.30, 0.96, "background")
    bFill:AddAnchor("TOPLEFT", btn, 1, 1)
    bFill:AddAnchor("BOTTOMRIGHT", btn, -1, -1)
    RegisterPxInset(bFill, btn)
    local bLabel = btn:CreateChildWidget("label", "ttpInfoCloseLbl", 0, true)
    bLabel:SetExtent(92, 14)
    bLabel:AddAnchor("CENTER", btn, 0, 0)
    bLabel:SetText("Got it")
    bLabel.style:SetAlign(ALIGN.CENTER)
    bLabel.style:SetFontSize(13)
    bLabel.style:SetColor(0.88, 0.90, 0.93, 1)
    bLabel:Clickable(false)
    btn:SetHandler("OnClick", function()
        infoCardWindow:Show(false)
        local root = ensureRoot()
        if root then
            root.infoCardSeen = true
            Store.Save()
        end
    end)

    infoCardWindow:EnableDrag(true)
    infoCardWindow:SetHandler("OnDragStart", function(self) self:StartMoving() end)
    infoCardWindow:SetHandler("OnDragStop", function(self) self:StopMovingOrSizing() end)
    infoCardWindow:Show(true)
end

function BuffSettingsWindow.ShowInfoCard()
    pcall(showInfoCard)
end

function BuffSettingsWindow.MaybeShowInfoCard()
    local root = ensureRoot()
    if root and root.infoCardSeen ~= true then
        pcall(showInfoCard)
    end
end

function BuffSettingsWindow.ToggleBuffSelectionWindow()
    if buffSelectionWindow then
        local isVisible = buffSelectionWindow:IsVisible()
        buffSelectionWindow:Show(not isVisible)
        if not isVisible then
            -- Thin-line geometry with the live scale; no-op when unchanged
            RefreshPxGeometry()
            fillBuffData(buffScrollList, 1, searchEditBox:GetText())
            -- First time the window is opened, not at load: the card lands when
            -- the player is already looking at the addon.
            BuffSettingsWindow.MaybeShowInfoCard()
        end
    else
        api.Log:Err("Buff selection window does not exist")
    end
end

-- Check if the buff selection window is visible
function BuffSettingsWindow.IsWindowVisible()
    return buffSelectionWindow and buffSelectionWindow:IsVisible() or false
end

-- Expose the window so main.lua can include it in reload-ghost cleanup
-- (CreateEmptyWindow widgets are invisible to FindWidget)
function BuffSettingsWindow.GetWindow()
    return buffSelectionWindow
end

function BuffSettingsWindow.RefreshLoggedBuffs()
    local buffsFromLogger = BuffsLogger.GetBuffsSetCopy()

    if buffsFromLogger then
        for idFromLogger, loggerBuff in pairs(buffsFromLogger) do
            if not BuffList.AllBuffsIndex[idFromLogger] then
                local iconPath = loggerBuff.iconPath

                local entry = {
                    id = idFromLogger,
                    name = loggerBuff.name, 
                    iconPath = loggerBuff.iconPath,
                    description = loggerBuff.description 
                }
                table.insert(BuffList.AllBuffs, entry)
                BuffList.AllBuffsIndex[idFromLogger] = entry



                -----
                local descriptionText
                if loggerBuff.description and string.len(loggerBuff.description) > 0 then
                    if string.len(loggerBuff.description) > 100 then
                        descriptionText = string.sub(loggerBuff.description, 1, 100) .. "..."
                    else
                        descriptionText = loggerBuff.description
                    end
                else
                    descriptionText = "No description"
                end
                api.Log:Err(string.format("Added new buff from logger: %s (Descr: %s)", loggerBuff.name, descriptionText))
            end
        end
    end

    -- Refill the scroll list with updated data
    fillBuffData(buffScrollList, buffScrollList.curPageIdx or 1, searchEditBox:GetText())
end

-- Initialize the BuffWatchWindow
function BuffSettingsWindow.Initialize(buffsLogger)
    -- Initializers
    BuffsLogger = buffsLogger
    loadSettings()
    BuffList.InitializeAllBuffs(buffsLogger)
    ----------------------------------------

   -- Create Settings UI elements-----------------
   -- Layout variables
    local columnGap = 18
    local columnWidth = 80
    local rowHeight = 55
    local leftMargin = 40
    local topMargin = 50
    -- Column positions
    local x1 = leftMargin                                
    local x2 = leftMargin + columnWidth + columnGap      
    local x3 = leftMargin + (columnWidth + columnGap) * 2
    local x4 = leftMargin + (columnWidth + columnGap) * 3
    --local x5 = leftMargin + (columnWidth + columnGap) * 4
    -- Row positions
    local y1 = topMargin                                 
    local y2 = y1 + rowHeight                     
    local y3 = y2 + rowHeight             
    local y4 = y3 + rowHeight        
    local y5 = y4 + rowHeight          
    
    
    --================= Create the main window =================--
    -- BetterBars-style flat dark shell: CreateEmptyWindow + color drawables
    -- (outline, body, header bar, accent stripe) instead of the default game
    -- window chrome. Drag and close are wired manually below.
    local wndWidth, wndHeight = 500, 948
    buffSelectionWindow = api.Interface:CreateEmptyWindow("buffSelectorWindow", "UIParent")
    buffSelectionWindow:SetExtent(wndWidth, wndHeight)
    buffSelectionWindow:AddAnchor("CENTER", "UIParent", "CENTER", 0, 0)

    local wndOutline = buffSelectionWindow:CreateColorDrawable(0, 0, 0, 0.96, "background")
    wndOutline:AddAnchor("TOPLEFT", buffSelectionWindow, 0, 0)
    wndOutline:AddAnchor("BOTTOMRIGHT", buffSelectionWindow, 0, 0)

    local wndBody = buffSelectionWindow:CreateColorDrawable(0.06, 0.06, 0.068, 0.96, "background")
    wndBody:AddAnchor("TOPLEFT", buffSelectionWindow, 1, 1)
    wndBody:AddAnchor("BOTTOMRIGHT", buffSelectionWindow, -1, -1)
    RegisterPxInset(wndBody, buffSelectionWindow)

    local wndHeader = buffSelectionWindow:CreateColorDrawable(0.09, 0.09, 0.11, 0.98, "background")
    wndHeader:SetExtent(wndWidth - 2, 34)
    wndHeader:AddAnchor("TOPLEFT", buffSelectionWindow, 1, 1)

    local wndAccent = buffSelectionWindow:CreateColorDrawable(0, 0.75, 0.75, 0.85, "background")
    wndAccent:SetExtent(4, 34)
    wndAccent:AddAnchor("TOPLEFT", buffSelectionWindow, 1, 1)
    RegisterPxRefresher(function()
        local b = Px(1)
        wndHeader:SetExtent(wndWidth - 2 * b, 34)
        wndHeader:RemoveAllAnchors()
        wndHeader:AddAnchor("TOPLEFT", buffSelectionWindow, b, b)
        wndAccent:RemoveAllAnchors()
        wndAccent:AddAnchor("TOPLEFT", buffSelectionWindow, b, b)
    end)

    local wndTitle = buffSelectionWindow:CreateChildWidget("label", "ttpWndTitle", 0, true)
    wndTitle:SetExtent(220, 18)
    wndTitle:AddAnchor("TOPLEFT", buffSelectionWindow, 16, 9)
    wndTitle:SetText("TrackThatPlease")
    wndTitle.style:SetFontSize(17)
    wndTitle.style:SetAlign(ALIGN.LEFT)
    wndTitle.style:SetColor(1, 0.84, 0, 1)

    -- (the close button is created flat-style after the UI factories below)
    -- Stay open when ESC is pressed, unlike BetterBars/CustomUI: ESC opens the
    -- game menu, which is also where this window is launched from, so closing on
    -- it fights the user. Close with the X, the ESC-menu entry, or "ttp" in chat.
    pcall(function()
        if buffSelectionWindow.SetCloseOnEscape then
            buffSelectionWindow:SetCloseOnEscape(false)
        end
    end)

    -- EnableDrag is required for CreateEmptyWindow-based shells
    if buffSelectionWindow.EnableDrag then buffSelectionWindow:EnableDrag(true) end
    buffSelectionWindow:SetHandler("OnDragStart", function(self)
        self:StartMoving()
        api.Cursor:ClearCursor()
        api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end)
    buffSelectionWindow:SetHandler("OnDragStop", function(self)
        self:StopMovingOrSizing()
        api.Cursor:ClearCursor()
    end)

    local s = BuffSettingsWindow.settings

    -- Tooltips are owned by the window rather than the hovered control, so that
    -- Raise() can lift them above the dropdowns and the search box (siblings)
    -- instead of being trapped inside a button's own subtree.
    local function addTooltip(id, target, text)
        return helpers.createTooltip(id, target, text, nil, nil, buffSelectionWindow)
    end

    --================= Flat-UI factories (BetterBars style) =================--
    local function createAnchor(target, x, y)
        return {
            anchor = "TOPLEFT",
            target = target,
            relativeAnchor = "TOPLEFT",
            x = x,
            y = y
        }
    end

    local function createSectionPanel(id, x, y, w, h, titleText)
        local p = buffSelectionWindow:CreateChildWidget("emptywidget", id, 0, true)
        p:SetExtent(w, h)
        p:AddAnchor("TOPLEFT", buffSelectionWindow, x, y)
        local bg = p:CreateColorDrawable(0.045, 0.045, 0.052, 0.84, "background")
        bg:AddAnchor("TOPLEFT", p, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", p, 0, 0)
        local hdr = p:CreateColorDrawable(0.09, 0.09, 0.11, 0.95, "background")
        hdr:SetExtent(w, 22)
        hdr:AddAnchor("TOPLEFT", p, 0, 0)
        local accent = p:CreateColorDrawable(0, 0.75, 0.75, 0.85, "background")
        accent:SetExtent(4, 22)
        accent:AddAnchor("TOPLEFT", p, 0, 0)
        local t = p:CreateChildWidget("label", id .. "_title", 0, true)
        t:SetExtent(w - 28, 16)
        t:AddAnchor("TOPLEFT", p, 14, 3)
        t:SetText(titleText)
        t.style:SetFontSize(12)
        t.style:SetAlign(ALIGN.LEFT)
        t.style:SetColor(1, 0.84, 0, 1)
        p:Show(true)
        return p
    end

    local TONE_ACTIVE = {0.12, 0.28, 0.15, 0.95}
    local TONE_IDLE = {0.14, 0.14, 0.16, 0.95}

    local function createFlatButton(parent, id, text, x, y, w, h, onClick)
        local btn = parent:CreateChildWidget("button", id, 0, true)
        btn:SetExtent(w, h)
        btn:AddAnchor("TOPLEFT", parent, x, y)
        btn:SetText("")
        local border = btn:CreateColorDrawable(0, 0, 0, 0.92, "background")
        border:AddAnchor("TOPLEFT", btn, 0, 0)
        border:AddAnchor("BOTTOMRIGHT", btn, 0, 0)
        local fill = btn:CreateColorDrawable(TONE_IDLE[1], TONE_IDLE[2], TONE_IDLE[3], TONE_IDLE[4], "background")
        fill:AddAnchor("TOPLEFT", btn, 1, 1)
        fill:AddAnchor("BOTTOMRIGHT", btn, -1, -1)
        RegisterPxInset(fill, btn)
        local lbl = btn:CreateChildWidget("label", id .. "_txt", 0, true)
        lbl:SetExtent(w - 4, 14)
        lbl:AddAnchor("CENTER", btn, 0, 0)
        lbl:SetText(text)
        lbl.style:SetFontSize(12)
        lbl.style:SetAlign(ALIGN.CENTER)
        lbl.style:SetColor(1, 1, 1, 1)
        lbl:Clickable(false)
        btn._fill = fill
        btn._label = lbl
        function btn:SetFlatText(v) self._label:SetText(v or "") end
        function btn:SetTone(c) self._fill:SetColor(c[1], c[2], c[3], c[4]) end
        function btn:SetFlatTextColor(r, g, b, a) self._label.style:SetColor(r, g, b, a) end
        if onClick then btn:SetHandler("OnClick", onClick) end
        btn:Show(true)
        return btn
    end

    -- Flat horizontal slider. The engine's W_CTRL scroll widget renders as a
    -- VERTICAL scrollbar, so this one is drawn from drawables (track + fill)
    -- and driven by -/+ step buttons and the mouse wheel over the track.
    local sliderCount = 0
    -- A check drawn like the watched-list rows: a flat 14px box whose fill
    -- carries the state. Same geometry and the same two colours as
    -- UpdateBuffSelectedAppearance uses, so the two read as one control.
    local function createFlatCheck(panel, id, labelText, x, y, w, isOn, onToggle)
        local btn = panel:CreateChildWidget("button", id, 0, true)
        btn:SetExtent(w, 20)
        btn:AddAnchor("TOPLEFT", panel, x, y)
        btn:SetText("")

        -- Box right, label left: the same reading order as the watched-list
        -- rows, and it lands the box in the column the sliders put their values
        -- in. Anchored to the right edge so it follows the width, not a constant.
        local border = btn:CreateColorDrawable(0, 0, 0, 0.92, "overlay")
        border:SetExtent(14, 14)
        border:AddAnchor("RIGHT", btn, 0, 0)
        local fill = btn:CreateColorDrawable(0.14, 0.14, 0.16, 1, "overlay")
        fill:SetExtent(12, 12)
        fill:AddAnchor("RIGHT", btn, -1, 0)
        RegisterPxRefresher(function()
            local b = Px(1)
            fill:SetExtent(14 - 2 * b, 14 - 2 * b)
            fill:RemoveAllAnchors()
            fill:AddAnchor("RIGHT", btn, -b, 0)
        end)

        local lbl = btn:CreateChildWidget("label", id .. "_lbl", 0, true)
        lbl:SetExtent(w - 22, 16)
        lbl:AddAnchor("LEFT", btn, 0, 0)
        lbl:SetText(labelText)
        lbl.style:SetAlign(ALIGN.LEFT)
        lbl.style:SetFontSize(13)
        lbl.style:SetColor(1, 0.84, 0, 1)
        lbl:Clickable(false)

        local function refresh()
            if isOn() then
                fill:SetColor(0, 0.75, 0.75, 1)      -- cyan accent = on
            else
                fill:SetColor(0.14, 0.14, 0.16, 1)
            end
        end
        function btn:OnClick()
            onToggle()
            refresh()
        end
        btn:SetHandler("OnClick", btn.OnClick)
        refresh()
        return btn, refresh
    end

    -- layout (optional) overrides the row geometry for narrow parents; the
    -- defaults are the 468-wide section-panel layout every DISPLAY/TIMERS row
    -- uses. Keys: labelX/labelW, trackX/trackW, valX/valW.
    local function createSliderRow(panel, y, labelText, minV, maxV, value, onChanged, displayFn, layout)
        sliderCount = sliderCount + 1
        local id = "ttpSlider" .. sliderCount
        displayFn = displayFn or tostring
        layout = layout or {}
        local labelX = layout.labelX or 14
        local labelW = layout.labelW or 102
        local trackX = layout.trackX or 148
        local valX = layout.valX or 404
        local valW = layout.valW or 52

        local trackW, trackH = layout.trackW or 202, 16
        local cur = math.max(minV, math.min(maxV, value))

        local lbl = panel:CreateChildWidget("label", id .. "_lbl", 0, true)
        lbl:SetExtent(labelW, 16)
        lbl:AddAnchor("TOPLEFT", panel, labelX, y + 2)
        lbl:SetText(labelText)
        lbl.style:SetAlign(ALIGN.LEFT)
        lbl.style:SetFontSize(13)
        lbl.style:SetColor(1, 0.84, 0, 1)

        local valLbl = panel:CreateChildWidget("label", id .. "_val", 0, true)
        valLbl:SetExtent(valW, 16)
        valLbl:AddAnchor("TOPLEFT", panel, valX, y + 2)
        valLbl:SetText(displayFn(cur))
        valLbl.style:SetAlign(ALIGN.CENTER)
        valLbl.style:SetFontSize(13)
        valLbl.style:SetColor(1, 1, 1, 1)

        -- Track with proportional fill (button so it receives wheel input)
        local track = panel:CreateChildWidget("button", id .. "_track", 0, true)
        track:SetExtent(trackW, trackH)
        track:AddAnchor("TOPLEFT", panel, trackX, y)
        track:SetText("")
        local trackBorder = track:CreateColorDrawable(0, 0, 0, 0.92, "background")
        trackBorder:AddAnchor("TOPLEFT", track, 0, 0)
        trackBorder:AddAnchor("BOTTOMRIGHT", track, 0, 0)
        local trackBg = track:CreateColorDrawable(0.10, 0.10, 0.12, 0.95, "background")
        trackBg:AddAnchor("TOPLEFT", track, 1, 1)
        trackBg:AddAnchor("BOTTOMRIGHT", track, -1, -1)
        RegisterPxInset(trackBg, track)
        local fill = track:CreateColorDrawable(0, 0.55, 0.55, 0.9, "background")
        fill:AddAnchor("TOPLEFT", track, 1, 1)

        local function refreshFill()
            -- Live Px: the fill sits one device pixel inside the track
            local b = Px(1)
            local frac = (cur - minV) / (maxV - minV)
            local w = math.floor(frac * (trackW - 2 * b) + 0.5)
            if w < 1 then
                fill:SetVisible(false)
            else
                fill:SetVisible(true)
                fill:RemoveAllAnchors()
                fill:AddAnchor("TOPLEFT", track, b, b)
                fill:SetExtent(w, trackH - 2 * b)
            end
        end
        refreshFill()
        RegisterPxRefresher(refreshFill)

        local function apply(nv)
            if nv < minV then nv = minV end
            if nv > maxV then nv = maxV end
            if nv == cur then return end
            cur = nv
            valLbl:SetText(displayFn(cur))
            refreshFill()
            onChanged(cur)
        end

        -- Mouse wheel over the track adjusts the value quickly
        track:SetHandler("OnWheelUp", function() apply(cur + 1) end)
        track:SetHandler("OnWheelDown", function() apply(cur - 1) end)

        -- Click anywhere on the track to jump straight to that value. Both
        -- readings are in DEVICE pixels - GetMousePos always is, and
        -- GetEffectiveOffset is the post-scale screen position (the client's
        -- own SaveBound/ApplyLastWindowOffset pair divides it by the UI scale
        -- before re-anchoring, which is what certifies the space) - so the
        -- fraction needs the track's device width: trackW is in UI units and
        -- is multiplied up. The fraction is then scale-free.
        track:SetHandler("OnClick", function()
            pcall(function()
                local mouseX = api.Input:GetMousePos()
                local trackX = track:GetEffectiveOffset()
                if type(mouseX) ~= "number" or type(trackX) ~= "number" then return end
                local frac = (mouseX - trackX) / (trackW * uiScaleOrOne())
                if frac < 0 then frac = 0 end
                if frac > 1 then frac = 1 end
                apply(minV + math.floor(frac * (maxV - minV) + 0.5))
            end)
        end)

        local function makeStepBtn(suffix, text, x, delta)
            local b = panel:CreateChildWidget("button", id .. suffix, 0, true)
            b:SetExtent(18, trackH)
            b:AddAnchor("TOPLEFT", panel, x, y)
            b:SetText("")
            local bb = b:CreateColorDrawable(0, 0, 0, 0.92, "background")
            bb:AddAnchor("TOPLEFT", b, 0, 0)
            bb:AddAnchor("BOTTOMRIGHT", b, 0, 0)
            local bf = b:CreateColorDrawable(0.16, 0.16, 0.18, 0.95, "background")
            bf:AddAnchor("TOPLEFT", b, 1, 1)
            bf:AddAnchor("BOTTOMRIGHT", b, -1, -1)
            RegisterPxInset(bf, b)
            local bl = b:CreateChildWidget("label", id .. suffix .. "_t", 0, true)
            bl:SetExtent(16, 14)
            bl:AddAnchor("CENTER", b, 0, 0)
            bl:SetText(text)
            bl.style:SetFontSize(13)
            bl.style:SetAlign(ALIGN.CENTER)
            bl.style:SetColor(1, 1, 1, 1)
            bl:Clickable(false)
            b:SetHandler("OnClick", function() apply(cur + delta) end)
            b:Show(true)
            return b
        end
        -- Derived from the track so narrow layouts carry them along: dec sits
        -- 24 ahead of the track (18 wide + the 6px gap the panel rows use),
        -- inc 4 past its end. Identity with the old 124/354 at the defaults.
        makeStepBtn("_dec", "-", trackX - 24, -1)
        makeStepBtn("_inc", "+", trackX + trackW + 4, 1)
        track:Show(true)
    end

    -- Header close button (flat style)
    createFlatButton(buffSelectionWindow, "ttpWndHelpBtn", "?", wndWidth - 60, 6, 24, 22, function()
        BuffSettingsWindow.ShowInfoCard()
    end)

    createFlatButton(buffSelectionWindow, "ttpWndCloseBtn", "X", wndWidth - 32, 6, 24, 22, function()
        buffSelectionWindow:Show(false)
    end)

    -- Sits below the Select All row, which is anchored to the same bottom edge
    -- but stays on the right, so the two do not meet.
    local credit = buffSelectionWindow:CreateChildWidget("label", "ttpCredit", 0, true)
    credit:SetExtent(260, 11)
    credit:AddAnchor("BOTTOMLEFT", buffSelectionWindow, 6, -4)
    credit:SetText("TrackThatPlease - " .. BuffSettingsWindow.ADDON_VERSION .. " - By Dehling")
    credit.style:SetAlign(ALIGN.LEFT)
    credit.style:SetFontSize(10)
    credit.style:SetColor(0.30, 0.31, 0.35, 1)
    credit:Clickable(false)

    --================= DISPLAY section =================--
    local displayPanel = createSectionPanel("ttpDisplayPanel", 16, 42, 468, 198, "DISPLAY")
    -- Sizes the above-head player bar only; the static bar has its own slider
    -- in its Configure popup
    createSliderRow(displayPanel, 32, "Player icons", 10, 60, s.iconSize, function(v)
        BuffSettingsWindow.settings.iconSize = v
        queueSave()
    end)
    createSliderRow(displayPanel, 58, "Target icons", 10, 60, s.targetIconSize, function(v)
        BuffSettingsWindow.settings.targetIconSize = v
        queueSave()
    end)
    createSliderRow(displayPanel, 84, "Icon spacing", 1, 10, s.iconSpacing, function(v)
        BuffSettingsWindow.settings.iconSpacing = v
        queueSave()
    end)
    createSliderRow(displayPanel, 110, "Text size", 10, 36, s.fontSize, function(v)
        BuffSettingsWindow.settings.fontSize = v
        queueSave()
    end)
    createSliderRow(displayPanel, 136, "Max buffs", 3, BuffSettingsWindow.MAX_BUFFS_COUNT, s.maxBuffsShown, function(v)
        BuffSettingsWindow.settings.maxBuffsShown = v
        queueSave()
    end)

    -- Label starts on the sliders' left edge; the box is right-anchored, so the
    -- width lands it under their "-" step button (that sits at 124 and is 18
    -- wide, so its centre is 133; a 14px box ending at 140 centres on the same).
    createFlatCheck(displayPanel, "ttpStacksCheck", "Show stacks", 14, 164, 126,
        function() return BuffSettingsWindow.settings.shouldShowStacks == true end,
        function()
            BuffSettingsWindow.settings.shouldShowStacks =
                not (BuffSettingsWindow.settings.shouldShowStacks == true)
            BuffSettingsWindow.SaveSettings()
        end)

    --================= TIMERS & POSITION section =================--
    local timersPanel = createSectionPanel("ttpTimersPanel", 16, 246, 468, 142, "TIMERS & POSITION")
    createSliderRow(timersPanel, 32, "Buff warn", 0, 10, math.floor(s.buffWarnTime / 1000), function(v)
        BuffSettingsWindow.settings.buffWarnTime = v * 1000
        queueSave()
    end, function(v) return v .. "s" end)
    createSliderRow(timersPanel, 58, "Debuff warn", 0, 10, math.floor(s.debuffWarnTime / 1000), function(v)
        BuffSettingsWindow.settings.debuffWarnTime = v * 1000
        queueSave()
    end, function(v) return v .. "s" end)
    -- Offsets are stored as -100..100 (negative = above the head anchor); the
    -- slider works in 0..200 and maps. 200 steps on a ~200px track is 1px per
    -- step, so click-to-set can land on any value.
    createSliderRow(timersPanel, 84, "Player offset", 0, 200, s.playerBuffVerticalOffset + 100, function(v)
        BuffSettingsWindow.settings.playerBuffVerticalOffset = v - 100
        queueSave()
    end, function(v) return tostring(v - 100) end)
    createSliderRow(timersPanel, 110, "Target offset", 0, 200, s.targetBuffVerticalOffset + 100, function(v)
        BuffSettingsWindow.settings.targetBuffVerticalOffset = v - 100
        queueSave()
    end, function(v) return tostring(v - 100) end)

    --================= PLAYER BAR section =================--
    local playerBarPanel = createSectionPanel("ttpPlayerBarPanel", 16, 394, 468, 92, "PLAYER BAR")

    -- Two modes. Nameplate compensation used to be a third one; it is the
    -- Nametag toggle beside this now, because it is orthogonal to where the bar
    -- sits - it corrects how the game reports the position, not where you want it.
    local MODE_LABELS = {
        head = "Position: Above head",
        fixed = "Position: Fixed screen",
    }
    local MODE_NEXT = { head = "fixed", fixed = "head" }

    local modeBtn, moveBtn, nametagBtn
    local moveActive = false
    local modeBtnRefresh, nametagBtnRefresh, slotRefresh

    -- One slot holds both of the next two. "Move bar" only means anything in
    -- Fixed screen mode, and nameplate compensation only runs in Above head, so
    -- whichever applies to the current mode is the one on screen.
    slotRefresh = function()
        local fixed = BuffSettingsWindow.settings.playerBarMode == "fixed"
        moveBtn:Show(fixed)
        nametagBtn:Show(not fixed)
    end

    modeBtnRefresh = function()
        local mode = BuffSettingsWindow.settings.playerBarMode
        modeBtn:SetFlatText(MODE_LABELS[mode] or MODE_LABELS.head)
        modeBtn:SetTone(mode ~= "head" and TONE_ACTIVE or TONE_IDLE)
    end
    modeBtn = createFlatButton(playerBarPanel, "ttpModeBtn", "", 14, 32, 170, 22, function()
        local mode = BuffSettingsWindow.settings.playerBarMode
        local nextMode = MODE_NEXT[mode] or "head"
        -- Leaving Fixed mid-drag would hide the button still holding the drag
        -- open, stranding the bar unlocked with no way to lock it. End it first.
        if moveActive and nextMode ~= "fixed" then
            moveActive = false
            moveBtn:SetFlatText("Move bar")
            moveBtn:SetTone(TONE_IDLE)
            api:Emit("TTP_PLAYERBAR_UNLOCK")
        end
        BuffSettingsWindow.settings.playerBarMode = nextMode
        modeBtnRefresh()
        slotRefresh()
        -- the compensation calibrates its resting height on entry, so clear the
        -- old calibration whenever the mode changes
        api:Emit("TTP_BARMODE_CHANGED")
        BuffSettingsWindow.SaveSettings()
    end)
    modeBtnRefresh()
    addTooltip("ttpModeBtnTip", modeBtn,
        "'Above head' follows the character in the world. \n" ..
        "'Fixed screen' pins the bar to a screen position instead, so nothing \n" ..
        "in the world can move it. \n" ..
        "The button beside this one follows the mode: Nametag in 'Above head', \n" ..
        "'Move bar' in 'Fixed screen'.")

    moveBtn = createFlatButton(playerBarPanel, "ttpMoveBtn", "Move bar", 196, 32, 130, 22, function()
        moveActive = not moveActive
        moveBtn:SetFlatText(moveActive and "Done moving" or "Move bar")
        moveBtn:SetTone(moveActive and TONE_ACTIVE or TONE_IDLE)
        api:Emit("TTP_PLAYERBAR_UNLOCK")
        modeBtnRefresh() -- unlocking forces fixed mode
    end)
    moveBtn:Show(false) -- slotRefresh decides, once both buttons exist
    addTooltip("ttpMoveBtnTip", moveBtn,
        "Shows the player bar as a colored box you can drag anywhere. \n" ..
        "Click again to lock the position (uses Fixed screen mode).")

    -- Shares the slot above with "Move bar": shown in Above head mode only
    nametagBtnRefresh = function()
        local on = BuffSettingsWindow.settings.nametagEnabled == true
        nametagBtn:SetFlatText(on and "Nametag: ON" or "Nametag: OFF")
        nametagBtn:SetTone(on and TONE_ACTIVE or TONE_IDLE)
    end
    nametagBtn = createFlatButton(playerBarPanel, "ttpNametagBtn", "", 196, 32, 130, 22, function()
        BuffSettingsWindow.settings.nametagEnabled =
            not (BuffSettingsWindow.settings.nametagEnabled == true)
        nametagBtnRefresh()
        -- the compensation calibrates its resting height on entry
        api:Emit("TTP_BARMODE_CHANGED")
        BuffSettingsWindow.SaveSettings()
    end)
    nametagBtnRefresh()
    addTooltip("ttpNametagBtnTip", nametagBtn,
        "Turn this ON if your own character's nameplate is showing. \n" ..
        "The game anchors overhead UI to the nameplate, so with it on the \n" ..
        "reported position wanders and the bar jitters. This cancels that \n" ..
        "wander and holds the bar steady through jumps and abrupt skills. \n" ..
        "Leave it OFF with no nameplate - plain 'Above head' is already \n" ..
        "correct then.")
    slotRefresh()

    --================= Static bar (second row of PLAYER BAR) =================--
    -- A second, always-fixed player bar with its own watched list. The panel
    -- carries a single button; everything about the bar - enabling it,
    -- placing it, sizing it, jumping to its list - lives in the popup it
    -- opens, so the panel stays two short rows.
    --
    -- Declared ahead of the widgets: the window's OnHide (defined at the end
    -- of Initialize) must be able to end an active move.
    local staticCfgPopup
    local staticMoveActive = false
    local staticMoveBtn

    -- Emitting the unlock event TOGGLES main.lua's drag state, so this guards
    -- on its own flag to only ever emit while a move is actually open
    local function endStaticMove()
        if not staticMoveActive then return end
        staticMoveActive = false
        if staticMoveBtn then
            staticMoveBtn:SetFlatText("Move bar")
            staticMoveBtn:SetTone(TONE_IDLE)
        end
        api:Emit("TTP_STATICBAR_UNLOCK")
    end

    -- The one panel-side control: opens the popup. Sits in the mode button's
    -- column, matching its width, since it is now alone on the row.
    local staticCfgBtn = createFlatButton(playerBarPanel, "ttpStaticCfgBtn", "Static Bar", 14, 62, 170, 22, function()
        if not staticCfgPopup then return end
        local wasVisible = staticCfgPopup:IsVisible()
        staticCfgPopup:Show(not wasVisible)
        if not wasVisible then
            -- Created before the TRACKING panel and the buff list, so lift it
            -- above them (same treatment as the dropdown popups)
            pcall(function() staticCfgPopup:Raise() end)
        end
    end)
    addTooltip("ttpStaticCfgTip", staticCfgBtn,
        "A second bar for your own buffs, pinned to a fixed screen spot, \n" ..
        "with its own list - independent of the bar above your head, so a \n" ..
        "buff can be on either bar, or on both. \n" ..
        "Opens its settings: enable it, place it, size it, edit its list. \n" ..
        "Placing works with the bar disabled too.")

    -- The popup. A child of the settings window on purpose: it follows window
    -- drags, hides with it, and the /reload stale-HUD sweep that parks the
    -- window off screen takes the popup along without knowing it exists.
    staticCfgPopup = buffSelectionWindow:CreateChildWidget("emptywidget", "ttpStaticCfgPopup", 0, true)
    local popW, popH = 300, 196
    staticCfgPopup:SetExtent(popW, popH)
    -- Flyout at the window's top-right, outside the frame: covers no settings,
    -- and top-aligned with the header so it reads as part of the same window
    staticCfgPopup:AddAnchor("TOPLEFT", buffSelectionWindow, "TOPRIGHT", 8, 0)

    local popOutline = staticCfgPopup:CreateColorDrawable(0, 0, 0, 0.96, "background")
    popOutline:AddAnchor("TOPLEFT", staticCfgPopup, 0, 0)
    popOutline:AddAnchor("BOTTOMRIGHT", staticCfgPopup, 0, 0)
    local popBody = staticCfgPopup:CreateColorDrawable(0.06, 0.06, 0.068, 0.98, "background")
    popBody:AddAnchor("TOPLEFT", staticCfgPopup, 1, 1)
    popBody:AddAnchor("BOTTOMRIGHT", staticCfgPopup, -1, -1)
    RegisterPxInset(popBody, staticCfgPopup)
    local popHeader = staticCfgPopup:CreateColorDrawable(0.09, 0.09, 0.11, 0.98, "background")
    popHeader:SetExtent(popW - 2, 30)
    popHeader:AddAnchor("TOPLEFT", staticCfgPopup, 1, 1)
    -- Accent in the static track-type tint, tying the popup to the dropdown entry
    local popAccent = staticCfgPopup:CreateColorDrawable(0.72, 0.58, 0.95, 0.85, "background")
    popAccent:SetExtent(4, 30)
    popAccent:AddAnchor("TOPLEFT", staticCfgPopup, 1, 1)
    RegisterPxRefresher(function()
        local b = Px(1)
        popHeader:SetExtent(popW - 2 * b, 30)
        popHeader:RemoveAllAnchors()
        popHeader:AddAnchor("TOPLEFT", staticCfgPopup, b, b)
        popAccent:RemoveAllAnchors()
        popAccent:AddAnchor("TOPLEFT", staticCfgPopup, b, b)
    end)

    local popTitle = staticCfgPopup:CreateChildWidget("label", "ttpStaticCfgTitle", 0, true)
    popTitle:SetExtent(200, 16)
    popTitle:AddAnchor("TOPLEFT", staticCfgPopup, 14, 8)
    -- Matches the panel button's label exactly, so the popup reads as that
    -- button's window
    popTitle:SetText("Static Bar")
    popTitle.style:SetFontSize(15)
    popTitle.style:SetAlign(ALIGN.LEFT)
    popTitle.style:SetColor(1, 0.84, 0, 1)
    popTitle:Clickable(false)

    createFlatButton(staticCfgPopup, "ttpStaticCfgClose", "X", popW - 30, 4, 24, 22, function()
        staticCfgPopup:Show(false)
    end)

    -- The enable toggle, moved here from a PLAYER BAR checkbox: full-width
    -- state button, first row, since it is the bar's primary switch
    local staticEnableBtn
    local function staticEnableRefresh()
        local on = BuffSettingsWindow.settings.staticBarEnabled == true
        staticEnableBtn:SetFlatText(on and "Enabled" or "Disabled")
        staticEnableBtn:SetTone(on and TONE_ACTIVE or TONE_IDLE)
    end
    staticEnableBtn = createFlatButton(staticCfgPopup, "ttpStaticEnableBtn", "", 14, 40, popW - 28, 22, function()
        local enabled = not (BuffSettingsWindow.settings.staticBarEnabled == true)
        BuffSettingsWindow.settings.staticBarEnabled = enabled
        -- Turning the bar off with a drag open would strand it unlocked
        if not enabled then endStaticMove() end
        staticEnableRefresh()
        BuffSettingsWindow.SaveSettings()
    end)
    staticEnableRefresh()
    addTooltip("ttpStaticEnableTip", staticEnableBtn,
        "Turns the static bar on or off. \n" ..
        "Placing and sizing below work with the bar disabled too, \n" ..
        "so it can be set up first and enabled when wanted.")

    staticMoveBtn = createFlatButton(staticCfgPopup, "ttpStaticMoveBtn", "Move bar", 14, 70, 130, 22, function()
        staticMoveActive = not staticMoveActive
        staticMoveBtn:SetFlatText(staticMoveActive and "Done moving" or "Move bar")
        staticMoveBtn:SetTone(staticMoveActive and TONE_ACTIVE or TONE_IDLE)
        api:Emit("TTP_STATICBAR_UNLOCK")
    end)
    addTooltip("ttpStaticMoveTip", staticMoveBtn,
        "Shows the static bar as a colored box you can drag anywhere. \n" ..
        "Click again to lock the position.")

    createFlatButton(staticCfgPopup, "ttpStaticEditBtn", "Edit list", 156, 70, 130, 22, function()
        if trackTypeDropdown and trackTypeDropdown.SelectAndApply then
            trackTypeDropdown:SelectAndApply(TRACK_TYPE_STATIC)
        end
    end)

    -- The bar's own icon size, on the compact layout: the standard row is laid
    -- for the 468-wide panels and would run 156 units past this popup's edge.
    -- Every x here is derived left-to-right inside popW = 300, with the step
    -- buttons following the track automatically (see makeStepBtn).
    createSliderRow(staticCfgPopup, 104, "Icon size", 10, 60, s.staticIconSize, function(v)
        BuffSettingsWindow.settings.staticIconSize = v
        queueSave()
    end, nil, { labelW = 62, trackX = 104, trackW = 118, valX = 248, valW = 40 })

    -- Short primer, info-card style: fixed lines rather than wordwrap so the
    -- text cannot reflow against the fixed popup extent
    local staticHintLines = {
        "The bar only appears while Enabled AND its list",
        "has buffs. The list lives under TRACKING: set",
        "Track type to 'Static bar', then tick buffs.",
    }
    for i, lineText in ipairs(staticHintLines) do
        local hint = staticCfgPopup:CreateChildWidget("label", "ttpStaticHint" .. i, 0, true)
        hint:SetExtent(popW - 28, 14)
        hint:AddAnchor("TOPLEFT", staticCfgPopup, 14, 132 + (i - 1) * 17)
        hint:SetText(lineText)
        hint.style:SetFontSize(12)
        hint.style:SetAlign(ALIGN.LEFT)
        hint.style:SetColor(0.55, 0.57, 0.62, 1)
        hint:Clickable(false)
    end

    staticCfgPopup:Show(false)

    --================= TRACKING section =================--
    local trackingPanel = createSectionPanel("ttpTrackingPanel", 16, 492, 468, 140, "TRACKING")

    -- The two dropdowns build their own label and anchor themselves; only the
    -- search box and the scroll list still come from the shared helpers.
    local anchors = {
        searchEditBox = createAnchor(trackingPanel, 310, 32),
        buffScrollList = createAnchor(buffSelectionWindow, 40, 642),
    }

    --================= Watched-list scope / sharing row =================--
    -- Display settings are always shared; only the watched lists can be per-character.
    local TONE_WARN = {0.38, 0.12, 0.12, 0.95}
    local buffScopeBtn, promoteBtn

    -- The copy button always pushes the list currently in use into the other
    -- scope, so its direction follows the toggle: Character -> Global while this
    -- character has its own list, Global -> Character otherwise. Either way it
    -- overwrites a list that may hold hundreds of buffs, so it arms on the first
    -- click and only acts on a second one.
    local promoteArmed = false
    local promoteArmToken = 0
    local function promoteIdleText()
        return BuffSettingsWindow.IsUsingCharacterBuffs() and "To global" or "To character"
    end
    local function disarmPromote()
        promoteArmed = false
        if promoteBtn then
            promoteBtn:SetFlatText(promoteIdleText())
            promoteBtn:SetTone(TONE_IDLE)
        end
    end

    refreshBuffScopeButton = function()
        local perCharacter = BuffSettingsWindow.IsUsingCharacterBuffs()
        if buffScopeBtn then
            buffScopeBtn:SetFlatText(perCharacter and "List: Character" or "List: Global")
            buffScopeBtn:SetTone(perCharacter and TONE_ACTIVE or TONE_IDLE)
        end
        if promoteBtn then
            disarmPromote() -- also relabels for the new direction
        end
    end

    buffScopeBtn = createFlatButton(trackingPanel, "ttpBuffScopeBtn", "", 14, 108, 150, 22, function()
        if not BuffSettingsWindow.SetUseCharacterBuffs(not BuffSettingsWindow.IsUsingCharacterBuffs()) then
            api.Log:Err("TrackThatPlease: character not loaded yet, try again in a moment.")
            return
        end
        refreshBuffScopeButton()
        refreshWatchedUI()
    end)
    addTooltip("ttpBuffScopeBtnTip", buffScopeBtn,
        "'Global' shares one watched-buff list across all your characters. \n" ..
        "'Character' gives this character its own list, seeded from the global \n" ..
        "one. Switching back keeps both lists, so nothing is lost. \n" ..
        "All other settings are always shared.")

    promoteBtn = createFlatButton(trackingPanel, "ttpPromoteBtn", "To global", 170, 108, 98, 22, function()
        if not promoteArmed then
            promoteArmed = true
            promoteArmToken = promoteArmToken + 1
            local token = promoteArmToken
            promoteBtn:SetFlatText("Overwrite?")
            promoteBtn:SetTone(TONE_WARN)
            api:DoIn(4000, function()
                if promoteArmed and promoteArmToken == token then disarmPromote() end
            end)
            return
        end

        local toGlobal = BuffSettingsWindow.IsUsingCharacterBuffs()
        disarmPromote()

        local ok
        if toGlobal then
            ok = BuffSettingsWindow.PromoteCharacterBuffsToGlobal()
        else
            ok = BuffSettingsWindow.CopyGlobalBuffsToCharacter()
        end

        if not ok then
            api.Log:Err("TrackThatPlease: character not loaded yet, try again in a moment.")
            return
        end
        if toGlobal then
            api.Log:Info("TrackThatPlease: global list replaced with this character's list.")
        else
            api.Log:Info("TrackThatPlease: this character's stored list replaced with the global one. "
                .. "Switch 'List' to Character to use it.")
        end
        refreshBuffScopeButton()
        refreshWatchedUI()
    end)
    addTooltip("ttpPromoteBtnTip", promoteBtn,
        "Copies the list you are using into the other scope, overwriting it - \n" ..
        "click twice to confirm. \n" ..
        "On 'Character' it reads 'To global': your list becomes the shared one \n" ..
        "that every character on 'Global' inherits. \n" ..
        "On 'Global' it reads 'To character': the shared list overwrites this \n" ..
        "character's own stored list.")

    local exportBtn = createFlatButton(trackingPanel, "ttpExportBtn", "Export", 274, 108, 88, 22, function()
        local playerCount, targetCount, backedUp = BuffSettingsWindow.ExportWatchedBuffs()
        if not playerCount then
            api.Log:Err("TrackThatPlease: could not write " .. BuffSettingsWindow.SHARE_PATH)
            return
        end
        api.Log:Info(string.format("TrackThatPlease: exported %d player / %d target buffs to %s",
            playerCount, targetCount, BuffSettingsWindow.SHARE_PATH))
        if backedUp then
            api.Log:Info("TrackThatPlease: the previous file was kept as "
                .. BuffSettingsWindow.SHARE_BACKUP_PATH)
        end
    end)
    addTooltip("ttpExportBtnTip", exportBtn,
        "Writes the list you are using to \n" ..
        BuffSettingsWindow.SHARE_PATH .. " \n" ..
        "Send that file to a friend as-is - they can import it without renaming. \n" ..
        "If the file already held someone else's list it is kept as \n" ..
        BuffSettingsWindow.SHARE_BACKUP_PATH)

    local importBtn = createFlatButton(trackingPanel, "ttpImportBtn", "Import", 366, 108, 88, 22, function()
        local addedPlayer, addedTarget = BuffSettingsWindow.ImportWatchedBuffs()
        if not addedPlayer then
            api.Log:Err("TrackThatPlease: could not read " .. BuffSettingsWindow.SHARE_PATH)
            return
        end
        api.Log:Info(string.format("TrackThatPlease: imported %d new player / %d new target buffs",
            addedPlayer, addedTarget))
        refreshWatchedUI()
    end)
    addTooltip("ttpImportBtnTip", importBtn,
        "Reads a shared list from \n" ..
        BuffSettingsWindow.SHARE_PATH .. " \n" ..
        "and adds it to the list you are using. Only adds - it never removes \n" ..
        "buffs you already watch.")

    refreshBuffScopeButton()

    --================= Flat styling for the shared field widgets =================--
    -- The dropdowns and the search box come from util/helpers with the game's
    -- default chrome and 14/15px gold text, which is left over from the old look
    -- and clashes with the flat panels. Restyle them here rather than in helpers,
    -- so the shared module keeps its current behaviour for any other caller.
    local FIELD_LABEL_COLOR = {0.62, 0.66, 0.72, 1}
    local FIELD_TEXT_COLOR = {0.88, 0.90, 0.93, 1}
    -- Selection tints, brightened for legibility on the dark shell
    local TINT_PLAYER = {0.45, 0.85, 0.50, 1}
    local TINT_TARGET = {0.95, 0.45, 0.45, 1}
    local TINT_BOTH = {0.95, 0.80, 0.45, 1}
    -- Static bar: violet, read against the green/red/amber of the other three
    local TINT_STATIC = {0.72, 0.58, 0.95, 1}
    local TINT_ALL = {0.62, 0.66, 0.72, 1}
    local TINT_LOGGED = {0.95, 0.70, 0.35, 1}
    local TINT_WATCHED = {0.35, 0.80, 0.80, 1} -- matches the cyan panel accent

    local function styleFieldLabel(label)
        if not label then return end
        pcall(function()
            -- Same extent for every field label: the shared helper leaves its own
            -- label at the default height, so its text sits higher in the row than
            -- the ones built here unless the box matches.
            label:SetExtent(140, 16)
            label.style:SetFontSize(12)
            label.style:SetAlign(ALIGN.LEFT)
            label.style:SetColor(FIELD_LABEL_COLOR[1], FIELD_LABEL_COLOR[2],
                                 FIELD_LABEL_COLOR[3], FIELD_LABEL_COLOR[4])
        end)
    end

    --================= Flat dropdown (replaces the engine combo box) =================--
    -- The engine combo box draws its frame, its arrow and its expanded list from
    -- whichever in-game UI skin the player has selected, and the popup is built
    -- internally where it cannot be restyled. This builds the whole control out of
    -- our own widgets instead, so it looks identical on every UI skin.
    local FIELD_ROW_Y = 58
    local openDropdown -- at most one popup is visible at a time

    local function createFieldLabel(id, text, x)
        local lbl = trackingPanel:CreateChildWidget("label", id, 0, true)
        lbl:AddAnchor("TOPLEFT", trackingPanel, x, 32)
        lbl:SetText(text)
        lbl:Clickable(false)
        styleFieldLabel(lbl)
        return lbl
    end

    -- Down-pointing triangle drawn from stacked 1px rows: no font glyph involved,
    -- so it renders the same everywhere.
    local function drawArrow(parent, rightInset)
        local rows = {}
        local widths = { 9, 7, 5, 3, 1 }
        for i, w in ipairs(widths) do
            local row = parent:CreateColorDrawable(0.62, 0.66, 0.72, 1, "overlay")
            row:SetExtent(w, 1)
            row:AddAnchor("RIGHT", parent, -rightInset - (9 - w) / 2, -2 + i)
            table.insert(rows, row)
        end
        -- Glyph-internal geometry in device pixels; rightInset stays layout
        RegisterPxRefresher(function()
            for i, w in ipairs(widths) do
                local row = rows[i]
                row:SetExtent(Px(w), Px(1))
                row:RemoveAllAnchors()
                row:AddAnchor("RIGHT", parent, -rightInset - Px((9 - w) / 2), Px(-2 + i))
            end
        end)
        return rows
    end

    local function createFlatDropdown(id, x, w, options, defaultIndex, onSelect)
        local dd = trackingPanel:CreateChildWidget("button", id, 0, true)
        dd:SetExtent(w, 28)
        dd:AddAnchor("TOPLEFT", trackingPanel, x, FIELD_ROW_Y)
        dd:SetText("")

        local border = dd:CreateColorDrawable(0, 0, 0, 0.92, "background")
        border:AddAnchor("TOPLEFT", dd, 0, 0)
        border:AddAnchor("BOTTOMRIGHT", dd, 0, 0)
        local fill = dd:CreateColorDrawable(0.10, 0.10, 0.12, 1, "background")
        fill:AddAnchor("TOPLEFT", dd, 1, 1)
        fill:AddAnchor("BOTTOMRIGHT", dd, -1, -1)
        RegisterPxInset(fill, dd)

        local text = dd:CreateChildWidget("label", id .. "_txt", 0, true)
        text:SetExtent(w - 28, 14)
        text:AddAnchor("LEFT", dd, 8, 0)
        text.style:SetFontSize(13)
        text.style:SetAlign(ALIGN.LEFT)
        text:Clickable(false)

        local arrowRows = drawArrow(dd, 8)

        -- The popup hangs off the window, not the panel, so it can overlap the
        -- rows beneath it instead of being clipped by the TRACKING panel.
        local rowHeight = 22
        local popup = buffSelectionWindow:CreateChildWidget("emptywidget", id .. "_pop", 0, true)
        popup:SetExtent(w, #options * rowHeight + 2)
        popup:AddAnchor("TOPLEFT", dd, "BOTTOMLEFT", 0, 2)
        local popBorder = popup:CreateColorDrawable(0, 0, 0, 0.96, "background")
        popBorder:AddAnchor("TOPLEFT", popup, 0, 0)
        popBorder:AddAnchor("BOTTOMRIGHT", popup, 0, 0)
        local popFill = popup:CreateColorDrawable(0.08, 0.08, 0.095, 1, "background")
        popFill:AddAnchor("TOPLEFT", popup, 1, 1)
        popFill:AddAnchor("BOTTOMRIGHT", popup, -1, -1)
        RegisterPxInset(popFill, popup)
        popup:Show(false)
        local optionRows = {}

        dd.dropdownItem = options
        dd._index = defaultIndex or 1

        function dd:HidePopup()
            popup:Show(false)
            if openDropdown == self then openDropdown = nil end
        end

        function dd:GetSelectedIndex()
            return self._index
        end

        function dd:Select(index)
            index = tonumber(index) or 1
            if index < 1 or index > #options then index = 1 end
            self._index = index
            text:SetText(options[index] or "")
        end

        -- Select AND run the selection callback, as if the row were clicked.
        -- For callers outside the dropdown (the static-bar popup's Edit list
        -- shortcut) - plain Select only repaints the collapsed text.
        function dd:SelectAndApply(index)
            self:Select(index)
            if onSelect then onSelect(self._index, options[self._index]) end
        end

        function dd:SetAllTextColor(color)
            color = color or { 1, 1, 1, 1 }
            text.style:SetColor(color[1], color[2], color[3], color[4] or 1)
            for _, row in ipairs(arrowRows) do
                row:SetColor(color[1], color[2], color[3], color[4] or 1)
            end
        end

        for i, option in ipairs(options) do
            local row = popup:CreateChildWidget("button", id .. "_o" .. i, 0, true)
            row:SetExtent(w - 2, rowHeight)
            row:AddAnchor("TOPLEFT", popup, 1, 1 + (i - 1) * rowHeight)
            row:SetText("")
            local rowFill = row:CreateColorDrawable(0.08, 0.08, 0.095, 1, "background")
            rowFill:AddAnchor("TOPLEFT", row, 0, 0)
            rowFill:AddAnchor("BOTTOMRIGHT", row, 0, 0)
            local rowLabel = row:CreateChildWidget("label", id .. "_ol" .. i, 0, true)
            rowLabel:SetExtent(w - 14, 14)
            rowLabel:AddAnchor("LEFT", row, 7, 0)
            rowLabel:SetText(option)
            rowLabel.style:SetFontSize(13)
            rowLabel.style:SetAlign(ALIGN.LEFT)
            rowLabel.style:SetColor(0.88, 0.90, 0.93, 1)
            rowLabel:Clickable(false)
            row:SetHandler("OnEnter", function() rowFill:SetColor(0.17, 0.17, 0.20, 1) end)
            row:SetHandler("OnLeave", function() rowFill:SetColor(0.08, 0.08, 0.095, 1) end)
            row:SetHandler("OnClick", function()
                dd:Select(i)
                dd:HidePopup()
                if onSelect then onSelect(i, options[i]) end
            end)
            row:Show(true)
            table.insert(optionRows, row)
        end
        -- Rows sit inside the popup's one-device-pixel ring; the popup's own
        -- height carries the ring twice
        RegisterPxRefresher(function()
            local b = Px(1)
            popup:SetExtent(w, #options * rowHeight + 2 * b)
            for i, row in ipairs(optionRows) do
                row:SetExtent(w - 2 * b, rowHeight)
                row:RemoveAllAnchors()
                row:AddAnchor("TOPLEFT", popup, b, b + (i - 1) * rowHeight)
            end
        end)

        dd:SetHandler("OnClick", function()
            if popup:IsVisible() then
                dd:HidePopup()
                return
            end
            if openDropdown and openDropdown ~= dd then
                openDropdown:HidePopup()
            end
            openDropdown = dd
            popup:Show(true)
            pcall(function() popup:Raise() end)
        end)

        dd:Select(defaultIndex or 1)
        dd:Show(true)
        return dd
    end

    --================= Create trackTypeDropdown =================--
    local trackTypeLabel = createFieldLabel("ttpTrackTypeLbl", "Track type:", 14)
    trackTypeDropdown = createFlatDropdown("ttpTrackTypeDd", 14, 120, trackTypes, currentTrackType,
        function(selectedIndex, selectedValue)
            local newTrackType = selectedIndex
            if newTrackType ~= currentTrackType then
                currentTrackType = newTrackType
                searchEditBox:SetText("")
                fillBuffData(buffScrollList, 1, searchEditBox:GetText())
            end
            if selectedIndex == TRACK_TYPE_PLAYER then -- Player
                trackTypeDropdown:SetAllTextColor(TINT_PLAYER)
            elseif selectedIndex == TRACK_TYPE_TARGET then -- Target
                trackTypeDropdown:SetAllTextColor(TINT_TARGET)
            elseif selectedIndex == TRACK_TYPE_STATIC then -- Static bar
                trackTypeDropdown:SetAllTextColor(TINT_STATIC)
            else -- Both
                trackTypeDropdown:SetAllTextColor(TINT_BOTH)
            end
        end
    )
    trackTypeDropdown:SetAllTextColor(TINT_PLAYER)
    addTooltip("ttpTrackTypeTip", trackTypeDropdown,
        "Which list the checkmarks below apply to. \n" ..
        "'Both' keeps the Player and Target lists separate but applies every \n" ..
        "click to each of them, and only shows a checkmark when a buff is on \n" ..
        "both. Clicking a buff watched on just one adds it to the other. \n" ..
        "'Static bar' is the second player bar's own list (see PLAYER BAR), \n" ..
        "independent of the other two.")

    -- (show-stacks toggle now lives in the PLAYER BAR panel above)
    

    -- (max buffs is now a slider in the DISPLAY panel)

    -- (icon size is now a slider in the DISPLAY panel)

    -- (icon spacing is now a slider in the DISPLAY panel)

    -- (text size is now a slider in the DISPLAY panel)

    -- (debuff warn time is now a slider in the TIMERS & POSITION panel)

    -- (buff warn time is now a slider in the TIMERS & POSITION panel)


    -- (player vertical offset is now a slider in the TIMERS & POSITION panel)

    -- (target vertical offset is now a slider in the TIMERS & POSITION panel)

       --================= Create category dropdownn =================--
    local categoryDropdownTooltip = "'All static buffs' - all buffs in the game (many are outdated) \n" ..
        "'All logged buffs' - buffs collected by logged \n" ..
        "'Watched buffs' - buffs that are watched on (Player/Target)"

    local categoryLabel = createFieldLabel("ttpCategoryLbl", "Buff category:", 150)
    categoryDropdown = createFlatDropdown("ttpCategoryDd", 150, 140, categories, currentCategory,
        function(selectedIndex, selectedValue)
            local newCategory = selectedIndex
            if newCategory ~= currentCategory then
                currentCategory = newCategory
                searchEditBox:SetText("")  -- Clear search text when changing category
                fillBuffData(buffScrollList, 1, searchEditBox:GetText())
            end
            categoryDropdown:UpdateTextColor(selectedIndex)
        end
    )
    addTooltip("ttpCategoryDdTip", categoryDropdown, categoryDropdownTooltip)
    function categoryDropdown:UpdateTextColor(selectedIndex)
        if selectedIndex == CATEGORY_TYPE_ALL then
            self:SetAllTextColor(TINT_ALL)
        elseif selectedIndex == CATEGORY_TYPE_WATCHED then
            self:SetAllTextColor(TINT_WATCHED)
        elseif selectedIndex == CATEGORY_TYPE_LOGGED then
            self:SetAllTextColor(TINT_LOGGED)
        end
    end
    categoryDropdown:UpdateTextColor(currentCategory)


    --================= Create search box =================--
    local searchLabel
    searchEditBox, searchLabel = helpers.CreateTextEditWithLabel(
        buffSelectionWindow,
        anchors.searchEditBox,
        "Search:",
        140,        -- width
        28,         -- height
        "",         -- defaultText
        false,      -- isDigitOnly
        nil,        -- minValue
        nil,        -- maxValue
        function(value, text)
            fillBuffData(buffScrollList, 1, text)
        end
    )
    styleFieldLabel(searchLabel)
    -- Drop the gold LARGE text the helper applies, matching the flat button labels
    pcall(function()
        searchEditBox.style:SetFontSize(13)
        searchEditBox.style:SetColor(FIELD_TEXT_COLOR[1], FIELD_TEXT_COLOR[2],
                                     FIELD_TEXT_COLOR[3], FIELD_TEXT_COLOR[4])
    end)

    -- The dropdowns are ours and already sit on FIELD_ROW_Y; the search box still
    -- comes from the shared helper, which anchors it below its own label. Pin it to
    -- the same row so all three line up.
    pcall(function()
        searchEditBox:RemoveAllAnchors()
        searchEditBox:AddAnchor("TOPLEFT", trackingPanel, 310, FIELD_ROW_Y)
    end)

    addTooltip("ttpSearchTip", searchLabel,
        "Search by NAME or by buff ID. \n" ..
        "The ID is the number in brackets on each row, and the same \n" ..
        "number the logger announces in chat when it finds a new buff - \n" ..
        "paste it straight in. Exact ID matches sort to the top.")

    -- The search box is an engine widget, so its chrome is drawn from whichever
    -- in-game UI skin the player has selected. Paint a flat backdrop over it on the
    -- background layer (after the widget's own skin, beneath its text) so it
    -- matches the dropdowns on every skin.
    pcall(function()
        local border = searchEditBox:CreateColorDrawable(0, 0, 0, 0.92, "background")
        border:AddAnchor("TOPLEFT", searchEditBox, 0, 0)
        border:AddAnchor("BOTTOMRIGHT", searchEditBox, 0, 0)
        local fill = searchEditBox:CreateColorDrawable(0.10, 0.10, 0.12, 1, "background")
        fill:AddAnchor("TOPLEFT", searchEditBox, 1, 1)
        fill:AddAnchor("BOTTOMRIGHT", searchEditBox, -1, -1)
        RegisterPxInset(fill, searchEditBox)
    end)

    --================= Create select all button (flat) =================--
    selectAllButton = createFlatButton(buffSelectionWindow, "selectAllButton", "Select All", 0, 0, 104, 24, nil)
    selectAllButton:RemoveAllAnchors()
    -- Bottom bar, right side (next to the page control / count label)
    selectAllButton:AddAnchor("BOTTOMRIGHT", buffSelectionWindow, "BOTTOMRIGHT", -16, -14)

    function selectAllButton:OnClick()
        local allSelected = #filteredBuffs > 0
        for _, buff in ipairs(filteredBuffs) do
            if not isWatchedForCurrentType(buff.id) then
                allSelected = false
                break
            end
        end

        for _, buff in ipairs(filteredBuffs) do
            setWatchedForCurrentType(buff.id, not allSelected)
        end

--[[         --  "Watched Buffs" switch to  "All Buffs"
        if currentCategory == CATEGORY_TYPE_WATCHED and allSelected then
            currentCategory = CATEGORY_TYPE_ALL
            categoryDropdown:Select(currentCategory)
            categoryDropdown:UpdateTextColor(currentCategory)
        end ]]
        
        fillBuffData(buffScrollList, 1, searchEditBox:GetText())
        
        BuffSettingsWindow.SaveSettings()
    end
    selectAllButton:SetHandler("OnClick", selectAllButton.OnClick)
    

    --================= Create the buff scroll lis =================--
    buffScrollListWidth = 470
    buffScrollList = W_CTRL.CreatePageScrollListCtrl("buffScrollList", buffSelectionWindow)
    buffScrollList:SetWidth(buffScrollListWidth)
    local scrlAnchor = anchors.buffScrollList
    buffScrollList:AddAnchor(scrlAnchor.anchor, buffSelectionWindow, scrlAnchor.relativeAnchor, scrlAnchor.x, scrlAnchor.y)
    -- Right edge at -16 lines the scrollbar up with the section panels and the
    -- Select All button, which all end 16px in from the window edge
    buffScrollList:AddAnchor("BOTTOMRIGHT", buffSelectionWindow, -16, -56)
    buffScrollList:InsertColumn("", buffScrollListWidth -5, 0, DataSetFunc, nil, nil, LayoutSetFunc)
    -- Row count sets the slot height (list height / rows). 8 rows left ~31px per
    -- slot against a 30px icon, so the icons ran into each other; 7 gives ~35px.
    buffScrollList:InsertRows(7, false)
    buffScrollList:SetColumnHeight(1)

    -- The list's scrollbar is drawn from the player's UI skin, like the page
    -- control and the combo boxes were. Its widget is not exposed by name in the
    -- api stub, so probe the likely fields and paint a flat track onto whichever
    -- one answers. The paint goes on the background layer, so the thumb - which
    -- draws above it - stays visible.
    local function findChild(owner, names)
        if not owner then return nil end
        for _, name in ipairs(names) do
            local candidate = owner[name]
            if candidate and candidate.CreateColorDrawable then
                return candidate, name
            end
        end
        return nil
    end

    -- Flat fill painted over a widget. "background" sits under whatever the widget
    -- draws itself (use where a glyph or thumb must stay visible); "overlay" covers
    -- it outright (use where the widget's own art should be replaced).
    local function paintFlat(widget, layer, r, g, b, a)
        if not widget then return end
        pcall(function()
            local border = widget:CreateColorDrawable(0, 0, 0, 0.92, layer)
            border:AddAnchor("TOPLEFT", widget, 0, 0)
            border:AddAnchor("BOTTOMRIGHT", widget, 0, 0)
            local fill = widget:CreateColorDrawable(r, g, b, a, layer)
            fill:AddAnchor("TOPLEFT", widget, 1, 1)
            fill:AddAnchor("BOTTOMRIGHT", widget, -1, -1)
            RegisterPxInset(fill, widget)
        end)
    end

    local scrollWidget = findChild(buffScrollList, {
        "scroll", "scrollBar", "scrollbar", "vscroll",
        "verticalScroll", "scrollCtrl", "listScroll" })

    -- Small triangle built from stacked 1px rows, centred on its parent. Same
    -- approach as the dropdown arrow: no font glyph, so it renders identically
    -- whatever UI skin is active. dir is "up" or "down".
    local function drawTriangle(parent, dir, r, g, b)
        -- Kept narrow enough to still fit once the scrollbar is slimmed down
        local widths = { 7, 5, 3, 1 }
        local rows = {}
        for i, width in ipairs(widths) do
            local step = (dir == "up") and (#widths - i + 1) or i
            local row = parent:CreateColorDrawable(r, g, b, 1, "overlay")
            row:SetExtent(width, 1)
            row:AddAnchor("CENTER", parent, 0, -3 + step)
            rows[i] = { row = row, step = step, width = width }
        end
        -- Rows are device pixels or the glyph loses rows at sub-100% scale
        RegisterPxRefresher(function()
            for _, e in ipairs(rows) do
                e.row:SetExtent(Px(e.width), Px(1))
                e.row:RemoveAllAnchors()
                e.row:AddAnchor("CENTER", parent, 0, Px(-3 + e.step))
            end
        end)
    end

    if scrollWidget then
        -- Names confirmed against the live widget tree: the slider lives at
        -- scrollWidget.vs and its handle at scrollWidget.vs.thumb, with the bottom
        -- arrow at scrollWidget.downButton.
        local slider = findChild(scrollWidget, { "vs", "slider", "scrollBar" })
        local thumb = findChild(slider or scrollWidget, { "thumb", "handle", "grip", "bar" })
        local arrows = {}
        for dir, names in pairs({
            up = { "upButton", "up", "btnUp", "decBtn", "prevBtn", "topButton" },
            down = { "downButton", "down", "btnDown", "incBtn", "nextBtn", "bottomButton" },
        }) do
            arrows[dir] = findChild(scrollWidget, names) or findChild(slider, names)
        end

        -- Slim the bar down to 70% of the skin's default width. Each part is
        -- resized individually: narrowing the container does not cascade to the
        -- slider, thumb or end buttons.
        local SCROLLBAR_SCALE = 0.7
        local function narrow(widget)
            if not widget then return end
            pcall(function()
                local width = widget:GetWidth()
                if width and width > 0 then
                    widget:SetWidth(math.floor(width * SCROLLBAR_SCALE + 0.5))
                end
            end)
        end
        narrow(scrollWidget)
        narrow(slider)
        narrow(thumb)
        narrow(arrows.up)
        narrow(arrows.down)

        -- Painted after resizing. Track goes behind so the thumb still draws over
        -- it; the thumb and buttons go on overlay because the engine skin has to be
        -- covered rather than sat behind.
        --
        -- The track is painted 1px wider than its widget on the right: the engine
        -- sizes the thumb itself (it re-computes thumb geometry from the page
        -- count, so SetWidth on it does not stick), and its rounding leaves the
        -- thumb 1px wider than the track. Since the thumb cannot be narrowed,
        -- the track's paint is widened to meet it - anchor offsets may extend
        -- past the widget's own bounds, so this only touches our drawables.
        local TRACK_RIGHT_EXTEND = 1
        pcall(function()
            local border = scrollWidget:CreateColorDrawable(0, 0, 0, 0.92, "background")
            border:AddAnchor("TOPLEFT", scrollWidget, 0, 0)
            border:AddAnchor("BOTTOMRIGHT", scrollWidget, TRACK_RIGHT_EXTEND, 0)
            local fill = scrollWidget:CreateColorDrawable(0.10, 0.10, 0.12, 1, "background")
            fill:AddAnchor("TOPLEFT", scrollWidget, 1, 1)
            fill:AddAnchor("BOTTOMRIGHT", scrollWidget, TRACK_RIGHT_EXTEND - 1, -1)
            RegisterPxInset(fill, scrollWidget, TRACK_RIGHT_EXTEND)
        end)
        if thumb then
            -- Edge to edge rather than paintFlat's border+inset fill: the 1px inset
            -- left a dark sliver down the thumb's left side against the track.
            pcall(function()
                local fill = thumb:CreateColorDrawable(0, 0.55, 0.55, 1, "overlay")
                fill:AddAnchor("TOPLEFT", thumb, 0, 0)
                fill:AddAnchor("BOTTOMRIGHT", thumb, 0, 0)
            end)
        end
        for dir, arrow in pairs(arrows) do
            -- Same right-extension as the track: the arrow buttons are engine-sized
            -- like the thumb, so their paint is stretched to the shared right edge
            -- rather than resizing the widget.
            pcall(function()
                local border = arrow:CreateColorDrawable(0, 0, 0, 0.92, "overlay")
                border:AddAnchor("TOPLEFT", arrow, 0, 0)
                border:AddAnchor("BOTTOMRIGHT", arrow, TRACK_RIGHT_EXTEND, 0)
                local fill = arrow:CreateColorDrawable(0.14, 0.14, 0.16, 1, "overlay")
                fill:AddAnchor("TOPLEFT", arrow, 1, 1)
                fill:AddAnchor("BOTTOMRIGHT", arrow, TRACK_RIGHT_EXTEND - 1, -1)
                RegisterPxInset(fill, arrow, TRACK_RIGHT_EXTEND)
            end)
            pcall(function() drawTriangle(arrow, dir, 0.62, 0.66, 0.72) end)
        end
    else
        api.Log:Err("TrackThatPlease: scrollbar widget not found, left unstyled.")
    end

    -- Filter count label
    filteredCountLabel = buffSelectionWindow:CreateChildWidget("label", "filteredCountLabel", 0, true)
    filteredCountLabel:SetText("Displayed: 0")
    -- Same treatment as the credit line at the window's foot: it is there when
    -- wanted but should not compete with the controls beside it.
    filteredCountLabel.style:SetAlign(ALIGN.LEFT)
    filteredCountLabel.style:SetFontSize(10)
    filteredCountLabel.style:SetColor(0.30, 0.31, 0.35, 1)
    filteredCountLabel:AddAnchor("TOPLEFT", buffScrollList, "BOTTOMLEFT", 0, 8)
    
    function buffScrollList:OnPageChangedProc(curPageIdx)
        buffScrollList.curPageIdx = curPageIdx
        fillBuffData(buffScrollList, curPageIdx, searchEditBox:GetText())
    end

    --================= Custom pager =================--
    -- The engine page control is drawn from the player's UI skin like the combo
    -- boxes were, so it is hidden and replaced with flat buttons driving the same
    -- list. Its paging logic is still used - only its widgets are hidden.
    pcall(function() buffScrollList.pageControl:Show(false) end)

    local pageLabel
    local pagePrevBtn, pageNextBtn

    local function gotoPage(index)
        if index < 1 then index = 1 end
        if index > currentTotalPages then index = currentTotalPages end
        pcall(function() buffScrollList:SetCurrentPage(index) end)
        buffScrollList.curPageIdx = index
        fillBuffData(buffScrollList, index, searchEditBox:GetText())
    end

    pagePrevBtn = createFlatButton(buffSelectionWindow, "ttpPagePrev", "<", 0, 0, 26, 22, function()
        gotoPage((buffScrollList.curPageIdx or 1) - 1)
    end)

    pageNextBtn = createFlatButton(buffSelectionWindow, "ttpPageNext", ">", 0, 0, 26, 22, function()
        gotoPage((buffScrollList.curPageIdx or 1) + 1)
    end)

    pageLabel = buffSelectionWindow:CreateChildWidget("label", "ttpPageLabel", 0, true)
    pageLabel:SetExtent(58, 16)
    pageLabel:SetText("1 / 1")
    pageLabel.style:SetFontSize(13)
    pageLabel.style:SetAlign(ALIGN.CENTER)
    pageLabel.style:SetColor(1, 0.84, 0, 1)
    pageLabel:Clickable(false)

    -- Chained right to left off the Select All button rather than pinned to the
    -- window centre: the "Displayed: 151-200 / 11867" label on the left grows with
    -- the counts and used to run into a centred pager.
    -- Centred on the window rather than hung off Select All. Select All is
    -- anchored BOTTOMRIGHT at -16 and is 24 tall, so its centre line sits 26
    -- above the bottom edge; matching that keeps the whole row level while the
    -- pager itself is free to centre.
    pageLabel:RemoveAllAnchors()
    pageLabel:AddAnchor("CENTER", buffSelectionWindow, "BOTTOMLEFT", wndWidth / 2, -26)
    pagePrevBtn:RemoveAllAnchors()
    pagePrevBtn:AddAnchor("RIGHT", pageLabel, "LEFT", -6, 0)
    pageNextBtn:RemoveAllAnchors()
    pageNextBtn:AddAnchor("LEFT", pageLabel, "RIGHT", 6, 0)

    refreshPager = function()
        if not pageLabel then return end
        local page = buffScrollList.curPageIdx or 1
        if page > currentTotalPages then page = currentTotalPages end
        pageLabel:SetText(page .. " / " .. currentTotalPages)
        -- Grey the ends out rather than hiding them, so the row never reflows
        local atStart, atEnd = page <= 1, page >= currentTotalPages
        pagePrevBtn:SetFlatTextColor(atStart and 0.35 or 1, atStart and 0.35 or 1, atStart and 0.35 or 1, 1)
        pageNextBtn:SetFlatTextColor(atEnd and 0.35 or 1, atEnd and 0.35 or 1, atEnd and 0.35 or 1, 1)
    end
    refreshPager()

    -- Lets the settings layer redraw the list after the watched buffs are swapped
    -- (scope toggle, or the character name resolving after load)
    refreshWatchedUI = function()
        if buffScrollList and searchEditBox then
            fillBuffData(buffScrollList, 1, searchEditBox:GetText())
        end
    end

    fillBuffData(buffScrollList, 1, "")
    buffSelectionWindow:Show(false)

    --================= Create record all buffs button (flat, header bar) =================--
    recordAllButton = createFlatButton(buffSelectionWindow, "recordAllButton", "Start logging", wndWidth - 174, 6, 110, 22, function()
        if not BuffsLogger then return end
        if BuffsLogger.isActive then
            BuffsLogger.StopTracking()
            recordAllButton:SetFlatText("Start logging")
            recordAllButton:SetTone(TONE_IDLE)
        else
            BuffsLogger.StartTracking()
            recordAllButton:SetFlatText("Stop logging")
            recordAllButton:SetTone({0.38, 0.12, 0.12, 0.95}) -- red while recording
        end
    end)

    -- Recording indicator, immediately left of the logging button. It used to sit
    -- on the old floating HUD button, which no longer exists; main.lua pulses its
    -- alpha through GetRecordingIcon while logging is active.
    local recordingIcon = recordAllButton:CreateImageDrawable("Textures/Defaults/White.dds", "overlay")
    recordingIcon:SetExtent(16, 16)
    recordingIcon:AddAnchor("RIGHT", recordAllButton, "LEFT", -6, 0)
    recordingIcon:SetSRGB(false)
    recordingIcon:SetTgaTexture(RECORDING_ICON_PATH)
    recordingIcon:SetVisible(false)
    recordAllButton.recordingIndicationIcon = recordingIcon

    addTooltip(
        "recordAllButtonTooltip",
        recordAllButton,
        "This will start logging all buffs/debufs that are active on the player or target(s) during reccording time. \n" ..
        "So later on you can use them to add to your 'Watched buffs', \n" ..
        "You could find them under the 'All logged buffs' section of 'Buff category'"
    )

    -- OnHide handler --------------------------------
    function buffSelectionWindow:OnHide()
        -- A dropdown popup is parented to the window but shown independently, so
        -- close it explicitly rather than leaving it floating
        if openDropdown then openDropdown:HidePopup() end
        -- Same for the static-bar popup, and an open Move drag would otherwise
        -- strand the bar unlocked with its toggle button hidden
        endStaticMove()
        if staticCfgPopup then staticCfgPopup:Show(false) end
        buffScrollList:DeleteAllDatas()
        BuffSettingsWindow.SaveSettings()
    end
    buffSelectionWindow:SetHandler("OnHide", buffSelectionWindow.OnHide)
end
--============================ ### End ### ==============================--

-- Cleanup function for when the addon is unloaded
function BuffSettingsWindow.Cleanup()
    -- Save settings before cleanup to preserve user changes
    BuffSettingsWindow.SaveSettings()
    
    -- Clean up main UI window
    if buffSelectionWindow then
        -- Hide window if it's currently visible
        if buffSelectionWindow:IsVisible() then
            buffSelectionWindow:Show(false)
        end
        pcall(function() api.Interface:Free(buffSelectionWindow) end)
        buffSelectionWindow = nil
    end

end
--============================ ### End ### ==============================--

return BuffSettingsWindow