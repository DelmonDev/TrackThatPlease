local api = require("api")
local logsPath = "TrackThatPlease/buff_logs/buffsLogs.txt"
local BuffsLogger = {}
BuffsLogger.isActive = false

local buffsSet = {}
local updateTimer = 0
local updateInterval = 50 -- ms
local currentPlayerId = nil

local function escapeString(str)
    if not str then return "" end
    
    -- Escape special characters
    str = str:gsub("\"", "\\\"")  --  escape quotes
    str = str:gsub("\\", "/")     -- replace to forwardslash
    str = str:gsub("\n", "\\n")   -- Escape newlines
    str = str:gsub("\r", "\\r")   -- Escape carriage returns
    str = str:gsub("\t", "\\t")   -- Escape tabs
    
    return str
end

local function saveToFile()
    local lines = {}

    for id, entry in pairs(buffsSet) do
        table.insert(lines, string.format("[%d]: {id=%d, name=\"%s\", iconPath=\"%s\", description=\"%s\"}", 
            tonumber(id), 
            tonumber(entry.id), 
            entry.name,
            escapeString(entry.iconPath),
            escapeString(entry.description)
        )) 
    end
    local content = table.concat(lines, "\n")

    pcall(function()
        api.File:Write(logsPath, content)
    end)
end

function BuffsLogger.loadFromFile()
    local data = api.File:Read(logsPath)
    local result = {}

    if data then
        for id, id2, name, iconPath, description in data:gmatch("%[(%d+)%]: {id=(%d+), name=\"([^\"]*)\", iconPath=\"([^\"]*)\", description=\"([^\"]*)\"}") do
            result[tonumber(id)] = {
                id = tonumber(id2), 
                name = name, 
                iconPath = iconPath,
                description = description
            }
        end
    end

    return result
end

local function appendNewBuff(buff, unitName, buffTooltip)
    local entry = {
        id = buff.buff_id,
        name = buff.name or "",
        iconPath = (buff.path or ""),
        description = buff.description or "",
    }

    if not buffsSet[buff.buff_id] then
        buffsSet[buff.buff_id] = entry

        -- log new buffs
        api.Log:Info(string.format("|cFF87CEEB => BuffLogger. New buff |r|cFFFFFFFF[%d]|r = |cFFDDA0DD%s|r", tostring(entry.id), tostring(entry.name)))

        saveToFile()
    end
end 


local function trackBuffs(unitType)
    local unit = api.Unit:GetUnitId(unitType)
    if not unit then
        return
    end
    local unitName = api.Unit:GetUnitNameById(unit)

    -- Do not track self target buffs
    if unitType == "target" and unit == currentPlayerId then
        return
    end

    local buffCount = api.Unit:UnitBuffCount(unitType)
    local debuffCount = api.Unit:UnitDeBuffCount(unitType)

    if buffCount > 0 then
        for i = 1, buffCount do
            local buff = api.Unit:UnitBuff(unitType, i)
            if buff and buff.buff_id then
                local buffTooltip = api.Ability:GetBuffTooltip(buff.buff_id)
                local buffName = buffTooltip and buffTooltip.name or "Unknown"
                local buffDescription = buffTooltip and buffTooltip.description or ""

                buff.name = buffName
                buff.description = buffDescription

                appendNewBuff(buff, unitName, buffTooltip)
            else
                api.Log:Info("Failed to get buff information.")
            end
        end
    end

    if debuffCount > 0 then
        for i = 1, debuffCount do
            local debuff = api.Unit:UnitDeBuff(unitType, i)
            if debuff and debuff.buff_id then
                local debuffTooltip = api.Ability:GetBuffTooltip(debuff.buff_id)
                local debuffName = debuffTooltip and debuffTooltip.name or "Unknown"
                local buffDescription = debuffTooltip and debuffTooltip.description or ""

                debuff.name = debuffName
                debuff.description = buffDescription

                appendNewBuff(debuff, unitName, debuffTooltip)
            else
                api.Log:Info("Failed to get debuff information.")
            end
        end
    end
end

function BuffsLogger.Initialize() 
    buffsSet = {}
    buffsSet = BuffsLogger.loadFromFile()
    currentPlayerId = api.Unit:GetUnitId("player")

    -- Sorting by buff name
    local buffsCount = 0
    local sortArray = {}

    for id, entry in pairs(buffsSet) do
        table.insert(sortArray, {id = id, entry = entry})
        buffsCount = buffsCount + 1
    end

    table.sort(sortArray, function(a, b)
        local nameA = (a.entry.name or ""):lower()
        local nameB = (b.entry.name or ""):lower()
        return nameA < nameB
    end)
    
    local sortedBuffsSet = {}
    for _, item in ipairs(sortArray) do
        sortedBuffsSet[item.id] = item.entry
    end
    buffsSet = sortedBuffsSet
    -- Save sorted buffs to file
    saveToFile()
    -------------------------------------
    
    api.Log:Info("|cFF00FFFF=== Buffs tracker loaded: |cFFFFFFFF" .. buffsCount .. "|r buffs|r")
end

function BuffsLogger.StartTracking() 
    BuffsLogger.isActive = true
    api.Log:Info("|cFF00FFFF=== Buffs loggers|cFF006600 started|r tracking buffs ===|r")
end

function BuffsLogger.StopTracking() 
    BuffsLogger.isActive = false
    api.Log:Info("|cFF00FFFF=== Buffs|cFFAA0000 stopped|r tracking buffs ===|r")
end

function BuffsLogger.GetBuffsSetCopy()
    local copy = {}
    
    for id, entry in pairs(buffsSet) do
        copy[id] = {
            id = entry.id,
            name = entry.name,
            iconPath = entry.iconPath,
            description = entry.description
        }
    end
    
    return copy
end

function BuffsLogger.Track(currentDt)
    -- Track every 50 ms
    if BuffsLogger.isActive then
        updateTimer = updateTimer + currentDt

        if updateTimer >= updateInterval and BuffsLogger.isActive then
            trackBuffs("target")
            trackBuffs("player")
            updateTimer = 0
        end
    end
end

function BuffsLogger.CleanUp() 
    BuffsLogger.isActive = false
    currentPlayerId = nil
    buffsSet = {}
end

return BuffsLogger
