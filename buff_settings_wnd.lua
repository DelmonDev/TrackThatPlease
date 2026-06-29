local api = require("api")
local BuffList = require("TrackThatPlease/buff_helper")
local helpers = require("TrackThatPlease/util/helpers")
local BuffsLogger

local BuffSettingsWindow = {}
BuffSettingsWindow.settings = {}
-- Last element of maxBuffsOptions must be equal to this
BuffSettingsWindow.MAX_BUFFS_COUNT = 25 

local serializedSettings = {}

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

local filteredBuffs = {}
local currentTrackType = 1  -- 1 for Player, 2 for Target
local isSelectedAll = false

local function BuildNumericOptions(minValue, maxValue, step)
    local options = {}
    local value = minValue

    while value <= maxValue do
        table.insert(options, tostring(value))
        value = value + step
    end

    return options
end

local maxBuffsOptions = BuildNumericOptions(1, BuffSettingsWindow.MAX_BUFFS_COUNT, 1)
local iconSpacingOptions = BuildNumericOptions(0, 20, 1)
local iconSizeOptions = BuildNumericOptions(16, 64, 1)
local fontSizeOptions = BuildNumericOptions(8, 40, 1)
local warnTimeOptions = BuildNumericOptions(0.5, 30, 0.5)
local buffsXOffsetOptions = BuildNumericOptions(-300, 300, 1)
local buffsYOffsetOptions = BuildNumericOptions(-200, 200, 1)
local smoothingSpeedOptions = BuildNumericOptions(0, 40, 1)
local blinkSpeedOptions = BuildNumericOptions(0.5, 5, 0.5)
local buffScrollListWidth

-- Scroll and pagination
local pageSize = 50
local categories = {"All static buffs", "All logged buffs", "Watched buffs"}
local trackTypes = {"Player", "Target"}
local TRACK_TYPE_PLAYER = 1
local TRACK_TYPE_TARGET = 2
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

local function GetOptionBounds(options)
    local minValue = tonumber(options[1])
    local maxValue = tonumber(options[#options])
    return minValue, maxValue
end

local function NormalizeWarnTimeMilliseconds(value, defaultValue)
    local numericValue = tonumber(value) or defaultValue or 1000
    local normalizedHalfSeconds = math.floor((numericValue / 500) + 0.5)

    if normalizedHalfSeconds < 1 then
        normalizedHalfSeconds = 1
    elseif normalizedHalfSeconds > 60 then
        normalizedHalfSeconds = 60
    end

    return normalizedHalfSeconds * 500
end

local function PrintBuffWatchWindowSettings()
    api.Log:Info("|cFF00FFFF====== serializedSettings ======|r")
    
    if not serializedSettings then
        api.Log:Info("|cFFFF6347serializedSettings is nil!|r")
    else
        for key, value in pairs(serializedSettings) do
            if type(value) == "table" then
                local count = #value
                api.Log:Info(string.format("|cFFFFD700%s|r: |cFF98FB98(array with %d items)|r", key, count))
                
                local shown = 0
                for k, v in pairs(value) do
                    if shown < 3 then
                        api.Log:Info(string.format("  |cFFDDA0DD[%s]|r = |cFFFFFFFF%s|r", tostring(k), tostring(v)))
                        shown = shown + 1
                    else
                        api.Log:Info("  |cFF87CEEB... (more items)|r")
                        break
                    end
                end
            else
                api.Log:Info(string.format("|cFFFFD700%s|r: |cFFFFFFFF%s|r", key, tostring(value)))
            end
        end
    end
    
    api.Log:Info("|cFF00FFFF=== End Debug Output ===|r")
end

--============================ ### Settings section ### ==============================--

function BuffSettingsWindow.SaveSettings()
    -- Convert hash tables to serialized arrays for storage
    local serializedPlayerBuffs = {}
    local serializedTargetBuffs = {}
    
    for buffId, _ in pairs(playerWatchedBuffs) do
        table.insert(serializedPlayerBuffs, SerializeNumber(buffId))
    end
    
    for buffId, _ in pairs(targetWatchedBuffs) do
        table.insert(serializedTargetBuffs, SerializeNumber(buffId))
    end

    -- Save serialized data to disk
    serializedSettings.playerWatchedBuffs = serializedPlayerBuffs
    serializedSettings.targetWatchedBuffs = serializedTargetBuffs
    -- All others settings
    for key, value in pairs(BuffSettingsWindow.settings) do
        serializedSettings[key] = value
    end
    
    --PrintBuffWatchWindowSettings()

    -- Safely Save settings to file
    pcall(function()
        api.SaveSettings()
    end)
end

local function loadSettings()
    api.Log:Err("Start Loading settings for TrackThatPlease")
    local defaultX = (api.Interface:GetScreenWidth() / 2) -42 -- Center button (42 is half of button width)
    local defaultSettings = {
        UIScale = api.Interface:GetUIScale(),
        fontSize = 12,
        targetBuffHorizontalOffset = 0,
        targetBuffVerticalOffset = -38,
        playerBuffHorizontalOffset = 0,
        playerBuffVerticalOffset = -38,
        showAbovePlayerUnitFrame = false,
        showAboveTargetUnitFrame = false,
        iconSize = 34,
        iconSpacing = 3,
        maxBuffsShown = 5,
        debuffWarnTime = 2000,
        buffWarnTime = 3000,
        smoothingSpeed = 8,
        buffBlinkSpeed = 5,
        shouldShowStacks = true,
        btnSettingsPos = { defaultX, 25 },
    }
    --[[ -- Expected keys
        local allowedKeys = {}
        for key, _ in pairs(defaultSettings) do
            allowedKeys[key] = true
        end
        allowedKeys.playerWatchedBuffs = true
        allowedKeys.targetWatchedBuffs = true
        allowedKeys.enabled = true -- VERY IMPORTANT KEY 
    --]]

    -- Load Settings
    serializedSettings = api.GetSettings("TrackThatPlease") or {}
    --[[    -- Clear unexpected keys
            for key in pairs(serializedSettings) do
            if not allowedKeys[key] then
                serializedSettings[key] = nil
            end
        end 
    --]]

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
    
    -- Safe initialization of settings
    BuffSettingsWindow.settings = {}

    for k, defaultValue in pairs(defaultSettings) do
        BuffSettingsWindow.settings[k] = ensureType(serializedSettings[k], defaultValue)
    end

    BuffSettingsWindow.settings.debuffWarnTime = NormalizeWarnTimeMilliseconds(
        BuffSettingsWindow.settings.debuffWarnTime,
        defaultSettings.debuffWarnTime
    )
    BuffSettingsWindow.settings.buffWarnTime = NormalizeWarnTimeMilliseconds(
        BuffSettingsWindow.settings.buffWarnTime,
        defaultSettings.buffWarnTime
    )

    serializedSettings.debuffWarnTime = BuffSettingsWindow.settings.debuffWarnTime
    serializedSettings.buffWarnTime = BuffSettingsWindow.settings.buffWarnTime
    
    -- Load player buffs from serialized data
    local savedPlayerBuffs = serializedSettings.playerWatchedBuffs or {}
    playerWatchedBuffs = {}
    for _, idString in ipairs(savedPlayerBuffs) do
        local buffId = DeserializeNumber(idString)
        if buffId then
            playerWatchedBuffs[buffId] = true
        end
    end
    
    -- Load target buffs from serialized data
    local savedTargetBuffs = serializedSettings.targetWatchedBuffs or {}
    targetWatchedBuffs = {}
    for _, idString in ipairs(savedTargetBuffs) do
        local buffId = DeserializeNumber(idString)
        if buffId then
            targetWatchedBuffs[buffId] = true
        end
    end
end
--============================ ### End ### ==============================--

--============================ ### Scroll list functions ### ==============================--
local function updateSelectAllButton()
    if selectAllButton then
        local watchedBuffs = currentTrackType == TRACK_TYPE_PLAYER and playerWatchedBuffs or targetWatchedBuffs
        
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
            selectAllButton:Enable(false)
            selectAllButton:SetText("Too many buffs")
            selectAllButton:SetTextColor(0.5, 0.5, 0.5, 1) -- Gray text
        else
            -- Enable button and check selection state
            selectAllButton:Enable(true)
            selectAllButton:SetTextColor(unpack(FONT_COLOR.DEFAULT)) -- Normal text color
            
            local allSelected = false
            if #filteredBuffs > 0 then
                allSelected = true 
                for _, buff in ipairs(filteredBuffs) do
                    if not watchedBuffs[buff.id] then
                        allSelected = false
                        break
                    end
                end
            end
            
            selectAllButton:SetText(allSelected and "Unselect All" or "Select All")
        end
    end
end

-- Update the appearance of a buff icon
local function UpdateBuffSelectedAppearance(subItem, buffId)
    local isWatched = false
    
    if currentTrackType == TRACK_TYPE_PLAYER then -- Player
        isWatched = BuffSettingsWindow.IsPlayerBuffWatched(buffId)
    else -- Target
        isWatched = BuffSettingsWindow.IsTargetBuffWatched(buffId)
    end
    
    if isWatched then
        subItem.checkmarkIcon:SetCoords(852,49,15,15)
    else
        subItem.checkmarkIcon:SetCoords(832,49,15,15)
    end
    subItem.checkmarkIcon:Show(true)
end

local function updatePageCount(totalItems)
    local maxPages = math.ceil(totalItems / pageSize)
    buffScrollList:SetPageByItemCount(totalItems, pageSize)
    buffScrollList.pageControl:SetPageCount(maxPages)
    if buffScrollList.curPageIdx and buffScrollList.curPageIdx > maxPages then
        buffScrollList:SetCurrentPage(maxPages)
    end
end

-- Fill buff data for the scroll list
local function fillBuffData(buffScrollList, pageIndex, searchText)
    local startingIndex = ((pageIndex - 1) * pageSize) + 1 
    buffScrollList:DeleteAllDatas()
    
    local count = 1
    filteredBuffs = {}
    
    local function addBuff(buff)
        if searchText == "" or string.find(buff.name:lower(), searchText:lower()) then
            -- Calculate relevance score for search results
            local relevanceScore = 0
            if searchText ~= "" then
                local lowerName = buff.name:lower()
                local lowerSearch = searchText:lower()
                
                -- Exact match gets highest score
                if lowerName == lowerSearch then
                    relevanceScore = 1000
                -- Starts with search term gets high score
                elseif string.find(lowerName, "^" .. lowerSearch) then
                    relevanceScore = 500
                -- Contains search term gets medium score
                elseif string.find(lowerName, lowerSearch) then
                    -- Shorter names with match get higher score
                    relevanceScore = 100 + (100 - string.len(buff.name))
                end
            end
            
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
        local watchedBuffs = currentTrackType == TRACK_TYPE_PLAYER and playerWatchedBuffs or targetWatchedBuffs
        for buffId, _ in pairs(watchedBuffs) do
            local buff = BuffList.AllBuffsIndex[buffId]
            if buff then
                addBuff(buff)
            end
        end
    elseif currentCategory == CATEGORY_TYPE_LOGGED then
        local loggedBuffs = BuffsLogger.GetBuffsSetCopy()

        for buffId, buff in pairs(loggedBuffs) do
            addBuff(buff)
        end
    end
    
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
            local buffData = {
                id = buff.id,
                name = buff.name,
                iconPath = buff.iconPath,
                description = buff.description,
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
        local id = data.id
        subItem.id = id
        subItem.description = data.description

        local formattedText = string.format(
            "%s |cFFFFE4B5[%d]|r", 
            data.name,
            data.id 
        )
        
        subItem.textbox:SetText(formattedText)
        F_SLOT.SetIconBackGround(subItem.subItemIcon, data.iconPath)

        UpdateBuffSelectedAppearance(subItem, id)
    end
end

-- Create layout for each buff item in the list
local function LayoutSetFunc(frame, rowIndex, colIndex, subItem)
    local rowHeight = 80
    subItem:SetExtent(buffScrollListWidth - 150, rowHeight) 

    -- Add background
    local background = subItem:CreateImageDrawable(TEXTURE_PATH.HUD, "background")
    background:SetCoords(453, 145, 230, 23)
    background:AddAnchor("TOPLEFT", subItem, -70, 4)
    background:AddAnchor("BOTTOMRIGHT", subItem, -70, 4)

    -- Icon ----------------------
    local iconSize = 33
    local subItemIcon = CreateItemIconButton("subItemIcon", subItem)
    subItemIcon:SetExtent(iconSize, iconSize)
    subItemIcon:Show(true)
    F_SLOT.ApplySlotSkin(subItemIcon, subItemIcon.back, SLOT_STYLE.BUFF)
    subItemIcon:AddAnchor("LEFT", subItem, 5, 2)

    -- Setup tooltip ---------------------------------
    function subItemIcon:OnEnter()
        if not subItem.description or string.len(subItem.description) == 0 then
            return
        end
        -- get back line carriages
        local formattedDescription = string.gsub(subItem.description, "\\n", "\n")

        local posX, posY = api.Input:GetMousePos()
        api.Interface:SetTooltipOnPos(formattedDescription, subItem.subItemIcon, posX, posY)
    end
    function subItemIcon:OnLeave()
        api.Interface:SetTooltipOnPos(nil, subItem.subItemIcon, 0, 0)
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

    -- checkmark config
    local checkmarkIcon = subItem:CreateImageDrawable(TEXTURE_PATH.HUD, "overlay")
    checkmarkIcon:SetExtent(14, 14)
    checkmarkIcon:AddAnchor("LEFT", subItemIcon, "RIGHT", buffScrollListWidth - 145, 0) 
    checkmarkIcon:Show(true)
    subItem.checkmarkIcon = checkmarkIcon

    local clickOverlay = subItem:CreateChildWidget("button", "clickOverlay", 0, true)
    clickOverlay:AddAnchor("TOPLEFT", subItem, 45, 0)  -- Відступ 45 пікселів зліва
    clickOverlay:AddAnchor("BOTTOMRIGHT", subItem, 0, 0)

    function clickOverlay:OnClick()
        local buffId = subItem.id
        BuffSettingsWindow.ToggleBuffWatch(buffId)
        UpdateBuffSelectedAppearance(subItem, buffId)
        
        if currentCategory == CATEGORY_TYPE_WATCHED then
            local isWatched = false
            if currentTrackType == TRACK_TYPE_PLAYER then
                isWatched = BuffSettingsWindow.IsPlayerBuffWatched(buffId)
            else
                isWatched = BuffSettingsWindow.IsTargetBuffWatched(buffId)
            end
            -- Remove from Whached list if unwatched
            if not isWatched then
                fillBuffData(buffScrollList, buffScrollList.curPageIdx or 1, searchEditBox:GetText())
            else
                updateSelectAllButton()
            end
        else
            updateSelectAllButton()
        end
        
        BuffSettingsWindow.SaveSettings()
    end 
    clickOverlay:SetHandler("OnClick", clickOverlay.OnClick)
end
--============================ ### End ### ==============================--

--============================ ### BuffWatchWindow external functions ### ==============================--
-- Toggle a buff's watched status based on current tracking type
function BuffSettingsWindow.ToggleBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    
    if currentTrackType == TRACK_TYPE_PLAYER then -- Player
        BuffSettingsWindow.TogglePlayerBuffWatch(buffId)
    else -- Target
        BuffSettingsWindow.ToggleTargetBuffWatch(buffId)
    end
end

-- Toggle a player buff's watched status
function BuffSettingsWindow.TogglePlayerBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    
    if playerWatchedBuffs[buffId] then
        playerWatchedBuffs[buffId] = nil
    else
        playerWatchedBuffs[buffId] = true
    end
end

-- Toggle a target buff's watched status
function BuffSettingsWindow.ToggleTargetBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    
    if targetWatchedBuffs[buffId] then
        targetWatchedBuffs[buffId] = nil
    else
        targetWatchedBuffs[buffId] = true
    end
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

-- Toggle the buff selection window visibility
function BuffSettingsWindow.ToggleBuffSelectionWindow()
    if buffSelectionWindow then
        local isVisible = buffSelectionWindow:IsVisible()
        buffSelectionWindow:Show(not isVisible)
        if not isVisible then
            fillBuffData(buffScrollList, 1, searchEditBox:GetText())
        end
    else
        api.Log:Err("Buff selection window does not exist")
    end
end

-- Check if the buff selection window is visible
function BuffSettingsWindow.IsWindowVisible()
    return buffSelectionWindow and buffSelectionWindow:IsVisible() or false
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
    local columnWidth = 160
    local sliderRowHeight = 60
    local positionRowHeight = 60
    local controlRowHeight = 60
    local controlsTopGap = 4
     local leftMargin = 28
     local topMargin = 52
     -- Column positions
     local x1 = leftMargin
     local x2 = leftMargin + columnWidth + columnGap
     local x3 = leftMargin + (columnWidth + columnGap) * 2
     -- Row positions
     local y1 = topMargin
     local y2 = y1 + sliderRowHeight
     local y3 = y2 + sliderRowHeight
     local y4 = y3 + sliderRowHeight
    local y5 = y4 + positionRowHeight
    local y6 = y5 + controlRowHeight + controlsTopGap
    local y7 = y6 + controlRowHeight
    local y8 = y7 + controlRowHeight
    
    
    --================= Create the main window =================--
    buffSelectionWindow = api.Interface:CreateWindow("buffSelectorWindow", "Track List")
    buffSelectionWindow:SetWidth(600)
    buffSelectionWindow:SetHeight(900)
    buffSelectionWindow:AddAnchor("CENTER", "UIParent", "CENTER", 0, 0)

    local function createAnchor(x, y)
        return {
            anchor = "TOPLEFT",
            target = buffSelectionWindow,
            relativeAnchor = "TOPLEFT",
            x = x,
            y = y
        }
    end

    local anchors = {
        -- Row 1
        maxBuffsDropdown = createAnchor(x1, y1),
        fontSizeDropdown = createAnchor(x2, y1),
        iconSizeDropdown = createAnchor(x3, y1),
        -- Row 2
        iconSpacingDropdown = createAnchor(x1, y2),
        debuffWarnTimeDropdown = createAnchor(x2, y2),
        buffWarnTimeDropdown = createAnchor(x3, y2),
        -- Row 3
        smoothingSpeedDropdown = createAnchor(x1, y3),
        blinkSpeedDropdown = createAnchor(x2, y3),
        playerHorizontalOffsetDropdown = createAnchor(x1, y4),
        playerVerticalOffsetDropdown = createAnchor(x2, y4),
        targetHorizontalOffsetDropdown = createAnchor(x1, y5),
        targetVerticalOffsetDropdown = createAnchor(x2, y5),
        -- Row 4
        playerAboveUnitFrameCheckbox = createAnchor(x3, y4 + 18),
        targetAboveUnitFrameCheckbox = createAnchor(x3, y5 + 18),
        -- Row 5
        trackTypeDropdown = createAnchor(x1, y6),
        categoryDropdown = createAnchor(x2, y6),
        shouldShowStacksCheckbox = createAnchor(x3, y6),
        -- Row 6
        searchEditBox = createAnchor(x1, y7),
        selectAllButton = createAnchor(x3 + 16, y7 + 16),
        -- Row 7
        buffScrollList = createAnchor(leftMargin, y8),
    }

    --================= Create trackTypeDropdown =================--
    local trackTypeLabel
    trackTypeDropdown, trackTypeLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.trackTypeDropdown,
        "Track type:",
        0, -- Width will be set automatically
        trackTypes,
        currentTrackType, -- "Player" as default
        function(selectedIndex, selectedValue)
            local newTrackType = selectedIndex
            if newTrackType ~= currentTrackType then
                currentTrackType = newTrackType
                searchEditBox:SetText("")
                fillBuffData(buffScrollList, 1, searchEditBox:GetText())
            end
            if selectedIndex == TRACK_TYPE_PLAYER then -- Player
                trackTypeDropdown:SetAllTextColor({0.0, 0.4, 0.0, 0.9})
            elseif selectedIndex == TRACK_TYPE_TARGET then -- Target
                trackTypeDropdown:SetAllTextColor({0.5, 0.0, 0.0, 0.9})
            end
        end
    )
    trackTypeDropdown:SetAllTextColor({0.0, 0.4, 0.0, 0.9})

    --================= Create shouldShowStacks checkbox =================--
    local shouldShowStacksCheckbox, shouldShowStacksLabel = helpers.CreateCheckboxWithLabel(
        buffSelectionWindow,
        anchors.shouldShowStacksCheckbox,
        "Show stacks:",
        "Yes",
        BuffSettingsWindow.settings.shouldShowStacks,
        function(isChecked)
            BuffSettingsWindow.settings.shouldShowStacks = isChecked
            BuffSettingsWindow.SaveSettings()
        end
    )
    

    --================= Create numeric sliders =================--
    local maxBuffsMin, maxBuffsMax = GetOptionBounds(maxBuffsOptions)
    local _, maxBuffsLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.maxBuffsDropdown,
        "Max buffs to display:",
        columnWidth,
        BuffSettingsWindow.settings.maxBuffsShown,
        maxBuffsMin,
        maxBuffsMax,
        1,
        function(value)
            BuffSettingsWindow.settings.maxBuffsShown = value
            BuffSettingsWindow.SaveSettings()
        end,
        "Maximum number of tracked buffs to display"
    )

    local iconSizeMin, iconSizeMax = GetOptionBounds(iconSizeOptions)
    local _, iconSizeLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.iconSizeDropdown,
        "Icon size:",
        columnWidth,
        BuffSettingsWindow.settings.iconSize,
        iconSizeMin,
        iconSizeMax,
        1,
        function(value)
            BuffSettingsWindow.settings.iconSize = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local iconSpacingMin, iconSpacingMax = GetOptionBounds(iconSpacingOptions)
    local _, iconSpacingLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.iconSpacingDropdown,
        "Icon spacing:",
        columnWidth,
        BuffSettingsWindow.settings.iconSpacing,
        iconSpacingMin,
        iconSpacingMax,
        1,
        function(value)
            BuffSettingsWindow.settings.iconSpacing = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local fontSizeMin, fontSizeMax = GetOptionBounds(fontSizeOptions)
    local _, fontSizeLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.fontSizeDropdown,
        "Text size:",
        columnWidth,
        BuffSettingsWindow.settings.fontSize,
        fontSizeMin,
        fontSizeMax,
        1,
        function(value)
            BuffSettingsWindow.settings.fontSize = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local warnTimeMin, warnTimeMax = GetOptionBounds(warnTimeOptions)
    local _, debuffWarnTimeLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.debuffWarnTimeDropdown,
        "Debuff expiry warn(s):",
        columnWidth,
        BuffSettingsWindow.settings.debuffWarnTime / 1000,
        warnTimeMin,
        warnTimeMax,
        0.5,
        function(value)
            BuffSettingsWindow.settings.debuffWarnTime = value * 1000
            BuffSettingsWindow.SaveSettings()
        end,
        nil,
        2
    )

    local _, buffWarnTimeLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.buffWarnTimeDropdown,
        "Buff expiry warn(s):",
        columnWidth,
        BuffSettingsWindow.settings.buffWarnTime / 1000,
        warnTimeMin,
        warnTimeMax,
        0.5,
        function(value)
            BuffSettingsWindow.settings.buffWarnTime = value * 1000
            BuffSettingsWindow.SaveSettings()
        end,
        nil,
        2
    )

    local smoothingMin, smoothingMax = GetOptionBounds(smoothingSpeedOptions)
    local _, smoothingSpeedLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.smoothingSpeedDropdown,
        "Smoothing speed:",
        columnWidth,
        BuffSettingsWindow.settings.smoothingSpeed,
        smoothingMin,
        smoothingMax,
        1,
        function(value)
            BuffSettingsWindow.settings.smoothingSpeed = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local smoothingTooltipButton = buffSelectionWindow:CreateChildWidget("button", "smoothingTooltipButton", 0, true)
    smoothingTooltipButton:AddAnchor("LEFT", smoothingSpeedLabel, "RIGHT", 6, 0)
    smoothingTooltipButton:SetExtent(18, 18)
    smoothingTooltipButton:SetText("?")
    smoothingTooltipButton.style:SetFontSize(13)
    smoothingTooltipButton:SetTextColor(FONT_COLOR.BLUE[1], FONT_COLOR.BLUE[2], FONT_COLOR.BLUE[3], 1)
    smoothingTooltipButton:SetHighlightTextColor(FONT_COLOR.BLUE[1], FONT_COLOR.BLUE[2], FONT_COLOR.BLUE[3], 1)
    smoothingTooltipButton:SetPushedTextColor(FONT_COLOR.BLUE[1], FONT_COLOR.BLUE[2], FONT_COLOR.BLUE[3], 1)
    smoothingTooltipButton:SetDisabledTextColor(FONT_COLOR.BLUE[1], FONT_COLOR.BLUE[2], FONT_COLOR.BLUE[3], 1)
    helpers.createTooltip(
        "smoothingTooltip",
        smoothingTooltipButton,
        "Reduces jitter when buffs follow the player above the character instead of the unit frame.",
        0,
        -6
    )

    local blinkSpeedMin, blinkSpeedMax = GetOptionBounds(blinkSpeedOptions)
    local _, blinkSpeedLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.blinkSpeedDropdown,
        "Warning blink speed:",
        columnWidth,
        BuffSettingsWindow.settings.buffBlinkSpeed,
        blinkSpeedMin,
        blinkSpeedMax,
        0.5,
        function(value)
            BuffSettingsWindow.settings.buffBlinkSpeed = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local offsetXMin, offsetXMax = GetOptionBounds(buffsXOffsetOptions)
    local _, playerHorizontalOffsetLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.playerHorizontalOffsetDropdown,
        "Player X offset:",
        columnWidth,
        BuffSettingsWindow.settings.playerBuffHorizontalOffset,
        offsetXMin,
        offsetXMax,
        1,
        function(value)
            BuffSettingsWindow.settings.playerBuffHorizontalOffset = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local offsetYMin, offsetYMax = GetOptionBounds(buffsYOffsetOptions)
    local _, playerVerticalOffsetLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.playerVerticalOffsetDropdown,
        "Player Y offset:",
        columnWidth,
        BuffSettingsWindow.settings.playerBuffVerticalOffset,
        offsetYMin,
        offsetYMax,
        1,
        function(value)
            BuffSettingsWindow.settings.playerBuffVerticalOffset = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local _, targetHorizontalOffsetLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.targetHorizontalOffsetDropdown,
        "Target X offset:",
        columnWidth,
        BuffSettingsWindow.settings.targetBuffHorizontalOffset,
        offsetXMin,
        offsetXMax,
        1,
        function(value)
            BuffSettingsWindow.settings.targetBuffHorizontalOffset = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local _, targetVerticalOffsetLabel = helpers.CreateSliderWithLabel(
        buffSelectionWindow,
        anchors.targetVerticalOffsetDropdown,
        "Target Y offset:",
        columnWidth,
        BuffSettingsWindow.settings.targetBuffVerticalOffset,
        offsetYMin,
        offsetYMax,
        1,
        function(value)
            BuffSettingsWindow.settings.targetBuffVerticalOffset = value
            BuffSettingsWindow.SaveSettings()
        end
    )

    local playerAboveUnitFrameCheckbox, playerAboveUnitFrameLabel = helpers.CreateInlineCheckboxWithLabel(
        buffSelectionWindow,
        anchors.playerAboveUnitFrameCheckbox,
        "Show above player frame:",
        "Yes",
        BuffSettingsWindow.settings.showAbovePlayerUnitFrame,
        function(isChecked)
            BuffSettingsWindow.settings.showAbovePlayerUnitFrame = isChecked
            BuffSettingsWindow.SaveSettings()
        end
    )
    playerAboveUnitFrameCheckbox:RemoveAllAnchors()
    playerAboveUnitFrameCheckbox:AddAnchor("TOP", playerAboveUnitFrameLabel, "BOTTOM", 0, 8)

    local targetAboveUnitFrameCheckbox, targetAboveUnitFrameLabel = helpers.CreateInlineCheckboxWithLabel(
        buffSelectionWindow,
        anchors.targetAboveUnitFrameCheckbox,
        "Show above target frame:",
        "Yes",
        BuffSettingsWindow.settings.showAboveTargetUnitFrame,
        function(isChecked)
            BuffSettingsWindow.settings.showAboveTargetUnitFrame = isChecked
            BuffSettingsWindow.SaveSettings()
        end
    )
    targetAboveUnitFrameCheckbox:RemoveAllAnchors()
    targetAboveUnitFrameCheckbox:AddAnchor("TOP", targetAboveUnitFrameLabel, "BOTTOM", 0, 8)

       --================= Create category dropdownn =================--
    local categoryLabel
    categoryDropdown, categoryLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.categoryDropdown,
        "Buff category:",
        160,
        categories,
        currentCategory, -- "Watched Buffs" as default
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
    function categoryDropdown:UpdateTextColor(selectedIndex)
        if selectedIndex == CATEGORY_TYPE_ALL then
            self:SetAllTextColor({0.3, 0.3, 0.3, 1.0})
        elseif selectedIndex == CATEGORY_TYPE_WATCHED then
            self:SetAllTextColor({0.2, 0.4, 0.7, 1.0})
        elseif selectedIndex == CATEGORY_TYPE_LOGGED then
            self:SetAllTextColor({0.6, 0.3, 0.1, 1.0})
        end
    end
    categoryDropdown:UpdateTextColor(currentCategory)


    --================= Create search box =================--
    local searchLabel
    searchEditBox, searchLabel = helpers.CreateTextEditWithLabel(
        buffSelectionWindow,
        anchors.searchEditBox,
        "Search:",
        340,        -- width
        28,         -- height
        "",         -- defaultText
        false,      -- isDigitOnly
        nil,        -- minValue
        nil,        -- maxValue
        function(value, text)
            fillBuffData(buffScrollList, 1, text)
        end
    )

    --================= Create select all button =================--
    selectAllButton = buffSelectionWindow:CreateChildWidget("button", "selectAllButton", 0, true)
    selectAllButton:SetText("Select All")
    local saAnchor = anchors.selectAllButton
    selectAllButton:AddAnchor(saAnchor.anchor, saAnchor.target, saAnchor.relativeAnchor, saAnchor.x, saAnchor.y)
    ApplyButtonSkin(selectAllButton, BUTTON_BASIC.DEFAULT)
    selectAllButton:SetExtent(90, 30)
    selectAllButton.style:SetFontSize(12)
    selectAllButton:SetTextColor(unpack(FONT_COLOR.DEFAULT))
    selectAllButton:SetHighlightTextColor(unpack(FONT_COLOR.DEFAULT))
    selectAllButton:SetPushedTextColor(unpack(FONT_COLOR.DEFAULT))
    selectAllButton:SetDisabledTextColor(unpack(FONT_COLOR.DEFAULT))

    function selectAllButton:OnClick()
        local watchedBuffs = currentTrackType == TRACK_TYPE_PLAYER and playerWatchedBuffs or targetWatchedBuffs

        local allSelected = #filteredBuffs > 0
        for _, buff in ipairs(filteredBuffs) do
            if not watchedBuffs[buff.id] then
                allSelected = false
                break
            end
        end

        for _, buff in ipairs(filteredBuffs) do
            if allSelected then
                watchedBuffs[buff.id] = nil  -- Unselect all
            else
                watchedBuffs[buff.id] = true  -- Select all
            end
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
    buffScrollListWidth = 564
    buffScrollList = W_CTRL.CreatePageScrollListCtrl("buffScrollList", buffSelectionWindow)
    buffScrollList:SetWidth(buffScrollListWidth)
    local scrlAnchor = anchors.buffScrollList
    buffScrollList:AddAnchor(scrlAnchor.anchor, buffSelectionWindow, scrlAnchor.relativeAnchor, scrlAnchor.x, scrlAnchor.y)
    buffScrollList:AddAnchor("BOTTOMRIGHT", buffSelectionWindow, -4, -70)
    buffScrollList:InsertColumn("", buffScrollListWidth -5, 0, DataSetFunc, nil, nil, LayoutSetFunc)
    buffScrollList:InsertRows(10, false)
    buffScrollList:SetColumnHeight(1)

    -- Filter count label
    filteredCountLabel = buffSelectionWindow:CreateChildWidget("label", "filteredCountLabel", 0, true)
    filteredCountLabel:SetText("Displayed: 0")
    ApplyTextColor(filteredCountLabel, FONT_COLOR.BLACK)
    filteredCountLabel.style:SetAlign(ALIGN.LEFT)
    filteredCountLabel.style:SetFontSize(13)
    filteredCountLabel:AddAnchor("TOPLEFT", buffScrollList, "BOTTOMLEFT", 0, 15) 
    
    function buffScrollList:OnPageChangedProc(curPageIdx)
        fillBuffData(buffScrollList, curPageIdx, searchEditBox:GetText())
    end
    
    fillBuffData(buffScrollList, 1, "")
    buffSelectionWindow:Show(false)

    --================= Create record all buffs button =================--
    recordAllButton = buffSelectionWindow:CreateChildWidget("button", "recordAllButton", 0, true)
    recordAllButton:SetText("Start logging")
    recordAllButton:AddAnchor("TOPLEFT", buffSelectionWindow, "TOPLEFT", 35, 10)
    ApplyButtonSkin(recordAllButton, BUTTON_BASIC.DEFAULT)
    recordAllButton:SetAutoResize(false)
    recordAllButton:SetExtent(90, 28)
    recordAllButton.style:SetFontSize(14)

    function recordAllButton:UpdateTextColor(color)
        local color = color or FONT_COLOR.DEFAULT
        
        self:SetTextColor(unpack(color))
        self:SetHighlightTextColor(unpack(color))
        self:SetPushedTextColor(unpack(color))
        self:SetDisabledTextColor(unpack(color))
    end
    function recordAllButton:OnClick()
        if BuffsLogger then
          if BuffsLogger.isActive then
            BuffsLogger.StopTracking()
            recordAllButton:SetText("Start logging")
            self:UpdateTextColor(FONT_COLOR.DEFAULT)
          else
            BuffsLogger.StartTracking()
            recordAllButton:SetText("Stop logging")
            self:UpdateTextColor(FONT_COLOR.RED)
          end
        end
    end
    recordAllButton:SetHandler("OnClick", recordAllButton.OnClick)

    -- OnHide handler --------------------------------
    function buffSelectionWindow:OnHide()
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
        buffSelectionWindow = nil
    end

    api.Log:Info("BuffWatchWindow: Cleanup completed successfully")
end
--============================ ### End ### ==============================--

return BuffSettingsWindow