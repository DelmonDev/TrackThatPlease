local api = require("api")
local checkButton = require('TrackThatPlease/util/check_button')
local createSlider = require('TrackThatPlease/util/slider')
local helpers = {}
local labelFontSize = 14
local lableFontColor = FONT_COLOR.DARK_GRAY
local dropDownFontColor = FONT_COLOR.BLACK
local dropDownFontSize = 15
local dropDownWidth = 80
local dropdownHeight = 28
local counterWidth = 80
local counterHeight = 24
local sliderWidth = 172

local function ApplyButtonTextColor(button, color)
    button:SetTextColor(unpack(color))
    button:SetHighlightTextColor(unpack(color))
    button:SetPushedTextColor(unpack(color))
    button:SetDisabledTextColor(unpack(color))
end

-- Create a checkbox with label and optional tooltip
function helpers.CreateCheckboxWithLabel(parent, anchorInfo, labelText, checkboxText, defaultChecked, onCheckedChanged, tooltipText)
    -- Create label first
    local label = parent:CreateChildWidget("label", "label_" .. tostring(math.random(1000, 9999)), 0, true)
    
    -- Set label positioning
    if anchorInfo.anchor then
        label:AddAnchor(anchorInfo.anchor, anchorInfo.target, anchorInfo.relativeAnchor or anchorInfo.anchor, anchorInfo.x or 0, anchorInfo.y or 0)
    end
    
    -- Set label properties
    label:SetText(labelText or "")
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetFontSize(labelFontSize)
    ApplyTextColor(label, lableFontColor)


    -- Create checkbox below the label using checkButton.CreateCheckButton
    local checkBox = checkButton.CreateCheckButton("checkbox_" .. tostring(math.random(1000, 9999)), parent, checkboxText or "")
    checkBox:AddAnchor("TOPLEFT", label, "BOTTOMLEFT", 0, 10) -- gap below label
    checkBox:SetButtonStyle("default")
    
    -- Set default checked state
    if defaultChecked then
        checkBox:SetChecked(true)
    end
    

    if onCheckedChanged then
        function checkBox:OnCheckChanged()
            local isChecked = self:GetChecked()

            onCheckedChanged(isChecked)
        end

        checkBox:SetHandler("OnCheckChanged", checkBox.OnCheckChanged)
    end
    
    -- Add tooltip if provided
    local tooltip = nil
    if tooltipText and tooltipText ~= "" then
        tooltip = helpers.createTooltip("tooltip_" .. tostring(math.random(1000, 9999)), checkBox, tooltipText, 0, 0)
    end
    
    return checkBox, label, tooltip
end

function helpers.CreateInlineCheckboxWithLabel(parent, anchorInfo, labelText, checkboxText, defaultChecked, onCheckedChanged, tooltipText)
    local label = parent:CreateChildWidget("label", "label_" .. tostring(math.random(1000, 9999)), 0, true)

    if anchorInfo.anchor then
        label:AddAnchor(anchorInfo.anchor, anchorInfo.target, anchorInfo.relativeAnchor or anchorInfo.anchor, anchorInfo.x or 0, anchorInfo.y or 0)
    end

    label:SetText(labelText or "")
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetFontSize(labelFontSize)
    ApplyTextColor(label, lableFontColor)
    if label.SetAutoResize ~= nil then
        label:SetAutoResize(true)
    end

    local checkBox = checkButton.CreateCheckButton("checkbox_" .. tostring(math.random(1000, 9999)), parent, checkboxText or "")
    checkBox:AddAnchor("LEFT", label, "RIGHT", 8, 0)
    checkBox:SetButtonStyle("default")

    if defaultChecked then
        checkBox:SetChecked(true)
    end

    if onCheckedChanged then
        function checkBox:OnCheckChanged()
            local isChecked = self:GetChecked()

            onCheckedChanged(isChecked)
        end

        checkBox:SetHandler("OnCheckChanged", checkBox.OnCheckChanged)
    end

    local tooltip = nil
    if tooltipText and tooltipText ~= "" then
        tooltip = helpers.createTooltip("tooltip_" .. tostring(math.random(1000, 9999)), checkBox, tooltipText, 0, 0)
    end

    return checkBox, label, tooltip
end

-- Create a dropdown/combobox with label and optional tooltip
function helpers.CreateDropdownWithLabel(parent, anchorInfo, labelText, width, options, defaultIndex, onSelectionChanged, tooltipText, tooltipYOffset)
    -- Create label first
    local label = parent:CreateChildWidget("label", "label_" .. tostring(math.random(1000, 9999)), 0, true)
    
    -- Set label positioning
    if anchorInfo.anchor then
        label:AddAnchor(anchorInfo.anchor, anchorInfo.target, anchorInfo.relativeAnchor or anchorInfo.anchor, anchorInfo.x or 0, anchorInfo.y or 0)
    end
    
    -- Set label properties
    label:SetText(labelText or "")
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetFontSize(labelFontSize)
    ApplyTextColor(label, lableFontColor)
    
    -- Create dropdown below the label
    local dropdown = api.Interface:CreateComboBox(parent)
    dropdown:AddAnchor("TOPLEFT", label, "BOTTOMLEFT", 0, 8) -- gap below label
    
    -- Set dropdown properties
    dropdown:SetWidth((width and width ~= 0 and width) or dropDownWidth)
    dropdown:SetHeight(dropdownHeight)
    dropdown.dropdownItem = options
    dropdown:Select(defaultIndex or 1)
    dropdown:SetHighlightTextColor(unpack(dropDownFontColor))
    dropdown:SetPushedTextColor(unpack(dropDownFontColor))
    dropdown:SetDisabledTextColor(unpack(dropDownFontColor))
    dropdown:SetTextColor(unpack(dropDownFontColor))
    dropdown.style:SetFontSize(dropDownFontSize)

    -- Set handler
    if onSelectionChanged then
        
        function dropdown:SelectedProc()
            local selectedIndex = self:GetSelectedIndex()
            local selectedValue = options[selectedIndex]

            onSelectionChanged(selectedIndex, selectedValue)

            -- remove tooltip after change
            if self.tooltip then
                self:SetHandler("OnEnter", function() end)
                self:SetHandler("OnLeave", function() end)
                self.tooltip = nil
            end
        end
    end
    function dropdown:SetAllTextColor(color)
        color = color or dropDownFontColor -- Default to white if no color provided

        self:SetHighlightTextColor(unpack(color))
        self:SetPushedTextColor(unpack(color))
        self:SetDisabledTextColor(unpack(color))
        self:SetTextColor(unpack(color))
    end
    
    -- Add tooltip if provided
    local tooltip = nil
    if tooltipText and tooltipText ~= "" then
        tooltip = helpers.createTooltip("tooltip_" .. tostring(math.random(1000, 9999)), dropdown, tooltipText, 0)
        dropdown.tooltip = tooltip
    end

    return dropdown, label, tooltip
end

-- Create a text input/edit box with label and optional tooltip
function helpers.CreateTextEditWithLabel(parent, anchorInfo, labelText, width, height, defaultText, isDigitOnly, minValue, maxValue, onTextChanged, tooltipText)
    -- Create label first
    local label = parent:CreateChildWidget("label", "label_" .. tostring(math.random(1000, 9999)), 0, true)
    
    -- Set label positioning
    if anchorInfo.anchor then
        label:AddAnchor(anchorInfo.anchor, anchorInfo.target, anchorInfo.relativeAnchor or anchorInfo.anchor, anchorInfo.x or 0, anchorInfo.y or 0)
    end
    
    -- Set label properties
    label:SetText(labelText or "")
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetFontSize(labelFontSize)
    ApplyTextColor(label, lableFontColor)
    
    -- Create text edit below the label
    local textEdit = W_CTRL.CreateEdit("textEdit_" .. tostring(math.random(1000, 9999)), parent)
    textEdit:AddAnchor("TOPLEFT", label, "BOTTOMLEFT", 0, 10) -- gap below label
    
    -- Set text edit properties
    textEdit:SetExtent(width or 80, height or 24)
    textEdit:SetText(defaultText or "")
    textEdit.style:SetFontSize(FONT_SIZE.LARGE)
    textEdit.style:SetAlign(ALIGN.LEFT)
    textEdit.style:SetColor(FONT_COLOR.TITLE[1], FONT_COLOR.TITLE[2],
                         FONT_COLOR.TITLE[3], 1)
    -- Set digit-only properties if specified
    if isDigitOnly then
        textEdit.style:SetSnap(true)
        textEdit:SetDigit(true)
        textEdit.minValue = minValue or 1
        textEdit.maxValue = maxValue or 100
    end
    
    -- Set handler
    if onTextChanged then
        function textEdit:OnTextChanged()
            local text = self:GetText()
            local value = isDigitOnly and tonumber(text) or text
            
            if isDigitOnly and value then
                if string.len(text) >= 1 then
                    if value >= self.minValue and value <= self.maxValue then
                        onTextChanged(value, text)
                    elseif value < self.minValue then
                        value = self.minValue
                        self:SetText(tostring(value))
                        onTextChanged(value, tostring(value))
                    elseif value > self.maxValue then
                        value = self.maxValue
                        self:SetText(tostring(value))
                        onTextChanged(value, tostring(value))
                    end
                end
            else
                onTextChanged(value, text)
            end
        end
        textEdit:SetHandler("OnTextChanged", textEdit.OnTextChanged)
    end
    
    -- Add tooltip if provided
    local tooltip = nil
    if tooltipText and tooltipText ~= "" then
        tooltip = helpers.createTooltip("tooltip_" .. tostring(math.random(1000, 9999)), textEdit, tooltipText, 0, 0)
    end
    
    return textEdit, label, tooltip
end

function helpers.CreateSliderWithLabel(parent, anchorInfo, labelText, width, defaultValue, minValue, maxValue, step, onValueChanged, tooltipText, valueScale)
    local label = parent:CreateChildWidget("label", "label_" .. tostring(math.random(1000, 9999)), 0, true)

    if anchorInfo.anchor then
        label:AddAnchor(anchorInfo.anchor, anchorInfo.target, anchorInfo.relativeAnchor or anchorInfo.anchor, anchorInfo.x or 0, anchorInfo.y or 0)
    end

    local totalWidth = (width and width > 0) and width or sliderWidth
    local valueLabelWidth = 44
    local labelWidth = math.max(60, totalWidth - valueLabelWidth - 6)

    label:SetText(labelText or "")
    label:SetExtent(labelWidth, 18)
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetFontSize(labelFontSize)
    ApplyTextColor(label, lableFontColor)

    local valueLabel = parent:CreateChildWidget("label", "sliderValue_" .. tostring(math.random(1000, 9999)), 0, true)
    valueLabel:AddAnchor("LEFT", label, "RIGHT", 6, 0)
    valueLabel:SetExtent(valueLabelWidth, 18)
    valueLabel.style:SetAlign(ALIGN.RIGHT)
    valueLabel.style:SetFontSize(labelFontSize)
    ApplyTextColor(valueLabel, FONT_COLOR.BLACK)

    local sliderStep = tonumber(step) or 1

    local function getStepDecimals(value)
        local text = tostring(value or "")
        local dotIndex = string.find(text, ".", 1, true)
        if not dotIndex then
            return 0
        end
        return string.len(text) - dotIndex
    end

    local stepDecimals = getStepDecimals(sliderStep)
    local sliderScale = tonumber(valueScale)
    if sliderScale == nil or sliderScale < 1 then
        sliderScale = math.pow(10, stepDecimals)
    end
    sliderScale = math.max(1, math.floor(sliderScale + 0.5))

    local function scaleToSlider(value)
        return math.floor((tonumber(value) or 0) * sliderScale + 0.5)
    end

    local function scaleFromSlider(value)
        return (tonumber(value) or 0) / sliderScale
    end

    local slider = createSlider("slider_" .. tostring(math.random(1000, 9999)), parent)
    slider:AddAnchor("TOPLEFT", label, "BOTTOMLEFT", 0, 8)
    slider:SetExtent(totalWidth, 26)
    slider:SetMinMaxValues(scaleToSlider(minValue), scaleToSlider(maxValue))
    if slider.SetStep ~= nil then
        slider:SetStep(math.max(1, scaleToSlider(sliderStep)))
    else
        slider:SetValueStep(math.max(1, scaleToSlider(sliderStep)))
    end
    if slider.UseWheel ~= nil then
        slider:UseWheel()
    end

    local function formatValue(value)
        if stepDecimals <= 0 then
            return tostring(math.floor(value + 0.5))
        end

        local formatted = string.format("%." .. tostring(stepDecimals) .. "f", value)
        formatted = formatted:gsub("(%..-)0+$", "%1")
        formatted = formatted:gsub("%.$", "")
        return formatted
    end

    local function normalizeValue(value)
        value = tonumber(value) or minValue or 0
        if minValue ~= nil and value < minValue then
            value = minValue
        end
        if maxValue ~= nil and value > maxValue then
            value = maxValue
        end

        local baseValue = tonumber(minValue) or 0
        local snappedSteps = math.floor(((value - baseValue) / sliderStep) + 0.5)
        local snappedValue = baseValue + (snappedSteps * sliderStep)

        if minValue ~= nil and snappedValue < minValue then
            snappedValue = minValue
        end
        if maxValue ~= nil and snappedValue > maxValue then
            snappedValue = maxValue
        end

        return tonumber(string.format("%.6f", snappedValue)) or snappedValue
    end

    local isInternalSliderUpdate = false

    local function setSliderValue(value, shouldNotify)
        value = normalizeValue(value)
        valueLabel:SetText(formatValue(value))
        isInternalSliderUpdate = true
        if slider.SetValue ~= nil then
            slider:SetValue(scaleToSlider(value), false)
        end
        isInternalSliderUpdate = false
        if shouldNotify and onValueChanged then
            onValueChanged(value)
        end
    end

    local initialValue = normalizeValue(defaultValue)
    setSliderValue(initialValue, false)

    slider:SetHandler("OnSliderChanged", function(_, rawValue)
        if isInternalSliderUpdate then
            return
        end
        local value = normalizeValue(scaleFromSlider(rawValue))
        setSliderValue(value, true)
    end)

    local tooltip = nil
    if false and tooltipText and tooltipText ~= "" then
        tooltip = helpers.createTooltip("tooltip_" .. tostring(math.random(1000, 9999)), slider, tooltipText, 0, 0)
    end

    return slider, label, valueLabel, tooltip
end

function helpers.CreateCounterWithLabel(parent, anchorInfo, labelText, width, defaultValue, minValue, maxValue, step, onValueChanged, tooltipText)
    local label = parent:CreateChildWidget("label", "label_" .. tostring(math.random(1000, 9999)), 0, true)

    if anchorInfo.anchor then
        label:AddAnchor(anchorInfo.anchor, anchorInfo.target, anchorInfo.relativeAnchor or anchorInfo.anchor, anchorInfo.x or 0, anchorInfo.y or 0)
    end

    label:SetText(labelText or "")
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetFontSize(labelFontSize)
    ApplyTextColor(label, lableFontColor)

    local totalWidth = (width and width > 0) and width or counterWidth
    local smallLayout = totalWidth <= 64
    local buttonWidth = smallLayout and 14 or 16
    local buttonHeight = 20
    local gap = 1
    local valueWidth = math.max(18, totalWidth - (buttonWidth * 2) - (gap * 2))

    local minusButton = parent:CreateChildWidget("button", "counterMinus_" .. tostring(math.random(1000, 9999)), 0, true)
    minusButton:AddAnchor("TOPLEFT", label, "BOTTOMLEFT", 0, 8)
    minusButton:SetText("-")
    ApplyButtonSkin(minusButton, BUTTON_BASIC.RESET)
    minusButton:SetAutoResize(false)
    minusButton:SetExtent(buttonWidth, buttonHeight)
    minusButton.style:SetFontSize(12)
    ApplyButtonTextColor(minusButton, FONT_COLOR.DEFAULT)

    local valueLabel = parent:CreateChildWidget("label", "counterValue_" .. tostring(math.random(1000, 9999)), 0, true)
    valueLabel:AddAnchor("LEFT", minusButton, "RIGHT", gap, 0)
    valueLabel:SetExtent(valueWidth, counterHeight)
    valueLabel.style:SetAlign(ALIGN.CENTER)
    valueLabel.style:SetFontSize(dropDownFontSize)
    ApplyTextColor(valueLabel, dropDownFontColor)

    local plusButton = parent:CreateChildWidget("button", "counterPlus_" .. tostring(math.random(1000, 9999)), 0, true)
    plusButton:AddAnchor("LEFT", valueLabel, "RIGHT", gap, 0)
    plusButton:SetText("+")
    ApplyButtonSkin(plusButton, BUTTON_BASIC.RESET)
    plusButton:SetAutoResize(false)
    plusButton:SetExtent(buttonWidth, buttonHeight)
    plusButton.style:SetFontSize(12)
    ApplyButtonTextColor(plusButton, FONT_COLOR.DEFAULT)

    local counterStep = tonumber(step)
    if counterStep == nil then
        counterStep = 1
        tooltipText = onValueChanged
        onValueChanged = step
    end

    local function getStepDecimals(value)
        local text = tostring(value or "")
        local dotIndex = string.find(text, ".", 1, true)
        if not dotIndex then
            return 0
        end
        return string.len(text) - dotIndex
    end

    local stepDecimals = getStepDecimals(counterStep)

    local function formatValue(value)
        if stepDecimals <= 0 then
            return tostring(math.floor(value + 0.5))
        end

        local formatted = string.format("%." .. tostring(stepDecimals) .. "f", value)
        formatted = formatted:gsub("(%..-)0+$", "%1")
        formatted = formatted:gsub("%.$", "")
        return formatted
    end

    local function clampValue(value)
        value = tonumber(value) or minValue or 0
        if minValue ~= nil and value < minValue then
            value = minValue
        end
        if maxValue ~= nil and value > maxValue then
            value = maxValue
        end

        local baseValue = tonumber(minValue) or 0
        local snappedSteps = math.floor(((value - baseValue) / counterStep) + 0.5)
        local snappedValue = baseValue + (snappedSteps * counterStep)

        if minValue ~= nil and snappedValue < minValue then
            snappedValue = minValue
        end
        if maxValue ~= nil and snappedValue > maxValue then
            snappedValue = maxValue
        end

        return tonumber(string.format("%.6f", snappedValue)) or snappedValue
    end

    local currentValue = clampValue(defaultValue)

    function valueLabel:Refresh()
        self:SetText(formatValue(currentValue))
        minusButton:Enable(minValue == nil or currentValue > minValue)
        plusButton:Enable(maxValue == nil or currentValue < maxValue)
    end

    function valueLabel:SetValue(newValue, shouldNotify)
        local clampedValue = clampValue(newValue)
        if clampedValue == currentValue and not shouldNotify then
            return
        end
        currentValue = clampedValue
        self:Refresh()
        if shouldNotify and onValueChanged then
            onValueChanged(currentValue)
        end
    end

    function valueLabel:GetValue()
        return currentValue
    end

    function minusButton:OnClick()
        valueLabel:SetValue(currentValue - counterStep, true)
    end
    minusButton:SetHandler("OnClick", minusButton.OnClick)

    function plusButton:OnClick()
        valueLabel:SetValue(currentValue + counterStep, true)
    end
    plusButton:SetHandler("OnClick", plusButton.OnClick)

    valueLabel:Refresh()

    local tooltip = nil
    if tooltipText and tooltipText ~= "" then
        tooltip = helpers.createTooltip("tooltip_" .. tostring(math.random(1000, 9999)), valueLabel, tooltipText, 0, 0)
    end

    return valueLabel, label, minusButton, plusButton, tooltip
end

function helpers.DefaultTooltipSetting(widget)
    ApplyTextColor(widget, FONT_COLOR.SOFT_BROWN)
    widget:SetInset(10, 10, 10, 10)
    widget:SetLineSpace(4)
    widget.style:SetSnap(true)
end

function helpers.createTooltip(id, parent, text, x, y)
    local tooltip = api.Interface:CreateWidget("gametooltip", id, parent)
    local tooltipText = text

    tooltip:AddAnchor("BOTTOM", parent, "TOP", x or 0, y or -5)
    tooltip:EnablePick(false)
    tooltip:Show(false)
    helpers.DefaultTooltipSetting(tooltip)

    tooltip.bg = tooltip:CreateNinePartDrawable('ui/common_new/default.dds', "background")
    tooltip.bg:SetTextureInfo("tooltip")
    tooltip.bg:AddAnchor("TOPLEFT", tooltip, 0, 0)
    tooltip.bg:AddAnchor("BOTTOMRIGHT", tooltip, 0, 0)
    tooltip.bg:SetColor(1, 1, 1, 0.85) 
    tooltip.style:SetFontSize(14)

    -- Set word wrap properties for tooltip
    tooltip:SetAutoWordwrap(true)
    tooltip:SetWidth(300)
    
    tooltip:ClearLines()
    tooltip:AddLine(tooltipText, "", 0, "left", ALIGN.LEFT, 0)

    function parent:SetTooltipText(newText)
        tooltipText = newText
    end

    function parent:OnEnter()
        if not tooltipText or tooltipText == "" then
            return
        end

        tooltip:ClearLines()
        tooltip:AddLine(tooltipText, "", 0, "left", ALIGN.LEFT, 0)
        tooltip:Raise() -- Ensure tooltip is on top
        tooltip:Show(true)

    end
    
    function parent:OnLeave()
        tooltip:Show(false)
    end

    parent:SetHandler("OnEnter", parent.OnEnter)
    parent:SetHandler("OnLeave", parent.OnLeave)

    return tooltip
end

-- Creates a floating button that toggles the setttings visibility
function helpers.createOverlayButton(text, position, onDragStopProc)
    local btn = api.Interface:CreateWidget("button", "openTTTSettingsBtn", "UIParent")

    ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)

    btn:SetText("TrackThatPls")
    btn.style:SetFontSize(13)

    -- Set colors
    btn:SetTextColor(unpack(FONT_COLOR.DEFAULT))
    btn:SetHighlightTextColor(unpack(FONT_COLOR.DEFAULT))
    btn:SetPushedTextColor(unpack(FONT_COLOR.DEFAULT))
    btn:SetDisabledTextColor(unpack(FONT_COLOR.DEFAULT))

    -- Set size and position
    btn:SetExtent(85, 30)
    btn:AddAnchor("TOPLEFT", "UIParent", "TOPLEFT", position[1] , position[2])

    function btn:OnDragStart()
        self:RemoveAllAnchors()
        self:StartMoving()
        api.Cursor:ClearCursor()
        api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end

    function btn:OnDragStop()
        self:StopMovingOrSizing()
        api.Cursor:ClearCursor()

        onDragStopProc()
    end

    -- Assign drag handlers for btn
    btn:SetHandler("OnDragStart", btn.OnDragStart)
    btn:SetHandler("OnDragStop", btn.OnDragStop)
    btn:EnableDrag(true)
    btn:Show(true)

    return btn
end

return helpers
