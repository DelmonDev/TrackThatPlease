local api = require("api")
local BuffSettingsWindow = require("TrackThatPlease/buff_settings_wnd")
local helpers = require("TrackThatPlease/util/helpers")
local BuffsLogger = require("TrackThatPlease/util/buff_logger")
local BuffList = require("TrackThatPlease/buff_helper")
local stopReccordingIconPath = "../Addon/TrackThatPlease/icons/rec-button.png"
local openSettingsBtnStopIcon

-- Addon Information
local TargetBuffTrackerAddon = {
    name = "TrackThatPlease",
    author = "Dehling/Fortuno",
    version = "2.2",
    desc = "Tracks buffs/debuffs on target, with UI"
}

--FORK Option by @Fortuno for colored buff debuff borders
--FORK Idea by @mykeew to implement targeting for Target and Self (Player), now properly implemented

-- UI Elements
local playerBuffCanvas
local targetBuffCanvas
local playerBuffIcons = {}
local playerBuffLabels = {}
local targetBuffIcons = {}
local targetBuffLabels = {}
local playerBuffStackLabels = {}
local targetBuffStackLabels = {}
local openSettingsBtn

-- Variables
local previousPlayerXYZString = "0,0,0"
local previousPlayerXYZSmothed = {x = 0, y = 0, z = 0}
local previousTargetXYZString = "0,0,0"
local previousTargetXYZSmothed = {x = 0, y = 0, z = 0}
local previousTarget
local uiScale
local isRefreshingUIForNewSettings = false


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
-- smoothing function to prevent player buffs jittering
-- Frame-rate independent smoothing function to prevent player buffs jittering
local function SmoothPosition(current, last, deltaTime, unitType)
    local smoothingSpeed = BuffSettingsWindow.settings.smoothingSpeed

    if unitType == "target" then
        return {
            x = current.x,
            y = current.y,
            z = current.z
        }
    end

    if smoothingSpeed == 0 then
        return {
            x = math.floor(current.x * 100 + 0.5) / 100,
            y = math.floor(current.y * 100 + 0.5) / 100,
            z = current.z
        }
    end

    -- Calculate the smoothing factor (frame-rate independent)
    local smoothingFactor = 1 - math.exp(-smoothingSpeed * (deltaTime / 1000))
    smoothingFactor = math.max(0, math.min(1, smoothingFactor))
    
    local smoothedX = last.x + (current.x - last.x) * smoothingFactor
    local smoothedY = last.y + (current.y - last.y) * smoothingFactor
    
    return {
        x = math.floor(smoothedX * 100 + 0.5) / 100,
        y = math.floor(smoothedY * 100 + 0.5) / 100,
        z = current.z
    }
end

local buffBlinkSpeed = 5 -- Speed of the blink effect
local function GetBlinkAlpha(minAlpha, maxAlpha, timer)
    local amplitude = (maxAlpha - minAlpha) / 2
    local mid = (maxAlpha + minAlpha) / 2
    return mid + amplitude * math.sin(timer * buffBlinkSpeed)
end

-- Function to check if a buff is being watched for player or target
local function IsWatchedBuff(buffId, isPlayer)
    buffId = math.floor(tonumber(buffId) or 0)
    if isPlayer then
        return BuffSettingsWindow.IsPlayerBuffWatched(buffId)
    else
        return BuffSettingsWindow.IsTargetBuffWatched(buffId)
    end
end

-- Function to create buff icon and label
local function CreateBuffElement(index, canvas)
    local icon = CreateItemIconButton("buffIcon" .. index, canvas)
    F_SLOT.ApplySlotSkin(icon, icon.back, SLOT_STYLE.DEFAULT)
    icon:Clickable(false)
    icon:SetExtent(BuffSettingsWindow.settings.iconSize, BuffSettingsWindow.settings.iconSize)
    icon:Show(false)

    -- Create a border around the icon
    local borderSize = 1
    
    -- Top border
    local topBorder = icon:CreateColorDrawable(1, 1, 1, 0, "overlay")
    topBorder:AddAnchor("TOPLEFT", icon, -borderSize, -borderSize)
    topBorder:AddAnchor("TOPRIGHT", icon, borderSize, -borderSize)
    topBorder:SetHeight(borderSize)
    icon.topBorder = topBorder
    
    -- Bottom border
    local bottomBorder = icon:CreateColorDrawable(1, 1, 1, 0, "overlay")
    bottomBorder:AddAnchor("BOTTOMLEFT", icon, -borderSize, borderSize)
    bottomBorder:AddAnchor("BOTTOMRIGHT", icon, borderSize, borderSize)
    bottomBorder:SetHeight(borderSize)
    icon.bottomBorder = bottomBorder
    
    -- Left border
    local leftBorder = icon:CreateColorDrawable(1, 1, 1, 0, "overlay")
    leftBorder:AddAnchor("TOPLEFT", icon, -borderSize, -borderSize)
    leftBorder:AddAnchor("BOTTOMLEFT", icon, -borderSize, borderSize)
    leftBorder:SetWidth(borderSize)
    icon.leftBorder = leftBorder
    
    -- Right border
    local rightBorder = icon:CreateColorDrawable(1, 1, 1, 0, "overlay")
    rightBorder:AddAnchor("TOPRIGHT", icon, borderSize, -borderSize)
    rightBorder:AddAnchor("BOTTOMRIGHT", icon, borderSize, borderSize)
    rightBorder:SetWidth(borderSize)
    icon.rightBorder = rightBorder

    function icon:SetBorderColor(color)
        self.topBorder:SetColor(unpack(color))
        self.bottomBorder:SetColor(unpack(color))
        self.leftBorder:SetColor(unpack(color))
        self.rightBorder:SetColor(unpack(color))
    end

    ----------------------------------------------------------------

    -- Create time label -------------------------------------
    local timeLabel
    timeLabel = canvas:CreateChildWidget("label", "buffTimeLeftLabel" .. index, 0, true)
    timeLabel:SetText("")
    timeLabel:AddAnchor("CENTER", icon, "CENTER", 0, 0)
    timeLabel.style:SetFontSize(BuffSettingsWindow.settings.fontSize)
    --timeLabel.style:SetFont("ui/font/yoon_firedgothic_b.ttf", BuffSettingsWindow.settings.fontSize)
    timeLabel.style:SetAlign(ALIGN.CENTER)
    timeLabel.style:SetShadow(true)
    timeLabel.style:SetOutline(true)
    timeLabel:Show(false)
    timeLabel.style:SetColor(1, 1, 1, 1)

    local stackLabel = canvas:CreateChildWidget("label", "buffStackLabel" .. index, 0, true)
    local stackFontSize = math.floor(BuffSettingsWindow.settings.fontSize * 0.65 + 0.5)
    stackLabel:SetText("")
    stackLabel:AddAnchor("TOPLEFT", icon, "TOPLEFT", 2, 6)
    -- ui/font/SD_LeeyagiL.ttf
    -- ui/font/yoon_firedgothic_b.ttf
    --stackLabel.style:SetFont("ui/font/yoon_firedgothic_b.ttf", BuffSettingsWindow.settings.fontSize - 4) -- another font for stacks
    stackLabel.style:SetFontSize(stackFontSize)
    stackLabel.style:SetAlign(ALIGN.LEFT)
    stackLabel.style:SetShadow(true)
    stackLabel.style:SetOutline(true)
    stackLabel.style:SetColor(0.97, 0.91, 0.81, 0.9)
    stackLabel:SetAlpha(0.80) 

    stackLabel:Show(false)

    return icon, timeLabel, stackLabel
end

-- Function to position buffs with whole bar centered
local function PositionBuffs(watchedBuffs, canvas, icons, labels, stackLabels)
    local maxBuffsToDisplay = math.min(#watchedBuffs, BuffSettingsWindow.settings.maxBuffsShown)
    local iconSize = BuffSettingsWindow.settings.iconSize
    local iconSpacing = BuffSettingsWindow.settings.iconSpacing
    local fontSize = BuffSettingsWindow.settings.fontSize
    
    local newWidth = iconSize * maxBuffsToDisplay + (maxBuffsToDisplay - 1) * iconSpacing
    local newHeight = iconSize

    -- Update the canvas size
    canvas:SetExtent(newWidth, newHeight)

    local startX = -newWidth / 2 + iconSize / 2
    
    for i = 1, maxBuffsToDisplay do
        local icon = icons[i]
        local offsetX = startX + (i - 1) * (iconSize + iconSpacing)
        local label = labels[i]
        local stackLabel = stackLabels[i]

        label.style:SetFontSize(fontSize)
        stackLabel.style:SetFontSize(fontSize - 3) -- Update stack label font size
        icon:SetExtent(iconSize, iconSize)
        icon:RemoveAllAnchors()
        icon:AddAnchor("CENTER", canvas, "CENTER", offsetX, 0)
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
    return adjustments[uiScale] or { x = 0, y = 0 }
end

-- Function to collect all watched buffs and debuffs
local function CollectWatchedBuffsAndDebuffs()
    local playerBuffs = {}
    local targetBuffs = {}

    -- Helper function to collect buffs and debuffs from a unit
    local function CollectBuffsAndDebuffs(unit, buffList, isPlayer)
        -- Check buffs
        local buffCount = api.Unit:UnitBuffCount(unit) or 0
        for i = 1, buffCount do
            local buff = api.Unit:UnitBuff(unit, i)
            if buff and IsWatchedBuff(buff.buff_id, isPlayer) then
                buff.isBuff = true
                table.insert(buffList, buff)
            end
        end

        -- Check debuffs
        local debuffCount = api.Unit:UnitDeBuffCount(unit) or 0
        for i = 1, debuffCount do
            local debuff = api.Unit:UnitDeBuff(unit, i)
            if debuff and IsWatchedBuff(debuff.buff_id, isPlayer) then
                debuff.isBuff = false
                table.insert(buffList, debuff)
            end
        end
    end

    -- Collect buffs and debuffs from the player
    CollectBuffsAndDebuffs("player", playerBuffs, true)

    -- Collect buffs and debuffs from the target
    CollectBuffsAndDebuffs("target", targetBuffs, false)

    return playerBuffs, targetBuffs
end

-- Function to clear all buff icons and labels
local function ClearAllBuffs()
    for i = 1, BuffSettingsWindow.MAX_BUFFS_COUNT do
        if playerBuffIcons[i] then
            playerBuffIcons[i]:Show(false)
        end
        if playerBuffLabels[i] then
            playerBuffLabels[i]:Show(false)
        end
        if playerBuffStackLabels[i] then
            playerBuffStackLabels[i]:Show(false)
        end
        if targetBuffIcons[i] then
            targetBuffIcons[i]:Show(false)
        end
        if targetBuffLabels[i] then
            targetBuffLabels[i]:Show(false)
        end
        if targetBuffStackLabels[i] then
            targetBuffStackLabels[i]:Show(false)
        end
    end
end

local loggedBuffIds = {}

local function UpdateBuffIconsAndTimers(buffs, icons, timeLabels, stackLabels, maxBuffsToDisplay, blinkTimer)
    local shoudShowStacks = BuffSettingsWindow.settings.shouldShowStacks

    for i = 1, maxBuffsToDisplay do
        local buff = buffs[i]
        local icon = icons[i]
        local timeLabel = timeLabels[i]
        local stackLabel = stackLabels[i]

        F_SLOT.SetIconBackGround(icon, buff.path)
        

        if buff.isBuff then
            F_SLOT.ApplySlotSkin(icon, icon.back, BUFF)
            icon:SetBorderColor({0, 1, 0, 0.6}) 
        else
            F_SLOT.ApplySlotSkin(icon, icon.back, DEBUFF)
            icon:SetBorderColor({1, 0, 0, 0.6})
        end

        icon:Show(true)
        -- Buff indication logic
        if buff.timeLeft and buff.timeLeft > 0 then
            -- Timers ----------------------------------------------------------------
            local timerText = ""
            local warnTime = (buff.isBuff and BuffSettingsWindow.settings.buffWarnTime) 
                or (not buff.isBuff and BuffSettingsWindow.settings.debuffWarnTime)

            if buff.timeLeft > 5940000 then -- More than 99 minutes (99 * 60 * 1000 ms)
                timerText = string.format("%dh", math.floor(buff.timeLeft / 3600000)) -- Convert to hours
            elseif buff.timeLeft > 60000 then -- More than 1 minute but less than 99 minutes
                timerText = string.format("%dm", math.floor(buff.timeLeft / 60000))
            elseif buff.timeLeft >= warnTime then
                timerText = string.format("%ds", math.floor(buff.timeLeft / 1000))
            else -- Less than warnTime
                timerText = string.format("%.1f", buff.timeLeft / 1000)
            end
            timeLabel:SetText(timerText)
            timeLabel:Show(true)

            -- Stacks -------------------------------------------------------------------------------
            -- shoudShowStacks
            if shoudShowStacks and buff.stack and buff.stack > 1 then
                -- Format stack number
                local stackText
                local thousands
                if buff.stack >= 1000 then
                    thousands = buff.stack / 1000
                    if thousands == math.floor(thousands) then
                        stackText = string.format("%dk", thousands)
                    else
                        stackText = string.format("%.1fk", thousands)
                    end
                else
                    stackText = tostring(buff.stack)
                end
                
                --stackLabel:SetText("x" .. (buff.stack >= 1000 and " " or "") .. stackText)
                stackLabel:SetText("x" .. stackText)
                stackLabel:Show(true)
            else
                stackLabel:Show(false)
            end

            -- Blink effect -----------------------------------------------------------------
            local shouldBlink = (
                (buff.isBuff and buff.timeLeft <= BuffSettingsWindow.settings.buffWarnTime) or
                (not buff.isBuff and buff.timeLeft <= BuffSettingsWindow.settings.debuffWarnTime)
            )

            if shouldBlink then
                local alpha = GetBlinkAlpha(0.45, 1, blinkTimer)
                icon:SetAlpha(alpha)
                timeLabel:SetAlpha(alpha)
                stackLabel:SetAlpha(alpha)
            else
                timeLabel:SetAlpha(1)
                icon:SetAlpha(1)
                stackLabel:SetAlpha(1)
            end
        else
            timeLabel:SetText("")
            timeLabel:Show(false)
            stackLabel:SetText("")
            stackLabel:Show(false)
        end
    end
end

local function HideUnusedBuffSlots(buffIcons, buffLabels, stackLabels, maxBuffsToDisplay)
    -- Hide unused buff slots
    for i = maxBuffsToDisplay + 1, BuffSettingsWindow.MAX_BUFFS_COUNT do
        buffIcons[i]:Show(false)
        if buffLabels[i] then buffLabels[i]:Show(false) end
        if stackLabels[i] then stackLabels[i]:Show(false) end
    end
end

local function UpdateBuffsPositionWithSmoothing(unitType, dt)
    local x, y, z = api.Unit:GetUnitScreenPosition(unitType)
    
    if x and y and z then
        local currentPos = {x = x, y = y, z = z}
        
        local previousXYZSmoothed, previousXYZString, canvas, baseOffsetY
        
        if unitType == "player" then
            previousXYZSmoothed = previousPlayerXYZSmothed
            previousXYZString = previousPlayerXYZString
            canvas = playerBuffCanvas
            baseOffsetY = BuffSettingsWindow.settings.playerBuffVerticalOffset
        else -- target
            previousXYZSmoothed = previousTargetXYZSmothed
            previousXYZString = previousTargetXYZString
            canvas = targetBuffCanvas
            baseOffsetY = BuffSettingsWindow.settings.targetBuffVerticalOffset
        end
        
        local smoothPos = SmoothPosition(currentPos, previousXYZSmoothed, dt, unitType)
        
        local smoothedPosString = string.format("%.3f,%.3f,%.3f", smoothPos.x, smoothPos.y, smoothPos.z)
        if previousXYZString ~= smoothedPosString then
            local adjustment = GetPositionAdjustment()
            
            canvas:RemoveAllAnchors()
            canvas:AddAnchor("BOTTOM", "UIParent", "TOPLEFT", 
                smoothPos.x + adjustment.x, 
                smoothPos.y + baseOffsetY + adjustment.y)
            
            if unitType == "player" then
                previousPlayerXYZString = smoothedPosString
            else -- target
                previousTargetXYZString = smoothedPosString
            end
        end
        
        previousXYZSmoothed.x = smoothPos.x
        previousXYZSmoothed.y = smoothPos.y
        previousXYZSmoothed.z = smoothPos.z
        
        canvas:Show(previousXYZSmoothed.z >= 0 and previousXYZSmoothed.z <= 100)
    end
end


local blinkTimer = 0
local BLINK_CYCLE = math.pi * 2 -- Full cycle for sin()

--- Function to update the blink timer based on player and target buffs
local function UpdateBlinkTimer(playerBuffs, targetBuffs, dt)
    if #playerBuffs > 0 or #targetBuffs > 0 then
        blinkTimer = blinkTimer + dt / 1000
        
        if blinkTimer >= BLINK_CYCLE then
            blinkTimer = blinkTimer - BLINK_CYCLE
        end
    else
        blinkTimer = 0 
    end
end

local recordingIconAnimation = {
    isActive = false,
    currentAlpha = 1.0,
    targetAlpha = 0.1,
    direction = -1,
    animationSpeed = 0.08,
    stepDelay = 100
}

-- Function to show recording animation
local function AnimateRecordingIcon()
    if not recordingIconAnimation.isActive then
        return
    end
    
    if not openSettingsBtn or not openSettingsBtn.recordingIndicationIcon then
        recordingIconAnimation.isActive = false
        return
    end
    
    -- Update current alpha
    recordingIconAnimation.currentAlpha = recordingIconAnimation.currentAlpha + 
        (recordingIconAnimation.animationSpeed * recordingIconAnimation.direction)
    
    -- Перевірити межі та змінити напрямок
    if recordingIconAnimation.currentAlpha <= 0.1 then
        recordingIconAnimation.currentAlpha = 0.1
        recordingIconAnimation.direction = 1 -- Start increasing
    elseif recordingIconAnimation.currentAlpha >= 1.0 then
        recordingIconAnimation.currentAlpha = 1.0
        recordingIconAnimation.direction = -1 -- Start decreasing
    end
    
    -- Aplly alpha
    openSettingsBtn.recordingIndicationIcon:SetColor(1, 1, 1, recordingIconAnimation.currentAlpha)
    
    -- Plann next animation
    if recordingIconAnimation.isActive then
        api:DoIn(recordingIconAnimation.stepDelay, AnimateRecordingIcon)
    end
end

-- Update event to handle buff/debuff updates
local function OnUpdate(dt)
    -- If active will track buffs
    BuffsLogger.Track(dt)


    -- Check if player is targeting themselves
    local playerUnitId = api.Unit:GetUnitId("player")
    local targetUnitId = api.Unit:GetUnitId("target")
    local isSelfTarget = (playerUnitId == targetUnitId)

    -- Collect all watched buffs and debuffs
    local playerBuffs, targetBuffs = CollectWatchedBuffsAndDebuffs()
    -- Update blink timer
    UpdateBlinkTimer(playerBuffs, targetBuffs, dt)

    -- ## PLAYER Update position and show player buffs/debuffs ##------
    if #playerBuffs > 0 then
        local maxPlayerBuffsToDisplay = math.min(#playerBuffs, BuffSettingsWindow.settings.maxBuffsShown)

        PositionBuffs(playerBuffs, playerBuffCanvas, playerBuffIcons, playerBuffLabels, playerBuffStackLabels)
        UpdateBuffIconsAndTimers(playerBuffs, playerBuffIcons, playerBuffLabels, playerBuffStackLabels, maxPlayerBuffsToDisplay, blinkTimer)
        HideUnusedBuffSlots(playerBuffIcons, playerBuffLabels, playerBuffStackLabels, maxPlayerBuffsToDisplay)
        UpdateBuffsPositionWithSmoothing("player", dt)
    else
        -- Hide last icon and label if no player buffs
        if playerBuffIcons[1]:Show(false) then playerBuffIcons[1]:Show(false) end
        if playerBuffLabels[1] then playerBuffLabels[1]:Show(false) end
        if playerBuffStackLabels[1] then playerBuffStackLabels[1]:Show(false) end
        playerBuffCanvas:Show(false)
    end
    -- ##--------------------------------------------------------------------------------- ## -----

    -- ## TARGET Update position and show target buffs/debuffs (only if not self-targeting) ##------
    if not isSelfTarget and #targetBuffs > 0 then
        local maxTargetBuffsToDisplay = math.min(#targetBuffs, BuffSettingsWindow.settings.maxBuffsShown)

        PositionBuffs(targetBuffs, targetBuffCanvas, targetBuffIcons, targetBuffLabels, targetBuffStackLabels)
        UpdateBuffIconsAndTimers(targetBuffs, targetBuffIcons, targetBuffLabels, targetBuffStackLabels, maxTargetBuffsToDisplay, blinkTimer)
        HideUnusedBuffSlots(targetBuffIcons, targetBuffLabels, targetBuffStackLabels, maxTargetBuffsToDisplay)
        UpdateBuffsPositionWithSmoothing("target", dt)
    else
        -- Hide last icon and label if no target buffs
        if targetBuffIcons[1]:Show(false) then targetBuffIcons[1]:Show(false) end
        if targetBuffLabels[1] then targetBuffLabels[1]:Show(false) end
        if targetBuffStackLabels[1] then targetBuffStackLabels[1]:Show(false) end
        targetBuffCanvas:Show(false)
    end
    -- ##---------------------------------------------------------------------------------
end

local function HandleChatCommand(channel, unit, isHostile, name, message, speakerInChatBound, specifyName, factionName, trialPosition)
    local playerName = api.Unit:GetUnitNameById(api.Unit:GetUnitId("player"))
    if playerName == name and message == "ttp" then
        BuffSettingsWindow.ToggleBuffSelectionWindow()
    end
end

local function OnNewBuffLogged()
    BuffSettingsWindow.RefreshLoggedBuffs()
end
local function OnBuffsLoggingStarted()
    if not recordingIconAnimation.isActive then
        openSettingsBtn.recordingIndicationIcon:SetVisible(true)
        recordingIconAnimation.isActive = true
        recordingIconAnimation.currentAlpha = 1.0
        recordingIconAnimation.direction = -1
        AnimateRecordingIcon()
    end
end
local function OnBuffsLoggingStopped()
    recordingIconAnimation.isActive = false
    openSettingsBtn.recordingIndicationIcon:SetVisible(false)
    if openSettingsBtn and openSettingsBtn.recordingIndicationIcon then
        openSettingsBtn.recordingIndicationIcon:SetColor(1, 1, 1, 1.0)
    end
end

-- Load function to initialize the UI elements
local function OnLoad()
    -- load setttings------------------------
    BuffsLogger.Initialize()
    BuffSettingsWindow.Initialize(BuffsLogger)

    uiScale = math.floor(BuffSettingsWindow.settings.UIScale * 100 + 0.5)
    -------------------------------------

    playerBuffCanvas = api.Interface:CreateEmptyWindow("playerBuffCanvas")
    playerBuffCanvas:SetExtent(BuffSettingsWindow.settings.iconSize * BuffSettingsWindow.settings.maxBuffsShown + (BuffSettingsWindow.settings.maxBuffsShown - 1) * BuffSettingsWindow.settings.iconSpacing, BuffSettingsWindow.settings.iconSize)
    playerBuffCanvas:Show(false)
    playerBuffCanvas:Clickable(false)
    
    targetBuffCanvas = api.Interface:CreateEmptyWindow("targetBuffCanvas")
    targetBuffCanvas:SetExtent(BuffSettingsWindow.settings.iconSize * BuffSettingsWindow.settings.maxBuffsShown + (BuffSettingsWindow.settings.maxBuffsShown - 1) * BuffSettingsWindow.settings.iconSpacing, BuffSettingsWindow.settings.iconSize)
    targetBuffCanvas:Show(false)
    targetBuffCanvas:Clickable(false)
    
    -- Create buff canvases
    for i = 1, BuffSettingsWindow.MAX_BUFFS_COUNT do
        playerBuffIcons[i], playerBuffLabels[i], playerBuffStackLabels[i] = CreateBuffElement(i, playerBuffCanvas)
        targetBuffIcons[i], targetBuffLabels[i], targetBuffStackLabels[i] = CreateBuffElement(i, targetBuffCanvas)
    end
    
    api.On("UPDATE", OnUpdate)
    api.On("CHAT_MESSAGE", HandleChatCommand)
    api.On("TTP_NEW_BUFF_LOGGED", OnNewBuffLogged)
    api.On("TTP_BUFFS_LOGGING_STARTED", OnBuffsLoggingStarted)
    api.On("TTP_BUFFS_LOGGING_STOPPED", OnBuffsLoggingStopped)

    -- Toggle settings window visibility
    openSettingsBtn = helpers.createOverlayButton("TrackThatPls", BuffSettingsWindow.settings.btnSettingsPos,
        function ()
          local PosX, PosY = openSettingsBtn:GetOffset()
          BuffSettingsWindow.settings.btnSettingsPos = { PosX, PosY }
          BuffSettingsWindow.SaveSettings()
        end
    )
    openSettingsBtn:SetHandler("OnClick", function()
        BuffSettingsWindow.ToggleBuffSelectionWindow()
    end)
    -- Create icon for button
    local _w, buttonHeight = openSettingsBtn:GetExtent()
    buttonHeight = math.floor(buttonHeight * 0.70)
    local settingsIconDrawable = openSettingsBtn:CreateImageDrawable("Textures/Defaults/White.dds", "overlay")
    settingsIconDrawable:SetExtent(buttonHeight, buttonHeight)
    settingsIconDrawable:AddAnchor("RIGHT", openSettingsBtn, "LEFT", -3, 0)
    settingsIconDrawable:SetSRGB(false)
    settingsIconDrawable:SetVisible(false)
    settingsIconDrawable:SetTgaTexture(stopReccordingIconPath)
    openSettingsBtn.recordingIndicationIcon = settingsIconDrawable
    
    
    BuffSettingsWindow.RefreshLoggedBuffs()

    api.Log:Info("TrackThatPlease had been loaded. Type - ttp - in chat to access the TrackList \n or use the Button from UI")
end

-- Unload function to clean up
local function OnUnload()
    -- Disconnect event handlers to prevent memory leaks
    api.On("UPDATE", function() end)
    api.On("CHAT_MESSAGE", function() end)

    -- Cleanup BuffWatchWindow first (saves settings)
    if BuffSettingsWindow and BuffSettingsWindow.Cleanup then
        BuffSettingsWindow.Cleanup()
        BuffSettingsWindow = nil
    end

    -- Clean up settings button
    if openSettingsBtn then
        openSettingsBtn:Show(false)
        openSettingsBtn = nil
    end

    -- Clean up player buff UI elements
    if playerBuffCanvas then
        playerBuffCanvas:Show(false)
        playerBuffCanvas = nil
    end
    
    -- Clean up target buff UI elements
    if targetBuffCanvas then
        targetBuffCanvas:Show(false)
        targetBuffCanvas = nil
    end

    api.Log:Err("TrackThatPlease: Unload completed successfully")
end

TargetBuffTrackerAddon.OnLoad = OnLoad
TargetBuffTrackerAddon.OnUnload = OnUnload

return TargetBuffTrackerAddon