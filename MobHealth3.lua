--[[
	MobHealth3!
		

	By Neronix of Hellscream EU
		With tons of contributions by Mikk

	Forked and updated by Mirasu for Kronos 4 
--]]

MobHealth3 = AceLibrary("AceAddon-2.0"):new("AceEvent-2.0", "AceConsole-2.0", "AceDB-2.0")

--[[
	File-scope local vars
--]]

local MH3Cache = {}

local AccumulatorHP = {} -- Keeps Damage-taken data for mobs that we've actually poked during this session
local AccumulatorPerc = {} -- Keeps Percentage-taken data for mobs that we've actually poked during this session
local calculationUnneeded = {} -- Keeps a list of things that don't need calculation (e.g. Beast Lore'd mobs)

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

-- Corrected Metatable: This prevents the infinite loop/C Stack Overflow
local compatMT = {
    __index = function(t, k)
        local val = rawget(t, k)
        if val then
            -- This looks for the number after the "/" (the 156)
            local _, _, health = string.find(val, ".+/(%d+)")
            if health then
                return health .. "/100"
            else
                -- If it's just a number like "156", use it as is
                return val .. "/100"
            end
        end
        return nil
    end
}

-- Debug function. Not for Joe Average
function GetMH3Cache() return MH3Cache end


--[[
	Init/Enable methods
--]]

function MobHealth3:OnInitialize()
    -- 1. Ensure the Database exists
    if not MobHealthDB then MobHealthDB = {} end
    
    -- 2. Register Database with Ace2
    self.db = self:RegisterDB("MobHealth3Config")

    -- 3. Register Chat Commands (Option A)
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
            -- ... (your other args: precision, stablemax, reset)
        },
    })

    -- 4. THE UNIVERSAL BRIDGES (Force pfUI compatibility)
    MobHealth3DB = MobHealthDB
    
    if pfUI and pfUI.api then
        -- Force pfUI's shared library to point to our database
        pfUI.api.libmobhealth = MobHealthDB
        
        -- pfUI specific: If it has its own internal cache, we overwrite it
        if pfUI.cache and pfUI.cache["libmobhealth"] then
            pfUI.cache["libmobhealth"] = MobHealthDB
        end
    end

    -- 5. Enable the Guestimator/Format Metatable
    setmetatable(MobHealthDB, compatMT)
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MobHealth3:|r Database Loaded (".. (MobHealthDB and "ALIVE" or "DEAD") ..")")
    -- V7: ERROR-PROOF INJECTOR (Place inside OnInitialize)
    local injector = CreateFrame("Frame")
    -- V8: CLEAN INJECTOR (Target Frame only, No Tooltips)
    local injector = CreateFrame("Frame")
    injector:SetScript("OnUpdate", function()
        -- 1. TARGET FRAME OVERLAY (Silent)
        -- We only update the Blizzard Target frame. 
        -- Dedicated tooltip addons will handle the tooltip their own way.
        if TargetFrame and TargetFrame:IsVisible() then
            local c, m, found = MobHealth3:GetUnitHealth("target")
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
             local c, m, found = MobHealth3:GetUnitHealth("targettarget")
             if found then
                 local tot = getglobal("TargetofTargetHealthBarText")
                 if tot and tot.SetText then tot:SetText(c .. " / " .. m) end
             end
        end
    end)
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MobHealth3:|r Ultra-Compatible Mode Active.")
end

--[[
	Dummy MobHealthFrame. Some mods use this to detect MH/MH2/MI2
--]]

CreateFrame("frame", "MobHealthFrame")

--[[
    Event Handlers
--]]

function MobHealth3:UNIT_COMBAT()
	if arg1=="target" and currentAccHP then
		recentDamage = recentDamage + arg4
		totalDamage = totalDamage + arg4
	end
end

function MobHealth3:PLAYER_TARGET_CHANGED()

	-- Is target valid?
	-- We ignore pets. There's simply far too many pets that share names with players so we let players take priority

	local creatureType = UnitCreatureType("target") -- Saves us from calling it twice
	if UnitCanAttack("player", "target") and not UnitIsDead("target") and not UnitIsFriend("player", "target") and not ( (creatureType == "Beast" or creatureType == "Demon") and UnitPlayerControlled("target") ) then

		targetName = UnitName("target")
		targetLevel = UnitLevel("target")

		targetIndex = string.format("%s:%d", targetName, targetLevel)

		--self:Debug("Acquired valid target: index: %s, in db: %s", targetIndex, not not MH3Cache[targetIndex])

		recentDamage, totalDamage = 0, 0, 0
		startPercent = UnitHealth("target")
		lastPercent = startPercent

		currentAccHP = AccumulatorHP[targetIndex]
		currentAccPerc = AccumulatorPerc[targetIndex]

		if not UnitIsPlayer("target") then
			-- Mob: keep accumulated percentage below 200% in case we hit mobs with different hp
			if not currentAccHP then
				if MH3Cache[targetIndex] then
					-- We claim that this previous value that we have is from seeing percentage drop from 100 to 0
					AccumulatorHP[targetIndex] = MH3Cache[targetIndex]
					AccumulatorPerc[targetIndex] = 100
				else
					-- Nothing previously known. Start fresh.
					AccumulatorHP[targetIndex] = 0
					AccumulatorPerc[targetIndex] = 0
				end
				currentAccHP = AccumulatorHP[targetIndex]
				currentAccPerc = AccumulatorPerc[targetIndex]
			end

			if currentAccPerc>200 then
				currentAccHP = currentAccHP / currentAccPerc * 100
				currentAccPerc = 100
			end

		else
			-- Player health can change a lot. Different gear, buffs, etc.. we only assume that we've seen 10% knocked off players previously
			if not currentAccHP then
				if MH3Cache[targetIndex] then
					AccumulatorHP[targetIndex] = MH3Cache[targetIndex]*0.1
					AccumulatorPerc[targetIndex] = 10
				else
					AccumulatorHP[targetIndex] = 0
					AccumulatorPerc[targetIndex] = 0
				end
				currentAccHP = AccumulatorHP[targetIndex]
				currentAccPerc = AccumulatorPerc[targetIndex]
			end
	
			if currentAccPerc>10 then
				currentAccHP = currentAccHP / currentAccPerc * 10
				currentAccPerc = 10
			end

		end

	else
		--self:Debug("Acquired invalid target. Ignoring")
		currentAccHP = nil
		currentAccPerc = nil
	end
end

function MobHealth3:UNIT_HEALTH()
	if currentAccHP and arg1=="target" then 
		self:CalculateMaxHealth(UnitHealth("target"), UnitHealthMax("target")) 
	end
end

--[[
	The meat of the machine!
--]]

function MobHealth3:CalculateMaxHealth(current, max)

	if calculationUnneeded[targetIndex] then return;
    
    elseif current==startPercent or current==0 then
	--self:Debug("Targetting a dead guy?")
    
    elseif max > 100 then
        -- zOMG! Beast Lore! We no need no stinking calculations!
        MH3Cache[targetIndex] = max
        -- print(string.format("We got beast lore! Max is %d", max))
        calculationUnneeded[targetIndex] = true

	elseif current > lastPercent or startPercent>100 then
		-- Oh noes! It healed! :O
		lastPercent = current
		startPercent = current
		recentDamage=0
		totalDamage=0
		--self:Debug("O NOES IT HEALED!?")

	elseif recentDamage>0 then

		if current~=lastPercent then
			currentAccHP = currentAccHP + recentDamage
			currentAccPerc = currentAccPerc + (lastPercent-current)
			recentDamage = 0
			lastPercent = current		
		end
		
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
--]]
function MobHealth3:GetUnitHealth(unit, current, max, name, level)
    if not UnitExists(unit) then return 0, 0, false; end
    current, max, name, level = current or UnitHealth(unit), max or UnitHealthMax(unit), name or UnitName(unit), level or UnitLevel(unit)
    if level == -1 then level = 63; end

    -- Only process if the game is currently showing a 0-100 percentage
    if max == 100 and not (UnitPlayerControlled(unit)) then 
        local key = name..":"..level
        local rawData = MobHealthDB[key] -- Using the Global DB name directly
        
        -- Guestimator Logic: If level is missing, check level+1 and scale down
        if not rawData then
            local nextLvlData = MobHealthDB[name..":"..(level + 1)]
            if nextLvlData then
                local _, _, found = string.find(tostring(nextLvlData), ".+/(%d+)")
                local baseHP = tonumber(found or nextLvlData)
                if baseHP then
                    local ratio = (level < 20) and 0.88 or (level < 40 and 0.925 or 0.965)
                    rawData = math.floor(baseHP * ratio)
                end
            end
        end

        if rawData then
            -- Format Fix: Pull "156" out of "8/156"
            local _, _, finalMax = string.find(tostring(rawData), ".+/(%d+)")
            finalMax = tonumber(finalMax or rawData)
            
            if finalMax and finalMax > 100 then
                -- Math: Convert percentage (current) to real health
                local realCur = math.floor(current/100 * finalMax + 0.5)
                return realCur, finalMax, true
            end
        end
    end
    return current, max, false
end
