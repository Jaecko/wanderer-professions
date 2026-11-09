local _, ns = ...
local L = ns.L

-- Wanderer Professions, what goes beyond this profession now: what your other characters know and when their
-- cooldowns end (a ledger for the account, written by each character as it opens its professions), the next rank,
-- Merchant's Favor (the database, corrected by what the merchants really ask), the sub-recipes of a reagent.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local EMPTY = {}
local TREE_DEPTH = 3
-- A profession's ceiling -> the next rank: the skill and the level it asks.
local NEXT_RANKS = { [75] = { word = "RANK_JOURNEYMAN", skill = 50, level = 10 }, [150] = { word = "RANK_EXPERT", skill = 125, level = 20 },
	[225] = { word = "RANK_ARTISAN", skill = 200, level = 35 } }

local function Account()
	WandererProfessionsAccountDB = type(WandererProfessionsAccountDB) == "table" and WandererProfessionsAccountDB or {}
	local db = WandererProfessionsAccountDB
	for _, part in ipairs({ "characters", "favor" }) do
		if type(db[part]) ~= "table" then db[part] = {} end
	end
	return db
end

local function Mine()
	local characters = Account().characters
	local key = W.CharacterKey()
	characters[key] = type(characters[key]) == "table" and characters[key] or {}
	local mine = characters[key]
	for _, part in ipairs({ "lines", "cooldowns" }) do
		if type(mine[part]) ~= "table" then mine[part] = {} end
	end
	return mine
end

function ns.ForgetCharacter(key) Account().characters[key] = nil end

-- A character forgets nothing by opening one profession: only this line is written again.
function ns.RecordRead(line, book)
	local mine = Mine()
	local known = {}
	for id, row in pairs(book.recipes) do
		if row.l then known[id] = true end
	end
	mine.lines[line] = { known = known, time = time() }
	local ui = C_TradeSkillUI
	if not (ui and ui.GetRecipeCooldown) then return end
	local data = ns.PROF_RECIPES and ns.PROF_RECIPES[line] or EMPTY
	for id in pairs(known) do
		if data[id] and data[id].cd then
			local left = Clean(Safe(ui.GetRecipeCooldown, id))
			mine.cooldowns[id] = type(left) == "number" and left > 0 and time() + math.floor(left) or nil
		end
	end
end

-- Seconds before this recipe can be made again on this character (nil: ready).
function ns.CooldownLeft(recipe)
	local ready = Mine().cooldowns[recipe.id]
	return ready and ready > time() and ready - time() or nil
end

-- "in 3 h", "in 12 min".
function ns.WaitWords(seconds)
	if seconds >= 3600 then return L.IN_HOURS:format(math.ceil(seconds / 3600)) end
	return L.IN_MINUTES:format(math.max(1, math.ceil(seconds / 60)))
end

-- Your other characters who know a recipe: { name, class }.
function ns.KnownBy(line, id)
	local list = {}
	local characters = Account().characters
	for _, who in ipairs(W.Characters(true)) do
		local entry = characters[who.key]
		local book = type(entry) == "table" and entry.lines and entry.lines[line]
		if book and book.known and book.known[id] then list[#list + 1] = { name = who.name, class = who.class } end
	end
	return list
end

-- Each character's cooldowns, those Wanderer keeps (transmutes, mooncloth, salt shaker) and those read here:
-- { { name, left } }, left nil when ready.
function ns.CooldownsOf(who)
	local list, now = {}, time()
	local named = {}
	for _, cooldown in ipairs(type(who.entry and who.entry.cooldowns) == "table" and who.entry.cooldowns or EMPTY) do
		list[#list + 1] = { name = cooldown.name, left = (cooldown.ready or 0) > now and cooldown.ready - now or nil }
		named[#named + 1] = cooldown.name
	end
	local entry = Account().characters[who.key]
	for id, ready in pairs(type(entry) == "table" and entry.cooldowns or EMPTY) do
		local name = C_Spell and C_Spell.GetSpellName and Clean(Safe(C_Spell.GetSpellName, id))
		local kept = false
		for _, other in ipairs(named) do
			if name and name:sub(1, #other) == other then kept = true end
		end
		if name and not kept then list[#list + 1] = { name = name, left = ready > now and ready - now or nil } end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

-- Who knows what, for a search by name: { { id, line, name, who = { names } } } (at most `most`).
function ns.WhoKnows(query, most)
	local folded, found, index = U.Fold(query), {}, {}
	local characters = Account().characters
	for _, who in ipairs(W.Characters()) do
		local entry = characters[who.key]
		for line, book in pairs(type(entry) == "table" and entry.lines or EMPTY) do
			for id in pairs(book.known or EMPTY) do
				local name = index[id] and index[id].name or (C_Spell and C_Spell.GetSpellName and Clean(Safe(C_Spell.GetSpellName, id)))
				if name and U.Matches(name, query, folded) then
					local row = index[id]
					if not row then
						row = { id = id, line = line, name = name, who = {} }
						index[id] = row
						found[#found + 1] = row
					end
					row.who[#row.who + 1] = who.name
				end
			end
		end
	end
	table.sort(found, function(a, b) return a.name < b.name end)
	for position = #found, (most or 100) + 1, -1 do found[position] = nil end
	return found
end

-- The next rank of a profession at its ceiling: { name, skill, level, ready } (nil: nothing above).
function ns.NextRank(profession)
	local rank = NEXT_RANKS[profession.most]
	if not rank then return nil end
	local level = Clean(Safe(UnitLevel, "player")) or 0
	return { name = L[rank.word], skill = rank.skill, level = rank.level, ready = profession.rank >= rank.skill and level >= rank.level }
end

-- A recipe anywhere ------------------------------------------------------------------------------------------

local lineOf
function ns.LineOf(spell)
	if not lineOf then
		lineOf = {}
		for line, rows in pairs(ns.PROF_RECIPES or EMPTY) do
			for id in pairs(rows) do lineOf[id] = line end
		end
	end
	return lineOf[spell]
end

-- The recipes that make a thing, among those this character knows: a reagent's own recipe.
local makers
function ns.ForgetMakers() makers = nil end
function ns.MakerOf(item)
	if not makers then
		makers = {}
		for _, profession in ipairs(ns.Professions()) do
			for _, recipe in ipairs(ns.Recipes(profession.line) or EMPTY) do
				if recipe.learned and recipe.item and recipe.reagents[1] and not makers[recipe.item] then makers[recipe.item] = recipe end
			end
		end
	end
	return makers[item]
end

-- What a craft really asks, reagent under reagent where one is made and the bags fall short:
-- { { id, need, have, depth, maker } } in reading order.
function ns.Tree(recipe, times)
	local rows = {}
	-- (items: how many of the parent's product are wanted; a craft may give several)
	local function Walk(parent, items, depth, seen)
		local crafts = math.ceil(items / math.max(parent.made or 1, 1))
		for _, reagent in ipairs(parent.reagents) do
			local need = reagent.need * crafts
			local have = ns.Owned(reagent.id)
			local maker = ns.MakerOf(reagent.id)
			rows[#rows + 1] = { id = reagent.id, need = need, have = have, depth = depth, maker = maker }
			if maker and have < need and depth < TREE_DEPTH and not seen[maker.id] then
				seen[maker.id] = true
				Walk(maker, need - have, depth + 1, seen)
				seen[maker.id] = nil
			end
		end
	end
	Walk(recipe, times * math.max(recipe.made or 1, 1), 1, { [recipe.id] = true })
	return rows
end

-- Merchant's Favor -------------------------------------------------------------------------------------------

local function FavorData() return ns.PROF_FAVOR or EMPTY end

-- How much you hold (nil: this client does not say).
function ns.FavorAmount()
	local data = FavorData()
	if data.currency and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local info = Safe(C_CurrencyInfo.GetCurrencyInfo, data.currency)
		return type(info) == "table" and Clean(info.quantity) or nil
	end
	return data.item and U.ItemCount(data.item) or nil
end

-- Its cost: what a merchant was seen asking comes before the database. { cost, rep }
function ns.FavorOf(spell)
	local seen = Account().favor[spell]
	local known = (FavorData().recipes or EMPTY)[spell]
	if seen then return { cost = seen, rep = known and known.rep } end
	return known and { cost = known.cost, rep = known.rep } or nil
end

-- Every recipe sold for Favor, known by the database or seen at a merchant.
function ns.FavorSpells()
	local spells, seen = {}, {}
	for _, source in ipairs({ FavorData().recipes or EMPTY, Account().favor }) do
		for spell in pairs(source) do
			if not seen[spell] then
				seen[spell] = true
				spells[#spells + 1] = spell
			end
		end
	end
	return spells
end

function ns.FavorGoal() return ns.DB().favorGoal end
function ns.SetFavorGoal(spell)
	ns.DB().favorGoal = spell
	ns.Changed()
end

local spellOfRecipeItem
local function SpellOfRecipeItem(item)
	if not spellOfRecipeItem then
		spellOfRecipeItem = {}
		for _, rows in pairs(ns.PROF_RECIPES or EMPTY) do
			for id, row in pairs(rows) do
				if row.b then spellOfRecipeItem[row.b] = id end
			end
		end
	end
	return spellOfRecipeItem[item]
end

local function FavorName()
	local data = FavorData()
	if data.currency and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local info = Safe(C_CurrencyInfo.GetCurrencyInfo, data.currency)
		return type(info) == "table" and Clean(info.name) or nil
	end
	return data.item and U.ItemName(data.item) or nil
end

-- A merchant open: what it really asks in Favor, kept for the account.
function ns.ReadMerchant()
	local name = FavorName()
	local count = name and Clean(Safe(GetMerchantNumItems))
	if not count or not GetMerchantItemCostInfo then return end
	local changed = false
	for index = 1, count do
		local spell = SpellOfRecipeItem(Clean(Safe(GetMerchantItemID, index)))
		for slot = 1, spell and (Clean(Safe(GetMerchantItemCostInfo, index)) or 0) or 0 do
			local _, value, _, currency = Safe(GetMerchantItemCostItem, index, slot)
			if Clean(currency) == name and Clean(value) then
				Account().favor[spell] = Clean(value)
				changed = true
			end
		end
	end
	if changed then ns.Changed() end
end
