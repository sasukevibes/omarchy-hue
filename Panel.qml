import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ashton.hue"
  ipcTarget: "ashton.hue"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool windowOpen: false
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function toggleWindow() { windowOpen = !windowOpen }
  function closeWindow() { windowOpen = false }
  function refresh() { controls.refresh() }

  // A normal desktop window, like Omacalc — the bar button and the
  // keyboard shortcut both toggle this rather than an anchored popover.
  FloatingWindow {
    id: window
    visible: root.windowOpen
    title: "Philips Hue"
    color: Color.background
    implicitWidth: Style.space(480)
    implicitHeight: Style.space(700)
    minimumSize: Qt.size(Style.space(380), Style.space(480))
    onVisibleChanged: if (!visible) root.windowOpen = false

    BorderSurface {
      anchors.fill: parent
      color: Color.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.border, Math.max(1, Style.normalBorderWidth))
      radius: Style.cornerRadius

      HueControls {
        id: controls
        anchors.fill: parent
        anchors.margins: Style.space(16)
        active: window.visible
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCloseRequested: root.closeWindow()
      }
    }
  }
}
