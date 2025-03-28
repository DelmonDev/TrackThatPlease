local api = require("api")
local BuffList = require("TrackThatPlease/buff_helper")

local BuffWatchWindow = {}

-- UI elements
local buffSelectionWindow
local buffScrollList
local searchEditBox
local categoryDropdown
local trackTypeDropdown

-- Settings and data
local settings
local playerWatchedBuffs = {}
local targetWatchedBuffs = {}
local currentTrackType = 1  -- 1 for Player, 2 for Target

-- Scroll and pagination
local pageSize = 20
local currentCategory = 1  -- "Watched Buffs" as default
local categories = {"All Buffs", "Player Buffs", "Target Buffs"}
local trackTypes = {"Player", "Target"}

-- Helper functions for number serialization
local function SerializeNumber(num)
    return string.format("%.0f", num)
end

local function DeserializeNumber(str)
    return tonumber(str)
end

-- Function to save settings
local function SaveSettings()
    local savedPlayerBuffs = {}
    local savedTargetBuffs = {}
    
    for _, id in ipairs(playerWatchedBuffs) do
        table.insert(savedPlayerBuffs, SerializeNumber(id))
    end
    
    for _, id in ipairs(targetWatchedBuffs) do
        table.insert(savedTargetBuffs, SerializeNumber(id))
    end
    
    settings.playerWatchedBuffs = savedPlayerBuffs
    settings.targetWatchedBuffs = savedTargetBuffs
    api.SaveSettings()
end

-- Update the appearance of a buff icon
local function UpdateIconAppearance(subItem, buffId)
    local isWatched = false
    
    if currentTrackType == 1 then -- Player
        isWatched = BuffWatchWindow.IsPlayerBuffWatched(buffId)
    else -- Target
        isWatched = BuffWatchWindow.IsTargetBuffWatched(buffId)
    end
    
    if isWatched then
        subItem.checkmarkIcon:SetCoords(852,49,15,15)
    else
        subItem.checkmarkIcon:SetCoords(832,49,15,15)
    end
    subItem.checkmarkIcon:Show(true)
end

-- Set data for each buff item in the list
local function DataSetFunc(subItem, data, setValue)
    if setValue then
        local str = string.format("%s", data.name)
        local id = data.id
        subItem.id = id
        subItem.textbox:SetText(str)
        F_SLOT.SetIconBackGround(subItem.subItemIcon, BuffList.GetBuffIcon(id))
        UpdateIconAppearance(subItem, id)
    end
end

-- Create layout for each buff item in the list
local function LayoutSetFunc(frame, rowIndex, colIndex, subItem)
    -- Add background
    local background = subItem:CreateImageDrawable(TEXTURE_PATH.HUD, "background")
    background:SetCoords(453, 145, 230, 23)
    background:AddAnchor("TOPLEFT", subItem, -70, 4)
    background:AddAnchor("BOTTOMRIGHT", subItem, -70, 4)

    local subItemIcon = CreateItemIconButton("subItemIcon", subItem)
    subItemIcon:SetExtent(30, 30)
    subItemIcon:Show(true)
    F_SLOT.ApplySlotSkin(subItemIcon, subItemIcon.back, SLOT_STYLE.BUFF)
    subItemIcon:AddAnchor("LEFT", subItem, 5, 2)
    subItem.subItemIcon = subItemIcon

    subItem:SetExtent(380, 30)
    local textbox = subItem:CreateChildWidget("textbox", "textbox", 0, true)
    textbox:AddAnchor("TOPLEFT", subItem, 43, 2)
    textbox:AddAnchor("BOTTOMRIGHT", subItem, 0, 0)
    textbox.style:SetAlign(ALIGN.LEFT)
    textbox.style:SetFontSize(FONT_SIZE.LARGE)
    ApplyTextColor(textbox, FONT_COLOR.WHITE)
    subItem.textbox = textbox

    -- checkmark config
    local checkmarkIcon = subItem:CreateImageDrawable(TEXTURE_PATH.HUD, "overlay")
    checkmarkIcon:SetExtent(14, 14)
    checkmarkIcon:AddAnchor("TOPRIGHT", subItemIcon, 260, 10)
    checkmarkIcon:Show(true)
    subItem.checkmarkIcon = checkmarkIcon

    local clickOverlay = subItem:CreateChildWidget("button", "clickOverlay", 0, true)
    clickOverlay:AddAnchor("TOPLEFT", subItem, 0, 0)
    clickOverlay:AddAnchor("BOTTOMRIGHT", subItem, 0, 0)
    function clickOverlay:OnClick()
        local buffId = subItem.id
        BuffWatchWindow.ToggleBuffWatch(buffId)
        UpdateIconAppearance(subItem, buffId)
        SaveSettings()
    end 
    clickOverlay:SetHandler("OnClick", clickOverlay.OnClick)
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
    local filteredBuffs = {}
    
    local function addBuff(buff)
        if searchText == "" or string.find(buff.name:lower(), searchText:lower()) then
            table.insert(filteredBuffs, buff)
        end
    end

    if currentCategory == 1 then  -- All Buffs
        for _, buff in ipairs(BuffList.ALL_BUFFS) do
            addBuff(buff)
        end
    elseif currentCategory == 2 then  -- Player Buffs
        for _, buff in ipairs(BuffList.ALL_BUFFS) do
            if BuffWatchWindow.IsPlayerBuffWatched(buff.id) then
                addBuff(buff)
            end
        end
    elseif currentCategory == 3 then  -- Target Buffs
        for _, buff in ipairs(BuffList.ALL_BUFFS) do
            if BuffWatchWindow.IsTargetBuffWatched(buff.id) then
                addBuff(buff)
            end
        end
    end
    
    updatePageCount(#filteredBuffs)

    for i = startingIndex, math.min(startingIndex + pageSize - 1, #filteredBuffs) do
        local buff = filteredBuffs[i]
        if buff then
            local buffData = {
                id = buff.id,
                name = buff.name,
                isViewData = true,
                isAbstention = false
            }
            buffScrollList:InsertData(count, 1, buffData, false)
            count = count + 1
        end
    end
end

-- Toggle a buff's watched status based on current tracking type
function BuffWatchWindow.ToggleBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    
    if currentTrackType == 1 then -- Player
        BuffWatchWindow.TogglePlayerBuffWatch(buffId)
    else -- Target
        BuffWatchWindow.ToggleTargetBuffWatch(buffId)
    end
end

-- Toggle a player buff's watched status
function BuffWatchWindow.TogglePlayerBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    local index = nil
    for i, id in ipairs(playerWatchedBuffs) do
        if id == buffId then
            index = i
            break
        end
    end
    
    if index then
        table.remove(playerWatchedBuffs, index)
    else
        table.insert(playerWatchedBuffs, buffId)
    end
end

-- Toggle a target buff's watched status
function BuffWatchWindow.ToggleTargetBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    local index = nil
    for i, id in ipairs(targetWatchedBuffs) do
        if id == buffId then
            index = i
            break
        end
    end
    
    if index then
        table.remove(targetWatchedBuffs, index)
    else
        table.insert(targetWatchedBuffs, buffId)
    end
end

-- Check if a buff is being watched (general function used by main.lua)
function BuffWatchWindow.IsBuffWatched(buffId)
    return BuffWatchWindow.IsPlayerBuffWatched(buffId) or BuffWatchWindow.IsTargetBuffWatched(buffId)
end

-- Check if a player buff is being watched
function BuffWatchWindow.IsPlayerBuffWatched(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    for _, id in ipairs(playerWatchedBuffs) do
        if id == buffId then
            return true
        end
    end
    return false
end

-- Check if a target buff is being watched
function BuffWatchWindow.IsTargetBuffWatched(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    for _, id in ipairs(targetWatchedBuffs) do
        if id == buffId then
            return true
        end
    end
    return false
end

-- Toggle the buff selection window visibility
function BuffWatchWindow.ToggleBuffSelectionWindow()
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
function BuffWatchWindow.IsWindowVisible()
    return buffSelectionWindow and buffSelectionWindow:IsVisible() or false
end

-- Initialize the BuffWatchWindow
function BuffWatchWindow.Initialize(addonSettings)
    settings = api.GetSettings("TrackThatPlease") or {}
    
    -- Load player buffs
    local savedPlayerBuffs = settings.playerWatchedBuffs or {}
    playerWatchedBuffs = {}
    for _, idString in ipairs(savedPlayerBuffs) do
        table.insert(playerWatchedBuffs, DeserializeNumber(idString))
    end
    
    -- Load target buffs
    local savedTargetBuffs = settings.targetWatchedBuffs or {}
    targetWatchedBuffs = {}
    for _, idString in ipairs(savedTargetBuffs) do
        table.insert(targetWatchedBuffs, DeserializeNumber(idString))
    end
    
    -- Backward compatibility for existing users
    if settings.watchedBuffs and (#playerWatchedBuffs == 0 and #targetWatchedBuffs == 0) then
        for _, idString in ipairs(settings.watchedBuffs) do
            table.insert(playerWatchedBuffs, DeserializeNumber(idString))
            table.insert(targetWatchedBuffs, DeserializeNumber(idString))
        end
    end
    
    -- Create the main window
    buffSelectionWindow = api.Interface:CreateWindow("buffSelectorWindow", "Track List")
    buffSelectionWindow:SetWidth(450)
    buffSelectionWindow:SetHeight(700)
    
    -- Create the track type selector
    local trackTypeLabel = buffSelectionWindow:CreateChildWidget("label", "trackTypeLabel", 0, true)
    trackTypeLabel:SetText("Track Type:")
    trackTypeLabel.style:SetAlign(ALIGN.LEFT)
    trackTypeLabel.style:SetFontSize(FONT_SIZE.LARGE)
    ApplyTextColor(trackTypeLabel, FONT_COLOR.BLACK)
    trackTypeLabel:AddAnchor("TOPLEFT", buffSelectionWindow, 75, 60)
    
    trackTypeDropdown = api.Interface:CreateComboBox(buffSelectionWindow)
    trackTypeDropdown:AddAnchor("TOPLEFT", trackTypeLabel, "BOTTOMLEFT", 0, 15)
    trackTypeDropdown:SetWidth(300)
    trackTypeDropdown.style:SetFontSize(FONT_SIZE.LARGE)
    trackTypeDropdown.dropdownItem = trackTypes
    trackTypeDropdown:Select(1)  -- "Player" as default
    
    -- Create the search box
    local searchLabel = buffSelectionWindow:CreateChildWidget("label", "searchLabel", 0, true)
    searchLabel:SetText("Search Name/ID:")
    searchLabel.style:SetAlign(ALIGN.LEFT)
    searchLabel.style:SetFontSize(FONT_SIZE.LARGE)
    ApplyTextColor(searchLabel, FONT_COLOR.BLACK)
    searchLabel:AddAnchor("TOPLEFT", trackTypeDropdown, "BOTTOMLEFT", 0, 30)

    searchEditBox = W_CTRL.CreateEdit("searchEditBox", buffSelectionWindow)
    searchEditBox:SetExtent(300, 24)
    searchEditBox:AddAnchor("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, 15)
    searchEditBox.style:SetFontSize(FONT_SIZE.LARGE)
    
    function searchEditBox:OnTextChanged()
        local searchText = searchEditBox:GetText()
        if searchText ~= "" and currentCategory ~= 1 then
            currentCategory = 1  -- Switch to "All Buffs"
            categoryDropdown:Select(1)
        end
        fillBuffData(buffScrollList, 1, searchText)
    end
    searchEditBox:SetHandler("OnTextChanged", searchEditBox.OnTextChanged)
    
    -- Create category dropdown
    local categoryLabel = buffSelectionWindow:CreateChildWidget("label", "categoryLabel", 0, true)
    categoryLabel:SetText("Buff Category:")
    categoryLabel.style:SetAlign(ALIGN.LEFT)
    categoryLabel.style:SetFontSize(FONT_SIZE.LARGE)
    ApplyTextColor(categoryLabel, FONT_COLOR.BLACK)
    categoryLabel:AddAnchor("TOPLEFT", searchEditBox, "BOTTOMLEFT", 0, 30)

    categoryDropdown = api.Interface:CreateComboBox(buffSelectionWindow)
    categoryDropdown:AddAnchor("TOPLEFT", categoryLabel, "BOTTOMLEFT", 0, 15)
    categoryDropdown:SetWidth(300)
    categoryDropdown.style:SetFontSize(FONT_SIZE.LARGE)
    categoryDropdown.dropdownItem = categories
    categoryDropdown:Select(1)  -- "Player Buffs" as default
    
    -- Create the buff scroll list
    buffScrollList = W_CTRL.CreatePageScrollListCtrl("buffScrollList", buffSelectionWindow)
    buffScrollList:SetWidth(380)
    buffScrollList:AddAnchor("TOPLEFT", categoryDropdown, "BOTTOMLEFT", 0, 15)
    buffScrollList:AddAnchor("BOTTOMRIGHT", buffSelectionWindow, -4, -40)
    buffScrollList:InsertColumn("", 380, 0, DataSetFunc, nil, nil, LayoutSetFunc)
    buffScrollList:InsertRows(10, false)
    buffScrollList:SetColumnHeight(-3)
    
    function trackTypeDropdown:SelectedProc()
        currentTrackType = self:GetSelectedIndex()
        fillBuffData(buffScrollList, 1, searchEditBox:GetText())
    end
    
    function categoryDropdown:SelectedProc()
        currentCategory = self:GetSelectedIndex()
        fillBuffData(buffScrollList, 1, searchEditBox:GetText())
    end
    
    function buffScrollList:OnPageChangedProc(curPageIdx)
        fillBuffData(buffScrollList, curPageIdx, searchEditBox:GetText())
    end
    
    fillBuffData(buffScrollList, 1, "")
    buffSelectionWindow:Show(false)

    -- OnHide handler
    function buffSelectionWindow:OnHide()
        buffScrollList:DeleteAllDatas()
    end 
    buffSelectionWindow:SetHandler("OnHide", buffSelectionWindow.OnHide)
end

-- Cleanup function for when the addon is unloaded
function BuffWatchWindow.Cleanup()
    if buffSelectionWindow then
        buffSelectionWindow:Show(false)
        buffSelectionWindow:ReleaseHandler("OnHide")
        buffSelectionWindow = nil
    end
    SaveSettings()
end

return BuffWatchWindow