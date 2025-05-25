local BuffList = require("TrackThatPlease/buff_helper")

local BuffWatchWindow = {}

-- UI elements
local buffSelectionWindow
local buffScrollList
local searchEditBox
local categoryDropdown
local AllBuffsIndex = {}
local AllBuffs = {}
local allSelected = false
local filteredCountLabel

-- Settings and data
local settings
local watchedBuffs = {}
local filteredBuffs = {}

-- Scroll and pagination
local pageSize = 50
local currentCategory = 2  -- "Watched Buffs" as default
local categories = {"All Buffs", "Watched Buffs"}

-- Helper functions for number serialization
local function SerializeNumber(num)
    return string.format("%.0f", num)
end

local function DeserializeNumber(str)
    return tonumber(str)
end

-- Function to save settings
local function SaveSettings()
    local savedBuffs = {}
    for id, _ in pairs(watchedBuffs) do
        table.insert(savedBuffs, SerializeNumber(id))
    end
    settings.watchedBuffs = savedBuffs

    api.SaveSettings()
    --api.Log:Err("Settings saved with watched buffs count: " .. #savedBuffs)
end

-- Update the appearance of a buff icon
local function UpdateIconAppearance(subItem, buffId)
    if BuffWatchWindow.IsBuffWatched(buffId) then
        subItem.checkmarkIcon:SetCoords(852,49,15,15)
    else
        subItem.checkmarkIcon:SetCoords(832,49,15,15)
    end
    subItem.checkmarkIcon:Show(true)
end

-- Set data for each buff item in the list
local function DataSetFunc(subItem, data, setValue)
    if setValue then
        local str = string.format("(%d) %s", data.id, data.name)
        local id = data.id
        subItem.id = id
        subItem.textbox:SetText(str)
        F_SLOT.SetIconBackGround(subItem.subItemIcon, data.iconPath)
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

    subItem:SetExtent(440, 30)
    local textbox = subItem:CreateChildWidget("textbox", "textbox", 0, true)
    textbox:AddAnchor("TOPLEFT", subItem, 43, 2)
    textbox:AddAnchor("BOTTOMRIGHT", subItem, 0, 0)
    textbox.style:SetAlign(ALIGN.LEFT)
    textbox.style:SetFontSize(14)
    ApplyTextColor(textbox, FONT_COLOR.WHITE)
    subItem.textbox = textbox

    -- checkmark config
    local checkmarkIcon = subItem:CreateImageDrawable(TEXTURE_PATH.HUD, "overlay")
    checkmarkIcon:SetExtent(14, 14)
    checkmarkIcon:AddAnchor("TOPRIGHT", subItemIcon, 300, 10)
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
    filteredBuffs = {}

    if currentCategory == 1 then  -- All Buffs
        if string.len(searchText) < 3 then
            if buffScrollList:GetDataCount() == #AllBuffs then
                return  -- No need to filter if already showing all buffs
            end
            for i, buff in ipairs(AllBuffs) do
                table.insert(filteredBuffs, buff)
            end
        else
            filteredBuffs = BuffList.searchNgram(searchText)
        end
    elseif currentCategory == 2 then  -- Watched Buffs
        for id, _ in pairs(watchedBuffs) do
            local buff = AllBuffsIndex[id]
            if buff then
                if searchText == "" or string.find(buff.name:lower(), searchText:lower()) then
                    table.insert(filteredBuffs, buff)
                end
            else
                api.Log:Err("Buff with ID " .. tostring(id) .. " not found in AllBuffs")
            end
        end

        table.sort(filteredBuffs, function(a, b)
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    end

    updatePageCount(#filteredBuffs)
    filteredCountLabel:SetText("Count: " .. tostring(#filteredBuffs))

    for i = startingIndex, math.min(startingIndex + pageSize - 1, #filteredBuffs) do
        local buff = filteredBuffs[i]
        if buff then
            local buffData = {
                id = buff.id,
                name = buff.name,
                iconPath = buff.iconPath,
                isViewData = true,
                isAbstention = false
            }
            buffScrollList:InsertData(count, 1, buffData, false)
            count = count + 1
        end
    end
end

-- Toggle a buff's watched status
function BuffWatchWindow.ToggleBuffWatch(buffId)
    buffId = DeserializeNumber(SerializeNumber(buffId))
    if watchedBuffs[buffId] then
        watchedBuffs[buffId] = nil
    else
        watchedBuffs[buffId] = true
    end
end

-- Check if a buff is being watched
function BuffWatchWindow.IsBuffWatched(buffId)

    buffId = DeserializeNumber(SerializeNumber(buffId))
    return watchedBuffs[buffId] ~= nil
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
    local savedBuffs = settings.watchedBuffs or {}
    local buffs = BuffList.GetAllBuffs()  -- Load all buffs from the helper module
    AllBuffsIndex = buffs.AllBuffsIndex
    AllBuffs = buffs.AllBuffs
    api.AllBuffsIndex = AllBuffsIndex  -- Make it globally accessible
    
    for _, idString in ipairs(savedBuffs) do
        watchedBuffs[DeserializeNumber(idString)] = true
    end

    
    -- Create the main window
    buffSelectionWindow = api.Interface:CreateWindow("buffSelectorWindow", "Track Target List")
    buffSelectionWindow:SetWidth(475)
    buffSelectionWindow:SetHeight(750)
    buffSelectionWindow:RemoveAllAnchors()
    buffSelectionWindow:AddAnchor("CENTER", "UIParent", "CENTER", 0, 0)
    local childrenWidth = 360
    
    -- Create the search box
    local searchLabel = buffSelectionWindow:CreateChildWidget("label", "searchLabel", 0, true)
    searchLabel:SetText("Search Name")
    searchLabel.style:SetAlign(ALIGN.LEFT)
    searchLabel.style:SetFontSize(FONT_SIZE.LARGE)
    ApplyTextColor(searchLabel, FONT_COLOR.BLACK)
    searchLabel:AddAnchor("TOPLEFT", buffSelectionWindow, 75, 60)

    searchEditBox = W_CTRL.CreateEdit("searchEditBox", buffSelectionWindow)
    searchEditBox:SetExtent(childrenWidth, 24)
    searchEditBox:AddAnchor("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, 15)
    searchEditBox.style:SetFontSize(FONT_SIZE.LARGE)
    
    function searchEditBox:OnTextChanged()
        local searchText = searchEditBox:GetText()
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
    categoryDropdown:SetWidth(childrenWidth)
    categoryDropdown.style:SetFontSize(FONT_SIZE.LARGE)
    categoryDropdown.dropdownItem = categories
    categoryDropdown:Select(2)  -- "Watched Buffs" as default
    
    -- Create the buff scroll list
    buffScrollList = W_CTRL.CreatePageScrollListCtrl("buffScrollList", buffSelectionWindow)
    buffScrollList:SetWidth(childrenWidth + 60)
    buffScrollList:AddAnchor("TOPLEFT", categoryDropdown, "BOTTOMLEFT", 0, 35)
    buffScrollList:AddAnchor("BOTTOMRIGHT", buffSelectionWindow, -4, -40)
    buffScrollList:InsertColumn("", childrenWidth + 60, 0, DataSetFunc, nil, nil, LayoutSetFunc)
    buffScrollList:InsertRows(10, false)
    buffScrollList:SetColumnHeight(-3)

    -- Create select all button
    local selectAllButton = buffSelectionWindow:CreateChildWidget("button", "selectAllButton", 0, true)
    selectAllButton:SetText("Select All")
    selectAllButton:AddAnchor("TOPRIGHT", categoryDropdown, "BOTTOMRIGHT", 0, 8)
    ApplyButtonSkin(selectAllButton, BUTTON_BASIC.DEFAULT)
    selectAllButton:SetExtent(78, 25)
    selectAllButton.style:SetFontSize(11)
    -- Set colors
    selectAllButton:SetTextColor(unpack(FONT_COLOR.DEFAULT))
    selectAllButton:SetHighlightTextColor(unpack(FONT_COLOR.DEFAULT))
    selectAllButton:SetPushedTextColor(unpack(FONT_COLOR.DEFAULT))
    selectAllButton:SetDisabledTextColor(unpack(FONT_COLOR.DEFAULT))

    -- Filter count label
    filteredCountLabel = buffSelectionWindow:CreateChildWidget("label", "filteredCountLabel", 0, true)
    filteredCountLabel:SetText("0")
    ApplyTextColor(filteredCountLabel, FONT_COLOR.DEFAULT)
    filteredCountLabel.style:SetAlign(ALIGN.LEFT)
    filteredCountLabel.style:SetFontSize(12)
    filteredCountLabel:AddAnchor("TOPLEFT", categoryDropdown, "BOTTOMLEFT", 0, 15)

    function selectAllButton:OnClick()
        if not allSelected then
            for i, buff in ipairs(filteredBuffs) do
                watchedBuffs[buff.id] = true
            end
            selectAllButton:SetText("Unselect All")
            allSelected = true
        else
            for i, buff in ipairs(filteredBuffs) do
                watchedBuffs[buff.id] = nil
            end
            selectAllButton:SetText("Select All")
            allSelected = false
        end
            SaveSettings()
            fillBuffData(buffScrollList, 1, searchEditBox:GetText())
    end
    selectAllButton:SetHandler("OnClick", selectAllButton.OnClick)

    function categoryDropdown:SelectedProc()
        local newCategory = self:GetSelectedIndex()
        if newCategory ~= currentCategory then
            currentCategory = newCategory
            searchEditBox:SetText("")  -- Clear search text when changing category
            fillBuffData(buffScrollList, 1, searchEditBox:GetText())
        end
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