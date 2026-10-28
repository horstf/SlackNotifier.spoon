# SlackNotifier

A Hammerspoon menu bar app that shows your Slack activity count (the same
number as Slack's Activity badge). A dot on the icon means there are other
unread messages. The dropdown lists unread conversations, and clicking one
opens it in Slack. Works with multiple workspaces.

![screenshot](screenshot.png)

## Setup

Clone this repo into `~/.hammerspoon/Spoons/`, then add to your Hammerspoon
config:

```lua
hs.loadSpoon('SlackNotifier')
spoon.SlackNotifier:start({
  interval = 60, -- optional, seconds
  workspaces = {
    { cookieToken = 'xoxd-xxxx', workspaceToken = 'xoxc-xxxx' },
  },
})
```

Get both tokens from Chrome devtools while you're logged in at app.slack.com:

- `cookieToken`: Application > Cookies > `https://app.slack.com`, the value of
  `d` (starts with `xoxd-`). If it contains `%..` sequences, URL-decode it.
- `workspaceToken`: Network tab, reload, pick a `POST` to `slack.com/api/`, and
  copy `token` from the payload (starts with `xoxc-`).
