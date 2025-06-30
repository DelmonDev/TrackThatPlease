local staticBuffList  = require("TrackThatPlease/static_buff_list")

local BuffsLogger
local ALL_BUFFS = staticBuffList.ALL_BUFFS
local ddsData = staticBuffList.ddsData
local BuffHelper = {}

-- This function returns the buff info given a buff ID
function BuffHelper.GetBuffInfo(buffId)
    for _, buffInfo in ipairs(ALL_BUFFS) do
        if buffInfo.id == buffId then
            return buffInfo
        end
    end
    return nil
end

-- This function returns the buff name given a buff ID
function BuffHelper.GetBuffName(buffId)
    local buffInfo = BuffHelper.GetBuffInfo(buffId)
    return buffInfo and buffInfo.name or "Unknown Buff"
end

-- Function to get the icon path for a given buff ID
function BuffHelper.GetBuffIcon(buffId)
    local iconPath = ddsData[buffId]
    return iconPath and ("game/ui/icon/" .. iconPath) or "game/ui/icon/icon_skill_buff274.dds"
    
end

function BuffHelper.InitializeAllBuffs(buffsLogger)
    BuffsLogger = buffsLogger

    local allbufs = ALL_BUFFS
    local filteredBuffsArr = {}
    local idIndex = {}

    local buffsFromLogger = BuffsLogger.loadFromFile()

    for _, buffInfo in ipairs(allbufs) do
        local id = buffInfo.id
        local name = buffInfo.name
        local iconPath = ddsData[id]
        iconPath = iconPath and ("game/ui/icon/" .. iconPath) or "game/ui/icon/icon_skill_buff274.dds"
        local description = ""  -- Default empty description
        
        -- Override with data from logger if exists
        local loggerBuff = buffsFromLogger[id]
        if loggerBuff then
            -- Override name if logger has it
            if loggerBuff.name and loggerBuff.name ~= "" and loggerBuff.name ~= "Unknown" then
                name = loggerBuff.name
            end
            
            -- Override iconPath if logger has it
            if loggerBuff.iconPath and loggerBuff.iconPath ~= "" then
                iconPath = loggerBuff.iconPath
            end
            
            -- Add description from logger
            if loggerBuff.description and loggerBuff.description ~= "" then
                description = loggerBuff.description
            end
        end
        
        local entry = {
            id = id,
            name = name,
            iconPath = iconPath,
            description = description
        }
        
        table.insert(filteredBuffsArr, entry)
        idIndex[id] = entry
    end

    -- Second pass: add buffs from buffsFromLogger that are not already in idIndex
    if buffsFromLogger then
        for idFromLogger, loggerBuff in pairs(buffsFromLogger) do
            if not idIndex[idFromLogger] then -- Check if this ID was not in ALL_BUFFS
                local iconPath = loggerBuff.iconPath

                local entry = {
                    id = idFromLogger,
                    name = loggerBuff.name, 
                    iconPath = loggerBuff.iconPath,
                    description = loggerBuff.description 
                }
                table.insert(filteredBuffsArr, entry)
                idIndex[idFromLogger] = entry
            end
        end
    end

    table.sort(filteredBuffsArr, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    BuffHelper.AllBuffs = filteredBuffsArr
    BuffHelper.AllBuffsIndex = idIndex
end

return BuffHelper