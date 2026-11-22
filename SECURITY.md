# Security policy

Tally reads the login tokens your AI coding tools already keep on your Mac (the Claude Code Keychain entry, `~/.codex/auth.json`, the OpenCode Go API key) to fetch your own usage from each provider. Bugs in how it handles them matter, so please report them privately.

## Reporting a vulnerability

Use **[Report a vulnerability](https://github.com/PratikRai0101/tally/security/advisories/new)** on GitHub. Please don't open a public issue for security problems.

Include what you found, how to reproduce it, and your Tally version (`npx tally-menubar version` prints it). You'll get a reply within a few days, and a fix or a plan soon after. With your permission, you'll be credited in the release notes.

## What's in scope

- Tally sending a credential anywhere other than its own provider, or writing one to disk, logs or a share card
- Ways for another app or user to read data through Tally, or to make Tally run code (for example through the [before-cutoff hook](README.md#before-cutoff-hook))
- The `tally-menubar` npm installer: downloading, verifying (SHA-256) and installing the app

## Supported versions

Only the latest release gets fixes. Update with `npx tally-menubar@latest update`.
