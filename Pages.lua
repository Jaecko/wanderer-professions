local _, ns = ...
local L = ns.L

-- The workbench's other pages, on the rail under your professions: Merchant's Favor, your characters, the camp
-- objects, the Writs, the specializations. One way of drawing them all: a heading saying what it is, what it
-- knows, a few switches, then rows made of an icon, two lines and one action.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

-- (the kit's rich row: as many as the page holds; read as it is, an older Wanderer has none)
local ROW_HEIGHT = (Skin and rawget(Skin, "ROW") or { rich = 54 }).rich
local LIST_TOP = 72
local MOST_RESULTS = 100
local EMPTY = {}
local ICONS = { favor = "Interface\\Icons\\INV_Misc_Coin_02", people = "Interface\\Icons\\INV_Misc_GroupLooking",
	camp = "Interface\\Icons\\Spell_Fire_Fire", writs = "Interface\\Icons\\INV_Scroll_03", specs = "Interface\\Icons\\INV_Misc_Book_11" }
ns.PAGE_ICONS = ICONS

local page, widgets
local offset = 0
local switches = { favorMine = true, favorAfford = false, writsAll = false }
local query = ""

local function Toggle(key)
	return function()
		switches[key], offset = not switches[key], 0
		ns.Draw()
	end
end

local function ReachesPlace(place, title, info)
	return { label = L.GO, tip = L.GO_DESC, run = function() U.Go(place.map, place.x, place.y, title, info) end }
end

local function FactionFits(row)
	return not row.f or row.f == (UnitFactionGroup("player") or ""):sub(1, 1)
end

-- What one recipe looks like, known or not (its profession may never have been opened here).
local function Describe(spell)
	local line = ns.LineOf(spell)
	return line and (ns.FindRecipe(line, spell) or ns.DescribeRecipe(line, spell)) or nil
end

local function MyLines()
	local lines = {}
	for _, profession in ipairs(ns.Professions()) do lines[profession.line] = profession end
	return lines
end

-- Merchant's Favor -------------------------------------------------------------------------------------------

local function Reputation(favor)
	if not favor.rep then return nil, true end
	-- (the same recipes on both sides, each with its own faction)
	local factions = (ns.PROF_FAVOR or EMPTY).factions or EMPTY
	local name, standing = U.Faction(factions[(UnitFactionGroup("player") or ""):sub(1, 1)] or favor.rep[1])
	local word = _G["FACTION_STANDING_LABEL" .. favor.rep[2]] or ""
	return L.FAVOR_REPUTATION:format(word, name or "?"), (standing or 0) >= favor.rep[2]
end

local function Bound(item)
	local bind = item and ns.BindOf(item)
	return bind and L[bind] or nil
end

local function FavorRow(spell, have, mine, goal)
	local recipe = Describe(spell)
	local favor = ns.FavorOf(spell)
	if not (recipe and favor and favor.cost) then return nil end
	local affordable = have and have >= favor.cost
	if switches.favorMine and not mine[recipe.line] then return nil end
	if switches.favorAfford and not affordable then return nil end
	local reputation, standing = Reputation(favor)
	local isGoal = goal == spell
	return { cost = favor.cost, goal = isGoal, icon = recipe.icon, quality = recipe.item and U.ItemQuality(recipe.item), item = recipe.item,
		title = isGoal and Skin.Colorize(recipe.name, "gold") or recipe.name, note = ns.Joined(mine[recipe.line] and mine[recipe.line].name, reputation and Skin.Colorize(reputation, standing and "soft" or "bad"), Bound(recipe.item)),
		right = Skin.Colorize(tostring(favor.cost), affordable and "good" or "soft"), faded = recipe.learned,
		action = { label = isGoal and L.FAVOR_GOAL_OFF or L.FAVOR_GOAL, tip = L.FAVOR_GOAL_DESC, run = function() ns.SetFavorGoal(not isGoal and spell or nil) end },
		onClick = recipe.learned and function() ns.GoToRecipe(recipe.line, spell) end or nil }
end

local function FavorView()
	local have, goal = ns.FavorAmount(), ns.FavorGoal()
	local mine = MyLines()
	local rows = {}
	for _, spell in ipairs(ns.FavorSpells()) do
		local row = FavorRow(spell, have, mine, goal)
		if row then rows[#rows + 1] = row end
	end
	table.sort(rows, function(a, b)
		if a.goal ~= b.goal then return a.goal end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.title < b.title
	end)
	local info = goal and ns.FavorOf(goal)
	local recipe = goal and Describe(goal)
	local place = (ns.PROF_FAVOR or EMPTY).merchants
	for _, merchant in ipairs(place or EMPTY) do
		if FactionFits(merchant) then
			place = merchant
			break
		end
	end
	return { title = L.PAGE_FAVOR, sub = have and L.FAVOR_HAVE:format(have) or L.FAVOR_UNKNOWN,
		sub2 = recipe and info and L.FAVOR_GOAL_LINE:format(recipe.name, have or 0, info.cost) or nil,
		share = have and info and info.cost and math.min(have / info.cost, 1) or nil, rows = rows, empty = L.FAVOR_EMPTY,
		go = place and place.map and ReachesPlace(place, L.PAGE_FAVOR, L.FAVOR_MERCHANTS) or nil,
		switches = { { label = L.FAVOR_MINE, on = switches.favorMine, tip = L.FAVOR_MINE_DESC, run = Toggle("favorMine") },
			{ label = L.FAVOR_AFFORD, on = switches.favorAfford, tip = L.FAVOR_AFFORD_DESC, run = Toggle("favorAfford") } } }
end

-- Your characters ------------------------------------------------------------------------------------------

local function PeopleRow(who)
	local crafts = {}
	for _, craft in ipairs(type(who.entry and who.entry.crafts) == "table" and who.entry.crafts or EMPTY) do
		crafts[#crafts + 1] = craft.name .. " " .. craft.rank .. "/" .. craft.max
	end
	local waits, tips = {}, { who.name }
	for _, cooldown in ipairs(ns.CooldownsOf(who)) do
		local state = cooldown.left and ns.WaitWords(cooldown.left) or Skin.Colorize(L.READY, "good")
		tips[#tips + 1] = cooldown.name .. " : " .. state
		if #waits < 2 then waits[#waits + 1] = state end
	end
	local r, g, b = U.ClassColor(who.class)
	return { icon = "Interface\\Icons\\ClassIcon_" .. tostring(who.class or "Warrior"), title = who.name, titleColor = r and { r, g, b } or nil,
		note = crafts[1] and table.concat(crafts, "  ·  ") or L.PEOPLE_NO_CRAFT, right = table.concat(waits, "  ·  "), tip = tips[2] and tips or nil }
end

local function PeopleView()
	local rows = {}
	if query ~= "" then
		for _, found in ipairs(ns.WhoKnows(query, MOST_RESULTS)) do
			local recipe = Describe(found.id)
			rows[#rows + 1] = { icon = recipe and recipe.icon, item = recipe and recipe.item, title = found.name, note = table.concat(found.who, ", "),
				onClick = ns.Profession(found.line) and function() ns.GoToRecipe(found.line, found.id) end or nil }
		end
	else
		for _, who in ipairs(W.Characters()) do rows[#rows + 1] = PeopleRow(who) end
	end
	return { title = L.PAGE_PEOPLE, sub = L.PEOPLE_SUB, search = true, rows = rows, empty = L.PEOPLE_EMPTY }
end

-- Camp objects -----------------------------------------------------------------------------------------------

local function CampView()
	local mine = MyLines()
	local rows = {}
	for spell, camp in pairs(ns.PROF_CAMP or EMPTY) do
		local recipe = Describe(spell)
		local profession = recipe and mine[recipe.line]
		if profession then
			local left = recipe.learned and ns.CooldownLeft(recipe)
			local can = recipe.learned and ns.CanMake(recipe) or 0
			local state
			if not recipe.learned then
				state = Skin.Colorize(L.NOTE_TO_LEARN, "muted")
			elseif left then
				state = ns.WaitWords(left)
			else
				state = Skin.Colorize(can > 0 and L.PROGRESS_CAN:format(can) or L.PROGRESS_SHORT, can > 0 and "good" or "soft")
			end
			local blueprint = camp.blueprint and U.ItemName(camp.blueprint)
			if camp.blueprint and not blueprint then U.LoadItem(camp.blueprint) end
			rows[#rows + 1] = { order = camp.tier * 1000 + camp.skill, icon = recipe.icon, item = recipe.item, title = recipe.name, right = state,
				note = L.CAMP_TIER:format(camp.tier, camp.skill) .. (blueprint and "  ·  " .. L.CAMP_BLUEPRINT:format(blueprint) or ""),
				faded = not recipe.learned, onClick = function() ns.GoToRecipe(recipe.line, spell) end }
		end
	end
	table.sort(rows, function(a, b) return a.order < b.order end)
	return { title = L.PAGE_CAMP, sub = L.CAMP_SUB, rows = rows, empty = L.CAMP_EMPTY }
end

-- Writs ---------------------------------------------------------------------------------------------------------

local function WritRow(item, writ, held, mine)
	local recipe = Describe(writ.spell)
	if not recipe or not (held > 0 or (switches.writsAll and mine[recipe.line])) then return nil end
	local name = U.ItemName(item)
	if not name then U.LoadItem(item) end
	local product = recipe.item and U.ItemName(recipe.item) or recipe.name
	local can = recipe.learned and ns.CanMake(recipe) or 0
	local state
	if not mine[recipe.line] then
		state = Skin.Colorize(L.WRIT_NOT_YOURS, "muted")
	elseif not recipe.learned then
		state = Skin.Colorize(L.NOTE_TO_LEARN, "muted")
	else
		state = Skin.Colorize(can > 0 and L.PROGRESS_CAN:format(can) or L.PROGRESS_SHORT, can > 0 and "good" or "soft")
	end
	return { order = (held > 0 and 0 or 1), name = name or "", icon = U.ItemIcon(item), item = item, title = name or "", right = state, faded = held == 0,
		note = L.WRIT_ASKS:format(writ.count or 1, product) .. (writ.map and "  ·  " .. (U.MapName(writ.map) or "") or ""),
		action = writ.map and writ.x and ReachesPlace(writ, name or "", L.PAGE_WRITS) or nil,
		onClick = recipe.learned and function() ns.GoToRecipe(recipe.line, writ.spell) end or nil }
end

local function WritsView()
	local mine = MyLines()
	local rows = {}
	for item, writ in pairs(ns.PROF_WRITS or EMPTY) do
		local row = WritRow(item, writ, U.ItemCount(item) or 0, mine)
		if row then rows[#rows + 1] = row end
	end
	table.sort(rows, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.name < b.name
	end)
	return { title = L.PAGE_WRITS, sub = L.WRITS_SUB, rows = rows, empty = L.WRITS_EMPTY,
		switches = { { label = L.WRITS_ALL, on = switches.writsAll, tip = L.WRITS_ALL_DESC, run = Toggle("writsAll") } } }
end

-- Specializations ----------------------------------------------------------------------------------------------

-- The recipes a specialization opens: their names, for the tooltip.
local function Gains(line, spell)
	local names = {}
	for id, row in pairs(ns.PROF_RECIPES and ns.PROF_RECIPES[line] or EMPTY) do
		if row.sp == spell then
			local recipe = ns.DescribeRecipe(line, id)
			if recipe then names[#names + 1] = recipe.name end
		end
	end
	table.sort(names)
	return names
end

local function SpecsView()
	local line = ns.CurrentLine()
	local profession = ns.Profession(line, true)
	local rows = {}
	-- (each side has its own quest for the same specialization)
	local specs, seen = {}, {}
	for _, spec in ipairs(ns.PROF_SPECS and ns.PROF_SPECS[line] or EMPTY) do
		if FactionFits(spec) and not seen[spec.spell] then
			seen[spec.spell] = true
			specs[#specs + 1] = spec
		end
	end
	for _, spec in ipairs(specs) do
		local name = C_Spell and C_Spell.GetSpellName and U.Clean(U.Safe(C_Spell.GetSpellName, spec.spell)) or "?"
		local chosen = U.Clean(U.Safe(IsPlayerSpell, spec.spell)) and true or false
		local level = U.Clean(U.Safe(UnitLevel, "player")) or 0
		local reachable = profession and profession.rank >= (spec.skill or 0) and level >= (spec.level or 0)
		local gains = Gains(line, spec.spell)
		local tip = { name, L.SPEC_GAINS:format(#gains) }
		for index = 1, math.min(#gains, 10) do tip[#tip + 1] = gains[index] end
		local state = chosen and Skin.Colorize(L.SPEC_CHOSEN, "good") or Skin.Colorize(reachable and L.SPEC_OPEN or L.SPEC_LOCKED, reachable and "gold" or "muted")
		rows[#rows + 1] = { icon = C_Spell and C_Spell.GetSpellTexture and U.Clean(U.Safe(C_Spell.GetSpellTexture, spec.spell)), title = name, right = state, tip = tip,
			note = L.SPEC_NEEDS:format(spec.level or 0, spec.skill or 0) .. "  ·  " .. L.SPEC_GAINS:format(#gains),
			action = spec.map and not chosen and ReachesPlace(spec, name, L.PAGE_SPECS) or nil }
	end
	return { title = L.PAGE_SPECS, sub = Skin.Colorize(L.SPEC_WARNING, "warn"), rows = rows, empty = L.SPECS_EMPTY }
end

local VIEWS = { favor = FavorView, people = PeopleView, camp = CampView, writs = WritsView, specs = SpecsView }

-- Drawing -------------------------------------------------------------------------------------------------------

local function NewRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT - 3)
	row:RegisterForClicks("LeftButtonUp")
	row.ground = row:CreateTexture(nil, "BACKGROUND")
	row.ground:SetAllPoints()
	row.ground:SetColorTexture(1, 1, 1, 0.03)
	row.icon = Skin.Icon(row, 36)
	row.icon:SetPoint("LEFT", 4, 0)
	row.title = Skin.Text(row, "GameTooltipText", "text")
	row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 9, -2)
	row.title:SetPoint("TOPRIGHT", row, "TOPRIGHT", -270, -5)
	row.title:SetJustifyH("LEFT")
	row.title:SetWordWrap(false)
	row.note = Skin.Text(row, "GameTooltipTextSmall", "muted")
	row.note:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 9, 2)
	row.note:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -270, 5)
	row.note:SetJustifyH("LEFT")
	row.note:SetWordWrap(false)
	row.right = Skin.Text(row, "GameTooltipTextSmall", "soft")
	row.right:SetPoint("RIGHT", row, "RIGHT", -112, 0)
	row.right:SetWidth(150)
	row.right:SetJustifyH("RIGHT")
	row.right:SetWordWrap(false)
	row.action = Skin.SmallButton(row, "", function(self) if self.run then self.run() end end, function() return row.action.tip or "" end)
	row.action:SetPoint("RIGHT", -6, 0)
	row:SetScript("OnEnter", function(self)
		-- (the kit's hover tint)
		self.ground:SetColorTexture(1, 1, 1, 0.03 + (Skin.HOVER or 0.05))
		local data = self.data
		if data and data.tip and not data.item then Skin.ShowTip(self, data.tip, "ANCHOR_RIGHT") end
	end)
	row:SetScript("OnLeave", function(self)
		self.ground:SetColorTexture(1, 1, 1, 0.03)
		GameTooltip:Hide()
	end)
	-- (an item's row: the item itself under the mouse)
	Skin.ItemTooltip(row, function(self) return self.data and self.data.item end, "ANCHOR_RIGHT")
	row:SetScript("OnClick", function(self) if self.data and self.data.onClick then self.data.onClick() end end)
	return row
end

local function FillRow(row, data)
	row.data = data
	row.icon:Set(data.icon, data.quality)
	row.icon.texture:SetDesaturated(data.faded or false)
	row.title:SetText(data.title)
	if data.titleColor then row.title:SetTextColor(data.titleColor[1], data.titleColor[2], data.titleColor[3]) else row.title:SetTextColor(Skin.COLORS.text[1], Skin.COLORS.text[2], Skin.COLORS.text[3]) end
	row.note:SetText(data.note or "")
	row.right:SetText(data.right or "")
	row.action:SetShown(data.action ~= nil)
	if data.action then
		row.action.run, row.action.tip = data.action.run, data.action.tip
		row.action:SetLabel(data.action.label)
	end
end

local function Build(parent)
	local w = { rows = {}, switches = {} }
	w.frame = CreateFrame("Frame", nil, parent)
	w.title = Skin.Text(w.frame, "GameTooltipHeaderText", "gold")
	w.title:SetPoint("TOPLEFT", 0, -2)
	w.sub = Skin.Text(w.frame, "GameTooltipText", "soft")
	w.sub:SetPoint("TOPLEFT", w.title, "BOTTOMLEFT", 0, -4)
	w.sub:SetWidth(540)
	w.sub:SetJustifyH("LEFT")
	w.sub2 = Skin.Text(w.frame, "GameTooltipTextSmall", "muted")
	w.sub2:SetPoint("TOPLEFT", w.sub, "BOTTOMLEFT", 0, -3)
	w.bar = Skin.ProgressLine(w.frame, 4)
	w.bar:SetPoint("TOPLEFT", w.sub2, "BOTTOMLEFT", 0, -4)
	w.bar:SetWidth(300)
	w.go = Skin.SmallButton(w.frame, L.GO, function(self) if self.run then self.run() end end, L.GO_DESC)
	w.go:SetPoint("TOPRIGHT", 0, 0)
	w.search = Skin.CreateInput(w.frame, nil, 40, { hint = L.PEOPLE_SEARCH, onChange = function(input, typed)
		if not typed then return end
		query, offset = input:GetText() or "", 0
		ns.Changed()
	end })
	w.search:SetPoint("TOPRIGHT", 0, -28)
	w.search:SetWidth(260)
	w.list = CreateFrame("Frame", nil, w.frame)
	w.list:SetPoint("TOPLEFT", 0, -LIST_TOP)
	w.list:SetPoint("BOTTOMRIGHT", -Skin.SCROLL_WIDTH - 2, 0)
	w.list:EnableMouseWheel(true)
	w.list:SetScript("OnMouseWheel", function(_, delta)
		offset = offset - delta * 2
		ns.Draw()
	end)
	w.scroll = Skin.ScrollBar(w.frame, function(value)
		offset = math.floor(value + 0.5)
		ns.Draw()
	end)
	w.scroll:SetPoint("TOPLEFT", w.list, "TOPRIGHT", 2, 0)
	w.scroll:SetPoint("BOTTOMLEFT", w.list, "BOTTOMRIGHT", 2, 0)
	w.empty = Skin.Text(w.list, "GameTooltipText", "muted")
	w.empty:SetPoint("TOP", 0, -40)
	w.empty:SetWidth(520)
	return w
end

local function DrawSwitches(list)
	for index, switch in ipairs(list or EMPTY) do
		local button = widgets.switches[index]
		if not button then
			button = Skin.SmallButton(widgets.frame, "", function(self) if self.run then self.run() end end, function() return widgets.switches[index].tip or "" end)
			if index == 1 then button:SetPoint("TOPRIGHT", 0, -30) else button:SetPoint("RIGHT", widgets.switches[index - 1], "LEFT", -6, 0) end
			widgets.switches[index] = button
		end
		button.run, button.tip = switch.run, switch.tip
		button:SetLabel(Skin.Colorize(switch.label, switch.on and "gold" or "text"))
		button:Show()
	end
	for index = #(list or EMPTY) + 1, #widgets.switches do widgets.switches[index]:Hide() end
end

-- Which pages the rail shows for this profession (a page with nothing behind it is not offered).
function ns.PagesFor(line)
	local list = { "favor", "people" }
	if next(ns.PROF_CAMP or EMPTY) then list[#list + 1] = "camp" end
	if next(ns.PROF_WRITS or EMPTY) then list[#list + 1] = "writs" end
	if ns.PROF_SPECS and ns.PROF_SPECS[line] and ns.PROF_SPECS[line][1] then list[#list + 1] = "specs" end
	return list
end

function ns.PageTitle(key) return L["PAGE_" .. key:upper()] end

function ns.CurrentPage() return page end
function ns.SetPage(key)
	if key ~= page then offset, query = 0, "" end
	page = key
	if widgets and widgets.search:GetText() ~= "" then widgets.search:SetText("") end
end

-- The page in the frame given (made the first time); nil hides it.
function ns.DrawPage(parent, left, top, right, bottom)
	if not page then
		if widgets then widgets.frame:Hide() end
		return
	end
	if not widgets then
		widgets = Build(parent)
		widgets.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", left, -top)
		widgets.frame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -right, bottom)
	end
	widgets.frame:Show()
	local view = VIEWS[page]()
	widgets.title:SetText(view.title)
	widgets.sub:SetText(view.sub or "")
	widgets.sub2:SetText(view.sub2 or "")
	widgets.bar:SetShown(view.share ~= nil)
	if view.share then widgets.bar:Set(view.share) end
	widgets.go:SetShown(view.go ~= nil)
	if view.go then widgets.go.run = view.go.run end
	widgets.search:SetShown(view.search or false)
	DrawSwitches(view.switches)
	local fits = math.max(1, math.floor((parent:GetHeight() - top - bottom - LIST_TOP) / ROW_HEIGHT))
	offset = math.max(0, math.min(offset, #view.rows - fits))
	for index = 1, fits do
		local data = view.rows[offset + index]
		local row = widgets.rows[index]
		if data and not row then
			row = NewRow(widgets.list)
			row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
			row:SetPoint("TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
			widgets.rows[index] = row
		end
		if row then
			row:SetShown(data ~= nil)
			if data then FillRow(row, data) end
		end
	end
	for index = fits + 1, #widgets.rows do widgets.rows[index]:Hide() end
	widgets.scroll:Set(#view.rows, fits, offset)
	widgets.empty:SetShown(#view.rows == 0)
	widgets.empty:SetText(view.empty or "")
end
