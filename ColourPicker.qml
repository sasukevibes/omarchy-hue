import QtQuick
import qs.Commons
import qs.Ui

// A full hue/saturation spectrum picker, used anywhere the fixed 6-swatch
// palette (HueControls.swatches) is too limiting — free colour choice for a
// room or single light, and building a custom 4-6 colour light show palette.
// Hue/saturation are on the bridge's native 0-65535/0-254 scale, matching
// what hue.py's `colour`/`light-colour`/`lightshow-start` commands accept.
Column {
  id: root

  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property int hue: 0
  property int sat: 254
  // Light show colours are stored (and always rendered) at full saturation,
  // so that picker skips the saturation lane entirely — it would otherwise
  // promise a pastel that the show never actually plays.
  property bool showSaturation: true
  // Room/light pickers apply live as sliders are released (matches the
  // brightness slider elsewhere in this file). The light show picker instead
  // stages a colour and only commits it when "Add colour" is pressed, so
  // scrubbing the hue bar doesn't spam the palette.
  property bool autoCommit: true
  property string confirmLabel: "Add colour"
  property bool confirmEnabled: true

  signal committed(int hue, int sat)

  function buildHueStops() {
    var s = []
    for (var i = 0; i <= 6; i++) s.push(Qt.hsva(i / 6, 1, 1, 1))
    return s
  }
  readonly property var hueStops: buildHueStops()
  readonly property var satStops: [Qt.hsva(root.hue / 65535, 0, 1, 1), Qt.hsva(root.hue / 65535, 1, 1, 1)]

  spacing: Style.spacing.sm

  Row {
    spacing: Style.spacing.sm

    Rectangle {
      width: Style.space(28)
      height: width
      radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      color: Qt.hsva(root.hue / 65535, root.showSaturation ? root.sat / 254 : 1.0, 1.0, 1.0)
      border.width: 1
      border.color: root.foreground
    }

    Text {
      text: "Hue"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  SpectrumSlider {
    width: parent.width
    foreground: root.foreground
    stops: root.hueStops
    minimum: 0
    maximum: 65535
    integer: true
    value: root.hue
    onMoved: function(v) { root.hue = v }
    onReleased: function(v) {
      root.hue = v
      if (root.autoCommit) root.committed(root.hue, root.sat)
    }
  }

  Text {
    visible: root.showSaturation
    text: "Saturation"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  SpectrumSlider {
    visible: root.showSaturation
    width: parent.width
    foreground: root.foreground
    stops: root.satStops
    minimum: 0
    maximum: 254
    integer: true
    value: root.sat
    onMoved: function(v) { root.sat = v }
    onReleased: function(v) {
      root.sat = v
      if (root.autoCommit) root.committed(root.hue, root.sat)
    }
  }

  Button {
    visible: !root.autoCommit
    width: parent.width
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    text: root.confirmLabel
    enabled: root.confirmEnabled
    onClicked: root.committed(root.hue, root.sat)
  }
}
