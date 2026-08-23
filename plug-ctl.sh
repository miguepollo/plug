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
  *)
    echo "usage: plug-ctl.sh bind <keys> | unbind | bar on|off [section]" >&2
    exit 2
    ;;
esac
