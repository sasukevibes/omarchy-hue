import QtQuick
import qs.Commons
import qs.Ui

// A horizontal gradient slider — same press/drag/release contract as the
// shared PanelSlider, but painted from a list of colour stops instead of a
// flat trackColor. Plain QtQuick Rectangles only render vertical gradients,
// so the bar is approximated with many thin solid slices rather than a real
// linear gradient; at slice-count 48 the banding isn't visible in practice.
Item {
  id: root

  property color foreground: Color.foreground
  property var stops: [Color.foreground, Color.foreground]
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property bool integer: false
  property bool dragging: false
  property real liveValue: value
  property int sliceCount: 48
  property real trackHeight: Math.max(10, Math.round(Style.spacing.controlHeight * 0.4))
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.5))

  onValueChanged: if (!dragging) liveValue = value

  signal moved(real value)
  signal released(real value)

  implicitWidth: Style.space(200)
  implicitHeight: knobSize + Style.spacing.sm

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))

  function mix(a, b, f) {
    return Qt.rgba(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 1)
  }
  function colorAt(t) {
    var s = root.stops
    if (!s || s.length === 0) return root.foreground
    if (s.length === 1) return s[0]
    var scaled = Math.max(0, Math.min(1, t)) * (s.length - 1)
    var lo = Math.floor(scaled)
    var hi = Math.min(s.length - 1, lo + 1)
    return mix(s[lo], s[hi], scaled - lo)
  }

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    height: root.trackHeight
    radius: height / 2
    clip: true

    Row {
      anchors.fill: parent
      Repeater {
        model: root.sliceCount
        Rectangle {
          required property int index
          width: track.width / root.sliceCount
          height: track.height
          color: root.colorAt(index / (root.sliceCount - 1))
        }
      }
    }
  }

  BorderSurface {
    id: knob
    width: root.knobSize
    height: root.knobSize
    radius: root.knobSize / 2
    color: root.colorAt(root.progress)
    borderSpec: Border.flat(root.foreground, Math.max(1, Style.space(2)))
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progress - width / 2))
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    function valueFromX(x) {
      var clamped = Math.max(0, Math.min(track.width, x))
      var raw = root.minimum + (clamped / track.width) * root.range
      if (root.integer) raw = Math.round(raw)
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    onPressed: function(mouse) {
      root.dragging = true
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }
    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }
    onReleased: function(mouse) {
      root.dragging = false
      root.released(root.liveValue)
      root.liveValue = root.value
    }
  }
}
