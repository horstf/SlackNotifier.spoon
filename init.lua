--- === SlackNotifier ===
---
--- Check Slack API periodically and show your activity count in a menubar app.
--- A dot on the icon means unread, unmuted messages outside the activity count.
--- Supports multiple Slack workspaces.

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

-- fade the finished glyph in one pass so overlapping strokes stay even
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

-- draw the unread dot just outside the top right corner of the glyph
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

-- per-workspace state, keyed by index in obj.workspaces
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

-- activity_v2 keys already covered by the conversation list
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

-- labels for the remaining activity_v2 keys
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

-- forward declaration
local updateMenu

-- unread, unmuted, and not already counted as a mention
local function isQuietUnread(index, convo)
	local muted = mutedChannels[index] or {}
	return convo.unread and convo.mentions == 0 and not muted[convo.id]
end

-- called by both the counts and the mute handler, whichever lands last
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

-- open a conversation in the Slack app
local function openConversation(index, conversationId)
	local team = teams[index]
	if team and team.id then
		hs.urlevent.openURL('slack://channel?team=' .. team.id .. '&id=' .. conversationId)
	else
		hs.urlevent.openURL('https://app.slack.com/client/-/' .. conversationId)
	end
end

-- build dropdown menu items
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
				-- skip muted conversations without mentions
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

-- resolve a conversation ID to a readable name (cached)
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

-- create a handler for auth.test (team ID and name)
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

-- create a handler for users.prefs.get (mute state)
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

		-- activity_v2 matches the Activity tab badge; fall back to channel_badges
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

		-- collect unread conversations
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

		-- mentions first
		table.sort(workspaceConvos, function(a, b) return a.mentions > b.mentions end)
		convos[index] = workspaceConvos

		counts[index] = {
			activityCount = activityCount,
			unreadCount = 0,
			starredCount = starredCount,
			err = false,
		}

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

		-- look up the team once
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
---             workspaces: Array of { name, cookieToken, workspaceToken } tables
---                         (name is optional)
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
