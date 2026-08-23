# Plug

**One place to manage your community Omarchy plugins — and never apply an
update blind.**

![Plug](preview.png)

Plugins run as you, with no sandbox, so an update is just new code you have not
seen. Plug manages your installed community plugins — toggle, remove, browse and
install more — and puts a gate in front of every update: it flags when one is
waiting, and an AI reviewer of your choice reads the exact changes and tells you,
in plain English, whether it is safe to apply.

## What it does

- **Installed** — every community plugin you have, each row with the same four
  controls in the same place: **update**, **restore**, **remove** and an
  **on/off** switch, plus a trust dot from a quick capability scan. The update
  control lights **green** the moment the plugin's repository has moved past
  what you installed; restore lights up once Plug has applied an update it can
  undo. Laid out two-up to save space, with a folded **Official** section for
  Omarchy's own optional bar widgets — those show just the on/off switch,
  lined up with the community rows (a built-in is part of Omarchy, not an
  installed copy, so there is nothing to update or remove).
- **Review an update** — Plug fetches the exact changes, runs a fast offline
  scan, and hands the diff to your chosen AI reviewer (read-only). You get a
  **safe / be careful / do not** verdict, a plain-English summary of what
  changed, anything to watch for, and the author's own commit notes — then you
  decide. It also judges the update the way the marketplace's own approval
  checks do (new privileges, downloads, network hosts, background processes, or
  writes outside the plugin).
- **Restore** — undo the last update you applied, returning the plugin to the
  version it was on before. Plug then flags the update as available again, so
  nothing is lost — you can re-apply it whenever you are ready.
- **Store** — search the community marketplace and install with one click.
  Omarchy's built-in plugins appear here too, marked **OFFICIAL** and shown for
  discovery only.

## Choosing your reviewer

The reviewer is entirely your choice, set in **Settings**. Plug offers only the
tools you actually have:

- **Command-line agents** — Claude Code, Codex, or Gemini, if their command is
  installed. Plug runs them once, read-only.
- **Local servers** — Ollama or LM Studio, if they are running. The review is a
  request to `localhost`, so **nothing leaves your machine** — a real LLM review
  that is completely private. Their loaded models are listed automatically.
- **Just the offline scan** — no AI at all; Plug reports what its own capability
  scan found. Everything stays local.

Interactive apps such as ChatGPT Desktop or Grok Bot are not offered: they are
windows, not something Plug can call for a one-shot review.

However Plug talks to a command-line or local reviewer, it never handles your
login: it relies on that tool's own sign-in. If you use Claude Code, it uses the
Claude account you already set up in the terminal; Plug never sees a password or
key. If the tool is not signed in, the review falls back to the offline scan.

**Privacy.** When you review an update with a cloud agent (Claude, Codex,
Gemini), the plugin's code changes — the diff — are sent to that provider, and
only then. Choosing a local server (Ollama, LM Studio) or the offline scan keeps
everything on your machine.

## Install

```
omarchy plugin add https://github.com/weedwhitesandwine/plug.git --enable
```

Open it from the bar icon, or from a terminal:

```
omarchy-shell shell toggle io.github.weedwhitesandwine.plug
```

A hotkey is **off by default** — set one in Settings if you want. Plug checks
every shortcut Hyprland is actually using (including Omarchy's own, which are
not in `bindings.lua`) and refuses a combination that is already taken.

## Update

```
omarchy plugin update io.github.weedwhitesandwine.plug --yes
```

## Remove

Hide the bar icon and clear the hotkey in Settings first (that removes Plug's
entry from `shell.json` and its block from `bindings.lua`), then:

```
omarchy plugin remove io.github.weedwhitesandwine.plug
```

Its state is left in `~/.local/state/plug/`, which you can delete.

## What it runs, reads and writes

**Its own state**, all inside `~/.local/state/plug/`: `state.json` (git and
scan results per plugin), `catalog.json` (the marketplace catalog, cached),
`settings.json` (your choices), `locks.json` (restore bookkeeping — which
version each applied update came from).

**Outside its own directory** — only in response to something you do:

| Path | When |
|---|---|
| `~/.config/hypr/bindings.lua` | only when you set or clear a hotkey, and only Plug's own marked block, between `-- >>> plug hotkey` and `-- <<< plug hotkey` |
| `~/.config/omarchy/shell.json` | only when you show or hide the bar icon, and only Plug's own `{"id": …}` entry |
| a plugin's own checkout under `~/.config/omarchy/plugins/…` | standard git operations (`fetch`, fast-forward, and `reset` for a revert) when you update or roll back **that** plugin |

**Commands it runs:** `omarchy-shell shell listPlugins` / `listShellConfig` /
`setPluginEnabled` (read the list and your shell config; enable/disable on your
click); `omarchy-restart-shell` (only after you apply an update or a restore —
see below — and never while the screen is locked) with `omarchy-shell shell
ping` / `summon` to bring Plug back afterwards with the result;
`omarchy plugin add` / `remove` (install/uninstall on your click); `git` inside each plugin's checkout (read its
state, fetch updates, show the diff, apply or revert); `hyprctl binds` (read
active shortcuts) and `hyprctl reload` (after a hotkey change); `python3` (Plug's
own engine); `bash` (Plug's own `plug-ctl.sh`); and the AI reviewer you chose —
either its command (`claude` / `codex` / `gemini`) or a request to a local
server on `localhost`.

**Network:** each installed plugin's git remote, to check for and fetch updates;
the marketplace catalog on `raw.githubusercontent.com`; and, when you review an
update with a cloud agent, that provider — never otherwise. A local-server
reviewer stays on `localhost`.

**Restarting the shell.** New plugin code sits unused until the shell restarts:
the running shell keeps the copy it loaded at startup, and asking it to rescan
its plugins only refreshes which plugins exist, not their code. So applying an
update or a restore ends with a shell restart — otherwise you would be told the
update was applied while the old version carried on running, which is exactly
the trap Plug exists to close. Your windows and workspaces are untouched; the
bar and the panels reload. Nothing else Plug does restarts anything.

**Timers and background work:** none that runs on its own. The jobs you start —
install, remove, update, restore, on/off — do outlive Plug's own window,
because the reload that finishes them also closes it; each one ends by
reopening Plug on the plugin it acted on and telling you what happened.

Everything runs as your own user.

## Handling untrusted input

A plugin's repository, the marketplace catalog and the update diff all come from
outside, and Plug runs inside a shell process that stays up for days, so all of
it is treated as data:

- Every file Plug reads is read to a size ceiling, following a symlink only to a
  real regular file, so an oversized or redirected file cannot be pulled whole
  into the shell or hang it.
- Every file Plug writes is staged under an exclusively-created name in a
  directory it has verified it owns, then renamed into place, so a symlink left
  at one of those names is never written through.
- A hotkey is validated against a fixed shape in both the settings view and the
  helper script, and refused rather than escaped, because it becomes Lua source
  in `bindings.lua`.
- The AI reviewer is run **structurally read-only** — no tools, in an empty
  working directory — so a prompt-injection hidden in an update's diff has
  nothing to act on. The diff is data it reads, never instructions it follows.
- `git` runs against each untrusted checkout with the repository's own hooks and
  config disabled, so inspecting a plugin can never run code from it.

## Dependencies

`git`, `python3`, `bash` and `hyprctl`, all of which Omarchy already provides.
An AI reviewer is optional — without one, Plug uses its offline scan.

## Licence

MIT — see [LICENSE](LICENSE).

## Credits

Built with [Claude Code](https://claude.com/claude-code).
