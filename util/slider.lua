local api = require("api")

-- Portions of this implementation are based on the original AddonLibrary
-- slider code by Misosoup and contributors.

local UOT_SLIDER = 24
local WHITE_TEXTURE_PATH = "Textures/Defaults/White.dds"

local function createSolidDrawable(widget, layer, color, width, height)
    if type(widget) ~= "table" then
        return nil
    end

    local drawable = nil
    if widget.CreateImageDrawable ~= nil then
        local ok, result = pcall(function()
            return widget:CreateImageDrawable(WHITE_TEXTURE_PATH, layer or "background")
        end)
        if ok then
            drawable = result
        end
    end

    if drawable == nil and widget.CreateColorDrawable ~= nil then
        local ok, result = pcall(function()
            return widget:CreateColorDrawable(color[1], color[2], color[3], color[4], layer or "background")
        end)
        if ok then
            drawable = result
        end
    end

    if drawable == nil then
        return nil
    end

    if drawable.SetColor ~= nil then
        drawable:SetColor(color[1], color[2], color[3], color[4])
    end

    if width ~= nil and height ~= nil and drawable.SetExtent ~= nil then
        drawable:SetExtent(width, height)
    end

    return drawable
end

local function setButtonBackgrounds(button, drawables)
    if type(button) ~= "table" or type(drawables) ~= "table" then
        return
    end

    if button.SetNormalBackground ~= nil and drawables.normal ~= nil then
        button:SetNormalBackground(drawables.normal)
    end
    if button.SetHighlightBackground ~= nil and drawables.highlight ~= nil then
        button:SetHighlightBackground(drawables.highlight)
    end
    if button.SetPushedBackground ~= nil and drawables.pushed ~= nil then
        button:SetPushedBackground(drawables.pushed)
    end
    if button.SetDisabledBackground ~= nil and drawables.disabled ~= nil then
        button:SetDisabledBackground(drawables.disabled)
    end
end

local function setViewOfSlider(id, parent)
    local slider = parent:CreateChildWidgetByType(UOT_SLIDER, id, 0, true)
    slider:SetHeight(26)

    local bg = createSolidDrawable(slider, "background", {0.26, 0.22, 0.18, 1})
    if bg ~= nil then
        bg:AddAnchor("LEFT", slider, 3, 0)
        bg:AddAnchor("RIGHT", slider, -3, 0)
        if bg.SetHeight ~= nil then
            bg:SetHeight(6)
        elseif bg.SetExtent ~= nil then
            bg:SetExtent(0, 6)
        end
    end

    slider.bg = bg
    slider.bgColor = {0.56, 0.46, 0.24, 1}
    if slider.bg ~= nil and slider.bg.SetColor ~= nil then
        slider.bg:SetColor(slider.bgColor[1], slider.bgColor[2], slider.bgColor[3], slider.bgColor[4])
    end

    local thumb = slider:CreateChildWidget("button", "thumb", 0, true)
    thumb:Show(true)
    thumb:SetText("")
    local thumbDrawables = {
        normal = createSolidDrawable(thumb, "background", {0.95, 0.84, 0.46, 1}, 14, 22),
        highlight = createSolidDrawable(thumb, "background", {1, 0.9, 0.58, 1}, 14, 22),
        pushed = createSolidDrawable(thumb, "background", {0.88, 0.74, 0.34, 1}, 14, 22),
        disabled = createSolidDrawable(thumb, "background", {0.45, 0.45, 0.45, 1}, 14, 22)
    }
    for _, drawable in pairs(thumbDrawables) do
        if drawable ~= nil and drawable.AddAnchor ~= nil then
            drawable:AddAnchor("CENTER", thumb, 0, 0)
        end
    end
    setButtonBackgrounds(thumb, thumbDrawables)
    slider:SetThumbButtonWidget(thumb)
    slider.thumb = thumb
    slider:SetFixedThumb(true)
    slider:SetMinThumbLength(14)
    thumb:SetExtent(14, 22)
    slider:SetOrientation(1)

    return slider
end

local function createSlider(id, parent)
    local slider = setViewOfSlider(id, parent)
    slider.useWheel = false

    function slider:SetStep(value)
        self:SetValueStep(value)
        self:SetPageStep(value)
    end

    function slider:SetInitialValue(initialValue)
        self:SetValue(initialValue, false)
    end

    function slider:SetBgColor(colorTable)
        self.bgColor = colorTable
        if self.bg ~= nil and self.bg.SetColor ~= nil then
            self.bg:SetColor(self.bgColor[1], self.bgColor[2], self.bgColor[3], self.bgColor[4])
        end
    end

    function slider:SetEnable(enable)
        if self.thumb ~= nil and self.thumb.Enable ~= nil then
            self.thumb:Enable(enable)
        end
        if self.label ~= nil then
            for index = 1, #self.label do
                self.label[index]:Enable(enable)
            end
        end
        if self.bg ~= nil and self.bg.SetColor ~= nil and enable then
            self.bg:SetColor(self.bgColor[1], self.bgColor[2], self.bgColor[3], self.bgColor[4])
        elseif self.bg ~= nil and self.bg.SetColor ~= nil then
            self.bg:SetColor(0.5, 0.5, 0.5, 1)
        end
    end

    function slider:UseWheel()
        self.useWheel = true

        self:SetHandler("OnWheelUp", function(this)
            if not this:IsEnabled() or not this.useWheel then
                return
            end
            this:Up(1)
        end)

        self:SetHandler("OnWheelDown", function(this)
            if not this:IsEnabled() or not this.useWheel then
                return
            end
            this:Down(1)
        end)
    end

    return slider
end

return createSlider