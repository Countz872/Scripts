-- TEB Hub
-- Combined: Bloom Automation, Fruit Multi-Mailer, Optimization + Counter, Auto Rejoin
-- Run as one client script.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TEB_HUB_VERSION = "1.2.0"

-- NEVER include the script version in these cloud keys.
-- Keeping them stable preserves player settings across future releases.
local TEB_STABLE_USER_KEY = "TEBHubUser-" .. tostring(player.UserId)
local TEB_LEGACY_BLOOM_KEY = "BloomAutomationUser-" .. tostring(player.UserId)

_G.TEBHubModules = _G.TEBHubModules or {}

local oldHub = playerGui:FindFirstChild("TEBHubUI")
if oldHub then
	oldHub:Destroy()
end


-- ============================================================
-- TEB HUB SCOPED CLOUDFLARE CONFIG
-- Player save takes priority; global default is fallback only.
-- ============================================================
local HttpService = game:GetService("HttpService")
local TEB_CLOUD_ENDPOINT = "https://scripts-gag2.tucodanj.workers.dev"
local TEB_USER_KEY = TEB_STABLE_USER_KEY
local TEB_CLOUD_DEBOUNCE = 1.25
local tebSaveRevisions = {}

local function tebRequestFunction()
	return (syn and syn.request)
		or http_request
		or request
		or (http and http.request)
end

local function tebCloudCall(action, scope, data, keyOverride)
	local requestFn = tebRequestFunction()
	if not requestFn then
		return false, "request/http_request is unavailable."
	end

	local body = {
		key = keyOverride or TEB_USER_KEY,
		userId = tostring(player.UserId),
		scope = tostring(scope or "hub"),
		data = data,
	}

	local ok, response = pcall(function()
		return requestFn({
			Url = TEB_CLOUD_ENDPOINT .. "/" .. action,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["Accept"] = "application/json",
			},
			Body = HttpService:JSONEncode(body),
		})
	end)

	if not ok then
		return false, tostring(response)
	end

	local statusCode = tonumber(response.StatusCode or response.Status or response.status_code) or 0
	local responseBody = response.Body or response.body or ""

	if statusCode < 200 or statusCode >= 300 then
		return false, "HTTP " .. tostring(statusCode) .. ": " .. tostring(responseBody)
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(responseBody)
	end)

	if not decodeOk or type(decoded) ~= "table" then
		return false, "Worker returned invalid JSON."
	end

	if decoded.ok ~= true then
		return false, tostring(decoded.error or "Cloud request failed.")
	end

	return true, decoded
end

local function tebLoadScope(scope)
	local ok, result = tebCloudCall("load", scope)
	if not ok then
		return nil, "error", result
	end

	-- Previous Bloom releases used a different stable user key.
	-- Check it before accepting the global default, then migrate it forward.
	if scope == "bloom" and result.source ~= "user" then
		local legacyOk, legacyResult = tebCloudCall(
			"load",
			scope,
			nil,
			TEB_LEGACY_BLOOM_KEY
		)

		if legacyOk and legacyResult.source == "user" and type(legacyResult.data) == "table" then
			tebCloudCall("save", scope, legacyResult.data)
			return legacyResult.data, "legacy-user-migrated"
		end
	end

	return type(result.data) == "table" and result.data or nil, result.source or "none"
end

local function tebSaveScopeNow(scope, data)
	return tebCloudCall("save", scope, data)
end

local function tebQueueSaveScope(scope, getter)
	tebSaveRevisions[scope] = (tebSaveRevisions[scope] or 0) + 1
	local revision = tebSaveRevisions[scope]

	task.delay(TEB_CLOUD_DEBOUNCE, function()
		if tebSaveRevisions[scope] ~= revision then
			return
		end
		local ok, data = pcall(getter)
		if ok and type(data) == "table" then
			tebSaveScopeNow(scope, data)
		end
	end)
end

local function tebSetDefaultScope(scope, data)
	return tebCloudCall("set-default", scope, data)
end

_G.TEBCloudLoadScope = tebLoadScope
_G.TEBCloudSaveScope = tebSaveScopeNow
_G.TEBCloudQueueSaveScope = tebQueueSaveScope
_G.TEBCloudSetDefaultScope = tebSetDefaultScope
_G.TEBHubCloudSections = _G.TEBHubCloudSections or {}

local MODULE_SOURCES = {
	Bloom = [=[
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

-- Automation lifetime is independent from whether any UI is visible.
local automationAlive = true

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

-- ============================================================
-- CLOUD CONFIG (Cloudflare Worker + KV)
-- ============================================================
local HttpService = game:GetService("HttpService")

-- Each Roblox account automatically gets its own cloud configuration.
-- No device file, HWID, readfile, or writefile is needed.
local ROBLOX_USER_ID = tostring(player.UserId)

local function trim(value)
	return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

-- The Worker hashes this value before using it as a KV key.
-- This prefix keeps the generated key above the Worker's 20-character minimum.
local CLOUD_CONFIG = {
	Enabled = true,
	Endpoint = "https://scripts-gag2.tucodanj.workers.dev",
	SyncKey = TEB_STABLE_USER_KEY,
	AutoLoad = true,
	AutoSave = true,
	SaveDebounceSeconds = 1.25
}

local cloudSaveRevision = 0
local cloudLastError = nil
local cloudLoaded = false
local cloudSaveQueued = false
local savedUiX = 4
local savedUiY = 34

local function getHttpRequestFunction()
	return (syn and syn.request)
		or http_request
		or request
		or (http and http.request)
end

local function getNormalizedCloudEndpoint()
	local endpoint = trim(CLOUD_CONFIG.Endpoint):gsub("/+$", "")

	if not endpoint:match("^https://[%w%-%.]+%.workers%.dev$") then
		return nil
	end

	return endpoint
end

local function cloudIsConfigured()
	return CLOUD_CONFIG.Enabled
		and getNormalizedCloudEndpoint() ~= nil
		and type(CLOUD_CONFIG.SyncKey) == "string"
		and #CLOUD_CONFIG.SyncKey >= 20
end

local function cloudCall(action, data)
	if not cloudIsConfigured() then
		return false, "Cloud config is not configured."
	end

	local requestFunction = getHttpRequestFunction()
	if not requestFunction then
		return false, "This environment does not provide request/http_request."
	end

	local endpoint = getNormalizedCloudEndpoint()
	if not endpoint then
		return false, "Invalid cloud endpoint URL."
	end

	local body = {
		key = CLOUD_CONFIG.SyncKey,
		userId = ROBLOX_USER_ID,
		scope = "bloom",
		data = data
	}

	local ok, response = pcall(function()
		return requestFunction({
			Url = endpoint .. "/" .. action,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json"
			},
			Body = HttpService:JSONEncode(body)
		})
	end)

	if not ok then
		return false, tostring(response)
	end

	local statusCode = tonumber(response.StatusCode or response.Status or response.status_code) or 0
	local responseBody = response.Body or response.body or ""

	if statusCode < 200 or statusCode >= 300 then
		return false, "HTTP " .. tostring(statusCode) .. ": " .. tostring(responseBody)
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(responseBody)
	end)

	if not decodeOk or type(decoded) ~= "table" then
		return false, "Worker returned invalid JSON."
	end

	if decoded.ok ~= true then
		return false, tostring(decoded.error or "Cloud request failed.")
	end

	return true, decoded
end

local function buildCloudSettings()
	return {
		version = 1,
		robloxUserId = ROBLOX_USER_ID,
		masterEnabled = masterEnabled,
		enabled = enabled,
		kgThreshold = kgThreshold,
		kgFilterEnabled = kgFilterEnabled,
		kgMode = kgMode,
		ratioControlEnabled = ratioControlEnabled,
		startBelowRatio = startBelowRatio,
		stopAboveRatio = stopAboveRatio,
		selectedSprinklers = selectedSprinklers,
		selectedWateringCans = selectedWateringCans,
		minimized = minimized,
		uiX = savedUiX,
		uiY = savedUiY
	}
end

local function applyBoolean(targetValue, fallback)
	if type(targetValue) == "boolean" then
		return targetValue
	end
	return fallback
end

local function applyNumber(targetValue, fallback, minimum, maximum)
	local numberValue = tonumber(targetValue)
	if not numberValue then
		return fallback
	end
	if minimum then numberValue = math.max(minimum, numberValue) end
	if maximum then numberValue = math.min(maximum, numberValue) end
	return numberValue
end

local function applyCloudSettings(data)
	if type(data) ~= "table" then
		return false
	end

	masterEnabled = applyBoolean(data.masterEnabled, masterEnabled)
	enabled = applyBoolean(data.enabled, enabled)
	kgThreshold = applyNumber(data.kgThreshold, kgThreshold, 0, 1000000)
	kgFilterEnabled = applyBoolean(data.kgFilterEnabled, kgFilterEnabled)

	if data.kgMode == "Above" or data.kgMode == "Below" then
		kgMode = data.kgMode
	end

	ratioControlEnabled = applyBoolean(data.ratioControlEnabled, ratioControlEnabled)
	startBelowRatio = applyNumber(data.startBelowRatio, startBelowRatio, 0, 100)
	stopAboveRatio = applyNumber(data.stopAboveRatio, stopAboveRatio, 0, 100)
	minimized = applyBoolean(data.minimized, minimized)
	savedUiX = applyNumber(data.uiX, savedUiX, -10000, 10000)
	savedUiY = applyNumber(data.uiY, savedUiY, -10000, 10000)

	if type(data.selectedSprinklers) == "table" then
		for _, name in ipairs(SPRINKLER_NAMES) do
			if type(data.selectedSprinklers[name]) == "boolean" then
				selectedSprinklers[name] = data.selectedSprinklers[name]
			end
		end
	end

	if type(data.selectedWateringCans) == "table" then
		for _, name in ipairs(WATERING_CAN_NAMES) do
			if type(data.selectedWateringCans[name]) == "boolean" then
				selectedWateringCans[name] = data.selectedWateringCans[name]
			end
		end
	end

	return true
end

_G.TEBHubCloudSections = _G.TEBHubCloudSections or {}
_G.TEBHubCloudSections.Bloom = {
	Get = buildCloudSettings,
	Apply = applyCloudSettings,
}

local function loadCloudSettings()
	if not CLOUD_CONFIG.AutoLoad or not cloudIsConfigured() then
		return false, "Cloud auto-load disabled or not configured."
	end

	local success, result = cloudCall("load")
	if not success then
		cloudLastError = result
		return false, result
	end

	if result.found and type(result.data) == "table" then
		applyCloudSettings(result.data)
	end

	cloudLoaded = true
	cloudLastError = nil
	return true, result.found and "Cloud settings loaded." or "No cloud save yet; defaults loaded."
end

local function saveCloudSettingsNow()
	if not CLOUD_CONFIG.AutoSave or not cloudIsConfigured() then
		return false, "Cloud auto-save disabled or not configured."
	end

	local success, result = cloudCall("save", buildCloudSettings())
	if not success then
		cloudLastError = result
		return false, result
	end

	cloudLastError = nil
	return true, "Cloud settings saved."
end

local function queueCloudSave()
	if not CLOUD_CONFIG.AutoSave or not cloudIsConfigured() then
		return
	end

	cloudSaveRevision += 1
	local myRevision = cloudSaveRevision
	cloudSaveQueued = true

	task.delay(CLOUD_CONFIG.SaveDebounceSeconds, function()
		if myRevision ~= cloudSaveRevision then
			return
		end
		cloudSaveQueued = false
		saveCloudSettingsNow()
	end)
end

-- Load before constructing the UI, so all controls start with cloud values.
loadCloudSettings()

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
frame.Position = UDim2.fromOffset(savedUiX, savedUiY)
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

	local x = savedUiX
	local y = savedUiY

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
		queueCloudSave()
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
		queueCloudSave()
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
		queueCloudSave()
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
	queueCloudSave()
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
	queueCloudSave()
end)

ratioToggleButton.MouseButton1Click:Connect(function()
	ratioControlEnabled = not ratioControlEnabled
	wateredForCurrentCondition = false
	waitingForCollection = false
	updateRatioButton()
	queueCloudSave()

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
		queueCloudSave()
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
		queueCloudSave()
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
	queueCloudSave()
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
	queueCloudSave()

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
	queueCloudSave()
end)

closeButton.MouseButton1Click:Connect(function()
	automationAlive = false
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
		savedUiX = frame.Position.X.Offset
		savedUiY = frame.Position.Y.Offset
		queueCloudSave()
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

	while automationAlive do
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

if minimized then
	body.Visible = false
	frame.Size = UDim2.new(0, 340, 0, 36)
	minimizeButton.Text = "+"
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
if cloudLastError then
	setStatus("Ready. Cloud config error: " .. tostring(cloudLastError))
elseif cloudLoaded then
	setStatus("Ready. Cloud settings loaded.")
else
	setStatus("Ready. UserId cloud config active (" .. ROBLOX_USER_ID .. ").")
end

-- TEB Hub lifecycle bridge
_G.TEBHubModules = _G.TEBHubModules or {}
_G.TEBHubModules.Bloom = {
	Stop = function()
		automationAlive = false
		masterEnabled = false
		enabled = false
		waitingForCollection = false
		wateredForCurrentCondition = false
		if gui and gui.Parent then
			gui:Destroy()
		end
	end,
	IsRunning = function()
		return automationAlive == true
	end
}

]=],
	Mailer = [=[
--// Phone Compact Fruit Counter + Multi-User Raw Mailer
--// Put this as a LocalScript in StarterPlayer > StarterPlayerScripts.
--//
--// What it does:
--// - Counts harvested fruits from Backpack/Character descendants:
--//     HarvestedFruit == true
--//     FruitValue exists
--// - Caches each fruit's Base x1 value once:
--//     Base x1 = FruitValue / stock multiplier
--// - Sends to multiple usernames sequentially.
--// - Uses max 20 fruits per mail.
--// - For each username, picks fruits that meet or exceed the target with the smallest overpay possible.
--// - Shows avatar thumbnails for queried usernames.
--// - Keeps compact trade history.
--// - Keeps compact expandable logs.
--//
--// Packet notes:
--// - Recipient packet: 1D 01 <sequence> <usernameLength> <username>
--// - Mail packet:      1C 01 <sequence> <recipientUserId as little-endian f64> ...
--// - Sequence start is configurable below.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Event = ReplicatedStorage
	:WaitForChild("SharedModules")
	:WaitForChild("Packet")
	:WaitForChild("RemoteEvent")

--// SETTINGS

local HARVESTED_ATTRIBUTE = "HarvestedFruit"
local FRUIT_VALUE_ATTRIBUTE = "FruitValue"

-- Server-enforced max.
local MAX_FRUITS_PER_MAIL = 20

-- Fresh sample had recipient packet using 0x3E:
-- "\x1D\x01>\fglynoxven320"
local DEFAULT_PACKET_SEQUENCE_START_HEX = "3E"

local RECIPIENT_PACKET_DELAY = 0.12
local MAIL_BATCH_DELAY = 0.20

-- Your game has a real mail cooldown.
-- This script waits this long between each mail packet.
local MAIL_COOLDOWN_SECONDS = 10.75

-- Rolling mail allowance. The exact game reset window can be changed in the UI.
local DEFAULT_MAIL_LIMIT_COUNT = 50
local DEFAULT_MAIL_LIMIT_WINDOW_HOURS = 24

local DEFAULT_TARGET_VALUE = "1B"
local DEFAULT_TARGET_FRUIT_COUNT = 20
local targetMode = "Value" -- "Value" or "Fruit"

local mailerCloudData = nil
if type(_G.TEBCloudLoadScope) == "function" then
	local loaded = _G.TEBCloudLoadScope("mailer")
	if type(loaded) == "table" then
		mailerCloudData = loaded
		if loaded.targetMode == "Value" or loaded.targetMode == "Fruit" then
			targetMode = loaded.targetMode
		end
	end
end

local mailLimitCount = math.max(
	1,
	math.floor(tonumber(mailerCloudData and mailerCloudData.mailLimitCount) or DEFAULT_MAIL_LIMIT_COUNT)
)

local mailLimitWindowHours = math.max(
	1,
	tonumber(mailerCloudData and mailerCloudData.mailLimitWindowHours) or DEFAULT_MAIL_LIMIT_WINDOW_HOURS
)

local mailUsageTimestamps = {}

if mailerCloudData and type(mailerCloudData.mailUsageTimestamps) == "table" then
	for _, timestamp in ipairs(mailerCloudData.mailUsageTimestamps) do
		timestamp = tonumber(timestamp)
		if timestamp then
			table.insert(mailUsageTimestamps, timestamp)
		end
	end
end

local function pruneMailUsage(now)
	now = tonumber(now) or os.time()
	local cutoff = now - (mailLimitWindowHours * 3600)
	local kept = {}

	for _, timestamp in ipairs(mailUsageTimestamps) do
		if tonumber(timestamp) and timestamp > cutoff and timestamp <= now + 300 then
			table.insert(kept, timestamp)
		end
	end

	table.sort(kept)
	mailUsageTimestamps = kept
	return #mailUsageTimestamps
end

local function getMailLimitState()
	local now = os.time()
	local used = pruneMailUsage(now)
	local remaining = math.max(0, mailLimitCount - used)
	local resetIn = 0

	if used > 0 then
		resetIn = math.max(0, (mailUsageTimestamps[1] + (mailLimitWindowHours * 3600)) - now)
	end

	return used, remaining, resetIn
end

local function formatDuration(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)

	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end

	return string.format("%dm", minutes)
end
local FALLBACK_SELL_MULTI = 1

-- Hypno Bloom support.
-- Hypno Bloom uses the same base-kg behavior as Moon Bloom, but its base price is 9500.
-- Hypno Bloom has its own stock card, so this script uses Hypno Bloom's own multiplier.
local HYPNO_BLOOM_BASE_PRICE = 9500
local HYPNO_BLOOM_USES_MOON_BLOOM_MULTIPLIER = false

-- Optional. Leave nil unless you know the exact Moon Bloom base kg.
-- If set, Hypno Bloom can fallback to: 9500 * (kg / MOON_BLOOM_BASE_KG)^2
local MOON_BLOOM_BASE_KG = nil

-- Existing fruits do not recalculate once cached.
local RECALCULATE_EXISTING_FRUITS = true

-- Safe mode:
-- This keeps the older scanner that actually sees your 100kg+ fruits.
-- It only allows FruitValue updates to refresh cached values; it does not replace the scanner.
local SAFE_VALUE_RECALC_ONLY = true

-- If total available is below target for a username:
-- false = skip that username instead of sending partial value.
local SEND_PARTIAL_IF_NOT_ENOUGH = false

-- Live refill mode:
-- Keeps mailing when your auto-claim mail script adds more fruits to inventory.
-- IMPORTANT: this version keeps the older exact descendant scanner because it sees the 100kg+ fruits.
local LIVE_REFILL_MAILING = true
local WAIT_FOR_NEW_FRUITS_SECONDS = 45
local REFILL_RESCAN_INTERVAL = 1.00

-- If current inventory is below the target, send all current mailable fruits,
-- then wait for more fruits from mail.
local SEND_CURRENT_INVENTORY_WHEN_BELOW_TARGET = true

-- Cooldown handles pacing now.
local PAUSE_EVERY_BATCHES = 0
local PAUSE_AFTER_BATCHES_DELAY = 0

-- Exact closest subset is used up to this many mailable fruits.
-- Above this, it falls back to a faster greedy selector.
local MAX_OPTIMIZED_TARGET_FRUITS = 28

local MIN_VALID_MULTI = 0.01
local MAX_VALID_MULTI = 20

local EXACT_ITEM_KEY_ATTRIBUTES = {
	"ItemKey",
}

local FALLBACK_ITEM_KEY_ATTRIBUTES = {
	"ItemID",
	"ItemId",
	"UUID",
	"Uuid",
	"GUID",
	"Guid",
	"Id",
	"ID",
}

local FRUIT_NAME_ATTRIBUTES = {
	"SeedToolTip",
	"FruitName",
	"ItemName",
	"DisplayName",
	"ToolTip",
	"Tooltip",
	"Name",
}

local KG_ATTRIBUTES = {
	"KG",
	"Kg",
	"kg",
	"Weight",
	"weight",
	"WeightKg",
	"WeightKG",
	"Mass",
	"mass",
}

--// STATE

local running = true
local mailing = false

local fruitCache = {}
local connectedRoots = {}
local connectedInstances = {}
local sentKeySet = {}

local userIdCache = {}
local loadedRecipients = {}
local loadedRecipientMap = {}
local avatarCardMap = {}
local historyEntries = {}
local logEntries = {}
local progressRows = {}

local lastStockCardCount = 0
local lastStatus = "loaded"

local refreshUI
local addLog
local addHistory
local updateTargetFormattedLabel
local loadRecipientsFromBox

--// BASIC HELPERS

local function isTextObject(obj)
	return obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")
end

local function cleanNumberText(text)
	text = tostring(text or "")
	text = text:gsub(",", "")
	return text
end

local function parseUserNumber(text)
	text = cleanNumberText(text)
	text = text:gsub("%s+", "")

	if text == "" then
		return nil
	end

	local directNumber = tonumber(text)
	if directNumber then
		return directNumber
	end

	local numberPart, suffix = text:match("^([%d%.]+)([kKmMbBtT]?)$")

	if not numberPart then
		numberPart = text:match("[%d%.]+")
		suffix = text:match("([kKmMbBtT])") or ""
	end

	local value = numberPart and tonumber(numberPart) or nil
	if not value then
		return nil
	end

	suffix = tostring(suffix or ""):lower()

	if suffix == "k" then
		value *= 1e3
	elseif suffix == "m" then
		value *= 1e6
	elseif suffix == "b" then
		value *= 1e9
	elseif suffix == "t" then
		value *= 1e12
	end

	return value
end

local function formatShortNumber(value)
	if typeof(value) ~= "number" then
		return "?"
	end

	local absValue = math.abs(value)

	if absValue >= 1e12 then
		return string.format("%.2fT", value / 1e12)
	elseif absValue >= 1e9 then
		return string.format("%.2fB", value / 1e9)
	elseif absValue >= 1e6 then
		return string.format("%.2fM", value / 1e6)
	elseif absValue >= 1e3 then
		return string.format("%.2fK", value / 1e3)
	end

	return tostring(math.floor(value + 0.5))
end

local function formatNumber(value)
	if typeof(value) ~= "number" then
		return "?"
	end

	value = math.floor(value + 0.5)
	local text = tostring(value)

	while true do
		local newText, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		text = newText

		if count == 0 then
			break
		end
	end

	return text
end

local function normalizeName(text)
	text = tostring(text or "")
	text = text:lower()
	text = text:gsub("%s+", "")
	text = text:gsub("_", "")
	text = text:gsub("-", "")
	return text
end

local function isHypnoBloomName(text)
	local normalized = normalizeName(text)
	return normalized == "hypnobloom" or normalized:find("hypnobloom", 1, true) ~= nil
end

local function findKgInText(text)
	text = tostring(text or "")
	local value = text:match("([%d%.]+)%s*[kK][gG]") or text:match("[kK][gG]%s*([%d%.]+)")
	return value and tonumber(value) or nil
end

local function getFruitKgFromInstance(instance)
	for _, attrName in ipairs(KG_ATTRIBUTES) do
		local attr = instance:GetAttribute(attrName)
		if typeof(attr) == "number" then
			return attr
		elseif typeof(attr) == "string" then
			local parsed = findKgInText(attr) or tonumber(attr)
			if parsed then
				return parsed
			end
		end
	end

	local current = instance
	while current and current ~= game do
		if current:IsA("Tool") then
			for _, attrName in ipairs(KG_ATTRIBUTES) do
				local attr = current:GetAttribute(attrName)
				if typeof(attr) == "number" then
					return attr
				elseif typeof(attr) == "string" then
					local parsed = findKgInText(attr) or tonumber(attr)
					if parsed then
						return parsed
					end
				end
			end

			return findKgInText(current.Name)
		end

		current = current.Parent
	end

	return findKgInText(instance.Name)
end

local function parseHexByte(hex)
	hex = tostring(hex or "")
	hex = hex:gsub("%s+", "")
	hex = hex:gsub("0x", "")

	local value = tonumber(hex, 16)

	if not value or value < 0 or value > 255 then
		error("Invalid packet sequence hex: " .. tostring(hex))
	end

	return value
end

local function incrementPacketByte(value)
	value += 1

	if value > 255 then
		value = 0
	end

	return value
end

local function getAttributeNumber(instance, attributeName)
	local value = instance:GetAttribute(attributeName)

	if typeof(value) == "number" then
		return value
	end

	if typeof(value) == "string" then
		return parseUserNumber(value)
	end

	return nil
end

local function getAttributeString(instance, attrNames)
	for _, attrName in ipairs(attrNames) do
		local value = instance:GetAttribute(attrName)

		if typeof(value) == "string" and value ~= "" then
			return value, attrName
		end
	end

	return nil, nil
end

local function findUuidInText(text)
	text = tostring(text or "")
	return text:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)")
end

local function copyArray(arr)
	local result = {}

	for i, value in ipairs(arr) do
		result[i] = value
	end

	return result
end

--// UI

local gui = Instance.new("ScreenGui")
gui.Name = "CompactFruitMultiMailer"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui


local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(430, 470)
main.Position = UDim2.fromOffset(8, 52)
main.BackgroundColor3 = Color3.fromRGB(22, 22, 24)
main.BorderSizePixel = 0
main.ZIndex = 1
main.Parent = gui

local mainScale = Instance.new("UIScale")
mainScale.Name = "PhoneFitScale"
mainScale.Scale = 1
mainScale.Parent = main

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 12)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(85, 85, 90)
mainStroke.Thickness = 1
mainStroke.Parent = main

local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 32)
topBar.BackgroundColor3 = Color3.fromRGB(34, 34, 38)
topBar.BorderSizePixel = 0
topBar.Parent = main

local topCorner = Instance.new("UICorner")
topCorner.CornerRadius = UDim.new(0, 12)
topCorner.Parent = topBar

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -116, 1, 0)
title.Position = UDim2.fromOffset(12, 0)
title.BackgroundTransparency = 1
title.Text = "Fruit Mailer"
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = topBar

local rescanButton = Instance.new("TextButton")
rescanButton.Name = "Rescan"
rescanButton.Size = UDim2.fromOffset(48, 22)
rescanButton.Position = UDim2.new(1, -116, 0, 5)
rescanButton.BackgroundColor3 = Color3.fromRGB(55, 55, 60)
rescanButton.BorderSizePixel = 0
rescanButton.Text = "Rescan"
rescanButton.Font = Enum.Font.GothamBold
rescanButton.TextSize = 10
rescanButton.TextColor3 = Color3.fromRGB(255, 255, 255)
rescanButton.Parent = topBar

local minimizeButton = Instance.new("TextButton")
minimizeButton.Name = "Minimize"
minimizeButton.Size = UDim2.fromOffset(26, 22)
minimizeButton.Position = UDim2.new(1, -58, 0, 5)
minimizeButton.BackgroundColor3 = Color3.fromRGB(55, 55, 60)
minimizeButton.BorderSizePixel = 0
minimizeButton.Text = "-"
minimizeButton.Font = Enum.Font.GothamBold
minimizeButton.TextSize = 18
minimizeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
minimizeButton.Parent = topBar

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.Size = UDim2.fromOffset(26, 22)
closeButton.Position = UDim2.new(1, -29, 0, 5)
closeButton.BackgroundColor3 = Color3.fromRGB(120, 38, 38)
closeButton.BorderSizePixel = 0
closeButton.Text = "X"
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 13
closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
closeButton.Parent = topBar

for _, button in ipairs({ rescanButton, minimizeButton, closeButton }) do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = button
end

local content = Instance.new("ScrollingFrame")
content.Name = "Content"
content.Size = UDim2.new(1, -12, 1, -38)
content.Position = UDim2.fromOffset(6, 34)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.ScrollBarThickness = 5
content.ScrollingDirection = Enum.ScrollingDirection.Y
content.CanvasSize = UDim2.fromOffset(0, 940)
content.AutomaticCanvasSize = Enum.AutomaticSize.None
content.Active = true
content.Parent = main

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Size = UDim2.new(1, 0, 0, 24)
statusLabel.Position = UDim2.fromOffset(0, 0)
statusLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
statusLabel.BorderSizePixel = 0
statusLabel.Text = "Ready."
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 10
statusLabel.TextColor3 = Color3.fromRGB(170, 220, 255)
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Center
statusLabel.TextWrapped = true
statusLabel.Parent = content

local statusPadding = Instance.new("UIPadding")
statusPadding.PaddingLeft = UDim.new(0, 8)
statusPadding.PaddingRight = UDim.new(0, 8)
statusPadding.Parent = statusLabel

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(0, 8)
statusCorner.Parent = statusLabel

local statsLabel = Instance.new("TextLabel")
statsLabel.Name = "Stats"
statsLabel.Size = UDim2.new(1, 0, 0, 30)
statsLabel.Position = UDim2.fromOffset(0, 27)
statsLabel.BackgroundTransparency = 1
statsLabel.Text = "Fruits: 0 | Mailable: 0 | Base: 0 | Stock cards: 0"
statsLabel.Font = Enum.Font.Gotham
statsLabel.TextSize = 10
statsLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
statsLabel.TextXAlignment = Enum.TextXAlignment.Left
statsLabel.TextWrapped = true
statsLabel.Parent = content

local recipientLabel = Instance.new("TextLabel")
recipientLabel.Size = UDim2.fromOffset(68, 22)
recipientLabel.Position = UDim2.fromOffset(0, 58)
recipientLabel.BackgroundTransparency = 1
recipientLabel.Text = "Users:"
recipientLabel.Font = Enum.Font.GothamBold
recipientLabel.TextSize = 10
recipientLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
recipientLabel.TextXAlignment = Enum.TextXAlignment.Left
recipientLabel.Parent = content

local recipientBox = Instance.new("TextBox")
recipientBox.Name = "RecipientBox"
recipientBox.Size = UDim2.new(1, -150, 0, 26)
recipientBox.Position = UDim2.fromOffset(54, 56)
recipientBox.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
recipientBox.BorderSizePixel = 0
recipientBox.Text = mailerCloudData and tostring(mailerCloudData.recipients or "") or ""
recipientBox.PlaceholderText = "user1, user2, user3"
recipientBox.Font = Enum.Font.Gotham
recipientBox.TextSize = 11
recipientBox.TextColor3 = Color3.fromRGB(255, 255, 255)
recipientBox.PlaceholderColor3 = Color3.fromRGB(150, 150, 155)
recipientBox.ClearTextOnFocus = false
recipientBox.Parent = content

local recipientCorner = Instance.new("UICorner")
recipientCorner.CornerRadius = UDim.new(0, 7)
recipientCorner.Parent = recipientBox

local loadUsersButton = Instance.new("TextButton")
loadUsersButton.Name = "LoadUsers"
loadUsersButton.Size = UDim2.fromOffset(50, 26)
loadUsersButton.Position = UDim2.new(1, -50, 0, 56)
loadUsersButton.BackgroundColor3 = Color3.fromRGB(55, 62, 78)
loadUsersButton.BorderSizePixel = 0
loadUsersButton.Text = "Load"
loadUsersButton.Font = Enum.Font.GothamBold
loadUsersButton.TextSize = 10
loadUsersButton.TextColor3 = Color3.fromRGB(255, 255, 255)
loadUsersButton.Parent = content

local loadUsersCorner = Instance.new("UICorner")
loadUsersCorner.CornerRadius = UDim.new(0, 7)
loadUsersCorner.Parent = loadUsersButton

local clearQueryButton = Instance.new("TextButton")
clearQueryButton.Name = "ClearQuery"
clearQueryButton.Size = UDim2.fromOffset(50, 26)
clearQueryButton.Position = UDim2.new(1, -104, 0, 56)
clearQueryButton.BackgroundColor3 = Color3.fromRGB(76, 50, 50)
clearQueryButton.BorderSizePixel = 0
clearQueryButton.Text = "Clear"
clearQueryButton.Font = Enum.Font.GothamBold
clearQueryButton.TextSize = 10
clearQueryButton.TextColor3 = Color3.fromRGB(255, 255, 255)
clearQueryButton.Parent = content

local clearQueryCorner = Instance.new("UICorner")
clearQueryCorner.CornerRadius = UDim.new(0, 7)
clearQueryCorner.Parent = clearQueryButton

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.fromOffset(66, 22)
targetLabel.Position = UDim2.fromOffset(0, 88)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "Target:"
targetLabel.Font = Enum.Font.GothamBold
targetLabel.TextSize = 10
targetLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Parent = content

local targetBox = Instance.new("TextBox")
targetBox.Name = "TargetBox"
targetBox.Size = UDim2.fromOffset(86, 24)
targetBox.Position = UDim2.fromOffset(54, 86)
targetBox.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
targetBox.BorderSizePixel = 0
targetBox.Text = mailerCloudData and tostring(mailerCloudData.valueTarget or DEFAULT_TARGET_VALUE) or DEFAULT_TARGET_VALUE
targetBox.PlaceholderText = "1B"
targetBox.Font = Enum.Font.Gotham
targetBox.TextSize = 11
targetBox.TextColor3 = Color3.fromRGB(255, 255, 255)
targetBox.ClearTextOnFocus = false
targetBox.Parent = content

local targetCorner = Instance.new("UICorner")
targetCorner.CornerRadius = UDim.new(0, 7)
targetCorner.Parent = targetBox

local targetFormattedLabel = Instance.new("TextLabel")
targetFormattedLabel.Name = "FormattedTarget"
targetFormattedLabel.Size = UDim2.new(1, -150, 0, 24)
targetFormattedLabel.Position = UDim2.fromOffset(146, 86)
targetFormattedLabel.BackgroundTransparency = 1
targetFormattedLabel.Text = "1.00B"
targetFormattedLabel.Font = Enum.Font.GothamBold
targetFormattedLabel.TextSize = 10
targetFormattedLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
targetFormattedLabel.TextXAlignment = Enum.TextXAlignment.Left
targetFormattedLabel.Parent = content

local seqLabel = Instance.new("TextLabel")
seqLabel.Size = UDim2.fromOffset(32, 22)
seqLabel.Position = UDim2.fromOffset(0, 116)
seqLabel.BackgroundTransparency = 1
seqLabel.Text = "Seq:"
seqLabel.Font = Enum.Font.GothamBold
seqLabel.TextSize = 10
seqLabel.TextColor3 = Color3.fromRGB(180, 180, 185)
seqLabel.TextXAlignment = Enum.TextXAlignment.Left
seqLabel.Parent = content

local seqBox = Instance.new("TextBox")
seqBox.Name = "SeqBox"
seqBox.Size = UDim2.fromOffset(38, 24)
seqBox.Position = UDim2.fromOffset(30, 114)
seqBox.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
seqBox.BorderSizePixel = 0
seqBox.Text = mailerCloudData and tostring(mailerCloudData.packetSequence or DEFAULT_PACKET_SEQUENCE_START_HEX) or DEFAULT_PACKET_SEQUENCE_START_HEX
seqBox.PlaceholderText = "3E"
seqBox.Font = Enum.Font.Code
seqBox.TextSize = 11
seqBox.TextColor3 = Color3.fromRGB(255, 255, 255)
seqBox.ClearTextOnFocus = false
seqBox.Parent = content

local seqCorner = Instance.new("UICorner")
seqCorner.CornerRadius = UDim.new(0, 6)
seqCorner.Parent = seqBox

local previewButton = Instance.new("TextButton")
previewButton.Name = "Preview"
previewButton.Size = UDim2.fromOffset(62, 24)
previewButton.Position = UDim2.fromOffset(74, 114)
previewButton.BackgroundColor3 = Color3.fromRGB(55, 55, 60)
previewButton.BorderSizePixel = 0
previewButton.Text = "Preview"
previewButton.Font = Enum.Font.GothamBold
previewButton.TextSize = 10
previewButton.TextColor3 = Color3.fromRGB(255, 255, 255)
previewButton.Parent = content

local sendButton = Instance.new("TextButton")
sendButton.Name = "Send"
sendButton.Size = UDim2.fromOffset(88, 24)
sendButton.Position = UDim2.fromOffset(142, 114)
sendButton.BackgroundColor3 = Color3.fromRGB(55, 90, 60)
sendButton.BorderSizePixel = 0
sendButton.Text = "Mail"
sendButton.Font = Enum.Font.GothamBold
sendButton.TextSize = 10
sendButton.TextColor3 = Color3.fromRGB(255, 255, 255)
sendButton.Parent = content

local logsButton = Instance.new("TextButton")
logsButton.Name = "Logs"
logsButton.Size = UDim2.fromOffset(58, 24)
logsButton.Position = UDim2.new(1, -58, 0, 114)
logsButton.BackgroundColor3 = Color3.fromRGB(48, 48, 54)
logsButton.BorderSizePixel = 0
logsButton.Text = "Logs ▼"
logsButton.Font = Enum.Font.GothamBold
logsButton.TextSize = 10
logsButton.TextColor3 = Color3.fromRGB(255, 255, 255)
logsButton.Parent = content

for _, button in ipairs({ previewButton, sendButton, logsButton }) do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = button
end

local valueModeButton = Instance.new("TextButton")
valueModeButton.Name = "ValueModeCheck"
valueModeButton.Size = UDim2.fromOffset(96, 24)
valueModeButton.Position = UDim2.fromOffset(0, 144)
valueModeButton.BackgroundColor3 = Color3.fromRGB(55, 62, 78)
valueModeButton.BorderSizePixel = 0
valueModeButton.Text = "☑ Value"
valueModeButton.Font = Enum.Font.GothamBold
valueModeButton.TextSize = 10
valueModeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
valueModeButton.Parent = content

local fruitModeButton = Instance.new("TextButton")
fruitModeButton.Name = "FruitModeCheck"
fruitModeButton.Size = UDim2.fromOffset(96, 24)
fruitModeButton.Position = UDim2.fromOffset(102, 144)
fruitModeButton.BackgroundColor3 = Color3.fromRGB(55, 62, 78)
fruitModeButton.BorderSizePixel = 0
fruitModeButton.Text = "☐ Fruits"
fruitModeButton.Font = Enum.Font.GothamBold
fruitModeButton.TextSize = 10
fruitModeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
fruitModeButton.Parent = content

local fruitCountLabel = Instance.new("TextLabel")
fruitCountLabel.Size = UDim2.fromOffset(92, 24)
fruitCountLabel.Position = UDim2.fromOffset(0, 174)
fruitCountLabel.BackgroundTransparency = 1
fruitCountLabel.Text = "Target fruits:"
fruitCountLabel.Font = Enum.Font.GothamBold
fruitCountLabel.TextSize = 10
fruitCountLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
fruitCountLabel.TextXAlignment = Enum.TextXAlignment.Left
fruitCountLabel.Parent = content

local fruitCountBox = Instance.new("TextBox")
fruitCountBox.Name = "TargetFruitCount"
fruitCountBox.Size = UDim2.fromOffset(110, 24)
fruitCountBox.Position = UDim2.fromOffset(92, 174)
fruitCountBox.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
fruitCountBox.BorderSizePixel = 0
fruitCountBox.Text = tostring(
	mailerCloudData and tonumber(mailerCloudData.fruitCount)
	or DEFAULT_TARGET_FRUIT_COUNT
)
fruitCountBox.PlaceholderText = "100"
fruitCountBox.Font = Enum.Font.GothamBold
fruitCountBox.TextSize = 10
fruitCountBox.TextColor3 = Color3.fromRGB(255, 220, 120)
fruitCountBox.ClearTextOnFocus = false
fruitCountBox.Parent = content

local fruitCountHint = Instance.new("TextLabel")
fruitCountHint.Size = UDim2.new(1, -214, 0, 24)
fruitCountHint.Position = UDim2.fromOffset(214, 174)
fruitCountHint.BackgroundTransparency = 1
fruitCountHint.Text = "any harvested fruits"
fruitCountHint.Font = Enum.Font.Gotham
fruitCountHint.TextSize = 9
fruitCountHint.TextColor3 = Color3.fromRGB(165, 175, 205)
fruitCountHint.TextXAlignment = Enum.TextXAlignment.Left
fruitCountHint.Parent = content

for _, object in ipairs({ valueModeButton, fruitModeButton, fruitCountBox }) do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = object
end

local mailLimitLabel = Instance.new("TextLabel")
mailLimitLabel.Size = UDim2.fromOffset(82, 24)
mailLimitLabel.Position = UDim2.fromOffset(0, 204)
mailLimitLabel.BackgroundTransparency = 1
mailLimitLabel.Text = "Mail limit:"
mailLimitLabel.Font = Enum.Font.GothamBold
mailLimitLabel.TextSize = 10
mailLimitLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
mailLimitLabel.TextXAlignment = Enum.TextXAlignment.Left
mailLimitLabel.Parent = content

local mailLimitCountBox = Instance.new("TextBox")
mailLimitCountBox.Name = "MailLimitCount"
mailLimitCountBox.Size = UDim2.fromOffset(48, 24)
mailLimitCountBox.Position = UDim2.fromOffset(70, 204)
mailLimitCountBox.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
mailLimitCountBox.BorderSizePixel = 0
mailLimitCountBox.Text = tostring(mailLimitCount)
mailLimitCountBox.PlaceholderText = "50"
mailLimitCountBox.Font = Enum.Font.GothamBold
mailLimitCountBox.TextSize = 10
mailLimitCountBox.TextColor3 = Color3.fromRGB(255, 255, 255)
mailLimitCountBox.ClearTextOnFocus = false
mailLimitCountBox.Parent = content
addCorner = addCorner

local mailWindowBox = Instance.new("TextBox")
mailWindowBox.Name = "MailLimitHours"
mailWindowBox.Size = UDim2.fromOffset(52, 24)
mailWindowBox.Position = UDim2.fromOffset(124, 204)
mailWindowBox.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
mailWindowBox.BorderSizePixel = 0
mailWindowBox.Text = tostring(mailLimitWindowHours)
mailWindowBox.PlaceholderText = "24"
mailWindowBox.Font = Enum.Font.GothamBold
mailWindowBox.TextSize = 10
mailWindowBox.TextColor3 = Color3.fromRGB(255, 255, 255)
mailWindowBox.ClearTextOnFocus = false
mailWindowBox.Parent = content

local mailLimitStatus = Instance.new("TextLabel")
mailLimitStatus.Size = UDim2.new(1, -184, 0, 24)
mailLimitStatus.Position = UDim2.fromOffset(184, 204)
mailLimitStatus.BackgroundTransparency = 1
mailLimitStatus.Text = "0/50 used"
mailLimitStatus.Font = Enum.Font.Code
mailLimitStatus.TextSize = 9
mailLimitStatus.TextColor3 = Color3.fromRGB(170, 220, 255)
mailLimitStatus.TextXAlignment = Enum.TextXAlignment.Left
mailLimitStatus.Parent = content

for _, object in ipairs({mailLimitCountBox, mailWindowBox}) do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = object
end

local avatarFrame = Instance.new("ScrollingFrame")
avatarFrame.Name = "Avatars"
avatarFrame.Size = UDim2.new(1, 0, 0, 54)
avatarFrame.Position = UDim2.fromOffset(0, 238)
avatarFrame.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
avatarFrame.BorderSizePixel = 0
avatarFrame.ScrollBarThickness = 4
avatarFrame.ScrollingDirection = Enum.ScrollingDirection.X
avatarFrame.CanvasSize = UDim2.fromOffset(0, 0)
avatarFrame.AutomaticCanvasSize = Enum.AutomaticSize.X
avatarFrame.Parent = content

local avatarCorner = Instance.new("UICorner")
avatarCorner.CornerRadius = UDim.new(0, 8)
avatarCorner.Parent = avatarFrame

local avatarPadding = Instance.new("UIPadding")
avatarPadding.PaddingTop = UDim.new(0, 6)
avatarPadding.PaddingBottom = UDim.new(0, 6)
avatarPadding.PaddingLeft = UDim.new(0, 6)
avatarPadding.PaddingRight = UDim.new(0, 6)
avatarPadding.Parent = avatarFrame

local avatarLayout = Instance.new("UIListLayout")
avatarLayout.FillDirection = Enum.FillDirection.Horizontal
avatarLayout.Padding = UDim.new(0, 8)
avatarLayout.SortOrder = Enum.SortOrder.LayoutOrder
avatarLayout.Parent = avatarFrame

local previewLabel = Instance.new("TextLabel")
previewLabel.Name = "PreviewText"
previewLabel.Size = UDim2.new(1, 0, 0, 96)
previewLabel.Position = UDim2.fromOffset(0, 298)
previewLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
previewLabel.BorderSizePixel = 0
previewLabel.Text = "Preview: none"
previewLabel.Font = Enum.Font.Gotham
previewLabel.TextSize = 10
previewLabel.TextColor3 = Color3.fromRGB(170, 220, 255)
previewLabel.TextXAlignment = Enum.TextXAlignment.Left
previewLabel.TextYAlignment = Enum.TextYAlignment.Top
previewLabel.TextWrapped = true
previewLabel.Parent = content

local previewPadding = Instance.new("UIPadding")
previewPadding.PaddingLeft = UDim.new(0, 8)
previewPadding.PaddingRight = UDim.new(0, 8)
previewPadding.PaddingTop = UDim.new(0, 6)
previewPadding.PaddingBottom = UDim.new(0, 6)
previewPadding.Parent = previewLabel

local previewCorner = Instance.new("UICorner")
previewCorner.CornerRadius = UDim.new(0, 8)
previewCorner.Parent = previewLabel

local progressTitle = Instance.new("TextLabel")
progressTitle.Name = "ProgressTitle"
progressTitle.Size = UDim2.new(1, 0, 0, 18)
progressTitle.Position = UDim2.fromOffset(0, 400)
progressTitle.BackgroundTransparency = 1
progressTitle.Text = "Mail Progress"
progressTitle.Font = Enum.Font.GothamBold
progressTitle.TextSize = 11
progressTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
progressTitle.TextXAlignment = Enum.TextXAlignment.Left
progressTitle.Parent = content

local progressFrame = Instance.new("ScrollingFrame")
progressFrame.Name = "Progress"
progressFrame.Size = UDim2.new(1, 0, 0, 58)
progressFrame.Position = UDim2.fromOffset(0, 420)
progressFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
progressFrame.BorderSizePixel = 0
progressFrame.ScrollBarThickness = 5
progressFrame.CanvasSize = UDim2.fromOffset(0, 0)
progressFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
progressFrame.Parent = content

local progressCorner = Instance.new("UICorner")
progressCorner.CornerRadius = UDim.new(0, 8)
progressCorner.Parent = progressFrame

local progressPadding = Instance.new("UIPadding")
progressPadding.PaddingTop = UDim.new(0, 6)
progressPadding.PaddingBottom = UDim.new(0, 6)
progressPadding.PaddingLeft = UDim.new(0, 6)
progressPadding.PaddingRight = UDim.new(0, 6)
progressPadding.Parent = progressFrame

local progressLayout = Instance.new("UIListLayout")
progressLayout.Padding = UDim.new(0, 5)
progressLayout.SortOrder = Enum.SortOrder.LayoutOrder
progressLayout.Parent = progressFrame

local historyTitle = Instance.new("TextLabel")
historyTitle.Name = "HistoryTitle"
historyTitle.Size = UDim2.new(1, 0, 0, 18)
historyTitle.Position = UDim2.fromOffset(0, 484)
historyTitle.BackgroundTransparency = 1
historyTitle.Text = "Trade History"
historyTitle.Font = Enum.Font.GothamBold
historyTitle.TextSize = 11
historyTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
historyTitle.TextXAlignment = Enum.TextXAlignment.Left
historyTitle.Parent = content

local historyFrame = Instance.new("ScrollingFrame")
historyFrame.Name = "History"
historyFrame.Size = UDim2.new(1, 0, 0, 330)
historyFrame.Position = UDim2.fromOffset(0, 506)
historyFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
historyFrame.BorderSizePixel = 0
historyFrame.ScrollBarThickness = 6
historyFrame.CanvasSize = UDim2.fromOffset(0, 0)
historyFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
historyFrame.Parent = content

local historyCorner = Instance.new("UICorner")
historyCorner.CornerRadius = UDim.new(0, 8)
historyCorner.Parent = historyFrame

local historyPadding = Instance.new("UIPadding")
historyPadding.PaddingTop = UDim.new(0, 6)
historyPadding.PaddingBottom = UDim.new(0, 6)
historyPadding.PaddingLeft = UDim.new(0, 6)
historyPadding.PaddingRight = UDim.new(0, 6)
historyPadding.Parent = historyFrame

local historyLayout = Instance.new("UIListLayout")
historyLayout.Padding = UDim.new(0, 5)
historyLayout.SortOrder = Enum.SortOrder.LayoutOrder
historyLayout.Parent = historyFrame

local logFrame = Instance.new("ScrollingFrame")
logFrame.Name = "Logs"
logFrame.Size = UDim2.new(1, 0, 0, 120)
logFrame.Position = UDim2.fromOffset(0, 852)
logFrame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
logFrame.BorderSizePixel = 0
logFrame.ScrollBarThickness = 6
logFrame.CanvasSize = UDim2.fromOffset(0, 0)
logFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
logFrame.Visible = false
logFrame.Parent = content

local logCorner = Instance.new("UICorner")
logCorner.CornerRadius = UDim.new(0, 8)
logCorner.Parent = logFrame

local logPadding = Instance.new("UIPadding")
logPadding.PaddingTop = UDim.new(0, 6)
logPadding.PaddingBottom = UDim.new(0, 6)
logPadding.PaddingLeft = UDim.new(0, 6)
logPadding.PaddingRight = UDim.new(0, 6)
logPadding.Parent = logFrame

local logLayout = Instance.new("UIListLayout")
logLayout.Padding = UDim.new(0, 4)
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Parent = logFrame

--// DRAGGING

do
	local dragging = false
	local dragStart
	local startPos

	topBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)
end

local minimized = false
local fullSize = main.Size
local miniSize = UDim2.fromOffset(430, 32)

local function fitMainToScreen()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local viewport = camera.ViewportSize

	local baseWidth = 430
	local baseHeight = 470
	local safeWidth = math.max(240, viewport.X - 12)
	local safeHeight = math.max(300, viewport.Y - 54)

	local scale = math.min(safeWidth / baseWidth, safeHeight / baseHeight, 1)
	scale = math.clamp(scale, 0.58, 1)

	mainScale.Scale = scale

	fullSize = UDim2.fromOffset(baseWidth, baseHeight)
	miniSize = UDim2.fromOffset(baseWidth, 32)

	main.Size = minimized and miniSize or fullSize

	local scaledWidth = baseWidth * scale
	local scaledHeight = (minimized and 32 or baseHeight) * scale

	local currentX = main.AbsolutePosition.X
	local currentY = main.AbsolutePosition.Y

	local clampedX = math.clamp(currentX, 6, math.max(6, viewport.X - scaledWidth - 6))
	local clampedY = math.clamp(currentY, 6, math.max(6, viewport.Y - scaledHeight - 6))

	main.Position = UDim2.fromOffset(clampedX, clampedY)
end

task.defer(fitMainToScreen)

task.spawn(function()
	while running do
		local camera = workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Wait()
			fitMainToScreen()
		else
			task.wait(1)
		end
	end
end)

minimizeButton.MouseButton1Click:Connect(function()
	minimized = not minimized
	content.Visible = not minimized
	main.Size = minimized and miniSize or fullSize
	content.CanvasPosition = Vector2.new(0, 0)
	minimizeButton.Text = minimized and "+" or "-"
	fitMainToScreen()
end)

closeButton.MouseButton1Click:Connect(function()
	running = false
	gui:Destroy()
end)

logsButton.MouseButton1Click:Connect(function()
	logFrame.Visible = not logFrame.Visible
	logsButton.Text = logFrame.Visible and "Logs ▲" or "Logs ▼"

	if logFrame.Visible then
		task.defer(function()
			content.CanvasPosition = Vector2.new(0, 594)
		end)
	end
end)

--// LOG / HISTORY

addLog = function(message, color)
	message = tostring(message)

	print("[FruitMultiMailer]", message)

	statusLabel.Text = message
	statusLabel.TextColor3 = color or Color3.fromRGB(170, 220, 255)

	local row = Instance.new("TextLabel")
	row.Name = "LogRow"
	row.Size = UDim2.new(1, -4, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	row.BorderSizePixel = 0
	row.Font = Enum.Font.Code
	row.TextSize = 11
	row.TextColor3 = color or Color3.fromRGB(230, 230, 230)
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.TextYAlignment = Enum.TextYAlignment.Top
	row.TextWrapped = true
	row.Text = os.date("%H:%M:%S") .. "  " .. message
	row.LayoutOrder = #logEntries + 1
	row.Parent = logFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = row

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 5)
	c.Parent = row

	table.insert(logEntries, row)

	if #logEntries > 80 then
		local old = table.remove(logEntries, 1)
		if old then
			old:Destroy()
		end
	end

	task.defer(function()
		logFrame.CanvasPosition = Vector2.new(0, math.max(0, logFrame.AbsoluteCanvasSize.Y))
	end)
end

local function clearProgressRows()
	for _, rowData in pairs(progressRows) do
		if rowData.Row then
			rowData.Row:Destroy()
		end
	end

	table.clear(progressRows)
end

local function createProgressRow(username, targetValue, fruitCount, batchCount)
	local row = Instance.new("Frame")
	row.Name = "ProgressRow"
	row.Size = UDim2.new(1, -4, 0, 32)
	row.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
	row.BorderSizePixel = 0
	row.Parent = progressFrame

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 6)
	rowCorner.Parent = row

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -10, 0, 16)
	label.Position = UDim2.fromOffset(5, 2)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextColor3 = Color3.fromRGB(235, 235, 235)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = string.format("%s | target %s | 0/%d mails", username, formatShortNumber(targetValue), batchCount)
	label.Parent = row

	local barBack = Instance.new("Frame")
	barBack.Name = "BarBack"
	barBack.Size = UDim2.new(1, -10, 0, 8)
	barBack.Position = UDim2.fromOffset(5, 21)
	barBack.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
	barBack.BorderSizePixel = 0
	barBack.Parent = row

	local barBackCorner = Instance.new("UICorner")
	barBackCorner.CornerRadius = UDim.new(1, 0)
	barBackCorner.Parent = barBack

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(90, 180, 110)
	fill.BorderSizePixel = 0
	fill.Parent = barBack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	progressRows[username:lower()] = {
		Row = row,
		Label = label,
		Fill = fill,
		Target = targetValue,
		FruitCount = fruitCount,
		BatchCount = batchCount,
	}
end

local function prepareProgressRows(plans)
	clearProgressRows()

	for _, plan in ipairs(plans) do
		if not plan.Skipped then
			createProgressRow(plan.Username, plan.Target or 0, plan.Fruits and #plan.Fruits or 0, math.max(1, plan.Batches and #plan.Batches or 1))
		end
	end
end

local function updateProgressRow(username, completedBatches, totalBatches, stateText, color)
	local rowData = progressRows[username:lower()]
	if not rowData then
		return
	end

	local ratio = 0

	if totalBatches and totalBatches > 0 then
		ratio = math.clamp(completedBatches / totalBatches, 0, 1)
	end

	rowData.Fill.Size = UDim2.new(ratio, 0, 1, 0)
	rowData.Label.Text = string.format(
		"%s | target %s | %d/%d mails | %s",
		username,
		formatShortNumber(rowData.Target or 0),
		completedBatches,
		totalBatches or 0,
		stateText or ""
	)

	if color then
		rowData.Fill.BackgroundColor3 = color
	end
end

local function updateProgressValueRow(username, sentValue, targetValue, mailCount, stateText, color)
	local rowData = progressRows[username:lower()]
	if not rowData then
		return
	end

	local ratio = 0
	if targetValue and targetValue > 0 then
		ratio = math.clamp((sentValue or 0) / targetValue, 0, 1)
	end

	rowData.Fill.Size = UDim2.new(ratio, 0, 1, 0)
	rowData.Label.Text = string.format(
		"%s | %s/%s | %d mail%s | %s",
		username,
		formatShortNumber(sentValue or 0),
		formatShortNumber(targetValue or 0),
		mailCount or 0,
		mailCount == 1 and "" or "s",
		stateText or ""
	)

	if color then
		rowData.Fill.BackgroundColor3 = color
	end
end

local function summarizeFruits(fruits)
	local counts = {}

	for _, fruit in ipairs(fruits) do
		local name = tostring(fruit.fruitName or "Unknown")
		counts[name] = (counts[name] or 0) + 1
	end

	local parts = {}

	for name, count in pairs(counts) do
		table.insert(parts, name .. " x" .. tostring(count))
	end

	table.sort(parts)
	return table.concat(parts, ", ")
end

local function makeFruitDetailText(fruits)
	local lines = {}

	for index, fruit in ipairs(fruits) do
		local keyText = fruit.itemKey and string.sub(fruit.itemKey, 1, 8) or "NO_KEY"

		table.insert(lines, string.format(
			"%02d. %s | Base %s | Now %s | key:%s",
			index,
			tostring(fruit.fruitName or "Unknown"),
			formatShortNumber(fruit.baseValue or 0),
			formatShortNumber(fruit.currentValue or 0),
			keyText
		))
	end

	if #lines == 0 then
		return "No fruits recorded."
	end

	return table.concat(lines, "\n")
end

addHistory = function(username, fruits, selectedTotal, targetValue, batches, reason)
	local extra = math.max(0, selectedTotal - targetValue)
	local remaining = math.max(0, targetValue - selectedTotal)
	local diffText = remaining > 0 and ("left " .. formatShortNumber(remaining)) or ("+" .. formatShortNumber(extra))
	local expanded = false

	local row = Instance.new("Frame")
	row.Name = "HistoryRow"
	row.Size = UDim2.new(1, -4, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
	row.BorderSizePixel = 0
	row.LayoutOrder = #historyEntries + 1
	row.Parent = historyFrame

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 7)
	rowCorner.Parent = row

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.Padding = UDim.new(0, 4)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row

	local rowPadding = Instance.new("UIPadding")
	rowPadding.PaddingTop = UDim.new(0, 5)
	rowPadding.PaddingBottom = UDim.new(0, 5)
	rowPadding.PaddingLeft = UDim.new(0, 6)
	rowPadding.PaddingRight = UDim.new(0, 6)
	rowPadding.Parent = row

	local header = Instance.new("TextButton")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 46)
	header.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
	header.BorderSizePixel = 0
	header.AutoButtonColor = true
	header.Font = Enum.Font.GothamBold
	header.TextSize = 12
	header.TextColor3 = Color3.fromRGB(235, 235, 235)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextYAlignment = Enum.TextYAlignment.Center
	header.TextWrapped = true
	header.Text = string.format(
		"▶ %s | target %s | sent %s | %s\n%d fruit%s • %d mail%s • %s • scroll rows",
		username,
		formatShortNumber(targetValue),
		formatShortNumber(selectedTotal),
		diffText,
		#fruits,
		#fruits == 1 and "" or "s",
		batches,
		batches == 1 and "" or "s",
		os.date("%H:%M:%S")
	)
	header.Parent = row

	local headerPad = Instance.new("UIPadding")
	headerPad.PaddingLeft = UDim.new(0, 8)
	headerPad.PaddingRight = UDim.new(0, 8)
	headerPad.Parent = header

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 6)
	headerCorner.Parent = header

	local detail = Instance.new("ScrollingFrame")
	detail.Name = "FruitDropdown"
	detail.Size = UDim2.new(1, 0, 0, 0)
	detail.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
	detail.BorderSizePixel = 0
	detail.Visible = false
	detail.ClipsDescendants = true
	detail.ScrollBarThickness = 6
	detail.ScrollingDirection = Enum.ScrollingDirection.Y
	detail.CanvasSize = UDim2.fromOffset(0, 0)
	detail.AutomaticCanvasSize = Enum.AutomaticSize.None
	detail.Active = true
	detail.Parent = row

	local detailCorner = Instance.new("UICorner")
	detailCorner.CornerRadius = UDim.new(0, 6)
	detailCorner.Parent = detail

	local detailContent = Instance.new("Frame")
	detailContent.Name = "FruitRows"
	detailContent.Size = UDim2.new(1, -12, 0, 0)
	detailContent.Position = UDim2.fromOffset(6, 5)
	detailContent.BackgroundTransparency = 1
	detailContent.Parent = detail

	local detailLayout = Instance.new("UIListLayout")
	detailLayout.Padding = UDim.new(0, 2)
	detailLayout.SortOrder = Enum.SortOrder.LayoutOrder
	detailLayout.Parent = detailContent

	local rowHeight = 18

	if #fruits == 0 then
		local emptyRow = Instance.new("TextLabel")
		emptyRow.Name = "FruitRow"
		emptyRow.Size = UDim2.new(1, -8, 0, rowHeight)
		emptyRow.BackgroundTransparency = 1
		emptyRow.Font = Enum.Font.Code
		emptyRow.TextSize = 11
		emptyRow.TextColor3 = Color3.fromRGB(210, 210, 215)
		emptyRow.TextXAlignment = Enum.TextXAlignment.Left
		emptyRow.TextYAlignment = Enum.TextYAlignment.Center
		emptyRow.Text = "No fruits recorded."
		emptyRow.LayoutOrder = 1
		emptyRow.Parent = detailContent
	else
		for index, fruit in ipairs(fruits) do
			local keyText = fruit.itemKey and string.sub(fruit.itemKey, 1, 8) or "NO_KEY"

			local fruitRow = Instance.new("TextLabel")
			fruitRow.Name = "FruitRow_" .. tostring(index)
			fruitRow.Size = UDim2.new(1, -8, 0, rowHeight)
			fruitRow.BackgroundColor3 = index % 2 == 0 and Color3.fromRGB(24, 24, 28) or Color3.fromRGB(18, 18, 22)
			fruitRow.BorderSizePixel = 0
			fruitRow.Font = Enum.Font.Code
			fruitRow.TextSize = 10
			fruitRow.TextColor3 = Color3.fromRGB(215, 215, 220)
			fruitRow.TextXAlignment = Enum.TextXAlignment.Left
			fruitRow.TextYAlignment = Enum.TextYAlignment.Center
			fruitRow.TextWrapped = false
			fruitRow.TextTruncate = Enum.TextTruncate.None
			fruitRow.Text = string.format(
				"%03d. %s | Base %s | Now %s | key:%s",
				index,
				tostring(fruit.fruitName or "Unknown"),
				formatShortNumber(fruit.baseValue or 0),
				formatShortNumber(fruit.currentValue or 0),
				keyText
			)
			fruitRow.LayoutOrder = index
			fruitRow.Parent = detailContent

			local rowPad = Instance.new("UIPadding")
			rowPad.PaddingLeft = UDim.new(0, 4)
			rowPad.PaddingRight = UDim.new(0, 4)
			rowPad.Parent = fruitRow
		end
	end

	local function setExpanded(state)
		expanded = state
		detail.Visible = expanded

		if expanded then
			local totalRows = math.max(1, #fruits)
			local fullTextHeight = 14 + (totalRows * (rowHeight + 2))
			local visibleHeight = math.clamp(fullTextHeight, 72, 270)

			detail.Size = UDim2.new(1, 0, 0, visibleHeight)
			detail.CanvasSize = UDim2.fromOffset(0, fullTextHeight + 24)
			detail.CanvasPosition = Vector2.new(0, 0)

			detailContent.Size = UDim2.new(1, -12, 0, fullTextHeight)
			header.Text = string.gsub(header.Text, "^▶", "▼")
		else
			detail.Size = UDim2.new(1, 0, 0, 0)
			detail.CanvasSize = UDim2.fromOffset(0, 0)
			header.Text = string.gsub(header.Text, "^▼", "▶")
		end
	end

	header.MouseButton1Click:Connect(function()
		setExpanded(not expanded)
	end)

	table.insert(historyEntries, row)

	task.defer(function()
		historyFrame.CanvasPosition = Vector2.new(0, math.max(0, historyFrame.AbsoluteCanvasSize.Y))
	end)
end

--// AVATARS / USER IDS

local function parseRecipientQueries(text)
	local recipients = {}
	local seen = {}

	text = tostring(text or "")

	for username in text:gmatch("[A-Za-z0-9_]+") do
		if username ~= "" then
			local key = username:lower()

			if not seen[key] then
				seen[key] = true

				table.insert(recipients, {
					Username = username,
				})
			end
		end
	end

	return recipients
end

local function parseUsernames(text)
	local names = {}

	for _, recipient in ipairs(parseRecipientQueries(text)) do
		table.insert(names, recipient.Username)
	end

	return names
end

local function getUserIdFromUsername(username)
	username = tostring(username or "")

	if username == "" then
		error("Recipient username is empty.")
	end

	if userIdCache[username] then
		return userIdCache[username]
	end

	local ok, result = pcall(function()
		return Players:GetUserIdFromNameAsync(username)
	end)

	if not ok then
		error("Could not resolve " .. username .. ": " .. tostring(result))
	end

	userIdCache[username] = result
	return result
end

local function userIdToMailBytes(userId)
	userId = tonumber(userId)

	if not userId then
		error("Invalid recipient UserId.")
	end

	local b = buffer.create(8)
	buffer.writef64(b, 0, userId)
	return buffer.tostring(b)
end

loadRecipientsFromBox = function()
	local recipients = parseRecipientQueries(recipientBox.Text)

	if #recipients == 0 then
		addLog("No usernames entered.", Color3.fromRGB(255, 220, 120))
		return
	end

	addLog("Loading/appending " .. tostring(#recipients) .. " username(s). Existing cards stay.")

	for _, recipient in ipairs(recipients) do
		local username = recipient.Username
		local mapKey = username:lower()

		if avatarCardMap[mapKey] then
			addLog(username .. " is already loaded. Edit the amount on the avatar card.")
			continue
		end

		local index = #loadedRecipients + 1

		local card = Instance.new("Frame")
		card.Name = "AvatarCard"
		card.Size = UDim2.fromOffset(150, 42)
		card.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
		card.BorderSizePixel = 0
		card.LayoutOrder = index
		card.Parent = avatarFrame

		avatarCardMap[mapKey] = card

		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = UDim.new(0, 8)
		cardCorner.Parent = card

		local img = Instance.new("ImageLabel")
		img.Name = "Avatar"
		img.Size = UDim2.fromOffset(32, 32)
		img.Position = UDim2.fromOffset(5, 5)
		img.BackgroundColor3 = Color3.fromRGB(26, 26, 30)
		img.BorderSizePixel = 0
		img.Image = ""
		img.Parent = card

		local imgCorner = Instance.new("UICorner")
		imgCorner.CornerRadius = UDim.new(1, 0)
		imgCorner.Parent = img

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "NameLabel"
		nameLabel.Size = UDim2.new(1, -94, 0, 20)
		nameLabel.Position = UDim2.fromOffset(42, 2)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = username .. "\nloading..."
		nameLabel.Font = Enum.Font.Gotham
		nameLabel.TextSize = 9
		nameLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextYAlignment = Enum.TextYAlignment.Center
		nameLabel.TextWrapped = true
		nameLabel.Parent = card

		local amountBox = Instance.new("TextBox")
		amountBox.Name = "AmountBox"
		amountBox.Size = UDim2.fromOffset(56, 18)
		amountBox.Position = UDim2.new(1, -61, 0, 4)
		amountBox.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
		amountBox.BorderSizePixel = 0
		amountBox.Text = targetMode == "Fruit" and tostring(getDefaultFruitTargetCount()) or (targetBox.Text ~= "" and targetBox.Text or DEFAULT_TARGET_VALUE)
		amountBox.PlaceholderText = targetMode == "Fruit" and "20" or "1B"
		amountBox.Font = Enum.Font.GothamBold
		amountBox.TextSize = 9
		amountBox.TextColor3 = Color3.fromRGB(255, 220, 120)
		amountBox.ClearTextOnFocus = false
		amountBox.Parent = card

		local amountCorner = Instance.new("UICorner")
		amountCorner.CornerRadius = UDim.new(0, 5)
		amountCorner.Parent = amountBox

		local amountLabel = Instance.new("TextLabel")
		amountLabel.Name = "AmountLabel"
		amountLabel.Size = UDim2.new(1, -42, 0, 16)
		amountLabel.Position = UDim2.fromOffset(42, 24)
		amountLabel.BackgroundTransparency = 1
		amountLabel.Text = "target: " .. tostring(amountBox.Text)
		amountLabel.Font = Enum.Font.Gotham
		amountLabel.TextSize = 9
		amountLabel.TextColor3 = Color3.fromRGB(180, 180, 185)
		amountLabel.TextXAlignment = Enum.TextXAlignment.Left
		amountLabel.Parent = card

		local recipientData = {
			Username = username,
			UserId = nil,
			TargetInput = amountBox,
			TargetLabel = amountLabel,
		}

		loadedRecipientMap[mapKey] = recipientData
		table.insert(loadedRecipients, recipientData)

		local function updateCardAmount()
			local value = parseUserNumber(amountBox.Text)

			if value and value > 0 then
				amountLabel.Text = "target: " .. formatShortNumber(value)
				amountLabel.TextColor3 = Color3.fromRGB(180, 180, 185)
			else
				amountLabel.Text = "target: invalid"
				amountLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
			end
		end

		amountBox:GetPropertyChangedSignal("Text"):Connect(updateCardAmount)

		amountBox.FocusLost:Connect(function()
			local value = parseUserNumber(amountBox.Text)

			if value and value > 0 then
				amountBox.Text = formatShortNumber(value)
			end

			updateCardAmount()
		end)

		updateCardAmount()

		task.spawn(function()
			local ok, result = pcall(function()
				local userId = getUserIdFromUsername(username)
				local thumb = Players:GetUserThumbnailAsync(
					userId,
					Enum.ThumbnailType.AvatarBust,
					Enum.ThumbnailSize.Size100x100
				)

				return {
					UserId = userId,
					Thumbnail = thumb,
				}
			end)

			if ok and result then
				img.Image = result.Thumbnail
				recipientData.UserId = result.UserId
				nameLabel.Text = username .. "\n" .. tostring(result.UserId)

				addLog("Loaded " .. username .. ". Set amount on the avatar card.", Color3.fromRGB(170, 255, 170))
			else
				nameLabel.Text = username .. "\nnot found"
				nameLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
				loadedRecipientMap[mapKey] = nil
				avatarCardMap[mapKey] = nil

				for i = #loadedRecipients, 1, -1 do
					if loadedRecipients[i] == recipientData then
						table.remove(loadedRecipients, i)
						break
					end
				end

				card:Destroy()
				addLog("Failed to load " .. username .. ": " .. tostring(result), Color3.fromRGB(255, 120, 120))
			end
		end)
	end
end

--// STOCK MULTIPLIERS

local function parseMultiplierText(text)
	text = cleanNumberText(text)

	local found =
		text:match("[xX]%s*([%d%.]+)")
		or text:match("([%d%.]+)%s*[xX]")
		or text:match("([%d%.]+)")

	local numberValue = tonumber(found)

	if numberValue and numberValue >= MIN_VALID_MULTI and numberValue <= MAX_VALID_MULTI then
		return numberValue
	end

	return nil
end

local function getStockScrollingFrame()
	local fruitStockPrice = playerGui:FindFirstChild("FruitStockPrice")
	if not fruitStockPrice then
		return nil, "FruitStockPrice not found"
	end

	local frame = fruitStockPrice:FindFirstChild("Frame")
	if not frame then
		return nil, "FruitStockPrice.Frame not found"
	end

	local scrollingFrame = frame:FindFirstChild("ScrollingFrame")
	if not scrollingFrame then
		return nil, "FruitStockPrice.Frame.ScrollingFrame not found"
	end

	return scrollingFrame, "found"
end

local function getFruitCardMultiplier(card)
	local innerFrame = card:FindFirstChild("Frame")
	if not innerFrame then
		return nil
	end

	local multiplierLabel = innerFrame:FindFirstChild("Multiplier")
	if not multiplierLabel or not isTextObject(multiplierLabel) then
		return nil
	end

	return parseMultiplierText(multiplierLabel.Text)
end

local function buildStockMultiplierMap()
	local map = {}
	local cardCount = 0

	local scrollingFrame, reason = getStockScrollingFrame()
	if not scrollingFrame then
		lastStockCardCount = 0
		lastStatus = reason
		return map
	end

	local seenCards = {}

	local function readCard(card)
		if seenCards[card] or card.Name ~= "FruitCard" then
			return
		end

		seenCards[card] = true

		local fruitName = card:GetAttribute("SeedToolTip")
		local multi = getFruitCardMultiplier(card)

		if typeof(fruitName) == "string" and fruitName ~= "" and multi then
			map[normalizeName(fruitName)] = multi
			cardCount += 1
		end
	end

	for _, card in ipairs(scrollingFrame:GetChildren()) do
		readCard(card)
	end

	for _, card in ipairs(scrollingFrame:GetDescendants()) do
		readCard(card)
	end

	lastStockCardCount = cardCount
	lastStatus = cardCount > 0 and "stock multipliers loaded" or "no readable stock cards"

	return map
end

local function findMultiplierForFruitName(fruitName, multiplierMap)
	local directKey = normalizeName(fruitName)

	if multiplierMap[directKey] then
		return multiplierMap[directKey], "exact"
	end

	for key, multi in pairs(multiplierMap) do
		if directKey:find(key, 1, true) or key:find(directKey, 1, true) then
			return multi, "contains"
		end
	end

	-- Hypno Bloom support:
	-- Hypno Bloom has its own stock card, so do not borrow Moon Bloom's multiplier.
	if HYPNO_BLOOM_USES_MOON_BLOOM_MULTIPLIER and isHypnoBloomName(fruitName) then
		local moonKey = normalizeName("Moon Bloom")

		if multiplierMap[moonKey] then
			return multiplierMap[moonKey], "moon bloom multi for hypno"
		end

		for key, multi in pairs(multiplierMap) do
			if key:find("moonbloom", 1, true) then
				return multi, "moon bloom multi for hypno"
			end
		end
	end

	return FALLBACK_SELL_MULTI, "fallback"
end

local function getSpecialBaseValueOverride(instance, fruitName, currentValue, sellMulti, multiSource)
	if isHypnoBloomName(fruitName) then
		-- Main path: currentValue / multiplier is still the most accurate.
		-- For Hypno, the multiplier should come from Hypno Bloom's own stock card.
		if multiSource ~= "fallback" and sellMulti and sellMulti > 0 then
			return currentValue / sellMulti, "hypno using " .. tostring(multiSource)
		end

		-- Optional fallback if no multiplier exists and you fill MOON_BLOOM_BASE_KG.
		local kg = getFruitKgFromInstance(instance)

		if kg and MOON_BLOOM_BASE_KG and MOON_BLOOM_BASE_KG > 0 then
			return HYPNO_BLOOM_BASE_PRICE * ((kg / MOON_BLOOM_BASE_KG) ^ 2), "hypno kg fallback price 9500"
		end
	end

	return nil, nil
end

--// FRUIT DETECTION

local function getTrackedRoots()
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

local function isTrackedInventoryInstance(instance)
	for _, root in ipairs(getTrackedRoots()) do
		if instance == root or instance:IsDescendantOf(root) then
			return true
		end
	end

	return false
end

local function getAncestorTool(instance)
	local current = instance

	while current and current ~= game do
		if current:IsA("Tool") then
			return current
		end

		current = current.Parent
	end

	return nil
end

local function friendlyToolName(name)
	name = tostring(name or "")

	local fruitName, mutation = name:match("^Fruit:([^:]+):([^:]+):")
	if fruitName and mutation then
		return fruitName .. " [" .. mutation .. "]"
	end

	local justFruit = name:match("^Fruit:([^:]+):")
	if justFruit then
		return justFruit
	end

	return name
end

local function getDisplayNameFromInstance(instance)
	local value = getAttributeString(instance, FRUIT_NAME_ATTRIBUTES)
	if value then
		return friendlyToolName(value)
	end

	local ancestorTool = getAncestorTool(instance)
	if ancestorTool then
		local toolValue = getAttributeString(ancestorTool, FRUIT_NAME_ATTRIBUTES)
		if toolValue then
			return friendlyToolName(toolValue)
		end

		return friendlyToolName(ancestorTool.Name)
	end

	return friendlyToolName(instance.Name)
end

local function scanAttributesForUuid(obj, label)
	if not obj then
		return nil, nil
	end

	local ok, attrs = pcall(function()
		return obj:GetAttributes()
	end)

	if ok and typeof(attrs) == "table" then
		for attrName, attrValue in pairs(attrs) do
			if typeof(attrValue) == "string" then
				local uuid = findUuidInText(attrValue)
				if uuid then
					return uuid, label .. "." .. tostring(attrName)
				end
			end
		end
	end

	return nil, nil
end

local function getItemKeyFromInstance(instance)
	local key, attrName = getAttributeString(instance, EXACT_ITEM_KEY_ATTRIBUTES)
	if key then
		return key, "instance." .. tostring(attrName)
	end

	local ancestorTool = getAncestorTool(instance)

	if ancestorTool then
		local toolKey, toolAttrName = getAttributeString(ancestorTool, EXACT_ITEM_KEY_ATTRIBUTES)
		if toolKey then
			return toolKey, "tool." .. tostring(toolAttrName)
		end
	end

	local fallback, fallbackAttr = getAttributeString(instance, FALLBACK_ITEM_KEY_ATTRIBUTES)
	if fallback then
		return fallback, "instance." .. tostring(fallbackAttr)
	end

	if ancestorTool then
		local toolFallback, toolFallbackAttr = getAttributeString(ancestorTool, FALLBACK_ITEM_KEY_ATTRIBUTES)
		if toolFallback then
			return toolFallback, "tool." .. tostring(toolFallbackAttr)
		end
	end

	local uuid, uuidSource = scanAttributesForUuid(instance, "instance")
	if uuid then
		return uuid, uuidSource
	end

	if ancestorTool then
		local toolUuid, toolUuidSource = scanAttributesForUuid(ancestorTool, "tool")
		if toolUuid then
			return toolUuid, toolUuidSource
		end
	end

	return nil, "missing"
end

local function isHarvestedFruitInstance(instance)
	if instance:GetAttribute(HARVESTED_ATTRIBUTE) ~= true then
		return false
	end

	return getAttributeNumber(instance, FRUIT_VALUE_ATTRIBUTE) ~= nil
end

local function cacheFruitOnce(instance, reason)
	if not running then
		return
	end

	if not instance or not instance.Parent then
		return
	end

	if fruitCache[instance] and not RECALCULATE_EXISTING_FRUITS then
		return
	end

	if not isTrackedInventoryInstance(instance) then
		return
	end

	if not isHarvestedFruitInstance(instance) then
		return
	end

	local fruitValue = getAttributeNumber(instance, FRUIT_VALUE_ATTRIBUTE)
	if not fruitValue then
		return
	end

	local itemKey, itemKeySource = getItemKeyFromInstance(instance)
	local multiplierMap = buildStockMultiplierMap()
	local fruitName = getDisplayNameFromInstance(instance)
	local sellMulti, multiSource = findMultiplierForFruitName(fruitName, multiplierMap)

	local baseValue = fruitValue / sellMulti
	local specialBaseValue, specialSource = getSpecialBaseValueOverride(instance, fruitName, fruitValue, sellMulti, multiSource)

	if specialBaseValue then
		baseValue = specialBaseValue
		multiSource = specialSource
	end

	fruitCache[instance] = {
		instance = instance,
		fruitName = fruitName,
		itemKey = itemKey,
		itemKeySource = itemKeySource,
		currentValue = fruitValue,
		sellMulti = sellMulti,
		baseValue = baseValue,
		multiSource = multiSource,
		reason = reason or "cached",
	}

	if refreshUI then
		refreshUI()
	end
end

local function connectInstance(instance)
	if connectedInstances[instance] then
		return
	end

	connectedInstances[instance] = true

	cacheFruitOnce(instance, "detected")

	instance:GetAttributeChangedSignal(HARVESTED_ATTRIBUTE):Connect(function()
		cacheFruitOnce(instance, HARVESTED_ATTRIBUTE .. " changed")
	end)

	instance:GetAttributeChangedSignal(FRUIT_VALUE_ATTRIBUTE):Connect(function()
		if RECALCULATE_EXISTING_FRUITS or not fruitCache[instance] then
			cacheFruitOnce(instance, FRUIT_VALUE_ATTRIBUTE .. " changed")
		elseif refreshUI then
			refreshUI()
		end
	end)

	local watchedKeyAttrs = {}
	for _, attrName in ipairs(EXACT_ITEM_KEY_ATTRIBUTES) do
		table.insert(watchedKeyAttrs, attrName)
	end
	for _, attrName in ipairs(FALLBACK_ITEM_KEY_ATTRIBUTES) do
		table.insert(watchedKeyAttrs, attrName)
	end
	for _, attrName in ipairs(FRUIT_NAME_ATTRIBUTES) do
		table.insert(watchedKeyAttrs, attrName)
	end

	for _, attrName in ipairs(watchedKeyAttrs) do
		instance:GetAttributeChangedSignal(attrName):Connect(function()
			if not fruitCache[instance] or not fruitCache[instance].itemKey or RECALCULATE_EXISTING_FRUITS then
				cacheFruitOnce(instance, attrName .. " changed")
			end
		end)
	end

	instance.AncestryChanged:Connect(function()
		task.defer(function()
			if not instance.Parent or not isTrackedInventoryInstance(instance) then
				fruitCache[instance] = nil
				if refreshUI then
					refreshUI()
				end
			elseif refreshUI then
				refreshUI()
			end
		end)
	end)
end

local function scanRoot(root)
	if not root then
		return
	end

	connectInstance(root)

	for _, obj in ipairs(root:GetDescendants()) do
		connectInstance(obj)
	end
end

local function connectRoot(root)
	if not root or connectedRoots[root] then
		return
	end

	connectedRoots[root] = true

	scanRoot(root)

	root.DescendantAdded:Connect(function(obj)
		connectInstance(obj)
		cacheFruitOnce(obj, "new descendant")
	end)

	root.DescendantRemoving:Connect(function(obj)
		task.defer(function()
			if fruitCache[obj] and (not obj.Parent or not isTrackedInventoryInstance(obj)) then
				fruitCache[obj] = nil

				if refreshUI then
					refreshUI()
				end
			end
		end)
	end)
end

local function getCachedFruitsArray(onlyMailable, excludeSent)
	local fruits = {}

	for instance, data in pairs(fruitCache) do
		if instance and instance.Parent and isTrackedInventoryInstance(instance) then
			data.isEquipped = player.Character and instance:IsDescendantOf(player.Character)

			local canUse = true

			if onlyMailable and not data.itemKey then
				canUse = false
			end

			if excludeSent and data.itemKey and sentKeySet[data.itemKey] then
				canUse = false
			end

			if canUse then
				table.insert(fruits, data)
			end
		else
			fruitCache[instance] = nil
		end
	end

	table.sort(fruits, function(a, b)
		return a.baseValue > b.baseValue
	end)

	return fruits
end

--// TARGET SELECTION

local function getSelectionTotal(fruits)
	local total = 0

	for _, fruit in ipairs(fruits) do
		total += fruit.baseValue
	end

	return total
end

local function selectClosestAtOrOverTarget(fruits, targetValue)
	local n = #fruits

	if n == 0 then
		return {}, 0, "no fruits"
	end

	local totalAvailable = getSelectionTotal(fruits)

	if totalAvailable < targetValue then
		if SEND_PARTIAL_IF_NOT_ENOUGH then
			return copyArray(fruits), totalAvailable, "partial below target"
		end

		return nil, totalAvailable, "not enough unsent value"
	end

	if n > MAX_OPTIMIZED_TARGET_FRUITS then
		local ascending = copyArray(fruits)
		table.sort(ascending, function(a, b)
			return a.baseValue < b.baseValue
		end)

		local selected = {}
		local sum = 0

		for _, fruit in ipairs(ascending) do
			table.insert(selected, fruit)
			sum += fruit.baseValue

			if sum >= targetValue then
				break
			end
		end

		local changed = true

		while changed do
			changed = false

			table.sort(selected, function(a, b)
				return a.baseValue > b.baseValue
			end)

			for i = #selected, 1, -1 do
				local fruit = selected[i]

				if sum - fruit.baseValue >= targetValue then
					sum -= fruit.baseValue
					table.remove(selected, i)
					changed = true
				end
			end
		end

		table.sort(selected, function(a, b)
			return a.baseValue > b.baseValue
		end)

		return selected, sum, "greedy closest >= target"
	end

	local mid = math.floor(n / 2)

	local function generateSubsets(startIndex, endIndex)
		local subsets = {}

		local function rec(i, sum, count, selectedIndexes)
			if i > endIndex then
				table.insert(subsets, {
					sum = sum,
					count = count,
					indexes = copyArray(selectedIndexes),
				})
				return
			end

			rec(i + 1, sum, count, selectedIndexes)

			table.insert(selectedIndexes, i)
			rec(i + 1, sum + fruits[i].baseValue, count + 1, selectedIndexes)
			table.remove(selectedIndexes)
		end

		rec(startIndex, 0, 0, {})
		return subsets
	end

	local left = generateSubsets(1, mid)
	local right = generateSubsets(mid + 1, n)

	table.sort(right, function(a, b)
		if a.sum ~= b.sum then
			return a.sum < b.sum
		end

		return a.count < b.count
	end)

	local best = nil

	local function better(candidate)
		if not best then
			return true
		end

		local extra = candidate.sum - targetValue
		local bestExtra = best.sum - targetValue

		if extra ~= bestExtra then
			return extra < bestExtra
		end

		if candidate.count ~= best.count then
			return candidate.count < best.count
		end

		return candidate.sum < best.sum
	end

	for _, l in ipairs(left) do
		local needed = targetValue - l.sum
		local lo = 1
		local hi = #right
		local found = nil

		while lo <= hi do
			local m = math.floor((lo + hi) / 2)

			if right[m].sum >= needed then
				found = m
				hi = m - 1
			else
				lo = m + 1
			end
		end

		if found then
			local r = right[found]
			local candidate = {
				sum = l.sum + r.sum,
				count = l.count + r.count,
				left = l,
				right = r,
			}

			if candidate.sum >= targetValue and better(candidate) then
				best = candidate
			end
		end
	end

	if not best then
		return copyArray(fruits), totalAvailable, "fallback all"
	end

	local selected = {}
	local used = {}

	for _, index in ipairs(best.left.indexes) do
		if not used[index] then
			used[index] = true
			table.insert(selected, fruits[index])
		end
	end

	for _, index in ipairs(best.right.indexes) do
		if not used[index] then
			used[index] = true
			table.insert(selected, fruits[index])
		end
	end

	table.sort(selected, function(a, b)
		return a.baseValue > b.baseValue
	end)

	return selected, best.sum, "closest >= target"
end

local function splitIntoBatches(fruits, batchSize)
	local batches = {}
	local current = {}

	for _, fruit in ipairs(fruits) do
		table.insert(current, fruit)

		if #current >= batchSize then
			table.insert(batches, current)
			current = {}
		end
	end

	if #current > 0 then
		table.insert(batches, current)
	end

	return batches
end

--// PACKET BUILDERS

local function buildRecipientPacket(username, packetByte)
	username = tostring(username or "")

	if username == "" then
		error("Recipient username is empty.")
	end

	if #username > 255 then
		error("Username too long.")
	end

	return buffer.fromstring(
		string.char(0x1D, 0x01, packetByte)
		.. string.char(#username)
		.. username
	)
end

local function buildSingleFruitEntry(itemKey)
	itemKey = tostring(itemKey or "")

	if itemKey == "" then
		error("Missing ItemKey/UUID.")
	end

	return
		string.char(0x1C)
		.. string.char(0x0B, 0x07) .. "ItemKey"
		.. string.char(0x0B, 0x24) .. itemKey
		.. string.char(0x0B, 0x05) .. "Count"
		.. string.char(0x05, 0x01)
		.. string.char(0x0B, 0x08) .. "Category"
		.. string.char(0x0B, 0x0F) .. "HarvestedFruits"
		.. string.char(0x00)
end

local function buildFruitMailPacket(itemKeys, packetByte, recipientUserId)
	if typeof(itemKeys) ~= "table" or #itemKeys == 0 then
		error("itemKeys must be a non-empty array.")
	end

	if #itemKeys > MAX_FRUITS_PER_MAIL then
		error("Cannot send more than " .. tostring(MAX_FRUITS_PER_MAIL) .. " fruits in one mail.")
	end

	local recipientBytes = userIdToMailBytes(recipientUserId)

	if #recipientBytes ~= 8 then
		error("Recipient UserId bytes must be exactly 8 bytes.")
	end

	local packet =
		string.char(0x1C, 0x01, packetByte)
		.. recipientBytes
		.. string.char(0x1C, 0x05, 0x01)

	for index, itemKey in ipairs(itemKeys) do
		if index > 1 then
			packet ..= string.char(0x05, index)
		end

		packet ..= buildSingleFruitEntry(itemKey)
	end

	packet ..= string.char(0x00, 0x06) .. "fruits"

	return buffer.fromstring(packet)
end

local function getItemKeysFromBatch(batch)
	local keys = {}

	for _, fruit in ipairs(batch) do
		if fruit.itemKey then
			table.insert(keys, fruit.itemKey)
		end
	end

	return keys
end

local function markFruitsAsSent(fruits)
	for _, fruit in ipairs(fruits) do
		if fruit.itemKey then
			sentKeySet[fruit.itemKey] = true
		end
	end
end

--// REFRESH / PREVIEW

updateTargetFormattedLabel = function()
	local targetValue = parseUserNumber(targetBox.Text)

	if targetValue and targetValue > 0 then
		targetFormattedLabel.Text = formatShortNumber(targetValue) .. " (" .. formatNumber(targetValue) .. ")"
		targetFormattedLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	else
		local fallback = parseUserNumber(DEFAULT_TARGET_VALUE) or 1000000000
		targetFormattedLabel.Text = "default " .. formatShortNumber(fallback)
		targetFormattedLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	end
end

refreshUI = function()
	if not running then
		return
	end

	local fruits = getCachedFruitsArray(false, false)
	local mailable = getCachedFruitsArray(true, true)

	local totalCurrent = 0
	local totalBase = 0
	local fallbackCount = 0

	for _, fruit in ipairs(fruits) do
		totalCurrent += fruit.currentValue
		totalBase += fruit.baseValue

		if fruit.multiSource == "fallback" then
			fallbackCount += 1
		end
	end

	statsLabel.Text = string.format(
		"Fruits: %d | Mailable unsent: %d | Base: %s | Current: %s | Stock: %d | Fallback: %d",
		#fruits,
		#mailable,
		formatShortNumber(totalBase),
		formatShortNumber(totalCurrent),
		lastStockCardCount,
		fallbackCount
	)
end

local function getRecipientsForPlanning()
	local result = {}
	local seen = {}

	-- Loaded avatar cards are the main source, because each one has its own amount box.
	for _, recipient in ipairs(loadedRecipients) do
		local key = recipient.Username:lower()

		if not seen[key] then
			seen[key] = true
			table.insert(result, recipient)
		end
	end

	-- If someone typed usernames but did not click Load yet, include them with the default target.
	-- They will not have avatar cards until Load is clicked.
	for _, recipient in ipairs(parseRecipientQueries(recipientBox.Text)) do
		local key = recipient.Username:lower()

		if not seen[key] then
			seen[key] = true
			table.insert(result, recipient)
		end
	end

	return result
end

local function getDefaultTargetValue()
	local value = parseUserNumber(targetBox.Text)

	if value and value > 0 then
		return value
	end

	return parseUserNumber(DEFAULT_TARGET_VALUE) or 1000000000
end

local function getRecipientTargetValue(recipient, defaultTargetValue)
	if recipient.TargetInput then
		local value = parseUserNumber(recipient.TargetInput.Text)

		if value and value > 0 then
			return value
		end

		return nil
	end

	return defaultTargetValue
end

local function getDefaultFruitTargetCount()
	local count = math.floor(tonumber(fruitCountBox.Text) or 0)
	return count > 0 and count or DEFAULT_TARGET_FRUIT_COUNT
end

local function getRecipientFruitTargetCount(recipient, defaultCount)
	if recipient.TargetInput then
		local count = math.floor(tonumber(cleanNumberText(recipient.TargetInput.Text)) or 0)
		return count > 0 and count or nil
	end
	return defaultCount
end

local function getAvailableFruitPool(source, usedSet)
	local result = {}
	for _, fruit in ipairs(source) do
		if fruit.itemKey and (not usedSet or not usedSet[fruit.itemKey]) then
			table.insert(result, fruit)
		end
	end
	table.sort(result, function(a, b)
		return (a.baseValue or 0) > (b.baseValue or 0)
	end)
	return result
end

local function takeFruitCount(source, amount)
	local selected = {}

	for index = 1, math.min(amount, #source) do
		table.insert(selected, source[index])
	end

	return selected, getSelectionTotal(selected)
end

local function makePreview()
	local recipients = getRecipientsForPlanning()
	local targetValue = getDefaultTargetValue()
	local targetFruitCount = targetMode == "Fruit" and getDefaultFruitTargetCount() or nil

	if #recipients == 0 then
		previewLabel.Text = "Preview: enter at least one username."
		previewLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
		return nil
	end

	local available = getCachedFruitsArray(true, true)
	local tempUsed = {}
	local previewPlans = {}
	local totalSelected = 0
	local totalFruitCount = 0

	for _, recipient in ipairs(recipients) do
		local username = recipient.Username
		local selected = {}
		local selectedTotal = 0
		local reason = "no current fruits"
		local plan = {
			Username = username,
			Fruits = {},
			Total = 0,
			Batches = {},
			Reason = reason,
			Skipped = false,
			LiveRefill = LIVE_REFILL_MAILING,
			Mode = targetMode,
		}

		if targetMode == "Fruit" then
			local recipientCount = getRecipientFruitTargetCount(recipient, targetFruitCount)

			if not recipientCount or recipientCount <= 0 then
				plan.Reason = "invalid user fruit count"
				plan.TargetCount = 0
				plan.Skipped = true
				table.insert(previewPlans, plan)
				continue
			end

			local pool = getAvailableFruitPool(available, tempUsed)
			selected, selectedTotal = takeFruitCount(pool, recipientCount)
			reason = #selected >= recipientCount
				and "fruit count ready"
				or (LIVE_REFILL_MAILING and "sending current fruits, then waiting refill" or "not enough fruits")
			plan.TargetCount = recipientCount
			plan.Target = selectedTotal
		else
			local recipientTarget = getRecipientTargetValue(recipient, targetValue)

			if not recipientTarget or recipientTarget <= 0 then
				plan.Reason = "invalid user target"
				plan.Target = 0
				plan.Skipped = true
				table.insert(previewPlans, plan)
				continue
			end

			local pool = {}
			for _, fruit in ipairs(available) do
				if fruit.itemKey and not tempUsed[fruit.itemKey] then
					table.insert(pool, fruit)
				end
			end

			local poolTotal = getSelectionTotal(pool)
			if #pool == 0 then
				reason = LIVE_REFILL_MAILING and "no current fruits; will wait for mail refills" or "no fruits"
			elseif poolTotal < recipientTarget and SEND_CURRENT_INVENTORY_WHEN_BELOW_TARGET then
				selected = copyArray(pool)
				selectedTotal = poolTotal
				reason = LIVE_REFILL_MAILING and "sending all current inventory, then waiting refill" or "sending all current inventory"
			elseif poolTotal >= recipientTarget then
				local picked, pickedTotal, pickedReason = selectClosestAtOrOverTarget(pool, recipientTarget)
				if picked and #picked > 0 then
					selected, selectedTotal, reason = picked, pickedTotal, pickedReason
				else
					selected, selectedTotal, reason = copyArray(pool), poolTotal, "selector fallback: sending current inventory"
				end
			else
				reason = "not enough current inventory"
			end
			plan.Target = recipientTarget
		end

		for _, fruit in ipairs(selected) do
			tempUsed[fruit.itemKey] = true
		end

		plan.Fruits = selected
		plan.Total = selectedTotal
		plan.Batches = splitIntoBatches(selected, MAX_FRUITS_PER_MAIL)
		plan.Reason = reason
		table.insert(previewPlans, plan)
		totalSelected += selectedTotal
		totalFruitCount += #selected
	end

	local mailCount = 0
	local waitingUsers = 0
	for _, plan in ipairs(previewPlans) do
		if not plan.Skipped then
			mailCount += #plan.Batches
			if plan.Mode == "Fruit" then
				if #plan.Fruits < (plan.TargetCount or 0) then waitingUsers += 1 end
			elseif plan.Total < (plan.Target or 0) then
				waitingUsers += 1
			end
		end
	end

	local previewLines = {}
	local usedMails, remainingMails, resetIn = getMailLimitState()

	table.insert(
		previewLines,
		string.format(
			"Mail allowance: %d/%d used | %d left%s",
			usedMails,
			mailLimitCount,
			remainingMails,
			remainingMails <= 0 and (" | reset in " .. formatDuration(resetIn)) or ""
		)
	)

	if targetMode == "Fruit" then
		table.insert(
			previewLines,
			string.format(
				"Fruit-count preview — default %d per account | Total base %s",
				targetFruitCount,
				formatShortNumber(totalSelected)
			)
		)
	else
		table.insert(
			previewLines,
			string.format(
				"Value preview — %d fruit%s | %d mail%s | Total base %s",
				totalFruitCount,
				totalFruitCount == 1 and "" or "s",
				mailCount,
				mailCount == 1 and "" or "s",
				formatShortNumber(totalSelected)
			)
		)
	end

	for _, plan in ipairs(previewPlans) do
		local accountStatus

		if plan.Skipped then
			accountStatus = "SKIPPED: " .. tostring(plan.Reason)
		elseif plan.Mode == "Fruit" then
			accountStatus = string.format(
				"%d/%d fruit | %d mail%s | Base %s | %s",
				#plan.Fruits,
				plan.TargetCount or 0,
				#plan.Batches,
				#plan.Batches == 1 and "" or "s",
				formatShortNumber(plan.Total or 0),
				tostring(plan.Reason)
			)
		else
			accountStatus = string.format(
				"%d fruit | %d mail%s | %s/%s base | %s",
				#plan.Fruits,
				#plan.Batches,
				#plan.Batches == 1 and "" or "s",
				formatShortNumber(plan.Total or 0),
				formatShortNumber(plan.Target or 0),
				tostring(plan.Reason)
			)
		end

		table.insert(previewLines, tostring(plan.Username) .. ": " .. accountStatus)
	end

	previewLabel.Text = table.concat(previewLines, "\n")

	previewLabel.TextColor3 = waitingUsers > 0 and Color3.fromRGB(255, 220, 120) or Color3.fromRGB(170, 220, 255)
	return previewPlans
end

local function waitMailCooldown(seconds, nextLabel)
	seconds = tonumber(seconds) or MAIL_COOLDOWN_SECONDS

	for remaining = seconds, 0, -1 do
		if not mailing then
			return
		end

		local textRemaining = string.format("%.0f", remaining)
		addLog("Cooldown " .. textRemaining .. "s before next mail" .. (nextLabel and (" → " .. nextLabel) or "") .. ".", Color3.fromRGB(255, 220, 120))
		task.wait(1)
	end
end

local function rescanInventoryNow()
	buildStockMultiplierMap()

	for _, root in ipairs(getTrackedRoots()) do
		connectRoot(root)
		scanRoot(root)
	end

	refreshUI()
end

local function waitForNewMailableFruits(timeoutSeconds)
	local elapsed = 0

	while mailing and elapsed < timeoutSeconds do
		rescanInventoryNow()

		local available = getCachedFruitsArray(true, true)

		if #available > 0 then
			return available
		end

		local remaining = math.max(0, math.floor(timeoutSeconds - elapsed + 0.5))
		addLog("No current fruits. Waiting for mail claim refill... " .. tostring(remaining) .. "s", Color3.fromRGB(255, 220, 120))

		task.wait(REFILL_RESCAN_INTERVAL)
		elapsed += REFILL_RESCAN_INTERVAL
	end

	rescanInventoryNow()
	return getCachedFruitsArray(true, true)
end

local function selectLiveRefillBatch(remainingTarget)
	rescanInventoryNow()

	local available = getCachedFruitsArray(true, true)

	if #available == 0 then
		return {}, 0, "no current fruits"
	end

	local totalAvailable = getSelectionTotal(available)

	if totalAvailable >= remainingTarget then
		local selected, selectedTotal, reason = selectClosestAtOrOverTarget(available, remainingTarget)

		if selected and #selected > 0 then
			return selected, selectedTotal, reason
		end
	end

	if SEND_CURRENT_INVENTORY_WHEN_BELOW_TARGET then
		table.sort(available, function(a, b)
			return a.baseValue > b.baseValue
		end)

		local selected = {}

		for i = 1, math.min(MAX_FRUITS_PER_MAIL, #available) do
			table.insert(selected, available[i])
		end

		return selected, getSelectionTotal(selected), "below target; sending current inventory batch"
	end

	return {}, totalAvailable, "below target and partial sending disabled"
end

local function selectLiveFruitBatch(remainingCount)
	rescanInventoryNow()
	local available = getCachedFruitsArray(true, true)

	if #available == 0 then
		return {}, 0, "no current fruits"
	end

	table.sort(available, function(a, b)
		return (a.baseValue or 0) > (b.baseValue or 0)
	end)

	local amount = math.min(remainingCount, MAX_FRUITS_PER_MAIL, #available)
	local selected, selectedTotal = takeFruitCount(available, amount)

	return selected, selectedTotal,
		#selected >= remainingCount and "fruit target ready" or "partial fruit batch"
end

--// MAILING

local function sendPlans(plans, reason)
	if mailing then
		addLog("Already mailing. Wait for current send to finish.", Color3.fromRGB(255, 220, 120))
		return
	end
	if not plans or #plans == 0 then
		addLog("No mail plans to send.", Color3.fromRGB(255, 120, 120))
		return
	end

	local usedMails, remainingMails, resetIn = getMailLimitState()
	if remainingMails <= 0 then
		addLog(
			string.format(
				"Mail limit reached: %d/%d in %.1f hours. Reset in %s.",
				usedMails,
				mailLimitCount,
				mailLimitWindowHours,
				formatDuration(resetIn)
			),
			Color3.fromRGB(255, 120, 120)
		)
		updateMailLimitDisplay()
		return
	end

	local packetByte
	local okSeq, seqErr = pcall(function() packetByte = parseHexByte(seqBox.Text) end)
	if not okSeq then
		addLog("Bad sequence byte: " .. tostring(seqErr), Color3.fromRGB(255, 120, 120))
		return
	end

	mailing = true
	sendButton.Text = "Sending..."
	prepareProgressRows(plans)

	task.spawn(function()
		local ok, err = pcall(function()
			local needsCooldownBeforeNextMail = false

			for _, plan in ipairs(plans) do
				if plan.Skipped then
					addLog("Skipped " .. tostring(plan.Username) .. ": " .. tostring(plan.Reason), Color3.fromRGB(255, 220, 120))
					continue
				end

				local username = plan.Username
				local mode = plan.Mode or "Value"
				local targetValue = plan.Target or 0
				local targetCount = plan.TargetCount or 0
				
				if mode == "Fruit" then
					if targetCount <= 0 then
						addLog("Skipped " .. username .. ": invalid fruit-count target.", Color3.fromRGB(255, 120, 120))
						continue
					end
				elseif targetValue <= 0 then
					addLog("Skipped " .. username .. ": invalid value target.", Color3.fromRGB(255, 120, 120))
					continue
				end

				local userId = getUserIdFromUsername(username)
				local sentFruits, sentTotal, sentMails, sentCount = {}, 0, 0, 0
				local stoppedReason = "completed"

				if mode == "Fruit" then
					addLog(string.format("Fruit-count mailing to %s | target %d fruits.", username, targetCount), Color3.fromRGB(170, 220, 255))
					updateProgressValueRow(username, 0, targetCount, 0, "0 fruits", Color3.fromRGB(90, 180, 110))
				else
					addLog("Value mailing to " .. username .. " | target " .. formatShortNumber(targetValue) .. ".", Color3.fromRGB(170, 220, 255))
					updateProgressValueRow(username, 0, targetValue, 0, "starting", Color3.fromRGB(90, 180, 110))
				end

				while mailing and ((mode == "Fruit" and sentCount < targetCount) or (mode == "Value" and sentTotal < targetValue)) do
					local selected, selectedTotal
					if mode == "Fruit" then
						selected, selectedTotal = selectLiveFruitBatch(targetCount - sentCount)
					else
						selected, selectedTotal = selectLiveRefillBatch(targetValue - sentTotal)
					end

					if not selected or #selected == 0 then
						if not LIVE_REFILL_MAILING then
							stoppedReason = "no current fruits"
							break
						end

						local progressNow = mode == "Fruit" and sentCount or sentTotal
						local progressTarget = mode == "Fruit" and targetCount or targetValue
						updateProgressValueRow(username, progressNow, progressTarget, sentMails, "waiting refill", Color3.fromRGB(255, 190, 90))
						local newAvailable = waitForNewMailableFruits(WAIT_FOR_NEW_FRUITS_SECONDS)
						if not newAvailable or #newAvailable == 0 then
							stoppedReason = "stopped: no new fruits from mail"
							break
						end
						continue
					end

					for _, batch in ipairs(splitIntoBatches(selected, MAX_FRUITS_PER_MAIL)) do
						if not mailing then break end

						local usedNow, remainingNow, resetNow = getMailLimitState()
						if remainingNow <= 0 then
							stoppedReason = string.format(
								"mail limit reached (%d/%d); reset in %s",
								usedNow,
								mailLimitCount,
								formatDuration(resetNow)
							)
							mailing = false
							updateMailLimitDisplay()
							break
						end

						if needsCooldownBeforeNextMail then waitMailCooldown(MAIL_COOLDOWN_SECONDS, username .. " next mail") end
						local itemKeys = getItemKeysFromBatch(batch)
						if #itemKeys == 0 then stoppedReason = "selected batch had no item keys" break end

						local recipientByte = packetByte
						packetByte = incrementPacketByte(packetByte)
						local fruitPacketByte = packetByte
						packetByte = incrementPacketByte(packetByte)
						local batchValue = getSelectionTotal(batch)

						addLog(string.format("%s mail %d | %d fruit(s) | Base %s | seq %02X/%02X", username, sentMails + 1, #itemKeys, formatShortNumber(batchValue), recipientByte, fruitPacketByte))
						Event:FireServer(buildRecipientPacket(username, recipientByte))
						task.wait(RECIPIENT_PACKET_DELAY)
						Event:FireServer(buildFruitMailPacket(itemKeys, fruitPacketByte, userId))
						recordMailUsage()
						task.wait(MAIL_BATCH_DELAY)

						needsCooldownBeforeNextMail = true
						sentMails += 1
						sentTotal += batchValue
						sentCount += #batch
						for _, fruit in ipairs(batch) do table.insert(sentFruits, fruit) end
						markFruitsAsSent(batch)
						refreshUI()

						if mode == "Fruit" then
							updateProgressValueRow(username, sentCount, targetCount, sentMails, string.format("%d/%d | Base %s", sentCount, targetCount, formatShortNumber(sentTotal)), sentCount >= targetCount and Color3.fromRGB(120, 220, 130) or Color3.fromRGB(255, 190, 90))
						else
							local remainingAfter = math.max(0, targetValue - sentTotal)
							updateProgressValueRow(username, sentTotal, targetValue, sentMails, remainingAfter <= 0 and "target reached" or ("left " .. formatShortNumber(remainingAfter)), remainingAfter <= 0 and Color3.fromRGB(120, 220, 130) or Color3.fromRGB(255, 190, 90))
						end
					end
				end

				local complete = mode == "Fruit" and sentCount >= targetCount or sentTotal >= targetValue
				if complete then
					if mode == "Fruit" then
						addLog(string.format("%s fruit-count target reached: %d fruits | Base %s.", username, sentCount, formatShortNumber(sentTotal)), Color3.fromRGB(170, 255, 170))
					else
						addLog(username .. " value target reached: " .. formatShortNumber(sentTotal) .. " sent.", Color3.fromRGB(170, 255, 170))
					end
				else
					addLog(username .. " stopped. Reason: " .. tostring(stoppedReason), Color3.fromRGB(255, 220, 120))
				end

				if #sentFruits > 0 then
					local historyTarget = mode == "Fruit" and sentTotal or targetValue
					local historyReason = mode == "Fruit" and (tostring(targetCount) .. " fruits | " .. stoppedReason) or stoppedReason
					addHistory(username, sentFruits, sentTotal, historyTarget, sentMails, historyReason)
				end
				refreshUI()
			end
		end)

		addLog(ok and "Mailing finished." or ("Send error: " .. tostring(err)), ok and Color3.fromRGB(170, 255, 170) or Color3.fromRGB(255, 120, 120))
		mailing = false
		sendButton.Text = "Mail"
	end)
end

local function makeSendAllPlans()
	local recipients = getRecipientsForPlanning()

	if #recipients == 0 then
		addLog("Enter at least one username.", Color3.fromRGB(255, 220, 120))
		return nil
	end

	local all = getCachedFruitsArray(true, true)

	if #all == 0 then
		addLog("No mailable unsent fruits.", Color3.fromRGB(255, 120, 120))
		return nil
	end

	local plans = {}

	if #recipients == 1 then
		table.insert(plans, {
			Username = recipients[1].Username,
			Fruits = all,
			Total = getSelectionTotal(all),
			Batches = splitIntoBatches(all, MAX_FRUITS_PER_MAIL),
			Reason = "send all",
			Target = getSelectionTotal(all),
		})

		return plans
	end

	local defaultTargetValue = parseUserNumber(targetBox.Text) or 0
	local tempUsed = {}

	for _, recipient in ipairs(recipients) do
		local username = recipient.Username
		local recipientTarget = getRecipientTargetValue(recipient, defaultTargetValue)

		if not recipientTarget or recipientTarget <= 0 then
			table.insert(plans, {
				Username = username,
				Fruits = {},
				Total = 0,
				Batches = {},
				Reason = "invalid user target",
				Target = 0,
				Skipped = true,
			})
			continue
		end

		local pool = {}

		for _, fruit in ipairs(all) do
			if fruit.itemKey and not tempUsed[fruit.itemKey] then
				table.insert(pool, fruit)
			end
		end

		local selected, selectedTotal, reason = selectClosestAtOrOverTarget(pool, recipientTarget)

		if selected then
			for _, fruit in ipairs(selected) do
				tempUsed[fruit.itemKey] = true
			end

			table.insert(plans, {
				Username = username,
				Fruits = selected,
				Total = selectedTotal,
				Batches = splitIntoBatches(selected, MAX_FRUITS_PER_MAIL),
				Reason = recipient.TargetInput and ("send all split by card target " .. formatShortNumber(recipientTarget)) or "send all split by default target",
				Target = recipientTarget,
			})
		else
			table.insert(plans, {
				Username = username,
				Fruits = {},
				Total = 0,
				Batches = {},
				Reason = reason,
				Target = recipientTarget,
				Skipped = true,
			})
		end
	end

	return plans
end

--// BUTTONS

local function buildMailerCloudSettings()
	return {
		version = 1,
		targetMode = targetMode,
		recipients = recipientBox.Text,
		valueTarget = targetBox.Text,
		packetSequence = seqBox.Text,
		fruitCount = math.max(1, math.floor(tonumber(fruitCountBox.Text) or DEFAULT_TARGET_FRUIT_COUNT)),
		mailLimitCount = mailLimitCount,
		mailLimitWindowHours = mailLimitWindowHours,
		mailUsageTimestamps = mailUsageTimestamps,
	}
end

local function queueMailerCloudSave()
	if type(_G.TEBCloudQueueSaveScope) == "function" then
		_G.TEBCloudQueueSaveScope("mailer", buildMailerCloudSettings)
	end
end

_G.TEBHubCloudSections = _G.TEBHubCloudSections or {}
_G.TEBHubCloudSections.Mailer = {
	Get = buildMailerCloudSettings,
}

local function updateMailLimitDisplay()
	local used, remaining, resetIn = getMailLimitState()
	mailLimitCountBox.Text = tostring(mailLimitCount)
	mailWindowBox.Text = tostring(mailLimitWindowHours)

	if remaining <= 0 then
		mailLimitStatus.Text = string.format(
			"%d/%d used | reset in %s",
			used,
			mailLimitCount,
			formatDuration(resetIn)
		)
		mailLimitStatus.TextColor3 = Color3.fromRGB(255, 120, 120)
	else
		mailLimitStatus.Text = string.format(
			"%d/%d used | %d left",
			used,
			mailLimitCount,
			remaining
		)
		mailLimitStatus.TextColor3 = Color3.fromRGB(170, 220, 255)
	end
end

local function recordMailUsage()
	table.insert(mailUsageTimestamps, os.time())
	pruneMailUsage()
	updateMailLimitDisplay()
	queueMailerCloudSave()
end

local function updateTargetModeUI()
	local fruitMode = targetMode == "Fruit"

	valueModeButton.Text = fruitMode and "☐ Value" or "☑ Value"
	fruitModeButton.Text = fruitMode and "☑ Fruits" or "☐ Fruits"

	valueModeButton.BackgroundColor3 = not fruitMode and Color3.fromRGB(45, 115, 65) or Color3.fromRGB(55, 62, 78)
	fruitModeButton.BackgroundColor3 = fruitMode and Color3.fromRGB(45, 115, 65) or Color3.fromRGB(55, 62, 78)

	-- Keep both target sections visible. The checkbox decides which one is used.
	targetBox.Visible = true
	targetFormattedLabel.Visible = true
	fruitCountBox.Visible = true

	targetBox.TextTransparency = fruitMode and 0.45 or 0
	targetFormattedLabel.TextTransparency = fruitMode and 0.45 or 0
	fruitCountBox.TextTransparency = fruitMode and 0 or 0.45
	fruitCountHint.TextTransparency = fruitMode and 0 or 0.45
end

valueModeButton.MouseButton1Click:Connect(function()
	targetMode = "Value"
	updateTargetModeUI()
	queueMailerCloudSave()
	makePreview()
end)

fruitModeButton.MouseButton1Click:Connect(function()
	targetMode = "Fruit"
	updateTargetModeUI()
	queueMailerCloudSave()
	makePreview()
end)

fruitCountBox.FocusLost:Connect(function()
	local count = math.floor(tonumber(fruitCountBox.Text) or 0)
	fruitCountBox.Text = tostring(count > 0 and count or DEFAULT_TARGET_FRUIT_COUNT)
	queueMailerCloudSave()
end)

mailLimitCountBox.FocusLost:Connect(function()
	local value = math.floor(tonumber(mailLimitCountBox.Text) or 0)
	mailLimitCount = math.clamp(value > 0 and value or DEFAULT_MAIL_LIMIT_COUNT, 1, 500)
	updateMailLimitDisplay()
	queueMailerCloudSave()
end)

mailWindowBox.FocusLost:Connect(function()
	local value = tonumber(mailWindowBox.Text)
	mailLimitWindowHours = math.clamp(value and value > 0 and value or DEFAULT_MAIL_LIMIT_WINDOW_HOURS, 1, 168)
	pruneMailUsage()
	updateMailLimitDisplay()
	queueMailerCloudSave()
end)

updateTargetModeUI()
updateMailLimitDisplay()

recipientBox.FocusLost:Connect(queueMailerCloudSave)
seqBox.FocusLost:Connect(queueMailerCloudSave)

targetBox:GetPropertyChangedSignal("Text"):Connect(updateTargetFormattedLabel)

targetBox.FocusLost:Connect(function()
	local targetValue = parseUserNumber(targetBox.Text)

	if targetValue and targetValue > 0 then
		targetBox.Text = formatShortNumber(targetValue)
	elseif tostring(targetBox.Text or ""):gsub("%s+", "") == "" then
		targetBox.Text = DEFAULT_TARGET_VALUE
	end

	updateTargetFormattedLabel()
end)

clearQueryButton.MouseButton1Click:Connect(function()
	recipientBox.Text = ""

	for _, child in ipairs(avatarFrame:GetChildren()) do
		if child:IsA("Frame") and child.Name == "AvatarCard" then
			child:Destroy()
		end
	end

	table.clear(loadedRecipients)
	table.clear(loadedRecipientMap)
	table.clear(avatarCardMap)

	addLog("Cleared username query and loaded user cards.", Color3.fromRGB(255, 220, 120))
end)

recipientBox.FocusLost:Connect(function()
	loadRecipientsFromBox()
end)

loadUsersButton.MouseButton1Click:Connect(loadRecipientsFromBox)

previewButton.MouseButton1Click:Connect(function()
	makePreview()
end)

sendButton.MouseButton1Click:Connect(function()
	local plans = makePreview()

	if plans then
		sendPlans(plans, "target")
	end
end)


rescanButton.MouseButton1Click:Connect(function()
	fruitCache = {}
	connectedInstances = {}
	connectedRoots = {}
	sentKeySet = {}

	buildStockMultiplierMap()

	for _, root in ipairs(getTrackedRoots()) do
		connectRoot(root)
		scanRoot(root)
	end

	refreshUI()
	addLog("Rescanned with stable scanner. Cache/sent memory cleared; values can update safely.")
end)

-- Remote response logger if the game replies on the same RemoteEvent.
pcall(function()
	Event.OnClientEvent:Connect(function(...)
		local parts = {}

		for i, value in ipairs({ ... }) do
			table.insert(parts, "[" .. tostring(i) .. "] " .. typeof(value) .. "=" .. tostring(value))
		end

		addLog("Remote response: " .. table.concat(parts, " | "), Color3.fromRGB(170, 220, 255))
	end)
end)

--// STARTUP

local backpack = player:WaitForChild("Backpack")
connectRoot(backpack)

if player.Character then
	connectRoot(player.Character)
end

player.CharacterAdded:Connect(function(character)
	connectRoot(character)
	task.defer(function()
		buildStockMultiplierMap()
		scanRoot(character)
		refreshUI()
	end)
end)

task.defer(function()
	buildStockMultiplierMap()

	for _, root in ipairs(getTrackedRoots()) do
		connectRoot(root)
		scanRoot(root)
	end

	updateTargetFormattedLabel()
	refreshUI()

	addLog("Loaded mailer with rolling " .. tostring(mailLimitCount) .. "-mail / " .. tostring(mailLimitWindowHours) .. "h tracker.", Color3.fromRGB(170, 255, 170))
end)

-- TEB Hub lifecycle bridge
_G.TEBHubModules = _G.TEBHubModules or {}
_G.TEBHubModules.Mailer = {
	Stop = function()
		running = false
		mailing = false
		if gui and gui.Parent then
			gui:Destroy()
		end
	end,
	IsRunning = function()
		-- Runtime state is independent from UI visibility or GUI parenting.
		return running == true
	end
}

]=],
	Optimizer = [=[
local TEB_OPTIMIZER_ACTIVE = true
--// Combined Optimization Script + Lightweight Plant/Fruit Counter UI
--// Put this in a LocalScript, for example StarterPlayerScripts

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

--------------------------------------------------
-- OPTIMIZATION SETTINGS
--------------------------------------------------

local PLANTS_FOLDER_NAME = "Plants"
local FRUITS_FOLDER_NAME = "Fruits"
local FRUIT_SPAWN_LOCATIONS_NAME = "FruitSpawnLocations"

local BASE_PART_NAME = "Base"
local LEAVES_MODEL_NAME = "Leaves"

local HIDE_BASE_AND_TOUCH_PARTS = true
local KEEP_LEAVES_PARTS = true
local HIDE_FRUIT_SPAWN_LOCATIONS = true

-- Fruit parts with these names are protected.
local FRUIT_KEEP_NAMES = {
	["1"] = true,
	["Base"] = true,
	["HarvestPart"] = true,
}

-- true = removes every MeshPart inside Fruits, even if named Base/HarvestPart/1.
-- false = keeps MeshParts if their name is listed in FRUIT_KEEP_NAMES.
local REMOVE_ALL_FRUIT_MESHPARTS = true

local processed = {}

--------------------------------------------------
-- OPTIMIZATION HELPERS
--------------------------------------------------

local function safeDestroy(instance)
	if instance and instance.Parent then
		pcall(function()
			instance:Destroy()
		end)
	end
end

local function hasAncestorNamed(instance, name)
	local current = instance.Parent

	while current do
		if current.Name == name then
			return true
		end

		current = current.Parent
	end

	return false
end

local function isInsidePlants(instance)
	return instance.Name == PLANTS_FOLDER_NAME
		or hasAncestorNamed(instance, PLANTS_FOLDER_NAME)
end

local function isInsideFruits(instance)
	return instance.Name == FRUITS_FOLDER_NAME
		or hasAncestorNamed(instance, FRUITS_FOLDER_NAME)
end

local function isInsideFruitSpawnLocations(instance)
	return instance.Name == FRUIT_SPAWN_LOCATIONS_NAME
		or hasAncestorNamed(instance, FRUIT_SPAWN_LOCATIONS_NAME)
end

local function isInsideLeaves(instance)
	local current = instance

	while current do
		if current.Name == LEAVES_MODEL_NAME and current:IsA("Model") then
			return true
		end

		current = current.Parent
	end

	return false
end

local function hasTouchTrigger(part)
	if not part:IsA("BasePart") then
		return false
	end

	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("TouchTransmitter")
			or child.ClassName == "TouchTransmitter"
			or child.Name == "TouchInterest" then

			return true
		end
	end

	return false
end

local function isNumberNameExceptOne(instance)
	local number = tonumber(instance.Name)
	return number ~= nil and number ~= 1
end

local function isVisualJunk(instance)
	return instance:IsA("Decal")
		or instance:IsA("Texture")
		or instance:IsA("SurfaceAppearance")
		or instance:IsA("ParticleEmitter")
		or instance:IsA("Trail")
		or instance:IsA("Beam")
		or instance:IsA("Smoke")
		or instance:IsA("Fire")
		or instance:IsA("Sparkles")
		or instance:IsA("Highlight")
		or instance:IsA("Explosion")
end

local function isLight(instance)
	return instance:IsA("PointLight")
		or instance:IsA("SpotLight")
		or instance:IsA("SurfaceLight")
end

--------------------------------------------------
-- OPTIMIZATION FUNCTIONS
--------------------------------------------------

local function clearMeshTexture(instance)
	if instance:IsA("MeshPart") then
		instance.TextureID = ""
	end
end

local function optimizeBasePart(part)
	if not part or not part.Parent then
		return
	end

	part.Material = Enum.Material.SmoothPlastic
	part.Reflectance = 0
	part.CastShadow = false

	clearMeshTexture(part)
end

local function hideImportantPart(part)
	if not part or not part.Parent then
		return
	end

	optimizeBasePart(part)

	part.Transparency = 1
	part.LocalTransparencyModifier = 1
	part.CanCollide = false

	-- Keep these enabled because automation/touch scripts may rely on them.
	part.CanTouch = true
	part.CanQuery = true
end

local function disableLight(light)
	if light and light.Parent then
		light.Enabled = false
	end
end

--------------------------------------------------
-- FRUIT OPTIMIZATION
--------------------------------------------------

local function processFruitObject(instance)
	if not instance or not instance.Parent then
		return
	end

	-- Delete decals, textures, SurfaceAppearance, and effects inside Fruits.
	if isVisualJunk(instance) then
		safeDestroy(instance)
		return
	end

	-- Delete SpecialMesh inside Fruits.
	if instance:IsA("SpecialMesh") then
		safeDestroy(instance)
		return
	end

	if isLight(instance) then
		disableLight(instance)
		return
	end

	-- Keep non-parts inside Fruits for automation.
	if not instance:IsA("BasePart") then
		return
	end

	optimizeBasePart(instance)

	-- Remove MeshParts inside Fruits.
	if instance:IsA("MeshPart") then
		if REMOVE_ALL_FRUIT_MESHPARTS then
			safeDestroy(instance)
			return
		end

		if not FRUIT_KEEP_NAMES[instance.Name] then
			safeDestroy(instance)
			return
		end
	end

	-- Keep 1, Base, and HarvestPart.
	if FRUIT_KEEP_NAMES[instance.Name] then
		return
	end

	-- Remove numbered fruit parts like 2, 3, 4, 5, etc.
	if isNumberNameExceptOne(instance) then
		safeDestroy(instance)
		return
	end
end

--------------------------------------------------
-- PLANT OPTIMIZATION
--------------------------------------------------

local function processPlantObject(instance)
	if not instance or not instance.Parent then
		return
	end

	-- Fruits use their own cleanup rules.
	if isInsideFruits(instance) then
		processFruitObject(instance)
		return
	end

	-- Delete all visual junk outside Fruits too.
	if isVisualJunk(instance) then
		safeDestroy(instance)
		return
	end

	-- Delete SpecialMesh everywhere in plants.
	if instance:IsA("SpecialMesh") then
		safeDestroy(instance)
		return
	end

	if isLight(instance) then
		disableLight(instance)
		return
	end

	if not instance:IsA("BasePart") then
		return
	end

	optimizeBasePart(instance)

	-- Hide FruitSpawnLocations instead of deleting.
	if isInsideFruitSpawnLocations(instance) then
		if HIDE_FRUIT_SPAWN_LOCATIONS then
			hideImportantPart(instance)
		end

		return
	end

	-- Keep Leaves visible but optimized.
	if KEEP_LEAVES_PARTS and isInsideLeaves(instance) then
		return
	end

	-- Hide Base parts and touch-trigger parts.
	if instance.Name == BASE_PART_NAME or hasTouchTrigger(instance) then
		if HIDE_BASE_AND_TOUCH_PARTS then
			hideImportantPart(instance)
		else
			optimizeBasePart(instance)
		end

		return
	end

	-- Delete unnecessary plant parts.
	safeDestroy(instance)
end

--------------------------------------------------
-- GLOBAL OPTIMIZATION OUTSIDE PLANTS
--------------------------------------------------

local function processGlobalObject(instance)
	if not instance or not instance.Parent then
		return
	end

	if isVisualJunk(instance) then
		safeDestroy(instance)
		return
	end

	if instance:IsA("SpecialMesh") then
		safeDestroy(instance)
		return
	end

	if isLight(instance) then
		disableLight(instance)
		return
	end

	if instance:IsA("BasePart") then
		optimizeBasePart(instance)
	end
end

--------------------------------------------------
-- MAIN OPTIMIZER
--------------------------------------------------

local function process(instance)
	if not TEB_OPTIMIZER_ACTIVE then
		return
	end

	if not instance or not instance.Parent then
		return
	end

	if processed[instance] then
		return
	end

	processed[instance] = true

	if isInsidePlants(instance) then
		processPlantObject(instance)
	else
		processGlobalObject(instance)
	end
end

local function processTree(root)
	process(root)

	if root and root.Parent then
		for _, descendant in ipairs(root:GetDescendants()) do
			process(descendant)
		end
	end
end

-- Optimize existing objects first.
processTree(workspace)

-- Optimize future objects.
workspace.DescendantAdded:Connect(function(obj)
	task.defer(function()
		processTree(obj)
	end)
end)

--------------------------------------------------
-- COUNTER UI
--------------------------------------------------

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oldGui = playerGui:FindFirstChild("PlantFruitCounterUI")
if oldGui then
	oldGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "PlantFruitCounterUI"
gui.ResetOnSpawn = false
gui.Parent = playerGui


local main = Instance.new("Frame")
main.Name = "MainFrame"
main.Size = UDim2.fromOffset(230, 115)
main.Position = UDim2.fromOffset(25, 180)
main.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
main.BorderSizePixel = 0
main.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = main

local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 32)
topBar.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
topBar.BorderSizePixel = 0
topBar.Parent = main

local topCorner = Instance.new("UICorner")
topCorner.CornerRadius = UDim.new(0, 8)
topCorner.Parent = topBar

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -70, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "Plant Counter"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 15
title.Font = Enum.Font.SourceSansBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = topBar

local minimizeButton = Instance.new("TextButton")
minimizeButton.Size = UDim2.fromOffset(28, 24)
minimizeButton.Position = UDim2.new(1, -62, 0, 4)
minimizeButton.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
minimizeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
minimizeButton.TextSize = 14
minimizeButton.Font = Enum.Font.SourceSansBold
minimizeButton.Text = "_"
minimizeButton.BorderSizePixel = 0
minimizeButton.Parent = topBar

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(28, 24)
closeButton.Position = UDim2.new(1, -31, 0, 4)
closeButton.BackgroundColor3 = Color3.fromRGB(70, 45, 45)
closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
closeButton.TextSize = 14
closeButton.Font = Enum.Font.SourceSansBold
closeButton.Text = "X"
closeButton.BorderSizePixel = 0
closeButton.Parent = topBar

local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -16, 1, -42)
content.Position = UDim2.fromOffset(8, 38)
content.BackgroundTransparency = 1
content.Parent = main

local plantsLabel = Instance.new("TextLabel")
plantsLabel.Size = UDim2.new(1, 0, 0, 28)
plantsLabel.Position = UDim2.fromOffset(0, 0)
plantsLabel.BackgroundTransparency = 1
plantsLabel.TextColor3 = Color3.fromRGB(180, 255, 180)
plantsLabel.TextSize = 18
plantsLabel.Font = Enum.Font.Code
plantsLabel.TextXAlignment = Enum.TextXAlignment.Left
plantsLabel.Parent = content

local fruitsLabel = Instance.new("TextLabel")
fruitsLabel.Size = UDim2.new(1, 0, 0, 28)
fruitsLabel.Position = UDim2.fromOffset(0, 32)
fruitsLabel.BackgroundTransparency = 1
fruitsLabel.TextColor3 = Color3.fromRGB(255, 220, 160)
fruitsLabel.TextSize = 18
fruitsLabel.Font = Enum.Font.Code
fruitsLabel.TextXAlignment = Enum.TextXAlignment.Left
fruitsLabel.Parent = content

--------------------------------------------------
-- LIGHTWEIGHT COUNTER LOGIC
--------------------------------------------------

local watchedFolders = {}
local folderConnections = {}
local updateQueued = false

local function countNow()
	local plantCount = 0
	local fruitCount = 0

	for folder in pairs(watchedFolders) do
		if folder and folder.Parent then
			if folder.Name == PLANTS_FOLDER_NAME then
				plantCount += #folder:GetChildren()
			elseif folder.Name == FRUITS_FOLDER_NAME then
				fruitCount += #folder:GetChildren()
			end
		end
	end

	plantsLabel.Text = "Plants: " .. tostring(plantCount)
	fruitsLabel.Text = "Fruits: " .. tostring(fruitCount)
end

local function queueCounterUpdate()
	if updateQueued then
		return
	end

	updateQueued = true

	task.delay(0.25, function()
		updateQueued = false
		countNow()
	end)
end

local function watchFolder(folder)
	if watchedFolders[folder] then
		return
	end

	if folder.Name ~= PLANTS_FOLDER_NAME and folder.Name ~= FRUITS_FOLDER_NAME then
		return
	end

	watchedFolders[folder] = true
	folderConnections[folder] = {}

	table.insert(folderConnections[folder], folder.ChildAdded:Connect(queueCounterUpdate))
	table.insert(folderConnections[folder], folder.ChildRemoved:Connect(queueCounterUpdate))

	queueCounterUpdate()
end

local function unwatchFolder(folder)
	if not watchedFolders[folder] then
		return
	end

	watchedFolders[folder] = nil

	if folderConnections[folder] then
		for _, connection in ipairs(folderConnections[folder]) do
			connection:Disconnect()
		end

		folderConnections[folder] = nil
	end

	queueCounterUpdate()
end

local function findAndWatchFolders(root)
	if root.Name == PLANTS_FOLDER_NAME or root.Name == FRUITS_FOLDER_NAME then
		watchFolder(root)
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == PLANTS_FOLDER_NAME or descendant.Name == FRUITS_FOLDER_NAME then
			watchFolder(descendant)
		end
	end
end

findAndWatchFolders(workspace)

workspace.DescendantAdded:Connect(function(obj)
	if obj.Name == PLANTS_FOLDER_NAME or obj.Name == FRUITS_FOLDER_NAME then
		watchFolder(obj)
	end
end)

workspace.DescendantRemoving:Connect(function(obj)
	if watchedFolders[obj] then
		unwatchFolder(obj)
	end
end)

countNow()

--------------------------------------------------
-- UI DRAGGING
--------------------------------------------------

local dragging = false
local dragStart
local startPosition

topBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then

		dragging = true
		dragStart = input.Position
		startPosition = main.Position

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not dragging then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then

		local delta = input.Position - dragStart

		main.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end
end)

--------------------------------------------------
-- UI BUTTONS
--------------------------------------------------

local minimized = false
local normalSize = main.Size

minimizeButton.MouseButton1Click:Connect(function()
	minimized = not minimized

	if minimized then
		normalSize = main.Size
		content.Visible = false
		main.Size = UDim2.fromOffset(230, 32)
		minimizeButton.Text = "+"
	else
		content.Visible = true
		main.Size = normalSize
		minimizeButton.Text = "_"
	end
end)

closeButton.MouseButton1Click:Connect(function()
	gui:Destroy()
end)

-- TEB Hub lifecycle bridge
_G.TEBHubModules = _G.TEBHubModules or {}
_G.TEBHubModules.Optimizer = {
	Stop = function()
		TEB_OPTIMIZER_ACTIVE = false
		if gui and gui.Parent then
			gui:Destroy()
		end
	end,
	IsRunning = function()
		return TEB_OPTIMIZER_ACTIVE == true
	end
}

]=],
}

-- Startup must never wait for Cloudflare.
-- These hardcoded defaults are applied immediately on every launch.
local loadedHubConfig = {}
local loadedHubSource = "local-startup"

local moduleEnabled = {
	Bloom = false,
	Mailer = false,
	Optimizer = true,
	AutoRejoin = true,
}

local moduleBusy = {}
local rejoinDelay = 150
local rejoining = false
local hubRunning = true
local hubMinimized = false
local hubSavedX = 8
local hubSavedY = 80

local function buildHubCloudSettings()
	return {
		schemaVersion = 1,
		hubVersion = TEB_HUB_VERSION,
		Bloom = moduleEnabled.Bloom,
		Mailer = moduleEnabled.Mailer,
		Optimizer = moduleEnabled.Optimizer,
		AutoRejoin = moduleEnabled.AutoRejoin,
		RejoinDelay = rejoinDelay,
		Minimized = hubMinimized,
		UiX = hubSavedX,
		UiY = hubSavedY,
	}
end

local function queueHubCloudSave()
	tebQueueSaveScope("hub", buildHubCloudSettings)
end

local function executeModule(name)
	if moduleBusy[name] then
		return false, "Module is busy."
	end

	if type(loadstring) ~= "function" then
		return false, "loadstring is not available."
	end

	moduleBusy[name] = true

	local source = MODULE_SOURCES[name]
	local compiled, compileError = loadstring(source, "TEB_" .. name)

	if not compiled then
		moduleBusy[name] = nil
		return false, "Compile error: " .. tostring(compileError)
	end

	task.spawn(function()
		local ok, runtimeError = pcall(compiled)
		moduleBusy[name] = nil

		if not ok then
			warn("[TEB Hub][" .. name .. "]", runtimeError)
			moduleEnabled[name] = false
		end
	end)

	return true
end

local function stopModule(name)
	local module = _G.TEBHubModules and _G.TEBHubModules[name]

	if module and type(module.Stop) == "function" then
		local ok, err = pcall(module.Stop)
		if not ok then
			warn("[TEB Hub] Failed stopping " .. name .. ":", err)
		end
	end

	moduleEnabled[name] = false
end

-- ============================================================
-- INSTANT CORE STARTUP
-- These start before Cloudflare and before any TEB Hub UI is created.
-- ============================================================

local earlyStatusMessage = "Starting core modules..."
local earlyStatusError = false
local earlySetStatus = function(message, isError)
	earlyStatusMessage = tostring(message)
	earlyStatusError = isError == true
	if isError then
		warn("[TEB Hub]", message)
	else
		print("[TEB Hub]", message)
	end
end

-- Start Optimizer immediately. Do not wait for the hub UI or cloud config.
do
	local started, startError = executeModule("Optimizer")
	if started then
		moduleEnabled.Optimizer = true
		earlySetStatus("Optimizer started immediately.")
	else
		moduleEnabled.Optimizer = false
		earlySetStatus("Optimizer failed to start: " .. tostring(startError), true)
	end
end

-- Register Auto Rejoin immediately. It is active before the UI appears.
local autoRejoinConnection
autoRejoinConnection = GuiService.ErrorMessageChanged:Connect(function(errorMessage)
	if not hubRunning or not moduleEnabled.AutoRejoin or rejoining then
		return
	end

	if not errorMessage or errorMessage == "" then
		return
	end

	rejoining = true
	local capturedDelay = rejoinDelay

	task.spawn(function()
		for remaining = capturedDelay, 1, -1 do
			if not hubRunning or not moduleEnabled.AutoRejoin or not rejoining then
				return
			end

			earlySetStatus("Connection error. Rejoining in " .. tostring(remaining) .. "s.")
			task.wait(1)
		end

		if not hubRunning or not moduleEnabled.AutoRejoin or not rejoining then
			return
		end

		earlySetStatus("Rejoining now...")
		local ok, err = pcall(function()
			TeleportService:Teleport(game.PlaceId, player)
		end)

		if not ok then
			rejoining = false
			earlySetStatus("Rejoin failed: " .. tostring(err), true)
		end
	end)
end)

-- ============================================================
-- UNIFIED TEB HUB UI
-- One responsive window, sidebar navigation, central module pages.
-- ============================================================

local gui = Instance.new("ScreenGui")
gui.Name = "TEBHubUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- The one permanent TEB Hub side toggle.
-- It is outside the main frame, so hiding the hub cannot hide this button.
local sideToggle = Instance.new("TextButton")
sideToggle.Name = "TEBHubToggle"
sideToggle.Size = UDim2.fromOffset(104, 38)
sideToggle.Position = UDim2.new(0, 8, 0.5, -19)
sideToggle.BackgroundColor3 = Color3.fromRGB(62, 52, 135)
sideToggle.BorderSizePixel = 0
sideToggle.Text = "TEB Hub"
sideToggle.Font = Enum.Font.GothamBold
sideToggle.TextSize = 12
sideToggle.TextColor3 = Color3.new(1, 1, 1)
sideToggle.AutoButtonColor = true
sideToggle.Visible = true
sideToggle.Active = true
sideToggle.Selectable = true
sideToggle.ZIndex = 1000
sideToggle.Parent = gui

local sideToggleCorner = Instance.new("UICorner")
sideToggleCorner.CornerRadius = UDim.new(0, 10)
sideToggleCorner.Parent = sideToggle

local sideToggleStroke = Instance.new("UIStroke")
sideToggleStroke.Color = Color3.fromRGB(145, 125, 255)
sideToggleStroke.Thickness = 1.25
sideToggleStroke.Transparency = 0.15
sideToggleStroke.Parent = sideToggle

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(920, 620)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Position = UDim2.fromScale(0.5, 0.5)
main.BackgroundColor3 = Color3.fromRGB(17, 18, 24)
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 14)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(106, 88, 220)
mainStroke.Thickness = 1.5
mainStroke.Transparency = 0.25
mainStroke.Parent = main

local hubScale = Instance.new("UIScale")
hubScale.Name = "ResponsiveScale"
hubScale.Scale = 1
hubScale.Parent = main

local function updateHubScale()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local safeWidth = math.max(320, viewport.X - 16)
	local safeHeight = math.max(300, viewport.Y - 16)
	hubScale.Scale = math.clamp(math.min(safeWidth / 920, safeHeight / 620, 1), 0.42, 1)
end

updateHubScale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateHubScale)
end

local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 48)
topBar.BackgroundColor3 = Color3.fromRGB(34, 29, 62)
topBar.BorderSizePixel = 0
topBar.Parent = main

local topGradient = Instance.new("UIGradient")
topGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(91, 65, 190)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(43, 67, 150)),
})
topGradient.Parent = topBar

local hubTitle = Instance.new("TextLabel")
hubTitle.Size = UDim2.new(1, -130, 1, 0)
hubTitle.Position = UDim2.fromOffset(18, 0)
hubTitle.BackgroundTransparency = 1
hubTitle.Text = "TEB HUB"
hubTitle.Font = Enum.Font.GothamBold
hubTitle.TextSize = 18
hubTitle.TextColor3 = Color3.new(1, 1, 1)
hubTitle.TextXAlignment = Enum.TextXAlignment.Left
hubTitle.Parent = topBar

local versionLabel = Instance.new("TextLabel")
versionLabel.Size = UDim2.fromOffset(90, 20)
versionLabel.Position = UDim2.new(1, -176, 0, 14)
versionLabel.BackgroundColor3 = Color3.fromRGB(45, 47, 66)
versionLabel.BorderSizePixel = 0
versionLabel.Text = "v" .. TEB_HUB_VERSION
versionLabel.Font = Enum.Font.Code
versionLabel.TextSize = 10
versionLabel.TextColor3 = Color3.fromRGB(205, 215, 255)
versionLabel.Parent = topBar

local versionCorner = Instance.new("UICorner")
versionCorner.CornerRadius = UDim.new(0, 6)
versionCorner.Parent = versionLabel

local hubSubtitle = Instance.new("TextLabel")
hubSubtitle.Size = UDim2.fromOffset(280, 20)
hubSubtitle.Position = UDim2.fromOffset(112, 14)
hubSubtitle.BackgroundTransparency = 1
hubSubtitle.Text = "Unified automation control center"
hubSubtitle.Font = Enum.Font.Gotham
hubSubtitle.TextSize = 11
hubSubtitle.TextColor3 = Color3.fromRGB(210, 215, 240)
hubSubtitle.TextXAlignment = Enum.TextXAlignment.Left
hubSubtitle.Parent = topBar

local minimizeButton = Instance.new("TextButton")
minimizeButton.Size = UDim2.fromOffset(34, 28)
minimizeButton.Position = UDim2.new(1, -78, 0, 10)
minimizeButton.BackgroundColor3 = Color3.fromRGB(58, 59, 78)
minimizeButton.BorderSizePixel = 0
minimizeButton.Text = "−"
minimizeButton.Font = Enum.Font.GothamBold
minimizeButton.TextSize = 18
minimizeButton.TextColor3 = Color3.new(1, 1, 1)
minimizeButton.Parent = topBar

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(34, 28)
closeButton.Position = UDim2.new(1, -40, 0, 10)
closeButton.BackgroundColor3 = Color3.fromRGB(145, 48, 58)
closeButton.BorderSizePixel = 0
closeButton.Text = "X"
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 12
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.Parent = topBar

for _, button in ipairs({minimizeButton, closeButton}) do
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = button
end

local sidebar = Instance.new("Frame")
sidebar.Name = "Sidebar"
sidebar.Size = UDim2.new(0, 190, 1, -48)
sidebar.Position = UDim2.fromOffset(0, 48)
sidebar.BackgroundColor3 = Color3.fromRGB(22, 23, 31)
sidebar.BorderSizePixel = 0
sidebar.Parent = main

local sidebarLine = Instance.new("Frame")
sidebarLine.Size = UDim2.new(0, 1, 1, 0)
sidebarLine.Position = UDim2.new(1, -1, 0, 0)
sidebarLine.BackgroundColor3 = Color3.fromRGB(55, 56, 72)
sidebarLine.BorderSizePixel = 0
sidebarLine.Parent = sidebar

local profile = Instance.new("Frame")
profile.Size = UDim2.new(1, -20, 0, 66)
profile.Position = UDim2.fromOffset(10, 12)
profile.BackgroundColor3 = Color3.fromRGB(29, 30, 40)
profile.BorderSizePixel = 0
profile.Parent = sidebar
local profileCorner = Instance.new("UICorner")
profileCorner.CornerRadius = UDim.new(0, 9)
profileCorner.Parent = profile

local profileTitle = Instance.new("TextLabel")
profileTitle.Size = UDim2.new(1, -16, 0, 24)
profileTitle.Position = UDim2.fromOffset(8, 8)
profileTitle.BackgroundTransparency = 1
profileTitle.Text = player.DisplayName
profileTitle.Font = Enum.Font.GothamBold
profileTitle.TextSize = 12
profileTitle.TextColor3 = Color3.new(1, 1, 1)
profileTitle.TextXAlignment = Enum.TextXAlignment.Left
profileTitle.Parent = profile

local profileId = Instance.new("TextLabel")
profileId.Size = UDim2.new(1, -16, 0, 20)
profileId.Position = UDim2.fromOffset(8, 34)
profileId.BackgroundTransparency = 1
profileId.Text = "UserId: " .. tostring(player.UserId)
profileId.Font = Enum.Font.Code
profileId.TextSize = 10
profileId.TextColor3 = Color3.fromRGB(165, 175, 205)
profileId.TextXAlignment = Enum.TextXAlignment.Left
profileId.Parent = profile

local pageArea = Instance.new("Frame")
pageArea.Name = "PageArea"
pageArea.Size = UDim2.new(1, -190, 1, -48)
pageArea.Position = UDim2.fromOffset(190, 48)
pageArea.BackgroundColor3 = Color3.fromRGB(19, 20, 27)
pageArea.BorderSizePixel = 0
pageArea.Parent = main

local pageHeader = Instance.new("Frame")
pageHeader.Size = UDim2.new(1, 0, 0, 58)
pageHeader.BackgroundColor3 = Color3.fromRGB(24, 25, 34)
pageHeader.BorderSizePixel = 0
pageHeader.Parent = pageArea

local pageTitle = Instance.new("TextLabel")
pageTitle.Size = UDim2.new(1, -30, 0, 28)
pageTitle.Position = UDim2.fromOffset(18, 8)
pageTitle.BackgroundTransparency = 1
pageTitle.Text = "Dashboard"
pageTitle.Font = Enum.Font.GothamBold
pageTitle.TextSize = 17
pageTitle.TextColor3 = Color3.new(1, 1, 1)
pageTitle.TextXAlignment = Enum.TextXAlignment.Left
pageTitle.Parent = pageHeader

local pageDescription = Instance.new("TextLabel")
pageDescription.Size = UDim2.new(1, -30, 0, 18)
pageDescription.Position = UDim2.fromOffset(18, 34)
pageDescription.BackgroundTransparency = 1
pageDescription.Text = "Manage all TEB Hub modules from one place."
pageDescription.Font = Enum.Font.Gotham
pageDescription.TextSize = 10
pageDescription.TextColor3 = Color3.fromRGB(165, 175, 205)
pageDescription.TextXAlignment = Enum.TextXAlignment.Left
pageDescription.Parent = pageHeader

local pageContainer = Instance.new("Frame")
pageContainer.Name = "Pages"
pageContainer.Size = UDim2.new(1, -24, 1, -82)
pageContainer.Position = UDim2.fromOffset(12, 70)
pageContainer.BackgroundTransparency = 1
pageContainer.ClipsDescendants = true
pageContainer.Parent = pageArea

local pages = {}
local navButtons = {}
local pageMeta = {
	Dashboard = {"Dashboard", "Manage all TEB Hub modules from one place."},
	Bloom = {"Bloom Automation", "Configure watering, KG filters, ratios, sprinklers, and cans."},
	Mailer = {"Fruit Multi-Mailer", "Send by value or fruit quantity while tracking total values."},
	Optimizer = {"Optimization + Counter", "Reduce visual load and monitor plant and fruit counts."},
	Rejoin = {"Auto Rejoin", "Automatically reconnect after a connection error."},
	Settings = {"Cloud & Defaults", "Manage UserId cloud settings and global defaults."},
}

local function createPage(name)
	local page = Instance.new("Frame")
	page.Name = name .. "Page"
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = pageContainer
	pages[name] = page
	return page
end

for _, name in ipairs({"Dashboard", "Bloom", "Mailer", "Optimizer", "Rejoin", "Settings"}) do
	createPage(name)
end

local function makeNavButton(name, label, order)
	local button = Instance.new("TextButton")
	button.Name = name .. "Nav"
	button.Size = UDim2.new(1, -20, 0, 40)
	button.Position = UDim2.fromOffset(10, 90 + ((order - 1) * 46))
	button.BackgroundColor3 = Color3.fromRGB(29, 30, 40)
	button.BorderSizePixel = 0
	button.Text = "  " .. label
	button.Font = Enum.Font.GothamBold
	button.TextSize = 11
	button.TextColor3 = Color3.fromRGB(205, 210, 228)
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Parent = sidebar
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button
	navButtons[name] = button
	return button
end

makeNavButton("Dashboard", "Dashboard", 1)
makeNavButton("Bloom", "Bloom Automation", 2)
makeNavButton("Mailer", "Fruit Mailer", 3)
makeNavButton("Optimizer", "Optimizer", 4)
makeNavButton("Rejoin", "Auto Rejoin", 5)
makeNavButton("Settings", "Cloud & Defaults", 6)

local currentPage = "Dashboard"

local function showPage(name)
	if not pages[name] then
		return
	end
	currentPage = name
	for pageName, page in pairs(pages) do
		page.Visible = pageName == name
	end
	for buttonName, button in pairs(navButtons) do
		local active = buttonName == name
		button.BackgroundColor3 = active and Color3.fromRGB(75, 59, 150) or Color3.fromRGB(29, 30, 40)
		button.TextColor3 = active and Color3.new(1, 1, 1) or Color3.fromRGB(205, 210, 228)
	end
	local meta = pageMeta[name]
	pageTitle.Text = meta[1]
	pageDescription.Text = meta[2]
end

for name, button in pairs(navButtons) do
	button.MouseButton1Click:Connect(function()
		showPage(name)
	end)
end

local function addCorner(object, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = object
	return corner
end

local function makePanel(parent, position, size)
	local panel = Instance.new("Frame")
	panel.Position = position
	panel.Size = size
	panel.BackgroundColor3 = Color3.fromRGB(26, 27, 36)
	panel.BorderSizePixel = 0
	panel.Parent = parent
	addCorner(panel, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(54, 56, 72)
	stroke.Transparency = 0.35
	stroke.Parent = panel
	return panel
end

local function makeActionButton(parent, text, position, size)
	local button = Instance.new("TextButton")
	button.Position = position
	button.Size = size
	button.BackgroundColor3 = Color3.fromRGB(58, 59, 76)
	button.BorderSizePixel = 0
	button.Text = text
	button.Font = Enum.Font.GothamBold
	button.TextSize = 11
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Parent = parent
	addCorner(button, 8)
	return button
end

local statusBar = Instance.new("TextLabel")
statusBar.Size = UDim2.new(1, -20, 0, 34)
statusBar.Position = UDim2.new(0, 10, 1, -44)
statusBar.BackgroundColor3 = Color3.fromRGB(28, 30, 41)
statusBar.BorderSizePixel = 0
statusBar.Text = "TEB Hub ready."
statusBar.Font = Enum.Font.Code
statusBar.TextSize = 10
statusBar.TextColor3 = Color3.fromRGB(170, 215, 255)
statusBar.TextWrapped = true
statusBar.Parent = sidebar
addCorner(statusBar, 8)

local function setStatus(text, isError)
	statusBar.Text = tostring(text)
	statusBar.TextColor3 = isError and Color3.fromRGB(255, 125, 125) or Color3.fromRGB(170, 215, 255)
end

-- From this point onward, early core-module messages also update the visible UI.
earlySetStatus = setStatus
setStatus(earlyStatusMessage, earlyStatusError)

-- Dashboard cards
local dashboardPage = pages.Dashboard
local dashboardGrid = Instance.new("UIGridLayout")
dashboardGrid.CellSize = UDim2.new(0.5, -8, 0, 150)
dashboardGrid.CellPadding = UDim2.fromOffset(12, 12)
dashboardGrid.SortOrder = Enum.SortOrder.LayoutOrder
dashboardGrid.Parent = dashboardPage

local dashboardCards = {}

local function makeModuleCard(name, titleText, descriptionText)
	local card = Instance.new("Frame")
	card.Name = name .. "Card"
	card.BackgroundColor3 = Color3.fromRGB(27, 28, 38)
	card.BorderSizePixel = 0
	card.Parent = dashboardPage
	addCorner(card, 10)

	local heading = Instance.new("TextLabel")
	heading.Size = UDim2.new(1, -20, 0, 28)
	heading.Position = UDim2.fromOffset(10, 10)
	heading.BackgroundTransparency = 1
	heading.Text = titleText
	heading.Font = Enum.Font.GothamBold
	heading.TextSize = 13
	heading.TextColor3 = Color3.new(1, 1, 1)
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.Parent = card

	local description = Instance.new("TextLabel")
	description.Size = UDim2.new(1, -20, 0, 48)
	description.Position = UDim2.fromOffset(10, 40)
	description.BackgroundTransparency = 1
	description.Text = descriptionText
	description.Font = Enum.Font.Gotham
	description.TextSize = 10
	description.TextColor3 = Color3.fromRGB(175, 182, 205)
	description.TextWrapped = true
	description.TextXAlignment = Enum.TextXAlignment.Left
	description.TextYAlignment = Enum.TextYAlignment.Top
	description.Parent = card

	local toggle = makeActionButton(card, "OFF", UDim2.new(0, 10, 1, -48), UDim2.new(0.52, -15, 0, 34))
	local open = makeActionButton(card, "Open", UDim2.new(0.52, 5, 1, -48), UDim2.new(0.48, -15, 0, 34))

	dashboardCards[name] = {Card = card, Toggle = toggle, Open = open}
	return card
end

makeModuleCard("Bloom", "Bloom Automation", "Automated watering with KG and ratio controls.")
makeModuleCard("Mailer", "Fruit Multi-Mailer", "Value-based and fruit-count-based mailing.")
makeModuleCard("Optimizer", "Optimization + Counter", "Visual cleanup and live plant/fruit counts.")
makeModuleCard("AutoRejoin", "Auto Rejoin", "Reconnect automatically after connection errors.")

-- Module page shells
local moduleHosts = {}
local pageEnableButtons = {}

local function createModuleShell(pageName, moduleName, warningText)
	local page = pages[pageName]
	local controlBar = makePanel(page, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 52))
	local enableButton = makeActionButton(controlBar, "Enable", UDim2.fromOffset(10, 9), UDim2.fromOffset(130, 34))
	pageEnableButtons[moduleName] = enableButton

	local warning = Instance.new("TextLabel")
	warning.Size = UDim2.new(1, -160, 1, 0)
	warning.Position = UDim2.fromOffset(152, 0)
	warning.BackgroundTransparency = 1
	warning.Text = warningText or ""
	warning.Font = Enum.Font.Gotham
	warning.TextSize = 10
	warning.TextColor3 = Color3.fromRGB(205, 184, 120)
	warning.TextWrapped = true
	warning.TextXAlignment = Enum.TextXAlignment.Left
	warning.Parent = controlBar

	local host = Instance.new("Frame")
	host.Name = moduleName .. "Host"
	host.Size = UDim2.new(1, 0, 1, -64)
	host.Position = UDim2.fromOffset(0, 64)
	host.BackgroundColor3 = Color3.fromRGB(22, 23, 31)
	host.BorderSizePixel = 0
	host.ClipsDescendants = true
	host.Parent = page
	addCorner(host, 10)

	local empty = Instance.new("TextLabel")
	empty.Name = "EmptyMessage"
	empty.Size = UDim2.fromScale(1, 1)
	empty.BackgroundTransparency = 1
	empty.Text = "Enable " .. pageMeta[pageName][1] .. " to load its controls here."
	empty.Font = Enum.Font.Gotham
	empty.TextSize = 12
	empty.TextColor3 = Color3.fromRGB(145, 153, 180)
	empty.Parent = host

	moduleHosts[moduleName] = host
end

createModuleShell("Bloom", "Bloom", "All Bloom controls and statistics appear in this page.")
createModuleShell("Mailer", "Mailer", "Mailer history, targets, and progress remain inside this page.")
createModuleShell("Optimizer", "Optimizer", "Disabling stops future processing; deleted visuals cannot be restored.")

-- Rejoin page
local rejoinPage = pages.Rejoin
local rejoinPanel = makePanel(rejoinPage, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 180))

local rejoinToggle = makeActionButton(rejoinPanel, "Auto Rejoin", UDim2.fromOffset(16, 18), UDim2.fromOffset(190, 38))

local delayTitle = Instance.new("TextLabel")
delayTitle.Size = UDim2.fromOffset(180, 26)
delayTitle.Position = UDim2.fromOffset(16, 72)
delayTitle.BackgroundTransparency = 1
delayTitle.Text = "Rejoin delay in seconds"
delayTitle.Font = Enum.Font.GothamBold
delayTitle.TextSize = 11
delayTitle.TextColor3 = Color3.fromRGB(225, 228, 240)
delayTitle.TextXAlignment = Enum.TextXAlignment.Left
delayTitle.Parent = rejoinPanel

local delayBox = Instance.new("TextBox")
delayBox.Size = UDim2.fromOffset(130, 34)
delayBox.Position = UDim2.fromOffset(210, 68)
delayBox.BackgroundColor3 = Color3.fromRGB(38, 40, 52)
delayBox.BorderSizePixel = 0
delayBox.Text = tostring(rejoinDelay)
delayBox.ClearTextOnFocus = false
delayBox.Font = Enum.Font.GothamBold
delayBox.TextSize = 12
delayBox.TextColor3 = Color3.new(1, 1, 1)
delayBox.Parent = rejoinPanel
addCorner(delayBox, 8)

local rejoinInfo = Instance.new("TextLabel")
rejoinInfo.Size = UDim2.new(1, -32, 0, 46)
rejoinInfo.Position = UDim2.fromOffset(16, 118)
rejoinInfo.BackgroundTransparency = 1
rejoinInfo.Text = "When Roblox reports a connection error, TEB Hub counts down and teleports you back into the current place."
rejoinInfo.Font = Enum.Font.Gotham
rejoinInfo.TextSize = 10
rejoinInfo.TextWrapped = true
rejoinInfo.TextColor3 = Color3.fromRGB(170, 180, 205)
rejoinInfo.TextXAlignment = Enum.TextXAlignment.Left
rejoinInfo.TextYAlignment = Enum.TextYAlignment.Top
rejoinInfo.Parent = rejoinPanel

-- Settings page
local settingsPage = pages.Settings
local cloudPanel = makePanel(settingsPage, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 210))

local cloudTitle = Instance.new("TextLabel")
cloudTitle.Size = UDim2.new(1, -24, 0, 30)
cloudTitle.Position = UDim2.fromOffset(12, 12)
cloudTitle.BackgroundTransparency = 1
cloudTitle.Text = "UserId Cloud Configuration"
cloudTitle.Font = Enum.Font.GothamBold
cloudTitle.TextSize = 14
cloudTitle.TextColor3 = Color3.new(1, 1, 1)
cloudTitle.TextXAlignment = Enum.TextXAlignment.Left
cloudTitle.Parent = cloudPanel

local cloudText = Instance.new("TextLabel")
cloudText.Size = UDim2.new(1, -24, 0, 72)
cloudText.Position = UDim2.fromOffset(12, 46)
cloudText.BackgroundTransparency = 1
cloudText.Text = "Player-specific settings are stored under UserId " .. tostring(player.UserId) .. ". Existing player settings always take priority over the global default."
cloudText.Font = Enum.Font.Gotham
cloudText.TextSize = 10
cloudText.TextWrapped = true
cloudText.TextColor3 = Color3.fromRGB(175, 182, 205)
cloudText.TextXAlignment = Enum.TextXAlignment.Left
cloudText.TextYAlignment = Enum.TextYAlignment.Top
cloudText.Parent = cloudPanel

local defaultButton = makeActionButton(cloudPanel, "Set Current Settings as Default", UDim2.fromOffset(12, 130), UDim2.fromOffset(270, 38))
defaultButton.BackgroundColor3 = Color3.fromRGB(112, 77, 34)

local cloudSourceLabel = Instance.new("TextLabel")
cloudSourceLabel.Size = UDim2.new(1, -306, 0, 38)
cloudSourceLabel.Position = UDim2.fromOffset(294, 130)
cloudSourceLabel.BackgroundTransparency = 1
cloudSourceLabel.Text = "Loaded source: " .. tostring(loadedHubSource)
cloudSourceLabel.Font = Enum.Font.Code
cloudSourceLabel.TextSize = 10
cloudSourceLabel.TextColor3 = Color3.fromRGB(155, 205, 255)
cloudSourceLabel.TextXAlignment = Enum.TextXAlignment.Left
cloudSourceLabel.Parent = cloudPanel

local moduleGuiNames = {
	Bloom = "BloomAutomationUI",
	Mailer = "CompactFruitMultiMailer",
	Optimizer = "PlantFruitCounterUI",
}

local function clearHost(moduleName)
	local host = moduleHosts[moduleName]
	if not host then
		return
	end
	for _, child in ipairs(host:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local empty = Instance.new("TextLabel")
	empty.Name = "EmptyMessage"
	empty.Size = UDim2.fromScale(1, 1)
	empty.BackgroundTransparency = 1
	empty.Text = "Enable this module to load its controls here."
	empty.Font = Enum.Font.Gotham
	empty.TextSize = 12
	empty.TextColor3 = Color3.fromRGB(145, 153, 180)
	empty.Parent = host
end

local function normalizeMountedFrame(moduleName, frame)
	local host = moduleHosts[moduleName]
	if not host or not frame then
		return
	end

	for _, child in ipairs(host:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	frame.Parent = host
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.fromOffset(0, 0)
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = true

	for _, obj in ipairs(frame:GetDescendants()) do
		if obj:IsA("UIScale") then
			obj.Scale = 1
		end
	end

	local namedTopBar = frame:FindFirstChild("TopBar")
	if namedTopBar and namedTopBar:IsA("GuiObject") then
		namedTopBar.Visible = false
	end

	if moduleName == "Bloom" then
		local bloomBody = frame:FindFirstChildWhichIsA("ScrollingFrame")
		if bloomBody then
			bloomBody.Position = UDim2.fromOffset(0, 0)
			bloomBody.Size = UDim2.fromScale(1, 1)
			bloomBody.ScrollBarThickness = 5
		end
		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("Frame") and child ~= bloomBody and child.AbsoluteSize.Y <= 45 then
				child.Visible = false
			end
		end
	elseif moduleName == "Mailer" then
		local content = frame:FindFirstChild("Content")
		if content and content:IsA("GuiObject") then
			content.Position = UDim2.fromOffset(6, 6)
			content.Size = UDim2.new(1, -12, 1, -12)
		end
	elseif moduleName == "Optimizer" then
		local content = frame:FindFirstChild("Content")
		if content and content:IsA("GuiObject") then
			content.Position = UDim2.fromOffset(20, 20)
			content.Size = UDim2.new(1, -40, 1, -40)
		end
	end
end

local function mountModuleUI(moduleName)
	local guiName = moduleGuiNames[moduleName]
	if not guiName then
		return
	end

	task.spawn(function()
		local moduleGui = playerGui:WaitForChild(guiName, 8)
		if not moduleGui then
			setStatus(moduleName .. " started, but its UI was not found.", true)
			return
		end

		local frame
		if moduleName == "Mailer" then
			frame = moduleGui:FindFirstChild("Main")
		elseif moduleName == "Optimizer" then
			frame = moduleGui:FindFirstChild("MainFrame")
		else
			frame = moduleGui:FindFirstChildWhichIsA("Frame")
		end

		if not frame then
			setStatus(moduleName .. " UI frame was not found.", true)
			return
		end

		normalizeMountedFrame(moduleName, frame)

		-- Keep the backing ScreenGui alive and enabled after moving its visible
		-- frame into TEB Hub. Module runtimes are controlled only by their own
		-- runtime flags, never by hub visibility or mounted UI visibility.
		moduleGui.Enabled = true

		setStatus(moduleName .. " controls mounted inside TEB Hub.")
	end)
end

local function refreshModuleVisuals()
	for name, data in pairs(dashboardCards) do
		local enabled = moduleEnabled[name] == true
		data.Toggle.Text = enabled and "Enabled" or "Disabled"
		data.Toggle.BackgroundColor3 = enabled and Color3.fromRGB(42, 126, 69) or Color3.fromRGB(58, 59, 76)
	end

	for name, button in pairs(pageEnableButtons) do
		local enabled = moduleEnabled[name] == true
		button.Text = enabled and "Disable Module" or "Enable Module"
		button.BackgroundColor3 = enabled and Color3.fromRGB(42, 126, 69) or Color3.fromRGB(58, 59, 76)
	end

	local rejoinOn = moduleEnabled.AutoRejoin == true
	rejoinToggle.Text = rejoinOn and "Auto Rejoin: ON" or "Auto Rejoin: OFF"
	rejoinToggle.BackgroundColor3 = rejoinOn and Color3.fromRGB(42, 126, 69) or Color3.fromRGB(58, 59, 76)
end

local function setModule(name, wanted)
	if wanted then
		local ok, err = executeModule(name)
		if not ok then
			moduleEnabled[name] = false
			setStatus(name .. " failed: " .. tostring(err), true)
		else
			moduleEnabled[name] = true
			setStatus(name .. " started.")
			mountModuleUI(name)
		end
	else
		stopModule(name)
		clearHost(name)
		setStatus(name .. " stopped.")
	end
	refreshModuleVisuals()
	queueHubCloudSave()
end

for name, data in pairs(dashboardCards) do
	if name ~= "AutoRejoin" then
		data.Toggle.MouseButton1Click:Connect(function()
			setModule(name, not moduleEnabled[name])
		end)
		data.Open.MouseButton1Click:Connect(function()
			showPage(name)
		end)
	else
		data.Toggle.MouseButton1Click:Connect(function()
			moduleEnabled.AutoRejoin = not moduleEnabled.AutoRejoin
			if not moduleEnabled.AutoRejoin then
				rejoining = false
			end
			refreshModuleVisuals()
			queueHubCloudSave()
			setStatus("Auto Rejoin " .. (moduleEnabled.AutoRejoin and "enabled." or "disabled."))
		end)
		data.Open.MouseButton1Click:Connect(function()
			showPage("Rejoin")
		end)
	end
end

for name, button in pairs(pageEnableButtons) do
	button.MouseButton1Click:Connect(function()
		setModule(name, not moduleEnabled[name])
	end)
end

rejoinToggle.MouseButton1Click:Connect(function()
	moduleEnabled.AutoRejoin = not moduleEnabled.AutoRejoin
	if not moduleEnabled.AutoRejoin then
		rejoining = false
	end
	refreshModuleVisuals()
	queueHubCloudSave()
	setStatus("Auto Rejoin " .. (moduleEnabled.AutoRejoin and "enabled." or "disabled."))
end)

delayBox.FocusLost:Connect(function()
	local value = tonumber(delayBox.Text)
	if value and value >= 0 and value <= 3600 then
		rejoinDelay = math.floor(value)
		delayBox.Text = tostring(rejoinDelay)
		queueHubCloudSave()
		setStatus("Auto Rejoin delay set to " .. tostring(rejoinDelay) .. " seconds.")
	else
		delayBox.Text = tostring(rejoinDelay)
		setStatus("Delay must be between 0 and 3600 seconds.", true)
	end
end)

defaultButton.MouseButton1Click:Connect(function()
	defaultButton.Active = false
	defaultButton.Text = "Saving defaults..."

	local sections = {
		hub = buildHubCloudSettings(),
	}

	for sectionName, bridge in pairs(_G.TEBHubCloudSections or {}) do
		if type(bridge) == "table" and type(bridge.Get) == "function" then
			local ok, data = pcall(bridge.Get)
			if ok and type(data) == "table" then
				sections[string.lower(sectionName)] = data
			end
		end
	end

	local failures = {}
	for scope, data in pairs(sections) do
		local ok, result = tebSetDefaultScope(scope, data)
		if not ok then
			table.insert(failures, scope .. ": " .. tostring(result))
		end
	end

	if #failures == 0 then
		setStatus("Default config saved. Existing UserId settings still take priority.")
	else
		setStatus("Some defaults failed: " .. table.concat(failures, " | "), true)
	end

	defaultButton.Text = "Set Current Settings as Default"
	defaultButton.Active = true
end)

-- Auto Rejoin was registered before UI creation so it is active immediately.

-- Drag the one unified window.
do
	local dragging = false
	local dragStart
	local startPosition

	topBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPosition = main.Position
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(
				startPosition.X.Scale,
				startPosition.X.Offset + delta.X,
				startPosition.Y.Scale,
				startPosition.Y.Offset + delta.Y
			)
		end
	end)
end

local function setHubVisible(visible)
	-- UI visibility only. All automation modules continue running.
	main.Visible = visible == true
	sideToggle.Visible = true
	sideToggle.Active = true
	sideToggle.ZIndex = 1000
end

minimizeButton.MouseButton1Click:Connect(function()
	setHubVisible(false)
end)

sideToggle.MouseButton1Click:Connect(function()
	setHubVisible(not main.Visible)
end)

closeButton.MouseButton1Click:Connect(function()
	-- Only the red X intentionally stops and destroys the entire hub.
	hubRunning = false
	rejoining = false

	if autoRejoinConnection then
		autoRejoinConnection:Disconnect()
		autoRejoinConnection = nil
	end

	for _, name in ipairs({"Bloom", "Mailer", "Optimizer"}) do
		stopModule(name)
	end

	gui:Destroy()
end)

refreshModuleVisuals()
showPage("Dashboard")
setHubVisible(true)
sideToggle.Visible = true

task.defer(function()
	-- Optimizer already started before UI creation. Only optional modules start here.
	for _, name in ipairs({"Bloom", "Mailer"}) do
		if moduleEnabled[name] then
			local shouldStart = true
			moduleEnabled[name] = false
			setModule(name, shouldStart)
		end
	end

	if moduleEnabled.Optimizer then
		mountModuleUI("Optimizer")
	end
end)

setStatus("TEB Hub v" .. TEB_HUB_VERSION .. " ready. Auto Rejoin and Optimizer started from hardcoded defaults.")

-- Load cloud settings in the background only after the hub is already usable.
-- Optimizer and Auto Rejoin intentionally remain ON regardless of cloud values.
task.spawn(function()
	local cloudConfig, cloudSource, cloudError = tebLoadScope("hub")

	if not hubRunning then
		return
	end

	if type(cloudConfig) ~= "table" then
		cloudSourceLabel.Text = "Loaded source: local defaults"
		if cloudError then
			setStatus("Cloud config unavailable; using hardcoded defaults.")
		end
		return
	end

	loadedHubConfig = cloudConfig
	loadedHubSource = cloudSource or "cloud"
	cloudSourceLabel.Text = "Loaded source: " .. tostring(loadedHubSource)

	-- These optional settings may be restored after startup without blocking it.
	local savedDelay = tonumber(cloudConfig.RejoinDelay)
	if savedDelay then
		rejoinDelay = math.clamp(math.floor(savedDelay), 0, 3600)
		delayBox.Text = tostring(rejoinDelay)
	end

	-- Restore Bloom and Mailer preferences asynchronously.
	for _, name in ipairs({"Bloom", "Mailer"}) do
		local wanted = cloudConfig[name] == true
		if wanted ~= moduleEnabled[name] then
			setModule(name, wanted)
		end
	end

	-- Hardcoded startup requirements: never let cloud turn these off.
	moduleEnabled.Optimizer = true
	moduleEnabled.AutoRejoin = true
	refreshModuleVisuals()
	setStatus("Cloud config loaded in background. Optimizer and Auto Rejoin remain ON.")
end)
