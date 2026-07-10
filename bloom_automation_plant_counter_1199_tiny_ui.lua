-- Moon/Hypno Bloom Automation LocalScript
-- Paste into a LocalScript or run on the client.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local Event = ReplicatedStorage.SharedModules.Packet.RemoteEvent

local TARGET_SEED_NAMES = {
	["Moon Bloom"] = true,
	["Hypno Bloom"] = true
}

local TARGET_SEED_LABEL = "Moon/Hypno Bloom"
local BLOOM_BASE_KG = 9

local WATERING_CAN_PACKET_ID = 67
local SPRINKLER_PACKET_ID = 20

local SPRINKLER_CHECK_RADIUS = 12
local SPRINKLER_PLACE_WAIT_TIME = 5
local CHECK_DELAY = 0.5

local SPRINKLER_NAMES = {
	"Common Sprinkler",
	"Uncommon Sprinkler",
	"Rare Sprinkler",
	"Legendary Sprinkler",
	"Super Sprinkler"
}

local WATERING_CAN_NAMES = {
	"Common Watering Can",
	"Super Watering Can"
}

-- Defaults: only Super Sprinkler ON
local selectedSprinklers = {
	["Common Sprinkler"] = false,
	["Uncommon Sprinkler"] = false,
	["Rare Sprinkler"] = false,
	["Legendary Sprinkler"] = false,
	["Super Sprinkler"] = true
}

-- Defaults: only Super Watering Can ON
local selectedWateringCans = {
	["Common Watering Can"] = false,
	["Super Watering Can"] = true
}

local masterEnabled = true
local enabled = false
local loopRunning = false
local minimized = false

-- Defaults: Above 58.5 KG ON
local kgThreshold = 93
local kgFilterEnabled = true
local kgMode = "Above" -- "Above" or "Below"

-- Defaults: ratio auto ON, start below 80%, stop above 85%
-- Ratio is good-KG Moon/Hypno Bloom fruits / Moon/Hypno Bloom plants.
local ratioControlEnabled = true
local startBelowRatio = 0.80
local stopAboveRatio = 0.85

-- Automation will not start unless Moon/Hypno Bloom plant count reaches this.
local MIN_PLANTS_TO_START = 1199

local wateredForCurrentCondition = false
local waitingForCollection = false
local sessionFullyGrownCount = 0
local sessionBadKgCount = 0
local sessionStartedAt = 0

-- Delay before capturing the post-water session state.
local SESSION_CAPTURE_DELAY = 0.8

-- Important anti-spam delay:
-- Super Watering Can may take a few seconds before fruits visually/attribute-wise become fully grown.
-- During this window, the script will NOT start another water session.
local GROWTH_SETTLE_TIME = 8

-- After watering, wait until harvested fruit inventory stops changing before watering again.
local HARVEST_IDLE_SECONDS = 10

-- Track BOTH:
-- 1. Player counter attribute: player:GetAttribute("HarvestedFruits")
-- 2. Inventory/tool fruit attribute: HarvestedFruit == true
local HARVESTED_FRUITS_PLAYER_ATTRIBUTE = "HarvestedFruits"
local HARVESTED_FRUIT_ITEM_ATTRIBUTE = "HarvestedFruit"

local harvestTrackerStarted = false
local harvestWatchedInstances = {}
local harvestWatchedRoots = {}

local lastHarvestedFruitCounter = tonumber(player:GetAttribute(HARVESTED_FRUITS_PLAYER_ATTRIBUTE)) or 0
local lastHarvestedFruitItemCount = 0
local lastHarvestChangeTime = os.clock()

local sessionStartHarvestedFruitCounter = 0
local sessionStartHarvestedFruitItemCount = 0

local lastRatioGoodFruitCount = nil
local lastRatioPlantCount = nil

local oldGui = player:WaitForChild("PlayerGui"):FindFirstChild("BloomAutomationUI")
if oldGui then
	oldGui:Destroy()
end

local function makeItemBuffer(packetId, position, itemName, extraByte)
	local nameLength = #itemName
	local size = 2 + 12 + 1 + nameLength

	if extraByte ~= nil then
		size += 1
	end

	local b = buffer.create(size)

	buffer.writeu16(b, 0, packetId)

	buffer.writef32(b, 2, position.X)
	buffer.writef32(b, 6, position.Y)
	buffer.writef32(b, 10, position.Z)

	buffer.writeu8(b, 14, nameLength)
	buffer.writestring(b, 15, itemName)

	if extraByte ~= nil then
		buffer.writeu8(b, 15 + nameLength, extraByte)
	end

	return b
end

local function getPosition(instance)
	if not instance then
		return nil
	end

	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end

	if instance:IsA("BasePart") then
		return instance.Position
	end

	local model = instance:FindFirstAncestorOfClass("Model")
	if model then
		return model:GetPivot().Position
	end

	return nil
end

local function isTargetSeedName(seedName)
	return seedName ~= nil and TARGET_SEED_NAMES[seedName] == true
end

local function hasMoonBloomSeedName(instance)
	if isTargetSeedName(instance:GetAttribute("SeedName")) then
		return true
	end

	local parent = instance.Parent

	while parent and parent ~= workspace do
		if isTargetSeedName(parent:GetAttribute("SeedName")) then
			return true
		end

		parent = parent.Parent
	end

	return false
end

local function findMoonBloomPlant()
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if isTargetSeedName(descendant:GetAttribute("SeedName")) and descendant:GetAttribute("SizeMulti") == nil then
			return descendant
		end
	end

	for _, descendant in ipairs(workspace:GetDescendants()) do
		if isTargetSeedName(descendant:GetAttribute("SeedName")) then
			local model = descendant:FindFirstAncestorOfClass("Model")
			return model or descendant
		end
	end

	return nil
end

local function findMoonBloomPlants()
	local plants = {}
	local seen = {}

	for _, descendant in ipairs(workspace:GetDescendants()) do
		if isTargetSeedName(descendant:GetAttribute("SeedName")) and descendant:GetAttribute("SizeMulti") == nil then
			local root

			if descendant:IsA("Model") then
				root = descendant
			else
				root = descendant:FindFirstAncestorOfClass("Model") or descendant
			end

			if root and not seen[root] then
				seen[root] = true
				table.insert(plants, root)
			end
		end
	end

	return plants
end

local function isFruitFullyGrown(fruit)
	local age = tonumber(fruit:GetAttribute("Age"))
	local maxAge = tonumber(fruit:GetAttribute("MaxAge"))

	if not age or not maxAge then
		return false
	end

	return age >= maxAge
end

local function findMoonBloomFruits()
	local fruits = {}

	for _, descendant in ipairs(workspace:GetDescendants()) do
		local sizeMulti = descendant:GetAttribute("SizeMulti")

		if sizeMulti ~= nil and hasMoonBloomSeedName(descendant) then
			sizeMulti = tonumber(sizeMulti)

			if sizeMulti then
				local age = tonumber(descendant:GetAttribute("Age"))
				local maxAge = tonumber(descendant:GetAttribute("MaxAge"))
				local kg = sizeMulti * BLOOM_BASE_KG
				local fullyGrown = isFruitFullyGrown(descendant)

				table.insert(fruits, {
					Instance = descendant,
					SizeMulti = sizeMulti,
					KG = kg,
					Age = age,
					MaxAge = maxAge,
					FullyGrown = fullyGrown
				})
			end
		end
	end

	return fruits
end

local function getPlayerHarvestedFruitCounter()
	local value = player:GetAttribute(HARVESTED_FRUITS_PLAYER_ATTRIBUTE)

	if typeof(value) == "number" then
		return value
	end

	if typeof(value) == "string" then
		return tonumber(value) or 0
	end

	return 0
end

local function getHarvestRoots()
	local roots = {}

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(roots, backpack)
	end

	if player.Character then
		table.insert(roots, player.Character)
	end

	return roots
end

local function getHarvestedFruitOwner(instance)
	local current = instance

	while current and current ~= game do
		if current:IsA("Tool") then
			return current
		end

		current = current.Parent
	end

	return instance
end

local function isHarvestedFruitItem(instance)
	return instance:GetAttribute(HARVESTED_FRUIT_ITEM_ATTRIBUTE) == true
end

local function getHarvestedFruitItemCount()
	local count = 0
	local seen = {}

	for _, root in ipairs(getHarvestRoots()) do
		for _, instance in ipairs(root:GetDescendants()) do
			if isHarvestedFruitItem(instance) then
				local owner = getHarvestedFruitOwner(instance)

				if owner and not seen[owner] then
					seen[owner] = true
					count += 1
				end
			end
		end
	end

	return count
end

local function refreshHarvestActivity()
	local counter = getPlayerHarvestedFruitCounter()
	local itemCount = getHarvestedFruitItemCount()

	if counter ~= lastHarvestedFruitCounter or itemCount ~= lastHarvestedFruitItemCount then
		lastHarvestedFruitCounter = counter
		lastHarvestedFruitItemCount = itemCount
		lastHarvestChangeTime = os.clock()
	end

	return counter, itemCount
end

local function getHarvestIdleSeconds()
	refreshHarvestActivity()
	return os.clock() - lastHarvestChangeTime
end

local function watchHarvestInstance(instance)
	if not instance or harvestWatchedInstances[instance] then
		return
	end

	harvestWatchedInstances[instance] = true

	instance:GetAttributeChangedSignal(HARVESTED_FRUIT_ITEM_ATTRIBUTE):Connect(function()
		refreshHarvestActivity()
	end)
end

local function watchHarvestRoot(root)
	if not root or harvestWatchedRoots[root] then
		return
	end

	harvestWatchedRoots[root] = true

	watchHarvestInstance(root)

	for _, instance in ipairs(root:GetDescendants()) do
		watchHarvestInstance(instance)
	end

	root.DescendantAdded:Connect(function(instance)
		watchHarvestInstance(instance)
		task.defer(refreshHarvestActivity)
	end)

	root.DescendantRemoving:Connect(function()
		task.defer(refreshHarvestActivity)
	end)
end

local function startHarvestTracker()
	if harvestTrackerStarted then
		return
	end

	harvestTrackerStarted = true

	lastHarvestedFruitCounter = getPlayerHarvestedFruitCounter()
	lastHarvestedFruitItemCount = getHarvestedFruitItemCount()
	lastHarvestChangeTime = os.clock()

	player:GetAttributeChangedSignal(HARVESTED_FRUITS_PLAYER_ATTRIBUTE):Connect(function()
		refreshHarvestActivity()
	end)

	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	watchHarvestRoot(backpack)

	if player.Character then
		watchHarvestRoot(player.Character)
	end

	player.CharacterAdded:Connect(function(character)
		task.wait(0.5)
		watchHarvestRoot(character)
		refreshHarvestActivity()
	end)

	refreshHarvestActivity()
end

-- Pure KG check — does NOT care about growth stage.
-- A fruit is "good" or "bad" by weight alone, the moment it has a KG value.
-- This is what makes good-fruit counting behave the same as bad-fruit counting.
local function passesKg(fruitData)
	if not kgFilterEnabled then
		return true
	end

	if kgMode == "Above" then
		return fruitData.KG > kgThreshold
	elseif kgMode == "Below" then
		return fruitData.KG < kgThreshold
	end

	return true
end

local function fruitFailsKg(fruitData)
	return not passesKg(fruitData)
end

local function getNumberAttributeDeep(instance, attributeName)
	if not instance then
		return nil
	end

	local current = instance

	while current and current ~= game do
		local value = current:GetAttribute(attributeName)

		if typeof(value) == "number" then
			return value
		elseif typeof(value) == "string" then
			local numberValue = tonumber(value)
			if numberValue then
				return numberValue
			end
		end

		current = current.Parent
	end

	-- Stats-only fallback:
	-- Some fruit models put Age/MaxAge on a child instead of the SizeMulti instance.
	local model = instance:IsA("Model") and instance or instance:FindFirstAncestorOfClass("Model")

	if model then
		for _, obj in ipairs(model:GetDescendants()) do
			local value = obj:GetAttribute(attributeName)

			if typeof(value) == "number" then
				return value
			elseif typeof(value) == "string" then
				local numberValue = tonumber(value)
				if numberValue then
					return numberValue
				end
			end
		end
	end

	return nil
end

local function getStatsFruitKey(instance)
	-- Keep this safe: do not use plant ancestor as the key.
	-- Prefer the exact SizeMulti instance, then a very close model only if it also has SizeMulti.
	if not instance then
		return nil
	end

	if instance:GetAttribute("SizeMulti") ~= nil then
		return instance
	end

	local model = instance:FindFirstAncestorOfClass("Model")

	if model and model:GetAttribute("SizeMulti") ~= nil then
		return model
	end

	return instance
end

local function findMoonBloomFruitsForStats()
	local rawFruits = findMoonBloomFruits()
	local fruits = {}
	local seen = {}

	for _, fruitData in ipairs(rawFruits) do
		local instance = fruitData.Instance
		local key = getStatsFruitKey(instance)

		if key and not seen[key] then
			seen[key] = true

			local age = getNumberAttributeDeep(instance, "Age")
			local maxAge = getNumberAttributeDeep(instance, "MaxAge")
			local fullyGrown = fruitData.FullyGrown

			if age and maxAge then
				fullyGrown = age >= maxAge
			end

			table.insert(fruits, {
				Instance = instance,
				SizeMulti = fruitData.SizeMulti,
				KG = fruitData.KG,
				Age = age or fruitData.Age,
				MaxAge = maxAge or fruitData.MaxAge,
				FullyGrown = fullyGrown
			})
		end
	end

	return fruits
end

local function getHarvestSessionCounts()
	local fruits = findMoonBloomFruits()

	local fullyGrownCount = 0
	local badKgCount = 0
	local unfinishedCount = 0

	for _, fruitData in ipairs(fruits) do
		if fruitData.FullyGrown then
			fullyGrownCount += 1

			if fruitFailsKg(fruitData) then
				badKgCount += 1
			end
		else
			unfinishedCount += 1
		end
	end

	return fullyGrownCount, badKgCount, unfinishedCount
end

local function getRipeBadKgCount()
	local _, badKgCount = getHarvestSessionCounts()
	return badKgCount
end

-- Single source of truth for the stats panel.
-- Four MUTUALLY EXCLUSIVE buckets (every fruit falls into exactly one):
--   goodRipeCount    - fully grown, passes KG (nothing to do, stays uncollected)
--   goodGrowingCount - not fully grown yet, but already weighs enough to pass
--   badRipeCount     - fully grown, fails KG -> THIS is what blocks the next watering
--   badGrowingCount  - fails KG right now, but still growing -> does NOT block yet
-- badRipeCount here always matches the "waiting for N bad KG fruit(s)" status message,
-- because that message is generated from the exact same fully-grown+fails-KG condition.
local function getFullFruitBreakdown()
	local fruits = findMoonBloomFruitsForStats()
	local total = #fruits
	local goodRipeCount = 0
	local goodGrowingCount = 0
	local badRipeCount = 0
	local badGrowingCount = 0
	local missingGrowthDataCount = 0

	for _, fruitData in ipairs(fruits) do
		local good = passesKg(fruitData)
		local hasGrowthData = fruitData.Age ~= nil and fruitData.MaxAge ~= nil

		if not hasGrowthData then
			missingGrowthDataCount += 1
		end

		if fruitData.FullyGrown then
			if good then
				goodRipeCount += 1
			else
				badRipeCount += 1
			end
		else
			if good then
				goodGrowingCount += 1
			else
				badGrowingCount += 1
			end
		end
	end

	return total, goodRipeCount, goodGrowingCount, badRipeCount, badGrowingCount, missingGrowthDataCount
end

local function startWaterSession()
	task.wait(SESSION_CAPTURE_DELAY)

	if not masterEnabled or not enabled then
		waitingForCollection = false
		wateredForCurrentCondition = false
		return
	end

	sessionFullyGrownCount, sessionBadKgCount = getHarvestSessionCounts()
	sessionStartedAt = os.clock()

	-- Snapshot both harvest signals at the start of the session.
	sessionStartHarvestedFruitCounter = getPlayerHarvestedFruitCounter()
	sessionStartHarvestedFruitItemCount = getHarvestedFruitItemCount()
	lastHarvestedFruitCounter = sessionStartHarvestedFruitCounter
	lastHarvestedFruitItemCount = sessionStartHarvestedFruitItemCount
	lastHarvestChangeTime = os.clock()

	waitingForCollection = true
	wateredForCurrentCondition = true
end

local function collectionSessionFinished()
	if not waitingForCollection then
		return true, "No active collection session."
	end

	local elapsed = os.clock() - sessionStartedAt

	if elapsed < GROWTH_SETTLE_TIME then
		return false,
			string.format(
				"Watered once. Waiting %.1fs for growth to settle.",
				GROWTH_SETTLE_TIME - elapsed
			)
	end

	local harvestedCounter, harvestedItemCount = refreshHarvestActivity()
	local idleSeconds = getHarvestIdleSeconds()

	-- Completion is based on BOTH harvest signals being idle:
	-- player HarvestedFruits counter and inventory HarvestedFruit items.
	-- No ripe/bad KG fruit count is used here.
	if idleSeconds < HARVEST_IDLE_SECONDS then
		return false,
			string.format(
				"Harvest active. Counter %d | Items %d | idle %.1fs / %.1fs.",
				harvestedCounter,
				harvestedItemCount,
				idleSeconds,
				HARVEST_IDLE_SECONDS
			)
	end

	waitingForCollection = false
	wateredForCurrentCondition = false

	return true, "Harvest signals idle. Ready to water again."
end

local function checkKgCondition()
	local fruits = findMoonBloomFruits()
	local total = #fruits

	if not kgFilterEnabled then
		return true, total, total, "KG filter disabled."
	end

	if total == 0 then
		return true, 0, 0, "No Moon/Hypno Bloom fruits found. Continuing automation."
	end

	local passing = 0
	local failingFullyGrown = 0
	local failingGrowing = 0
	local notFullyGrown = 0

	for _, fruitData in ipairs(fruits) do
		if not fruitData.FullyGrown then
			notFullyGrown += 1

			if fruitFailsKg(fruitData) then
				failingGrowing += 1
			else
				passing += 1
			end

			continue
		end

		if fruitFailsKg(fruitData) then
			failingFullyGrown += 1
		else
			passing += 1
		end
	end

	if failingFullyGrown > 0 then
		return true, total, passing,
			"Ripe bad KG fruit(s): " .. failingFullyGrown .. ". Harvest idle controls next water."
	end

	if failingGrowing > 0 then
		return true, total, passing,
			"Bad growing fruit(s): " .. failingGrowing .. ". Watering allowed."
	end

	if notFullyGrown > 0 then
		return true, total, passing, "Some fruits are not fully grown. Watering allowed."
	end

	return true, total, passing, "KG condition passed."
end

local function getFruitPlantRatio()
	local fruits = findMoonBloomFruits()
	local plants = findMoonBloomPlants()

	local goodFruitCount = 0
	local plantCount = #plants
	local ratio = 0

	for _, fruitData in ipairs(fruits) do
		-- Important:
		-- Ratio counts any fruit that PASSES the KG filter, regardless of growth stage.
		-- Bad KG Moon/Hypno fruits should be collected, so they should NOT count toward stop ratio.
		if passesKg(fruitData) then
			goodFruitCount += 1
		end
	end

	if plantCount > 0 then
		ratio = goodFruitCount / plantCount
	end

	return goodFruitCount, plantCount, ratio
end

local function getCurrentPlantCount()
	local plants = findMoonBloomPlants()
	return #plants
end

local function plantCountRequirementMet()
	return getCurrentPlantCount() >= MIN_PLANTS_TO_START
end


local function getSelectedCount(tbl)
	local count = 0

	for _, selected in pairs(tbl) do
		if selected then
			count += 1
		end
	end

	return count
end

local function equipTool(toolName)
	local character = player.Character or player.CharacterAdded:Wait()
	local backpack = player:WaitForChild("Backpack")
	local humanoid = character:WaitForChild("Humanoid")

	local tool = character:FindFirstChild(toolName)

	if tool then
		return tool
	end

	tool = backpack:FindFirstChild(toolName)

	if not tool then
		return nil
	end

	humanoid:EquipTool(tool)

	local equippedTool = character:WaitForChild(toolName, 2)
	return equippedTool
end

local function findSprinklerNearPlant(sprinklerName, plantPosition)
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:GetAttribute("SprinklerName") == sprinklerName then
			local sprinklerPosition = getPosition(descendant)

			if sprinklerPosition then
				local distance = (sprinklerPosition - plantPosition).Magnitude

				if distance <= SPRINKLER_CHECK_RADIUS then
					return descendant
				end
			end
		end
	end

	return nil
end

local function waitForSprinklerNearPlant(sprinklerName, plantPosition, timeout)
	local startTime = os.clock()

	while masterEnabled and enabled and os.clock() - startTime < timeout do
		local sprinkler = findSprinklerNearPlant(sprinklerName, plantPosition)

		if sprinkler then
			return sprinkler
		end

		task.wait(0.25)
	end

	return nil
end

local function placeSprinkler(sprinklerName, plantPosition)
	if not masterEnabled or not enabled then
		return false, "Force stopped."
	end

	local sprinklerTool = equipTool(sprinklerName)

	if not sprinklerTool then
		return false, sprinklerName .. " not found or could not be equipped."
	end

	Event:FireServer(
		makeItemBuffer(SPRINKLER_PACKET_ID, plantPosition, sprinklerName, 1),
		{
			sprinklerTool
		}
	)

	return true, "Placed " .. sprinklerName .. "."
end

local function ensureSelectedSprinklers(plantPosition, setStatus)
	if getSelectedCount(selectedSprinklers) == 0 then
		return false, "Select at least one sprinkler."
	end

	for _, sprinklerName in ipairs(SPRINKLER_NAMES) do
		if not masterEnabled or not enabled then
			return false, "Force stopped."
		end

		if selectedSprinklers[sprinklerName] then
			setStatus("Checking " .. sprinklerName .. "...")

			local existing = findSprinklerNearPlant(sprinklerName, plantPosition)

			if not existing then
				setStatus(sprinklerName .. " missing. Equipping and placing...")

				local placed, placeMessage = placeSprinkler(sprinklerName, plantPosition)
				setStatus(placeMessage)

				if not placed then
					return false, placeMessage
				end

				local confirmed = waitForSprinklerNearPlant(
					sprinklerName,
					plantPosition,
					SPRINKLER_PLACE_WAIT_TIME
				)

				if not confirmed then
					return false, sprinklerName .. " was not confirmed near plant."
				end
			end
		end
	end

	return true, "Selected sprinklers confirmed."
end

local function waterWithSelectedCans(plantPosition, setStatus)
	if getSelectedCount(selectedWateringCans) == 0 then
		return false, "Select at least one watering can."
	end

	local wateredAny = false

	for _, wateringCanName in ipairs(WATERING_CAN_NAMES) do
		if not masterEnabled or not enabled then
			return false, "Force stopped."
		end

		if selectedWateringCans[wateringCanName] then
			setStatus("Equipping " .. wateringCanName .. "...")

			local wateringCan = equipTool(wateringCanName)

			if not wateringCan then
				return false, wateringCanName .. " not found or could not be equipped."
			end

			Event:FireServer(
				makeItemBuffer(WATERING_CAN_PACKET_ID, plantPosition, wateringCanName),
				{
					wateringCan
				}
			)

			wateredAny = true
			task.wait(0.15)
		end
	end

	if wateredAny then
		return true, "Watered once with selected watering can(s)."
	end

	return false, "No watering can was used."
end

-- ============================================================
-- UI
-- ============================================================

local ACCENT_GOLD = Color3.fromRGB(255, 205, 110)
local ACCENT_PURPLE = Color3.fromRGB(120, 90, 220)
local ACCENT_BLUE = Color3.fromRGB(70, 110, 220)
local PANEL_COLOR = Color3.fromRGB(32, 32, 40)
local GOOD_COLOR = "rgb(120,230,140)"
local BAD_COLOR = "rgb(255,110,110)"
local WARN_COLOR = "rgb(255,220,120)"

local gui = Instance.new("ScreenGui")
gui.Name = "BloomAutomationUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 340, 0, 480)
frame.AnchorPoint = Vector2.new(0, 0)
frame.Position = UDim2.new(0, 4, 0, 34)
frame.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
frame.BackgroundTransparency = 0.05
frame.BorderSizePixel = 0
frame.Parent = gui

-- Extra small phone fit.
-- Keeps the original control layout, then scales the whole panel down for tiny screens.
local uiScale = Instance.new("UIScale")
uiScale.Name = "PhoneTinyScale"
uiScale.Scale = 0.78
uiScale.Parent = frame

local BASE_UI_WIDTH = 340
local BASE_UI_HEIGHT = 480
local MIN_UI_SCALE = 0.48
local MAX_UI_SCALE = 0.82

local function updatePhoneScale()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(360, 640)

	local safeWidth = math.max(180, viewport.X - 8)
	local safeHeight = math.max(240, viewport.Y - 48)

	local scaleX = safeWidth / BASE_UI_WIDTH
	local scaleY = safeHeight / BASE_UI_HEIGHT
	local scale = math.clamp(math.min(scaleX, scaleY, MAX_UI_SCALE), MIN_UI_SCALE, MAX_UI_SCALE)

	uiScale.Scale = scale

	local scaledWidth = BASE_UI_WIDTH * scale
	local scaledHeight = BASE_UI_HEIGHT * scale

	local x = 4
	local y = 34

	if scaledHeight > viewport.Y - 8 then
		y = 4
	end

	frame.Position = UDim2.fromOffset(
		math.clamp(x, 0, math.max(0, viewport.X - scaledWidth)),
		math.clamp(y, 0, math.max(0, viewport.Y - scaledHeight))
	)
end

updatePhoneScale()

if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updatePhoneScale)
end

local frameCorner = Instance.new("UICorner")
frameCorner.CornerRadius = UDim.new(0, 10)
frameCorner.Parent = frame

local frameStroke = Instance.new("UIStroke")
frameStroke.Color = ACCENT_GOLD
frameStroke.Transparency = 0.55
frameStroke.Thickness = 1.5
frameStroke.Parent = frame

local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(40, 35, 60)
topBar.BorderSizePixel = 0
topBar.Parent = frame

local topCorner = Instance.new("UICorner")
topCorner.CornerRadius = UDim.new(0, 10)
topCorner.Parent = topBar

local topBarGradient = Instance.new("UIGradient")
topBarGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, ACCENT_PURPLE),
	ColorSequenceKeypoint.new(1, ACCENT_BLUE)
})
topBarGradient.Rotation = 0
topBarGradient.Parent = topBar

local topBarCoverBottom = Instance.new("Frame")
topBarCoverBottom.Size = UDim2.new(1, 0, 0, 10)
topBarCoverBottom.Position = UDim2.new(0, 0, 1, -10)
topBarCoverBottom.BackgroundColor3 = topBar.BackgroundColor3
topBarCoverBottom.BorderSizePixel = 0
topBarCoverBottom.ZIndex = 1
topBarCoverBottom.Parent = topBar
local topBarGradient2 = Instance.new("UIGradient")
topBarGradient2.Color = topBarGradient.Color
topBarGradient2.Parent = topBarCoverBottom

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Text = "🌙 Moon/Hypno Bloom Automation"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 12
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.ZIndex = 2
title.Parent = topBar

local minimizeButton = Instance.new("TextButton")
minimizeButton.Size = UDim2.new(0, 28, 0, 24)
minimizeButton.Position = UDim2.new(1, -64, 0, 6)
minimizeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
minimizeButton.Text = "-"
minimizeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
minimizeButton.TextSize = 18
minimizeButton.Font = Enum.Font.GothamBold
minimizeButton.ZIndex = 2
minimizeButton.Parent = topBar

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.new(0, 28, 0, 24)
closeButton.Position = UDim2.new(1, -32, 0, 6)
closeButton.BackgroundColor3 = Color3.fromRGB(150, 55, 55)
closeButton.Text = "X"
closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
closeButton.TextSize = 13
closeButton.Font = Enum.Font.GothamBold
closeButton.ZIndex = 2
closeButton.Parent = topBar

local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, 0, 1, -36)
body.Position = UDim2.new(0, 0, 0, 36)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 4
body.ScrollBarImageColor3 = ACCENT_GOLD
body.ScrollingDirection = Enum.ScrollingDirection.Y
body.CanvasSize = UDim2.new(0, 0, 0, 700)
body.AutomaticCanvasSize = Enum.AutomaticSize.None
body.Parent = frame

local function addCorner(instance, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 6)
	corner.Parent = instance
end

local function addStroke(instance, color, transparency, thickness)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Color3.fromRGB(70, 70, 85)
	stroke.Transparency = transparency or 0.6
	stroke.Thickness = thickness or 1
	stroke.Parent = instance
	return stroke
end

local function addSectionPanel(yTop, height, labelText, labelColor)
	local panel = Instance.new("Frame")
	panel.Size = UDim2.new(0, 320, 0, height)
	panel.Position = UDim2.new(0, 10, 0, yTop)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.ZIndex = 0
	panel.Parent = body
	addCorner(panel, 8)
	addStroke(panel, Color3.fromRGB(70, 70, 90), 0.7, 1)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0, 300, 0, 16)
	label.Position = UDim2.new(0, 10, 0, yTop + 4)
	label.BackgroundTransparency = 1
	label.Text = labelText
	label.TextColor3 = labelColor or ACCENT_GOLD
	label.TextSize = 11
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 1
	label.Parent = body

	return panel
end

addCorner(minimizeButton, 5)
addCorner(closeButton, 5)

-- SECTION A: Automation Controls (panel: y=2, height=64)
addSectionPanel(2, 64, "⚙  AUTOMATION CONTROLS", ACCENT_GOLD)

local masterButton = Instance.new("TextButton")
masterButton.Size = UDim2.new(0, 150, 0, 34)
masterButton.Position = UDim2.new(0, 10, 0, 24)
masterButton.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
masterButton.TextColor3 = Color3.fromRGB(255, 255, 255)
masterButton.TextSize = 12
masterButton.Font = Enum.Font.GothamBold
masterButton.Text = "Master: ON"
masterButton.Parent = body
addCorner(masterButton, 6)
addStroke(masterButton)

local toggleButton = Instance.new("TextButton")
toggleButton.Size = UDim2.new(0, 150, 0, 34)
toggleButton.Position = UDim2.new(0, 180, 0, 24)
toggleButton.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleButton.TextSize = 12
toggleButton.Font = Enum.Font.GothamBold
toggleButton.Text = "Auto: OFF"
toggleButton.Parent = body
addCorner(toggleButton, 6)
addStroke(toggleButton)

-- SECTION B: KG Filter (panel: y=76, height=92)
addSectionPanel(76, 92, "⚖  KG FILTER", ACCENT_GOLD)

local kgLabel = Instance.new("TextLabel")
kgLabel.Size = UDim2.new(0, 140, 0, 26)
kgLabel.Position = UDim2.new(0, 10, 0, 98)
kgLabel.BackgroundTransparency = 1
kgLabel.Text = "KG threshold:"
kgLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
kgLabel.TextSize = 12
kgLabel.Font = Enum.Font.Gotham
kgLabel.TextXAlignment = Enum.TextXAlignment.Left
kgLabel.Parent = body

local kgBox = Instance.new("TextBox")
kgBox.Size = UDim2.new(0, 90, 0, 26)
kgBox.Position = UDim2.new(0, 240, 0, 98)
kgBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
kgBox.TextColor3 = Color3.fromRGB(255, 255, 255)
kgBox.TextSize = 12
kgBox.Font = Enum.Font.Gotham
kgBox.Text = tostring(kgThreshold)
kgBox.ClearTextOnFocus = false
kgBox.Parent = body
addCorner(kgBox, 5)
addStroke(kgBox)

local aboveButton = Instance.new("TextButton")
aboveButton.Size = UDim2.new(0, 150, 0, 30)
aboveButton.Position = UDim2.new(0, 10, 0, 132)
aboveButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
aboveButton.TextColor3 = Color3.fromRGB(255, 255, 255)
aboveButton.TextSize = 12
aboveButton.Font = Enum.Font.GothamBold
aboveButton.Text = "Above: OFF"
aboveButton.Parent = body
addCorner(aboveButton, 6)
addStroke(aboveButton)

local belowButton = Instance.new("TextButton")
belowButton.Size = UDim2.new(0, 150, 0, 30)
belowButton.Position = UDim2.new(0, 180, 0, 132)
belowButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
belowButton.TextColor3 = Color3.fromRGB(255, 255, 255)
belowButton.TextSize = 12
belowButton.Font = Enum.Font.GothamBold
belowButton.Text = "Below: OFF"
belowButton.Parent = body
addCorner(belowButton, 6)
addStroke(belowButton)

-- SECTION C: Ratio Auto Control (panel: y=178, height=150)
addSectionPanel(178, 150, "📊  RATIO AUTO-CONTROL", ACCENT_GOLD)

local ratioToggleButton = Instance.new("TextButton")
ratioToggleButton.Size = UDim2.new(0, 320, 0, 30)
ratioToggleButton.Position = UDim2.new(0, 10, 0, 200)
ratioToggleButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
ratioToggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
ratioToggleButton.TextSize = 12
ratioToggleButton.Font = Enum.Font.GothamBold
ratioToggleButton.Text = "Ratio Auto: OFF"
ratioToggleButton.Parent = body
addCorner(ratioToggleButton, 6)
addStroke(ratioToggleButton)

local startRatioLabel = Instance.new("TextLabel")
startRatioLabel.Size = UDim2.new(0, 120, 0, 26)
startRatioLabel.Position = UDim2.new(0, 10, 0, 236)
startRatioLabel.BackgroundTransparency = 1
startRatioLabel.Text = "Start below:"
startRatioLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
startRatioLabel.TextSize = 12
startRatioLabel.Font = Enum.Font.Gotham
startRatioLabel.TextXAlignment = Enum.TextXAlignment.Left
startRatioLabel.Parent = body

local startRatioBox = Instance.new("TextBox")
startRatioBox.Size = UDim2.new(0, 90, 0, 26)
startRatioBox.Position = UDim2.new(0, 240, 0, 236)
startRatioBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
startRatioBox.TextColor3 = Color3.fromRGB(255, 255, 255)
startRatioBox.TextSize = 12
startRatioBox.Font = Enum.Font.Gotham
startRatioBox.Text = tostring(startBelowRatio)
startRatioBox.ClearTextOnFocus = false
startRatioBox.Parent = body
addCorner(startRatioBox, 5)
addStroke(startRatioBox)

local stopRatioLabel = Instance.new("TextLabel")
stopRatioLabel.Size = UDim2.new(0, 120, 0, 26)
stopRatioLabel.Position = UDim2.new(0, 10, 0, 268)
stopRatioLabel.BackgroundTransparency = 1
stopRatioLabel.Text = "Stop above:"
stopRatioLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
stopRatioLabel.TextSize = 12
stopRatioLabel.Font = Enum.Font.Gotham
stopRatioLabel.TextXAlignment = Enum.TextXAlignment.Left
stopRatioLabel.Parent = body

local stopRatioBox = Instance.new("TextBox")
stopRatioBox.Size = UDim2.new(0, 90, 0, 26)
stopRatioBox.Position = UDim2.new(0, 240, 0, 268)
stopRatioBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
stopRatioBox.TextColor3 = Color3.fromRGB(255, 255, 255)
stopRatioBox.TextSize = 12
stopRatioBox.Font = Enum.Font.Gotham
stopRatioBox.Text = tostring(stopAboveRatio)
stopRatioBox.ClearTextOnFocus = false
stopRatioBox.Parent = body
addCorner(stopRatioBox, 5)
addStroke(stopRatioBox)

local ratioText = Instance.new("TextLabel")
ratioText.Size = UDim2.new(0, 300, 0, 42)
ratioText.Position = UDim2.new(0, 10, 0, 298)
ratioText.BackgroundTransparency = 1
ratioText.Text = "Ratio: 0 good fruits / 0 plants = 0.00%"
ratioText.TextColor3 = ACCENT_GOLD
ratioText.TextSize = 11
ratioText.Font = Enum.Font.Code
ratioText.TextXAlignment = Enum.TextXAlignment.Left
ratioText.Parent = body

-- SECTION D: Sprinklers (panel: y=336, height=126)
addSectionPanel(336, 126, "💧  SPRINKLERS TO PLACE", ACCENT_GOLD)

local sprinklerButtons = {}

for index, sprinklerName in ipairs(SPRINKLER_NAMES) do
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, 150, 0, 28)

	local row = math.floor((index - 1) / 2)
	local col = (index - 1) % 2

	button.Position = UDim2.new(0, 10 + (col * 160), 0, 358 + (row * 32))
	button.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 12
	button.Font = Enum.Font.GothamBold
	button.Text = sprinklerName
	button.Parent = body
	addCorner(button, 6)
	addStroke(button)

	sprinklerButtons[sprinklerName] = button

	button.MouseButton1Click:Connect(function()
		selectedSprinklers[sprinklerName] = not selectedSprinklers[sprinklerName]
		wateredForCurrentCondition = false
		waitingForCollection = false
	end)
end

-- SECTION E: Watering Cans (panel: y=468, height=58)
addSectionPanel(468, 58, "🚿  WATERING CANS TO USE", ACCENT_GOLD)

local wateringButtons = {}

for index, wateringCanName in ipairs(WATERING_CAN_NAMES) do
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, 150, 0, 28)
	button.Position = UDim2.new(0, 10 + ((index - 1) * 160), 0, 490)
	button.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 12
	button.Font = Enum.Font.GothamBold
	button.Text = wateringCanName
	button.Parent = body
	addCorner(button, 6)
	addStroke(button)

	wateringButtons[wateringCanName] = button

	button.MouseButton1Click:Connect(function()
		selectedWateringCans[wateringCanName] = not selectedWateringCans[wateringCanName]
		wateredForCurrentCondition = false
		waitingForCollection = false
	end)
end

-- SECTION F: Stats & Status (panel: y=534, height=152)
addSectionPanel(534, 152, "📈  STATS & STATUS", ACCENT_GOLD)

local fruitText = Instance.new("TextLabel")
fruitText.Size = UDim2.new(0, 300, 0, 66)
fruitText.Position = UDim2.new(0, 10, 0, 556)
fruitText.BackgroundTransparency = 1
fruitText.Text = "Fruits: 0"
fruitText.RichText = true
fruitText.TextColor3 = Color3.fromRGB(200, 220, 255)
fruitText.TextSize = 11
fruitText.Font = Enum.Font.Code
fruitText.TextXAlignment = Enum.TextXAlignment.Left
fruitText.TextYAlignment = Enum.TextYAlignment.Top
fruitText.TextWrapped = true
fruitText.Parent = body

local statusText = Instance.new("TextLabel")
statusText.Size = UDim2.new(0, 300, 0, 56)
statusText.Position = UDim2.new(0, 10, 0, 614)
statusText.BackgroundTransparency = 1
statusText.Text = "Status: Ready"
statusText.TextColor3 = Color3.fromRGB(200, 255, 200)
statusText.TextSize = 11
statusText.Font = Enum.Font.Code
statusText.TextWrapped = true
statusText.TextXAlignment = Enum.TextXAlignment.Left
statusText.TextYAlignment = Enum.TextYAlignment.Top
statusText.Parent = body

local function setStatus(text)
	if statusText and statusText.Parent then
		statusText.Text = "Status: " .. text
	end
end

local function updateMasterButton()
	if masterEnabled then
		masterButton.Text = "Master: ON"
		masterButton.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
	else
		masterButton.Text = "Master: OFF"
		masterButton.BackgroundColor3 = Color3.fromRGB(130, 45, 45)
	end
end

local function updateToggleButton()
	if enabled then
		toggleButton.Text = "Auto: ON"
		toggleButton.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
	else
		toggleButton.Text = "Auto: OFF"
		toggleButton.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
	end
end

local function updateKgButtons()
	if kgFilterEnabled and kgMode == "Above" then
		aboveButton.Text = "Above: ON"
		aboveButton.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
	else
		aboveButton.Text = "Above: OFF"
		aboveButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	end

	if kgFilterEnabled and kgMode == "Below" then
		belowButton.Text = "Below: ON"
		belowButton.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
	else
		belowButton.Text = "Below: OFF"
		belowButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	end
end

local function updateRatioButton()
	if ratioControlEnabled then
		ratioToggleButton.Text = "Ratio Auto: ON"
		ratioToggleButton.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
	else
		ratioToggleButton.Text = "Ratio Auto: OFF"
		ratioToggleButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	end
end

local function updateItemButtons()
	for sprinklerName, button in pairs(sprinklerButtons) do
		if selectedSprinklers[sprinklerName] then
			button.Text = sprinklerName .. ": ON"
			button.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
		else
			button.Text = sprinklerName .. ": OFF"
			button.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
		end
	end

	for wateringCanName, button in pairs(wateringButtons) do
		if selectedWateringCans[wateringCanName] then
			button.Text = wateringCanName .. ": ON"
			button.BackgroundColor3 = Color3.fromRGB(40, 120, 50)
		else
			button.Text = wateringCanName .. ": OFF"
			button.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
		end
	end
end

local function updateFruitDisplay()
	local total, goodRipeCount, goodGrowingCount, badRipeCount, badGrowingCount, missingGrowthDataCount = getFullFruitBreakdown()
	local missingText = ""

	if missingGrowthDataCount and missingGrowthDataCount > 0 then
		missingText = string.format(
			"\n<font color=\"%s\">Missing Age/MaxAge: %d</font>",
			WARN_COLOR,
			missingGrowthDataCount
		)
	end

	fruitText.Text = string.format(
		"Fruits: %d\n<font color=\"%s\">Good Ripe: %d</font> | <font color=\"%s\">Good Growing: %d</font>\n<font color=\"%s\">Bad Ripe: %d</font> | <font color=\"%s\">Bad Growing: %d</font>%s",
		total,
		GOOD_COLOR, goodRipeCount,
		WARN_COLOR, goodGrowingCount,
		BAD_COLOR, badRipeCount,
		WARN_COLOR, badGrowingCount,
		missingText
	)
end

local function updateRatioDisplay()
	local goodFruitCount, plantCount, ratio = getFruitPlantRatio()
	local plantStatus = "WAIT"

	if plantCount >= MIN_PLANTS_TO_START then
		plantStatus = "OK"
	end

	ratioText.Text = string.format(
		"Ratio: %d good fruits / %d plants = %.2f%%\nPlants: %d / %d [%s]",
		goodFruitCount,
		plantCount,
		ratio * 100,
		plantCount,
		MIN_PLANTS_TO_START,
		plantStatus
	)
end

local function applyRatioAutoControl()
	if not masterEnabled then
		return
	end

	if not ratioControlEnabled then
		return
	end

	local goodFruitCount, plantCount, ratio = getFruitPlantRatio()

	if plantCount < MIN_PLANTS_TO_START then
		if enabled then
			enabled = false
			wateredForCurrentCondition = false
			waitingForCollection = false
			setStatus(
				"Plant count too low: " ..
				plantCount ..
				" / " ..
				MIN_PLANTS_TO_START ..
				". Automation stopped."
			)
		end

		return
	end

	if plantCount <= 0 then
		return
	end

	if goodFruitCount ~= lastRatioGoodFruitCount or plantCount ~= lastRatioPlantCount then
		if not waitingForCollection then
			wateredForCurrentCondition = false
		end
	end

	lastRatioGoodFruitCount = goodFruitCount
	lastRatioPlantCount = plantCount

	if not enabled and ratio < startBelowRatio then
		enabled = true
		wateredForCurrentCondition = false
		waitingForCollection = false

		setStatus(
			string.format(
				"Good fruit ratio %.2f%% below %.2f%%. Auto-started.",
				ratio * 100,
				startBelowRatio * 100
			)
		)
	elseif enabled and ratio > stopAboveRatio then
		enabled = false
		wateredForCurrentCondition = false
		waitingForCollection = false

		setStatus(
			string.format(
				"Good fruit ratio %.2f%% above %.2f%%. Auto-stopped.",
				ratio * 100,
				stopAboveRatio * 100
			)
		)
	end
end

kgBox.FocusLost:Connect(function()
	local value = tonumber(kgBox.Text)

	if value and value >= 0 then
		kgThreshold = value
		kgBox.Text = tostring(kgThreshold)
		wateredForCurrentCondition = false
		waitingForCollection = false
		setStatus("KG threshold set to " .. kgThreshold .. ".")
	else
		kgBox.Text = tostring(kgThreshold)
		setStatus("Invalid KG threshold.")
	end
end)

aboveButton.MouseButton1Click:Connect(function()
	if kgFilterEnabled and kgMode == "Above" then
		kgFilterEnabled = false
	else
		kgFilterEnabled = true
		kgMode = "Above"
	end

	wateredForCurrentCondition = false
	waitingForCollection = false
	updateKgButtons()
end)

belowButton.MouseButton1Click:Connect(function()
	if kgFilterEnabled and kgMode == "Below" then
		kgFilterEnabled = false
	else
		kgFilterEnabled = true
		kgMode = "Below"
	end

	wateredForCurrentCondition = false
	waitingForCollection = false
	updateKgButtons()
end)

ratioToggleButton.MouseButton1Click:Connect(function()
	ratioControlEnabled = not ratioControlEnabled
	wateredForCurrentCondition = false
	waitingForCollection = false
	updateRatioButton()

	if ratioControlEnabled then
		setStatus("Ratio auto-control enabled.")
	else
		setStatus("Ratio auto-control disabled.")
	end
end)

startRatioBox.FocusLost:Connect(function()
	local value = tonumber(startRatioBox.Text)

	if value and value >= 0 then
		if value > 1 then
			value = value / 100
		end

		startBelowRatio = value
		startRatioBox.Text = tostring(startBelowRatio)
		wateredForCurrentCondition = false
		waitingForCollection = false

		setStatus("Start below ratio set to " .. tostring(startBelowRatio * 100) .. "%.")
	else
		startRatioBox.Text = tostring(startBelowRatio)
		setStatus("Invalid start ratio.")
	end
end)

stopRatioBox.FocusLost:Connect(function()
	local value = tonumber(stopRatioBox.Text)

	if value and value >= 0 then
		if value > 1 then
			value = value / 100
		end

		stopAboveRatio = value
		stopRatioBox.Text = tostring(stopAboveRatio)
		wateredForCurrentCondition = false
		waitingForCollection = false

		setStatus("Stop above ratio set to " .. tostring(stopAboveRatio * 100) .. "%.")
	else
		stopRatioBox.Text = tostring(stopAboveRatio)
		setStatus("Invalid stop ratio.")
	end
end)

masterButton.MouseButton1Click:Connect(function()
	masterEnabled = not masterEnabled

	if not masterEnabled then
		enabled = false
		wateredForCurrentCondition = false
		waitingForCollection = false
		setStatus("Master OFF. Automation force-stopped.")
	else
		setStatus("Master ON. Ratio auto can start automation if conditions match.")
	end

	updateMasterButton()
	updateToggleButton()
end)

toggleButton.MouseButton1Click:Connect(function()
	if not masterEnabled then
		enabled = false
		wateredForCurrentCondition = false
		waitingForCollection = false
		updateToggleButton()
		setStatus("Master is OFF. Turn Master ON before enabling automation.")
		return
	end

	local currentPlantCount = getCurrentPlantCount()

	if not enabled and currentPlantCount < MIN_PLANTS_TO_START then
		enabled = false
		wateredForCurrentCondition = false
		waitingForCollection = false
		updateToggleButton()
		setStatus(
			"Cannot start yet. Plants: " ..
			currentPlantCount ..
			" / " ..
			MIN_PLANTS_TO_START ..
			"."
		)
		return
	end

	enabled = not enabled
	wateredForCurrentCondition = false
	waitingForCollection = false
	updateToggleButton()

	if enabled then
		setStatus("Manually enabled. Waiting for condition...")
	else
		setStatus("Manually disabled.")
	end
end)

minimizeButton.MouseButton1Click:Connect(function()
	minimized = not minimized

	if minimized then
		body.Visible = false
		frame.Size = UDim2.new(0, 340, 0, 36)
		minimizeButton.Text = "+"
	else
		body.Visible = true
		frame.Size = UDim2.new(0, 340, 0, 480)
		minimizeButton.Text = "-"
	end

	updatePhoneScale()
end)

closeButton.MouseButton1Click:Connect(function()
	masterEnabled = false
	enabled = false
	gui:Destroy()
end)

-- Draggable UI
local dragging = false
local dragStart = nil
local startPosition = nil

topBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPosition = frame.Position
	end
end)

topBar.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart

		frame.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end
end)

local function automationLoop()
	if loopRunning then
		return
	end

	loopRunning = true

	while gui.Parent do
		updateItemButtons()
		updateKgButtons()
		updateRatioButton()
		updateMasterButton()
		updateToggleButton()
		updateRatioDisplay()

		if not masterEnabled then
			enabled = false
			wateredForCurrentCondition = false
			waitingForCollection = false
			setStatus("Master OFF. Automation force-stopped.")
			task.wait(CHECK_DELAY)
			continue
		end

		applyRatioAutoControl()

		local kgAllowed, totalFruits, passingFruits, kgMessage = checkKgCondition()
		updateFruitDisplay()

		if not enabled then
			task.wait(CHECK_DELAY)
			continue
		end

		local activePlantCount = getCurrentPlantCount()

		if activePlantCount < MIN_PLANTS_TO_START then
			enabled = false
			wateredForCurrentCondition = false
			waitingForCollection = false
			setStatus(
				"Plant count below requirement: " ..
				activePlantCount ..
				" / " ..
				MIN_PLANTS_TO_START ..
				". Automation stopped."
			)

			task.wait(CHECK_DELAY)
			continue
		end

		if waitingForCollection then
			local sessionDone, sessionMessage = collectionSessionFinished()
			setStatus(sessionMessage)

			if not sessionDone then
				task.wait(CHECK_DELAY)
				continue
			end
		end

		-- Do not start a new water session while harvest signals are still changing.
		-- Uses BOTH player HarvestedFruits and inventory HarvestedFruit items.
		local harvestIdleSeconds = getHarvestIdleSeconds()

		if harvestIdleSeconds < HARVEST_IDLE_SECONDS then
			wateredForCurrentCondition = false
			setStatus(
				string.format(
					"Waiting harvest idle. %.1fs / %.1fs.",
					harvestIdleSeconds,
					HARVEST_IDLE_SECONDS
				)
			)

			task.wait(CHECK_DELAY)
			continue
		end

		if not kgAllowed then
			wateredForCurrentCondition = false
			setStatus(kgMessage)
			task.wait(CHECK_DELAY)
			continue
		end

		if wateredForCurrentCondition then
			setStatus("Already watered once. Waiting for collection/reset...")
			task.wait(CHECK_DELAY)
			continue
		end

		local plant = findMoonBloomPlant()

		if not plant then
			wateredForCurrentCondition = false
			setStatus("No Moon/Hypno Bloom plant found.")
			task.wait(CHECK_DELAY)
			continue
		end

		local plantPosition = getPosition(plant)

		if not plantPosition then
			wateredForCurrentCondition = false
			setStatus("Could not get Moon/Hypno Bloom position.")
			task.wait(CHECK_DELAY)
			continue
		end

		setStatus(kgMessage)

		local sprinklersReady, sprinklerMessage = ensureSelectedSprinklers(plantPosition, setStatus)

		if not sprinklersReady then
			setStatus(sprinklerMessage)
			task.wait(CHECK_DELAY)
			continue
		end

		setStatus("Super Sprinkler ready. Watering once...")

		local watered, waterMessage = waterWithSelectedCans(plantPosition, setStatus)
		setStatus(waterMessage)

		if watered then
			setStatus("Watered once. Starting collection wait session...")
			startWaterSession()
		end

		task.wait(CHECK_DELAY)
	end

	loopRunning = false
end

startHarvestTracker()

task.spawn(automationLoop)

updateMasterButton()
updateToggleButton()
updateKgButtons()
updateRatioButton()
updateItemButtons()
updateRatioDisplay()
updateFruitDisplay()
setStatus("Ready. Tiny phone UI enabled. Scroll for all controls.")