local _, ns = ...
local L = ns.L

-- Who in the guild can make this: optional and off unless you ask for it. A question leaves only from your click,
-- and only members who switched this on themselves answer (an addon message to you, nothing in any chat).

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local PREFIX = "WProf1"
local ASK_EVERY = 10 -- seconds between two questions
local MOST_WAIT = 2 -- seconds at most before an answer (not everyone at once)

local answers, lastAsk = {}, 0

function ns.GuildAnswers(spell) return answers[spell] or {} end

function ns.GuildAsk(spell)
	if not (ns.Settings().guild and C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
	if not Clean(Safe(IsInGuild)) then
		W.Print(L.GUILD_NONE)
		return false
	end
	if time() - lastAsk < ASK_EVERY then return false end
	lastAsk = time()
	answers[spell] = {}
	Safe(C_ChatInfo.SendAddonMessage, PREFIX, "?" .. spell, "GUILD")
	return true
end

local function Knows(spell)
	local line = ns.LineOf(spell)
	local book = line and ns.DB().seen[line]
	local row = book and book.recipes[spell]
	return row and row.l and true or false
end

function ns.OnGuildMessage(prefix, text, channel, sender)
	if Clean(prefix) ~= PREFIX or not ns.Settings().guild then return end
	text, sender, channel = Clean(text), Clean(sender), Clean(channel)
	if type(text) ~= "string" or type(sender) ~= "string" then return end
	local kind, number = text:match("^([?!])(%d+)$")
	local spell = tonumber(number)
	-- (a question comes from the guild, an answer to you alone: anything else is not one of ours)
	if not spell or channel ~= (kind == "?" and "GUILD" or "WHISPER") then return end
	local short = Ambiguate and Ambiguate(sender, "short") or sender
	if kind == "!" then
		answers[spell] = answers[spell] or {}
		answers[spell][short] = true
		return ns.Changed()
	end
	if short == Clean(Safe(UnitName, "player")) or not Knows(spell) then return end
	C_Timer.After(math.random() * MOST_WAIT, function()
		Safe(C_ChatInfo.SendAddonMessage, PREFIX, "!" .. spell, "WHISPER", sender)
	end)
end

function ns.InitGuild()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then Safe(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX) end
end
