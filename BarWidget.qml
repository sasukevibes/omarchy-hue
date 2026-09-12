import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ashton.hue"

  readonly property bool windowOpen: panelLoader.item ? panelLoader.item.windowOpen === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }
  function openWindow() { if (panelLoader.item) panelLoader.item.windowOpen = true }
  function closeWindow() { if (panelLoader.item) panelLoader.item.closeWindow() }
  function toggleWindow() { if (panelLoader.item) panelLoader.item.toggleWindow() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: true

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Both the bar button and the keyboard shortcut drive the same floating
  // window — there is no anchored popover anymore, so "open"/"toggle" mean
  // "show the window" (matching the Sonos/Omacalc style floating app).
  IpcHandler {
    target: "ashton.hue"
    function open(): void { root.openWindow() }
    function close(): void { root.closeWindow() }
    function toggle(): void { root.toggleWindow() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "HUE"
    fontSize: Style.font.caption
    horizontalMargin: 6
    tooltipText: "Philips Hue"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton && panelLoader.item) panelLoader.item.refresh()
      else root.toggleWindow()
    }
  }
}
