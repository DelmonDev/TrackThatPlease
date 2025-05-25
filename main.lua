local BuffWatchWindow = require("TrackThatPlease/buffwatchwindow")

-- Addon Information
local TargetBuffTrackerAddon = {
    name = "TrackThatPlease",
    author = "Dehling/Fortuno",
    version = "2.0",
    desc = "Tracks buffs/debuffs on target, with UI"
}

--FORK Option by @Fortuno for colored buff debuff borders

-- UI Elements
local buffTrackerCanvas
local MAX_BUFFS_SHOWN = 8
local buffIcons = {}
local buffLabels = {}

-- Variables
local previousXYZ = "0,0,0"
local previousTarget

-- THIS RIGHT HERE ARE THE SETTINGS, 
local settings = {
    ShowTimers = true,
    IconSize = 34,
    IconSpacing = 3,
    UISize = 100, -- 80, 90 ,100, 110, 120
    RecolorIconBorders = true  -- New setting for toggling icon border recoloring
}

--ICON BACKGROUNDS IF BUFF OR DEBUFF
--------------------------------------------------------------------------------------------------------------------------------------------
BUFF = {
    path = TEXTURE_PATH.HUD,
    coords = {
        685,
        130,
        7,
        8
    },
    inset = {
        3,
        3,
        3,
        3
    },
    color = {
        0,
        1,
        0,
        1
    }
}

DEBUFF = {
    path = TEXTURE_PATH.HUD,
    coords = {
        685,
        130,
        7,
        8
    },
    inset = {
        3,
        3,
        3,
        3
    },
    color = {
        1,
        0,
        0,
        1
    }
}
--------------------------------------------------------------------------------------------------------------------------------------------
-- Function to check if a buff is being watched
local function IsWatchedBuff(buffId)
    return BuffWatchWindow.IsBuffWatched(math.floor(tonumber(buffId) or 0))
end

-- Function to create buff icon and label
local function CreateBuffElement(index)
    local icon = CreateItemIconButton("targetBuffIcon" .. index, buffTrackerCanvas)
    icon:Clickable(false)
    icon:SetExtent(settings.IconSize, settings.IconSize)
    icon:Show(false)

    local label
    if settings.ShowTimers then
        label = buffTrackerCanvas:CreateChildWidget("label", "buffTimeLeftLabel" .. index, 0, true)
        label:SetText("")
        label:AddAnchor("CENTER", icon, "CENTER", 0, 0)
        --label:AddAnchor("BOTTOM", icon, "TOP", 0, -5)
        label.style:SetFontSize(12)

        label.style:SetOutline(true)
        label.style:SetAlign(ALIGN_CENTER)
        label.style:SetShadow(true)
        label:Show(false)
    end

    return icon, label
end

-- Function to position buffs with whole bar centered
local function PositionBuffs(watchedBuffs)
    local totalWidth = #watchedBuffs * settings.IconSize + (#watchedBuffs - 1) * settings.IconSpacing
    local startX = -totalWidth / 2 + settings.IconSize / 2
    
    for i = 1, #watchedBuffs do
        local icon = buffIcons[i]
        local offsetX = startX + (i - 1) * (settings.IconSize + settings.IconSpacing)
        icon:RemoveAllAnchors()
        icon:AddAnchor("CENTER", buffTrackerCanvas, "CENTER", offsetX, 0)
    end
end

-- Function to get position adjustments based on UI scale
local function GetPositionAdjustment()
    local adjustments = {
        [80] = { x = 0, y = -6 },
        [90] = { x = 0, y = -3 },
        [100] = { x = 0, y = 0 },
        [110] = { x = 0, y = 3 },
        [120] = { x = 0, y = 6 },
    }
    return adjustments[settings.UISize] or { x = 0, y = 0 }
end

-- Function to collect all watched buffs and debuffs
local function CollectWatchedBuffsAndDebuffs()
    local watchedBuffs = {}
    
    -- Check buffs
    local buffCount = api.Unit:UnitBuffCount("target") or 0
    for i = 1, buffCount do
        local buff = api.Unit:UnitBuff("target", i)
        if buff and IsWatchedBuff(buff.buff_id) then
           
            buff.isBuff = true
            table.insert(watchedBuffs, buff)
        end
    end
    
    -- Check debuffs
    local debuffCount = api.Unit:UnitDeBuffCount("target") or 0
    for i = 1, debuffCount do
        local debuff = api.Unit:UnitDeBuff("target", i)
        if debuff and IsWatchedBuff(debuff.buff_id) then
            debuff.isBuff = false
            table.insert(watchedBuffs, debuff)
        end
    end
    
    return watchedBuffs
end

-- Update event to handle player tracking and buff/debuff update
local function GetBlinkAlpha(minAlpha, maxAlpha, timer, speed)
    local amplitude = (maxAlpha - minAlpha) / 2
    local mid = (maxAlpha + minAlpha) / 2
    return mid + amplitude * math.sin(timer * speed)
end

local blinkTimer = 0
local function OnUpdate(dt)
    blinkTimer = blinkTimer + dt / 1000
    local currentTarget = api.Unit:GetUnitId("target")
    
    -- Calculate when to move the anchor for the buff tracker
    local x, y, z = api.Unit:GetUnitScreenPosition("target")

    -- If you switch targets or player is nil, hide all buffs
    if currentTarget == nil or currentTarget ~= previousTarget then
        for i = 1, MAX_BUFFS_SHOWN do
            buffIcons[i]:Show(false)
            if buffLabels[i] then buffLabels[i]:Show(false) end
        end
        buffTrackerCanvas:Show(false)
        previousTarget = currentTarget
        return
    end

    -- Collect all watched buffs and debuffs
    local watchedBuffs = CollectWatchedBuffsAndDebuffs()

    -- Update position and show watched buffs/debuffs
    if #watchedBuffs > 0 then
        PositionBuffs(watchedBuffs)

        for i = 1, math.min(#watchedBuffs, MAX_BUFFS_SHOWN) do
            local buff = watchedBuffs[i]
            local icon = buffIcons[i]
            local label = buffLabels[i]

            F_SLOT.SetIconBackGround(icon, buff.path)
            if settings.RecolorIconBorders then
                if buff.isBuff then
                    F_SLOT.ApplySlotSkin(icon, icon.back, BUFF)
                else
                    F_SLOT.ApplySlotSkin(icon, icon.back, DEBUFF)
                end
            else
                F_SLOT.ApplySlotSkin(icon, icon.back, SLOT_STYLE.DEFAULT)
            end
            icon:Show(true)
            
            if settings.ShowTimers and label then
                if buff.timeLeft and buff.timeLeft > 0 then
                    local shouldBlink = (buff.isBuff and buff.timeLeft < 3000) or (not buff.isBuff and buff.timeLeft < 2000)
                    if shouldBlink then
                        local blinkSpeed =  4
                        local alpha = GetBlinkAlpha(0.5, 1, blinkTimer, blinkSpeed)
                        icon:SetAlpha(alpha)
                        label:SetAlpha(alpha)
                        label:SetText(string.format("%.1f", (buff.timeLeft / 1000)))
                    else
                        label:SetAlpha(1)
                        icon:SetAlpha(1)
                        if buff.timeLeft > 60000 then
                            label:SetText(string.format("%dm", math.floor(buff.timeLeft / 60000)))
                        else
                            label:SetText(string.format("%d", (buff.timeLeft / 1000)))
                        end
                    end

                    
                else
                    label:SetText("")
                end
                label:Show(true)
            end
        end

        -- Hide unused buff slots
        for i = #watchedBuffs + 1, MAX_BUFFS_SHOWN do
            buffIcons[i]:Show(false)
            if buffLabels[i] then buffLabels[i]:Show(false) end
        end

--[[         -- Update canvas position with UI scale adjustment
        if previousXYZ ~= (x .. "," .. y .. "," .. z) then ]]
            local adjustment = GetPositionAdjustment()
            local baseOffsetY = -35  -- Base vertical offset
            buffTrackerCanvas:RemoveAllAnchors()
            buffTrackerCanvas:AddAnchor("BOTTOM", "UIParent", "TOPLEFT", x + adjustment.x, y + baseOffsetY + adjustment.y)
--[[             previousXYZ = x .. "," .. y .. "," .. z
        end ]]

        buffTrackerCanvas:Show(z >= 0 and z <= 100)
    else
        blinkTimer = 0
        buffTrackerCanvas:Show(false)
    end

    previousTarget = currentTarget
end

local function HandleChatCommand(channel, unit, isHostile, name, message, speakerInChatBound, specifyName, factionName, trialPosition)
    local playerName = api.Unit:GetUnitNameById(api.Unit:GetUnitId("player"))
    if playerName == name and message == "ttp" then
        BuffWatchWindow.ToggleBuffSelectionWindow()
    end
end

-- Load function to initialize the UI elements
local function OnLoad()
    api.Log:Info("TrackThatPlease had been loaded. Type - ttp - in chat to acces the TrackList")
    local savedSettings = api.GetSettings("TrackThatPlease")
    if savedSettings then
        for k, v in pairs(savedSettings) do
            settings[k] = v
        end
    end

    -- Ensure the new setting has a default value if it wasn't in saved settings
    if settings.RecolorIconBorders == nil then
        settings.RecolorIconBorders = true
    end

    buffTrackerCanvas = api.Interface:CreateEmptyWindow("buffTargetOnMe")
    buffTrackerCanvas:SetExtent(settings.IconSize * MAX_BUFFS_SHOWN + (MAX_BUFFS_SHOWN - 1) * settings.IconSpacing, settings.IconSize)
    buffTrackerCanvas:Show(false)
    buffTrackerCanvas:Clickable(false)
    
    for i = 1, MAX_BUFFS_SHOWN do
        buffIcons[i], buffLabels[i] = CreateBuffElement(i)
    end
    
    api.On("UPDATE", OnUpdate)
    api.On("CHAT_MESSAGE", HandleChatCommand)
    
    BuffWatchWindow.Initialize()
end

-- Unload function to clean up
local function OnUnload()
    if buffTrackerCanvas ~= nil then
        buffTrackerCanvas:Show(false)
        buffTrackerCanvas = nil
    end
    BuffWatchWindow.Cleanup()
    
end

TargetBuffTrackerAddon.OnLoad = OnLoad
TargetBuffTrackerAddon.OnUnload = OnUnload

return TargetBuffTrackerAddon