import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "OllamaModel.js" as OllamaModel

// The small bar face hosts the real Panel so Omarchy can summon, switch, and
// mark it like every built-in panel. Service.qml remains the only API owner.
BarWidget {
  id: root
  moduleName: "flori.ollama-ps"
  readonly property var ollamaService: root.bar?.shell?.serviceFor("flori.ollama-ps") || null
  readonly property string state: ollamaService ? ollamaService.state : "checking"
  readonly property string errorText: ollamaService ? OllamaModel.plainText(ollamaService.errorText, 300) : ""
  readonly property var servers: ollamaService && Array.isArray(ollamaService.servers) ? ollamaService.servers : []
  readonly property var effectiveSettings: ({
    refreshIntervalSec: integerSetting("refreshIntervalSec", 15, 5, 300),
    maxDisplayedModels: Math.max(1, Math.floor(Number(setting("maxDisplayedModels", 12)) || 12)),
    compactMode: booleanSetting("compactMode", false),
    servers: setting("servers", {})
  })
  // ModuleSlot is the injected bar's authoritative instance record. Its
  // screen, region, and module id identify one live widget without relying on
  // a transient QML object string.
  readonly property var configurationSlot: {
    var slots = root.bar && Array.isArray(root.bar.moduleSlots) ? root.bar.moduleSlots : []
    for (var i = 0; i < slots.length; i++) if (slots[i] && slots[i].activeItem === root) return slots[i]
    return null
  }
  // Stable tracking key for the configure/unconfigure dance. Falls back to
  // "default" when the slotWindow→screen chain is unresolved (common).
  readonly property string serviceConfigurationSource: {
    var slot = configurationSlot
    if (!root.bar || !slot || typeof root.bar.slotWindow !== "function") return "default"
    var window = root.bar.slotWindow(slot)
    var screenName = window && window.screen ? String(window.screen.name || "") : ""
    if (!screenName || !slot.region || !slot.moduleName) return "default"
    return "bar-slot:" + screenName + ":" + String(slot.region) + ":" + String(slot.moduleName)
  }
  property string configuredServiceSource: ""

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // ── Settings coercion & label rendering ──
  function integerSetting(name, fallback, minimum, maximum) {
    var value = Number(setting(name, fallback))
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, Math.floor(value)))
  }
  function booleanSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || value === "true" || value === 1 || value === "1"
  }
  function onlineCount() {
    var n = 0
    for (var s = 0; s < servers.length; s++)
      if (servers[s] && servers[s].state === "online") n++
    return n
  }
  function barLabel() {
    if (root.vertical) return "\u{1f9e0}"
    var compact = root.effectiveSettings.compactMode
    var count = Number(ollamaService
      && ollamaService.totalLoadedModelCount) || 0
    var vram = OllamaModel.formatBytes(Number(ollamaService
      && ollamaService.totalAggregateVramBytes) || 0)
    var online = root.onlineCount()
    var total = root.servers.length
    var s = online + "/" + total
    if (root.state === "loaded")
      return compact
        ? "\u{1f9e0} " + count + " · " + vram + " · " + s
        : "\u{1f9e0} " + count + " models · " + vram
          + " · " + s + " servers"
    if (root.state === "idle")
      return compact
        ? "\u{1f9e0} " + s
        : "\u{1f9e0} " + s + " servers, no models"
    if (root.state === "checking")
      return "\u{1f9e0} " + (compact ? "…" : "Ollama…")
    return "\u{1f9e0} "
      + (compact ? "Offline" : "Ollama unavailable")
  }
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function togglePanel() { if (opened) close(); else open() }
  // Wire bar, anchor, service, and settings into the loaded panel.
  function injectPanel() {
    var panel = panelLoader.item
    if (!panel) return
    if ("bar" in panel) panel.bar = root.bar
    if ("anchorItem" in panel) panel.anchorItem = button
    if ("hostWidget" in panel) panel.hostWidget = root
    if ("ollamaService" in panel) panel.ollamaService = root.ollamaService
    if ("settings" in panel) panel.settings = root.effectiveSettings
    if ("effectiveSettings" in panel) panel.effectiveSettings = root.effectiveSettings
    configureService()
  }
  // Unconfigure stale source, then register this widget's settings.
  // Reads setting() fresh at call time so the 30 s sync timer and
  // event-driven calls always see the current bar-model state.
  function configureService() {
    if (!ollamaService || !serviceConfigurationSource || typeof ollamaService.configure !== "function") return
    if (configuredServiceSource !== "" && configuredServiceSource !== serviceConfigurationSource
        && typeof ollamaService.unconfigure === "function")
      ollamaService.unconfigure(configuredServiceSource)
    ollamaService.configure(({
      refreshIntervalSec: integerSetting("refreshIntervalSec", 15, 5, 300),
      maxDisplayedModels: Math.max(1, Math.floor(Number(setting("maxDisplayedModels", 12)) || 12)),
      compactMode: booleanSetting("compactMode", false),
      servers: setting("servers", {})
    }), serviceConfigurationSource)
    configuredServiceSource = serviceConfigurationSource
  }

  // ── Sizing, change-propagation & lifecycle hooks ──
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onOllamaServiceChanged: injectPanel()
  onEffectiveSettingsChanged: { injectPanel(); configureService() }
  onServiceConfigurationSourceChanged: configureService()
  Component.onCompleted: configureService()
  Component.onDestruction: if (ollamaService && configuredServiceSource !== "" && typeof ollamaService.unconfigure === "function") ollamaService.unconfigure(configuredServiceSource)

  // Periodic config sync: re-reads setting() every 30 s to self-heal
  // transient {} from bar-model rebuilds and pick up shell.json edits.
  // Service.qml's sameSettings() makes no-op reconfigure calls free.
  Timer {
    id: settingsRetry
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.configureService()
  }

  // Loads Panel.qml (kept off-tree/invisible until the bar is clicked).
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  // The visible bar face: aggregate label + state-colored foreground.
  WidgetButton {
    id: button
    bar: root.bar
    text: root.barLabel()
    fontSize: Style.font.body
    horizontalMargin: root.vertical ? Style.space(2) : Style.space(4)
    pressFeedbackButtons: Qt.NoButton
    foreground: root.state === "unavailable" ? (root.bar ? root.bar.urgent : Color.urgent) : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: {
      var c = Number(ollamaService
        && ollamaService.totalLoadedModelCount) || 0
      var v = OllamaModel.formatBytes(Number(ollamaService
        && ollamaService.totalAggregateVramBytes) || 0)
      var on = root.onlineCount(), tot = root.servers.length
      if (root.state === "loaded")
        return "Ollama: " + c + " models · " + v
          + " GPU · " + on + "/" + tot
          + " servers online\nEnter opens controls"
      if (root.state === "idle")
        return "Ollama: no models · " + on + "/" + tot
          + " servers online\nEnter opens controls"
      return root.errorText !== ""
        ? root.errorText : "Checking the Ollama API…"
    }
    onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.togglePanel() }
  }
}
