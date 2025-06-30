local api = require("api")
local BuffList = require("TrackThatPlease/buff_helper")
local helpers = require("TrackThatPlease/util/helpers")
local BuffsLogger

local BuffSettingsWindow = {}
BuffSettingsWindow.settings = {}
-- Last element of maxBuffsOptions must be equal to this
BuffSettingsWindow.MAX_BUFFS_COUNT = 13 

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

local maxBuffsOptions = {"3", "5", "7", "9", "11", "13"} -- Last element must be equal to BuffSettingsWindow.MAX_BUFFS_COUNT
local iconSpacingOptions = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10"}
local iconSizeOptions = {"25", "28", "30", "32", "34", "36", "38", "40", "42", "44", "46", "48", "50", "52", "54", "56", "58"}
local fontSizeOptions = {"10", "11", "12", "13", "14", "15", "16", "18", "20", "22", "24", "26", "28", "30", "32", "34", "36"}
local warnTimeOptions = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10"}
local buffsYOffsetOptions = {"-52", "-48", "-46", "-44", "-42", "-40", "-38", "-36", "-32", "-28", "-24"}
local smoothingSpeedOptions = { "0", "2", "4", "6", "8", "12", "16", "18", "20", "24", "28", "32", "36" }
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
        targetBuffVerticalOffset = -38,
        playerBuffVerticalOffset = -38,
        iconSize = 34,
        iconSpacing = 3,
        maxBuffsShown = 5,
        debuffWarnTime = 2000,
        buffWarnTime = 3000,
        smoothingSpeed = 8,
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
    buffSelectionWindow = api.Interface:CreateWindow("buffSelectorWindow", "Track List")
    buffSelectionWindow:SetWidth(500)
    buffSelectionWindow:SetHeight(750)
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
        iconSpacingDropdown = createAnchor(x4, y1),
        -- Row 2
        debuffWarnTimeDropdown = createAnchor(x1, y2),
        buffWarnTimeDropdown = createAnchor(x2, y2),
        smoothingSpeedDropdown = createAnchor(x3, y2),
        playerVerticalOffsetDropdown = createAnchor(x4, y2),
        targetVerticalOffsetDropdown = createAnchor(x4 + 68, y2),
        -- Row 3
        trackTypeDropdown = createAnchor(x1, y3),
        categoryDropdown = createAnchor(x2, y3),
        shouldShowStacksCheckbox = createAnchor(x4, y3),
        -- Row 4
        searchEditBox = createAnchor(x1, y4),
        -- Row 5
        buffScrollList = createAnchor(leftMargin, y5),
        selectAllButton = createAnchor(x4, y5 - 40) ,
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
    

    --================= Create max buffs dropdown =================--
    local maxBuffsLabel
    local maxBuffsIndex = 2 
    -- Set from loaded settings
    for i, value in ipairs(maxBuffsOptions) do
        if tonumber(value) == BuffSettingsWindow.settings.maxBuffsShown then
            maxBuffsIndex = i   
            break
        end
    end
    local maxBuffsDropdown, maxBuffsLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.maxBuffsDropdown,
        "Max buffs:",
        0,
        maxBuffsOptions,
        maxBuffsIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.maxBuffsShown = tonumber(selectedValue)
            BuffSettingsWindow.SaveSettings()
        end,
        "Maximum number of tracked buffs to display"
    )

    --================= Create Icon Size dropdown =================--
    local iconSizeIndex = 5 -- Default 34
    -- Set from loaded settings
    for i, value in ipairs(iconSizeOptions) do
        if tonumber(value) == BuffSettingsWindow.settings.iconSize then
            iconSizeIndex = i   
            break
        end
    end
    local iconSizeDropdown, iconSizeLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.iconSizeDropdown,
        "Icon size:",
        0,
        iconSizeOptions,
        iconSizeIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.iconSize = tonumber(selectedValue)
            BuffSettingsWindow.SaveSettings()
        end
    )

    --================= Create Icon Size dropdown =================--
    local iconSpacingIndex = 3 -- Default 3
    -- Set from loaded settings
    for i, value in ipairs(iconSpacingOptions) do
        if tonumber(value) == BuffSettingsWindow.settings.iconSpacing then
            iconSpacingIndex = i   
            break
        end
    end
    local iconSpacingDropdown, iconSpacingLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.iconSpacingDropdown,
        "Icon spacing:",
        0,
        iconSpacingOptions,
        iconSpacingIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.iconSpacing = tonumber(selectedValue)
            BuffSettingsWindow.SaveSettings()
        end
    )

    --================= Create Font Size dropdown =================--
    local fontSizeIndex = 4 -- Default 12
    -- Set from loaded settings
    for i, value in ipairs(fontSizeOptions) do
        if tonumber(value) == BuffSettingsWindow.settings.fontSize then
            fontSizeIndex = i   
            break
        end
    end
    local fontSizeDropdown, fontSizeLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.fontSizeDropdown,
        "Text size:",
        0,
        fontSizeOptions,
        fontSizeIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.fontSize = tonumber(selectedValue)
            BuffSettingsWindow.SaveSettings()
        end
    )

    -- Create debuffWarnTime dropdown
    local debuffWarnTimeIndex = BuffSettingsWindow.settings.debuffWarnTime / 1000 -- Convert ms to seconds
    local debuffWarnTimeDropdown, debuffWarnTimeLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.debuffWarnTimeDropdown,
        "Debuff warn:",
        0, -- Use default width
        warnTimeOptions,
        debuffWarnTimeIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.debuffWarnTime = tonumber(selectedIndex) * 1000 -- Convert to milliseconds
            BuffSettingsWindow.SaveSettings()
        end,
        "Time (in sec) before debuff expires to start warning (blinking)"
    )

    -- Create buffWarnTime dropdown
    local buffWarnTimeIndex = BuffSettingsWindow.settings.buffWarnTime / 1000 -- Convert ms to seconds
    local buffWarnTimeDropdown, buffWarnTimeLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.buffWarnTimeDropdown,
        "Buff warn:",
        0, -- Use default width
        warnTimeOptions,
        buffWarnTimeIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.buffWarnTime = tonumber(selectedIndex) * 1000 -- Convert to milliseconds
            BuffSettingsWindow.SaveSettings()
        end,
        "Time (in sec) before buff expires to start warning (blinking)"
    )

    -- Create smoothingSpeed dropdown
    local smoothingSpeedIndex = 5 -- Default to "12"
    -- Set from loaded settings
    for i, speed in ipairs(smoothingSpeedOptions) do
        if tonumber(speed) == BuffSettingsWindow.settings.smoothingSpeed then
            smoothingSpeedIndex = i
            break
        end
    end
    local smoothingSpeedDropdown, smoothingSpeedLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.smoothingSpeedDropdown,
        "Smoothing:",
        0, -- Use default width
        smoothingSpeedOptions,
        smoothingSpeedIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.smoothingSpeed = tonumber(selectedValue)
            BuffSettingsWindow.SaveSettings()
        end,
        "Speed of buff icons position update smoothing (for a player) \n (higher = faster response, lower = smoother movement (no jitter) \n 0 = no smoothing)",
        -55
    )

    -- Create player vertical offset dropdown (optional fourth dropdown)
    local offsetIndex = 6 -- Default to "-38"
    -- Set from loaded settings
    for i, offset in ipairs(buffsYOffsetOptions) do
        if tonumber(offset) == BuffSettingsWindow.settings.playerBuffVerticalOffset then
            offsetIndex = i
            break
        end
    end
    local playerVerticalOffsetDropdown, playerVerticalOffsetLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.playerVerticalOffsetDropdown,
        "P Offset:",
        62,
        buffsYOffsetOptions,
        offsetIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.playerBuffVerticalOffset = tonumber(selectedValue)
            BuffSettingsWindow.SaveSettings()
        end,
        "Vertical offset for player buffs positioning"
    )

    -- Create target vertical offset dropdown
    local targetOffsetIndex = 6 -- Default to "-38"
    -- Set from loaded settings
    for i, offset in ipairs(buffsYOffsetOptions) do
        if tonumber(offset) == BuffSettingsWindow.settings.targetBuffVerticalOffset then
            targetOffsetIndex = i
            break
        end
    end
    local targetVerticalOffsetDropdown, targetVerticalOffsetLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.targetVerticalOffsetDropdown,
        "T Offset:",
        62,
        buffsYOffsetOptions,
        targetOffsetIndex,
        function(selectedIndex, selectedValue)
            BuffSettingsWindow.settings.targetBuffVerticalOffset = tonumber(selectedValue)
            BuffSettingsWindow.SaveSettings()
        end,
        "Vertical offset for target buffs positioning"
    )

       --================= Create category dropdownn =================--
    local categoryDropdownTooltip = "'All static buffs' - all buffs in the game (many are outdated) \n" ..
        "'All logged buffs' - buffs collected by logged \n" ..
        "'Watched buffs' - buffs that are watched on (Player/Target)"

    local categoryLabel
    categoryDropdown, categoryLabel = helpers.CreateDropdownWithLabel(
        buffSelectionWindow,
        anchors.categoryDropdown,
        "Buff category:",
        140,
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
        end,
        categoryDropdownTooltip
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
        240,        -- width
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
    buffScrollListWidth = 470
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

    helpers.createTooltip(
        "recordAllButtonTooltip",
        recordAllButton,
        "This will start logging all buffs/debufs that are active on the player or target(s) during reccording time. \n" ..
        "So later on you can use them to add to your 'Watched buffs', \n" ..
        "You could find them under the 'All logged buffs' section of 'Buff category'"
    )

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