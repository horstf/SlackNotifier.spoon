# Hammerspoon Slack notifier

Check the Slack API periodically and show your unread activity count in a
menubar app.

The number is Slack's own Activity total — the `activity_v2` figure behind the
Activity tab badge — so it counts direct messages, mentions, thread replies,
reactions, reminders and invites, and it matches what Slack itself shows. It is
always displayed, including as a zero, with the icon dimmed when there is
nothing unread, so a quiet menu bar never looks the same as a crashed spoon.

A dot on the top right of the icon means there are unread messages that Slack
does not badge, so they never reach the activity count: ordinary channel
traffic. A dotted icon with no number therefore reads as "nothing needs you,
but there is unread reading". No dot and no number means genuinely nothing
unread, and the icon dims as well.

Muted conversations are left out of the dot, since Slack hides them from the
sidebar on purpose and counting them would report unread that Slack is
deliberately not showing you. A mention in a muted channel still badges in
Slack, so those still count towards the activity number and still appear in the
dropdown. Mute state is not a property of a conversation — it lives in your
account preferences, as a JSON blob under `all_notifications_prefs` — so it is
fetched from `users.prefs.get` alongside the counts.

The dropdown lists each unread conversation by name (the person for a DM,
`#channel` for a channel), with a mention count where there is one — rows with
no mention count are the ones the dot is telling you about. Clicking a row
opens that conversation in the Slack app via a `slack://` deep link. Activity
with no conversation to open — reactions, reminders, invites — is listed below
as a labelled count.

![screenshot](https://zthings.files.wordpress.com/2020/02/screen-shot-2020-02-09-at-11.17.33-pm.png)

## Loading the spoon

Clone this repo in `~/.hammerspoon/Spoons/`. (After doing so, the path to this
readme should be `~/.hammerspoon/Spoons/SlackNotifier.spoon/readme.md`.

Now load the spoon from your Hammerspoon config:

```lua
hs.loadSpoon('SlackNotifier')
spoon.SlackNotifier:start({
  workspaces = {
    {
      cookieToken = "xoxd-xxxx",
      workspaceToken = "xoxc-xxxx",
    },
    {
      cookieToken = "xoxd-yyyy",
      workspaceToken = "xoxc-yyyy",
    },
  },
})
```

A single workspace can also be configured with the flat form:

```lua
spoon.SlackNotifier:start({
  cookieToken = "xoxd-xxxx",
  workspaceToken = "xoxc-xxxx",
})
```

# Configuration

- `interval`: Interval in seconds to refresh the menu (default 60)
- `workspaces`: Array of workspace tables, each containing `cookieToken` and `workspaceToken` (see below)

For each workspace, you will need two tokens:

- `cookieToken`: Token found in your cookies when authenticated against your Slack workspace in the browser
  - Using Chrome devtools, go to Application > Cookies > https://app.slack.com
  - Copy the value for `d`. It should start with `xoxd-`.
  - If it contains URL-encoded characters (`%..`), you will need to URL-decode it: `copy( encodeURIComponent( 'token' ) )`.
- `workspaceToken`: Token found in request payload when authenticated against your Slack workspace in the browser
  - Using Chrome devtools, go to Network, reload the page, and filter for `slack.com/api/`, select a `POST` request, and click the Payload tab.
  - Look for `token` in the payload. It should start with `xoxc-`.

Counts from all workspaces are aggregated into a single menubar display. Rows
in the dropdown are only prefixed with the workspace name when more than one
workspace is configured. `name` is optional — it defaults to the workspace name
Slack reports from `auth.test`, which is also where the team ID for deep links
comes from.

## Debugging

`SlackNotifier:refresh()` fetches immediately, and the dropdown has a "Refresh
now" item that does the same. The last raw `client.counts` payload for each
workspace is kept in `spoon.SlackNotifier.lastPayloads`, so if a count ever
looks wrong you can inspect what Slack actually returned:

```lua
hs.inspect(spoon.SlackNotifier.lastPayloads[1].activity_v2)
```
