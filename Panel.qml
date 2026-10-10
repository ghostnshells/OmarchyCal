import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Center-screen calendar card in the same visual language as the
// weather popup (popup background, border, type scale), summoned with
// SUPER+ALT+C via:
//   omarchy-shell shell toggle ghostnshells.calendar-popup
//
// Events are color-coded by type (work, meetings, urgent, ...). Without a
// configured URL the card shows annotated demo events.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool opened: false
  readonly property string pluginId: (manifest && manifest.id) || "ghostnshells.calendar-popup"

  function open(payloadJson) {
    root.opened = true
    settingsFile.reload()
    var today = new Date()
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.selectedKey = Model.dayKey(today)
    root.selectedDate = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 12, 0, 0)
    root.refresh()
    Qt.callLater(function() {
      if (root.opened && keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    if (root.editingSettings) root.cancelEditingSettings()
    root.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else root.close()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- Calendar state ----
  property int viewYear: new Date().getFullYear()
  property int viewMonth: new Date().getMonth()
  property string selectedKey: ""
  property var selectedDate: new Date()

  property var allEvents: []
  property var eventsByDay: ({})
  property bool loading: false
  property string lastSyncLabel: ""
  property string syncError: ""
  property bool demoMode: true

  property string icsText: ""
  property bool editingSettings: false
  property bool savingSettings: false

  readonly property string todayKey: {
    var t = new Date()
    return t.getFullYear() + "-" + (t.getMonth() + 1 < 10 ? "0" : "") + (t.getMonth() + 1) + "-" + (t.getDate() < 10 ? "0" : "") + t.getDate()
  }
  readonly property var icsUrls: Model.splitIcsUrls(root.icsText)
  readonly property var monthCells: Model.buildMonthCells(root.viewYear, root.viewMonth, root.eventsByDay, 1, root.todayKey)
  readonly property var weekdayRow: Model.weekdayNames(1, true)
  readonly property string monthTitle: {
    var d = new Date(root.viewYear, root.viewMonth, 1, 12, 0, 0)
    return Qt.formatDate(d, "MMMM yyyy")
  }
  readonly property var selectedEvents: {
    var list = root.eventsByDay[root.selectedKey]
    if (!list) return []
    var copy = list.slice()
    copy.sort(function(a, b) {
      if (a.allDay && !b.allDay) return -1
      if (!a.allDay && b.allDay) return 1
      return a.start - b.start
    })
    return copy
  }
  readonly property string selectedTitle: Qt.formatDate(root.selectedDate, "dddd, d MMMM")
  readonly property int selectedCount: root.selectedEvents.length
  readonly property var legendCats: Model.categories()

  property FileView settingsFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/calendar-popup.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var s = Model.parseSettings(text())
      root.icsText = s.ics
      if (root.opened && !root.editingSettings) Qt.callLater(root.refresh)
    }
    onLoadFailed: {
      root.icsText = ""
      if (root.opened && !root.editingSettings) Qt.callLater(root.refresh)
    }
  }

  function eventColor(c) {
    if (c === "__accent__") return Color.accent
    if (c === "__urgent__") return Color.urgent
    return c
  }

  function refresh() {
    if (!root.opened) return
    var urls = Model.splitIcsUrls(root.icsText)
    if (urls.length === 0) {
      root.loadDemo()
      return
    }
    root.fetchQueue = urls.slice(0, 3)
    root.fetchIndex = 0
    root.fetchResults = []
    root.syncError = ""
    root.loading = true
    root.startNextFetch()
  }

  function loadDemo() {
    var today = new Date()
    var demo = Model.demoEvents(today)
    root.allEvents = demo
    root.eventsByDay = Model.groupByDay(demo)
    root.demoMode = true
    root.loading = false
    root.syncError = ""
    var t = new Date()
    root.lastSyncLabel = "DEMO • PRESS E TO CONNECT GOOGLE"
  }

  // ---- Sequential ICS fetch (one curl at a time) ----
  property var fetchQueue: []
  property int fetchIndex: 0
  property var fetchResults: []

  function startNextFetch() {
    if (root.fetchIndex >= root.fetchQueue.length) {
      root.finishFetch()
      return
    }
    var url = root.fetchQueue[root.fetchIndex]
    icsProc.command = ["curl", "-fsSL", "--max-time", "12", "-A", "omarchy-calendar-popup/1.0", url]
    icsProc.running = true
  }

  function finishFetch() {
    var base = []
    for (var i = 0; i < root.fetchResults.length; i++) {
      var chunk = Model.parseIcsEvents(root.fetchResults[i])
      for (var j = 0; j < chunk.length; j++) base.push(chunk[j])
    }
    var now = new Date()
    var rangeStart = new Date(now.getFullYear(), now.getMonth() - 1, 1)
    var rangeEnd = new Date(now.getFullYear(), now.getMonth() + 3, 1)
    var expanded = Model.expandEvents(base, rangeStart, rangeEnd)
    root.allEvents = expanded
    root.eventsByDay = Model.groupByDay(expanded)
    root.demoMode = false
    root.loading = false
    if (base.length === 0 && root.syncError === "") root.syncError = "No events found in the configured calendar."
    var t = new Date()
    var hh = t.getHours()
    var mm = t.getMinutes()
    root.lastSyncLabel = "SYNCED " + (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
  }

  // ---- Month navigation ----
  function prevMonth() {
    if (root.viewMonth === 0) { root.viewYear--; root.viewMonth = 11 }
    else root.viewMonth--
  }
  function nextMonth() {
    if (root.viewMonth === 11) { root.viewYear++; root.viewMonth = 0 }
    else root.viewMonth++
  }
  function goToday() {
    var t = new Date()
    root.viewYear = t.getFullYear()
    root.viewMonth = t.getMonth()
    root.selectedKey = Model.dayKey(t)
    root.selectedDate = new Date(t.getFullYear(), t.getMonth(), t.getDate(), 12, 0, 0)
  }
  function selectCell(cell) {
    root.selectedKey = cell.key
    root.selectedDate = new Date(cell.date.getFullYear(), cell.date.getMonth(), cell.date.getDate(), 12, 0, 0)
    // Clicking a dimmed adjacent-month day follows it into that month.
    if (cell.date.getMonth() !== root.viewMonth || cell.date.getFullYear() !== root.viewYear) {
      root.viewMonth = cell.date.getMonth()
      root.viewYear = cell.date.getFullYear()
    }
  }

  // Keyboard day navigation. Crossing a month boundary follows the
  // selection into the new month automatically.
  function moveSelection(dayDelta) {
    var base = root.selectedDate instanceof Date ? root.selectedDate : new Date()
    var nd = new Date(base.getTime())
    nd.setDate(nd.getDate() + dayDelta)
    nd = new Date(nd.getFullYear(), nd.getMonth(), nd.getDate(), 12, 0, 0)
    root.selectedDate = nd
    root.selectedKey = Model.dayKey(nd)
    if (nd.getMonth() !== root.viewMonth || nd.getFullYear() !== root.viewYear) {
      root.viewMonth = nd.getMonth()
      root.viewYear = nd.getFullYear()
    }
  }

  // ---- Settings editing ----
  function startEditingSettings() {
    root.editingSettings = true
    root.savingSettings = false
    Qt.callLater(function() {
      urlField.text = root.icsText
      urlField.forceActiveFocus()
    })
  }
  function cancelEditingSettings() {
    root.editingSettings = false
    root.savingSettings = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }
  function bashSingleQuoteEscape(s) {
    return String(s || "").replace(/'/g, "'\\''")
  }
  function commitSettings() {
    var value = urlField.text
    root.savingSettings = true
    var payload = "{\"ics\":\"" + value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\",\"weekStart\":1}"
    var escaped = root.bashSingleQuoteEscape(payload)
    settingsSaveProc.command = ["bash", "-c", "mkdir -p ~/.local/state/omarchy/settings && printf '%s' '" + escaped + "' > ~/.local/state/omarchy/settings/calendar-popup.json"]
    settingsSaveProc.running = true
  }
  function clearSettings() {
    urlField.text = ""
    root.commitSettings()
  }

  // ---- Fetch processes ----
  Process {
    id: icsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw !== "") {
          var next = root.fetchResults.slice()
          next.push(raw)
          root.fetchResults = next
        } else {
          if (root.syncError === "") root.syncError = "Could not reach the calendar URL. Check the ICS link."
        }
        root.fetchIndex++
        if (root.opened) Qt.callLater(root.startNextFetch)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.syncError === "") root.syncError = "Could not reach the calendar URL. Check the ICS link."
    }
  }

  Process {
    id: settingsSaveProc
    onExited: function(exitCode) {
      root.savingSettings = false
      if (exitCode !== 0) {
        root.syncError = "Could not save settings."
        return
      }
      settingsFile.reload()
      root.cancelEditingSettings()
      Qt.callLater(root.refresh)
    }
  }

  Timer {
    id: autoRefresh
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    onTriggered: if (root.opened) root.refresh()
  }

  // ---- Center-screen card ----
  PanelWindow {
    id: win
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "ghostnshells-calendar-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.55)
      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(760), win.width - Style.space(48))
      height: Math.min(cardColumn.implicitHeight + Style.space(20), win.height - Style.space(48))
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.space(10)
      radius: Style.cornerRadius

      MouseArea {
        anchors.fill: parent
        onClicked: function(mouse) { mouse.accepted = true }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (root.editingSettings) {
            if (event.key === Qt.Key_Escape) {
              root.cancelEditingSettings()
              event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
              root.commitSettings()
              event.accepted = true
            }
            return
          }
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            if (event.modifiers & Qt.ShiftModifier) root.prevMonth()
            else root.moveSelection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            if (event.modifiers & Qt.ShiftModifier) root.nextMonth()
            else root.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveSelection(-7)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveSelection(7)
            event.accepted = true
          } else if (event.text === "t" || event.text === "T") {
            root.goToday()
            event.accepted = true
          } else if (event.text === "r" || event.text === "R") {
            root.refresh()
            event.accepted = true
          } else if (event.text === "e" || event.text === "E") {
            root.startEditingSettings()
            event.accepted = true
          }
        }
      }

      Flickable {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        contentWidth: width
        contentHeight: cardColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: cardColumn
          width: parent.width
          spacing: Style.space(12)

          // Header: title + close hint
          Item {
            width: parent.width
            implicitHeight: Math.max(calTitle.implicitHeight, calClose.implicitHeight)
            Text {
              id: calTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "CALENDAR"
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 2
            }
            Text {
              id: calClose
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "ESC TO CLOSE"
              color: Qt.darker(Color.popups.text, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }

          // Month nav row
          Item {
            width: parent.width
            implicitHeight: Math.max(navRow.implicitHeight, syncLabel.implicitHeight)
            Row {
              id: navRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)
              Text {
                id: prevBtn
                anchors.verticalCenter: parent.verticalCenter
                text: "‹"
                color: Qt.darker(Color.popups.text, 1.2)
                font.family: Style.font.family
                font.pixelSize: Style.font.display
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.prevMonth()
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.monthTitle.toUpperCase()
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                font.letterSpacing: 1
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "›"
                color: Qt.darker(Color.popups.text, 1.2)
                font.family: Style.font.family
                font.pixelSize: Style.font.display
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.nextMonth()
                }
              }
              Item { width: Style.space(8); height: 1 }
              // Today pill
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: todayLabel.implicitWidth + Style.space(20)
                height: todayLabel.implicitHeight + Style.space(10)
                radius: height / 2
                color: Style.hoverFillFor(Color.popups.text, Color.accent)
                border.width: 1
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)
                Text {
                  id: todayLabel
                  anchors.centerIn: parent
                  text: "TODAY"
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.goToday()
                }
              }
            }
            Text {
              id: syncLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.loading ? "SYNCING…" : root.lastSyncLabel
              color: Qt.darker(Color.popups.text, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }

          // Main two-column body
          Row {
            width: parent.width
            spacing: Style.space(20)

            // Left: month grid
            Column {
              width: Math.min(Style.space(430), parent.width * 0.6)
              spacing: Style.space(6)

              // Weekday header
              Row {
                width: parent.width
                spacing: 0
                Repeater {
                  model: root.weekdayRow
                  Item {
                    required property string modelData
                    width: parent.width / 7
                    height: wdLabel.implicitHeight + Style.space(4)
                    Text {
                      id: wdLabel
                      anchors.centerIn: parent
                      text: modelData.toUpperCase()
                      color: Qt.darker(Color.popups.text, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1
                    }
                  }
                }
              }

              // Day cells
              Grid {
                width: parent.width
                columns: 7
                Repeater {
                  model: root.monthCells
                  Rectangle {
                    required property var modelData
                    width: parent.width / 7
                    height: Style.space(58)
                    radius: Style.cornerRadius * 0.6
                    color: {
                      if (modelData.key === root.selectedKey) return Style.hoverFillFor(Color.popups.text, Color.accent)
                      if (modelData.isToday) return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
                      return "transparent"
                    }
                    border.width: modelData.isToday ? 1 : 0
                    border.color: modelData.isToday ? Color.accent : "transparent"
                    opacity: modelData.inMonth ? 1.0 : 0.38

                    Column {
                      anchors.centerIn: parent
                      spacing: 3
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        textFormat: Text.PlainText
                        text: modelData.day
                        color: modelData.key === root.selectedKey ? Color.accent : Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: modelData.isToday || modelData.key === root.selectedKey
                      }
                      // Event dots (up to 3 category colors)
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 4
                        visible: modelData.dots.length > 0
                        Repeater {
                          model: modelData.dots
                          Rectangle {
                            required property string modelData
                            width: 7
                            height: 7
                            radius: 3.5
                            color: {
                              if (modelData === "__accent__") return Color.accent
                              if (modelData === "__urgent__") return Color.urgent
                              return modelData
                            }
                          }
                        }
                        Text {
                          visible: modelData.events.length > 3
                          text: "+" + (modelData.events.length - 3)
                          color: Qt.darker(Color.popups.text, 1.4)
                          font.family: Style.font.family
                          font.pixelSize: 10
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }
                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectCell(modelData)
                    }
                  }
                }
              }

              // Error / demo notice
              Text {
                visible: root.syncError !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.syncError
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }
              Rectangle {
                visible: root.demoMode && root.syncError === ""
                width: parent.width
                height: demoNotice.implicitHeight + Style.space(14)
                radius: Style.cornerRadius * 0.6
                color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
                border.width: 1
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
                Text {
                  id: demoNotice
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(24)
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Showing sample events — press E to connect your Google Calendar."
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startEditingSettings()
                }
              }
            }

            // Divider
            Rectangle {
              width: 1
              height: agendaCol.implicitHeight + Style.space(8)
              color: Color.popups.text
              opacity: 0.12
            }

            // Right: agenda
            Column {
              id: agendaCol
              width: parent.width - Math.min(Style.space(430), parent.width * 0.6) - Style.space(20) - 1
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: root.selectedTitle.toUpperCase()
                color: Qt.darker(Color.popups.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
              Text {
                visible: root.selectedCount > 0
                textFormat: Text.PlainText
                text: root.selectedCount === 1 ? "1 EVENT" : root.selectedCount + " EVENTS"
                color: Qt.darker(Color.popups.text, 1.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: root.selectedCount === 0 && !root.loading
                text: "No events — enjoy the open day."
                color: Qt.darker(Color.popups.text, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }
              Text {
                visible: root.loading
                text: "Syncing calendar…"
                color: Qt.darker(Color.popups.text, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }

              Column {
                width: parent.width
                spacing: Style.space(8)
                Repeater {
                  model: root.selectedEvents
                  Rectangle {
                    required property var modelData
                    width: parent.width
                    height: evCol.implicitHeight + Style.space(14)
                    radius: Style.cornerRadius * 0.6
                    color: Style.hoverFillFor(Color.popups.text, Color.accent)
                    border.width: 1
                    border.color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12)
                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: 0
                      spacing: Style.space(10)
                      Rectangle {
                        width: 4
                        height: parent.height
                        radius: 2
                        color: {
                          var c = modelData.color
                          if (c === "__accent__") return Color.accent
                          if (c === "__urgent__") return Color.urgent
                          return c
                        }
                      }
                      Column {
                        id: evCol
                        width: parent.width - Style.space(10) - 4 - Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                          width: parent.width
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                          text: modelData.title
                          color: Color.popups.text
                          font.family: Style.font.family
                          font.pixelSize: Style.font.body
                          font.bold: true
                        }
                        Text {
                          width: parent.width
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                          text: {
                            var t = ""
                            if (modelData.allDay) t = "All day"
                            else {
                              var sh = modelData.start.getHours()
                              var sm = modelData.start.getMinutes()
                              var eh = modelData.end.getHours()
                              var em = modelData.end.getMinutes()
                              function f(h, m) {
                                var sfx = h >= 12 ? "PM" : "AM"
                                var h12 = h % 12
                                if (h12 === 0) h12 = 12
                                return h12 + (m === 0 ? "" : ":" + (m < 10 ? "0" : "") + m) + " " + sfx
                              }
                              t = f(sh, sm) + " – " + f(eh, em)
                            }
                            if (modelData.location && modelData.location !== "") t += "  •  " + modelData.location
                            return t
                          }
                          color: Qt.darker(Color.popups.text, 1.35)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          visible: modelData.categoryLabel && modelData.categoryLabel !== ""
                          textFormat: Text.PlainText
                          text: modelData.categoryLabel.toUpperCase()
                          color: {
                            var cc = modelData.color
                            if (cc === "__accent__") return Color.accent
                            if (cc === "__urgent__") return Color.urgent
                            return cc
                          }
                          font.family: Style.font.family
                          font.pixelSize: 10
                          font.bold: true
                          font.letterSpacing: 1
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // Settings editor (E)
          Column {
            visible: root.editingSettings
            width: parent.width
            spacing: Style.space(8)
            Rectangle {
              width: parent.width
              height: 1
              color: Color.popups.text
              opacity: 0.12
            }
            Text {
              text: "GOOGLE CALENDAR CONNECTION"
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Google Calendar → Settings → Integrate calendar → copy the “Secret address in iCal format”, paste it below, then Ctrl+Enter. Separate multiple calendars with commas."
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            TextField {
              id: urlField
              width: parent.width
              placeholderText: "https://calendar.google.com/calendar/ical/…/basic.ics"
              foreground: Color.popups.text
              font.family: Style.font.family
              enabled: !root.savingSettings
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEditingSettings()
                  event.accepted = true
                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                  root.commitSettings()
                  event.accepted = true
                }
              }
            }
            Row {
              spacing: Style.space(16)
              Text {
                text: root.savingSettings ? "SAVING…" : "CTRL+ENTER TO SAVE"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  enabled: !root.savingSettings
                  onClicked: root.commitSettings()
                }
              }
              Text {
                text: "CLEAR"
                color: Qt.darker(Color.popups.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  enabled: !root.savingSettings
                  onClicked: root.clearSettings()
                }
              }
            }
          }

          // Legend
          Row {
            width: parent.width
            spacing: Style.space(14)
            Repeater {
              model: root.legendCats
              Row {
                required property var modelData
                spacing: Style.space(6)
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: 8
                  height: 8
                  radius: 4
                  color: {
                    if (modelData.color === "__accent__") return Color.accent
                    if (modelData.color === "__urgent__") return Color.urgent
                    return modelData.color
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.label.toUpperCase()
                  color: Qt.darker(Color.popups.text, 1.5)
                  font.family: Style.font.family
                  font.pixelSize: 10
                  font.letterSpacing: 1
                }
              }
            }
          }

          // Footer hints
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "← → ↑ ↓ DAYS   •   SHIFT+← → MONTH   •   T TODAY   •   E CONNECT GOOGLE   •   R REFRESH"
            color: Qt.darker(Color.popups.text, 1.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
