-- GLOBALS
-- These are all provided in the environment you'll be using.
ADDON = {
    -- Use this to get any of the windows defined in UIC below!
    -- GetContent(UIC)
    GetContent = {},
    -- RegisterContentWidget(UIC, widget)
    RegisterContentWidget = {},
    -- ShowContent(UIC, show (boolean))
    ShowContent = {},
    -- RegisterContentTriggerFunc(UIC, ToggleFunction)
    -- Calls ToggleFunction with true/false when ShowContent is called.
    RegisterContentTriggerFunc = {}
}
UIC = {
    DEV_WINDOW = 0,
    ABILITY_CHANGE = 0,
    CHARACTER_INFO = 0,
    AUTH_MSG_WND = 0,
    BUBBLE_ACTION_BAR = 0,
    BAG = 0,
    DEATH_AND_RESURRECTION_WND = 0,
    OPTION_FRAME = 0,
    SYSTEM_CONFIG_FRAME = 0,
    GAME_EXIT_FRAME = 0,
    SLAVE_EQUIPMENT = 0,
    PLAYER_UNITFRAME = 0,
    TARGET_UNITFRAME = 0,
    RAID_COMMAND_MESSAGE = 0,
    COMBAT_TEXT_FRAME = 0,
    TARGET_OF_TARGET_FRAME = 0,
    WATCH_TARGET_FRAME = 0,FONT_SIZE
    RAID_MANAGER = 0,
    COMMUNITY_WINDOW = 0,
    ENCHANT_WINDOW = 0
  }
BUTTON_BASIC = BUTTON_BASIC
CURSOR_PATH = CURSOR_PATH
FONT_COLOR = FONT_COLOR
FONT_SIZE = FONT_SIZE
TEXTURE_PATH = TEXTURE_PATH
F_SLOT = F_SLOT
SLOT_STYLE = {
  DEFAULT = {},
  BAG_DEFAULT = {},
  SOCKET = {},
  BAG_NOT_ALL_TAB = {},
  BUFF = {},
  EQUIP_ITEM = {},
  PET_ITEM = {},
  SLAVE_EQUIP = {
    FIGUREHEAD = {},
    STAY_SAIL = {},
    SQUARE_SAIL = {},
    FRONT_MAST = {},
    REAR_MAST = {},
    CANNON = {},
    BACKPACK = {},
    BOARD = {},
    HANDLE = {},
    RUDDER = {},
    LAMP = {},
    BELL = {},
    ORGAN = {},
    CARRIED_HARPOON = {},
    HARPOON = {},
    TELESCOPE = {},
    SCUBA = {},
    ENGINE = {},
    DECORATION = {},
    WATERWHEEL = {}
  }
}
COMBAT_TEXT_COLOR = {}
ConvertColor = {}
ApplyTextColor = {}
ApplyButtonSkin = {}
X2Util = {
    GetMyMoneyString = {},
    -- Takes x,y,z and returns screenX, screenY and distance
    -- Negative distance means the coordinate is off screen
    ConvertWorldToScreen = {}
}
CreateItemIconButton = {}
combatTextLocale = {}
ParseCombatMessage = {}
GetTextureInfo = {}
ALIGN = {
  LEFT = 0,
  RIGHT = 0,
  CENTER = 0,
  TOP = 0,
  BOTTOM = 0,
  BOTTOM_RIGHT = 0,
  BOTTOM_LEFT = 0,
  TOP_LEFT = 0,
  TOP_RIGHT = 0
}
W_MONEY = {
    -- CreateMoneyEditsWindow(id, parent, titleText)
    CreateMoneyEditsWindow = {},
    -- CreateTwoLineMoneyWindow(id, parent)
    CreateTwoLineMoneyWindow = {},
    -- CreateDefaultMoneyWindow(id, parent, width, height)
    CreateDefaultMoneyWindow = {},
    -- CreateTitleMoneyWindow(id, parent, titleText, direction, layoutType)
    CreateTitleMoneyWindow = {},
}
W_CTRL = {
    -- CreateComboBox(parent)
    CreateComboBox = {},
    -- CreateEdit(id, parent)
    CreateEdit = {},
    -- CreditMultiLineEdit(id, parent)
    CreditMultiLineEdit = {},
    -- CreateLabel(id, parent)
    CreateLabel = {},
    -- CreateList(id, parent) 
    CreateList = {},
    -- CreateListCtrl(id, parent)
    CreateListCtrl = {},
    -- CreatePageControl(id, parent, style)
    CreatePageControl = {},
    -- CreatePageScrollListCtrl(id, parent)
    CreatePageScrollListCtrl = {},
    -- CreateScroll(id, parent)
    CreateScroll = {},
    -- CreateScrollListBox(id, parent, bgType)
    CreateScrollListBox = {},
    -- CreateScrollListCtrl(id, parent, index)
    CreateScrollListCtrl = {},
}
W_UNIT = {
    -- CreateBuffWindow(id, parent, maxCount, isBuff, isRaidMember)
    CreateBuffWindow = {},
    -- CreateLevelLabel(id, parent, useLevelTexture)
    CreateLevelLabel = {},
}
W_BAR = {
    --CreateCastingBar(id, parent, unit)
    CreateCastingBar = {},
    --CreateDoubleGauge(id, parent)
    CreateDoubleGauge = {},
    --CreateExpBar(id, parent)
    CreateExpBar = {},
    --CreateLaborPowerBar(id, parent)
    CreateLaborPowerBar = {},
    --CreateHpBar(id, parent)
    CreateHpBar = {},
    --CreateSkillBar(id, parent)
    CreateSkillBar = {},
    --CreateStatusBarOfUnitFrame(id, parent, barType)
    CreateStatusBarOfUnitFrame = {},
    --CreateStatusBarOfRaidFrame(id, parent, barType)
    CreateStatusBarOfRaidFrame = {},
    --CreateStatusBar(id, parent, style)
    CreateStatusBar = {},
}
W_ICON = {
    -- CreateDestroyIcon(widget, layer)
    CreateDestroyIcon = {},
    -- CreatePackIcon(widget, layer)
    CreatePackIcon = {},
    -- CreateLifeTimeIcon(widget, layer)
    CreateLifeTimeIcon = {},
    -- CreateLookIcon(widget, layer)
    CreateLookIcon = {},
    -- CreateLockIcon(widget, layer)
    CreateLockIcon = {},
    -- CreateDyeingIcon(widget, layer)
    CreateDyeingIcon = {},
    -- CreateStack(widget)
    CreateStack = {},
    -- CreateLimitLevel(widget)
    CreateLimitLevel = {},
    -- CreateOverlayStateImg(widget, layer)
    CreateOverlayStateImg = {},
    -- CreateOpenPaperItemIcon(widget, layer)
    CreateOpenPaperItemIcon = {},
    -- CreatePartyIconWidget(widget)
    CreatePartyIconWidget = {},
    -- CreateLootIconWidget(widget)
    CreateLootIconWidget = {},
    -- CreateGuideIconWidget(widget)
    CreateGuideIconWidget = {},
    -- CreateItemIconImage(id, parent)
    CreateItemIconImage = {},
    -- CreateAchievementGradeIcon(widget)
    CreateAchievementGradeIcon = {},
    -- CreateQuestGradeMarker(parent)
    CreateQuestGradeMarker = {},
    -- DrawRoundDingbat(widget)
    DrawRoundDingbat = {},
    -- DrawMoneyIcon(parent, arg)
    DrawMoneyIcon = {},
    -- DrawSkillFlameIcon(widget, layer)
    DrawSkillFlameIcon = {},
    -- DrawItemSideEffectBackground(widget)
    DrawItemSideEffectBackground = {},
    -- CreateArrowIcon(widget, layer)
    CreateArrowIcon = {},
    -- DrawMinusDingbat(money_window_widget)
    DrawMinusDingbat = {},
    -- CreateLeaderMark(id, parent)
    CreateLeaderMark = {}
}
EQUIP_SLOT = {
    HEAD = 0,
    NECK = 0,
    CHEST = 0,
    WAIST = 0,
    LEGS = 0,
    HANDS = 0,
    FEET = 0,
    ARMS = 0,
    BACK = 0,
    EAR_1 = 0,
    EAR_2 = 0,
    FINGER_1 = 0,
    FINGER_2 = 0,
    UNDERSHIRT = 0,
    UNDERPANTS = 0,
    MAINHAND = 0,
    OFFHAND = 0,
    RANGED = 0,
    MUSICAL = 0,
    BACKPACK = 0,
    COSPLAY = 0,
}

-- API
ADDON_API = {
	File = {},
	Unit = {},
	Team = {},
	Log = {},
	Interface = {},
	Cursor = {},
	Input = {},
	Time = {},
	Player = {},
    Bag = {},
    Ability = {},
    Item = {},
    Skill = {},
    Store = {},
    Bank = {},
    Equipment = {},
    SiegeWeapon = {},
	-- This is the 'addons' directory at runtime
	baseDir = "",
	rootWindow = {},
  timers = {}
}


-- ======
-- Logging
-- ======

-- Logs a message to chat in YELLOW
function ADDON_API.Log:Info(message)
end

-- Logs a message to chat in RED
function ADDON_API.Log:Err(message)
end


-- ======
-- File Handling
-- ====== 

--[[
    Serializes a table and writes it to the desired path.
    Paths are relative to the addons folder
]]
function ADDON_API.File:Write(path, tbl)
end

--[[
    Reads the file located at path and deserializes it into a table.
    Paths are relative to the addons folder
]]
function ADDON_API.File:Read(path)
end

--[[
    Get the settings for the desired addonId
    addonId is the name of the folder the addon is stored in, for example 'example_addon'
]]
function ADDON_API.GetSettings(addonId) 
end

--[[
    Saves all addon settings. Do not call too often.
]]
function ADDON_API.SaveSettings()
end

-- ======
-- Interface
-- ======

--[[
    Creates a standard looking window. If size is not specified, it will default to 680x615
    Tabs can be used to define tabs on the window by default.
]]
function ADDON_API.Interface:CreateWindow(id, title, x, y, tabs)
end

--[[
    Creates an empty window, that does not render anything.
    Particularily useful to draw things on the HUD
]]
function ADDON_API.Interface:CreateEmptyWindow(id)
end

--[[
    Creates a Widget bound to parent.
    Types: button, label, window, slot, checkbutton, window, textbox, message, gametooltip
]]
function ADDON_API.Interface:CreateWidget(type, id, parent)
end

--[[
    Creates a status bar
]]
function ADDON_API.Interface:CreateStatusBar(name, parent, type)
end

--[[
    Creates a Combo Box (like the grade selector in the equipment folio)
    Use the dropdownItem member to set the contentsi
]]
function ADDON_API.Interface:CreateComboBox(window)
end

--[[
    Applies a skin to a button 
    Possible values are BUTTON_BASIC.{DEFAULT, RESET, BASIC} and more (to define...)
]]
function ADDON_API.Interface:ApplyButtonSkin(btn, skin)
end

--[[
    Sets tooltip at coordinates
]]
function ADDON_API.Interface:SetTooltipOnPos(text, target, posX, posY)
end

-- ======
-- Unit
-- ======
--[[
    Returns a unit's (player, npc, pet..) name by its ID
]]
function ADDON_API.Unit:GetUnitNameById(id)
end

--[[
    Returns a unit's information by its ID
]]
function ADDON_API.Unit:GetUnitInfoById(id)
end

--[[ 
    Note: "unit" in the below functions can be: 
    - player
    - target
    - targettarget
    - team1 through team50
    - playerpet1 or playerpet2
]]

--[[
    Get the screen coordinates of the desired unit. This can be used to overlay UI elements and "track" units.
]]
function ADDON_API.Unit:GetUnitScreenPosition(unit)
end

--[[
    Returns the distance between the desired unit and the player, in meters
]]
function ADDON_API.Unit:UnitDistance(unit)
end

--[[
    Returns the unit ID for the desired unit. The ID can then be passed to GetUnitNameById and GetUnitInfoById
]]
function ADDON_API.Unit:GetUnitId(unit)
end

--[[
    Returns the number of buffs a unit has
]]
function ADDON_API.Unit:UnitBuffCount(unit)
end

--[[
    Returns the buff at index for a unit. Nil if no buff is found
]]
function ADDON_API.Unit:UnitBuff(unit, index)
end

--[[
    Returns the unit world coordinates of the desired unit as x,y,z
]]
function ADDON_API.Unit:UnitWorldPosition(unit)
end

-- Same as buff
function ADDON_API.Unit:UnitDeBuffCount(unit)
end

-- Same as buff
function ADDON_API.Unit:UnitDeBuff(unit, index)
end

-- Self explanatory
function ADDON_API.Unit:UnitHealth(unit)
end

-- Self explanatory
function ADDON_API.Unit:UnitMaxHealth(unit)
end

-- Self explanatory
function ADDON_API.Unit:UnitMana(unit)
end

-- Self explanatory
function ADDON_API.Unit:UnitMaxMana(unit)
end

--[[
    Returns information about a unit. (todo fill api docs...)
]]
function ADDON_API.Unit:UnitInfo(unit)
end

function ADDON_API.Unit:UnitModifierInfo(unit)
end

function ADDON_API.Unit:UnitClass(unit)
end

function ADDON_API.Unit:UnitGearScore(unit)
end

function ADDON_API.Unit:UnitTeamAuthority(unit)
end

function ADDON_API.Unit:UnitIsTeamMember(unit)
end

function ADDON_API.Unit:UnitIsForceAttack(unit)
end

function ADDON_API.Unit:GetFactionName(unit)
end

function ADDON_API.Unit:GetUnitScreenNameTagOffset(unit)
end

--[[
    Returns a table {currentAbyssalCharge, maxAbyssalCharge, show}
]]
function ADDON_API.Unit:GetHighAbilityRscInfo()
end
-- ======
-- Team
-- ======
--[[
    Invites the desired player to raid/party

    If party is true and the player is not in party/raid, a party will be created. Otherwise, a raid
]]
function ADDON_API.Team:InviteToTeam(name, party)
end 

--[[
    Sets the player's role within the party
    0 = Blue
]]
function ADDON_API.Team:SetRole(role)
end

function ADDON_API.Team:IsPartyTeam()
end

function ADDON_API.Team:IsPartyRaid()
end

function ADDON_API.Team:GetMemberIndexByName(playerName)
end

-- ======
-- Bag
-- ======
--[[
    Equips the item at the bag slot specified
]]
function ADDON_API.Bag:EquipBagItem(bagSlot, isAux)
end

--[[
    @function GetBagItemInfo
    @desc Get item information at the index, in the bag specified. 1 = Inventory 
]]
function ADDON_API.Bag:GetBagItemInfo(bagType, index)
end

function ADDON_API.Bag:CountItems()
end

function ADDON_API.Bag:Capacity()
end

function ADDON_API.Bag:CountBagItemByItemType(type)
end

function ADDON_API.Bag:GetCurrency()
end

-- ======
-- Cursor
-- ======
function ADDON_API.Cursor:ClearCursor()
end

function ADDON_API.Cursor:SetCursorImage(image, x, y)
end

-- ======
-- Time
-- ======
-- Returns milliseconds since the game started
function ADDON_API.Time:GetUiMsec()
end

function ADDON_API.Time:GetLocalTime()
end

function ADDON_API.Time:PeriodTimeToDate(localTime, period)
end
-- ======
-- Input
-- ======
function ADDON_API.Input:IsShiftKeyDown()
end


-- ======
-- Player
-- ======

--[[
    @function ChangeAppellation
    @desc Changes the player's title
    @param type (number) The ID of the title to set
    @returns (nil|true) 
]]
function ADDON_API.Player:ChangeAppellation(type)
end

-- ======
-- Events & Timers
-- ======

--[[
    Binds callback to the desired event

    Current events:
    - UPDATE (dt) - Called every frame, with dt = time in msec since last frame
    - CHAT_MESSAGE
    - TEAM_MEMBERS_CHANGED
    - UI_RELOADED
    - UPDATE_PING_INFO - Called when the map ping is moved
]]
function ADDON_API.On(event, callback)
end

--[[
    Registers a callback to be executed in a certain duration (in msec)
    If you need to call this often, consider using On("UPDATE") instead
]]
function ADDON_API:DoIn(msec, callback)
end

--[[
    Emits an event. We recommend using event names like "ADDON_MY_EVENT" so that other addons don't get tripped.
]]
function ADDON_API:Emit(event, ...)
end

-- ======
-- Ability
-- The Ability module is everything Buffs
-- ======

function ADDON_API.Ability:GetBuffTooltip(buffId, itemLevel)
end

-- ======
-- Item
-- ======

function ADDON_API.Item:GetItemInfoByType(itemId)
end

-- ======
-- Skill
-- ======
function ADDON_API.Skill:GetSkillTooltip(skillId)
end

-- ======
-- Store
-- ======

-- Returns the Seller % on packs. Usually 80%, it futureproofs your addon if it changes.
function ADDON_API.Store:GetSellerShareRatio()
end

function ADDON_API.Store:GetSpecialtyRatio()
end

function ADDON_API.Store:GetProductionZoneGroups()
end

function ADDON_API.Store:GetSellableZoneGroups(startZoneId)
end

function ADDON_API.Store:GetSpecialtyRatioBetween(startZoneId, finishZoneId)
end

-- ======
-- Bank
-- ======
function ADDON_API.Bank:CountItems()
end

function ADDON_API.Bank:Capacity()
end

function ADDON_API.Bank:GetCurrency()
end

function ADDON_API.Bank:GetLinkText(inventorySlotId)
end

-- ======
-- Equipment
-- ======

function ADDON_API.Equipment:GetEquippedItemInfo(slotIdx)
end

--- ======
--- SiegeWeapon
--- ======

function ADDON_API.SiegeWeapon:GetSiegeWeaponSpeed()
end

function ADDON_API.SiegeWeapon:GetSiegeWeaponTurnSpeed()
end

return ADDON_API