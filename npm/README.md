# tally-menubar

## Your AI coding Wrapped

```sh
npx tally-menubar wrapped
```

Reads the session logs Claude Code, Codex, Pi and OpenCode already keep on your computer, prices them at API rates, and opens a Wrapped-style deck in your browser: six 1080×1920 story slides and a 1200×630 card for X. Pick 24 hours, 7 days or 30 days, set which plans you pay for, then copy, download or post. Works on macOS, Linux and Windows.

Nothing is uploaded and no project names are shown. The only network request is LiteLLM's public model price table, cached for a week. Your plan is read from `~/.claude.json` and `~/.codex/auth.json` (never the Keychain), and you can change it on the page.

Options: `--period=24h|7d|30d` picks the range it opens on (default 30d); `--no-open` prints the file path instead of opening a browser.

## The menu bar app (macOS)

Installs [Tally](https://github.com/PratikRai0101/tally), a macOS menu bar app that shows how much of each AI coding plan (Claude, Codex, OpenCode Go) you have left, when it resets, and what your usage would cost at API prices.

```sh
npx tally-menubar
```

That downloads the Tally release from GitHub, checks it against the SHA-256 shipped in this package, installs it to `~/Applications` and opens it. Requires macOS 14 or later and Node 18 or later.

| Command | What it does |
|---|---|
| `npx tally-menubar wrapped` | Your AI coding Wrapped (any OS) |
| `npx tally-menubar` | Install Tally and open it |
| `npx tally-menubar@latest update` | Update to the newest version |
| `npx tally-menubar usage` | Print spend, tokens and limits in the terminal |
| `npx tally-menubar uninstall` | Remove Tally (`--purge` also removes its settings) |
| `npx tally-menubar version` | Show the package and installed versions |

Options: `--no-open` skips launching after install, `--force` reinstalls.

The deck's font is Newsreader by Production Type, under the SIL Open Font License (`wrapped/OFL-Newsreader.txt`).

If Tally is already in `/Applications`, it is updated there. Set `TALLY_INSTALL_DIR` to install somewhere else.

## Why use this instead of the .zip

Tally isn't signed with an Apple Developer ID yet, so a copy downloaded in a browser is blocked with "Apple could not verify Tally". Files downloaded by Node aren't flagged by macOS that way, so this install opens normally. The checksum check makes sure you get exactly the published release.

After an update, macOS may ask once more to let Tally read your Claude login from the Keychain. Choose **Always Allow**.

## Releasing (maintainers)

```sh
npm run pin -- v1.4        # writes release.json from the GitHub release
# set "version" in package.json to 1.4.0
npm publish
```

MIT licence.
