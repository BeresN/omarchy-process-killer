import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus a popup listing the user's apps (anything that owns a
// Hyprland window) and heavier background processes, each with an X that
// ends it: SIGTERM to the app's main process, then SIGKILL for whatever of
// the app is still alive three seconds later.
Panel {
  id: root
  moduleName: "io.github.beresn.process-killer"
  ipcTarget: "io.github.beresn.process-killer"

  readonly property int minMemoryMB: Math.max(0, Number(setting("minMemoryMB", 50)) || 0)
  readonly property string barGlyph: String.fromCodePoint(0xF035B)
  readonly property string windowGlyph: String.fromCodePoint(0xF08C6)
  readonly property string processGlyph: String.fromCodePoint(0xF0493)
  readonly property string killGlyph: String.fromCodePoint(0xF0156)

  property var rows: []
  property int windowCount: 0
  property int selectedIndex: -1
  property bool cursorActive: false
  property bool freshOrder: true
  // pid -> time the kill was sent. Such rows stay listed but inert until they
  // vanish, and clicks are ignored for a beat after the list shifts, so a
  // double click cannot land on the row that slides up next.
  property var pending: ({})
  property double layoutChangedAt: 0

  readonly property string collectScript: [
    "echo \"@@SELF $$\"",
    "echo @@PROCS",
    "ps -u \"$(id -u)\" -o pid=,ppid=,rss=,comm=",
    "echo @@ARGS",
    "ps -u \"$(id -u)\" -o pid=,args=",
    "echo @@WINDOWS",
    "hyprctl clients -j 2>/dev/null"
  ].join("\n")

  // $1 is the app's main process, the rest are every pid of the app.
  readonly property string killScript: [
    "leader=$1",
    "kill -TERM \"$leader\" 2>/dev/null || exit 0",
    "for _ in $(seq 30); do kill -0 \"$leader\" 2>/dev/null || break; sleep 0.1; done",
    "shift",
    "kill -KILL \"$@\" 2>/dev/null",
    "exit 0"
  ].join("\n")

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function applySnapshot(raw) {
    var built = Model.buildRows(raw, root.minMemoryMB)
    var keep = !root.freshOrder
    var windows = Model.keepOrder(keep ? rows.filter(function(r) { return r.section === "windows" }) : [], built.windows)
    var processes = Model.keepOrder(keep ? rows.filter(function(r) { return r.section === "processes" }) : [], built.processes)
    windows.forEach(function(r) { r.section = "windows" })
    processes.forEach(function(r) { r.section = "processes" })
    var next = windows.concat(processes)

    var now = Date.now()
    var alive = {}
    for (var i = 0; i < next.length; i++) alive[next[i].pid] = true
    var stillPending = {}
    for (var pid in root.pending) {
      // A process that survives even SIGKILL (stuck in the kernel) gets its
      // X back after a while instead of staying greyed out forever.
      if (alive[pid] && now - root.pending[pid] < 6000) stillPending[pid] = root.pending[pid]
    }
    root.pending = stillPending

    if (!Model.sameLayout(rows, next)) root.layoutChangedAt = now
    root.freshOrder = false
    root.windowCount = windows.length
    root.rows = next
    if (root.cursorActive) root.selectedIndex = Model.clampIndex(root.selectedIndex, next.length)
  }

  function killRow(row) {
    if (!row || root.pending[row.pid] !== undefined) return
    if (Date.now() - root.layoutChangedAt < 600) return
    var next = Object.assign({}, root.pending)
    next[row.pid] = Date.now()
    root.pending = next
    Quickshell.execDetached(["bash", "-c", root.killScript, "process-killer", String(row.pid)]
      .concat(row.pids.map(String)))
    quickRefresh.restart()
  }

  function select(index) {
    root.cursorActive = true
    root.selectedIndex = index
  }

  function moveCursor(dy) {
    if (rows.length === 0) return
    if (!cursorActive) {
      select(0)
    } else {
      selectedIndex = Model.clampIndex(selectedIndex + dy, rows.length)
    }
    ensureVisible(selectedIndex)
  }

  function ensureVisible(index) {
    var item = rowRepeater.itemAt(index)
    if (!item) return
    if (item.y < flick.contentY) flick.contentY = item.y
    else if (item.y + item.height > flick.contentY + flick.height) flick.contentY = item.y + item.height - flick.height
  }

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    selectedIndex = -1
    freshOrder = true
    // The list on screen is from the previous opening until the first
    // refresh lands; keep its X buttons inert for that moment.
    layoutChangedAt = Date.now()
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: listProc
    command: ["bash", "-c", root.collectScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applySnapshot(text) }
  }

  Timer { interval: 2000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  Timer { id: quickRefresh; interval: 500; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    tooltipText: ""
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onDeleteRequested: if (root.cursorActive) root.killRow(root.rows[root.selectedIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · title/counts ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.barGlyph
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Processes"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: ("Windows: " + root.windowCount + " · background: " + (root.rows.length - root.windowCount)).toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // Capped so a busy session doesn't grow the popup past the screen.
        Flickable {
          id: flick
          visible: root.rows.length > 0
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(420))
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: flick.width
            spacing: Style.space(4)

            Repeater {
              id: rowRepeater
              model: root.rows

              delegate: Column {
                required property var modelData
                required property int index
                readonly property bool startsSection: index === 0 || root.rows[index - 1].section !== modelData.section

                width: listColumn.width
                spacing: Style.space(8)

                // Column skips invisible children, so hidden headers take no space.
                PanelSeparator {
                  visible: startsSection && index > 0
                  foreground: root.bar.foreground
                }

                PanelSectionHeader {
                  visible: startsSection
                  text: modelData.section === "windows" ? "WINDOWS" : "BACKGROUND (≥ " + root.minMemoryMB + " MB)"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                ProcessRow {
                  width: parent.width
                  entry: modelData
                  rowIndex: index
                }
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.rows.length === 0
          text: listProc.running ? "Loading…" : "No processes to show"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: "j/k — select · x — kill"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
        }
      }
    }
  }

  component ProcessRow: CursorSurface {
    id: row
    required property var entry
    required property int rowIndex

    readonly property bool rowSelected: root.cursorActive && root.selectedIndex === rowIndex
    readonly property bool isPending: root.pending[entry.pid] !== undefined

    hasCursor: rowSelected
    foreground: root.bar.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.select(row.rowIndex)
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(rowIcon.implicitHeight, info.implicitHeight, killBtn.implicitHeight)
      opacity: row.isPending ? 0.5 : 1

      Text {
        id: rowIcon
        textFormat: Text.PlainText
        text: row.entry.section === "windows" ? root.windowGlyph : root.processGlyph
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        anchors.left: rowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: memoryText.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: row.entry.name
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: row.isPending ? "Closing…" : Model.rowDetail(row.entry)
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Text {
        id: memoryText
        textFormat: Text.PlainText
        text: Model.formatMemory(row.entry.rssKiB)
        color: root.bar.foreground
        opacity: 0.7
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.right: killBtn.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      PanelActionButton {
        id: killBtn
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        enabled: !row.isPending
        iconText: root.killGlyph
        tooltipText: "Kill"
        foreground: root.bar.foreground
        hoverColor: Commons.Color.urgent
        fontFamily: root.bar.fontFamily
        onHovered: function(isHovered) { if (isHovered) root.select(row.rowIndex) }
        onClicked: root.killRow(row.entry)
      }
    }
  }
}
