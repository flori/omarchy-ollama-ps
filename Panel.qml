import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "OllamaModel.js" as OllamaModel

Panel {
  id: root
  moduleName: "flori.ollama-ps"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var ollamaService: null
  property var effectiveSettings: ({})
  property int selectedIndex: -1
  property bool confirmUnload: false
  property string confirmedModelName: ""
  property double nowMs: Date.now()
  property string copyFeedback: ""
  property double copyFeedbackUntilMs: 0
  property bool copyBusy: false
  property bool copyTimedOut: false
  readonly property var clipboardEnvironment: ({
    LANG: "C.UTF-8",
    LC_ALL: "C.UTF-8",
    WAYLAND_DISPLAY: null,
    XDG_RUNTIME_DIR: null
  })
  readonly property var barIdentity: hostWidget || root
  readonly property var servers: ollamaService && Array.isArray(ollamaService.servers) ? ollamaService.servers : []
  // Flatten online models into a single keyboard-navigable list.
  // Offline servers are skipped so their models never appear.
  readonly property var flatModels: {
    var result = []
    for (var s = 0; s < servers.length; s++) {
      var srv = servers[s]
      if (!srv || srv.state !== "online") continue
      for (var m = 0; m < srv.models.length; m++)
        result.push({ serverUrl: srv.url, model: srv.models[m] })
    }
    return result
  }
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property double lastSuccessfulRefreshMs: ollamaService ? Number(ollamaService.lastSuccessfulRefreshMs || 0) : 0
  readonly property bool refreshing: ollamaService ? ollamaService.refreshing === true : false

  // Inline component: styled footer button (label + click + hover state).
  component MenuAction: Rectangle {
    id: control
    property string label: ""
    signal clicked()
    height: Style.space(32)
    radius: Style.space(7)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, mouse.containsMouse ? .12 : .055)
    opacity: enabled ? 1 : .4
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.onPressAction: clicked()
    Text { anchors.centerIn: parent; text: control.label; color: root.foreground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: control.clicked() }
  }

  // ── Display helpers & keyboard/selection logic ──
  function plain(value, limit) { return OllamaModel.plainText(value, limit) }
  function refreshNow() {
    if (ollamaService) ollamaService.refresh()
  }
  // Aggregated loaded count; falls back to visible row count.
  function totalLoadedCount() {
    if (!ollamaService) return flatModels.length
    var count = Number(ollamaService.totalLoadedModelCount)
    return isFinite(count) && count >= 0 ? Math.floor(count) : flatModels.length
  }
  function aggregateVram() {
    var t = Number(ollamaService && ollamaService.totalAggregateVramBytes)
    return isFinite(t) && t > 0 ? OllamaModel.formatBytes(t) : ""
  }
  function onlineCount() {
    var n = 0
    for (var s = 0; s < servers.length; s++)
      if (servers[s] && servers[s].state === "online") n++
    return n
  }
  // Map (serverUrl, modelId) → flat index for keyboard/selection.
  function flatIndexOf(serverUrl, modelId) {
    for (var i = 0; i < flatModels.length; i++)
      if (flatModels[i].serverUrl === serverUrl && flatModels[i].model.modelId === modelId) return i
    return -1
  }
  function setCopyFeedback(message) {
    copyFeedback = message
    copyFeedbackUntilMs = Date.now() + 3000
    nowMs = Date.now()
  }
  function activeCopyFeedback() {
    return copyFeedbackUntilMs > nowMs ? copyFeedback : ""
  }
  function copySelectedModelName() {
    if (selectedIndex < 0 || selectedIndex >= flatModels.length) {
      setCopyFeedback("No model selected")
      return
    }
    var modelId = flatModels[selectedIndex].model.modelId
    if (!modelId) { setCopyFeedback("Copy unavailable"); return }
    if (copyBusy || copyTimedOut || copyProcess.running) {
      setCopyFeedback(copyTimedOut ? "Clipboard is resetting" : "Copy already in progress")
      return
    }
    copyProcess.command = ["/usr/bin/wl-copy", "--type", "text/plain;charset=utf-8", "--", modelId]
    copyBusy = true
    copyTimeout.restart()
    copyProcess.running = true
    setCopyFeedback("Copying\u2026")
  }
  function refreshAge() {
    if (!isFinite(lastSuccessfulRefreshMs) || lastSuccessfulRefreshMs <= 0) return "No successful refresh yet"
    var seconds = Math.max(0, Math.floor((nowMs - lastSuccessfulRefreshMs) / 1000))
    if (seconds < 10) return "Updated just now"
    if (seconds < 60) return "Updated " + seconds + "s ago"
    if (seconds < 3600) return "Updated " + Math.ceil(seconds / 60) + "m ago"
    return "Updated " + Math.ceil(seconds / 3600) + "h ago"
  }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") bar.switchPanelFrom(barIdentity, direction)
  }
  function clearUnloadConfirmation() {
    confirmUnload = false
    confirmedModelName = ""
  }
  function actionableModelIdAt(index) {
    if (index < 0 || index >= flatModels.length || !flatModels[index]) return ""
    var m = flatModels[index].model
    return m.actionable === true && typeof m.modelId === "string" ? m.modelId : ""
  }
  function serverUrlAt(index) {
    if (index < 0 || index >= flatModels.length || !flatModels[index]) return ""
    return flatModels[index].serverUrl
  }
  function selectStep(step) {
    if (flatModels.length === 0) { selectedIndex = -1; clearUnloadConfirmation(); return }
    var next = Math.max(0, Math.min(flatModels.length - 1, selectedIndex + step))
    if (next !== selectedIndex) selectedIndex = next
    clearUnloadConfirmation()
  }
  // Two-step confirm: first press arms, second fires the unload.
  function requestUnload(index) {
    if (index < 0 || index >= flatModels.length) return
    if (selectedIndex !== index) { selectedIndex = index; clearUnloadConfirmation() }
    var modelId = actionableModelIdAt(index)
    var serverUrl = serverUrlAt(index)
    if (!modelId || !serverUrl) {
      clearUnloadConfirmation()
      setCopyFeedback("Unload unavailable for this model")
      return
    }
    if (!ollamaService || ollamaService.busy) return
    if (!confirmUnload || confirmedModelName !== modelId || actionableModelIdAt(selectedIndex) !== confirmedModelName) {
      confirmUnload = true
      confirmedModelName = modelId
      return
    }
    if (ollamaService.unload(modelId, serverUrl)) clearUnloadConfirmation()
  }
  // Scroll the selected row into the visible Flickable area.
  function ensureSelectedVisible() {
    if (selectedIndex < 0 || !modelFlick) return
    var item = findFlatItem(selectedIndex)
    if (!item) return
    var point = item.mapToItem(modelFlick.contentItem || modelFlick, 0, 0)
    var top = point.y
    var bottom = top + item.height
    var margin = Style.space(6)
    var viewTop = modelFlick.contentY
    var viewBottom = viewTop + modelFlick.height
    var maximum = Math.max(0, modelFlick.contentHeight - modelFlick.height)
    if (top < viewTop + margin)
      modelFlick.contentY = Math.max(0, Math.min(maximum, top - margin))
    else if (bottom > viewBottom - margin)
      modelFlick.contentY = Math.max(0, Math.min(maximum, bottom + margin - modelFlick.height))
  }
  // Walk nested repeaters to find the visual item at a flat index.
  function findFlatItem(flatIdx) {
    var remaining = flatIdx
    for (var s = 0; s < serverRepeater.count; s++) {
      var block = serverRepeater.itemAt(s)
      if (!block) continue
      var inner = block.innerRepeater
      if (!inner) continue
      if (remaining < inner.count) return inner.itemAt(remaining)
      remaining -= inner.count
    }
    return null
  }

  // Stop copy timers/process on destruction to avoid dangling signals.
  function shutdownClipboard() {
    copyTimeout.stop()
    copyKill.stop()
    if (copyProcess.running) copyProcess.signal(15)
    copyBusy = false
    copyTimedOut = false
  }

  // ── State-change handlers ──
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    refreshNow()
    selectedIndex = flatModels.length > 0 ? 0 : -1
    clearUnloadConfirmation()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onServersChanged: {
    if (selectedIndex >= flatModels.length) selectedIndex = flatModels.length - 1
    clearUnloadConfirmation()
    Qt.callLater(ensureSelectedVisible)
  }
  onSelectedIndexChanged: {
    if (confirmedModelName !== "" && actionableModelIdAt(selectedIndex) !== confirmedModelName) clearUnloadConfirmation()
    Qt.callLater(ensureSelectedVisible)
  }

  // 1 s clock: drives relative-age / expiry labels while the panel is open.
  Timer { interval: 1000; running: root.opened; repeat: true; onTriggered: root.nowMs = Date.now() }

  // ── Clipboard kill-ladder: timeout (3 s) → terminate → SIGKILL (250 ms) ──
  Timer {
    id: copyTimeout
    interval: 3000
    repeat: false
    onTriggered: {
      if (!root.copyBusy) return
      root.copyTimedOut = true
      copyProcess.running = false
      copyKill.restart()
      root.setCopyFeedback("Clipboard setup timed out")
    }
  }

  Timer {
    id: copyKill
    interval: 250
    repeat: false
    onTriggered: if (copyProcess.running) copyProcess.signal(9)
  }

  // wl-copy child; exit 0 = copied, anything else = clipboard unavailable.
  Process {
    id: copyProcess
    command: []
    clearEnvironment: true
    environment: root.clipboardEnvironment
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (copyProcess.running) return
      if (root.copyBusy) {
        root.copyBusy = false
        copyTimeout.stop()
        copyKill.stop()
        if (!root.copyTimedOut) root.setCopyFeedback("Clipboard unavailable")
        root.copyTimedOut = false
      }
    })
    onExited: function(exitCode) {
      copyTimeout.stop()
      copyKill.stop()
      if (root.copyTimedOut) { root.copyBusy = false; root.copyTimedOut = false; return }
      if (!root.copyBusy) return
      root.copyBusy = false
      if (exitCode === 0) root.setCopyFeedback("Model name copied")
      else root.setCopyFeedback("Clipboard unavailable")
    }
  }

  // ── Lifecycle hooks ──
  Component.onDestruction: root.shutdownClipboard()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(408))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.selectStep(dy)
        if (dx !== 0) root.clearUnloadConfirmation()
      }
      onActivateRequested: {
        if (root.selectedIndex >= 0) root.requestUnload(root.selectedIndex)
        else root.refreshNow()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshNow()
        else if (text === "c" || text === "C") root.copySelectedModelName()
        else if ((text === "u" || text === "U") && root.selectedIndex >= 0) root.requestUnload(root.selectedIndex)
      }

      Flickable {
        id: modelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: modelFlick.width
          spacing: Style.space(14)

          // ── Header: brand + title + server status ──
          Item {
            width: parent.width
            height: Style.space(48)
            Rectangle {
              id: brand
              width: Style.space(42); height: width
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.space(12)
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, .12)
              Text { anchors.centerIn: parent; text: "\u{1f9e0}"; color: Color.accent; font.pixelSize: Style.space(22); textFormat: Text.PlainText }
            }
            Column {
              anchors.left: brand.right
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)
              Text { text: "Ollama"; color: root.foreground; font.pixelSize: Style.space(22); font.weight: Font.DemiBold; textFormat: Text.PlainText }
              Text {
                text: servers.length + " server" + (servers.length !== 1 ? "s" : "") + " \u00b7 " + root.onlineCount() + " online"
                color: root.foreground; opacity: .6; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText
              }
            }
            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: statusLabel.implicitWidth + Style.space(22)
              height: Style.space(26)
              radius: height / 2
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, .1)
              Row {
                id: statusLabel
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: "\u25cf"
                  color: root.onlineCount() > 0 ? Qt.rgba(.2, .8, .4, 1) : root.urgent
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                }
                Text {
                  text: root.onlineCount() > 0 ? root.onlineCount() + "/" + servers.length + " online" : servers.length > 0 ? "All offline" : "Checking"
                  color: root.foreground
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                }
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .1) }

          // ── LOADED MODELS summary ──
          Item {
            width: parent.width
            height: Style.space(16)
            Text { text: "LOADED MODELS"; color: root.foreground; opacity: .6; font.bold: true; font.pixelSize: Style.font.bodySmall; font.letterSpacing: .8; textFormat: Text.PlainText }
            Text { anchors.right: parent.right; text: root.totalLoadedCount() + " loaded" + (root.aggregateVram() !== "" ? " \u00b7 " + root.aggregateVram() + " GPU" : ""); color: root.foreground; opacity: .65; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
          }

          // ── Empty state ──
          Rectangle {
            visible: root.flatModels.length === 0 && root.onlineCount() === 0
            width: parent.width
            implicitHeight: emptyMessage.implicitHeight + Style.space(28)
            radius: Style.space(10)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .04)
            Text {
              id: emptyMessage
              anchors.fill: parent
              anchors.margins: Style.space(14)
              text: root.servers.length === 0 ? "No servers configured\nAdd a servers object to your shell.json entry."
                    : "All servers unreachable\nCheck that your Ollama services are running."
              color: root.foreground
              font.pixelSize: Style.font.body
              lineHeight: 1.5
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
            }
          }

          // ── Server sections (nested repeater) ──
          Repeater {
            id: serverRepeater
            model: root.servers
            delegate: Column {
              required property var modelData
              required property int index
              readonly property string srvUrl: modelData ? modelData.url : ""
              width: contentColumn.width
              spacing: Style.space(8)
              visible: modelData ? true : false

              // Server header row
              Item {
                width: parent.width
                height: Style.space(32)
                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8); height: width
                  radius: width / 2
                  color: modelData && modelData.state === "online" ? Qt.rgba(.2, .8, .4, 1) : root.urgent
                }
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  text: (modelData ? modelData.name : "") + (modelData && modelData.version ? "  v" + modelData.version : "")
                  color: root.foreground
                  font.pixelSize: Style.font.body
                  font.weight: Font.DemiBold
                  textFormat: Text.PlainText
                }
                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData && modelData.state === "online"
                    ? modelData.loadedModelCount + " loaded" + (modelData.aggregateVramBytes > 0 ? " \u00b7 " + OllamaModel.formatBytes(modelData.aggregateVramBytes) : "")
                    : modelData && modelData.error ? modelData.error : "offline"
                  color: modelData && modelData.state === "online" ? root.foreground : root.urgent
                  opacity: modelData && modelData.state === "online" ? .65 : 1
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideLeft
                  width: Math.min(implicitWidth, parent.width * 0.55)
                  textFormat: Text.PlainText
                }
              }

              // Inner model rows for this server
              Repeater {
                id: innerRepeater
                model: modelData && modelData.state === "online" && modelData.models ? modelData.models : []
                delegate: FocusScope {
                  required property var modelData
                  required property int index
                  readonly property var modelItem: modelData || ({})
                  readonly property int flatIdx: root.flatIndexOf(parent.srvUrl, modelItem.modelId || "")
                  readonly property bool selected: root.selectedIndex === flatIdx
                  width: contentColumn.width
                  implicitHeight: modelInfo.implicitHeight + Style.space(28)
                  activeFocusOnTab: true
                  Keys.onReturnPressed: root.requestUnload(flatIdx)
                  Keys.onSpacePressed: root.requestUnload(flatIdx)
                  onSelectedChanged: if (selected) Qt.callLater(root.ensureSelectedVisible)
                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(8)
                    color: selected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.07) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                    border.width: selected ? 1 : 0
                    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, .4)
                  }
                  Column {
                    id: modelInfo
                    anchors.left: parent.left
                    anchors.right: unloadLabel.left
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(5)
                    Text { width: parent.width; text: root.plain(modelItem.displayName, 160); color: root.foreground; font.pixelSize: Style.space(17); font.weight: Font.DemiBold; elide: Text.ElideRight; textFormat: Text.PlainText }
                    Text { width: parent.width; text: (modelItem.size > 0 ? OllamaModel.formatBytes(modelItem.size) : "") + (modelItem.size > 0 && modelItem.sizeVram > 0 ? " \u00b7 " + Math.min(100, Math.round(modelItem.sizeVram / modelItem.size * 100)) + "% GPU" : "") + (modelItem.context ? " \u00b7 ctx " + root.plain(modelItem.context, 20) : ""); visible: text !== ""; color: root.foreground; opacity: .7; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight; textFormat: Text.PlainText }
                    Text {
                      text: { root.nowMs; return OllamaModel.relativeExpiry(modelItem.expiresAt) }
                      visible: text !== ""; color: root.foreground; opacity: .6; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText
                    }
                  }
                  Text {
                    id: unloadLabel
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(14)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.ollamaService && root.ollamaService.busy && root.ollamaService.pendingModel === (modelItem.modelId || "") ? "\u2026" : (modelItem.modelId || "") === "" ? "Unavailable" : selected && root.confirmUnload && root.confirmedModelName === (modelItem.modelId || "") ? "Confirm" : "Unload"
                    color: root.urgent
                    font.pixelSize: Style.font.bodySmall
                    font.underline: selected && root.confirmUnload
                    textFormat: Text.PlainText
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: !root.ollamaService || !root.ollamaService.busy
                    cursorShape: (modelItem.modelId || "") !== "" && enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.requestUnload(flatIdx)
                  }
                }
              }

              // Separator between server blocks (not after last)
              Rectangle {
                visible: index < serverRepeater.count - 1
                width: parent.width
                height: 1
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .08)
              }
            }
          }

          // ── Footer buttons ──
          Row {
            width: parent.width
            spacing: Style.space(8)
            MenuAction {
              width: (parent.width - parent.spacing) / 2
              label: "\u29c9  Copy name   C"
              enabled: root.actionableModelIdAt(root.selectedIndex) !== "" && !root.copyBusy
              onClicked: root.copySelectedModelName()
            }
            MenuAction {
              width: (parent.width - parent.spacing) / 2
              label: root.refreshing ? "\u21bb  Refreshing\u2026" : "\u21bb  Refresh   R"
              enabled: !root.ollamaService || !root.ollamaService.busy
              onClicked: root.refreshNow()
            }
          }

          Rectangle { width: parent.width; height: 1; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .1) }

          Text { visible: root.ollamaService && root.ollamaService.feedbackText !== ""; width: parent.width; text: root.ollamaService ? root.ollamaService.feedbackText : ""; color: root.urgent; wrapMode: Text.Wrap; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
          Item {
            width: parent.width
            height: footerText.implicitHeight
            Text {
              id: footerText
              width: parent.width - closeHint.implicitWidth - Style.space(10)
              text: root.ollamaService && root.ollamaService.busy ? "Unloading model\u2026" : root.activeCopyFeedback() !== "" ? root.activeCopyFeedback() : root.confirmUnload ? "Press Enter or click again to unload" : root.refreshing ? "Refreshing\u2026" : root.refreshAge()
              color: root.foreground
              opacity: .6
              wrapMode: Text.Wrap
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }
            Text { id: closeHint; anchors.right: parent.right; text: "Esc  Close"; color: root.foreground; opacity: .45; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
          }
        }
      }
    }
  }
}
