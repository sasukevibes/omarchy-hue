import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root
  property bool active: false
  property var model: ({ paired: false, bridges: [], rooms: [],
                         ambient: ({ active: false, room: "", monitor: "all" }),
                         lightshow: ({ active: false, rooms: [], colors: [] }) })
  property bool busy: false
  property string errorText: ""
  property string selectedRoomId: ""
  property string selectedLightId: ""
  property var monitorList: []
  // Local UI state for the monitor picker before ambient mode is switched
  // on — there's one ambient session at a time, so once it's active the
  // daemon's own reported monitor (in model.ambient) takes over as truth.
  property string pendingMonitor: "all"
  // Locally-picked light show rooms/palette before the show is started —
  // mirrors pendingMonitor's role for ambient mode. A show spans every
  // selected room's lights as one combined pool (see toggleLightshowRun),
  // so once active the daemon's own reported rooms/colours (in
  // model.lightshow) take over as truth.
  property var pendingLightshowRooms: []
  property var pendingLightshowColors: []
  // Set when Start is pressed without a valid room/colour selection yet —
  // a disabled button that just does nothing on click was confusing, so
  // instead the button always responds and explains what's missing.
  property string lightshowWarning: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property var selectedRoom: roomById(selectedRoomId)
  readonly property var swatches: [
    { h: 0, c: "#ff595e" }, { h: 8000, c: "#ffca3a" }, { h: 22000, c: "#8ac926" },
    { h: 33000, c: "#36d7e8" }, { h: 45000, c: "#5b7cfa" }, { h: 54000, c: "#c05cff" }
  ]
  signal closeRequested()
  implicitHeight: content.implicitHeight

  // ------------------------------------------------------------- data plumbing
  function run(args) {
    if (proc.running) return
    busy = true
    errorText = ""
    proc.command = ["python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/ashton.hue/hue.py"].concat(args)
    proc.running = true
  }
  function refresh() { run(["status"]) }
  function fetchMonitors() {
    if (monitorsProc.running) return
    monitorsProc.command = ["python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/ashton.hue/hue.py", "monitors"]
    monitorsProc.running = true
  }
  function ambientActive(room) {
    var amb = root.model.ambient
    return !!room && !!amb && amb.active === true && String(amb.room) === String(room.id)
  }
  function ambientMonitor() {
    var amb = root.model.ambient
    return (amb && amb.active) ? (amb.monitor || "all") : root.pendingMonitor
  }
  function ambientHint(room) {
    if (!room) return ""
    var amb = root.model.ambient || {}
    if (amb.error) return amb.error
    if (root.ambientActive(room))
      return "Following " + (amb.monitor === "all" ? "all monitors" : amb.monitor) + " · brightens with audio"
    return "Colours this room to match your screen and pulses with audio"
  }
  function monitorOptions() {
    var opts = [{ value: "all", label: "All monitors" }]
    var list = root.monitorList || []
    for (var i = 0; i < list.length; i++) opts.push({ value: list[i], label: list[i] })
    return opts
  }
  function toggleAmbient(room) {
    if (!room) return
    if (root.ambientActive(room)) run(["ambient-stop"])
    else run(["ambient-start", String(room.id), "--monitor", root.pendingMonitor])
  }
  function setAmbientMonitor(room, monitor) {
    root.pendingMonitor = monitor
    if (room && root.ambientActive(room)) run(["ambient-start", String(room.id), "--monitor", monitor])
  }
  function lightshowIsActive() {
    return !!(root.model.lightshow && root.model.lightshow.active === true)
  }
  function lightshowRooms() {
    var ls = root.model.lightshow
    if (root.lightshowIsActive()) return (ls.rooms || []).map(String)
    return root.pendingLightshowRooms
  }
  function lightshowColorsSel() {
    var ls = root.model.lightshow
    if (root.lightshowIsActive()) return ls.colors || []
    return root.pendingLightshowColors
  }
  function lightshowRoomName(id) {
    var room = root.roomById(id)
    return room ? room.name : id
  }
  function setLightshowRooms(values) {
    root.pendingLightshowRooms = values || []
    root.lightshowWarning = ""
    var colors = root.lightshowColorsSel()
    if (root.lightshowIsActive() && root.pendingLightshowRooms.length >= 1 && colors.length >= 4 && colors.length <= 6)
      run(["lightshow-start", "--rooms", root.pendingLightshowRooms.join(","), "--colors", colors.join(",")])
  }
  function toggleLightshowColor(hue) {
    var current = root.lightshowColorsSel().slice()
    var idx = current.indexOf(hue)
    if (idx >= 0) current.splice(idx, 1)
    else if (current.length < 6) current.push(hue)
    root.pendingLightshowColors = current
    root.lightshowWarning = ""
    var rooms = root.lightshowRooms()
    if (root.lightshowIsActive() && rooms.length >= 1 && current.length >= 4 && current.length <= 6)
      run(["lightshow-start", "--rooms", rooms.join(","), "--colors", current.join(",")])
  }
  function lightshowHint() {
    var ls = root.model.lightshow || {}
    if (ls.error) return ls.error
    if (root.lightshowIsActive()) {
      var roomNames = (ls.rooms || []).map(function(id) { return root.lightshowRoomName(id) }).join(", ")
      return "Cycling " + (ls.colors || []).length + " colours across " + roomNames + " · one light drives the bass, others react to mid/treble"
    }
    return root.lightshowRooms().length + " room(s), " + root.lightshowColorsSel().length + " of 4-6 colours picked"
  }
  function toggleLightshowRun() {
    if (root.lightshowIsActive()) { run(["lightshow-stop"]); root.lightshowWarning = ""; return }
    var rooms = root.lightshowRooms()
    var colors = root.lightshowColorsSel()
    if (rooms.length < 1) { root.lightshowWarning = "Pick at least one room first"; return }
    if (colors.length < 4) { root.lightshowWarning = "Pick at least 4 colours first — only " + colors.length + " picked so far"; return }
    if (colors.length > 6) { root.lightshowWarning = "Pick at most 6 colours"; return }
    root.lightshowWarning = ""
    run(["lightshow-start", "--rooms", rooms.join(","), "--colors", colors.join(",")])
  }
  function roomById(id) {
    var rooms = model.rooms || []
    for (var i = 0; i < rooms.length; i++)
      if (String(rooms[i].id) === String(id)) return rooms[i]
    return null
  }
  function lightById(id) {
    var rooms = model.rooms || []
    for (var r = 0; r < rooms.length; r++) {
      var lights = rooms[r].lights || []
      for (var i = 0; i < lights.length; i++)
        if (String(lights[i].id) === String(id)) return lights[i]
    }
    return null
  }
  function selectRoom(room) {
    selectedRoomId = room ? String(room.id) : ""
    selectedLightId = ""
    cursorIndex = room ? -1 : 0
    cursorActive = true
    lightshowWarning = ""
  }
  function selectLight(light) {
    var key = light ? String(light.id) : ""
    selectedLightId = selectedLightId === key ? "" : key
  }
  function roomSubtitle(room) {
    if (!room.on) return "Off"
    var lightCount = (room.lights || []).length
    var pct = Math.round((room.brightness || 0) / 254 * 100)
    return lightCount === 1 ? ("On · " + pct + "%") : (lightCount + " lights · " + pct + "%")
  }
  function roomPower(room) { run(["power", String(room.id), room.on ? "off" : "on"]) }
  function roomBrightness(room, value) { run(["brightness", String(room.id), String(Math.round(value))]) }
  function roomColour(room, hue) { run(["colour", String(room.id), String(hue), "220"]) }
  function activateScene(room, scene) { run(["scene", String(room.id), String(scene.id)]) }
  function lightPower(light) { run(["light-power", String(light.id), light.on ? "off" : "on"]) }
  function lightBrightness(light, value) { run(["light-brightness", String(light.id), String(Math.round(value))]) }
  function lightColour(light, hue) { run(["light-colour", String(light.id), String(hue), "220"]) }

  // ------------------------------------------------------------- keyboard cursor
  // One flat list at a time: rooms (room list view) or lights (room detail
  // view, where index -1 is the room-wide controls row). j/k or Up/Down move
  // the cursor; h/l or Left/Right nudge brightness directly — no separate
  // "grab the slider" step. Space toggles power, 1-6 apply a colour swatch,
  // Enter drills into a room, Escape steps back out then closes.
  property int cursorIndex: 0
  property bool cursorActive: true
  property bool _enterConsumed: false

  function cursorFloor() { return root.selectedRoom ? -1 : 0 }
  function cursorCount() {
    return root.selectedRoom ? (root.selectedRoom.lights || []).length : (root.model.rooms || []).length
  }
  function moveCursor(dy) {
    var floor = root.cursorFloor()
    var max = root.cursorCount() - 1
    if (max < floor) { root.cursorIndex = floor; root.cursorActive = true; return }
    var next = Math.max(floor, Math.min(max, root.cursorIndex + dy))
    root.cursorIndex = next
    root.cursorActive = true
    root.syncExpandFromCursor()
  }
  function syncExpandFromCursor() {
    if (!root.selectedRoom) return
    if (root.cursorIndex < 0) { root.selectedLightId = ""; return }
    var light = (root.selectedRoom.lights || [])[root.cursorIndex]
    root.selectedLightId = light ? String(light.id) : ""
  }
  function focusedRoom() {
    if (root.selectedRoom) return root.selectedRoom
    return (root.model.rooms || [])[root.cursorIndex] || null
  }
  function focusedLight() {
    if (!root.selectedRoom || root.cursorIndex < 0) return null
    return (root.selectedRoom.lights || [])[root.cursorIndex] || null
  }
  function clampBri(v) { return Math.max(1, Math.min(254, Math.round(v))) }
  function cursorTogglePower() {
    var light = root.focusedLight()
    if (light) { root.lightPower(light); return }
    var room = root.focusedRoom()
    if (room) root.roomPower(room)
  }
  function cursorNudgeBrightness(direction) {
    var step = 26
    var light = root.focusedLight()
    if (light) { root.lightBrightness(light, root.clampBri((light.brightness || 1) + direction * step)); return }
    var room = root.focusedRoom()
    if (room) root.roomBrightness(room, root.clampBri((room.brightness || 1) + direction * step))
  }
  function cursorApplyColour(swatchIndex) {
    var swatch = root.swatches[swatchIndex]
    if (!swatch) return
    var light = root.focusedLight()
    if (light) { root.lightColour(light, swatch.h); return }
    var room = root.focusedRoom()
    if (room) root.roomColour(room, swatch.h)
  }
  function handleReturn() {
    root._enterConsumed = true
    if (!root.selectedRoom) {
      var room = root.focusedRoom()
      if (room) root.selectRoom(room)
    }
  }
  function handleActivate() {
    if (root._enterConsumed) { root._enterConsumed = false; return }
    root.cursorTogglePower()
  }
  function handleEscape() {
    if (root.selectedRoom) { root.selectRoom(null); return }
    root.closeRequested()
  }
  function handleTextKey(t) {
    if (t === "r" || t === "R") { root.refresh(); return }
    var n = parseInt(t, 10)
    if (!isNaN(n) && n >= 1 && n <= 6) root.cursorApplyColour(n - 1)
  }
  function ensureCursorVisible(item) {
    if (!item || !flick) return
    var margin = Style.space(6)
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var maxY = Math.max(0, flick.contentHeight - flick.height)
    if (top < viewTop + margin) flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > viewBottom - margin) flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  onActiveChanged: if (active) {
    selectedRoomId = ""
    selectedLightId = ""
    cursorIndex = 0
    cursorActive = true
    refresh()
    fetchMonitors()
    keyCatcher.forceActiveFocus()
  }

  Process {
    id: proc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (parsed.error) root.errorText = parsed.error
          else root.model = parsed
        } catch (e) { root.errorText = "Could not read the Hue response" }
        root.busy = false
      }
    }
    onExited: function() { root.busy = false }
  }

  Process {
    id: monitorsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.monitorList = parsed.monitors || []
        } catch (e) { /* leave the previous list in place */ }
      }
    }
  }

  Timer { interval: 15000; running: root.active && !root.busy; repeat: true; onTriggered: root.refresh() }

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onMoveRequested: function(dx, dy) {
      if (dy !== 0) root.moveCursor(dy)
      else if (dx !== 0) root.cursorNudgeBrightness(dx)
    }
    onReturnRequested: root.handleReturn()
    onActivateRequested: root.handleActivate()
    onCloseRequested: root.handleEscape()
    onTextKey: function(t) { root.handleTextKey(t) }

    Flickable {
      id: flick
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: footer.top
      anchors.bottomMargin: Style.spacing.sm
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.md

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          implicitHeight: Math.max(headerBack.implicitHeight, headerTitle.implicitHeight, headerActions.implicitHeight)

          PanelActionButton {
            id: headerBack
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !!root.selectedRoom
            iconText: "‹"
            fontSize: Style.font.icon
            foreground: root.foreground
            fontFamily: root.fontFamily
            tooltipText: "Back"
            onClicked: root.selectRoom(null)
          }

          Text {
            id: headerTitle
            textFormat: Text.PlainText
            anchors.left: headerBack.visible ? headerBack.right : parent.left
            anchors.leftMargin: headerBack.visible ? Style.space(6) : 0
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (headerBack.visible ? headerBack.width + Style.space(6) : 0) - headerActions.width - Style.space(8)
            text: root.selectedRoom ? root.selectedRoom.name : "Philips Hue"
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelActionButton {
              iconText: "⟳"
              fontSize: Style.font.icon
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: root.busy ? "Refreshing…" : "Refresh"
              enabled: !root.busy
              onClicked: root.refresh()
            }
            PanelActionButton {
              iconText: "×"
              fontSize: Style.font.icon
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: "Close"
              onClicked: root.closeRequested()
            }
          }
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          wrapMode: Text.Wrap
          text: root.errorText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // ------------------------------------------------------------ pairing
        Column {
          visible: root.model.paired !== true
          width: parent.width
          spacing: Style.spacing.md

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.model.message || "Looking for a bridge on this network…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Repeater {
            model: root.model.bridges || []
            Button {
              required property var modelData
              width: parent.width
              bordered: true
              leftAlign: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Pair with " + modelData.name + "  ·  " + modelData.ip
              enabled: !root.busy
              onClicked: root.run(["pair", modelData.ip])
            }
          }
          Text {
            visible: (root.model.bridges || []).length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: "Make sure this computer is on the same network as the bridge, then refresh."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ------------------------------------------------------------ room list
        Column {
          visible: root.model.paired === true && !root.selectedRoom
          width: parent.width
          spacing: Style.space(8)

          Text {
            visible: (root.model.rooms || []).length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: "No Hue rooms found."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.model.rooms || []
            RoomRow {
              required property var modelData
              required property int index
              width: content.width
              room: modelData
              rowIndex: index
            }
          }
        }

        // ------------------------------------------------------------ light show
        // Lives at the room-list level, not inside a single room's detail
        // view: a show spans every selected room's lights as one combined
        // pool (so a 3-light room plus a 2-light room is a single 5-light
        // wave, not two separate groups), which only makes sense as a
        // cross-room picker rather than something scoped to one room.
        Column {
          visible: root.model.paired === true && !root.selectedRoom && (root.model.rooms || []).length > 0
          width: parent.width
          spacing: Style.spacing.sm

          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader { text: "LIGHT SHOW"; foreground: root.foreground; fontFamily: root.fontFamily }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.lightshowHint()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          MultiSelect {
            width: parent.width
            label: "Rooms"
            noSelectionText: "Pick rooms"
            options: (root.model.rooms || []).map(function(r) { return { value: String(r.id), label: r.name } })
            values: root.lightshowRooms()
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setLightshowRooms(v) }
          }

          Row {
            spacing: Style.space(8)
            Repeater {
              model: root.swatches
              Rectangle {
                required property var modelData
                readonly property bool picked: root.lightshowColorsSel().indexOf(modelData.h) >= 0
                width: Style.space(28)
                height: width
                radius: width / 2
                color: modelData.c
                border.width: picked ? 3 : 1
                border.color: picked ? root.foreground : Qt.darker(root.foreground, 1.5)
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  enabled: !root.busy
                  onClicked: root.toggleLightshowColor(parent.modelData.h)
                }
              }
            }
          }

          Button {
            width: parent.width
            bordered: true
            leftAlign: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            text: root.lightshowIsActive() ? "Stop light show" : "Start light show"
            enabled: !root.busy
            onClicked: root.toggleLightshowRun()
          }
          Text {
            visible: root.lightshowWarning !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: root.lightshowWarning
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ------------------------------------------------------------ room detail
        Column {
          id: roomDetail
          readonly property var room: root.selectedRoom
          visible: !!room
          width: parent.width
          spacing: Style.spacing.lg

          // Whole-room controls — the keyboard cursor's index -1 row.
          CursorSurface {
            id: roomControlsSurface
            width: parent.width
            implicitHeight: roomControlsColumn.implicitHeight + Style.spacing.md * 2
            hasCursor: root.cursorActive && !!roomDetail.room && root.cursorIndex === -1
            foreground: root.foreground
            onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(roomControlsSurface)

            HoverHandler {
              onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursorIndex = -1 }
            }

            Column {
              id: roomControlsColumn
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              spacing: Style.spacing.sm

              Item {
                width: parent.width
                implicitHeight: Math.max(roomPowerLabel.implicitHeight, roomPowerSwitch.implicitHeight)
                Text {
                  id: roomPowerLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: roomDetail.room && roomDetail.room.on ? "All lights on" : "All lights off"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                ToggleSwitch {
                  id: roomPowerSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: !!roomDetail.room && roomDetail.room.on
                  foreground: root.foreground
                  enabled: !!roomDetail.room && !root.busy
                  onToggled: root.roomPower(roomDetail.room)
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm
                Text {
                  text: "Brightness"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                PanelSlider {
                  width: parent.width - x
                  minimum: 1
                  maximum: 254
                  integer: true
                  value: roomDetail.room ? (roomDetail.room.brightness || 1) : 1
                  enabled: !!roomDetail.room && !root.busy
                  onReleased: function(v) { if (roomDetail.room) root.roomBrightness(roomDetail.room, v) }
                }
              }

              Row {
                spacing: Style.space(8)
                Text {
                  text: "Colour"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Repeater {
                  model: root.swatches
                  Rectangle {
                    required property var modelData
                    width: Style.space(24)
                    height: width
                    radius: width / 2
                    color: modelData.c
                    border.width: 1
                    border.color: root.foreground
                    MouseArea {
                      anchors.fill: parent
                      enabled: !!roomDetail.room && !root.busy
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.roomColour(roomDetail.room, parent.modelData.h)
                    }
                  }
                }
              }

              PanelSeparator { width: parent.width; foreground: root.foreground }

              Item {
                width: parent.width
                implicitHeight: Math.max(ambientText.implicitHeight, ambientSwitch.implicitHeight)

                Column {
                  anchors.left: parent.left
                  anchors.right: ambientSwitch.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    text: "Ambient mode"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    id: ambientText
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: root.ambientHint(roomDetail.room)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                ToggleSwitch {
                  id: ambientSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.ambientActive(roomDetail.room)
                  foreground: root.foreground
                  enabled: !!roomDetail.room && !root.busy
                  onToggled: root.toggleAmbient(roomDetail.room)
                }
              }

              Dropdown {
                width: parent.width
                label: "Sync from"
                options: root.monitorOptions()
                value: root.ambientMonitor()
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(v) { root.setAmbientMonitor(roomDetail.room, v) }
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                visible: roomDetail.room && (roomDetail.room.scenes || []).length > 0
                Repeater {
                  model: roomDetail.room ? (roomDetail.room.scenes || []) : []
                  Button {
                    required property var modelData
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    text: modelData.name
                    enabled: !root.busy
                    onClicked: root.activateScene(roomDetail.room, modelData)
                  }
                }
              }
            }
          }

          // Individual lights.
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: roomDetail.room && (roomDetail.room.lights || []).length > 0

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader { text: "LIGHTS"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              model: roomDetail.room ? (roomDetail.room.lights || []) : []
              LightRow {
                required property var modelData
                required property int index
                width: parent.width
                light: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: roomDetail.room && (roomDetail.room.lights || []).length === 0
            width: parent.width
            text: "This room has no individually addressable lights."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // ------------------------------------------------------------- footer
    Text {
      id: footer
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: root.selectedRoom
        ? "↑↓ move · ←→ brightness · Space power · 1-6 colour · Esc back"
        : "↑↓ move · ←→ brightness · Space power · 1-6 colour · Enter open · Esc close"
      color: Qt.darker(root.foreground, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---------------------------------------------------------- room list row
  // A card that opens the room's detail view when tapped, with an inline
  // power switch on the trailing edge so the whole room can be flipped
  // without drilling in. Doubles as the keyboard cursor's row at this level.
  component RoomRow: CursorSurface {
    id: roomRow
    required property var room
    required property int rowIndex

    hasCursor: root.cursorActive && !root.selectedRoom && root.cursorIndex === roomRow.rowIndex
    foreground: root.foreground
    radius: Style.cornerRadius
    implicitHeight: Style.space(58)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(roomRow)

    Row {
      anchors.left: parent.left
      anchors.right: roomSwitch.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      Rectangle {
        width: Style.space(10)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: roomRow.room.on ? Color.accent : Qt.darker(root.foreground, 2.2)
      }

      Column {
        width: parent.width - Style.space(10) - Style.space(18) - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)
        Text {
          text: roomRow.room.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          text: root.roomSubtitle(roomRow.room)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Text {
        text: "›"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    ToggleSwitch {
      id: roomSwitch
      checked: roomRow.room.on
      foreground: root.foreground
      enabled: !root.busy
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      onToggled: root.roomPower(roomRow.room)
    }

    MouseArea {
      id: roomHover
      anchors.left: parent.left
      anchors.right: roomSwitch.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.cursorIndex = roomRow.rowIndex }
      onClicked: root.selectRoom(roomRow.room)
    }
  }

  // ------------------------------------------------------------- light row
  // Collapsed: name, live brightness/off label, and a power switch. Tapping
  // the row (outside the switch) toggles the brightness slider and colour
  // swatches open, and the keyboard cursor lands here as `rowIndex` too.
  component LightRow: Column {
    id: lightRow
    required property var light
    required property int rowIndex
    spacing: Style.space(6)

    readonly property bool expanded: root.selectedLightId === String(lightRow.light.id)
    readonly property bool unreachable: lightRow.light.reachable === false
    readonly property bool hasCursor: root.cursorActive && !!root.selectedRoom && root.cursorIndex === lightRow.rowIndex

    CursorSurface {
      id: lightSurface
      width: parent.width
      implicitHeight: Style.space(48)
      opacity: lightRow.unreachable ? 0.5 : 1.0
      hasCursor: lightRow.hasCursor
      current: lightRow.expanded
      foreground: root.foreground
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(lightSurface)

      Row {
        anchors.left: parent.left
        anchors.right: lightSwitch.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        Text {
          text: lightRow.unreachable ? (lightRow.light.name + " (unreachable)") : lightRow.light.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width - brightnessLabel.implicitWidth - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          id: brightnessLabel
          text: lightRow.light.on ? (Math.round((lightRow.light.brightness || 0) / 254 * 100) + "%") : "Off"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      ToggleSwitch {
        id: lightSwitch
        checked: lightRow.light.on
        foreground: root.foreground
        enabled: !lightRow.unreachable && !root.busy
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        onToggled: root.lightPower(lightRow.light)
      }

      MouseArea {
        id: lightHover
        anchors.left: parent.left
        anchors.right: lightSwitch.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        hoverEnabled: true
        enabled: !lightRow.unreachable
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.cursorIndex = lightRow.rowIndex }
        onClicked: root.selectLight(lightRow.light)
      }
    }

    Item {
      visible: lightRow.expanded
      width: parent.width
      implicitHeight: expandColumn.implicitHeight

      Column {
        id: expandColumn
        x: Style.space(10)
        width: parent.width - x
        spacing: Style.spacing.sm

        PanelSlider {
          width: parent.width
          minimum: 1
          maximum: 254
          integer: true
          value: lightRow.light.brightness || 1
          enabled: lightRow.light.on && !root.busy
          onReleased: function(v) { root.lightBrightness(lightRow.light, v) }
        }

        Row {
          spacing: Style.space(8)
          Repeater {
            model: root.swatches
            Rectangle {
              required property var modelData
              width: Style.space(20)
              height: width
              radius: width / 2
              color: modelData.c
              border.width: 1
              border.color: root.foreground
              MouseArea {
                anchors.fill: parent
                enabled: !root.busy
                cursorShape: Qt.PointingHandCursor
                onClicked: root.lightColour(lightRow.light, parent.modelData.h)
              }
            }
          }
        }
      }
    }
  }
}
