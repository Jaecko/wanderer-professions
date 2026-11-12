local _, ns = ...
local L = ns.L

-- Wanderer Professions, what is known. The game is the authority: an open profession is read through
-- C_TradeSkillUI (widget calls only; nothing of its window is touched) and kept for this character, because a
-- recipe's state can only be trusted once its profession was opened. Data/Recipes.lua adds what the game does not
-- say (the skill thresholds, where a recipe comes from) and the recipes not learned yet. Each recipe says where
-- its facts come from: "read" (the game said so), "data" (the database), "unknown".

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local NOTHING_TO_MAKE = { [182] = true, [393] = true, [356] = true } -- Herbalism, Skinning, Fishing
local DIFFICULTIES = { [0] = "orange", [1] = "yellow", [2] = "green", [3] = "grey" }
local BASIC_REAGENT = 1 -- (Enum.CraftingReagentType.Basic; an optional slot is not owed)
local MAX_SUGGESTIONS = 3
ns.MAX_QUEUE = 9 -- (as many as the strip shows)
local ARMOR_CLASS, ARMOR_KINDS = 4, { [1] = true, [2] = true, [3] = true, [4] = true } -- (cloth, leather, mail, plate)
local EMPTY = {}

local function DB()
	WandererProfessionsDB = type(WandererProfessionsDB) == "table" and WandererProfessionsDB or {}
	local db = WandererProfessionsDB
	-- (seen: skill line -> what the game said; queue: { line, id, count }; folded: the groups closed)
	for _, part in ipairs({ "seen", "queue", "folded" }) do
		if type(db[part]) ~= "table" then db[part] = {} end
	end
	return db
end
ns.DB = DB

function ns.Settings() return W.Settings("professions") or EMPTY end
function ns.On() return ns.Settings().enabled and true or false end

-- What changes the window: redrawn once, a moment later.
local listeners = {}
function ns.OnChanged(fn) listeners[#listeners + 1] = fn end
local function Tell() for _, fn in ipairs(listeners) do fn() end end
ns.Changed = U and U.Debounce(0.05, Tell) or function() end

-- The professions --------------------------------------------------------------------------------------------

-- Those of this character that make something: { name, icon, rank, most, line }. withGathering: the gathering ones
-- too, after them, marked gather (their skill on the rail; Forever gives some of them things to make, read once
-- they are opened like the others).
function ns.Professions(withGathering)
	local list, gathering = {}, {}
	for _, known in ipairs(U.Professions()) do
		if known.line and not NOTHING_TO_MAKE[known.line] then
			list[#list + 1] = known
		elseif known.line and withGathering then
			known.gather = true
			gathering[#gathering + 1] = known
		end
	end
	for _, known in ipairs(gathering) do list[#list + 1] = known end
	return list
end

function ns.Profession(line, withGathering)
	for _, known in ipairs(ns.Professions(withGathering)) do
		if known.line == line then return known end
	end
end

-- The profession open in the game now, if it is this character's own (never a link, nor the guild's).
local function OpenLine()
	local ui = C_TradeSkillUI
	if not (ui and ui.GetBaseProfessionInfo) then return nil end
	if ui.IsTradeSkillLinked and Clean(Safe(ui.IsTradeSkillLinked)) then return nil end
	if ui.IsTradeSkillGuild and Clean(Safe(ui.IsTradeSkillGuild)) then return nil end
	local info = Safe(ui.GetBaseProfessionInfo)
	if type(info) ~= "table" then return nil end
	local name, line = Clean(info.professionName), Clean(info.professionID)
	for _, known in ipairs(U.Professions()) do
		if (line and known.line == line) or known.name == name then return known.line or line end
	end
	return nil
end

local live -- the skill line open in the game
function ns.LiveLine() return live end
function ns.ForgetLive() live = nil end

-- Reading the game ---------------------------------------------------------------------------------------------

-- Its reagents and product, for a recipe the database does not have (what the game asks is what counts).
local function ReadSchematic(ui, id, row)
	if not ui.GetRecipeSchematic then return end
	local schematic = Safe(ui.GetRecipeSchematic, id, false)
	if type(schematic) ~= "table" then return end
	local flat = {}
	local slots = schematic.reagentSlotSchematics
	for _, slot in ipairs(type(slots) == "table" and slots or EMPTY) do
		local first = type(slot.reagents) == "table" and slot.reagents[1]
		local item, count = first and Clean(first.itemID), Clean(slot.quantityRequired)
		local kind = Clean(slot.reagentType)
		if item and count and count > 0 and (kind == nil or kind == BASIC_REAGENT) then
			flat[#flat + 1], flat[#flat + 2] = item, count
		end
	end
	if flat[1] then row.r = flat end
	row.i = Clean(schematic.outputItemID) or row.i
	row.n = Clean(schematic.quantityMin) or row.n
end

local function ReadCategory(ui, book, id)
	if not (id and ui.GetCategoryInfo) or book.cats[id] then return end
	local info = Safe(ui.GetCategoryInfo, id)
	if type(info) == "table" and Clean(info.name) then
		book.cats[id] = { name = Clean(info.name), order = Clean(info.uiOrder) or 0 }
	end
end

local lists, checked = {}, {} -- (the recipes built, by skill line; the database's rows asked once a session)

-- The game has no such recipe (the client's tables know recipes this world does not have): left out for good.
local function CheckAbsent(ui, line, book, read)
	if checked[line] then return end
	checked[line] = true
	book.absent = {}
	for id in pairs(ns.PROF_RECIPES and ns.PROF_RECIPES[line] or EMPTY) do
		if not read[id] and type(Safe(ui.GetRecipeInfo, id)) ~= "table" then book.absent[id] = true end
	end
end

-- What is open now, kept for this character. Called again each time the game updates the list.
function ns.ReadLive()
	local ui = C_TradeSkillUI
	local line = OpenLine()
	live = line
	if not (line and ui.GetAllRecipeIDs and ui.GetRecipeInfo) then return nil end
	local ids = Safe(ui.GetAllRecipeIDs)
	if type(ids) ~= "table" or #ids == 0 then ids = ui.GetFilteredRecipeIDs and Safe(ui.GetFilteredRecipeIDs) end
	if type(ids) ~= "table" or #ids == 0 then return line end -- (not ready yet: the next update has them)
	local seen = DB().seen
	local before = seen[line] or EMPTY
	local book = { cats = before.cats or {}, absent = before.absent, recipes = {}, time = time() }
	local data = ns.PROF_RECIPES and ns.PROF_RECIPES[line] or EMPTY
	local unlearned = false
	for _, id in ipairs(ids) do
		local info = Safe(ui.GetRecipeInfo, id)
		if type(info) == "table" then
			local was = (before.recipes or EMPTY)[id] or EMPTY
			local row = { nm = Clean(info.name), ic = Clean(info.icon), l = Clean(info.learned) and 1 or nil,
				d = Clean(info.relativeDifficulty), c = Clean(info.categoryID) or was.c, s = was.s, r = was.r, i = was.i, n = was.n }
			if not row.l then unlearned = true end
			if not row.r and not (data[id] and data[id].r) then ReadSchematic(ui, id, row) end
			ReadCategory(ui, book, row.c)
			book.recipes[id] = row
		end
	end
	-- (the game's list also has the recipes not learned: then it alone says which exist)
	book.full = unlearned or nil
	seen[line] = book
	if not book.full then CheckAbsent(ui, line, book, book.recipes) end
	lists[line] = nil
	ns.ForgetMakers()
	ns.RecordRead(line, book)
	return line
end

-- Asked when a recipe is chosen: where the game says it comes from.
function ns.ReadSource(recipe)
	local ui = C_TradeSkillUI
	local book = DB().seen[recipe.line]
	local row = book and book.recipes[recipe.id]
	if not (row and ui and ui.GetRecipeSourceText) or recipe.sourceText then return end
	local text = Clean(Safe(ui.GetRecipeSourceText, recipe.id))
	if type(text) == "string" and text ~= "" then
		row.s = text
		recipe.sourceText = text
		recipe.confidence = "read"
	end
end

-- The recipes --------------------------------------------------------------------------------------------------

local function SpellName(id)
	if C_Spell and C_Spell.GetSpellName then return Clean(Safe(C_Spell.GetSpellName, id)) end
end
local function SpellIcon(id)
	if C_Spell and C_Spell.GetSpellTexture then return Clean(Safe(C_Spell.GetSpellTexture, id)) end
end

local function Reagents(flat)
	local list = {}
	for index = 1, #(flat or EMPTY), 2 do list[#list + 1] = { id = flat[index], need = flat[index + 1] } end
	return list
end

local function Category(book, id)
	local known = id and book.cats and book.cats[id]
	if known then return known.name, known.order end
	local ui = C_TradeSkillUI
	local info = id and ui and ui.GetCategoryInfo and Safe(ui.GetCategoryInfo, id)
	if type(info) == "table" and Clean(info.name) then return Clean(info.name), Clean(info.uiOrder) or 0 end
	return L.GROUP_RECIPES, 9999
end

-- (some old trainer requirements stand above the yellow this world gives: the yellow is the truth)
local function Orange(data)
	if data.o and data.y then return math.min(data.o, data.y) end
	return data.o
end

local function Make(line, id, row, data, book)
	local item = row and row.i or data and data.i
	local name = row and row.nm or SpellName(id) or (item and U.ItemName(item))
	if not name then return nil end -- (a spell this client does not know)
	row, data = row or EMPTY, data or EMPTY
	local category, order = Category(book, row.c or data.c)
	local confidence = "unknown"
	if row.l or row.s then confidence = "read" elseif data.k then confidence = "data" end
	return { line = line, id = id, name = name, icon = row.ic or (item and U.ItemIcon(item)) or SpellIcon(id), item = item,
		made = row.n or data.n or 1, learned = row.l == 1, difficulty = row.d, category = category, order = order,
		reagents = Reagents(row.r or data.r), orange = Orange(data), yellow = data.y, green = data.g, grey = data.e,
		kind = data.k, cost = data.cost, teaches = data.b, places = data.p, sourceText = row.s, confidence = confidence,
		cooldown = data.cd, spec = data.sp }
end

-- One recipe, even of a profession never opened here.
function ns.DescribeRecipe(line, id)
	local data = ns.PROF_RECIPES and ns.PROF_RECIPES[line] and ns.PROF_RECIPES[line][id]
	local book = DB().seen[line] or EMPTY
	return Make(line, id, book.recipes and book.recipes[id], data, book)
end

local function Sooner(a, b)
	if a.learned ~= b.learned then return a.learned end
	if a.order ~= b.order then return a.order < b.order end
	if a.category ~= b.category then return a.category < b.category end
	if (a.yellow or 0) ~= (b.yellow or 0) then return (a.yellow or 0) > (b.yellow or 0) end
	return a.name < b.name
end

-- All the recipes of a profession (nil: never opened on this character, so nothing can be said yet).
function ns.Recipes(line)
	if lists[line] then return lists[line] end
	local book = DB().seen[line]
	if not book then return nil end
	local data = ns.PROF_RECIPES and ns.PROF_RECIPES[line] or EMPTY
	local list = {}
	for id, row in pairs(book.recipes) do list[#list + 1] = Make(line, id, row, data[id], book) end
	if not book.full then
		local faction = (UnitFactionGroup("player") or ""):sub(1, 1)
		local absent = book.absent or EMPTY
		for id, row in pairs(data) do
			-- (a row with neither a source nor a recipe item: nothing says it can be had in this world)
			if not book.recipes[id] and (row.k or row.b) and not absent[id] and (not row.f or row.f == faction) then
				list[#list + 1] = Make(line, id, nil, row, book)
			end
		end
	end
	table.sort(list, Sooner)
	lists[line] = list
	return list
end

-- "And at skill 250?": the colors and the suggestions at another skill, nothing else.
local preview
function ns.PreviewRank() return preview end
function ns.SetPreviewRank(rank) preview = rank end

-- A recipe's color for this skill: "red" (not reachable yet), orange, yellow, green, grey; nil when nothing says.
function ns.Color(recipe, rank)
	rank = preview or rank
	if not preview and recipe.line == live and recipe.difficulty then return DIFFICULTIES[recipe.difficulty] end
	if rank and recipe.yellow and recipe.grey then
		if recipe.orange and rank < recipe.orange then return "red" end
		if rank < recipe.yellow then return "orange" end
		if rank < (recipe.green or recipe.grey) then return "yellow" end
		return rank < recipe.grey and "green" or "grey"
	end
	return DIFFICULTIES[recipe.difficulty]
end

-- What you own -------------------------------------------------------------------------------------------------

local counts = {} -- (asked once per drawing: the same reagent comes back in many recipes)
function ns.ForgetCounts() wipe(counts) end

-- In the bags, in the bank.
function ns.Owned(id)
	local known = counts[id]
	if not known then
		local bags = U.ItemCount(id) or 0
		known = { bags = bags, bank = math.max((U.ItemCount(id, true) or bags) - bags, 0) }
		counts[id] = known
	end
	return known.bags, known.bank
end

-- How many can be made from the bags now.
function ns.CanMake(recipe)
	if not recipe.reagents[1] then return 0 end
	local most = math.huge
	for _, reagent in ipairs(recipe.reagents) do
		most = math.min(most, math.floor(ns.Owned(reagent.id) / reagent.need))
	end
	return most
end

-- The share of the reagents of one craft you carry (0 to 1).
function ns.Share(recipe)
	local have, need = 0, 0
	for _, reagent in ipairs(recipe.reagents) do
		have, need = have + math.min(ns.Owned(reagent.id), reagent.need), need + reagent.need
	end
	return need > 0 and have / need or 0
end

-- What a finished item does once made: how it binds, the armor it is ("BIND_PICKUP" or "BIND_EQUIP", a word).
function ns.ItemTraits(item)
	local api = C_Item and C_Item.GetItemInfo or GetItemInfo
	local _, _, _, _, _, _, subType, _, _, _, _, class, subClass, bind = Safe(api, item)
	bind = Clean(bind)
	local armor = Clean(class) == ARMOR_CLASS and ARMOR_KINDS[Clean(subClass)] and Clean(subType) or nil
	return bind == 1 and "BIND_PICKUP" or bind == 2 and "BIND_EQUIP" or nil, armor
end

function ns.BindOf(item) return (ns.ItemTraits(item)) end

-- Words that may be missing, joined.
function ns.Joined(...)
	local parts = {}
	for index = 1, select("#", ...) do
		local word = select(index, ...)
		if word and word ~= "" then parts[#parts + 1] = word end
	end
	return table.concat(parts, "  ·  ")
end

-- Your other characters holding it (Wanderer Bags keeps that): { name, class, bags, bank }.
function ns.Elsewhere(id)
	local bags = _G.WandererBags
	return type(bags) == "table" and bags.Carriers and bags.Carriers(id) or EMPTY
end

local function Auction()
	local auction = _G.WandererAuction
	return type(auction) == "table" and auction.IsOn and auction.IsOn() and auction or nil
end
ns.Auction = Auction

-- What one craft costs at the prices seen at the auction house (nil: a price is missing, or no Auction).
function ns.Cost(recipe)
	local auction = Auction()
	if not (auction and auction.Price and recipe.reagents[1]) then return nil end
	local total = 0
	for _, reagent in ipairs(recipe.reagents) do
		local price = auction.Price("item:" .. reagent.id)
		if not price then return nil end
		total = total + price * reagent.need
	end
	return total
end

-- What to send to the shopping list for this many crafts (what the bags do not cover). Gives how many were sent.
function ns.ToShopping(recipe, times)
	local auction = Auction()
	if not (auction and auction.AddToShopping) then return 0 end
	local sent = 0
	for _, reagent in ipairs(recipe.reagents) do
		-- (the list counts the total to carry: the whole need goes, only for what the bags lack)
		local wanted = reagent.need * times
		if wanted > ns.Owned(reagent.id) and auction.AddToShopping(reagent.id, wanted, recipe.name, true) then sent = sent + 1 end
	end
	return sent
end

-- Never a route: the two or three crafts that help now. Those of a sure point first, then what you can already
-- make, then the cheapest when the prices are known.
function ns.Suggestions(line)
	local profession = ns.Profession(line, true)
	local list = ns.Recipes(line)
	if not (profession and list) or (not preview and profession.rank >= profession.most) then return EMPTY end
	local found = {}
	for _, recipe in ipairs(list) do
		local color = recipe.learned and ns.Color(recipe, profession.rank)
		if color == "orange" or color == "yellow" then
			found[#found + 1] = { recipe = recipe, color = color, can = ns.CanMake(recipe), cost = ns.Cost(recipe) or math.huge }
		end
	end
	table.sort(found, function(a, b)
		if a.color ~= b.color then return a.color == "orange" end
		if (a.can > 0) ~= (b.can > 0) then return a.can > 0 end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.recipe.name < b.recipe.name
	end)
	local top = {}
	for index = 1, math.min(MAX_SUGGESTIONS, #found) do top[index] = found[index] end
	return top
end

-- The queue ----------------------------------------------------------------------------------------------------

function ns.Queue() return DB().queue end

function ns.Enqueue(recipe, count)
	local queue = DB().queue
	for _, step in ipairs(queue) do
		if step.id == recipe.id then
			step.count = step.count + count
			return ns.Changed()
		end
	end
	if #queue >= ns.MAX_QUEUE then return W.Print(L.QUEUE_FULL) end
	queue[#queue + 1] = { line = recipe.line, id = recipe.id, count = count }
	ns.Changed()
end

function ns.Unqueue(index)
	table.remove(DB().queue, index)
	ns.Changed()
end

function ns.FindRecipe(line, id)
	for _, recipe in ipairs(ns.Recipes(line) or EMPTY) do
		if recipe.id == id then return recipe end
	end
end

-- A run: the crafts asked by one click, from the click to the last one. While it lasts the window shows it going
-- on, and does not count the reagents as missing (they leave the bags as it goes).
local run
local RUN_IDLE = 3 -- seconds without a cast before a run is over (the game refused, or it stopped by itself)

function ns.Run() return run end

local function EndRun(finished)
	if not run then return end
	ns.lastRun = { id = run.id, left = run.total - run.done, finished = finished }
	run = nil
	ns.Changed()
end

local function CastNow()
	if not UnitCastingInfo then return nil end
	local _, _, _, started, ending, _, _, _, spell = Safe(UnitCastingInfo, "player")
	started, ending = Clean(started), Clean(ending)
	if Clean(spell) ~= (run and run.id) or not (started and ending) or ending <= started then return nil end
	return started / 1000, ending / 1000
end

-- How far it has gone (0 to 1), with the craft under way, and the seconds left when they can be told.
function ns.RunProgress()
	if not run then return 0 end
	local started, ending = CastNow()
	local part = 0
	if started then
		run.last, run.cast = GetTime(), ending - started
		part = math.max(0, math.min((GetTime() - started) / (ending - started), 1))
	elseif GetTime() - run.last > RUN_IDLE then
		EndRun(false)
		return 1
	end
	return math.min((run.done + part) / run.total, 1), run.cast and math.ceil((run.total - run.done - part) * run.cast) or nil
end

function ns.CraftStarted(spell)
	if run and spell == run.id then run.last = GetTime() end
end

-- Interrupted (you moved, a fight): what remains stays asked, one click starts it again.
function ns.CraftStopped(spell)
	if run and spell == run.id then EndRun(false) end
end

-- Asks the game to stop after the craft under way.
function ns.StopRun()
	local ui = C_TradeSkillUI
	if ui and ui.StopRecipeRepeat then Safe(ui.StopRecipeRepeat) end
	if run then run.total = math.min(run.total, run.done + 1) end
	ns.Changed()
end

function ns.CanStopRun()
	return C_TradeSkillUI and C_TradeSkillUI.StopRecipeRepeat ~= nil or false
end

function ns.ForgetRun() EndRun(false) end

-- A cast that went through: one less in the queue (and the bags change by themselves).
function ns.CraftDone(spell)
	if run and spell == run.id then
		run.done, run.last = run.done + 1, GetTime()
		if run.done >= run.total then EndRun(true) end
	end
	local queue = DB().queue
	for index, step in ipairs(queue) do
		if step.id == spell then
			step.count = step.count - 1
			if step.count <= 0 then table.remove(queue, index) end
			return ns.Changed()
		end
	end
end

-- Doing it -----------------------------------------------------------------------------------------------------

-- Only from a click. Gives false and the reason when it cannot start.
function ns.Craft(recipe, count)
	local ui = C_TradeSkillUI
	if not (ui and ui.CraftRecipe) then return false, L.CRAFT_NO_API end
	if InCombatLockdown() then return false, L.IN_FIGHT end
	if recipe.line ~= live then return false, L.OPEN_FIRST end
	local ok, result = pcall(ui.CraftRecipe, recipe.id, count)
	DB().lastCraft = { id = recipe.id, count = count, ok = ok, result = tostring(result), time = time() }
	if not ok then return false, L.CRAFT_REFUSED end
	run = { id = recipe.id, name = recipe.name, icon = recipe.icon, total = count, done = 0, last = GetTime() }
	ns.Changed()
	return true
end

-- Opens a profession in the game (out of sight under the workbench). Only from a click.
function ns.OpenProfession(line)
	if InCombatLockdown() then return false end
	local ui = C_TradeSkillUI
	return ui and ui.OpenTradeSkill and Safe(ui.OpenTradeSkill, line) ~= false or false
end

function ns.CloseProfession()
	local ui = C_TradeSkillUI
	if ui and ui.CloseTradeSkill then Safe(ui.CloseTradeSkill) end
end

-- The diagnostic: what this client really gives, written in the saved variables (/wprofessions dump).
function ns.Dump()
	local ui = C_TradeSkillUI
	local out = { time = time(), live = live, api = {}, frame = _G.ProfessionsFrame ~= nil }
	for _, name in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs", "GetRecipeInfo", "GetRecipeSchematic", "GetCategoryInfo",
		"GetRecipeSourceText", "GetRecipeCooldown", "CraftRecipe", "CraftEnchant", "OpenTradeSkill", "CloseTradeSkill", "GetBaseProfessionInfo" }) do
		out.api[name] = ui and ui[name] ~= nil or false
	end
	local frame = _G.ProfessionsFrame
	if frame then out.frameShown = frame:IsShown() and true or false end
	out.professions = {}
	for _, known in ipairs(U.Professions()) do
		local line = known.line
		local book = line and DB().seen[line]
		local read, learned = 0, 0
		for _, row in pairs(book and book.recipes or EMPTY) do
			read = read + 1
			if row.l then learned = learned + 1 end
		end
		local data = 0
		for _ in pairs(line and ns.PROF_RECIPES and ns.PROF_RECIPES[line] or EMPTY) do data = data + 1 end
		out.professions[#out.professions + 1] = { name = known.name, line = line, rank = known.rank, most = known.most, read = read,
			learned = learned, data = data, full = book and book.full or false, built = #(line and ns.Recipes(line) or EMPTY) }
	end
	if ui and live and ui.GetAllRecipeIDs then
		local ids = Safe(ui.GetAllRecipeIDs)
		local first = type(ids) == "table" and ids[1]
		out.ids = type(ids) == "table" and #ids or -1
		if first then
			local info = Safe(ui.GetRecipeInfo, first)
			out.first = { id = first }
			for key, value in pairs(type(info) == "table" and info or EMPTY) do
				if type(value) ~= "table" then out.first[key] = Clean(value) end
			end
			local schematic = ui.GetRecipeSchematic and Safe(ui.GetRecipeSchematic, first, false)
			out.schematic = type(schematic) == "table" and #(schematic.reagentSlotSchematics or EMPTY) or false
			out.source = ui.GetRecipeSourceText and Clean(Safe(ui.GetRecipeSourceText, first)) or false
		end
	end
	out.lastCraft = DB().lastCraft
	out.favor = { amount = ns.FavorAmount(), known = #ns.FavorSpells() }
	out.model = DB().model
	DB().dump = out
	return out
end
