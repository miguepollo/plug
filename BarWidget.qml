import QtQuick
import qs.Commons
import qs.Ui as Ui
import "."

// Bar icon for Plug: a plug glyph that opens the panel, with a small badge
// showing how many plugin updates are waiting. The glyph is a Nerd Font icon
// rather than an emoji, so it takes the theme's foreground like every other
// bar icon instead of rendering as a fixed-colour bitmap.
//
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — a bare `BarWidget` would resolve to the file itself.)
Ui.BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.plug"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property int updateCount: PlugState.updateCount
  readonly property bool opened: PlugState.overlay ? PlugState.overlay.opened === true : false

  // Clicking runs the same shell toggle route the panel is summoned by. This
  // works even before the panel has ever been opened — the shell instantiates
  // it — whereas calling the panel object directly would do nothing on a fresh
  // install, because that object does not exist until the panel first loads.
  function toggle() { root.bar.run("omarchy-shell shell toggle io.github.weedwhitesandwine.plug") }
  function open() { root.toggle() }
  function close() { root.toggle() }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-plug (U+F1E6) — a plug, themed like the rest of the bar.
    text: ""
    tooltipText: root.updateCount > 0
      ? ("Plug — " + root.updateCount + " update" + (root.updateCount === 1 ? "" : "s") + " waiting")
      : "Plug"
    onPressed: function(b) { root.toggle() }
  }

  // The update badge — a small dot with a count, only when something is
  // waiting. Fixed amber so it reads as "attention" on every theme.
  Rectangle {
    visible: root.updateCount > 0
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(1)
    anchors.rightMargin: Style.space(1)
    width: Math.max(Style.space(13), badge.implicitWidth + Style.space(6))
    height: Style.space(13)
    radius: height / 2
    color: "#d29922"
    Text {
      id: badge
      anchors.centerIn: parent
      text: root.updateCount > 9 ? "9+" : String(root.updateCount)
      textFormat: Text.PlainText
      color: "#1a1005"
      font.pixelSize: Style.font.caption - 2
      font.bold: true
    }
  }
}
