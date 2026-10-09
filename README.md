# cc-meter

A live terminal dashboard for your Claude Code usage across all sessions on the machine.

- **Rate limits:** 5-hour and weekly usage, when each resets, how fast you're using them, and a forecast of whether you'll hit the limit before the reset. Once a limit is used up, it shows the time it was hit.
- **Throughput:** tokens per second, latency, and output tokens, as charts over a selectable time window.
- **Today:** requests, tokens, and the share of input served from the prompt cache.
- **Breakdown:** usage per model, project, and live session.
- **Claude status:** incidents and component health from status.claude.com.

It's a single Python 3 file and needs nothing outside the standard library.

## Install

```sh
git clone https://github.com/palo-kunovsky/cc-meter.git
cd cc-meter
./cc-meter            # live dashboard
./cc-meter --once     # print one frame and exit
```

Optionally, link it onto your PATH: `ln -s "$PWD/cc-meter" /usr/local/bin/cc-meter`.

## Rate limits from the status line (recommended)

cc-meter reads rate limits from the Claude Code status line, so it doesn't spend calls on the rate-limited usage API. `statusline-command.sh` is a complete status line that does this. It writes `rate_limits` to `~/.cache/cc-meter/statusline.json` on every render. It needs `jq`.

```sh
cp statusline-command.sh ~/.claude/statusline-command.sh
```

```json
// ~/.claude/settings.json
"statusLine": { "type": "command", "command": "bash \"$HOME/.claude/statusline-command.sh\"" }
```

If you already have your own status line, copy only the `cc_meter_dir` block from the top of the script into it.

When no session has rendered a status line for 60 s, cc-meter falls back to the usage API. It authenticates with the Claude Code OAuth token from the macOS Keychain, or from `~/.claude/.credentials.json`.

## Keys

| Key | Action |
| --- | --- |
| `q` | quit |
| `↑ ↓` `j k` PgUp PgDn `g G` / wheel | scroll |
| `w` | cycle the chart window (1–24 h) |
| `r` | re-read transcripts now |
| `u` | fetch limits from the usage API now |
| `h` `?` | help: what every number means |

## Options

```
-i, --interval N        transcript refresh, seconds (default 5)
-u, --usage-interval N  poll the usage API when status-line data is older than this (default 60)
-w, --window N          throughput window, hours (default 2)
--once                  print one frame and exit
```

## Data & privacy

Everything is read locally from `~/.claude` (transcripts, sessions, account). State is kept in `~/.cache/cc-meter`. The only network calls are the Anthropic usage endpoint (the fallback) and the public status.claude.com API.

macOS is the primary target. On other systems, the Keychain lookup falls back to the credentials file.
