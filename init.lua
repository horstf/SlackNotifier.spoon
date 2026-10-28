--- === SlackNotifier ===
---
--- Check Slack API periodically and show your unread activity count in a
--- menubar app. The count is Slack's own Activity total (the `activity_v2`
--- figure behind the Activity tab badge): direct messages, mentions, thread
--- replies, reactions, reminders and invites. A number appears only when there
--- is something to report; otherwise the icon simply dims. It always stays in
--- the menu bar, so a quiet menu bar never looks like a crashed spoon.
---
--- A dot on the top right of the icon means there are unread messages that
--- Slack does not badge, so they are not in the activity count: ordinary
--- channel traffic. Muted conversations are excluded, since Slack hides those
--- from the sidebar on purpose. A dotted icon with no number therefore reads
--- as "nothing needs you, but there is unread reading".
---
--- The dropdown lists each unread conversation by name; clicking one opens it
--- in the Slack app. Supports multiple Slack workspaces.

-- luacheck: globals hs

local obj = {}

-- Metadata
obj.name = 'SlackNotifier'
obj.version = '1.0'
obj.author = 'Chris Zarate <chris@zarate.org>'
obj.homepage = 'https://github.com/chriszarate/SlackNotifier.spoon'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

-- create the icon
-- http://xqt2.com/asciiIcons.html
local iconAscii = [[ASCII:
............
....AD......
.........PQ.
.F..........
.I..........
...........G
...........H
K...........
N...........
..........L.
..........M.
.BC.........
......SR....
............
]]

local activeIcon = hs.image.imageFromASCII(iconAscii)

-- Asking imageFromASCII for a half-alpha fill and stroke draws every shape at
-- half opacity, so wherever the strokes overlap the translucent layers
-- accumulate and the glyph comes out mottled rather than evenly faded. Fading
-- the finished solid glyph in a single pass keeps the interior flat.
local function withAlpha(base, alpha)
	local size = base:size()
	local c = hs.canvas.new({ x = 0, y = 0, w = size.w, h = size.h })
	c[1] = {
		type = 'image',
		image = base,
		frame = { x = 0, y = 0, w = size.w, h = size.h },
		imageAlpha = alpha,
	}
	local img = c:imageFromCanvas()
	c:delete()
	return img
end

local dimmedIcon = withAlpha(activeIcon, 0.5)

-- The Slack glyph fills its own 12x14 box, so the unread badge goes on a wider
-- canvas just outside the top right corner rather than on top of the logo.
local function iconWithDot(base)
	local c = hs.canvas.new({ x = 0, y = 0, w = 18, h = 14 })
	c[1] = {
		type = 'image',
		image = base,
		frame = { x = 0, y = 0, w = 12, h = 14 },
	}
	c[2] = {
		type = 'circle',
		center = { x = 15, y = 3 },
		radius = 3,
		action = 'fill',
		fillColor = { white = 0 },
	}
	local img = c:imageFromCanvas()
	c:delete()
	return img
end

local activeDotIcon = iconWithDot(activeIcon)

-- category icons for dropdown menu
local function createCanvasIcon(drawFn)
	local size = 12
	local c = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
	drawFn(c, size)
	local img = c:imageFromCanvas()
	c:delete()
	return img:template(true)
end

local dmIcon = createCanvasIcon(function(c, s)
	c[1] = {
		type = 'segments',
		closed = true,
		coordinates = {
			{ x = 1, y = 2 },
			{ x = s - 1, y = 2 },
			{ x = s - 1, y = s - 3 },
			{ x = 5, y = s - 3 },
			{ x = 3, y = s },
			{ x = 3, y = s - 3 },
			{ x = 1, y = s - 3 },
		},
		action = 'fill',
		fillColor = { white = 0 },
	}
end)

local starredIcon = createCanvasIcon(function(c, s)
	local cx, cy, r = s / 2, s / 2, s / 2 - 1
	local ir = r * 0.38
	local coords = {}
	for i = 0, 4 do
		local oa = math.rad(-90 + i * 72)
		table.insert(coords, { x = cx + r * math.cos(oa), y = cy + r * math.sin(oa) })
		local ia = math.rad(-90 + i * 72 + 36)
		table.insert(coords, { x = cx + ir * math.cos(ia), y = cy + ir * math.sin(ia) })
	end
	c[1] = {
		type = 'segments',
		closed = true,
		coordinates = coords,
		action = 'fill',
		fillColor = { white = 0 },
	}
end)

local activityMenuIcon = createCanvasIcon(function(c, s)
	c[1] = {
		type = 'oval',
		frame = { x = 2, y = 2, w = s - 4, h = s - 4 },
		action = 'fill',
		fillColor = { white = 0 },
	}
end)

local channelIcon = createCanvasIcon(function(c, s)
	c[1] = {
		type = 'text',
		text = '#',
		textSize = s,
		textColor = { white = 0 },
		textAlignment = 'center',
		frame = { x = 0, y = -1, w = s, h = s + 2 },
	}
end)

-- per-workspace state, keyed by the workspace's index in obj.workspaces
--   counts[i]   = { activityCount, unreadCount, starredCount, err }
--   convos[i]   = array of { id, mentions, starred, isIm } for unread conversations
--   extras[i]   = array of { label, count } for activity with no conversation
--   teams[i]    = { id = 'T...', name = 'Acme' }, from auth.test
--   names[i]    = { [conversationId] = 'display name' } resolution cache
local counts = {}
local convos = {}
local extras = {}
local teams = {}
local names = {}

-- per-workspace starred channel IDs: { [index] = { [channelId] = true } }
local starredChannels = {}

-- per-workspace muted conversation IDs: { [index] = { [channelId] = true } }
local mutedChannels = {}

-- last raw client.counts payload per workspace, for debugging
obj.lastPayloads = {}

-- activity_v2 keys that are already covered by the unread conversation list,
-- so we do not report them twice
local conversationBacked = {
	dm = true,
	channel = true,
	at_user = true,
	at_channel = true,
	at_everyone = true,
	at_user_group = true,
	keyword = true,
	bot_dm_bundle = true,
}

-- readable labels for the remaining activity_v2 keys. Each pluralizes with a
-- trailing 's', so keep them noun-shaped.
local activityLabels = {
	message_reaction = 'Reaction',
	saved_reminder = 'Reminder',
	thread_v2 = 'Thread reply',
	external_channel_invite = 'Channel invite',
	internal_channel_invite = 'Channel invite',
	external_dm_invite = 'DM invite',
	shared_workspace_invite = 'Workspace invite',
	team_joiner_invite = 'Team invite',
	quietly_added_to_channel = 'Channel add',
	unjoined_channel_mention = 'Unjoined channel mention',
	list_approval_request = 'List approval request',
	list_approval_reviewed = 'List approval review',
	list_record_assigned = 'List record assignment',
	list_record_edited = 'List record edit',
	list_todo_notification = 'List to-do',
	list_user_mentioned = 'List mention',
	prejoin_dm_welcome_party_alert = 'Welcome party',
}

local function pluralize(count, label)
	if count == 1 then
		return label
	end
	return label .. 's'
end

-- forward declaration: recomputeUnread needs updateMenu, and the mute handler
-- needs recomputeUnread
local updateMenu

-- A conversation earns the dot only if it has unread messages, carries no
-- mention (mentions are already in the activity count) and is not muted. Slack
-- hides muted channels from the sidebar and does not badge them, so counting
-- them here would report unread that Slack itself is deliberately hiding.
local function isQuietUnread(index, convo)
	local muted = mutedChannels[index] or {}
	return convo.unread and convo.mentions == 0 and not muted[convo.id]
end

-- The mute list and the counts arrive from separate requests, so the dot count
-- is derived rather than computed in place: whichever lands last recomputes it.
local function recomputeUnread()
	for index, c in pairs(counts) do
		if not c.err then
			local quiet = 0
			for _, convo in ipairs(convos[index] or {}) do
				if isQuietUnread(index, convo) then
					quiet = quiet + 1
				end
			end
			c.unreadCount = quiet
		end
	end

	updateMenu()
end

-- aggregate counts across all workspaces and update the menu bar
function updateMenu()
	local totalActivity = 0
	local totalUnread = 0
	local allErr = true

	for _, c in pairs(counts) do
		if not c.err then
			allErr = false
			totalActivity = totalActivity + c.activityCount
			totalUnread = totalUnread + c.unreadCount
		end
	end

	obj.menu:returnToMenuBar()

	if allErr then
		obj.menu:setIcon(dimmedIcon, true):setTitle('?')
		return
	end

	-- A number is only shown when there is activity to report; the empty state
	-- is a dimmed icon with no title rather than a zero. The dot says there are
	-- unread messages the activity count does not cover, so a bare dotted icon
	-- means "nothing needs you, but there is unread reading".
	local icon = dimmedIcon
	if totalUnread > 0 then
		icon = activeDotIcon
	elseif totalActivity > 0 then
		icon = activeIcon
	end

	local title = ''
	if totalActivity > 0 then
		title = tostring(totalActivity)
	end

	obj.menu:setIcon(icon, true):setTitle(title)
end

-- open a conversation in the Slack app. Falls back to the workspace's web URL
-- if we never learned the team ID.
local function openConversation(index, conversationId)
	local team = teams[index]
	if team and team.id then
		hs.urlevent.openURL('slack://channel?team=' .. team.id .. '&id=' .. conversationId)
	else
		hs.urlevent.openURL('https://app.slack.com/client/-/' .. conversationId)
	end
end

-- build dropdown menu items: unread conversations first, then activity that has
-- no conversation to open, then a per-workspace footer
local function buildMenu()
	local items = {}
	local multi = #obj.workspaces > 1

	-- prefix rows with the workspace name only when there is more than one
	local function prefix(index)
		if not multi then
			return ''
		end
		local team = teams[index]
		local name = obj.workspaces[index].name or (team and team.name) or ('Workspace ' .. index)
		return name .. '  ·  '
	end

	local convoItems = {}
	local extraItems = {}

	for i in ipairs(obj.workspaces) do
		local c = counts[i]

		if c and c.err then
			table.insert(extraItems, {
				title = prefix(i) .. 'Error: ' .. tostring(c.errMessage or 'unknown'),
				disabled = true,
			})
		elseif c then
			local muted = mutedChannels[i] or {}

			for _, convo in ipairs(convos[i] or {}) do
				-- a muted conversation with no mention is one Slack is
				-- deliberately hiding, so keep it out of the list too
				if not (muted[convo.id] and convo.mentions == 0) then
					local name = names[i] and names[i][convo.id]
					local label = name or (convo.isIm and 'Direct message' or 'Channel')
					local suffix = ''
					if convo.mentions > 0 then
						suffix = '  (' .. convo.mentions .. ' ' ..
							pluralize(convo.mentions, 'mention') .. ')'
					end

					local icon = dmIcon
					if convo.starred then
						icon = starredIcon
					elseif not convo.isIm then
						icon = channelIcon
					end

					table.insert(convoItems, {
						title = prefix(i) .. label .. suffix,
						image = icon,
						fn = function()
							openConversation(i, convo.id)
						end,
					})
				end
			end

			for _, extra in ipairs(extras[i] or {}) do
				table.insert(extraItems, {
					title = prefix(i) .. extra.count .. '  ' .. pluralize(extra.count, extra.label),
					image = activityMenuIcon,
					disabled = true,
				})
			end
		end
	end

	if #convoItems == 0 and #extraItems == 0 then
		table.insert(items, { title = 'No unread activity', disabled = true })
	end

	for _, section in ipairs({ convoItems, extraItems }) do
		if #section > 0 then
			if #items > 0 then
				table.insert(items, { title = '-' })
			end
			for _, item in ipairs(section) do
				table.insert(items, item)
			end
		end
	end

	table.insert(items, { title = '-' })
	table.insert(items, { title = 'Refresh now', fn = function() obj:refresh() end })

	for i in ipairs(obj.workspaces) do
		local team = teams[i]
		if team and team.id then
			local name = obj.workspaces[i].name or team.name or ('Workspace ' .. i)
			table.insert(items, {
				title = 'Open ' .. name,
				fn = function()
					hs.urlevent.openURL('slack://open?team=' .. team.id)
				end,
			})
		end
	end

	return items
end

-- resolve a conversation ID to something a human can read, then refresh the
-- menu. Results are cached, so each conversation costs at most two calls once.
local function resolveName(index, conversationId, headers, token)
	names[index] = names[index] or {}
	if names[index][conversationId] then
		return
	end

	-- mark as in flight so a slow lookup is not started twice
	names[index][conversationId] = false

	local infoData = 'token=' .. token .. '&channel=' .. conversationId
	hs.http.asyncPost('https://slack.com/api/conversations.info', infoData, headers, function(status, body)
		if status < 0 then
			names[index][conversationId] = nil
			return
		end

		local json = hs.json.decode(body)
		if not json or not json.ok or not json.channel then
			names[index][conversationId] = nil
			return
		end

		local channel = json.channel

		if channel.name then
			names[index][conversationId] = '#' .. channel.name
			updateMenu()
			return
		end

		if not channel.user then
			names[index][conversationId] = nil
			return
		end

		-- a DM: resolve the other person's name
		local userData = 'token=' .. token .. '&user=' .. channel.user
		hs.http.asyncPost('https://slack.com/api/users.info', userData, headers, function(userStatus, userBody)
			if userStatus < 0 then
				names[index][conversationId] = nil
				return
			end

			local userJson = hs.json.decode(userBody)
			if not userJson or not userJson.ok or not userJson.user then
				names[index][conversationId] = nil
				return
			end

			local user = userJson.user
			local display = user.profile and user.profile.display_name
			if display == '' then
				display = nil
			end

			names[index][conversationId] = display or user.real_name or user.name or nil
			updateMenu()
		end)
	end)
end

-- create a handler for auth.test, which gives us the team ID needed for deep
-- links and a workspace name we can use if none was configured
local function makeTeamHandler(index)
	return function(status, body)
		if status < 0 then
			return
		end

		local json = hs.json.decode(body)
		if not json or not json.ok then
			return
		end

		teams[index] = { id = json.team_id, name = json.team }
	end
end

-- create a handler for users.prefs.get, which is where per-channel mute state
-- lives. It arrives as a JSON string inside the prefs blob rather than as
-- fields on the conversations themselves.
local function makeMutedHandler(index)
	return function(status, body)
		if status < 0 then
			return
		end

		local json = hs.json.decode(body)
		if not json or not json.ok or not json.prefs then
			return
		end

		local raw = json.prefs.all_notifications_prefs
		if type(raw) ~= 'string' then
			return
		end

		local decoded = hs.json.decode(raw)
		if not decoded or not decoded.channels then
			return
		end

		local muted = {}
		local now = os.time()
		for id, prefs in pairs(decoded.channels) do
			if prefs.muted == true or (prefs.temp_mute_expiration_ts or 0) > now then
				muted[id] = true
			end
		end

		mutedChannels[index] = muted
		recomputeUnread()
	end
end

-- create a handler for stars.list response for a specific workspace index
local function makeStarredHandler(index)
	return function(status, body)
		if status < 0 then
			return
		end

		local json = hs.json.decode(body)

		if not json.ok then
			return
		end

		local starred = {}
		for _, item in ipairs(json.items) do
			if item.type == 'channel' then
				starred[item.channel] = true
			end
		end

		starredChannels[index] = starred
	end
end

-- create a response handler for a specific workspace index
local function makeResponseHandler(index, headers, token)
	return function(status, body)
		if status < 0 then
			return
		end

		-- parse json response
		local json = hs.json.decode(body)

		-- keep the raw payload around for debugging
		obj.lastPayloads[index] = json

		if not json.ok then
			counts[index] = {
				activityCount = 0,
				unreadCount = 0,
				starredCount = 0,
				err = true,
				errMessage = json.error,
			}
			print('SlackNotifier: workspace ' .. index .. ' error: ' .. tostring(json.error))
			updateMenu()
			return
		end

		-- the activity count is Slack's own Activity total. activity_v2 is the
		-- figure behind the Activity tab badge; fall back to the older
		-- channel_badges sum if a workspace does not return it.
		local activityCount = 0
		local workspaceExtras = {}

		if json.activity_v2 then
			for key, count in pairs(json.activity_v2) do
				activityCount = activityCount + count
				if count > 0 and not conversationBacked[key] then
					table.insert(workspaceExtras, { label = activityLabels[key] or key, count = count })
				end
			end
		else
			for _, count in pairs(json.channel_badges or {}) do
				activityCount = activityCount + count
			end
			if json.saved then
				activityCount = activityCount + (json.saved.uncompleted_overdue_count or 0)
			end
		end

		table.sort(workspaceExtras, function(a, b) return a.label < b.label end)
		extras[index] = workspaceExtras

		-- collect unread conversations, and count starred channels among them
		local starred = starredChannels[index] or {}
		local workspaceConvos = {}
		local starredCount = 0

		for _, kind in ipairs({ 'ims', 'mpims', 'channels' }) do
			for _, channel in ipairs(json[kind] or {}) do
				local mentions = channel.mention_count or 0
				if channel.has_unreads or mentions > 0 then
					local isStarred = starred[channel.id] == true
					if isStarred then
						starredCount = starredCount + 1
					end
					table.insert(workspaceConvos, {
						id = channel.id,
						mentions = mentions,
						unread = channel.has_unreads == true,
						starred = isStarred,
						isIm = kind ~= 'channels',
					})
					resolveName(index, channel.id, headers, token)
				end
			end
		end

		-- mentions first, then whatever order Slack gave us
		table.sort(workspaceConvos, function(a, b) return a.mentions > b.mentions end)
		convos[index] = workspaceConvos

		counts[index] = {
			activityCount = activityCount,
			unreadCount = 0,
			starredCount = starredCount,
			err = false,
		}

		-- recomputeUnread fills in unreadCount from the mute list, then
		-- refreshes the menu bar
		recomputeUnread()
	end
end

-- fetch all workspaces
local function onInterval()
	local countsUrl = 'https://slack.com/api/client.counts'
	local starsUrl = 'https://slack.com/api/stars.list'
	local prefsUrl = 'https://slack.com/api/users.prefs.get'
	local authUrl = 'https://slack.com/api/auth.test'

	for i, workspace in ipairs(obj.workspaces) do
		local data = 'token=' .. workspace.workspaceToken
		local headers = {
			Cookie = 'd=' .. hs.http.encodeForQuery(workspace.cookieToken)
		}

		-- the team ID never changes, so look it up once per workspace
		if not teams[i] then
			hs.http.asyncPost(authUrl, data, headers, makeTeamHandler(i))
		end

		hs.http.asyncPost(prefsUrl, data, headers, makeMutedHandler(i))
		hs.http.asyncPost(starsUrl, data, headers, makeStarredHandler(i))
		hs.http.asyncPost(countsUrl, data, headers,
			makeResponseHandler(i, headers, workspace.workspaceToken))
	end
end

--- SlackNotifier:refresh()
--- Method
--- Fetch counts for every workspace immediately
---
--- Parameters: none
---
--- Returns:
---  * self (allow chaining)
function obj:refresh()
	onInterval()
	return self
end

--- SlackNotifier:start(config)
--- Method
--- Start the spoon
---
--- Parameters:
---  * config - A table containing config values:
---             interval:   Interval in seconds to refresh the menu (default 60)
---             workspaces: Array of { name, cookieToken, workspaceToken } tables.
---                         name is optional; it only labels rows when more than
---                         one workspace is configured, and defaults to the
---                         workspace name Slack reports.
---
---             For a single workspace, name, cookieToken, and workspaceToken
---             can be provided directly on the config table instead.
---
--- Returns:
---  * self (allow chaining)
function obj:start(config)
	local interval = config.interval or 60

	-- support both flat (single workspace) and array (multi-workspace) configs
	if config.workspaces then
		self.workspaces = config.workspaces
	else
		self.workspaces = {
			{ name = config.name, cookieToken = config.cookieToken, workspaceToken = config.workspaceToken }
		}
	end

	-- initialize per-workspace state
	counts = {}
	convos = {}
	extras = {}
	names = {}
	for i = 1, #self.workspaces do
		counts[i] = { activityCount = 0, unreadCount = 0, starredCount = 0, err = false }
		convos[i] = {}
		extras[i] = {}
		names[i] = {}
	end

	-- create menubar (or restore it)
	if self.menu then
		self.menu:returnToMenuBar()
	else
		self.menu = hs.menubar.new():setMenu(buildMenu)
	end

	updateMenu()

	-- set timer to fetch periodically
	self.timer = hs.timer.new(interval, onInterval)
	self.timer:start()

	-- fetch immediately, too
	onInterval()

	return self
end

--- SlackNotifier:stop()
--- Method
--- Stop the spoon
---
--- Parameters: none
---
--- Returns:
---  * self (allow chaining)
function obj:stop()
	if self.menu then
		self.menu:removeFromMenuBar()
	end

	if self.timer then
		self.timer:stop()
	end

	return self
end

return obj
