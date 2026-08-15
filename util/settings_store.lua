local api = require("api")

-- ============================================================================
-- Private, crash-resilient settings persistence (3.1)
--
-- TrackThatPlease's settings no longer live in the client's shared
-- `addon_settings` file. That file is one blob for every addon, and the client
-- rewrites it non-atomically: File:Write opens with "w" - truncating the file
-- on the spot - and only THEN serializes the table. A death between those two
-- steps (an out-of-memory failure inside the serializer is exactly what a long
-- session on the 32-bit client produces) leaves a 0-byte file, and on the next
-- boot the client silently replaces it with `{enabled=true}` defaults for
-- EVERY addon and rewrites it, making the loss permanent. Diagnosed from a
-- player's crash logs (Aug 2026); BetterBars 3.2 and power_ranger_on ship the
-- same defense.
--
-- So TrackThatPlease keeps its own file pair. api.SaveSettings is called at
-- most ONCE per install - the boot-time flush that purges its legacy branch
-- from the shared file (see scrubEngineBranch) - and never on a gameplay
-- path: it can neither suffer that wipe nor put the shared file at risk
-- when it matters. The shared store is still READ once to
-- migrate a pre-3.1 save (all schema versions: the v0/v1/v2 migration in
-- buff_settings_wnd runs on the root AFTER this store produces it, exactly as
-- it did on the engine's table), and still owns the addon manager's `enabled`
-- flag.
--
-- Both files live at the Addon ROOT (next to `addon_settings`, outside the
-- TrackThatPlease folder): the File API is rooted there, the root always
-- exists (File:Write creates no directories), and root files survive addon
-- updates and even full delete-and-reinstalls.
--
-- Large integers are encoded as "__n__<digits>" strings on write and decoded
-- on read. The client's serializer renders numbers with tostring, which this
-- client builds at ~6 significant figures - any raw integer >= 100000 (every
-- 7+ digit buff id) would be ROUNDED on save (8000138 -> 8000140). The live
-- watched lists already store ids as strings, but a v0 `legacyBackupV1`
-- snapshot can carry raw numeric ids, and the encoding keeps anything numeric
-- exact forever. (Same approach power_ranger_on/ezcd/nuzi use.)
-- ============================================================================

local Store = {}

local SETTINGS_PATH = "TrackThatPlease_settings.lua"
local BACKUP_PATH = "TrackThatPlease_settings_backup.lua"

-- The ONE root table for the whole session. Loads populate it in place, so
-- every module that grabbed it once keeps a valid reference forever - this
-- replaces the old detached-root fold-in dance in buff_settings_wnd.
local ROOT = {}
local loadedOnce = false
-- The private files are tried once per session: they cannot appear on their
-- own later, and Root() is called from UPDATE handlers - it must not do disk
-- reads per tick while a fresh install waits for the engine store.
local filesTried = false

local INT_PREFIX = "__n__"

local function isBigInt(v)
    return type(v) == "number" and math.floor(v) == v
        and (v >= 100000 or v <= -100000)
end

-- string.format("%.0f") goes through C's printf at full precision - it does
-- NOT pass through the truncated tostring, so the digits survive exactly.
local function encodeValue(v)
    if isBigInt(v) then return INT_PREFIX .. string.format("%.0f", v) end
    return v
end

local function decodeValue(v)
    if type(v) == "string" then
        local digits = v:match("^__n__(%-?%d+)$")
        if digits then return tonumber(digits) end
    end
    return v
end

-- Deep-copies tbl with big integers encoded, for the write side. The live
-- ROOT is never mutated. A cycle is dropped rather than raised: the client
-- serializer would abort the whole write on one.
local function encodeTable(tbl, seen)
    seen = seen or {}
    if seen[tbl] then return nil end
    seen[tbl] = true
    local out = {}
    for k, v in pairs(tbl) do
        local key = encodeValue(k)
        if type(v) == "table" then
            out[key] = encodeTable(v, seen)
        else
            out[key] = encodeValue(v)
        end
    end
    seen[tbl] = nil
    return out
end

-- Decodes a freshly deserialized table in place. Key renames are collected
-- and applied after the pairs loop - adding keys during traversal is
-- undefined behaviour in Lua.
local function decodeTable(tbl)
    local renamed
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            decodeTable(v)
        else
            local dv = decodeValue(v)
            if dv ~= v then tbl[k] = dv end
        end
        local dk = decodeValue(k)
        if dk ~= k then
            renamed = renamed or {}
            renamed[#renamed + 1] = k
        end
    end
    if renamed then
        for _, oldKey in ipairs(renamed) do
            tbl[decodeValue(oldKey)] = tbl[oldKey]
            tbl[oldKey] = nil
        end
    end
    return tbl
end

-- Plain deep copy (no encoding) for migrating the engine's table: ROOT holds
-- raw values; encoding happens only at write time.
local function deepCopy(tbl, seen)
    seen = seen or {}
    if seen[tbl] then return nil end
    seen[tbl] = true
    local out = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            out[k] = deepCopy(v, seen)
        else
            out[k] = v
        end
    end
    seen[tbl] = nil
    return out
end

-- Read one private file defensively. File:Read RAISES on a file that exists
-- but no longer deserializes (the truncated-by-a-crash case), so the pcall is
-- load-bearing. Only a non-empty table counts as a usable save; `next` is not
-- in the sandbox whitelist, so emptiness is probed with pairs.
local function readPrivate(path)
    local ok, data = pcall(function() return api.File:Read(path) end)
    if not ok or type(data) ~= "table" then return nil end
    for _ in pairs(data) do return decodeTable(data) end
    return nil
end

-- Scrub the engine's branch down to the bare `enabled` flag the addon
-- manager owns. power_ranger_on's stance, adopted here too (user call):
-- once the private pair is the source of truth, nothing of ours belongs in
-- the shared file - no replica, and no stale copy from earlier builds
-- lingering there. The accepted trade: if BOTH private files are ever lost
-- at once, the migration path finds nothing and the addon starts from
-- defaults. Runs after every load and save, so a branch populated by an
-- older build empties on the first boot of this one. The migration path in
-- Load deep-copies the engine table BEFORE any of this runs, so emptying
-- the branch can never touch the live ROOT.
local function scrubEngineBranch()
    local engineTable = api.GetSettings("TrackThatPlease")
    if type(engineTable) ~= "table" then return end
    local removed = 0
    for k in pairs(engineTable) do
        if k ~= "enabled" then
            engineTable[k] = nil
            removed = removed + 1
        end
    end
    -- One-shot flush: scrubbing only empties the IN-MEMORY table, and the
    -- client's boot rewrite copies the stale file branch back before addons
    -- load - without this, machines where no other addon saves mid-session
    -- would carry the stale keys forever. Fires only when something was
    -- actually removed (i.e. the transition boot; afterwards the branch
    -- arrives bare), and only on a REAL engine read - never from the
    -- parse-time detached table.
    if removed > 0 and engineTable.enabled ~= nil then
        pcall(function() api.SaveSettings() end)
    end
end

-- Save ROOT to the private pair. Backup FIRST: if the process dies mid-write
-- (the crash that motivated all this), dying during the backup write leaves
-- the previous primary intact, and dying during the primary write leaves a
-- fresh backup to heal from on the next boot. Either order keeps one good
-- copy; backup-first just makes the surviving copy the fresher one.
-- Never throws: every step is pcall'd, because saves run inside UI handlers.
function Store.Save()
    local ok, payload = pcall(encodeTable, ROOT)
    if not ok or type(payload) ~= "table" then return end
    pcall(function() api.File:Write(BACKUP_PATH, payload) end)
    pcall(function() api.File:Write(SETTINGS_PATH, payload) end)
    pcall(scrubEngineBranch)
end

-- Populate ROOT: primary file, then backup, then the shared store (a pre-3.1
-- save of any schema version, or a fresh install's bare `{enabled=true}`).
-- Persisted content wins per key; keys that exist only in ROOT (written by
-- code that ran before the load) survive.
function Store.Load()
    if loadedOnce then return ROOT end
    local saved
    local needsSave = false
    if not filesTried then
        filesTried = true
        saved = readPrivate(SETTINGS_PATH)
        if saved == nil then
            saved = readPrivate(BACKUP_PATH)
            if saved ~= nil then
                -- Primary lost or corrupt but the mirror survived: heal it.
                needsSave = true
            end
        end
    end
    if saved == nil then
        local engine = api.GetSettings("TrackThatPlease")
        -- `enabled` is how a REAL engine read is told apart from an early
        -- one: the client stamps `{enabled=true}` on every entry when its
        -- store initializes, while a read at chunk time gets nil or a
        -- detached empty table. Migrating THAT would freeze an empty root
        -- into the private file, shadowing the player's real save forever -
        -- so only a real read migrates; the next Root() call after the store
        -- is ready does it for real.
        if type(engine) == "table" and engine.enabled ~= nil then
            saved = deepCopy(engine)
            needsSave = true
        end
    end
    if saved ~= nil then
        for k, v in pairs(saved) do ROOT[k] = v end
        loadedOnce = true
        if needsSave then Store.Save() end
        -- Ordinary boots save nothing, so the cleanup runs here too
        pcall(scrubEngineBranch)
    end
    return ROOT
end

-- The live root table. Always a table, never nil; cheap after the first
-- successful load, so it is safe to call from UPDATE handlers.
function Store.Root()
    return Store.Load()
end

return Store
