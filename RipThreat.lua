local RT = LibStub("AceAddon-3.0"):NewAddon("RipThreat", "AceConsole-3.0", "AceEvent-3.0")
local LSM = LibStub("LibSharedMedia-3.0", true)
local hasLSM = LSM ~= nil

-- Constants
local SOUND_ID = 543 -- "None Shall Pass" sound (you can change this to any game sound ID you prefer)
local TEST_MODE = false -- Set to true to test on any mob
local DEBUG_MODE = false -- Set to true to enable debug messages
local HEALTH_THRESHOLD = 10 -- Health multiplier for boss detection
local CHECK_THRESHOLD = 0.5 -- Time between checks for the same unit (in seconds)
local ALERT_COOLDOWN = 5.0 -- Minimum time between alerts for the same unit (in seconds)

-- Default settings
local defaults = {
    profile = {
        sound = "None Shall Pass",
        font = "Friz Quadrata TT",
        position = {
            x = 0,
            y = 100,
        },
        fontSize = 24,
        historyPosition = {
            x = 0,
            y = -100,
        },
        historyFontSize = 18,
        historyAlpha = 0,
        historyScale = 1.0,
        historyTimeVisible = 5.0,
        historyMaxLines = 10,
        customText = {
            noTaunt = "LOST THREAT - NO TAUNT!",
            tauntFormat = "Taunted by %s (%s)"
        },
        tankOnlyAlerts = true -- New setting for tank-only alerts
    }
}

-- Create the alert frame
local alertFrame = CreateFrame("Frame", "RipThreatAlertFrame", UIParent)
alertFrame:SetSize(800, 60)
alertFrame:SetFrameStrata("HIGH")

local alertText = alertFrame:CreateFontString(nil, "OVERLAY")
alertText:SetFont("Fonts\\FRIZQT__.TTF", defaults.profile.fontSize, "OUTLINE")
alertText:SetPoint("CENTER", alertFrame, "CENTER")
alertText:SetTextColor(1, 0, 0) -- Red color for no-taunt warnings
alertText:SetText("")

-- Create the history frame
local historyFrame = CreateFrame("Frame", "RipThreatHistoryFrame", UIParent)
historyFrame:SetSize(400, 200)
historyFrame:SetFrameStrata("BACKGROUND")
historyFrame:SetPoint("CENTER", UIParent, "CENTER", defaults.profile.historyPosition.x, defaults.profile.historyPosition.y)
historyFrame:SetScale(defaults.profile.historyScale)

-- Add a background to the history frame
historyFrame.bg = historyFrame:CreateTexture(nil, "BACKGROUND")
historyFrame.bg:SetAllPoints()
historyFrame.bg:SetColorTexture(0, 0, 0, defaults.profile.historyAlpha)

-- Create a scrolling message frame for the history
local historyMessages = CreateFrame("ScrollingMessageFrame", nil, historyFrame)
historyMessages:SetPoint("TOPLEFT", 5, -5)
historyMessages:SetPoint("BOTTOMRIGHT", -5, 5)
historyMessages:SetFontObject(GameFontNormal)
historyMessages:SetTextColor(1, 1, 1)
historyMessages:SetJustifyH("LEFT")
historyMessages:SetFading(true)
historyMessages:SetFadeDuration(1.0)
historyMessages:SetTimeVisible(defaults.profile.historyTimeVisible)
historyMessages:SetMaxLines(defaults.profile.historyMaxLines)
historyMessages:SetInsertMode("BOTTOM")

-- Add this near the top with other locals
local tankCache = {}
local lastCheckedUnit = nil
local lastCheckedTime = 0
local isInInstance = false -- Track if player is in an instance
local isInCombat = false -- Track if player is in combat
local bossCache = {} -- Cache boss status to avoid repeated checks
local lastAlertTime = {} -- Track when we last alerted for each unit

-- Table of all tank taunt spell IDs with their names
local TAUNT_DEBUFFS = {
    [355] = "Taunt",           -- Warrior
    [56222] = "Dark Command",  -- Death Knight
    [49576] = "Death Grip",    -- Death Knight
    [6795] = "Growl",         -- Druid
    [185245] = "Torment",      -- Demon Hunter
    [116189] = "Provoke",      -- Monk
    [62124] = "Hand of Reckoning", -- Paladin
    [17735] = "Suffering",     -- Warlock Voidwalker
    [20736] = "Distracting Shot", -- Hunter
    [281854] = "Torment",      -- Warlock Felguard
    [2649] = "Growl"         -- Hunter Pet
}

-- Cache for taunt info to avoid repeated aura scans
local tauntCache = {}
local tauntCacheTime = {}
local TAUNT_CACHE_DURATION = 0.5 -- How long to cache taunt info (in seconds)

-- Function to update frame position from saved variables
local function UpdateFramePosition()
    local x = RT.db.profile.position.x
    local y = RT.db.profile.position.y
    alertFrame:ClearAllPoints()
    alertFrame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    
    local hx = RT.db.profile.historyPosition.x
    local hy = RT.db.profile.historyPosition.y
    historyFrame:ClearAllPoints()
    historyFrame:SetPoint("CENTER", UIParent, "CENTER", hx, hy)
end

-- Function to update font from saved variables
local function UpdateFont()
    local fontPath = "Fonts\\FRIZQT__.TTF"
    if hasLSM then
        fontPath = LSM:Fetch("font", RT.db.profile.font)
    end
    alertText:SetFont(fontPath, RT.db.profile.fontSize, "OUTLINE")
    historyMessages:SetFont(fontPath, RT.db.profile.historyFontSize, "OUTLINE")
end

-- Function to update history frame settings
local function UpdateHistoryFrame()
    historyFrame:SetScale(RT.db.profile.historyScale)
    historyFrame.bg:SetColorTexture(0, 0, 0, RT.db.profile.historyAlpha)
    historyMessages:SetTimeVisible(RT.db.profile.historyTimeVisible)
    historyMessages:SetMaxLines(RT.db.profile.historyMaxLines)
    UpdateFont()
end

-- Function to add a message to the history
local function AddToHistory(text, color)
    if not color then color = {r = 1, g = 1, b = 1} end
    historyMessages:AddMessage(text, color.r, color.g, color.b)
end

-- Function to show alert text
local function ShowAlertText(text, isWarning)
    alertText:SetText(text)
    alertText:SetTextColor(isWarning and 1 or 1, isWarning and 0 or 1, 0) -- Red for warnings, Yellow for info
    
    -- Clear any existing fade animation
    if alertFrame.fadeTimer then
        alertFrame.fadeTimer:Cancel()
    end
    
    -- Show the frame
    alertFrame:SetAlpha(1)
    alertFrame:Show()
    
    -- Play sound if it's a warning
    if isWarning then
        if hasLSM then
            local soundFile = LSM:Fetch("sound", RT.db.profile.sound)
            if soundFile then
                PlaySoundFile(soundFile, "Master")
            end
        else
            PlaySound(SOUND_ID, "Master")
        end
    end
    
    -- Set up fade out
    alertFrame.fadeTimer = C_Timer.NewTimer(3, function()
        local fadeInfo = {
            mode = "OUT",
            timeToFade = 0.5,
            finishedFunc = function()
                alertFrame:Hide()
            end,
        }
        UIFrameFade(alertFrame, fadeInfo)
    end)
end

-- Function to check if unit has any taunt debuff and return taunt info
local function GetTauntInfo(unit)
    if not unit then return nil end
    
    -- Check cache first
    local guid = UnitGUID(unit)
    if guid then
        local currentTime = GetTime()
        if tauntCache[guid] and (currentTime - tauntCacheTime[guid]) < TAUNT_CACHE_DURATION then
            return tauntCache[guid]
        end
    end
    
    local foundTaunt = nil
    AuraUtil.ForEachAura(unit, "HARMFUL", nil, function(name, icon, count, debuffType, duration, expirationTime, source, isStealable, nameplateShowPersonal, spellId)
        if TAUNT_DEBUFFS[spellId] then
            -- If we found a taunt, get source info
            local casterName = nil
            local className = ""
            local classColor = RAID_CLASS_COLORS["WARRIOR"]
            
            if source then
                if UnitIsPlayer(source) then
                    -- It's a player
                    casterName = UnitName(source)
                    className = select(2, UnitClass(source))
                    classColor = RAID_CLASS_COLORS[className]
                else
                    -- Try to get pet owner first
                    local owner = UnitOwner(source)
                    if owner then
                        -- It's a pet with an owner
                        local ownerName = UnitName(owner)
                        local petName = UnitName(source)
                        className = select(2, UnitClass(owner))
                        classColor = RAID_CLASS_COLORS[className]
                        casterName = string.format("%s's %s", ownerName, petName)
                    else
                        -- It's an NPC or pet without owner info
                        local sourceName = UnitName(source)
                        if sourceName then
                            -- Try to get the creature family name for pets
                            local family = UnitCreatureFamily(source)
                            if family then
                                casterName = string.format("%s (%s)", sourceName, family)
                            else
                                casterName = sourceName
                            end
                        end
                    end
                end
            end
            
            -- If we still don't have a name, use a generic one
            if not casterName then
                casterName = "Unknown Source"
            end
            
            local coloredName = string.format("|c%s%s|r", classColor.colorStr, casterName)
            
            foundTaunt = {
                caster = coloredName,
                ability = TAUNT_DEBUFFS[spellId]
            }
            
            -- Cache the result
            if guid then
                tauntCache[guid] = foundTaunt
                tauntCacheTime[guid] = GetTime()
            end
            
            return true -- Stop iteration
        end
    end)
    
    -- Cache negative results too
    if not foundTaunt and guid then
        tauntCache[guid] = nil
        tauntCacheTime[guid] = GetTime()
    end
    
    return foundTaunt
end

-- Function to check if unit is a raid boss
local function IsRaidBoss(unit)
    if TEST_MODE then return true end
    
    if not unit then return false end
    if not UnitExists(unit) then return false end
    
    -- Only check in instances
    if not isInInstance then return false end
    
    -- Check cache first
    local guid = UnitGUID(unit)
    if guid and bossCache[guid] ~= nil then
        return bossCache[guid]
    end
    
    -- Check classification and instance type
    local classification = UnitClassification(unit)
    local _, instanceType = IsInInstance()
    
    -- Check if unit is a boss by various methods
    local isBoss = false
    
    -- Method 1: Check unit classification
    if classification == "worldboss" or classification == "raidBoss" or classification == "boss" then
        isBoss = true
    end
    
    -- Method 2: Check if in instance and has boss flag
    if not isBoss and (instanceType == "raid" or instanceType == "party") and UnitLevel(unit) == -1 then
        isBoss = true
    end
    
    -- Method 3: Check unit health compared to player health (bosses have much more health)
    -- Only do this check if the other methods failed and we're in combat
    if not isBoss and isInCombat and classification == "elite" then
        if UnitHealthMax(unit) > UnitHealthMax("player") * HEALTH_THRESHOLD then
            isBoss = true
        end
    end
    
    if DEBUG_MODE then
        print("|cFFFF0000[RipThreat Debug]|r", UnitName(unit), "isBoss:", isBoss, "classification:", classification, "instanceType:", instanceType)
    end
    
    -- Cache the result if we have a GUID
    if guid then
        bossCache[guid] = isBoss
    end
    
    return isBoss
end

-- Table of tank specializations by class ID
local TANK_SPECS = {
    [1] = { -- Warrior
        [73] = true, -- Protection
    },
    [2] = { -- Paladin
        [66] = true, -- Protection
    },
    [6] = { -- Death Knight
        [250] = true, -- Blood
    },
    [10] = { -- Monk
        [268] = true, -- Brewmaster
    },
    [11] = { -- Druid
        [104] = true, -- Guardian
    },
    [12] = { -- Demon Hunter
        [581] = true, -- Vengeance
    },
}

-- Function to check if a unit is a tank - optimized version
local function IsUnitTank(unit)
    if not unit or not UnitExists(unit) then 
        return false 
    end
    
    local name = UnitName(unit)
    
    -- First check group role if in party/raid (most reliable)
    if UnitInParty(unit) or UnitInRaid(unit) then
        local role = UnitGroupRolesAssigned(unit)
        -- Cache the result
        tankCache[name] = (role == "TANK")
        return role == "TANK"
    end
    
    -- Check cache for known tanks
    if tankCache[name] ~= nil then
        return tankCache[name]
    end
    
    -- If not in an instance, don't bother with further checks
    if not isInInstance then
        return false
    end
    
    -- If not in group, check if they're even a class that can tank
    if UnitIsPlayer(unit) then
        local _, class, classID = UnitClass(unit)
        
        -- If it's not a class that can tank, cache and return false
        if not TANK_SPECS[classID] then 
            tankCache[name] = false
            return false 
        end
        
        -- For tank-capable classes, we'll be more lenient
        -- If they're actively tanking something, assume they're in tank spec
        local unitTarget = unit.."target"
        if UnitExists(unitTarget) then
            local isTanking = UnitDetailedThreatSituation(unit, unitTarget)
            if isTanking then
                tankCache[name] = true
                return true
            end
        end
    end
    
    -- Default to false but don't cache the result
    return false
end

-- Function to handle threat loss
local function HandleThreatLoss(unit)
    if not IsRaidBoss(unit) then return end
    
    -- Get threat situation
    local isTanking, status = UnitDetailedThreatSituation("player", unit)
    
    -- Get unit GUID for tracking
    local guid = UnitGUID(unit)
    local currentTime = GetTime()
    
    -- If we were tanking and now we're not
    if not isTanking and RT.wasTanking then
        -- Check if we're in alert cooldown for this unit
        if guid and lastAlertTime[guid] and (currentTime - lastAlertTime[guid]) < ALERT_COOLDOWN then
            if DEBUG_MODE then
                print("|cFFFF0000[RipThreat Debug]|r Alert on cooldown for", UnitName(unit))
            end
            RT.wasTanking = isTanking
            return
        end
        
        -- Check if the new tank is actually a tank (if tank-only alerts are enabled)
        local newTank = unit.."target"
        if RT.db.profile.tankOnlyAlerts then
            local isTank = IsUnitTank(newTank)
            if not isTank then
                -- Not a tank, don't alert
                RT.wasTanking = isTanking
                return
            end
        end
        
        -- Check if the mob has a taunt debuff
        local tauntInfo = GetTauntInfo(unit)
        local unitName = UnitName(unit)
        
        -- Record the alert time
        if guid then
            lastAlertTime[guid] = currentTime
        end
        
        if not tauntInfo then
            -- No taunt - show alert only
            local text = RT.db.profile.customText.noTaunt
            print("|cFFFF0000[RipThreat]|r Lost threat on " .. (unitName or "boss") .. " - No taunt active!")
            ShowAlertText(text, true)
        else
            -- Taunted - add to history only
            local message = string.format(RT.db.profile.customText.tauntFormat, tauntInfo.caster, tauntInfo.ability)
            print("|cFFFF0000[RipThreat]|r Lost threat on " .. (unitName or "boss") .. " - " .. message)
            -- Add taunt to history with yellow color
            AddToHistory(message, {r = 1, g = 1, b = 0})
        end
    end
    
    -- Update tanking status
    RT.wasTanking = isTanking
end

-- Options table for AceConfig
local options = {
    name = "RipThreat",
    handler = RT,
    type = "group",
    args = {
        alertGroup = {
            type = "group",
            name = "Alert Settings",
            order = 1,
            inline = true,
            args = {
                tankOnlyAlerts = {
                    type = "toggle",
                    name = "Tank-Only Alerts",
                    desc = "Only show alerts when you lose threat to another tank",
                    order = 0.5,
                    width = "full",
                    get = function(info) return RT.db.profile.tankOnlyAlerts end,
                    set = function(info, value)
                        RT.db.profile.tankOnlyAlerts = value
                    end,
                },
                font = {
                    type = "select",
                    name = "Font",
                    desc = "Select the font for alerts",
                    order = 1,
                    values = function()
                        if not hasLSM then return { ["Friz Quadrata TT"] = "Default" } end
                        local fonts = {}
                        for key, path in pairs(LSM:HashTable("font")) do
                            fonts[key] = key -- Use the key (friendly name) instead of the path
                        end
                        return fonts
                    end,
                    get = function(info) return RT.db.profile.font end,
                    set = function(info, value)
                        RT.db.profile.font = value
                        UpdateFont()
                    end,
                    disabled = function() return not hasLSM end,
                },
                fontSize = {
                    type = "range",
                    name = "Font Size",
                    desc = "Adjust the size of the alert text",
                    order = 2,
                    min = 8,
                    max = 72,
                    step = 1,
                    get = function(info) return RT.db.profile.fontSize end,
                    set = function(info, value)
                        RT.db.profile.fontSize = value
                        UpdateFont()
                    end,
                },
                sound = {
                    type = "select",
                    name = "Alert Sound",
                    desc = "Select the sound to play for alerts",
                    order = 3,
                    width = 1.5, -- Make room for preview button
                    values = function()
                        if not hasLSM then return { ["None Shall Pass"] = "Default" } end
                        local sounds = {}
                        for key, path in pairs(LSM:HashTable("sound")) do
                            sounds[key] = key -- Use the key (friendly name) instead of the path
                        end
                        return sounds
                    end,
                    get = function(info) return RT.db.profile.sound end,
                    set = function(info, value)
                        RT.db.profile.sound = value
                    end,
                    disabled = function() return not hasLSM end,
                },
                previewSound = {
                    type = "execute",
                    name = "Preview",
                    desc = "Play the selected sound",
                    order = 3.5,
                    width = 0.5,
                    func = function()
                        if hasLSM then
                            local soundFile = LSM:Fetch("sound", RT.db.profile.sound)
                            if soundFile then
                                PlaySoundFile(soundFile, "Master")
                            end
                        else
                            PlaySound(SOUND_ID, "Master")
                        end
                    end,
                    disabled = function() return not hasLSM end,
                },
                moveAlert = {
                    type = "execute",
                    name = "Move Alert Frame",
                    desc = "Click to move the alert frame",
                    order = 4,
                    func = function()
                        RT:MoveAlertFrame()
                    end,
                },
                noTauntText = {
                    type = "input",
                    name = "Threat Loss Alert Text",
                    desc = "The text to show when you lose threat and no taunt is active",
                    order = 5,
                    width = "full",
                    get = function(info) return RT.db.profile.customText.noTaunt end,
                    set = function(info, value)
                        RT.db.profile.customText.noTaunt = value
                    end,
                },
                tauntFormatText = {
                    type = "input",
                    name = "Taunt Notification Format",
                    desc = "The format for taunt alerts. Use %s for the taunter's name and ability (e.g. 'Taunted by %s (%s)')",
                    order = 6,
                    width = "full",
                    get = function(info) return RT.db.profile.customText.tauntFormat end,
                    set = function(info, value)
                        RT.db.profile.customText.tauntFormat = value
                    end,
                },
            },
        },
        historyGroup = {
            type = "group",
            name = "History Settings",
            order = 2,
            inline = true,
            args = {
                historyFontSize = {
                    type = "range",
                    name = "History Font Size",
                    desc = "Adjust the size of the history text",
                    order = 1,
                    min = 8,
                    max = 48,
                    step = 1,
                    get = function(info) return RT.db.profile.historyFontSize end,
                    set = function(info, value)
                        RT.db.profile.historyFontSize = value
                        UpdateFont()
                    end,
                },
                historyAlpha = {
                    type = "range",
                    name = "Background Opacity",
                    desc = "Adjust the opacity of the history window background",
                    order = 2,
                    min = 0,
                    max = 1,
                    step = 0.05,
                    get = function(info) return RT.db.profile.historyAlpha end,
                    set = function(info, value)
                        RT.db.profile.historyAlpha = value
                        UpdateHistoryFrame()
                    end,
                },
                historyScale = {
                    type = "range",
                    name = "Window Scale",
                    desc = "Adjust the size of the history window",
                    order = 3,
                    min = 0.5,
                    max = 2,
                    step = 0.1,
                    get = function(info) return RT.db.profile.historyScale end,
                    set = function(info, value)
                        RT.db.profile.historyScale = value
                        UpdateHistoryFrame()
                    end,
                },
                historyTimeVisible = {
                    type = "range",
                    name = "Message Duration",
                    desc = "How long messages remain visible (in seconds)",
                    order = 4,
                    min = 1,
                    max = 30,
                    step = 1,
                    get = function(info) return RT.db.profile.historyTimeVisible end,
                    set = function(info, value)
                        RT.db.profile.historyTimeVisible = value
                        UpdateHistoryFrame()
                    end,
                },
                historyMaxLines = {
                    type = "range",
                    name = "Maximum Lines",
                    desc = "Maximum number of messages to show",
                    order = 5,
                    min = 1,
                    max = 50,
                    step = 1,
                    get = function(info) return RT.db.profile.historyMaxLines end,
                    set = function(info, value)
                        RT.db.profile.historyMaxLines = value
                        UpdateHistoryFrame()
                    end,
                },
                moveHistory = {
                    type = "execute",
                    name = "Move History Frame",
                    desc = "Click to move the history frame",
                    order = 6,
                    func = function()
                        RT:MoveHistoryFrame()
                    end,
                },
            },
        },
        testGroup = {
            type = "group",
            name = "Test Settings",
            order = 3,
            inline = true,
            args = {
                test = {
                    type = "execute",
                    name = "Test Alert",
                    desc = "Show a test alert and history entry",
                    order = 1,
                    func = function()
                        -- Show threat loss alert
                        ShowAlertText("TEST - LOST THREAT - NO TAUNT!", true)
                        -- Add test taunt to history
                        local testTaunt = string.format(RT.db.profile.customText.tauntFormat, 
                            "|cFF00FF00TestTank|r", "Taunt")
                        AddToHistory(testTaunt, {r = 1, g = 1, b = 0})
                    end,
                },
                testMode = {
                    type = "toggle",
                    name = "Test Mode",
                    desc = "Enable to test alerts on any target",
                    order = 2,
                    get = function() return TEST_MODE end,
                    set = function(info, value)
                        TEST_MODE = value
                        print("|cFFFF0000[RipThreat]|r Test mode " .. (TEST_MODE and "enabled" or "disabled"))
                        if TEST_MODE then
                            -- Show threat loss alert
                            ShowAlertText("TEST - LOST THREAT - NO TAUNT!", true)
                            -- Add test taunt to history
                            local testTaunt = string.format(RT.db.profile.customText.tauntFormat, 
                                "|cFF00FF00TestTank|r", "Taunt")
                            AddToHistory(testTaunt, {r = 1, g = 1, b = 0})
                        end
                    end,
                },
            },
        },
    },
}

function RT:OnInitialize()
    -- Initialize our saved variables
    self.db = LibStub("AceDB-3.0"):New("RipThreatDB", defaults)
    
    -- Register our options table
    LibStub("AceConfig-3.0"):RegisterOptionsTable("RipThreat", options)
    
    -- Register with the appropriate settings system
    if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
        -- Retail WoW (Dragonflight)
        local dialog = LibStub("AceConfigDialog-3.0")
        dialog:SetDefaultSize("RipThreat", 800, 600)
        dialog:AddToBlizOptions("RipThreat")
    else
        -- Classic WoW
        LibStub("AceConfigDialog-3.0"):AddToBlizOptions("RipThreat")
    end
    
    -- Register slash commands
    self:RegisterChatCommand("rt", "SlashCommand")
    self:RegisterChatCommand("ripthreat", "SlashCommand")
    
    -- Update UI with saved settings
    UpdateFramePosition()
    UpdateFont()
    UpdateHistoryFrame()
    
    print("|cFFFF0000[RipThreat]|r loaded. Type /rt for commands.")
    if not hasLSM then
        print("|cFFFF0000[RipThreat]|r LibSharedMedia-3.0 not found. Using default sound and font.")
    end
end

function RT:OnEnable()
    self:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RegisterEvent("PLAYER_REGEN_DISABLED") -- Combat start
    self:RegisterEvent("PLAYER_REGEN_ENABLED") -- Combat end
    self.wasTanking = false
end

-- New function to update instance status
function RT:UpdateInstanceStatus()
    local inInstance, instanceType = IsInInstance()
    isInInstance = inInstance and (instanceType == "party" or instanceType == "raid")
    
    -- Clear caches when changing zones
    tankCache = {}
    bossCache = {}
end

function RT:PLAYER_ENTERING_WORLD()
    self:UpdateInstanceStatus()
end

function RT:ZONE_CHANGED_NEW_AREA()
    self:UpdateInstanceStatus()
end

function RT:PLAYER_REGEN_DISABLED()
    isInCombat = true
end

function RT:PLAYER_REGEN_ENABLED()
    isInCombat = false
    -- Clear the caches when leaving combat
    -- This helps if a mob's status changes during the fight
    bossCache = {}
    tauntCache = {}
    tauntCacheTime = {}
    lastAlertTime = {} -- Clear alert cooldowns
    RT.wasTanking = false -- Reset tanking status
end

function RT:UNIT_THREAT_LIST_UPDATE(event, unit)
    if not unit then return end
    
    -- Only process if we're in an instance and in combat
    if (not isInInstance or not isInCombat) and not TEST_MODE then return end
    
    -- Only process if unit is targeting player or is player's target
    if not (UnitIsUnit(unit.."target", "player") or UnitIsUnit("target", unit)) then
        return
    end
    
    -- Get current time
    local currentTime = GetTime()
    
    -- Check if we're processing the same unit too quickly
    if unit == lastCheckedUnit and (currentTime - lastCheckedTime) < CHECK_THRESHOLD then
        return
    end
    
    -- Update cache and process threat
    lastCheckedUnit = unit
    lastCheckedTime = currentTime
    
    -- Check if this is a valid unit to track
    if IsRaidBoss(unit) then
        -- Get current threat status
        local isTanking, status, scaledPercentage, rawPercentage, threatValue = UnitDetailedThreatSituation("player", unit)
        
        if DEBUG_MODE then
            print("|cFFFF0000[RipThreat Debug]|r Threat check on", UnitName(unit), 
                  "isTanking:", isTanking or "nil", 
                  "status:", status or "nil", 
                  "threat %:", rawPercentage or "nil")
        end
        
        -- Initialize wasTanking if this is the first check
        if RT.wasTanking == nil then
            RT.wasTanking = isTanking or false
        end
        
        -- Process threat changes
        HandleThreatLoss(unit)
    end
end

-- Frame movement functions
local function StartFrameMoving(frame, saveFunc)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveFunc(self)
    end)
    frame.moving = true
end

local function StopFrameMoving(frame)
    frame:StopMovingOrSizing()
    frame:SetMovable(false)
    frame:EnableMouse(false)
    frame:RegisterForDrag(nil)
    frame:SetScript("OnDragStart", nil)
    frame:SetScript("OnDragStop", nil)
    frame.moving = false
end

function RT:MoveAlertFrame()
    if alertFrame.moving then
        StopFrameMoving(alertFrame)
        print("|cFFFF0000[RipThreat]|r Alert frame position locked")
    else
        StartFrameMoving(alertFrame, function(frame)
            local scale = UIParent:GetScale()
            local x, y = frame:GetCenter()
            x = (x * scale) - (UIParent:GetWidth() * scale / 2)
            y = (y * scale) - (UIParent:GetHeight() * scale / 2)
            self.db.profile.position.x = x
            self.db.profile.position.y = y
        end)
        print("|cFFFF0000[RipThreat]|r Alert frame unlocked for moving. Click and drag to move, click again to lock")
        -- Show test text while moving
        ShowAlertText("TEST - LOST THREAT - NO TAUNT!", true)
    end
end

function RT:MoveHistoryFrame()
    if historyFrame.moving then
        StopFrameMoving(historyFrame)
        print("|cFFFF0000[RipThreat]|r History frame position locked")
    else
        StartFrameMoving(historyFrame, function(frame)
            local scale = UIParent:GetScale()
            local x, y = frame:GetCenter()
            x = (x * scale) - (UIParent:GetWidth() * scale / 2)
            y = (y * scale) - (UIParent:GetHeight() * scale / 2)
            self.db.profile.historyPosition.x = x
            self.db.profile.historyPosition.y = y
        end)
        print("|cFFFF0000[RipThreat]|r History frame unlocked for moving. Click and drag to move, click again to lock")
        -- Add some test messages while moving
        AddToHistory("Test Message 1", {r=1, g=0, b=0})
        AddToHistory("Test Message 2", {r=1, g=1, b=0})
        AddToHistory("Test Message 3", {r=1, g=1, b=1})
    end
end

function RT:SlashCommand(input)
    if input == "test" then
        TEST_MODE = not TEST_MODE
        print("|cFFFF0000[RipThreat]|r Test mode " .. (TEST_MODE and "enabled" or "disabled"))
        if TEST_MODE then
            ShowAlertText("TEST - LOST THREAT - NO TAUNT!", true)
        end
    elseif input == "debug" then
        DEBUG_MODE = not DEBUG_MODE
        print("|cFFFF0000[RipThreat]|r Debug mode " .. (DEBUG_MODE and "enabled" or "disabled"))
    elseif input == "config" or input == "options" then
        if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
            -- Retail WoW (Dragonflight)
            Settings.OpenToCategory("RipThreat")
        else
            -- Classic WoW
            InterfaceOptionsFrame_Show()
            InterfaceOptionsFrame_OpenToCategory("RipThreat")
        end
    else
        print("|cFFFF0000[RipThreat]|r Commands:")
        print("  /rt test - Toggle test mode")
        print("  /rt debug - Toggle debug mode")
        print("  /rt config - Open configuration")
    end
end
