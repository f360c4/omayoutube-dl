import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry for OmaYoutube-dl. Owns the button label, forwards open/close
// to the nested panel, mirrors download progress into the bar tooltip.
BarWidget {
  id: root
  moduleName: "io.github.aznit11.omayoutube-dl"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real activePct: panelLoader.item ? panelLoader.item.activePct : -1
  readonly property bool downloading: panelLoader.item ? panelLoader.item.downloading === true : false
  readonly property bool previewPlaying: panelLoader.item ? panelLoader.item.previewPlaying === true : false

  function open(payloadJson) {
    if (panelLoader.item) panelLoader.item.open(payloadJson);
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close();
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle();
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch();
  }

  function injectPanel() {
    var target = panelLoader.item;
    if (!target) return;
    if ("bar" in target) target.bar = root.bar;
    if ("settings" in target) target.settings = root.settings;
    if ("anchorItem" in target) target.anchorItem = button;
    if ("hostWidget" in target) target.hostWidget = root;
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel();
      Qt.callLater(root.injectPanel);
    }
  }

  IpcHandler {
    target: "io.github.aznit11.omayoutube-dl"

    function open(): void { root.open(); }
    function close(): void { root.close(); }
    function show(): void { root.open(); }
    function hide(): void { root.close(); }
    function toggle(): void { root.togglePanel(); }
    function transcribe(url: string): void { if (panelLoader.item) panelLoader.item.transcribe("ipc test", url); }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.downloading ? ("󰇚 " + Math.round(root.activePct) + "%") : (root.previewPlaying ? "󰏤 YT" : "󰇚 YT")
    tooltipText: root.downloading ? ("Downloading " + Math.round(root.activePct) + "% — open OmaYoutube-dl") : "Open OmaYoutube-dl"
    onPressed: function(b) {
      root.togglePanel();
    }
  }
}
