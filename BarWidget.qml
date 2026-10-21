pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar home for the standalone weather panel: home's condition glyph and
// temperature. The panel stays loaded in omarchy-shell, so opening it is
// a local state change, and its background refresh keeps this current.
BarWidget {
  id: root
  moduleName: "io.github.olivoil.weather"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property string barGlyph: panelLoader.item
    ? String(panelLoader.item.barGlyph || "") : ""
  readonly property string barTemperature: panelLoader.item
    ? String(panelLoader.item.barTemperature || "") : ""
  readonly property color barGlyphColor: panelLoader.item
    && panelLoader.item.barGlyphColor !== undefined
    ? panelLoader.item.barGlyphColor
    : (bar ? bar.foreground : Color.foreground)
  readonly property string barTooltip: panelLoader.item
    ? String(panelLoader.item.barTooltip || "Weather") : "Weather"
  readonly property bool hasWeather: barGlyph !== "" && barTemperature !== ""
  readonly property Item activeButton: hasWeather && !vertical
    ? weatherButton : iconButton
  readonly property real openPanelIndicatorWidth: hasWeather && !vertical
    ? weatherContent.implicitWidth
    : Math.max(Style.space(10), Math.round(activeButton.implicitWidth * 0.55))

  implicitWidth: activeButton.implicitWidth
  implicitHeight: activeButton.implicitHeight

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root.activeButton
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refreshWeatherNow)
      panelLoader.item.refreshWeatherNow()
  }

  function handlePress(buttonCode) {
    if (buttonCode === Qt.MiddleButton) root.refresh()
    else if (buttonCode === Qt.LeftButton) root.togglePanel()
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onActiveButtonChanged: injectPanel()

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

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
    function status(): string { return root.opened ? "open" : "closed" }
  }

  BarIconButton {
    id: iconButton
    anchors.fill: parent
    bar: root.bar
    visible: !root.hasWeather || root.vertical
    text: root.barGlyph !== "" ? root.barGlyph : ""
    slotSize: Style.bar.statusSlot
    foreground: root.barGlyphColor
    useActiveColor: false
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) { root.handlePress(buttonCode) }
  }

  WidgetButton {
    id: weatherButton
    anchors.fill: parent
    bar: root.bar
    visible: root.hasWeather && !root.vertical
    labelVisible: false
    hasVisualContent: visible
    useActiveColor: false
    fixedWidth: weatherContent.implicitWidth + Style.space(11)
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) { root.handlePress(buttonCode) }

    Row {
      id: weatherContent
      anchors.centerIn: parent
      spacing: Style.space(4)

      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        anchors.verticalCenter: parent.verticalCenter

        OpticalGlyph {
          anchors.fill: parent
          text: root.barGlyph
          fontFamily: weatherButton.fontFamily
          fontSize: Style.bar.iconFont
          color: root.barGlyphColor
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.barTemperature
        color: weatherButton.foreground
        font.family: weatherButton.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }
    }
  }
}
