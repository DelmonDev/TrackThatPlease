local api = require("api")
local BuffWatchWindow = require("TrackThatPlease/buffwatchwindow")

-- Addon Information
local TargetBuffTrackerAddon = {
    name = "TrackThatPlease",
    author = "Dehling",
    version = "1.0",
    desc = "Tracks buffs/debuffs on target, with UI"
}

--FORK Option by @Fortuno for colored buff debuff borders
--FORK Idea by @mykeew to implement targeting for Target and Self (Player), now properly implemented
--
-- UI Elements
local playerBuffCanvas
local targetBuffCanvas
local MAX_BUFFS_SHOWN = 5
local playerBuffIcons = {}
local playerBuffLabels = {}
local targetBuffIcons = {}
local targetBuffLabels = {}

-- Variables
local previousXYZ = "0,0,0"
local previousTarget

-- THIS RIGHT HERE ARE THE SETTINGS, 
local settings = {
    ShowTimers = true,
    IconSize = 25,
    IconSpacing = 3,
    UISize = 100, -- 80, 90 ,100, 110, 120
    RecolorIconBorders = true,  -- New setting for toggling icon border recoloring
    TargetBuffVerticalOffset = -35  -- New setting for target buff vertical offset
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
-- Function to check if a buff is being watched for player or target
local function IsWatchedBuff(buffId, isPlayer)
    buffId = math.floor(tonumber(buffId) or 0)
    if isPlayer then
        return BuffWatchWindow.IsPlayerBuffWatched(buffId)
    else
        return BuffWatchWindow.IsTargetBuffWatched(buffId)
    end
end

-- Function to create buff icon and label
local function CreateBuffElement(index, canvas)
    local icon = CreateItemIconButton("buffIcon" .. index, canvas)
    icon:Clickable(false)
    icon:SetExtent(settings.IconSize, settings.IconSize)
    icon:Show(false)
    F_SLOT.ApplySlotSkin(icon, icon.back, SLOT_STYLE.DEFAULT)

    local label
    if settings.ShowTimers then
        label = canvas:CreateChildWidget("label", "buffTimeLeftLabel" .. index, 0, true)
        label:SetText("")
        label:AddAnchor("CENTER", icon, "CENTER", 0, 0)
        label.style:SetFontSize(12)
        label.style:SetAlign(ALIGN.CENTER)
        label.style:SetShadow(true)
        label:Show(false)
    end

    return icon, label
end

-- Function to position buffs with whole bar centered
local function PositionBuffs(watchedBuffs, canvas, icons, labels)
    local totalWidth = #watchedBuffs * settings.IconSize + (#watchedBuffs - 1) * settings.IconSpacing
    local startX = -totalWidth / 2 + settings.IconSize / 2
    
    for i = 1, #watchedBuffs do
        local icon = icons[i]
        local offsetX = startX + (i - 1) * (settings.IconSize + settings.IconSpacing)
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
    return adjustments[settings.UISize] or { x = 0, y = 0 }
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
    for i = 1, MAX_BUFFS_SHOWN do
        if playerBuffIcons[i] then
            playerBuffIcons[i]:Show(false)
        end
        if playerBuffLabels[i] then
            playerBuffLabels[i]:Show(false)
        end
        if targetBuffIcons[i] then
            targetBuffIcons[i]:Show(false)
        end
        if targetBuffLabels[i] then
            targetBuffLabels[i]:Show(false)
        end
    end
end

-- Update event to handle buff/debuff updates
local function OnUpdate()
    -- Clear all buffs before updating
    ClearAllBuffs()

    -- [NEW CODE START] Check if player is targeting themselves
    local playerUnitId = api.Unit:GetUnitId("player")
    local targetUnitId = api.Unit:GetUnitId("target")
    local isSelfTarget = (playerUnitId == targetUnitId)
    -- [NEW CODE END]

    -- Collect all watched buffs and debuffs
    local playerBuffs, targetBuffs = CollectWatchedBuffsAndDebuffs()

    -- Update position and show player buffs/debuffs
    if #playerBuffs > 0 then
        PositionBuffs(playerBuffs, playerBuffCanvas, playerBuffIcons, playerBuffLabels)

        for i = 1, math.min(#playerBuffs, MAX_BUFFS_SHOWN) do
            local buff = playerBuffs[i]
            local icon = playerBuffIcons[i]
            local label = playerBuffLabels[i]

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
                    label:SetText(string.format("%.1f", (buff.timeLeft / 1000)))
                else
                    label:SetText("")
                end
                label:Show(true)
            end
        end

        -- Hide unused buff slots
        for i = #playerBuffs + 1, MAX_BUFFS_SHOWN do
            playerBuffIcons[i]:Show(false)
            if playerBuffLabels[i] then playerBuffLabels[i]:Show(false) end
        end

        -- Update canvas position with UI scale adjustment
        local x, y, z = api.Unit:GetUnitScreenPosition("player")
        if previousXYZ ~= (x .. "," .. y .. "," .. z) then
            local adjustment = GetPositionAdjustment()
            local baseOffsetY = -35  -- Base vertical offset
            playerBuffCanvas:RemoveAllAnchors()
            playerBuffCanvas:AddAnchor("BOTTOM", "UIParent", "TOPLEFT", x + adjustment.x, y + baseOffsetY + adjustment.y)
            previousXYZ = x .. "," .. y .. "," .. z
        end

        playerBuffCanvas:Show(z >= 0 and z <= 100)
    else
        playerBuffCanvas:Show(false)
    end

    -- [MODIFIED CODE START] Update position and show target buffs/debuffs (only if not self-targeting)
    if not isSelfTarget and #targetBuffs > 0 then
    -- [MODIFIED CODE END]
        PositionBuffs(targetBuffs, targetBuffCanvas, targetBuffIcons, targetBuffLabels)

        for i = 1, math.min(#targetBuffs, MAX_BUFFS_SHOWN) do
            local buff = targetBuffs[i]
            local icon = targetBuffIcons[i]
            local label = targetBuffLabels[i]

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
                    label:SetText(string.format("%.1f", (buff.timeLeft / 1000)))
                else
                    label:SetText("")
                end
                label:Show(true)
            end
        end

        -- Hide unused buff slots
        for i = #targetBuffs + 1, MAX_BUFFS_SHOWN do
            targetBuffIcons[i]:Show(false)
            if targetBuffLabels[i] then targetBuffLabels[i]:Show(false) end
        end

        -- Update canvas position with UI scale adjustment
        local x, y, z = api.Unit:GetUnitScreenPosition("target")
        if previousTarget ~= (x .. "," .. y .. "," .. z) then
            local adjustment = GetPositionAdjustment()
            local baseOffsetY = settings.TargetBuffVerticalOffset  -- Use the new setting for target buff vertical offset
            targetBuffCanvas:RemoveAllAnchors()
            targetBuffCanvas:AddAnchor("BOTTOM", "UIParent", "TOPLEFT", x + adjustment.x, y + baseOffsetY + adjustment.y)
            previousTarget = x .. "," .. y .. "," .. z
        end

        targetBuffCanvas:Show(z >= 0 and z <= 100)
    else
        targetBuffCanvas:Show(false)
    end
end

local function HandleChatCommand(channel, unit, isHostile, name, message, speakerInChatBound, specifyName, factionName, trialPosition)
    local playerName = api.Unit:GetUnitNameById(api.Unit:GetUnitId("player"))
    if playerName == name and message == "ttp" then
        BuffWatchWindow.ToggleBuffSelectionWindow()
    end
end

-- Load function to initialize the UI elements
local function OnLoad()
    api.Log:Info("TrackThatPlease had been loaded. Type - ttp - in chat to access the TrackList")
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

    playerBuffCanvas = api.Interface:CreateEmptyWindow("playerBuffCanvas")
    playerBuffCanvas:SetExtent(settings.IconSize * MAX_BUFFS_SHOWN + (MAX_BUFFS_SHOWN - 1) * settings.IconSpacing, settings.IconSize)
    playerBuffCanvas:Show(false)
    playerBuffCanvas:Clickable(false)

    targetBuffCanvas = api.Interface:CreateEmptyWindow("targetBuffCanvas")
    targetBuffCanvas:SetExtent(settings.IconSize * MAX_BUFFS_SHOWN + (MAX_BUFFS_SHOWN - 1) * settings.IconSpacing, settings.IconSize)
    targetBuffCanvas:Show(false)
    targetBuffCanvas:Clickable(false)

    for i = 1, MAX_BUFFS_SHOWN do
        playerBuffIcons[i], playerBuffLabels[i] = CreateBuffElement(i, playerBuffCanvas)
        targetBuffIcons[i], targetBuffLabels[i] = CreateBuffElement(i, targetBuffCanvas)
    end

    api.On("UPDATE", OnUpdate)
    api.On("CHAT_MESSAGE", HandleChatCommand)

    BuffWatchWindow.Initialize(settings)
end

-- Unload function to clean up
local function OnUnload()
    -- Clear all buffs before unloading
    ClearAllBuffs()

    if buffTrackerCanvas ~= nil then
        buffTrackerCanvas:Show(false)
        buffTrackerCanvas = nil
    end
    BuffWatchWindow.Cleanup()
    api.SaveSettings()
end

TargetBuffTrackerAddon.OnLoad = OnLoad
TargetBuffTrackerAddon.OnUnload = OnUnload

return TargetBuffTrackerAddon