local ADDON, ns = ...
local L = ns.L

-- The workbench: the game's profession window stays open out of sight as the source of everything, this one
-- is drawn in its place. A rail of your professions, the recipes (a list or a wall of icons), the stage with
-- the chosen one (big, its skill colors, its reagents as cards), the next crafts worth doing and the queue.
-- Nothing is ever made without a click. Everything of the game is read or asked through its API; its window only
-- gets moved aside (Skin.AsideGameWindow), the "game window" button brings it back.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

local WIDTH, HEIGHT = 920, 600
local TOP = 66 -- (under the heading)
local RAIL, RAIL_ROW = 48, 62
local LIST_WIDTH = 270
local LIST_TOP = 80 -- (the search, the two switches, the skill to look at)
local ROW_HEIGHT, HEADER_HEIGHT = 44, 24
local CELL, CELLS_PER_ROW = 48, 5
local MAX_PROFESSIONS = 7
local STAGE_GAP = 14
local HERO_HEIGHT, PLATE = 160, 96
local CARD_HEIGHT, MAX_CARDS = 42, 8
local TREE_ROW = 21
local HIGHEST_SKILL = 300
local PAGE_BUTTON = 46
local MAX_AMOUNT = 200
-- The other addons that are this same window: the workbench steps aside (one click away, by the link).
local SAME_JOB = { "Skillet", "Skillet-Classic", "Mastercraft", "ForeverArtisan", "NaowhForeverProfessions" }
local SKILL_COLORS = { red = { 0.85, 0.25, 0.25 }, orange = { 1, 0.5, 0.25 }, yellow = { 1, 0.85, 0.1 },
	green = { 0.3, 0.8, 0.3 }, grey = { 0.55, 0.55, 0.55 } }
-- (the kit's gold, and its tints under the mouse and on the chosen row)
local GOLD = Skin and Skin.COLORS.gold
-- (read as they are: an older Wanderer has neither)
local HOVER, CHOSEN = Skin and rawget(Skin, "HOVER") or 0.05, Skin and rawget(Skin, "CHOSEN") or 0.1
local SKILL_WORDS = { red = "COLOR_RED", orange = "COLOR_ORANGE", yellow = "COLOR_YELLOW", green = "COLOR_GREEN", grey = "COLOR_GREY" }
local SKILL_TONES = { red = "red", orange = "gold", yellow = "gold", green = "green", grey = "grey" }
local CONFIDENCE = { read = { "CHIP_READ", "CHIP_READ_DESC", "green" }, data = { "CHIP_DATA", "CHIP_DATA_DESC", "blue" },
	unknown = { "CHIP_UNKNOWN", "CHIP_UNKNOWN_DESC", "grey" } }

local window, ui
local current -- the skill line shown
local picked = {} -- skill line -> the recipe chosen
local query, onlyCan, asGrid = "", false, false
local amount = 1
local offset = 0
local entries = {}
local mode = "wanderer" -- or "game": the game's own window, asked for
local atBench = false -- a profession of yours open in the game
local pending -- a profession asked to open, on its way (the game closes the former one first)
local leaving = false -- (the window hidden because the game's closed)
local placeGame, reopen
local modelFailed, modelItem
local showTree = false

local function Replaces()
	if not ns.Settings().replace then return false end
	local api = C_AddOns and C_AddOns.IsAddOnLoaded
	for _, name in ipairs(SAME_JOB) do
		if api and U.Clean(U.Safe(api, name)) then return false end
	end
	return true
end

local function Away() return atBench and mode == "wanderer" and ns.On() end

local function SayOff() W.Print(L.OFF) end

local function Paint(text, color)
	if color then text:SetTextColor(color[1], color[2], color[3]) end
end

local function LinkOf(item) return item and select(2, U.ItemInfo(item)) end

local function Quality(item) return item and U.ItemQuality(item) end

-- The chosen recipe (first time here: what helps now, or the first one you know).
local function Selected()
	local recipe = picked[current] and ns.FindRecipe(current, picked[current])
	if recipe then return recipe end
	local top = ns.Suggestions(current)[1]
	recipe = top and top.recipe or (ns.Recipes(current) or {})[1]
	picked[current] = recipe and recipe.id
	return recipe
end

-- The list -----------------------------------------------------------------------------------------------------

local function Passes(recipe)
	if onlyCan and not (recipe.learned and ns.CanMake(recipe) > 0) then return false end
	if query == "" then return true end
	local folded = U.Fold(query)
	if U.Matches(recipe.name, query, folded) then return true end
	for _, reagent in ipairs(recipe.reagents) do
		local name = U.ItemName(reagent.id)
		if name and U.Matches(name, query, folded) then return true end
	end
	return false
end

-- Headers and rows (or rows of cells) as they read, top to bottom. The recipes to learn close the list, folded.
local function Entries()
	local out = {}
	local passing = {}
	local toLearn = 0
	for _, recipe in ipairs(ns.Recipes(current) or {}) do
		if Passes(recipe) then
			passing[#passing + 1] = recipe
			if not recipe.learned then toLearn = toLearn + 1 end
		end
	end
	local closed = query == "" and ns.DB().folded.toLearn ~= false
	local group, row
	for _, recipe in ipairs(passing) do
		local key = recipe.learned and recipe.category or "toLearn"
		if key ~= group then
			group, row = key, nil
			if recipe.learned then
				out[#out + 1] = { header = recipe.category }
			else
				out[#out + 1] = { header = L.GROUP_TO_LEARN:format(toLearn), fold = true, closed = closed }
			end
		end
		if recipe.learned or not closed then
			if asGrid then
				if not row or #row.cells >= CELLS_PER_ROW then
					row = { cells = {} }
					out[#out + 1] = row
				end
				row.cells[#row.cells + 1] = recipe
			else
				out[#out + 1] = { recipe = recipe }
			end
		end
	end
	return out
end

local function ChooseRecipe(recipe, button)
	if button == "LeftButton" and IsShiftKeyDown() then
		local link = LinkOf(recipe.item)
		if link then U.ChatInsert(link) end
		return
	end
	picked[current] = recipe.id
	amount = 1
	Skin.Play("click")
	ns.Draw()
end

local function NewHeader(parent)
	local header = CreateFrame("Button", nil, parent)
	header:SetHeight(HEADER_HEIGHT)
	header.chevron = Skin.Glyph(header, "chevron", 10)
	header.chevron:SetPoint("LEFT", 2, 0)
	header.text = Skin.Text(header, "GameTooltipTextSmall", "kicker")
	header.text:SetPoint("LEFT", 4, -1)
	header.text:SetPoint("RIGHT", -4, -1)
	header.text:SetJustifyH("LEFT")
	header:SetScript("OnClick", function(self)
		if not self.fold then return end
		ns.DB().folded.toLearn = not self.closed
		Skin.Play("click")
		ns.Draw()
	end)
	return header
end

local function NewRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT - 2)
	row:RegisterForClicks("LeftButtonUp")
	row.ground = row:CreateTexture(nil, "BACKGROUND")
	row.ground:SetAllPoints()
	row.icon = Skin.Icon(row, 36)
	row.icon:SetPoint("LEFT", 3, 0)
	row.icon:EnableMouse(false)
	row.count = Skin.Text(row.icon, "NumberFontNormal", "text")
	row.count:SetPoint("BOTTOMRIGHT", -2, 2)
	row.name = Skin.Text(row, "GameTooltipText", "text")
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -3)
	row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.bar = Skin.ProgressLine(row, 3)
	row.bar:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 5)
	row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 8)
	row.note = Skin.Text(row, "GameTooltipTextSmall", "muted")
	row.note:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 2)
	row:SetScript("OnEnter", function(self) if not self.chosen then self.ground:SetColorTexture(1, 1, 1, HOVER) end end)
	row:SetScript("OnLeave", function(self) if not self.chosen then self.ground:SetColorTexture(0, 0, 0, 0) end end)
	row:SetScript("OnClick", function(self, button) ChooseRecipe(self.recipe, button) end)
	return row
end

local function FillRow(row, recipe, chosen, rank)
	row.recipe, row.chosen = recipe, chosen
	if chosen then row.ground:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], CHOSEN) else row.ground:SetColorTexture(0, 0, 0, 0) end
	local can = recipe.learned and ns.CanMake(recipe) or 0
	row.icon:Set(recipe.icon, Quality(recipe.item))
	row.icon.texture:SetDesaturated(can == 0)
	row.count:SetText(can > 0 and can or "")
	row.name:SetText(recipe.name)
	local color = recipe.learned and SKILL_COLORS[ns.Color(recipe, rank)]
	Paint(row.name, color or SKILL_COLORS.grey)
	row.bar:SetShown(recipe.learned)
	row.note:SetShown(not recipe.learned)
	if recipe.learned then row.bar:Set(ns.Share(recipe)) else row.note:SetText(L.NOTE_TO_LEARN) end
end

local function NewGrid(parent)
	local grid = CreateFrame("Frame", nil, parent)
	grid:SetHeight(CELL)
	grid.cells = {}
	for index = 1, CELLS_PER_ROW do
		local cell = CreateFrame("Button", nil, grid)
		cell:SetSize(CELL - 3, CELL - 3)
		cell:SetPoint("TOPLEFT", (index - 1) * CELL, 0)
		cell.icon = Skin.Icon(cell, CELL - 3)
		cell.icon:SetAllPoints()
		cell.icon:EnableMouse(false)
		cell.count = Skin.Text(cell.icon, "NumberFontNormal", "text")
		cell.count:SetPoint("BOTTOMRIGHT", -3, 3)
		cell:SetScript("OnClick", function(self, button) ChooseRecipe(self.recipe, button) end)
		Skin.Tooltip(cell, function() return cell.recipe and cell.recipe.name or "" end, "ANCHOR_RIGHT")
		grid.cells[index] = cell
	end
	return grid
end

local function FillGrid(grid, recipes, chosenId)
	for index, cell in ipairs(grid.cells) do
		local recipe = recipes[index]
		cell:SetShown(recipe ~= nil)
		if recipe then
			cell.recipe = recipe
			local can = recipe.learned and ns.CanMake(recipe) or 0
			cell.icon:Set(recipe.icon, Quality(recipe.item))
			cell.icon.texture:SetDesaturated(can == 0)
			cell.count:SetText(can > 0 and can or "")
			if recipe.id == chosenId then cell.icon.edges.Color(GOLD[1], GOLD[2], GOLD[3], 1) end
		end
	end
end

local function Pooled(pool, used, make)
	used = used + 1
	local frame = pool[used]
	if not frame then
		frame = make(ui.rows)
		pool[used] = frame
	end
	frame:ClearAllPoints()
	frame:Show()
	return frame, used
end

local function HideFrom(pool, used)
	for index = used + 1, #pool do pool[index]:Hide() end
end

local function DrawList(recipe)
	entries = Entries()
	local room = ui.rows:GetHeight()
	offset = math.max(0, math.min(offset, #entries - math.floor(room / ROW_HEIGHT)))
	local profession = ns.Profession(current, true)
	local rank = profession and profession.rank
	local chosen = recipe and recipe.id
	local headers, rows, grids, shown, y = 0, 0, 0, 0, 0
	local place = function(frame, height)
		frame:SetPoint("TOPLEFT", ui.rows, "TOPLEFT", 0, -y)
		frame:SetPoint("TOPRIGHT", ui.rows, "TOPRIGHT", 0, -y)
		y = y + height
	end
	for index = offset + 1, #entries do
		local entry = entries[index]
		local height = entry.header and HEADER_HEIGHT or entry.cells and CELL or ROW_HEIGHT
		if y + height > room then break end
		shown = shown + 1
		if entry.header then
			local frame
			frame, headers = Pooled(ui.headerPool, headers, NewHeader)
			place(frame, height)
			frame.text:SetText(U.Upper(entry.header))
			frame.fold, frame.closed = entry.fold, entry.closed
			frame.chevron:SetShown(entry.fold or false)
			Skin.SetGlyph(frame.chevron, entry.closed and "chevron" or "down")
			frame.text:SetPoint("LEFT", entry.fold and 16 or 4, -1)
		elseif entry.cells then
			local frame
			frame, grids = Pooled(ui.gridPool, grids, NewGrid)
			place(frame, height)
			FillGrid(frame, entry.cells, chosen)
		else
			local frame
			frame, rows = Pooled(ui.rowPool, rows, NewRow)
			place(frame, height)
			FillRow(frame, entry.recipe, entry.recipe.id == chosen, rank)
		end
	end
	HideFrom(ui.headerPool, headers)
	HideFrom(ui.rowPool, rows)
	HideFrom(ui.gridPool, grids)
	ui.scroll:Set(#entries, shown, offset)
	ui.nothing:SetShown(#entries == 0 and ns.Recipes(current) ~= nil)
end

-- The rail -----------------------------------------------------------------------------------------------------

local function PickProfession(line)
	ns.SetPage(nil)
	if line ~= current then
		current, offset, amount = line, 0, 1
		ns.SetPreviewRank(nil)
		ns.DB().last = line
		Skin.Play("click")
	end
	if line ~= ns.LiveLine() and ns.OpenProfession(line) then
		pending = line
		C_Timer.After(1, function() if pending == line then pending = nil end end)
	end
	ns.Draw()
end

local function RailButton(index)
	local button = ui.rail[index]
	if button then return button end
	button = CreateFrame("Button", nil, window)
	button:SetSize(RAIL, RAIL_ROW - 4)
	button:SetPoint("TOPLEFT", window, "TOPLEFT", ui.margin, -TOP - (index - 1) * RAIL_ROW)
	button.icon = Skin.RoundPortrait(button, 40)
	button.icon:SetPoint("TOP", 0, -2)
	button.rank = Skin.Text(button, "GameTooltipTextSmall", "soft")
	button.rank:SetPoint("TOP", button.icon, "BOTTOM", 0, -2)
	button.mark = Skin.Rule(button, true, 1)
	button.mark:SetPoint("TOPLEFT", -4, -4)
	button.mark:SetPoint("BOTTOMLEFT", -4, 16)
	button:SetScript("OnClick", function(self) PickProfession(self.profession.line) end)
	Skin.Tooltip(button, function()
		local known = button.profession
		return known and { known.name, L.SKILL:format(known.rank, known.most) } or ""
	end, "ANCHOR_RIGHT")
	ui.rail[index] = button
	return button
end

-- The other pages, from the bottom of the rail up.
local function PageButton(key)
	local button = ui.pageButtons[key]
	if button then return button end
	button = CreateFrame("Button", nil, window)
	button:SetSize(RAIL, PAGE_BUTTON - 4)
	button.icon = Skin.RoundPortrait(button, 36)
	button.icon:SetPoint("CENTER")
	button.icon:SetTexture(ns.PAGE_ICONS[key])
	button.mark = Skin.Rule(button, true, 1)
	button.mark:SetPoint("TOPLEFT", -4, -4)
	button.mark:SetPoint("BOTTOMLEFT", -4, 4)
	button:SetScript("OnClick", function()
		ns.SetPage(ns.CurrentPage() ~= key and key or nil)
		Skin.Play("click")
		ns.Draw()
	end)
	Skin.Tooltip(button, ns.PageTitle(key), "ANCHOR_RIGHT")
	ui.pageButtons[key] = button
	return button
end

local function DrawPageButtons()
	local list = ns.PagesFor(current)
	for _, button in pairs(ui.pageButtons) do button:Hide() end
	local shown = ns.CurrentPage()
	local stillThere = false
	for index, key in ipairs(list) do
		local button = PageButton(key)
		local here = key == shown
		if here then stillThere = true end
		button:ClearAllPoints()
		button:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", ui.margin, ui.margin + (#list - index) * PAGE_BUTTON)
		button.icon:SetDesaturated(not here)
		button:SetAlpha(here and 1 or 0.7)
		button.mark:SetShown(here)
		button:Show()
	end
	if shown and not stillThere then ns.SetPage(nil) end
end

local function DrawRail(list)
	DrawPageButtons()
	-- (as many professions as fit above the pages: the rows closer, the icons smaller, when there are many)
	local pages = #ns.PagesFor(current)
	local height = U.Clean(U.Safe(window.GetHeight, window)) or HEIGHT
	local room = height - TOP - ui.margin - pages * PAGE_BUTTON - 8
	local row = math.max(36, math.min(RAIL_ROW, math.floor(room / math.max(1, math.min(#list, MAX_PROFESSIONS)))))
	local icon = math.max(22, math.min(40, row - 22))
	for index = 1, MAX_PROFESSIONS do
		local known = list[index]
		if known or ui.rail[index] then
			local button = RailButton(index)
			button:SetShown(known ~= nil)
			button:SetSize(RAIL, row - 4)
			button:ClearAllPoints()
			button:SetPoint("TOPLEFT", window, "TOPLEFT", ui.margin, -TOP - (index - 1) * row)
			button.icon:SetSize(icon, icon)
			button.icon.ring:SetSize(icon + 3, icon + 3)
			if known then
				local here = known.line == current
				button.profession = known
				button.icon:SetTexture(known.icon)
				button.icon:SetDesaturated(not here)
				local onBench = here and not ns.CurrentPage()
				button:SetAlpha(onBench and 1 or 0.7)
				button.rank:SetText(known.rank)
				button.mark:SetShown(onBench)
			end
		end
	end
end

-- The stage ----------------------------------------------------------------------------------------------------

local function HasPlace(recipe) return recipe.places and recipe.places[1] end

local function BestPlace(recipe)
	local map = C_Map and C_Map.GetBestMapForUnit and U.Clean(U.Safe(C_Map.GetBestMapForUnit, "player"))
	for _, place in ipairs(recipe.places) do
		if place[1] == map then return place end
	end
	return recipe.places[1]
end

-- Where a recipe comes from, in one line. What the game said comes first, the database after.
local function SourceWords(recipe)
	if recipe.learned then return L.SOURCE_KNOWN end
	if recipe.sourceText then return (recipe.sourceText:gsub("|n", " · ")) end
	local name = recipe.teaches and U.ItemName(recipe.teaches)
	if recipe.teaches and not name then U.LoadItem(recipe.teaches) end
	if recipe.kind == "t" then
		return recipe.cost and L.SOURCE_TRAINER_COST:format(U.Coins(recipe.cost)) or L.SOURCE_TRAINER
	elseif recipe.kind == "v" then
		return L.SOURCE_VENDOR
	elseif recipe.kind == "q" then
		return L.SOURCE_QUEST
	elseif recipe.kind == "d" then
		return name and L.SOURCE_DROP_ITEM:format(name) or L.SOURCE_DROP
	end
	return L.SOURCE_UNKNOWN
end

-- In order of what matters; those that no longer fit on the line stay out.
local function PlaceChips(chips)
	local last
	local used = 0
	for _, chip in ipairs(chips) do
		if chip:IsShown() then
			local width = chip:GetWidth() or 0
			if used + width > ui.heroRight then
				chip:Hide()
			else
				chip:ClearAllPoints()
				if last then chip:SetPoint("LEFT", last, "RIGHT", 5, 0) else chip:SetPoint("TOPLEFT", ui.title, "BOTTOMLEFT", 0, -7) end
				used, last = used + width + 5, chip
			end
		end
	end
end

local function SpecNeeded(recipe)
	if not recipe.spec or U.Clean(U.Safe(IsPlayerSpell, recipe.spec)) then return nil end
	return C_Spell and C_Spell.GetSpellName and U.Clean(U.Safe(C_Spell.GetSpellName, recipe.spec)) or nil
end

local function DrawChips(recipe, color)
	if recipe.learned and color then
		local words = L[SKILL_WORDS[color]]
		ui.chipColor:Set(color == "red" and words:format(recipe.orange or 0) or words, SKILL_TONES[color])
	else
		ui.chipColor:Set(nil)
	end
	local spec = SpecNeeded(recipe)
	ui.chipSpec:Set(spec and L.CHIP_NEEDS_SPEC:format(spec) or nil, "red")
	local left = recipe.learned and ns.CooldownLeft(recipe)
	ui.chipWait:Set(left and L.CHIP_COOLDOWN:format(ns.WaitWords(left)) or nil, "blue")
	local favor = not recipe.learned and ns.FavorOf(recipe.id)
	ui.chipFavor:Set(favor and favor.cost and L.CHIP_FAVOR:format(favor.cost) or nil, "gold")
	local bind, armor
	if recipe.item then bind, armor = ns.ItemTraits(recipe.item) end
	local traits = ns.Joined(bind and L[bind], armor)
	ui.chipBind:Set(traits ~= "" and traits or nil, bind == "BIND_PICKUP" and "gold" or "grey")
	ui.chipMade:Set(recipe.made > 1 and L.MAKES:format(recipe.made) or nil)
	local trust = CONFIDENCE[recipe.confidence]
	ui.chipTrust:Set(L[trust[1]], trust[3])
	ui.chipTrust.tip = L[trust[2]]
	PlaceChips({ ui.chipColor, ui.chipSpec, ui.chipWait, ui.chipFavor, ui.chipBind, ui.chipMade, ui.chipTrust })
end

-- Who else can make it: your other characters, and the guild when asked.
local function PeopleWords(recipe)
	local names = {}
	for _, who in ipairs(ns.KnownBy(recipe.line, recipe.id)) do names[#names + 1] = who.name end
	local guild = {}
	for name in pairs(ns.GuildAnswers(recipe.id)) do guild[#guild + 1] = name end
	table.sort(guild)
	return ns.Joined(names[1] and (recipe.learned and L.ALSO_KNOWN or L.KNOWN_BY):format(table.concat(names, ", ")),
		guild[1] and L.GUILD_KNOWN:format(table.concat(guild, ", ")))
end

-- Orange, yellow, green, grey on one bar, your skill marked on it.
local function DrawTimeline(recipe, rank)
	local line = ui.timeline
	rank = ns.PreviewRank() or rank
	local from, to = recipe.orange or recipe.yellow, recipe.grey
	line:SetShown(from ~= nil and to ~= nil and to > from)
	if not line:IsShown() then return end
	local width = line:GetWidth()
	if not width or width <= 0 then width = 280 end
	local last = to + math.max(4, math.floor((to - from) * 0.12))
	local function At(value) return (math.min(math.max(value, from), last) - from) / (last - from) * width end
	local marks = { recipe.orange or from, recipe.yellow or from, recipe.green or to, to, last }
	for index, part in ipairs(line.parts) do
		local left, right = At(marks[index]), At(marks[index + 1])
		part:SetShown(right > left)
		part:SetPoint("LEFT", line, "LEFT", left, 0)
		part:SetWidth(math.max(right - left, 1))
		line.numbers[index]:SetShown(right > left)
		line.numbers[index]:SetPoint("TOPLEFT", line, "BOTTOMLEFT", left, -2)
		line.numbers[index]:SetText(marks[index])
	end
	line.pointer:SetShown(rank ~= nil)
	if rank then line.pointer:SetPoint("BOTTOM", line, "BOTTOMLEFT", At(rank), -2) end
end

local function DrawModel(recipe)
	local model = ui.model
	local link = LinkOf(recipe.item)
	local wearable = link and C_Item and C_Item.IsEquippableItem and U.Clean(U.Safe(C_Item.IsEquippableItem, recipe.item))
	if not model or modelFailed or not wearable then
		if model then model:Hide() end
		modelItem = nil
		return
	end
	if modelItem == recipe.item and model:IsShown() then return end
	model:Show()
	local ok = pcall(function()
		model:SetUnit("player")
		model:Undress()
		model:TryOn(link)
	end)
	modelItem = ok and recipe.item or nil
	if not ok then
		modelFailed = true
		model:Hide()
	end
	ns.DB().model = ok
end

local function NewCard(index)
	local card = CreateFrame("Button", nil, ui.stage)
	local half = (ui.stageWidth - 8) / 2
	card:SetSize(half, CARD_HEIGHT - 4)
	card:SetPoint("TOPLEFT", ui.stage, "TOPLEFT", ((index - 1) % 2) * (half + 8), -HERO_HEIGHT - 26 - math.floor((index - 1) / 2) * CARD_HEIGHT)
	card:RegisterForClicks("LeftButtonUp")
	card.ground = card:CreateTexture(nil, "BACKGROUND")
	card.ground:SetAllPoints()
	card.ground:SetColorTexture(1, 1, 1, 0.035)
	card.icon = Skin.Icon(card, 34)
	card.icon:SetPoint("LEFT", 3, 0)
	card.icon:EnableMouse(false)
	card.name = Skin.Text(card, "GameTooltipTextSmall", "text")
	card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 8, -2)
	card.name:SetPoint("TOPRIGHT", card, "TOPRIGHT", -62, -5)
	card.name:SetJustifyH("LEFT")
	card.name:SetWordWrap(false)
	card.have = Skin.Text(card, "GameTooltipText", "text")
	card.have:SetPoint("TOPRIGHT", -6, -3)
	card.where = Skin.Text(card, "GameTooltipTextSmall", "muted")
	card.where:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 8, 2)
	card.where:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -6, 5)
	card.where:SetJustifyH("LEFT")
	card.where:SetWordWrap(false)
	Skin.ItemTooltip(card, function(self) return self.item end)
	card:SetScript("OnClick", function(self)
		if IsShiftKeyDown() then
			local link = LinkOf(self.item)
			if link then U.ChatInsert(link) end
		elseif self.maker then
			ns.GoToRecipe(self.maker.line, self.maker.id)
		end
	end)
	ui.cards[index] = card
	return card
end

-- Where the rest is, when the bags do not hold enough.
local function WhereWords(id, missing, bank, maker)
	local parts = {}
	if missing > 0 then parts[1] = Skin.Colorize(L.MISSING:format(missing), "bad") end
	if maker then parts[#parts + 1] = Skin.Colorize(L.MAKES_ITSELF, "gold") end
	if bank > 0 then parts[#parts + 1] = L.AT_BANK:format(bank) end
	for _, who in ipairs(missing > 0 and ns.Elsewhere(id) or {}) do
		parts[#parts + 1] = who.name .. " " .. (who.bags + who.bank)
		if #parts >= 3 then break end
	end
	return table.concat(parts, "  ·  ")
end

-- How many crafts the cards count: those left of the run under way, else those asked.
local function Times(recipe)
	local run = ns.Run()
	if run and run.id == recipe.id then return math.max(run.total - run.done, 1), true end
	return math.max(amount, 1), false
end

local function DrawCards(recipe)
	local times, running = Times(recipe)
	local anyShort = false
	for index = 1, MAX_CARDS do
		local reagent = recipe.reagents[index]
		local card = ui.cards[index] or (reagent and NewCard(index))
		if card then
			card:SetShown(reagent ~= nil and not showTree)
			if reagent then
				local bags, bank = ns.Owned(reagent.id)
				local need = reagent.need * times
				-- (a run under way takes them as it goes: nothing is missing)
				local missing = running and 0 or math.max(need - bags, 0)
				if missing > 0 then anyShort = true end
				local name = U.ItemName(reagent.id)
				if not name then U.LoadItem(reagent.id) end
				local maker = ns.MakerOf(reagent.id)
				card.item, card.maker = reagent.id, maker
				card.icon:Set(U.ItemIcon(reagent.id), Quality(reagent.id))
				card.icon.texture:SetDesaturated(missing > 0)
				card.name:SetText(name or "")
				card.have:SetText(Skin.Colorize(bags .. " / " .. need, missing > 0 and "bad" or "good"))
				card.where:SetText(WhereWords(reagent.id, missing, bank, maker))
			end
		end
	end
	return anyShort
end

local function TreeRow(index)
	local row = ui.treeRows[index]
	if row then return row end
	row = CreateFrame("Button", nil, ui.stage)
	row:SetHeight(TREE_ROW - 1)
	row:SetPoint("TOPLEFT", ui.stage, "TOPLEFT", 0, -HERO_HEIGHT - 26 - (index - 1) * TREE_ROW)
	row:SetPoint("TOPRIGHT", ui.stage, "TOPRIGHT", 0, -HERO_HEIGHT - 26 - (index - 1) * TREE_ROW)
	row.icon = Skin.Icon(row, 18)
	row.name = Skin.Text(row, "GameTooltipTextSmall", "text")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.name:SetWidth(330)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.have = Skin.Text(row, "GameTooltipTextSmall", "text")
	row.have:SetPoint("RIGHT", -4, 0)
	Skin.ItemTooltip(row, function(self) return self.item end)
	row:SetScript("OnClick", function(self)
		if self.maker then ns.GoToRecipe(self.maker.line, self.maker.id) end
	end)
	ui.treeRows[index] = row
	return row
end

local function DrawTree(recipe)
	local times, running = Times(recipe)
	local rows = showTree and ns.Tree(recipe, times) or {}
	for index = 1, MAX_CARDS do
		local data = rows[index]
		local row = (data or ui.treeRows[index]) and TreeRow(index)
		if row then
			row:SetShown(data ~= nil)
			if data then
				local name = U.ItemName(data.id)
				if not name then U.LoadItem(data.id) end
				row.item, row.maker = data.id, data.maker
				row.icon:ClearAllPoints()
				row.icon:SetPoint("LEFT", (data.depth - 1) * 18, 0)
				row.icon:Set(U.ItemIcon(data.id), Quality(data.id))
				local short = data.have < data.need and not running
				row.icon.texture:SetDesaturated(short)
				row.name:SetText(data.maker and Skin.Colorize(name or "", "gold") or (name or ""))
				row.have:SetText(Skin.Colorize(data.have .. " / " .. data.need, short and "bad" or "good"))
			end
		end
	end
end

-- The run under way, in place of the buttons that would start another.
local function DrawRun(run)
	ui.runBand:SetShown(run ~= nil)
	if not run then return end
	ui.runIcon:Set(run.icon)
	ui.runText:SetText(L.RUN_PROGRESS:format(run.name, run.done, run.total))
	ui.runStop:SetShown(ns.CanStopRun() and run.total > 1 and run.done + 1 < run.total)
end

local function DrawActions(recipe, can)
	local run = ns.Run()
	DrawRun(run)
	local isKnown, isLive = recipe.learned and not run, recipe.line == ns.LiveLine()
	for _, widget in ipairs({ ui.minus, ui.amount, ui.plus, ui.maximum, ui.addQueue, ui.create }) do widget:SetShown(isKnown) end
	ui.actionNote:SetShown(not recipe.learned)
	if run then return end
	if not isKnown then
		ui.actionNote:SetText(L.NOTE_NOT_YET)
		return
	end
	-- (an enchant is laid on one item: one at a time)
	local single = not recipe.item
	if single then amount = 1 end
	ui.minus:SetEnabled(not single and amount > 1)
	ui.plus:SetEnabled(not single and amount < MAX_AMOUNT)
	ui.maximum:SetEnabled(not single and can > 0)
	if not ui.amount:HasFocus() then ui.amount:SetText(amount) end
	if isLive then
		-- (what will really be made: never more than the bags allow)
		local count = math.max(math.min(amount, can), 1)
		ui.create:SetLabel(count > 1 and L.CREATE_MANY:format(count) or L.CREATE)
		ui.create:SetEnabled(can > 0 and not ns.CooldownLeft(recipe))
	else
		ui.create:SetLabel(L.OPEN_PROFESSION)
		ui.create:SetEnabled(true)
	end
end

local function DrawSuggestions(recipe)
	local list = ns.Suggestions(current)
	ui.progressTitle:SetShown(list[1] ~= nil)
	for index, card in ipairs(ui.suggestions) do
		local found = list[index]
		card:SetShown(found ~= nil)
		if found then
			card.recipe = found.recipe
			card.icon:Set(found.recipe.icon, Quality(found.recipe.item))
			card.icon.texture:SetDesaturated(found.can == 0)
			card.name:SetText(found.recipe.name)
			Paint(card.name, SKILL_COLORS[found.color])
			local cost = found.cost < math.huge and U.Coins(found.cost)
			local state = found.can > 0 and L.PROGRESS_CAN:format(found.can) or L.PROGRESS_SHORT
			card.note:SetText(cost and state .. "  ·  " .. cost or state)
			card.ground:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], found.recipe.id == (recipe and recipe.id) and CHOSEN or 0.03)
		end
	end
end

local function DrawQueue()
	local queue = ns.Queue()
	local need = {}
	for index = 1, ns.MAX_QUEUE do
		local step = queue[index]
		local cell = ui.queue[index]
		cell:SetShown(step ~= nil)
		if step then
			local recipe = ns.FindRecipe(step.line, step.id)
			cell.step, cell.index = step, index
			cell.recipeName = recipe and recipe.name or ""
			cell.icon:Set(recipe and recipe.icon, recipe and Quality(recipe.item))
			cell.count:SetText(step.count)
			for _, reagent in ipairs(recipe and recipe.reagents or {}) do
				need[reagent.id] = (need[reagent.id] or 0) + reagent.need * step.count
			end
		end
	end
	local missing = 0
	for id, count in pairs(need) do
		if count > ns.Owned(id) then missing = missing + 1 end
	end
	ui.queueEmpty:SetShown(queue[1] == nil)
	ui.queueRun:SetShown(queue[1] ~= nil)
	ui.queueMissing:SetShown(missing > 0)
	ui.queueMissing:SetText(L.QUEUE_MISSING:format(missing))
end

local function DrawHero(recipe, rank)
	local color = ns.Color(recipe, rank)
	local quality = Quality(recipe.item)
	if recipe.item and not quality then U.LoadItem(recipe.item) end
	ui.plate:Set(recipe.icon, quality)
	ui.plate.texture:SetDesaturated(not recipe.learned)
	ui.kicker:SetText(U.Upper(recipe.learned and recipe.category or L.NOTE_TO_LEARN))
	ui.title:SetText(recipe.name)
	if quality then ui.title:SetTextColor(U.QualityColor(quality)) else ui.title:SetTextColor(Skin.COLORS.gold[1], Skin.COLORS.gold[2], Skin.COLORS.gold[3]) end
	DrawChips(recipe, color)
	DrawTimeline(recipe, rank)
	ui.source:SetText(SourceWords(recipe))
	ui.people:SetText(PeopleWords(recipe))
	ui.go:SetShown(not recipe.learned and HasPlace(recipe) ~= nil)
	DrawModel(recipe)
end

local function DrawHeading(profession)
	ui.heading:SetShown(profession ~= nil)
	if not profession then return end
	local list = ns.Recipes(current) or {}
	local known = 0
	for _, recipe in ipairs(list) do
		if recipe.learned then known = known + 1 end
	end
	ui.headName:SetText(profession.name)
	ui.headSkill:SetText(L.SKILL:format(profession.rank, profession.most))
	ui.headKnown:SetText(ns.Recipes(current) and L.KNOWN:format(known, #list) or "")
	ui.headBar:Set(profession.most > 0 and profession.rank / profession.most or 0)
	local rank = ns.NextRank(profession)
	if rank and rank.ready then
		ui.headNext:SetText(Skin.Colorize(L.NEXT_RANK_READY:format(rank.name), "gold"))
	else
		ui.headNext:SetText(rank and L.NEXT_RANK:format(rank.name, rank.skill, rank.level) or "")
	end
	ui.art:SetTexture(profession.icon)
	ui.gameButton:SetShown(atBench)
end

-- All of it, from what is known now.
function ns.Draw()
	if not (window and window:IsShown()) then return end
	ns.ForgetCounts()
	-- (the gathering professions too, after the others: their skill on the rail, what they make if they make any)
	local professions = ns.Professions(true)
	if not ns.Profession(current, true) then
		current = ns.Profession(ns.DB().last, true) and ns.DB().last or (professions[1] and professions[1].line)
	end
	DrawRail(professions)
	local profession = ns.Profession(current, true)
	local seen = ns.PreviewRank()
	ui.whatIf:SetText(seen and Skin.Colorize(L.WHAT_IF:format(seen), "gold") or L.WHAT_IF_OFF)
	ui.whatIfReset:SetShown(seen ~= nil and not ns.CurrentPage())
	if profession then ui.slider:SetValue(seen or profession.rank) end
	DrawHeading(profession)
	ns.DrawPage(window, ui.margin + RAIL + 10, TOP, ui.margin, ui.margin)
	if ns.CurrentPage() then
		for _, part in ipairs(ui.listParts) do part:Hide() end
		ui.stage:Hide()
		ui.prompt:Hide()
		return
	end
	local read = profession and ns.Recipes(current) ~= nil
	local recipe = read and Selected() or nil
	for _, part in ipairs(ui.listParts) do part:SetShown(read and true or false) end
	DrawList(recipe)
	-- Nothing to show yet: said once, with the way out.
	ui.prompt:SetShown(not recipe)
	ui.stage:SetShown(recipe ~= nil)
	if not recipe then
		ui.promptTitle:SetText(profession and (profession.gather and profession.name or L.NOT_READ_TITLE) or L.NONE_TITLE)
		ui.promptText:SetText(profession and (profession.gather and L.GATHER_TEXT:format(profession.rank or 0, profession.most or 0)
			or L.NOT_READ_TEXT) or L.NONE_TEXT)
		ui.promptButton:SetShown(profession ~= nil)
		return
	end
	ns.ReadSource(recipe)
	if ns.lastRun then
		-- (finished: back to one; interrupted: what remains, one click from going on)
		if ns.lastRun.id == recipe.id then
			amount = ns.lastRun.finished and 1 or math.max(ns.lastRun.left, 1)
			if ns.lastRun.finished then Skin.Play("confirm") end
		end
		ns.lastRun = nil
	end
	local can = recipe.learned and ns.CanMake(recipe) or 0
	DrawHero(recipe, profession.rank)
	local short = DrawCards(recipe)
	DrawTree(recipe)
	ui.treeToggle:SetLabel(showTree and L.CARDS or L.TREE)
	ui.guildAsk:SetShown(ns.Settings().guild and true or false)
	ui.toShopping:SetShown(short and recipe.learned and ns.Auction() ~= nil)
	DrawActions(recipe, can)
	DrawSuggestions(recipe)
	DrawQueue()
end

function ns.CurrentLine() return current end

-- From a page, a card or the tree: to a recipe on the bench.
function ns.GoToRecipe(line, id)
	picked[line], amount = id, 1
	offset = 0
	PickProfession(line)
end

-- Making ---------------------------------------------------------------------------------------------------------

local function Start(recipe, count)
	if recipe.line ~= ns.LiveLine() then
		PickProfession(recipe.line)
		return
	end
	local ok, why = ns.Craft(recipe, count)
	if not ok then W.Print(why) end
end

local function RunQueue()
	local step = ns.Queue()[1]
	local recipe = step and ns.FindRecipe(step.line, step.id)
	if not step then return end
	if not recipe then return ns.Unqueue(1) end
	if recipe.line == ns.LiveLine() and ns.CanMake(recipe) == 0 then
		picked[recipe.line] = recipe.id
		W.Print(L.QUEUE_BLOCKED:format(recipe.name))
		return ns.Draw()
	end
	Start(recipe, recipe.item and math.min(step.count, ns.CanMake(recipe)) or 1)
end

local function SetAmount(value)
	amount = math.max(1, math.min(MAX_AMOUNT, value))
	ns.Draw()
end

-- Building it --------------------------------------------------------------------------------------------------

local function BuildList()
	local left = ui.margin + RAIL + 10
	local search = Skin.CreateInput(window, nil, 40, { hint = L.SEARCH, onChange = function(_, typed)
		if not typed then return end
		query, offset = ui.search:GetText() or "", 0
		ns.Draw()
	end })
	search:SetPoint("TOPLEFT", window, "TOPLEFT", left, -TOP)
	search:SetWidth(LIST_WIDTH)
	ui.search = search
	local can = Skin.SmallButton(window, L.ONLY_CAN, function(self)
		onlyCan, offset = not onlyCan, 0
		self:SetLabel(Skin.Colorize(L.ONLY_CAN, onlyCan and "gold" or "text"))
		ns.Draw()
	end, L.ONLY_CAN_DESC)
	can:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -5)
	local grid = Skin.SmallButton(window, L.GRID, function(self)
		asGrid, offset = not asGrid, 0
		self:SetLabel(asGrid and L.LIST or L.GRID)
		ns.Draw()
	end, L.GRID_DESC)
	grid:SetPoint("LEFT", can, "RIGHT", 6, 0)
	-- "And at skill 250?"
	local whatIf = Skin.Text(window, "GameTooltipTextSmall", "soft")
	whatIf:SetPoint("TOPLEFT", can, "BOTTOMLEFT", 0, -7)
	whatIf:SetWidth(112)
	whatIf:SetJustifyH("LEFT")
	whatIf:SetText(L.WHAT_IF_OFF)
	ui.whatIf = whatIf
	local slider = CreateFrame("Slider", nil, window)
	slider:SetOrientation("HORIZONTAL")
	slider:EnableMouse(true)
	slider:SetSize(128, 14)
	slider:SetPoint("LEFT", whatIf, "RIGHT", 4, 0)
	slider:SetMinMaxValues(1, HIGHEST_SKILL)
	slider:SetValueStep(5)
	slider:SetObeyStepOnDrag(true)
	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetHeight(2)
	track:SetPoint("LEFT")
	track:SetPoint("RIGHT")
	track:SetColorTexture(Skin.COLORS.kicker[1], Skin.COLORS.kicker[2], Skin.COLORS.kicker[3], 0.35)
	local thumb = slider:CreateTexture(nil, "ARTWORK")
	thumb:SetSize(8, 14)
	thumb:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.9)
	slider:SetThumbTexture(thumb)
	slider:SetScript("OnValueChanged", function(_, value, byUser)
		if not byUser then return end
		ns.SetPreviewRank(math.floor(value + 0.5))
		ns.Changed()
	end)
	Skin.Tooltip(slider, L.WHAT_IF_DESC)
	ui.slider = slider
	local reset = Skin.GlyphButton(window, "undo", 12, L.WHAT_IF_RESET, function()
		ns.SetPreviewRank(nil)
		ns.Draw()
	end)
	reset:SetPoint("LEFT", slider, "RIGHT", 2, 0)
	ui.whatIfReset = reset
	local rows = CreateFrame("Frame", nil, window)
	rows:SetPoint("TOPLEFT", window, "TOPLEFT", left, -TOP - LIST_TOP)
	rows:SetSize(LIST_WIDTH - Skin.SCROLL_WIDTH, HEIGHT - TOP - LIST_TOP - ui.margin)
	rows:EnableMouseWheel(true)
	rows:SetScript("OnMouseWheel", function(_, delta)
		offset = offset - delta * 2
		ns.Draw()
	end)
	ui.rows = rows
	ui.scroll = Skin.ScrollBar(window, function(value)
		offset = math.floor(value + 0.5)
		ns.Draw()
	end)
	ui.scroll:SetPoint("TOPLEFT", rows, "TOPRIGHT", 2, 0)
	ui.scroll:SetPoint("BOTTOMLEFT", rows, "BOTTOMRIGHT", 2, 0)
	ui.nothing = Skin.Text(rows, "GameTooltipText", "muted")
	ui.nothing:SetPoint("TOP", 0, -30)
	ui.nothing:SetWidth(LIST_WIDTH - 40)
	ui.nothing:SetText(L.NOTHING_FOUND)
	ui.listParts = { search, can, grid, rows, ui.scroll, whatIf, slider }
end

local function BuildHero(stage)
	local hero = CreateFrame("Frame", nil, stage)
	hero:SetPoint("TOPLEFT")
	hero:SetSize(ui.stageWidth, HERO_HEIGHT)
	local ground = hero:CreateTexture(nil, "BACKGROUND")
	ground:SetAllPoints()
	ground:SetColorTexture(1, 1, 1, 0.03)
	Skin.Edges(hero, GOLD[1], GOLD[2], GOLD[3], 0.14)
	-- (the profession's emblem, large and faint, behind the piece)
	ui.art = hero:CreateTexture(nil, "BORDER")
	ui.art:SetPoint("TOPRIGHT", -4, -4)
	ui.art:SetSize(HERO_HEIGHT - 8, HERO_HEIGHT - 8)
	ui.art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	ui.art:SetDesaturated(true)
	ui.art:SetAlpha(0.13)
	local plate = Skin.Icon(hero, PLATE)
	plate:SetPoint("LEFT", 16, 0)
	plate:EnableMouse(true)
	plate.padTip = true -- (a controller stops on it for its tooltip)
	-- (what it makes under the mouse, else the recipe itself)
	Skin.ItemTooltip(plate, function()
		local recipe = Selected()
		if not recipe then return nil end
		return recipe.item or (recipe.id and "spell:" .. recipe.id) or nil
	end, "ANCHOR_RIGHT")
	ui.plate = plate
	local right = ui.stageWidth - 16 - PLATE - 14 - 128
	ui.kicker = Skin.Text(hero, "GameTooltipTextSmall", "kicker")
	ui.kicker:SetPoint("TOPLEFT", plate, "TOPRIGHT", 14, 4)
	ui.kicker:SetWidth(right)
	ui.kicker:SetJustifyH("LEFT")
	ui.kicker:SetWordWrap(false)
	ui.title = Skin.Text(hero, "GameTooltipHeaderText", "gold")
	ui.title:SetPoint("TOPLEFT", ui.kicker, "BOTTOMLEFT", 0, -3)
	ui.title:SetWidth(right)
	ui.title:SetJustifyH("LEFT")
	ui.title:SetWordWrap(false)
	ui.heroRight = right
	ui.chipTrust, ui.chipColor, ui.chipMade = Skin.Chip(hero), Skin.Chip(hero), Skin.Chip(hero)
	ui.chipSpec, ui.chipWait, ui.chipFavor, ui.chipBind = Skin.Chip(hero), Skin.Chip(hero), Skin.Chip(hero), Skin.Chip(hero)
	ui.chipTrust:EnableMouse(true)
	ui.chipTrust.padTip = true
	Skin.Tooltip(ui.chipTrust, function() return ui.chipTrust.tip or "" end)
	local timeline = CreateFrame("Frame", nil, hero)
	timeline:SetPoint("TOPLEFT", ui.title, "BOTTOMLEFT", 0, -34)
	timeline:SetSize(right, 5)
	timeline.parts, timeline.numbers = {}, {}
	for index, name in ipairs({ "orange", "yellow", "green", "grey" }) do
		local part = timeline:CreateTexture(nil, "ARTWORK")
		local color = SKILL_COLORS[name]
		part:SetColorTexture(color[1], color[2], color[3], 0.85)
		part:SetHeight(5)
		timeline.parts[index] = part
		timeline.numbers[index] = Skin.Text(timeline, "GameTooltipTextSmall", "muted")
	end
	timeline.pointer = Skin.Glyph(timeline, "down", 10)
	timeline.pointer:SetVertexColor(1, 1, 1)
	ui.timeline = timeline
	ui.source = Skin.Text(hero, "GameTooltipTextSmall", "soft")
	ui.source:SetPoint("BOTTOMLEFT", plate, "BOTTOMRIGHT", 14, -6)
	ui.source:SetWidth(right - 70)
	ui.source:SetJustifyH("LEFT")
	ui.source:SetWordWrap(false)
	ui.people = Skin.Text(hero, "GameTooltipTextSmall", "muted")
	ui.people:SetPoint("TOPLEFT", ui.source, "BOTTOMLEFT", 0, -2)
	ui.people:SetWidth(right)
	ui.people:SetJustifyH("LEFT")
	ui.people:SetWordWrap(false)
	ui.go = Skin.SmallButton(hero, L.GO, function()
		local recipe = Selected()
		if not (recipe and HasPlace(recipe)) then return end
		local place = BestPlace(recipe)
		U.Go(place[1], place[2], place[3], recipe.name, SourceWords(recipe))
	end, L.GO_DESC, 20)
	ui.go:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", -136, 14)
	-- (a piece that is worn: on you, beside its icon)
	local ok, model = pcall(CreateFrame, "DressUpModel", nil, hero)
	if ok and model then
		model:SetPoint("TOPRIGHT", -2, -2)
		model:SetSize(126, HERO_HEIGHT - 4)
		model:Hide()
		ui.model = model
	end
end

local function BuildActions(stage)
	local y = -HERO_HEIGHT - 26 - (MAX_CARDS / 2) * CARD_HEIGHT - 2
	ui.minus = Skin.GlyphButton(stage, "down", 14, L.LESS, function() SetAmount(amount - 1) end)
	ui.minus:SetPoint("TOPLEFT", stage, "TOPLEFT", 0, y - 2)
	ui.amount = Skin.CreateInput(stage, nil, 3, { onChange = function(self, typed)
		if not typed then return end
		amount = math.max(1, math.min(MAX_AMOUNT, tonumber(self:GetText()) or 1))
		ns.Changed()
	end, onEnter = function(self)
		self:ClearFocus()
		ns.Draw()
	end })
	ui.amount:SetNumeric(true)
	ui.amount:SetWidth(44)
	ui.amount:SetPoint("LEFT", ui.minus, "RIGHT", 2, 0)
	ui.plus = Skin.GlyphButton(stage, "up", 14, L.MORE, function() SetAmount(amount + 1) end)
	ui.plus:SetPoint("LEFT", ui.amount, "RIGHT", 2, 0)
	ui.maximum = Skin.SmallButton(stage, L.MAXIMUM, function()
		local recipe = Selected()
		if recipe then SetAmount(math.max(ns.CanMake(recipe), 1)) end
	end, L.MAXIMUM_DESC)
	ui.maximum:SetPoint("LEFT", ui.plus, "RIGHT", 8, 0)
	ui.create = Skin.Button(stage, L.CREATE, function()
		local recipe = Selected()
		if recipe then Start(recipe, math.max(math.min(amount, ns.CanMake(recipe)), 1)) end
	end, "main")
	ui.create:SetPoint("TOPRIGHT", stage, "TOPRIGHT", 0, y)
	function ui.create:SetLabel(text)
		self:SetText(text)
		if self.Fit then self:Fit() end
	end
	ui.addQueue = Skin.SmallButton(stage, L.ADD_QUEUE, function()
		local recipe = Selected()
		if recipe then ns.Enqueue(recipe, amount) end
	end, L.ADD_QUEUE_DESC)
	ui.addQueue:SetPoint("RIGHT", ui.create, "LEFT", -22, 0)
	-- The run under way: what is being made, how far, how long, a way to stop.
	local band = CreateFrame("Frame", nil, stage)
	band:SetPoint("TOPLEFT", stage, "TOPLEFT", 0, y)
	band:SetSize(ui.stageWidth, 36)
	band:Hide()
	ui.runIcon = Skin.Icon(band, 30)
	ui.runIcon:SetPoint("LEFT", 0, 0)
	ui.runText = Skin.Text(band, "GameTooltipText", "text")
	ui.runText:SetPoint("TOPLEFT", ui.runIcon, "TOPRIGHT", 10, -1)
	ui.runText:SetWidth(ui.stageWidth - 200)
	ui.runText:SetJustifyH("LEFT")
	ui.runText:SetWordWrap(false)
	ui.runLeft = Skin.Text(band, "GameTooltipTextSmall", "muted")
	ui.runLeft:SetPoint("TOPRIGHT", band, "TOPRIGHT", -90, -3)
	ui.runBar = Skin.ProgressLine(band, 6)
	ui.runBar:SetPoint("BOTTOMLEFT", ui.runIcon, "BOTTOMRIGHT", 10, 2)
	ui.runBar:SetWidth(ui.stageWidth - 130)
	ui.runStop = Skin.SmallButton(band, L.RUN_STOP, function() ns.StopRun() end, L.RUN_STOP_DESC)
	ui.runStop:SetPoint("RIGHT", 0, 0)
	band:SetScript("OnUpdate", function()
		local share, left = ns.RunProgress()
		ui.runBar:Set(share)
		ui.runLeft:SetText(left and L.RUN_LEFT:format(left) or "")
	end)
	ui.runBand = band
	ui.actionNote = Skin.Text(stage, "GameTooltipText", "soft")
	ui.actionNote:SetPoint("TOPLEFT", stage, "TOPLEFT", 0, y - 6)
	ui.actionNote:SetWidth(ui.stageWidth)
	ui.actionNote:SetJustifyH("LEFT")
	return y - 36
end

local function SuggestionCard(stage, index, y, width)
	local card = CreateFrame("Button", nil, stage)
	card:SetSize(width, 42)
	card:SetPoint("TOPLEFT", stage, "TOPLEFT", (index - 1) * (width + 8), y)
	card.ground = card:CreateTexture(nil, "BACKGROUND")
	card.ground:SetAllPoints()
	card.icon = Skin.Icon(card, 34)
	card.icon:SetPoint("LEFT", 4, 0)
	card.icon:EnableMouse(false)
	card.name = Skin.Text(card, "GameTooltipTextSmall", "text")
	card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 7, -3)
	card.name:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -7)
	card.name:SetJustifyH("LEFT")
	card.name:SetWordWrap(false)
	card.note = Skin.Text(card, "GameTooltipTextSmall", "muted")
	card.note:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 7, 3)
	card:SetScript("OnClick", function(self) ChooseRecipe(self.recipe, "LeftButton") end)
	return card
end

local function QueueCell(stage, index, y)
	local cell = CreateFrame("Button", nil, stage)
	cell:SetSize(38, 38)
	cell:SetPoint("TOPLEFT", stage, "TOPLEFT", (index - 1) * 42, y)
	cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- (a controller: its top button takes it off the queue, as the right click)
	cell.padRight, cell.padRightWord = true, L.PAD_UNQUEUE
	cell.icon = Skin.Icon(cell, 38)
	cell.icon:SetAllPoints()
	cell.icon:EnableMouse(false)
	cell.count = Skin.Text(cell.icon, "NumberFontNormal", "text")
	cell.count:SetPoint("BOTTOMRIGHT", -3, 3)
	cell:SetScript("OnClick", function(self, button)
		if button == "RightButton" then return ns.Unqueue(self.index) end
		current, picked[self.step.line] = self.step.line, self.step.id
		ns.Draw()
	end)
	Skin.Tooltip(cell, function() return { cell.recipeName or "", (U.UsingPad and U.UsingPad()) and L.QUEUE_CELL_DESC_PAD or L.QUEUE_CELL_DESC } end)
	return cell
end

local function BuildBottom(stage, top)
	local titleProgress = Skin.Caps(stage, L.PROGRESS, "kicker")
	titleProgress:SetPoint("TOPLEFT", stage, "TOPLEFT", 0, top)
	ui.progressTitle = titleProgress
	local width = (ui.stageWidth - 16) / 3
	ui.suggestions = {}
	for index = 1, 3 do ui.suggestions[index] = SuggestionCard(stage, index, top - 16, width) end
	local queueTop = top - 66
	local titleQueue = Skin.Caps(stage, L.QUEUE, "kicker")
	titleQueue:SetPoint("TOPLEFT", stage, "TOPLEFT", 0, queueTop)
	ui.queueMissing = Skin.Text(stage, "GameTooltipTextSmall", "bad")
	ui.queueMissing:SetPoint("LEFT", titleQueue, "RIGHT", 10, 0)
	ui.queue = {}
	for index = 1, ns.MAX_QUEUE do ui.queue[index] = QueueCell(stage, index, queueTop - 16) end
	ui.queueEmpty = Skin.Text(stage, "GameTooltipTextSmall", "muted")
	ui.queueEmpty:SetPoint("TOPLEFT", stage, "TOPLEFT", 0, queueTop - 26)
	ui.queueEmpty:SetText(L.QUEUE_EMPTY)
	ui.queueRun = Skin.Button(stage, L.QUEUE_RUN, RunQueue, "main")
	ui.queueRun:SetPoint("TOPRIGHT", stage, "TOPRIGHT", 0, queueTop - 20)
	Skin.Tooltip(ui.queueRun, L.QUEUE_RUN_DESC)
end

local function BuildPrompt(stage)
	local prompt = CreateFrame("Frame", nil, window)
	prompt:SetPoint("TOPLEFT", window, "TOPLEFT", ui.margin + RAIL + 10, -TOP)
	prompt:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", 0, 0)
	ui.promptTitle = Skin.Text(prompt, "GameTooltipHeaderText", "gold")
	ui.promptTitle:SetPoint("CENTER", 0, 40)
	ui.promptText = Skin.Text(prompt, "GameTooltipText", "soft")
	ui.promptText:SetPoint("TOP", ui.promptTitle, "BOTTOM", 0, -8)
	ui.promptText:SetWidth(420)
	ui.promptButton = Skin.Button(prompt, L.OPEN_PROFESSION, function() if current then PickProfession(current) end end, "main")
	ui.promptButton:SetPoint("TOP", ui.promptText, "BOTTOM", 0, -14)
	ui.prompt = prompt
end

local function BuildHeading()
	local left = ui.margin + RAIL + 10 + LIST_WIDTH + STAGE_GAP
	local heading = CreateFrame("Frame", nil, window)
	heading:SetPoint("TOPLEFT", window, "TOPLEFT", left, -ui.margin - 2)
	heading:SetSize(300, 36)
	ui.headName = Skin.Text(heading, "GameTooltipText", "gold")
	ui.headName:SetPoint("TOPLEFT")
	ui.headSkill = Skin.Text(heading, "GameTooltipText", "text")
	ui.headSkill:SetPoint("LEFT", ui.headName, "RIGHT", 10, 0)
	ui.headKnown = Skin.Text(heading, "GameTooltipTextSmall", "muted")
	ui.headKnown:SetPoint("TOPRIGHT", 0, -2)
	ui.headBar = Skin.ProgressLine(heading, 4)
	ui.headBar:SetPoint("TOPLEFT", ui.headName, "BOTTOMLEFT", 0, -7)
	ui.headBar:SetWidth(300)
	ui.headNext = Skin.Text(heading, "GameTooltipTextSmall", "muted")
	ui.headNext:SetPoint("TOPLEFT", ui.headBar, "BOTTOMLEFT", 0, -3)
	ui.heading = heading
	ui.gameButton = Skin.SmallButton(window, L.GAME_WINDOW, function() ns.UseGameWindow() end, L.GAME_WINDOW_DESC)
	ui.gameButton:SetPoint("TOPRIGHT", window, "TOPRIGHT", -62, -8)
end

local function Create()
	window = Skin.CreateWindow("WandererProfessionsWindow", "MEDIUM")
	window:SetSize(WIDTH, HEIGHT)
	window:Hide()
	Skin.Sounds(window, Skin.SOUNDS.open, Skin.SOUNDS.close)
	Skin.Dress(window, { "CENTER", UIParent, "CENTER", 0, 30 }, "professionsPos")
	local _, _, margin = Skin.Header(window, "Wanderer", L.TITLE, { settings = "ext:professions" })
	-- (the heading's "?": what the workbench does, in a few words)
	if Skin.Help then Skin.Help(window, L.HELP_TIP, "HEADING") end
	ui = { margin = margin, rail = {}, cards = {}, treeRows = {}, pageButtons = {}, headerPool = {}, rowPool = {}, gridPool = {} }
	ui.stageWidth = WIDTH - margin * 2 - RAIL - 10 - LIST_WIDTH - STAGE_GAP
	BuildList()
	local stage = CreateFrame("Frame", nil, window)
	stage:SetPoint("TOPLEFT", window, "TOPLEFT", margin + RAIL + 10 + LIST_WIDTH + STAGE_GAP, -TOP)
	stage:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
	ui.stage = stage
	BuildHero(stage)
	local materials = Skin.Caps(stage, L.MATERIALS, "kicker")
	materials:SetPoint("TOPLEFT", stage, "TOPLEFT", 0, -HERO_HEIGHT - 9)
	ui.toShopping = Skin.SmallButton(stage, L.TO_SHOPPING, function()
		local recipe = Selected()
		if not recipe then return end
		W.Print(L.TO_SHOPPING_DONE:format(ns.ToShopping(recipe, math.max(amount, 1))))
	end, L.TO_SHOPPING_DESC, 18)
	ui.toShopping:SetPoint("TOPRIGHT", stage, "TOPRIGHT", 0, -HERO_HEIGHT - 5)
	ui.treeToggle = Skin.SmallButton(stage, L.TREE, function()
		showTree = not showTree
		Skin.Play("click")
		ns.Draw()
	end, L.TREE_DESC, 18)
	ui.treeToggle:SetPoint("LEFT", materials, "RIGHT", 10, 0)
	ui.guildAsk = Skin.SmallButton(stage, L.GUILD_ASK, function()
		local recipe = Selected()
		if recipe then ns.GuildAsk(recipe.id) end
	end, L.GUILD_ASK_DESC, 18)
	ui.guildAsk:SetPoint("LEFT", ui.treeToggle, "RIGHT", 6, 0)
	local bottom = BuildActions(stage)
	BuildBottom(stage, bottom)
	BuildPrompt(stage)
	BuildHeading()
	window:HookScript("OnShow", function() ns.Draw() end)
	window:HookScript("OnHide", function()
		if not leaving and atBench and mode == "wanderer" then ns.CloseProfession() end
	end)
	ns.OnChanged(function() ns.Draw() end)
end

-- With the game's window -------------------------------------------------------------------------------------

local function HookGameWindow()
	local frame = _G.ProfessionsFrame
	if placeGame or not frame then return end
	placeGame = Skin.AsideGameWindow(frame, Away)
end

local function Reopen()
	local frame = _G.ProfessionsFrame
	if reopen or not frame then return reopen end
	reopen = Skin.SmallButton(UIParent, L.TITLE, function() ns.UseWorkbench() end, L.BACK_TO_BENCH_DESC)
	reopen:SetFrameStrata("HIGH")
	reopen:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, -4)
	reopen:Hide()
	return reopen
end

function ns.UseGameWindow()
	mode = "game"
	if window and window:IsShown() then
		leaving = true
		window:Hide()
		leaving = false
	end
	if placeGame then placeGame() end
	if Reopen() then reopen:Show() end
end

function ns.UseWorkbench()
	mode = "wanderer"
	if reopen then reopen:Hide() end
	if not window then Create() end
	if placeGame then placeGame() end
	if window:IsShown() then ns.Draw() else window:Show() end
end

local function Arrive()
	if not ns.On() then return end
	HookGameWindow()
	local line = ns.ReadLive()
	local fromBench = pending ~= nil
	pending = nil
	atBench = line ~= nil
	-- (someone else's list, or the guild's: the game's window, as it is)
	if not line then
		if placeGame then placeGame() end
		return
	end
	current = line
	ns.DB().last = line
	if mode == "wanderer" and (Replaces() or fromBench) then
		ns.UseWorkbench()
	else
		ns.UseGameWindow()
	end
end

local function Leave()
	atBench = false
	ns.ForgetRun()
	ns.ForgetLive()
	if placeGame then placeGame() end
	-- (going from one profession to another: the game closes the first, the window stays)
	if pending then return end
	mode = "wanderer"
	if reopen then reopen:Hide() end
	if window and window:IsShown() then
		leaving = true
		window:Hide()
		leaving = false
	end
end

function ns.Toggle()
	if not ns.On() then return SayOff() end
	if window and window:IsShown() then return window:Hide() end
	-- (the game's window on screen, asked for: the workbench takes its place again)
	if atBench and mode == "game" then return ns.UseWorkbench() end
	ns.Open()
end

function ns.Open()
	if not ns.On() then return SayOff() end
	if not window then Create() end
	window:Show()
	if not atBench and current and Replaces() then PickProfession(current) end
end

ns.Window = function() return window end -- (tests)
ns.State = function() return { current = current, mode = mode, atBench = atBench, entries = entries, ui = ui } end -- (tests)

-- Init -----------------------------------------------------------------------------------------------------------

BINDING_HEADER_WANDERERPROFESSIONS = "Wanderer Professions"
BINDING_NAME_WANDERERPROFESSIONS_TOGGLE = L.TITLE
function WandererProfessions_Toggle() if ns.ready then ns.Toggle() end end -- (nothing before Init has passed Wanderer's check)

-- The game's key for the professions opens the workbench: an override for this session, so your own key bindings
-- are never rewritten and everything goes back by itself when this is off.
local keyOwner, takenKeys
local function PlaceProfessionKey()
	if InCombatLockdown() then return U.AfterFight("professionsKey", PlaceProfessionKey) end
	local keys = {}
	if ns.On() and ns.Settings().takeKey and Replaces() and ns.Professions()[1] and GetBindingKey then
		keys = { GetBindingKey("TOGGLEPROFESSIONBOOK") }
	end
	local words = table.concat(keys, ",")
	if words == (takenKeys or "") then return end
	takenKeys = words
	keyOwner = keyOwner or CreateFrame("Frame")
	U.Safe(ClearOverrideBindings, keyOwner)
	for _, key in ipairs(keys) do U.Safe(SetOverrideBinding, keyOwner, false, key, "WANDERERPROFESSIONS_TOGGLE") end
end

local readSoon = U and U.Debounce(0.1, function()
	if atBench then
		ns.ReadLive()
		ns.Changed()
	end
end)

local function OnEvent(_, event, unit, second, spell, fourth)
	-- (always: the game's window must come back even when the addon was switched off meanwhile)
	if event == "TRADE_SKILL_CLOSE" then return Leave() end
	if event == "UPDATE_BINDINGS" or event == "PLAYER_ENTERING_WORLD" then return PlaceProfessionKey() end
	if event == "SKILL_LINES_CHANGED" then PlaceProfessionKey() end
	if not ns.On() then return end
	if event == "CHAT_MSG_ADDON" then return ns.OnGuildMessage(unit, second, spell, fourth) end
	if event == "UNIT_SPELLCAST_START" then return ns.CraftStarted(U.Clean(spell)) end
	if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then return ns.CraftStopped(U.Clean(spell)) end
	if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then return ns.ReadMerchant() end
	if event == "TRADE_SKILL_SHOW" then
		Arrive()
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if unit == "player" then ns.CraftDone(U.Clean(spell)) end
	elseif event == "BAG_UPDATE_DELAYED" or event == "GET_ITEM_INFO_RECEIVED" then
		if window and window:IsShown() then ns.Changed() end
	else
		readSoon()
	end
end

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- (built on Wanderer's API 16: an older Wanderer is only asked to update, nothing of it is called)
	if (W.API or 1) < 16 then return W.Print(L.NEEDS_WANDERER) end
	-- (the controller's wheel: the workbench in front of the game's window, when it replaces it)
	if W and W.Skin and W.Skin.PadStandIn then
		W.Skin.PadStandIn({ micro = _G.ProfessionMicroButton, binding = "TOGGLEPROFESSIONBOOK",
			wanted = function() return ns.On() and Replaces() and ns.Professions()[1] ~= nil end,
			game = function()
				local book = _G.ProfessionsBookFrame
				return book and book:IsShown() and book or _G.ProfessionsFrame
			end,
			open = function() ns.Open() end, window = function() return window end })
	end
	W.RegisterExtension({
		key = "professions",
		addon = ADDON,
		slash = "/wprofessions",
		title = L.ADDON,
		news = L.NEWS_LINES,
		defaults = { enabled = true, replace = true, takeKey = true, guild = false },
		launcher = { label = L.TITLE, open = function() ns.Toggle() end },
		refresh = function() ns.Changed() end,
		options = function(o)
			local enabled = o.Checkbox("professions", "enabled", L.ENABLE, L.ENABLE_DESC, ns.Changed)
			local on = o.IsOn("professions", "enabled")
			o.Under(o.Button(L.TITLE, L.OPEN, L.OPEN_DESC, function()
				o.CloseSettings()
				ns.Open()
			end), enabled, on)
			o.Under(o.Checkbox("professions", "replace", L.REPLACE, L.REPLACE_DESC, ns.Changed), enabled, on)
			o.Under(o.Checkbox("professions", "takeKey", L.TAKE_KEY, L.TAKE_KEY_DESC, ns.Changed), enabled, on)
			o.Under(o.Checkbox("professions", "guild", L.GUILD, L.GUILD_DESC, ns.Changed), enabled, on)
		end,
	})
	SLASH_WANDERERPROFESSIONS1 = "/wprofessions"
	SLASH_WANDERERPROFESSIONS2 = "/wprof"
	SlashCmdList.WANDERERPROFESSIONS = function(text)
		if (text or ""):lower():find("^%s*dump") then
			ns.Dump()
			return W.Print(L.DUMP_DONE)
		end
		ns.Toggle()
	end
	W.WhenLoaded("Blizzard_Professions", HookGameWindow)
	-- (switched off with the workbench open: it goes, and the game's window comes back)
	ns.OnChanged(function()
		PlaceProfessionKey()
		if placeGame then placeGame() end
		if window and window:IsShown() and not ns.On() then
			leaving = true
			window:Hide()
			leaving = false
		end
	end)
	ns.InitGuild()
	if W.OnCharacterForgotten then W.OnCharacterForgotten(ns.ForgetCharacter) end
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
		"NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "MERCHANT_SHOW", "MERCHANT_UPDATE", "CHAT_MSG_ADDON", "UPDATE_BINDINGS", "PLAYER_ENTERING_WORLD" }) do
		events:RegisterEvent(event)
	end
	for _, event in ipairs({ "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED" }) do
		events:RegisterUnitEvent(event, "player")
	end
	events:SetScript("OnEvent", OnEvent)
	ns.ready = true
end

if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
