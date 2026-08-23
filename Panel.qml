import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "."

// Plug — one place to manage your community Omarchy plugins.
//
//   omarchy-shell shell toggle io.github.weedwhitesandwine.plug
//
// Three views. INSTALLED lists the third-party plugins you have, each with an
// on/off switch and a remove, and — the point of Plug — an UPDATE flag when
// the plugin's repository has moved past what you installed. Acting on that
// flag opens a REVIEW: the exact changes are read by the AI reviewer you chose
// in settings, structurally read-only, and reported back in plain English with
// a safe / be-careful / do-not traffic light. STORE searches the marketplace
// catalog and installs. First-party Omarchy plugins are never shown or touched
// — the shell manages those itself.
//
// The heavy lifting lives in plugd.py; this panel runs it and reads the small
// JSON files it writes, always through `head` so an oversized file is never
// pulled whole into the shell.
Item {
  id: root

  property bool opened: false
  readonly property string selfId: "io.github.weedwhitesandwine.plug"

  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return decodeURIComponent(u.replace(/^file:\/\//, "")).replace(/\/$/, "")
  }
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: {
    var b = Quickshell.env("XDG_STATE_HOME")
    return (b ? b : root.home + "/.local/state") + "/plug"
  }

  // ------------------------------------------------------------------ theme
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selBg: Color.menu.selectedBackground
  property color selText: Color.menu.selectedText
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color fainter: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.35)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)

  // Semantic colours for the verdict and trust dots — fixed, not theme, so a
  // green verdict is green on every theme. Picked for contrast on dark and
  // light alike.
  readonly property color okColor: "#3fb950"
  readonly property color warnColor: "#d29922"
  readonly property color dangerColor: "#f85149"
  function trustColor(score) {
    if (score >= 70) return root.okColor
    if (score >= 35) return root.warnColor
    return root.dangerColor
  }
  function verdictColor(v) {
    if (v === "SAFE") return root.okColor
    if (v === "DANGER") return root.dangerColor
    return root.warnColor
  }

  // ------------------------------------------------------------------ state
  property string tab: "installed"          // installed | store | settings
  property var installedRows: []            // joined listPlugins + engine aux
  property var auxById: ({})                // engine state.json plugins map
  property var catalogRows: []
  property bool catalogLoaded: false
  property string storeQuery: ""
  property bool busy: false
  property string busyNote: ""
  property string noticeText: ""

  // Selection cursor into the visible list.
  property int selectedIndex: 0

  // Remove confirmation, one row at a time.
  property string confirmRemoveId: ""

  // The review overlay. reviewId is the plugin under review; reviewData is the
  // engine's review-<id>.json once it lands.
  property string reviewId: ""
  property var reviewData: null
  property bool reviewRunning: false

  // Settings, loaded from the engine's settings.json.
  property var settings: ({ reviewAgent: "claude", reviewModel: "sonnet", autoCheck: true })
  property var availableAgents: []
  property bool settingsLoaded: false

  // Update count drives the header badge and the bar widget badge.
  readonly property int updateCount: {
    var n = 0
    for (var i = 0; i < root.installedRows.length; i++)
      if (root.installedRows[i].updateAvailable) n++
    return n
  }
  onUpdateCountChanged: PlugState.updateCount = root.updateCount

  // --------------------------------------------------------------- lifecycle
  function open(payloadJson) {
    root.opened = true
    root.tab = "installed"
    root.selectedIndex = 0
    root.confirmRemoveId = ""
    root.reviewId = ""
    root.reviewData = null
    root.noticeText = ""
    root.refreshAll()
    // Freshen the update flags in the background so they are current without
    // pressing the button — offline flags show immediately, the network check
    // updates them a moment later.
    if (root.settings.autoCheck !== false) autoCheckTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer { id: autoCheckTimer; interval: 500; onTriggered: if (root.opened) root.checkUpdates() }

  function close() {
    root.opened = false
    root.confirmRemoveId = ""
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() { if (root.opened) root.close(); else root.open("{}") }

  Component.onCompleted: {
    PlugState.overlay = root
    root.loadSettings()
    root.loadCatalog()
    root.loadBinds()
  }

  onOpenedChanged: if (root.opened) root.refreshAll()

  // -------------------------------------------------------------- data flow
  // The live installed list comes from the shell; the git/update/trust layer
  // comes from the engine's state.json. They are joined by id. First-party
  // plugins are dropped here and never appear again.
  function refreshAll() {
    listProc.running = false
    listProc.running = true
    snapshotProc.running = false
    snapshotProc.running = true
  }

  // Core shell infrastructure that is always on and has no meaningful switch,
  // so it is hidden from the Official section entirely.
  readonly property var hiddenFirstParty: ({
    "omarchy.bar": true, "omarchy.polkit": true, "omarchy.lock": true,
    "omarchy.idle": true, "omarchy.notifications": true, "omarchy.osd": true,
    "omarchy.launcher": true, "omarchy.menu": true, "omarchy.background": true,
    "omarchy.clipboard": true, "omarchy.image-picker": true, "omarchy.spacer": true
  })

  function rebuildInstalled() {
    var live = root.livePlugins || []
    var aux = root.auxById || {}
    var out = []
    var official = []
    for (var i = 0; i < live.length; i++) {
      var p = live[i]
      if (p.id === root.selfId) continue            // Plug does not manage itself
      if (p.firstParty === true) {
        // Omarchy's own. Show only the optional bar widgets that can actually
        // be toggled — never the core infrastructure — and never removable.
        if (root.hiddenFirstParty[p.id]) continue
        if (p.canDisable === false) continue
        if (!(p.kinds && p.kinds.indexOf("bar-widget") >= 0)) continue
        official.push({
          id: p.id, name: p.name || p.id, official: true,
          kinds: (p.kinds || []).join(", "),
          enabled: p.enabled === true, canDisable: true
        })
        continue
      }
      var a = aux[p.id] || {}
      out.push({
        id: p.id,
        name: p.name || a.name || p.id,
        author: a.author || "",
        kinds: (p.kinds || []).join(", "),
        official: false,
        enabled: p.enabled === true,
        canDisable: p.canDisable !== false,
        updateAvailable: a.updateAvailable === true,
        commitsBehind: a.commitsBehind || 0,
        trustScore: (a.trustScore === undefined ? -1 : a.trustScore),
        capabilities: a.capabilities || [],
        locked: a.locked === true,
        isGit: a.isGit === true,
        remote: a.remote || "",
        canRevert: (a.previousSha || "") !== ""
      })
    }
    out.sort(function(x, y) {
      if (x.updateAvailable !== y.updateAvailable) return x.updateAvailable ? -1 : 1
      return x.name.toLowerCase() < y.name.toLowerCase() ? -1 : 1
    })
    official.sort(function(x, y) { return x.name.toLowerCase() < y.name.toLowerCase() ? -1 : 1 })
    root.installedRows = out
    root.officialRows = official
    if (root.selectedIndex >= out.length) root.selectedIndex = Math.max(0, out.length - 1)
  }

  property var livePlugins: []
  property var officialRows: []
  // Both sections fold. Community is open by default (it is what you came for);
  // official is folded by default — it is long, rarely touched, and would
  // otherwise push the community plugins off the top.
  property bool communityExpanded: true
  property bool officialExpanded: false

  Process {
    id: listProc
    command: ["omarchy-shell", "shell", "listPlugins"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(text)
          if (Array.isArray(arr)) { root.livePlugins = arr; root.rebuildInstalled() }
        } catch (e) {}
      }
    }
  }

  // snapshot writes state.json (offline, fast); we read it back through head.
  Process {
    id: snapshotProc
    command: ["python3", root.pluginDir + "/plugd.py", "snapshot"]
    onExited: root.readState()
    stdout: StdioCollector { waitForEnd: true }
  }

  readonly property int stateCeiling: 4 * 1024 * 1024
  function readState() { stateReader.running = false; stateReader.running = true }
  Process {
    id: stateReader
    command: ["head", "-c", String(root.stateCeiling), "--", root.stateDir + "/state.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && typeof s === "object" && s.plugins) {
            root.auxById = s.plugins
            root.rebuildInstalled()
          }
        } catch (e) {}
      }
    }
  }

  // The one network step behind the update flag.
  function checkUpdates() {
    root.busy = true; root.busyNote = "Checking for updates…"
    checkProc.running = false; checkProc.running = true
  }
  // Set once a network check has actually completed, so "no updates" is only
  // shown after we have looked — not before the first check on open.
  property bool updatesChecked: false
  Process {
    id: checkProc
    command: ["python3", root.pluginDir + "/plugd.py", "check-updates"]
    onExited: { root.busy = false; root.busyNote = ""; root.updatesChecked = true; root.readState() }
    stdout: StdioCollector { waitForEnd: true }
  }

  // --------------------------------------------------------- enable/disable
  // Exactly the operation `omarchy plugin enable/disable` performs, skipping
  // the rescan that would tear this panel down. Detached so it outlives us if
  // the toggle happens to unload the panel, then re-reads state.
  function setEnabled(id, on) {
    Quickshell.execDetached(["bash", "-c",
      'omarchy-shell shell setPluginEnabled "$1" "$2" >/dev/null 2>&1',
      "--", id, on ? "true" : "false"])
    root.noticeText = (on ? "Enabled " : "Disabled ") + id
    rerunTimer.restart()
  }
  Timer { id: rerunTimer; interval: 500; onTriggered: root.refreshAll() }

  // ------------------------------------------------------------------ remove
  function askRemove(id) { root.confirmRemoveId = id }
  function removeConfirmed(id) {
    root.confirmRemoveId = ""
    root.busy = true; root.busyNote = "Removing…"
    removeProc.command = ["omarchy", "plugin", "remove", id]
    removeProc.running = false; removeProc.running = true
    root.noticeText = "Removed " + id
  }
  Process {
    id: removeProc
    onExited: { root.busy = false; root.busyNote = ""; root.refreshAll() }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // ------------------------------------------------------------------ update
  // The review gate. Running review invokes the chosen AI agent read-only on
  // the diff; when it lands we read review-<id>.json and show the verdict.
  function startReview(id) {
    root.reviewId = id
    root.reviewData = null
    root.reviewRunning = true
    reviewProc.command = ["python3", root.pluginDir + "/plugd.py", "review", id]
    reviewProc.running = false; reviewProc.running = true
  }
  // The review command prints the whole review record on stdout, so we read
  // it straight from there — no filename to keep in sync with the engine.
  Process {
    id: reviewProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d && d.review) root.reviewData = d
          else if (d && d.error) root.noticeText = "Review failed: " + d.error
        } catch (e) {}
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.reviewRunning = false
  }

  function approveUpdate() {
    if (!root.reviewId) return
    var id = root.reviewId
    root.busy = true; root.busyNote = "Applying update…"
    applyProc.command = ["python3", root.pluginDir + "/plugd.py", "apply", id]
    applyProc.running = false; applyProc.running = true
    root.reviewId = ""; root.reviewData = null
    root.noticeText = "Updated " + id
  }
  Process {
    id: applyProc
    onExited: { root.busy = false; root.busyNote = ""; root.refreshAll() }
    stdout: StdioCollector { waitForEnd: true }
  }

  function cancelReview() { root.reviewId = ""; root.reviewData = null; root.reviewRunning = false }

  function toggleLock(id, locked) {
    lockProc.command = ["python3", root.pluginDir + "/plugd.py",
                        locked ? "lock" : "unlock", id]
    lockProc.running = false; lockProc.running = true
  }
  Process { id: lockProc; onExited: root.refreshAll(); stdout: StdioCollector { waitForEnd: true } }

  // Undo the last applied update — the version to return to was recorded when
  // the update was applied.
  function revert(id) {
    root.busy = true; root.busyNote = "Reverting…"
    revertProc.command = ["python3", root.pluginDir + "/plugd.py", "rollback", id]
    revertProc.running = false; revertProc.running = true
    root.noticeText = "Reverted " + id + " to its previous version"
  }
  Process {
    id: revertProc
    onExited: { root.busy = false; root.busyNote = ""; root.refreshAll() }
    stdout: StdioCollector { waitForEnd: true }
  }

  // ------------------------------------------------------------------ store
  function loadCatalog() {
    catalogReader.running = false; catalogReader.running = true
  }
  function refreshCatalog() {
    root.busy = true; root.busyNote = "Fetching catalog…"
    catalogFetch.running = false; catalogFetch.running = true
  }
  Process {
    id: catalogFetch
    command: ["python3", root.pluginDir + "/plugd.py", "catalog"]
    onExited: { root.busy = false; root.busyNote = ""; root.loadCatalog() }
    stdout: StdioCollector { waitForEnd: true }
  }
  readonly property int catalogCeiling: 8 * 1024 * 1024
  Process {
    id: catalogReader
    command: ["head", "-c", String(root.catalogCeiling), "--", root.stateDir + "/catalog.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d && Array.isArray(d.plugins)) { root.catalogRows = d.plugins; root.catalogLoaded = true }
        } catch (e) {}
      }
    }
  }

  readonly property var installedIdSet: {
    var s = ({})
    for (var i = 0; i < root.installedRows.length; i++) s[root.installedRows[i].id] = true
    return s
  }
  // Community plugins first, then Omarchy's own built-ins (marked OFFICIAL),
  // so the two are visibly separated the way the list reads.
  readonly property var storeFiltered: {
    var q = root.storeQuery.trim().toLowerCase()
    var comm = []
    var off = []
    for (var i = 0; i < root.catalogRows.length; i++) {
      var c = root.catalogRows[i]
      if (q !== "") {
        var hay = (c.name + " " + c.author + " " + c.description + " "
                   + (c.tags || []).join(" ")).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      if (c.official) off.push(c)
      else comm.push(c)
      if (comm.length + off.length >= 300) break
    }
    return comm.concat(off)
  }
  readonly property int communityCount: {
    var n = 0
    for (var i = 0; i < root.catalogRows.length; i++) if (!root.catalogRows[i].official) n++
    return n
  }

  function installFromStore(c) {
    if (!c.repo) return
    root.busy = true; root.busyNote = "Installing " + c.name + "…"
    installProc.command = ["omarchy", "plugin", "add", c.repo + ".git", "--enable", "--yes"]
    installProc.running = false; installProc.running = true
    root.noticeText = "Installing " + c.name
  }
  Process {
    id: installProc
    onExited: { root.busy = false; root.busyNote = ""; root.refreshAll() }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // ------------------------------------------------------------------ settings
  readonly property string settingsFile: root.stateDir + "/settings.json"
  function loadSettings() { settingsReader.running = false; settingsReader.running = true }
  Process {
    id: settingsReader
    command: ["head", "-c", "65536", "--", root.stateDir + "/settings.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && typeof s === "object" && !Array.isArray(s)) root.settings = s
        } catch (e) {}
        root.settingsLoaded = true
        agentsProc.running = false; agentsProc.running = true
      }
    }
  }
  // Ask the engine which reviewers are actually installed.
  Process {
    id: agentsProc
    command: ["python3", root.pluginDir + "/plugd.py", "agents"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var a = JSON.parse(text)
          if (Array.isArray(a)) root.availableAgents = a
        } catch (e) {}
      }
    }
  }

  // Every hotkey active in Hyprland right now, whatever config assigned it —
  // `hyprctl binds` is the authoritative list, including Omarchy's own binds
  // that never appear in bindings.lua. Plug uses it to warn before you pick a
  // combination that is already taken.
  property var takenBinds: ({})
  function loadBinds() { bindsProc.running = false; bindsProc.running = true }
  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(text)
          if (!Array.isArray(arr)) return
          var names = { 1: "SHIFT", 4: "CTRL", 8: "ALT", 64: "SUPER" }
          var order = [64, 4, 8, 1]
          var taken = ({})
          for (var i = 0; i < arr.length; i++) {
            var m = arr[i].modmask
            var mods = []
            for (var j = 0; j < order.length; j++) if (m & order[j]) mods.push(names[order[j]])
            var key = String(arr[i].key || "").toUpperCase()
            if (!key) continue
            if (key === " ") key = "SPACE"
            if (mods.length) taken[mods.join(" + ") + " + " + key] = true
          }
          root.takenBinds = taken
        } catch (e) {}
      }
    }
  }
  function saveSettings() {
    if (!root.settingsLoaded) return
    Quickshell.execDetached(["bash", "-c",
      'd=$(dirname "$2") && mkdir -p "$d" && [ -O "$d" ] && t=$(mktemp "$2.XXXXXXXX") && printf "%s\\n" "$1" > "$t" && mv -f "$t" "$2"',
      "--", JSON.stringify(root.settings), root.settingsFile])
  }
  function setAgent(key) {
    var s = JSON.parse(JSON.stringify(root.settings))
    s.reviewAgent = key
    // Default the model to the agent's first, if we know it.
    for (var i = 0; i < root.availableAgents.length; i++)
      if (root.availableAgents[i].key === key) s.reviewModel = root.availableAgents[i].defaultModel
    root.settings = s
    root.saveSettings()
  }
  function setModel(m) {
    var s = JSON.parse(JSON.stringify(root.settings)); s.reviewModel = m
    root.settings = s; root.saveSettings()
  }

  // --------------------------------------------------------- hotkey capture
  property bool capturing: false
  property string captureNote: ""
  readonly property var shortcutPattern:
    /^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$/
  function validShortcut(s) {
    return typeof s === "string" && s.length <= 40 && root.shortcutPattern.test(s)
  }
  function captureKey(event) {
    if (event.key === Qt.Key_Escape) { root.capturing = false; root.captureNote = ""; return }
    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
    var name = ""
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) name = String.fromCharCode(65 + (event.key - Qt.Key_A))
    else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) name = String.fromCharCode(48 + (event.key - Qt.Key_0))
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F12) name = "F" + (event.key - Qt.Key_F1 + 1)
    if (name === "") return
    if (mods.length === 0) { root.captureNote = "Add a modifier — SUPER, CTRL or ALT"; return }
    var combo = mods.join(" + ") + " + " + name
    // Refuse a combination Hyprland already uses for something else, so Plug
    // never quietly steals a shortcut. The user picks another.
    if (root.takenBinds[combo] === true) {
      root.captureNote = combo + " is already used by something else — try another."
      return
    }
    var s = JSON.parse(JSON.stringify(root.settings)); s.shortcut = combo
    root.settings = s; root.saveSettings()
    root.capturing = false; root.captureNote = ""
    Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "bind", combo])
  }
  function clearHotkey() {
    var s = JSON.parse(JSON.stringify(root.settings)); s.shortcut = ""
    root.settings = s; root.saveSettings()
    Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "unbind"])
  }

  // ================================================================= UI
  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.namespace: "plug"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(e) {
        if (root.capturing) { root.captureKey(e); e.accepted = true; return }
        // Review overlay: Enter approves, Esc backs out.
        if (root.reviewId !== "") {
          if (e.key === Qt.Key_Escape) { root.cancelReview(); e.accepted = true }
          else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter)
                   && root.reviewData && !root.reviewRunning) { root.approveUpdate(); e.accepted = true }
          return
        }
        // Escape unwinds one layer at a time, then closes.
        if (e.key === Qt.Key_Escape) {
          if (root.confirmRemoveId !== "") root.confirmRemoveId = ""
          else if (root.tab === "store" && root.storeQuery !== "") root.storeQuery = ""
          else root.close()
          e.accepted = true; return
        }
        if (e.key === Qt.Key_Tab) {
          root.tab = root.tab === "installed" ? "store" : (root.tab === "store" ? "settings" : "installed")
          root.selectedIndex = 0; e.accepted = true; return
        }

        // The panel holds keyboard focus itself, so the Store search is a
        // filter buffer built from keystrokes rather than a focused field —
        // just type on the Store tab. Backspace edits it.
        if (root.tab === "store") {
          if (e.key === Qt.Key_Backspace) {
            root.storeQuery = root.storeQuery.slice(0, -1); e.accepted = true; return
          }
          if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 0x20
              && !(e.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))) {
            root.storeQuery += e.text; e.accepted = true; return
          }
        }

        // Installed tab: arrow keys move a visible cursor, Enter acts on it
        // (review a waiting update, otherwise toggle enabled), and x removes.
        if (root.tab === "installed") {
          var n = root.installedRows.length
          if (e.key === Qt.Key_Down) {
            root.selectedIndex = Math.min(n - 1, root.selectedIndex + 1); e.accepted = true; return
          }
          if (e.key === Qt.Key_Up) {
            root.selectedIndex = Math.max(0, root.selectedIndex - 1); e.accepted = true; return
          }
          if (root.selectedIndex >= 0 && root.selectedIndex < n) {
            var row = root.installedRows[root.selectedIndex]
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
              if (row.updateAvailable && !row.locked) root.startReview(row.id)
              else root.setEnabled(row.id, !row.enabled)
              e.accepted = true; return
            }
            if (e.key === Qt.Key_X || e.key === Qt.Key_Delete) {
              if (root.confirmRemoveId === row.id) root.removeConfirmed(row.id)
              else root.askRemove(row.id)
              e.accepted = true; return
            }
          }
        }
      }
    }

    Rectangle {
      id: card
      width: Math.min(Style.space(960), panel.width - Style.space(40))
      height: Math.min(Style.space(620), panel.height - Style.space(40))
      anchors.centerIn: parent
      color: root.background
      radius: root.cornerRadius
      border.color: root.border
      border.width: Math.max(1, Style.space(1))

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(18)
        spacing: Style.space(12)

        // -------- header: title, tabs, update badge, refresh
        Item {
          width: parent.width
          height: Style.space(30)
          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)
            Text {
              text: "  Plug"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              visible: root.updateCount > 0
              anchors.verticalCenter: parent.verticalCenter
              width: badgeText.implicitWidth + Style.space(14)
              height: Style.space(20)
              radius: height / 2
              color: root.warnColor
              Text {
                id: badgeText
                anchors.centerIn: parent
                text: root.updateCount + (root.updateCount === 1 ? " update" : " updates")
                textFormat: Text.PlainText
                color: "#1a1005"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            TabButton { label: "Installed"; active: root.tab === "installed"; onPickedT: root.tab = "installed" }
            TabButton { label: "Store"; active: root.tab === "store"; onPickedT: { root.tab = "store"; if (!root.catalogLoaded) root.refreshCatalog() } }
            TabButton { label: "Settings"; active: root.tab === "settings"; onPickedT: root.tab = "settings" }
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // -------- body
        Item {
          width: parent.width
          height: parent.height - Style.space(30) - Style.space(12) - 1 - Style.space(12) - footer.height - Style.space(12)

          // ===== INSTALLED =====
          Column {
            visible: root.tab === "installed" && root.reviewId === ""
            anchors.fill: parent
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(10)
              Text {
                text: root.installedRows.length + " community plugin" + (root.installedRows.length === 1 ? "" : "s")
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              // A plain-language status once a check has run: either the count
              // (also badged in the header) or an explicit all-clear.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.updatesChecked && !(root.busy && root.busyNote.indexOf("update") >= 0)
                text: root.updateCount > 0
                    ? (root.updateCount + " update" + (root.updateCount === 1 ? "" : "s") + " available")
                    : "✓ No updates available"
                textFormat: Text.PlainText
                color: root.updateCount > 0 ? root.warnColor : root.okColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Item { width: Style.space(1); height: 1 }
              PlugButton {
                label: root.busy && root.busyNote.indexOf("update") >= 0 ? "Checking…" : "Check for updates"
                onPicked: root.checkUpdates()
              }
            }

            Flickable {
              width: parent.width
              height: parent.height - Style.space(30)
              contentHeight: instCol.height
              clip: true
              Column {
                id: instCol
                width: parent.width
                spacing: Style.space(6)

                // ---- Community: your third-party plugins. Toggle + remove.
                SectionHeader {
                  label: "Community"
                  count: root.installedRows.length
                  expanded: root.communityExpanded
                  onToggled: root.communityExpanded = !root.communityExpanded
                }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(6)
                  readonly property real cellW: (width - columnSpacing) / 2
                  Repeater {
                    model: root.communityExpanded ? root.installedRows : []
                    delegate: InstalledRow {
                      width: parent.cellW
                      rowData: modelData
                      confirming: root.confirmRemoveId === modelData.id
                      selected: index === root.selectedIndex
                    }
                  }
                }
                Item {
                  visible: root.communityExpanded && root.installedRows.length === 0
                  width: parent.width; height: Style.space(60)
                  Text {
                    anchors.centerIn: parent
                    text: "No community plugins installed yet.\nBrowse the Store to add some."
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                // ---- Official (Omarchy's own bar widgets). Toggleable here,
                // never removable — the shell owns them; Plug just offers the
                // switch. Folded by default.
                SectionHeader {
                  visible: root.officialRows.length > 0
                  label: "Official — Omarchy's own"
                  count: root.officialRows.length
                  expanded: root.officialExpanded
                  onToggled: root.officialExpanded = !root.officialExpanded
                }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(6)
                  readonly property real cellW: (width - columnSpacing) / 2
                  Repeater {
                    model: root.officialExpanded ? root.officialRows : []
                    delegate: InstalledRow {
                      width: parent.cellW
                      rowData: modelData
                    }
                  }
                }
              }
            }
          }

          // ===== REVIEW OVERLAY =====
          ReviewView {
            visible: root.reviewId !== ""
            anchors.fill: parent
          }

          // ===== STORE =====
          Column {
            visible: root.tab === "store"
            anchors.fill: parent
            spacing: Style.space(8)

            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: root.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
              border.color: root.hairline
              border.width: 1
              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)
                Text {
                  text: "🔍"
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width - Style.space(40)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.storeQuery !== "" ? root.storeQuery
                      : "Type to search " + (root.communityCount || "the") + " community plugins…"
                  textFormat: Text.PlainText
                  color: root.storeQuery !== "" ? root.foreground : root.fainter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  clip: true
                }
              }
            }

            Flickable {
              width: parent.width
              height: parent.height - Style.space(40)
              contentHeight: storeCol.height
              clip: true
              Column {
                id: storeCol
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.storeFiltered
                  delegate: StoreRow { width: storeCol.width; cData: modelData }
                }
                Item {
                  visible: !root.catalogLoaded
                  width: parent.width; height: Style.space(60)
                  Text {
                    anchors.centerIn: parent
                    text: root.busy ? "Fetching catalog…" : "Catalog not loaded."
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }

          // ===== SETTINGS =====
          SettingsView {
            visible: root.tab === "settings"
            anchors.fill: parent
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // -------- footer
        Item {
          id: footer
          width: parent.width
          height: Style.space(16)
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.noticeText !== "" ? root.noticeText
                : root.reviewId !== "" ? "Enter apply · Esc back"
                : root.tab === "installed" ? "↑↓ move · Enter review/toggle · x remove · Tab switch view · Esc close"
                : root.tab === "store" ? "type to search · Tab switch view · Esc clear/close"
                : "Tab switch view · Esc close"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width - Style.space(120)
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.busy
            text: root.busyNote
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ================================================================= components
  component SectionHeader: Item {
    property string label: ""
    property int count: 0
    property bool expanded: true
    signal toggled()
    width: parent ? parent.width : 0
    height: Style.space(28)
    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      Text {
        text: parent.parent.expanded ? "▾" : "▸"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: parent.parent.label + " (" + parent.parent.count + ")"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1; color: root.hairline
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.toggled()
    }
  }

  component TabButton: Rectangle {
    property string label: ""
    property bool active: false
    signal pickedT()
    width: tbl.implicitWidth + Style.space(20)
    height: Style.space(24)
    radius: root.cornerRadius
    color: active ? root.selBg : "transparent"
    Text {
      id: tbl
      anchors.centerIn: parent
      text: parent.label
      textFormat: Text.PlainText
      color: parent.active ? root.selText : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: parent.active
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.pickedT() }
  }

  component PlugButton: Rectangle {
    property string label: ""
    property bool danger: false
    signal picked()
    width: pbl.implicitWidth + Style.space(20)
    height: Style.space(26)
    radius: root.cornerRadius
    color: hov.containsMouse
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
    border.color: danger ? root.dangerColor : root.hairline
    border.width: 1
    Text {
      id: pbl
      anchors.centerIn: parent
      text: parent.label
      textFormat: Text.PlainText
      color: parent.danger ? root.dangerColor : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.picked() }
  }

  // Compact row, sized for two-up. The wide action buttons are gone: the
  // amber UPDATE badge is itself the review trigger, the LOCKED badge unlocks,
  // and enable/remove sit in a small control cluster on the right — so two
  // rows fit across the card instead of one tall row wasting the width.
  component InstalledRow: Rectangle {
    property var rowData: null
    property bool confirming: false
    property bool selected: false
    height: Style.space(48)
    radius: root.cornerRadius
    color: selected ? root.selBg
      : rowHover.containsMouse
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
        : "transparent"
    border.color: selected ? root.accent
      : rowData && rowData.updateAvailable ? Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.5)
      : root.hairline
    border.width: selected ? Math.max(1, Style.space(1)) : 1
    opacity: rowData && rowData.locked ? 0.85 : 1
    MouseArea { id: rowHover; anchors.fill: parent; hoverEnabled: true }

    // controls on the right; text fills the space that is left.
    Row {
      id: controls
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)

      // on/off toggle (compact)
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(56); height: Style.space(22)
        radius: height / 2
        color: "transparent"
        border.color: root.hairline; border.width: 1
        Row {
          anchors.fill: parent
          Rectangle {
            width: parent.width / 2; height: parent.height; radius: height / 2
            color: rowData && rowData.enabled ? root.okColor : "transparent"
            Text { anchors.centerIn: parent; text: "on"; textFormat: Text.PlainText; color: rowData && rowData.enabled ? "#0a1a0e" : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (rowData && !rowData.enabled) root.setEnabled(rowData.id, true) }
          }
          Rectangle {
            width: parent.width / 2; height: parent.height; radius: height / 2
            color: rowData && !rowData.enabled ? root.fainter : "transparent"
            Text { anchors.centerIn: parent; text: "off"; textFormat: Text.PlainText; color: rowData && !rowData.enabled ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (rowData && rowData.enabled && rowData.canDisable) root.setEnabled(rowData.id, false) }
          }
        }
      }
      // revert (recently updated) — small, only when relevant
      Rectangle {
        visible: rowData && rowData.canRevert && !rowData.updateAvailable && !rowData.official
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22); height: Style.space(22); radius: height / 2
        color: rvHover.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
        border.color: root.hairline; border.width: 1
        Text { anchors.centerIn: parent; text: "↺"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        MouseArea { id: rvHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.revert(rowData.id) }
      }
      // remove — community only; compact ×, arms to a red confirm.
      Rectangle {
        visible: !(rowData && rowData.official)
        anchors.verticalCenter: parent.verticalCenter
        width: confirming ? Style.space(46) : Style.space(22); height: Style.space(22)
        radius: height / 2
        color: confirming ? root.dangerColor : (rmHover.containsMouse ? Qt.rgba(root.dangerColor.r, root.dangerColor.g, root.dangerColor.b, 0.15) : "transparent")
        border.color: root.dangerColor; border.width: 1
        Text { anchors.centerIn: parent; text: confirming ? "sure?" : "✕"; textFormat: Text.PlainText; color: confirming ? "#1a1005" : root.dangerColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: confirming }
        MouseArea {
          id: rmHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.confirmRemoveId === rowData.id) root.removeConfirmed(rowData.id)
            else root.askRemove(rowData.id)
          }
        }
      }
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: controls.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      // trust dot — community plugins only; official ones are not scanned.
      Rectangle {
        visible: !(rowData && rowData.official)
        width: Style.space(9); height: Style.space(9); radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: rowData && rowData.trustScore >= 0 ? root.trustColor(rowData.trustScore) : root.fainter
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)
        width: parent.width - Style.space(20)
        Row {
          spacing: Style.space(6)
          width: parent.width
          Text {
            text: rowData ? rowData.name : ""
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width - badges.width - Style.space(6))
          }
          Row {
            id: badges
            spacing: Style.space(5)
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
              visible: rowData && rowData.official
              width: ofb.implicitWidth + Style.space(10); height: Style.space(16); radius: height / 2
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
              Text { id: ofb; anchors.centerIn: parent; text: "OFFICIAL"; textFormat: Text.PlainText; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 2; font.bold: true }
            }
            // THE update flag — clickable: it opens the review.
            Rectangle {
              visible: rowData && rowData.updateAvailable
              width: upl.implicitWidth + Style.space(10); height: Style.space(16); radius: height / 2
              color: root.warnColor
              Text { id: upl; anchors.centerIn: parent; text: "UPDATE"; textFormat: Text.PlainText; color: "#1a1005"; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 2; font.bold: true }
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: if (rowData && !rowData.locked) root.startReview(rowData.id)
              }
            }
            // LOCKED badge — clickable: it unlocks.
            Rectangle {
              visible: rowData && rowData.locked
              width: lkl.implicitWidth + Style.space(10); height: Style.space(16); radius: height / 2
              color: "transparent"; border.color: root.fainter; border.width: 1
              Text { id: lkl; anchors.centerIn: parent; text: "LOCKED"; textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 2 }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleLock(rowData.id, false) }
            }
          }
        }
        Text {
          width: parent.width
          text: !rowData ? "" : confirming ? "remove this plugin?"
              : rowData.official ? (rowData.kinds || "built-in")
              : rowData.updateAvailable ? (rowData.commitsBehind + " new change" + (rowData.commitsBehind === 1 ? "" : "s") + " · click UPDATE to review")
              : (rowData.id + (rowData.kinds ? " · " + rowData.kinds : ""))
          textFormat: Text.PlainText
          color: confirming ? root.dangerColor : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component StoreRow: Rectangle {
    property var cData: null
    readonly property bool installed: cData && root.installedIdSet[cData.id] === true
    height: Style.space(58)
    radius: root.cornerRadius
    color: sHover.containsMouse
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
      : "transparent"
    border.color: root.hairline; border.width: 1
    MouseArea { id: sHover; anchors.fill: parent; hoverEnabled: true }
    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      Rectangle {
        width: Style.space(38); height: Style.space(38); radius: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        color: root.accent
        Text { anchors.centerIn: parent; text: cData ? (cData.initials || cData.name.slice(0, 2).toUpperCase()) : ""; textFormat: Text.PlainText; color: "#0a0a0a"; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Row {
          spacing: Style.space(6)
          Text { text: cData ? cData.name : ""; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          // Omarchy's own — clearly marked, and never installed or managed here.
          Rectangle {
            visible: cData && cData.official
            anchors.verticalCenter: parent.verticalCenter
            width: ofl.implicitWidth + Style.space(10); height: Style.space(15); radius: height / 2
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
            Text { id: ofl; anchors.centerIn: parent; text: "OFFICIAL"; textFormat: Text.PlainText; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1; font.bold: true }
          }
          Rectangle {
            visible: cData && !cData.official && cData.verificationStatus === "verified"
            anchors.verticalCenter: parent.verticalCenter
            width: vfl.implicitWidth + Style.space(10); height: Style.space(15); radius: height / 2
            color: Qt.rgba(root.okColor.r, root.okColor.g, root.okColor.b, 0.2)
            Text { id: vfl; anchors.centerIn: parent; text: "✓ verified"; textFormat: Text.PlainText; color: root.okColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1 }
          }
        }
        Text {
          text: cData ? ((cData.author ? "by " + cData.author + "  ·  " : "") + cData.description) : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: card.width - Style.space(200)
        }
      }
    }
    // Official plugins are built in (managed by the shell) — shown for
    // discovery, never installed from here. Community manual-setup plugins
    // cannot be one-click installed either. Everything else installs.
    PlugButton {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      label: cData && cData.official ? "built in"
           : parent.installed ? "installed"
           : (cData && cData.installAvailable) ? "install" : "manual setup"
      onPicked: if (cData && !cData.official && !parent.installed && cData.installAvailable)
                  root.installFromStore(cData)
    }
  }

  component ReviewView: Item {
    Column {
      anchors.fill: parent
      spacing: Style.space(12)
      Row {
        width: parent.width
        spacing: Style.space(10)
        PlugButton { label: "‹ back"; onPicked: root.cancelReview() }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Review: " + root.reviewId
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          width: card.width - Style.space(140)
        }
      }

      // running spinner-ish
      Item {
        visible: root.reviewRunning
        width: parent.width; height: Style.space(80)
        Text {
          anchors.centerIn: parent
          text: (root.settings.reviewAgent === "none" ? "Scanning the changes…" :
                 "Asking " + root.settings.reviewAgent + " to read the changes…")
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      // verdict
      Column {
        visible: !root.reviewRunning && root.reviewData !== null
        width: parent.width
        spacing: Style.space(10)
        Rectangle {
          width: parent.width
          height: verdictCol.height + Style.space(24)
          radius: root.cornerRadius
          color: {
            var v = root.reviewData ? root.reviewData.review.verdict : "UNKNOWN"
            var c = root.verdictColor(v)
            return Qt.rgba(c.r, c.g, c.b, 0.12)
          }
          border.width: 1
          border.color: {
            var v = root.reviewData ? root.reviewData.review.verdict : "UNKNOWN"
            return root.verdictColor(v)
          }
          Column {
            id: verdictCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(6)
            Row {
              spacing: Style.space(10)
              Rectangle {
                width: Style.space(16); height: Style.space(16); radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: root.reviewData ? root.verdictColor(root.reviewData.review.verdict) : root.fainter
              }
              Text {
                text: {
                  if (!root.reviewData) return ""
                  var v = root.reviewData.review.verdict
                  return v === "SAFE" ? "Safe to update"
                       : v === "CAUTION" ? "Be careful"
                       : v === "DANGER" ? "Do not update" : "Unclear"
                }
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                visible: root.reviewData && root.reviewData.review.agent && root.reviewData.review.agent !== "none"
                text: root.reviewData ? "reviewed by " + root.reviewData.review.agent : ""
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            Text {
              width: parent.width
              text: root.reviewData ? root.reviewData.review.headline : ""
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Text {
          text: "What changed"
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Column {
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            model: root.reviewData ? root.reviewData.review.whatChanged : []
            delegate: Text {
              width: card.width - Style.space(60)
              text: "•  " + modelData
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }
        Text {
          visible: root.reviewData && root.reviewData.review.watchFor && root.reviewData.review.watchFor !== "nothing notable"
          width: card.width - Style.space(60)
          text: root.reviewData ? "⚠  " + root.reviewData.review.watchFor : ""
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.warnColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // The author's own words for the change, next to the AI's read.
        Text {
          visible: root.reviewData && root.reviewData.changelog && root.reviewData.changelog.length > 0
          text: "The author's notes"
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Column {
          visible: root.reviewData && root.reviewData.changelog && root.reviewData.changelog.length > 0
          width: parent.width
          spacing: Style.space(2)
          Repeater {
            model: root.reviewData ? root.reviewData.changelog : []
            delegate: Text {
              width: card.width - Style.space(60)
              text: "·  " + modelData
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          spacing: Style.space(8)
          PlugButton { label: "Apply update"; onPicked: root.approveUpdate() }
          PlugButton { label: "Not now"; onPicked: root.cancelReview() }
          PlugButton { label: "Lock at current version"; onPicked: { root.toggleLock(root.reviewId, true); root.cancelReview() } }
        }
      }
    }
  }

  component SettingsView: Item {
    Flickable {
      anchors.fill: parent
      contentHeight: setCol.height
      clip: true
      Column {
        id: setCol
        width: parent.width
        spacing: Style.space(16)

        // AI reviewer
        Column {
          width: parent.width
          spacing: Style.space(6)
          Text { text: "Who reviews updates"; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Text {
            width: card.width - Style.space(60)
            text: "When an update is waiting, this is who reads the changes and tells you in plain English whether it is safe. It only ever reads — it can never change the plugin or your machine."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            spacing: Style.space(6)
            Repeater {
              model: {
                var opts = []
                for (var i = 0; i < root.availableAgents.length; i++) opts.push(root.availableAgents[i])
                opts.push({ key: "none", label: "Just the offline scan" })
                return opts
              }
              delegate: Rectangle {
                width: agl.implicitWidth + Style.space(20); height: Style.space(28); radius: root.cornerRadius
                color: root.settings.reviewAgent === modelData.key ? root.selBg : "transparent"
                border.color: root.hairline; border.width: 1
                Text { id: agl; anchors.centerIn: parent; text: modelData.label; textFormat: Text.PlainText; color: root.settings.reviewAgent === modelData.key ? root.selText : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setAgent(modelData.key) }
              }
            }
          }
          // model, when the chosen agent has choices
          Row {
            visible: {
              for (var i = 0; i < root.availableAgents.length; i++)
                if (root.availableAgents[i].key === root.settings.reviewAgent) return root.availableAgents[i].models.length > 1
              return false
            }
            spacing: Style.space(6)
            Text { text: "model:"; textFormat: Text.PlainText; color: root.dim; anchors.verticalCenter: parent.verticalCenter; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Repeater {
              model: {
                for (var i = 0; i < root.availableAgents.length; i++)
                  if (root.availableAgents[i].key === root.settings.reviewAgent) return root.availableAgents[i].models
                return []
              }
              delegate: Rectangle {
                width: mdl.implicitWidth + Style.space(16); height: Style.space(24); radius: root.cornerRadius
                color: root.settings.reviewModel === modelData ? root.selBg : "transparent"
                border.color: root.hairline; border.width: 1
                Text { id: mdl; anchors.centerIn: parent; text: modelData; textFormat: Text.PlainText; color: root.settings.reviewModel === modelData ? root.selText : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setModel(modelData) }
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // Hotkey
        Column {
          width: parent.width
          spacing: Style.space(6)
          Text { text: "Hotkey"; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Row {
            spacing: Style.space(8)
            Rectangle {
              width: Style.space(180); height: Style.space(30); radius: root.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
              border.color: root.capturing ? root.accent : root.hairline; border.width: 1
              Text {
                anchors.centerIn: parent
                text: root.capturing ? "press keys…" : (root.settings.shortcut || "no hotkey set")
                textFormat: Text.PlainText
                color: root.capturing ? root.accent : (root.settings.shortcut ? root.foreground : root.fainter)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.capturing = true; root.captureNote = "" } }
            }
            PlugButton { label: "clear"; onPicked: root.clearHotkey() }
          }
          Text {
            visible: root.captureNote !== ""
            text: root.captureNote
            textFormat: Text.PlainText
            color: root.warnColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            width: card.width - Style.space(60)
            text: "Off by default — Plug opens from the bar icon or a terminal without one. If you set a hotkey, Plug checks every shortcut Hyprland is actually using (including Omarchy's own, which are not in bindings.lua) and refuses a combination that is already taken."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // Bar icon
        Column {
          width: parent.width
          spacing: Style.space(6)
          Text { text: "Bar icon"; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Row {
            spacing: Style.space(8)
            PlugButton { label: "show in bar"; onPicked: Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "bar", "on", "right"]) }
            PlugButton { label: "hide from bar"; onPicked: Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "bar", "off"]) }
          }
        }
      }
    }
  }
}
