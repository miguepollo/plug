#!/bin/bash
# Plug settings helper. Runs ONLY when the user applies a choice in Plug's
# settings view — never on its own.
#
#   plug-ctl.sh bind "SUPER + P"   manage Plug's hotkey as a marked block in
#                                  ~/.config/hypr/bindings.lua (replaces only
#                                  its own block, never other lines)
#   plug-ctl.sh unbind             remove that block
#   plug-ctl.sh bar on|off [sec]   add/remove the Plug icon in the bar layout
#                                  (~/.config/omarchy/shell.json)
#
# It is also the detached runner for the jobs that cannot run inside the panel:
#
#   plug-ctl.sh remove <id>        uninstall a plugin
#   plug-ctl.sh apply <id>         apply the reviewed update
#   plug-ctl.sh rollback <id>      restore the version before the last update
#   plug-ctl.sh install <url> <nm> install from the store
#   plug-ctl.sh enable|disable <id>  turn a plugin on or off
#
# Each of those ends with the shell reloading its plugins, and a reload unloads
# every open panel — Plug's own window included. A job running inside the panel
# is therefore killed at the moment its work lands, taking the result message
# with it, which is why these run detached from the panel and summon Plug back
# afterwards with what happened.
set -e

ID="io.github.weedwhitesandwine.plug"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> plug hotkey (managed by Plug settings — change it there)"
MARK_OUT="-- <<< plug hotkey"

strip_block() {
  awk '
    index($0, ">>> plug hotkey") { skip = 1; next }
    index($0, "<<< plug hotkey") { skip = 0; next }
    !skip { print }
  ' "$BIND_FILE"
}

# ---------------------------------------------------------------- job helpers

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Is this id still referenced anywhere in the live shell config? Turning a
# plugin off clears ONE reference per call, and anything installed the usual
# way is referenced twice — once as a plugin, once as a bar widget — so a
# single call leaves an orphan behind pointing at a plugin that is on its way
# out. The config is the authority here, not the command's own "ok", which it
# reports even when there was nothing left to clear.
refs_left() {
  omarchy-shell shell listShellConfig 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
try:
    c = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(c, dict):
    sys.exit(1)
def eid(w):
    return w.get("id") if isinstance(w, dict) else w
seen = []
lay = (c.get("bar") or {}).get("layout")
for sec in (lay.values() if isinstance(lay, dict) else (lay or [])):
    for w in (sec or []):
        seen.append(eid(w))
for w in (c.get("plugins") or []):
    seen.append(eid(w))
sys.exit(0 if want in seen else 1)' "$1"
}

# Is this plugin on? The shell calls a bar widget enabled only when it has a
# place in the bar, so a plugin whose owner switched its bar icon off reports
# as disabled while running perfectly well — its entry sits in the plugins
# list instead. Either location counts as on here: hiding an icon is not
# switching a plugin off, and nothing should drag a hidden icon back.
is_on() {
  if omarchy-shell shell listPlugins 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in d if isinstance(d, list) else []:
    if p.get("id") == sys.argv[1]:
        sys.exit(0 if p.get("enabled") is True else 1)
sys.exit(1)' "$1"; then
    return 0
  fi
  refs_left "$1"
}

# Clear every reference, checking the config rather than trusting the reply.
# Two locations is the normal worst case; the cap stops a config that will not
# settle from spinning here forever.
clear_refs() {
  local id="$1" out i
  for i in 1 2 3 4 5; do
    refs_left "$id" || return 0
    out=$(omarchy-shell shell setPluginEnabled "$id" false 2>&1) || true
    [[ $out == "ok" ]] || { echo "${out:-setPluginEnabled produced no output}"; return 1; }
  done
  if refs_left "$id"; then echo "still referenced"; return 1; fi
  return 0
}

# Bring Plug back up with the outcome. The shell may be mid-teardown, mid-
# rebuild, or (after an update) still starting up again, so wait for it to
# answer before summoning and keep trying for a while after that.
finish() {
  local highlight="$1" notice="$2" err="$3" payload i
  payload=$(python3 -c '
import json, sys
h, n, e = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if h: d["highlight"] = h
if e: d["error"] = e
elif n: d["notice"] = n
print(json.dumps(d))' "$highlight" "$notice" "$err")
  for i in $(seq 1 60); do
    [[ $(omarchy-shell shell ping 2>/dev/null) ]] && break
    sleep 0.5
  done
  # Let the panel teardown settle so the payload is queued for the NEW panel
  # rather than eaten by the dying one.
  sleep 0.6
  for i in $(seq 1 20); do
    [[ $(omarchy-shell shell summon "$ID" "$payload" 2>/dev/null) == "ok" ]] && return 0
    sleep 0.5
  done
  return 0
}

# The last line is what a failing command actually said; the rest is noise.
last_line() { printf '%s' "$1" | tail -n 1; }

case "$1" in
  bind)
    key="$2"
    [[ -n $key && -f $BIND_FILE ]] || exit 1
    # This value ends up inside a Lua string in bindings.lua, so it is checked
    # here as well as in the settings view — a settings file can be edited or
    # restored from a backup without going near the UI. A hotkey is modifiers
    # plus one key and nothing else; anything that does not match that shape is
    # refused rather than escaped, because there is no reason for it to exist.
    if ! [[ $key =~ ^(SUPER|CTRL|ALT|SHIFT)([[:space:]]\+[[:space:]](SUPER|CTRL|ALT|SHIFT))*[[:space:]]\+[[:space:]]([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$ ]]; then
      echo "plug-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    # Staged in the same directory as bindings.lua and renamed over it, so the
    # swap is one atomic step; mktemp creates the stage file exclusively under
    # a random name, so nothing can have been planted at it.
    tmp=$(mktemp "$BIND_FILE.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "Plug (plugin manager)", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    chmod --reference="$BIND_FILE" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$BIND_FILE"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    tmp=$(mktemp "$BIND_FILE.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    strip_block > "$tmp"
    chmod --reference="$BIND_FILE" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$BIND_FILE"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    python3 - "$2" "${3:-right}" <<'PY'
import json, os, stat, sys, tempfile
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.plug"
p = os.path.expanduser("~/.config/omarchy/shell.json")
# shell.json belongs to the user, not to this plugin, and it is read back
# before it is rewritten. The open refuses symlinks and non-regular files, so
# a planted link cannot redirect the read and a FIFO cannot block it forever.
MAX_SHELL_JSON = 4 * 1024 * 1024
try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise SystemExit
        with os.fdopen(fd, "rb") as f:
            fd = None
            raw = f.read(MAX_SHELL_JSON + 1)
    finally:
        if fd is not None:
            os.close(fd)
    if len(raw) > MAX_SHELL_JSON:
        raise SystemExit
    d = json.loads(raw.decode("utf-8", "replace"))
except SystemExit:
    raise
except Exception:
    raise SystemExit
if not isinstance(d, dict):
    raise SystemExit
def eid(w): return w.get("id") if isinstance(w, dict) else w
if not isinstance(d.get("bar"), dict):
    d["bar"] = {}
bar = d["bar"]
if not isinstance(bar.get("layout"), dict):
    bar["layout"] = {}
lay = bar["layout"]
for s in ("left", "center", "right"):
    if not isinstance(lay.get(s), list):
        lay[s] = []
for s in lay:
    if isinstance(lay[s], list):
        lay[s] = [w for w in lay[s] if eid(w) != ID]
if not isinstance(d.get("plugins"), list):
    d["plugins"] = []
d["plugins"] = [w for w in d["plugins"] if eid(w) != ID]
if state == "on":
    lay[sec].append({"id": ID})
else:
    d["plugins"].append({"id": ID})
# Staged under an unpredictable name created exclusively by mkstemp in a
# directory verified owner-only, then renamed over the destination in one step.
home_cfg = os.path.dirname(p)
try:
    st = os.stat(home_cfg)
    if st.st_uid != os.getuid() or (st.st_mode & 0o022):
        raise SystemExit
except OSError:
    raise SystemExit
fd, tmp = tempfile.mkstemp(prefix=".shell.json.", suffix=".tmp", dir=home_cfg)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    try:
        os.chmod(tmp, os.stat(p).st_mode & 0o777)
    except OSError:
        pass
    os.replace(tmp, p)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    ;;
  remove)
    id="$2"
    [[ -n $id ]] || exit 2
    err=""
    # Every reference goes first. The uninstall command clears only one itself,
    # and by the time it has deleted the directory an orphan entry points at
    # nothing.
    err=$(clear_refs "$id") || true
    if [[ -z $err ]]; then
      # Judge it by whether it succeeded, never by whether it printed
      # something: a command that dies silently prints nothing at all, and
      # reading that as success reported failed removals as clean ones.
      if out=$(omarchy plugin remove "$id" --yes 2>&1); then
        :
      else
        err=$(last_line "$out")
        [[ -n $err ]] || err="omarchy plugin remove failed"
      fi
    fi
    if [[ -n $err ]]; then finish "$id" "" "$err"; else finish "" "Removed $id" ""; fi
    ;;
  apply | rollback)
    verb="$1"
    id="$2"
    [[ -n $id ]] || exit 2
    err=""
    deferred=0
    if out=$(python3 "$DIR/plugd.py" "$verb" "$id" 2>&1); then
      # Report what the engine reported: it answers with an error field rather
      # than a failing exit status when git refuses the operation.
      err=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict) and d.get("error"):
    print(str(d["error"]))')
    else
      err=$(last_line "$out")
      [[ -n $err ]] || err="plug engine failed"
    fi
    if [[ -z $err ]]; then
      # The new code is on disk, but the shell is still running the copy it
      # loaded at startup — and it keeps running it. Asking it to rescan its
      # plugins is not enough: a rescan re-reads which plugins exist, so
      # installs and removals show up, but already-loaded plugin code stays
      # cached. Only a restart actually picks up changed code, which is the
      # step that makes an update take effect at all. It is also what unloads
      # this panel, which is why this runs detached and summons Plug back.
      #
      # Never while the screen is locked: restarting the shell there takes the
      # lock screen with it. A locked screen means nobody pressed the button,
      # so the reload simply waits for the next restart.
      if omarchy-hyprland-session-locked 2>/dev/null; then
        deferred=1
      else
        omarchy-restart-shell >/dev/null 2>&1 || true
      fi
    fi
    if [[ $verb == apply ]]; then note="Updated $id"; else note="Restored $id to its previous version"; fi
    if (( deferred )); then note="$note — it loads when the shell next restarts"; fi
    if [[ -n $err ]]; then finish "$id" "" "$err"; else finish "$id" "$note" ""; fi
    ;;
  install)
    # install <url> <name> <reviewed-sha> <plugin-id> [--approved-version]
    #
    # What the reviewer read was one exact commit. A repository address is not
    # a commit — it is a pointer, and it can point somewhere else by the time
    # anything downloads it. So the repository is asked what it is at now,
    # without downloading it, and nothing is installed unless the answer is the
    # commit that was read. If it has moved, nothing lands on the disk at all;
    # the panel says so and offers the version that was approved, which comes
    # back here with --approved-version and is pinned after the install.
    url="$2"
    name="${3:-$2}"
    sha="${4:-}"
    pid="${5:-}"
    mode="${6:-}"
    [[ -n $url ]] || exit 2
    err=""
    moved=""

    if [[ -n $sha ]]; then
      now=$(python3 "$DIR/plugd.py" still-at "$url" "$sha" 2>/dev/null |
        python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("unreachable"); raise SystemExit
if not d.get("reachable"): print("unreachable")
elif d.get("same"): print("same")
else: print(d.get("now") or "unknown")')
      case "$now" in
        same) : ;;
        unreachable) err="could not reach the repository to check it" ;;
        *)
          if [[ $mode != "--approved-version" ]]; then
            # Nothing is installed. The panel decides what to offer.
            moved="$now"
          fi
          ;;
      esac
    fi

    if [[ -n $moved ]]; then
      finish "" "" "MOVED $name $moved"
      exit 0
    fi

    if [[ -z $err ]]; then
      # The approved version may not be the branch tip any more, so it is
      # installed switched off and pinned before anything is allowed to run.
      add_args=("$url" --yes)
      [[ $mode == "--approved-version" ]] || add_args+=(--enable)
      if out=$(omarchy plugin add "${add_args[@]}" 2>&1); then :; else
        err=$(last_line "$out")
        [[ -n $err ]] || err="omarchy plugin add failed"
      fi
    fi

    # Backstop: whatever the checks above concluded, what actually landed is
    # what matters. If it is not the reviewed commit, pin it to that commit;
    # if it cannot be pinned, remove it rather than leave unreviewed code
    # installed.
    if [[ -z $err && -n $sha && -n $pid ]]; then
      d="$HOME/.config/omarchy/plugins/$pid"
      if [[ -d $d/.git ]]; then
        head=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")
        if [[ $head != "$sha" ]]; then
          if git -C "$d" cat-file -t "$sha" >/dev/null 2>&1 &&
             git -C "$d" reset --hard "$sha" >/dev/null 2>&1 &&
             [[ $(git -C "$d" rev-parse HEAD 2>/dev/null) == "$sha" ]]; then
            :
          else
            omarchy plugin remove "$pid" --yes >/dev/null 2>&1 || true
            err="what arrived was not the version you approved — nothing was installed"
          fi
        fi
        if [[ -z $err && $mode == "--approved-version" ]]; then
          # Pinning rewrote files inside the plugin folder, and the shell
          # disables a plugin whose files change under it. So switching it on
          # has to come after that settles, and has to be confirmed rather
          # than assumed — the first attempt can be undone a moment later.
          for i in 1 2 3 4 5 6; do
            sleep 0.6
            is_on "$pid" && break
            out=$(omarchy-shell shell setPluginEnabled "$pid" true 2>&1) || true
          done
          is_on "$pid" || err="installed at the version you approved, but it could not be switched on — turn it on from the list"
        fi
      fi
    fi

    if [[ -n $err ]]; then finish "" "" "$err"; else finish "" "Installed $name" ""; fi
    ;;
  enable | disable)
    id="$2"
    [[ -n $id ]] || exit 2
    err=""
    if [[ $1 == enable ]]; then
      out=$(omarchy-shell shell setPluginEnabled "$id" true 2>&1) || true
      [[ $out == "ok" ]] || err="${out:-setPluginEnabled produced no output}"
      # Judge it by the state, not the answer. Still off with no entry
      # anywhere means the switch did nothing: clear whatever is there and try
      # once more. A plugin that is merely hidden is already on and is left
      # exactly as its owner set it.
      if [[ -z $err ]] && ! is_on "$id"; then
        clear_refs "$id" >/dev/null 2>&1 || true
        out=$(omarchy-shell shell setPluginEnabled "$id" true 2>&1) || true
        [[ $out == "ok" ]] || err="${out:-setPluginEnabled produced no output}"
        if [[ -z $err ]] && ! is_on "$id"; then err="could not switch it on"; fi
      fi
      note="Enabled $id"
    else
      err=$(clear_refs "$id") || true
      note="Disabled $id"
    fi
    if [[ -n $err ]]; then finish "$id" "" "$err"; else finish "$id" "$note" ""; fi
    ;;
  *)
    echo "usage: plug-ctl.sh bind <keys> | unbind | bar on|off [section] |" >&2
    echo "       remove <id> | apply <id> | rollback <id> | install <url> [name] |" >&2
    echo "       enable <id> | disable <id>" >&2
    exit 2
    ;;
esac
