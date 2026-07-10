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

local DEFAULT_TARGET_VALUE = "1B"
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
content.CanvasSize = UDim2.fromOffset(0, 900)
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
recipientBox.Text = ""
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
targetBox.Text = DEFAULT_TARGET_VALUE
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
seqBox.Text = DEFAULT_PACKET_SEQUENCE_START_HEX
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

local avatarFrame = Instance.new("ScrollingFrame")
avatarFrame.Name = "Avatars"
avatarFrame.Size = UDim2.new(1, 0, 0, 54)
avatarFrame.Position = UDim2.fromOffset(0, 144)
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
previewLabel.Size = UDim2.new(1, 0, 0, 34)
previewLabel.Position = UDim2.fromOffset(0, 204)
previewLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
previewLabel.BorderSizePixel = 0
previewLabel.Text = "Preview: none"
previewLabel.Font = Enum.Font.Gotham
previewLabel.TextSize = 10
previewLabel.TextColor3 = Color3.fromRGB(170, 220, 255)
previewLabel.TextXAlignment = Enum.TextXAlignment.Left
previewLabel.TextYAlignment = Enum.TextYAlignment.Center
previewLabel.TextWrapped = true
previewLabel.Parent = content

local previewPadding = Instance.new("UIPadding")
previewPadding.PaddingLeft = UDim.new(0, 8)
previewPadding.PaddingRight = UDim.new(0, 8)
previewPadding.Parent = previewLabel

local previewCorner = Instance.new("UICorner")
previewCorner.CornerRadius = UDim.new(0, 8)
previewCorner.Parent = previewLabel

local progressTitle = Instance.new("TextLabel")
progressTitle.Name = "ProgressTitle"
progressTitle.Size = UDim2.new(1, 0, 0, 18)
progressTitle.Position = UDim2.fromOffset(0, 244)
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
progressFrame.Position = UDim2.fromOffset(0, 264)
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
historyTitle.Position = UDim2.fromOffset(0, 328)
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
historyFrame.Position = UDim2.fromOffset(0, 350)
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
logFrame.Position = UDim2.fromOffset(0, 696)
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
			content.CanvasPosition = Vector2.new(0, 560)
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
		amountBox.Text = targetBox.Text ~= "" and targetBox.Text or DEFAULT_TARGET_VALUE
		amountBox.PlaceholderText = "1B"
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


local function makePreview()
	local recipients = getRecipientsForPlanning()
	local targetValue = getDefaultTargetValue()

	if #recipients == 0 then
		previewLabel.Text = "Preview: enter at least one username."
		previewLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
		return nil
	end

	local available = getCachedFruitsArray(true, true)
	local tempUsed = {}
	local previewPlans = {}
	local totalSelected = 0

	for _, recipient in ipairs(recipients) do
		local username = recipient.Username
		local recipientTarget = getRecipientTargetValue(recipient, targetValue)

		if not recipientTarget or recipientTarget <= 0 then
			table.insert(previewPlans, {
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

		for _, fruit in ipairs(available) do
			if fruit.itemKey and not tempUsed[fruit.itemKey] then
				table.insert(pool, fruit)
			end
		end

		local selected = {}
		local selectedTotal = 0
		local reason = "no current fruits"
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
				selected = picked
				selectedTotal = pickedTotal
				reason = pickedReason
			else
				selected = copyArray(pool)
				selectedTotal = poolTotal
				reason = "selector fallback: sending current inventory"
			end
		else
			selected = {}
			selectedTotal = poolTotal
			reason = "not enough current inventory"
		end

		for _, fruit in ipairs(selected) do
			if fruit.itemKey then
				tempUsed[fruit.itemKey] = true
			end
		end

		local batches = splitIntoBatches(selected, MAX_FRUITS_PER_MAIL)

		table.insert(previewPlans, {
			Username = username,
			Fruits = selected,
			Total = selectedTotal,
			Batches = batches,
			Reason = reason,
			Target = recipientTarget,
			Skipped = false,
			LiveRefill = LIVE_REFILL_MAILING,
		})

		totalSelected += selectedTotal
	end

	local okUsers = 0
	local skipped = 0
	local mailCount = 0
	local fruitCount = 0
	local waitingUsers = 0

	for _, plan in ipairs(previewPlans) do
		if plan.Skipped then
			skipped += 1
		else
			okUsers += 1
			mailCount += #plan.Batches
			fruitCount += #plan.Fruits

			if #plan.Fruits == 0 or plan.Total < plan.Target then
				waitingUsers += 1
			end
		end
	end

	previewLabel.Text = string.format(
		"Preview current: %d user%s | %d fruit%s | %d mail%s | %s now | %d waiting refill",
		okUsers,
		okUsers == 1 and "" or "s",
		fruitCount,
		fruitCount == 1 and "" or "s",
		mailCount,
		mailCount == 1 and "" or "s",
		formatShortNumber(totalSelected),
		waitingUsers
	)
	previewLabel.TextColor3 = (skipped > 0 or waitingUsers > 0) and Color3.fromRGB(255, 220, 120) or Color3.fromRGB(170, 220, 255)

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

	local packetByte

	local okSeq, seqErr = pcall(function()
		packetByte = parseHexByte(seqBox.Text)
	end)

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
				local targetValue = plan.Target or 0

				if not targetValue or targetValue <= 0 then
					addLog("Skipped " .. tostring(username) .. ": invalid target.", Color3.fromRGB(255, 120, 120))
					continue
				end

				local userId = getUserIdFromUsername(username)
				local sentFruits = {}
				local sentTotal = 0
				local sentMails = 0
				local stoppedReason = "completed"

				addLog("Stable-scanner live mailing to " .. username .. " | target " .. formatShortNumber(targetValue) .. ".", Color3.fromRGB(170, 220, 255))
				updateProgressValueRow(username, 0, targetValue, 0, "starting", Color3.fromRGB(90, 180, 110))

				while mailing and sentTotal < targetValue do
					local remainingTarget = targetValue - sentTotal
					local selected, selectedTotal, selectReason = selectLiveRefillBatch(remainingTarget)

					if not selected or #selected == 0 then
						if not LIVE_REFILL_MAILING then
							stoppedReason = "no current fruits"
							break
						end

						updateProgressValueRow(username, sentTotal, targetValue, sentMails, "waiting refill", Color3.fromRGB(255, 190, 90))

						local newAvailable = waitForNewMailableFruits(WAIT_FOR_NEW_FRUITS_SECONDS)

						if not newAvailable or #newAvailable == 0 then
							stoppedReason = "stopped: no new fruits from mail"
							break
						end

						continue
					end

					local batches = splitIntoBatches(selected, MAX_FRUITS_PER_MAIL)

					for _, batch in ipairs(batches) do
						if not mailing or sentTotal >= targetValue then
							break
						end

						if needsCooldownBeforeNextMail then
							waitMailCooldown(MAIL_COOLDOWN_SECONDS, username .. " next mail")
						end

						local itemKeys = getItemKeysFromBatch(batch)

						if #itemKeys == 0 then
							stoppedReason = "selected batch had no item keys"
							break
						end

						local recipientByte = packetByte
						packetByte = incrementPacketByte(packetByte)

						local fruitPacketByte = packetByte
						packetByte = incrementPacketByte(packetByte)

						local batchValue = getSelectionTotal(batch)

						addLog(string.format(
							"%s mail %d | %d fruit(s) | %s | seq %02X/%02X",
							username,
							sentMails + 1,
							#itemKeys,
							formatShortNumber(batchValue),
							recipientByte,
							fruitPacketByte
						))

						updateProgressValueRow(username, sentTotal, targetValue, sentMails, "sending", Color3.fromRGB(90, 180, 110))

						Event:FireServer(buildRecipientPacket(username, recipientByte))
						task.wait(RECIPIENT_PACKET_DELAY)

						Event:FireServer(buildFruitMailPacket(itemKeys, fruitPacketByte, userId))
						task.wait(MAIL_BATCH_DELAY)

						needsCooldownBeforeNextMail = true
						sentMails += 1
						sentTotal += batchValue

						for _, fruit in ipairs(batch) do
							table.insert(sentFruits, fruit)
						end

						markFruitsAsSent(batch)
						refreshUI()

						local remainingAfter = math.max(0, targetValue - sentTotal)
						updateProgressValueRow(
							username,
							sentTotal,
							targetValue,
							sentMails,
							remainingAfter <= 0 and "target reached" or ("left " .. formatShortNumber(remainingAfter)),
							remainingAfter <= 0 and Color3.fromRGB(120, 220, 130) or Color3.fromRGB(255, 190, 90)
						)

						if sentTotal >= targetValue then
							break
						end
					end
				end

				local remaining = math.max(0, targetValue - sentTotal)

				if remaining > 0 then
					addLog(
						username .. " stopped at " .. formatShortNumber(sentTotal) .. ". Left to mail: " .. formatShortNumber(remaining) .. ". Reason: " .. tostring(stoppedReason),
						Color3.fromRGB(255, 220, 120)
					)
					updateProgressValueRow(username, sentTotal, targetValue, sentMails, "stopped, left " .. formatShortNumber(remaining), Color3.fromRGB(255, 120, 120))
				else
					addLog(username .. " target reached: " .. formatShortNumber(sentTotal) .. " sent.", Color3.fromRGB(170, 255, 170))
					updateProgressValueRow(username, sentTotal, targetValue, sentMails, "completed", Color3.fromRGB(120, 220, 130))
				end

				if #sentFruits > 0 then
					addHistory(username, sentFruits, sentTotal, targetValue, sentMails, stoppedReason)
				else
					addLog(username .. " sent 0 fruits. Nothing added to history.", Color3.fromRGB(255, 220, 120))
				end

				refreshUI()
			end
		end)

		if ok then
			addLog("Stable-scanner live mailing finished. Check progress/history for left amounts.", Color3.fromRGB(170, 255, 170))
		else
			addLog("Send error: " .. tostring(err), Color3.fromRGB(255, 120, 120))
		end

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

	addLog("Loaded phone compact mailer. Hypno Bloom supported, base price " .. tostring(HYPNO_BLOOM_BASE_PRICE) .. ".", Color3.fromRGB(170, 255, 170))
end)