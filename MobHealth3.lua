--[[
	MobHealth3!
		

	By Neronix of Hellscream EU
		With tons of contributions by Mikk

	Forked and updated by Mirasu for Kronos 4 
--]]

MobHealth3 = AceLibrary("AceAddon-2.0"):new("AceEvent-2.0", "AceConsole-2.0", "AceDB-2.0")

-- PROTECTION: Claim the global database without overwriting it
MobHealth3_StaticDB = MobHealth3_StaticDB or {}

local MH3Cache = {}
local AccumulatorHP = {} 
local AccumulatorPerc = {} 
local calculationUnneeded = {} 

local currentAccHP
local currentAccPerc

local targetName, targetLevel, targetIndex
local recentDamage, totalDamage = 0, 0
local startPercent, lastPercent = 100, 100

local defaults = {
    saveData = true,
    precision = 10,
    stableMax = true,
}

--  PVP: Baseline health multipliers by class for the Plausibility Filter
local ClassHPMultipliers = {
    ["MAGE"] = 55,
    ["PRIEST"] = 60,
    ["ROGUE"] = 65,
    ["HUNTER"] = 70,
    ["DRUID"] = 70,
    ["SHAMAN"] = 75,
    ["PALADIN"] = 80,
    ["WARLOCK"] = 80,
    ["WARRIOR"] = 90,
}

-- Corrected Metatable: Handles Exact Match -> ?? Level -> Name-Only
compatMT = {
    __index = function(t, k)
        local val = rawget(t, k) or rawget(t, string.gsub(tostring(k), ":%d+$", ":63")) or rawget(t, string.gsub(tostring(k), ":%d+$", ""))
        if val then
            -- FIX: Always extract only the health portion
            local _, _, health = string.find(tostring(val), ".+/(%d+)")
            return (health or val) .. "/100"
        end
        return nil
    end
}

--  MASTER BRIDGE: Initialized after Metatable is ready
MobHealthDB = setmetatable(MobHealth3_StaticDB, compatMT)
MobHealth3DB = MobHealthDB

if pfUI and pfUI.api then
    pfUI.api.libmobhealth = MobHealthDB
end
-- Debug function. Not for Joe Average
function GetMH3Cache() return MH3Cache end


--[[
	Init/Enable methods
--]]

function MobHealth3:OnInitialize()
    -- Register our local config/cache
    self.db = self:RegisterDB("MobHealth3Config")

    -- Register Chat Commands
    self:RegisterChatCommand({"/mobhealth3", "/mh3"}, {
        type = "group",
        args = {
            save = {
                name = "Save Data",
                desc = "Save data across sessions.",
                type = "toggle",
                get = function() return true end,
                set = function(val) end,
            },
        },
    })



    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MobHealth3:|r Protected Database Loaded.")
    local injector = CreateFrame("Frame")
    injector:SetScript("OnUpdate", function()
        -- 1. TARGET FRAME OVERLAY (Silent)
        -- We only update the Blizzard Target frame. 
        -- Dedicated tooltip addons will handle the tooltip their own way.
        if TargetFrame and TargetFrame:IsVisible() then
            local c, m, found = self:GetUnitHealth("target")
            if found then
                if not MH3_TargetOverlay then
                    MH3_TargetOverlay = TargetFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    MH3_TargetOverlay:SetPoint("CENTER", TargetFrame, "TOPLEFT", 150, -38)
                end
                MH3_TargetOverlay:SetText(c .. " / " .. m)
                MH3_TargetOverlay:Show()
            elseif MH3_TargetOverlay then
                MH3_TargetOverlay:Hide()
            end
        end

        -- 2. TARGET OF TARGET (Optional) untested
        if TargetofTargetFrame and TargetofTargetFrame:IsVisible() then
             local c, m, found = self:GetUnitHealth("targettarget")
             if found then
                 local tot = getglobal("TargetofTargetHealthBarText")
                 if tot and tot.SetText then tot:SetText(c .. " / " .. m) end
             end
        end
    end)
    
end

function MobHealth3:OnEnable()
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("UNIT_HEALTH")
    
    -- Self Combat
    self:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE", "CombatLogParser")
    
    -- Group & Faction Combat (Other players of your faction)
    self:RegisterEvent("CHAT_MSG_COMBAT_PARTY_HITS", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_PARTY_DAMAGE", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE", "CombatLogParser")
    
    -- Enemy Faction Combat (Opposing faction players hitting your target)
    self:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE", "CombatLogParser")
    
    -- Pets, Summons, and Guards
    self:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE", "CombatLogParser")

    -- Periodic Damage (DoTs - Catches all DoT damage regardless of who cast it)
    self:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE", "CombatLogParser")
    self:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE", "CombatLogParser")
end

--[[
	Dummy MobHealthFrame. Some mods use this to detect MH/MH2/MI2
--]]

CreateFrame("frame", "MobHealthFrame")

--[[
    Event Handlers
--]]

function MobHealth3:CombatLogParser()
    local mobName, damage

    -- 1. Catch generic Hits (Melee & Spell, Self & Others)
    _, _, mobName, damage = string.find(arg1, " hits (.+) for (%d+)")
    
    -- 2. Catch generic Crits
    if not mobName then
        _, _, mobName, damage = string.find(arg1, " crits (.+) for (%d+)")
    end
    
    -- 3. Catch DoTs and Environmental
    if not mobName then
        _, _, mobName, damage = string.find(arg1, "^(.+) suffers (%d+)")
    end
    
    -- 4. Catch specific WoW 1.12 "You" formatting
    if not mobName then
        _, _, mobName, damage = string.find(arg1, "^You hit (.+) for (%d+)")
    end
    if not mobName then
        _, _, mobName, damage = string.find(arg1, "^You crit (.+) for (%d+)")
    end

    -- Verify the damage happened to our actual target
    if mobName and damage then
        if mobName == targetName and currentAccHP then
            recentDamage = recentDamage + tonumber(damage)
            totalDamage = totalDamage + tonumber(damage)
        end
    end
end

function MobHealth3:UNIT_HEALTH()
    if arg1 == "target" and currentAccHP ~= nil then 
        self:CalculateMaxHealth(UnitHealth("target"), UnitHealthMax("target")) 
    end
end

function MobHealth3:CalculateMaxHealth(current, max)
    if current == startPercent or current == 0 then
        return
    elseif max > 100 then
        return
    elseif current > lastPercent or startPercent > 100 then
        lastPercent = current
        startPercent = current
        recentDamage = 0
        totalDamage = 0
    elseif recentDamage > 0 then
        if current ~= lastPercent then
            currentAccHP = currentAccHP + recentDamage
            currentAccPerc = currentAccPerc + (lastPercent - current)
            recentDamage = 0
            lastPercent = current 
            
            AccumulatorHP[targetIndex] = currentAccHP
            AccumulatorPerc[targetIndex] = currentAccPerc
        end
    end
end

function MobHealth3:PLAYER_TARGET_CHANGED()
    if UnitExists("target") and not UnitIsDead("target") and not UnitIsFriend("player", "target") then
        targetName = UnitName("target")
        targetLevel = UnitLevel("target")

        targetIndex = string.format("%s:%d", targetName, targetLevel)
        recentDamage, totalDamage = 0, 0
        startPercent = UnitHealth("target")
        lastPercent = startPercent

        -- Default to 0 so combat estimator can begin tracking players/unknowns
        currentAccHP = AccumulatorHP[targetIndex] or 0
        currentAccPerc = AccumulatorPerc[targetIndex] or 0

        -- Only populate from DB if we don't already have combat data
        if currentAccHP == 0 then
            local db = MobHealth3_StaticDB or {}
            local rawData
            
            if targetLevel ~= -1 then
                rawData = rawget(db, targetIndex)
            end
            
            if not rawData then
                for key, val in pairs(db) do
                    if key == targetName or string.find(key, "^" .. targetName .. ":") then
                        rawData = val
                        break
                    end
                end
            end
            
            if rawData then
                local _, _, dbLevel, dbMax = string.find(tostring(rawData), "(%d+)/(%d+)")
                local finalMax = tonumber(dbMax or rawData)
                local sourceLevel = tonumber(dbLevel or targetLevel)
                
                if finalMax and finalMax > 100 then
                    -- THE GUESTIMATOR
                    if targetLevel > 0 and sourceLevel > 0 and targetLevel ~= sourceLevel then
                        finalMax = math.floor(finalMax * (targetLevel / sourceLevel))
                    end

                    AccumulatorHP[targetIndex] = finalMax
                    AccumulatorPerc[targetIndex] = 100
                    currentAccHP = finalMax
                    currentAccPerc = 100
                end
            end
        end

        -- PVP FIX: Raised player data retention from 10% to 100% for higher accuracy
        local maxLimit = UnitIsPlayer("target") and 100 or 200
        if currentAccPerc and currentAccPerc > maxLimit then
            currentAccHP = (currentAccHP / currentAccPerc) * maxLimit
            currentAccPerc = maxLimit
        end 
    else
        currentAccHP = nil
        currentAccPerc = nil
    end
end

--[[
	Compatibility for functions MobHealth2 introduced
--]]

function MobHealth_GetTargetMaxHP()
	local currHP, maxHP, found = MobHealth3:GetUnitHealth("target", UnitHealth("target"), UnitHealthMax("target"), UnitName("target"), UnitLevel("target"))
	return found and maxHP or nil
end

function MobHealth_GetTargetCurHP()
	local currHP, maxHP, found = MobHealth3:GetUnitHealth("target", UnitHealth("target"), UnitHealthMax("target"), UnitName("target"), UnitLevel("target"))
	return found and currHP or nil
end

--[[
	Compatibility for MobHealth_PPP()
--]]

function MobHealth_PPP(index)
    return MH3Cache[index] and MH3Cache[index]/100 or 0
end



-- THE UNIFIED ENGINE: Optimized for 1.12 logic
function MobHealth3:GetUnitHealth(unit, current, max, uName, uLevel)
    if type(unit) == "table" then unit, current, max, uName, uLevel = current, max, uName, uLevel, nil end
    if not UnitExists(unit) then return 0, 0, false; end
    
    current, max = current or UnitHealth(unit), max or UnitHealthMax(unit)
    uName, uLevel = uName or UnitName(unit), uLevel or UnitLevel(unit)

    -- 1. NPCs/Players (Pass through real numbers if max is known)
    if max > 100 then return current, max, true end

    local uKey = uName..":"..uLevel
    local db = MobHealth3_StaticDB or {}
    local rawData
    
    -- 2. Try DB Exact Match
    if uLevel ~= -1 then
        rawData = rawget(db, uKey)
    end
    
    -- 3. Try DB Name Fallback
    if not rawData then
        for key, val in pairs(db) do
            if key == uName or string.find(key, "^" .. uName .. ":") then
                rawData = val
                break
            end
        end
    end

    -- 4. STATIC DB MATCH FOUND (Apply Guestimator)
    if rawData then
        local _, _, dbLevel, dbMax = string.find(tostring(rawData), "(%d+)/(%d+)")
        local finalMax = tonumber(dbMax or rawData)
        local sourceLevel = tonumber(dbLevel or uLevel)

        if finalMax and finalMax > 100 then
            if uLevel > 0 and sourceLevel > 0 and uLevel ~= sourceLevel then
                finalMax = math.floor(finalMax * (uLevel / sourceLevel))
            end
            
            return math.floor((current/100) * finalMax + 0.5), finalMax, true
        end
    end
    
    -- 5. ULTIMATE FALLBACK: Combat Math Estimator (For Players & Unlisted NPCs)
    local accHP = AccumulatorHP[uKey]
    local accPerc = AccumulatorPerc[uKey]
    
    if accHP and accPerc and accPerc > 0 then
        -- ACCURACY FIX: Require a 5% drop to bypass the 1% rounding error
        if accPerc >= 5 then
                local estimatedMax = math.floor((accHP / accPerc) * 100 + 0.5)
                
                -- PLAUSIBILITY FILTER: Intercept ballooning and shrinking health
                if UnitIsPlayer(unit) and uLevel > 0 then
                    local sanityCap = uLevel * 130
                    local sanityFloor = uLevel * 30 -- e.g., Level 60 * 30 = 1,800 Max HP minimum
                    
                    if estimatedMax > sanityCap or estimatedMax < sanityFloor then
                        local _, targetClass = UnitClass(unit)
                        local classMult = ClassHPMultipliers[targetClass] or 65
                        estimatedMax = uLevel * classMult
                    end
                end

                if estimatedMax > 100 then
                    local estimatedCurrent = math.floor((current / 100) * estimatedMax + 0.5)
                return estimatedCurrent, estimatedMax, true
            end
        else
            -- Lock display to percentages while building confidence to prevent UI flickering
            return current, 100, true
        end
    end

    return current, max, false
end