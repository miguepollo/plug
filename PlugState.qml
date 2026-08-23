pragma Singleton
import QtQuick

// Shared handle so the bar widget and the panel can find each other: the
// widget forwards summon/toggle to the panel, and reads the panel's update
// count to badge its icon.
QtObject {
  property var overlay: null
  property int updateCount: 0
}
