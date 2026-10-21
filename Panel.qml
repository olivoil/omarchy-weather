pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Standalone home for the World Clock weather detail view. Locations, the
// home city, and units are Elsewhen's (omarchy.elsewhen), read live from
// shell.json; the panel always opens on home. Weather comes from
// Open-Meteo, shaped by Model.js the way the World Clock backend shaped
// it, so WeatherDetail renders unchanged.
Panel {
  id: root
  moduleName: "io.github.olivoil.weather"
  ipcTarget: moduleName
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Elsewhen's settings, followed live
  property var elsewhenSettings: ({ zonesSpec: "", homeCity: "", units: "", hour24: "" })
  readonly property var zones: Model.parseZones(elsewhenSettings.zonesSpec)
  property string localZone: ""
  readonly property var home: Model.homeZone(elsewhenSettings.homeCity, localZone)
  readonly property var locations: Model.locationList(zones, home)
  readonly property string homeKey: home ? Model.factsKey(home) : ""

  readonly property var formatLocale: Qt.locale(I18n.formatLocale)
  readonly property string autoUnits:
    formatLocale.measurementSystem === Locale.ImperialUSSystem ? "F" : "C"
  readonly property bool weatherUseImperial:
    Model.resolveUnits(elsewhenSettings.units, autoUnits) === "F"
  readonly property bool hour24: {
    if (elsewhenSettings.hour24 === true || elsewhenSettings.hour24 === false)
      return elsewhenSettings.hour24
    return !/[Aa]/.test(formatLocale.timeFormat(Locale.ShortFormat)
      .replace(/'[^']*'/g, ""))
  }
  readonly property int refreshMinutes: {
    var value = Number(setting("refreshMinutes", 15))
    return isFinite(value) ? Math.max(5, Math.min(120, Math.round(value))) : 15
  }

  // ---- clocks and weather state
  property var probedClocks: ({})
  property double probedAt: 0
  property double nowMs: Date.now()
  property bool probeQueued: false
  property var coords: ({})
  property var fallbackCoords: ({})
  property bool factsQueued: false
  property var weatherByKey: ({})
  property bool weatherError: false
  property double weatherLastUpdatedAt: 0
  property double weatherLastAttemptAt: 0

  // Selection is a "label|zone" key; empty means home.
  property string selectedKey: ""
  readonly property var selectedLocation: {
    for (var i = 0; i < locations.length; i++)
      if (Model.factsKey(locations[i]) === selectedKey) return locations[i]
    return locations.length > 0 ? locations[0] : null
  }

  readonly property string referenceUtc: new Date(nowMs).toISOString()
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool weatherLoading: weatherProc.running || geoProc.running

  // ---- the contract WeatherDetail reads off its controller
  readonly property string weatherDetailKey:
    selectedLocation ? Model.factsKey(selectedLocation) : ""
  readonly property var weatherDetailClock: {
    if (!selectedLocation) return null
    var ticked = Model.tickedClock(probedClocks[selectedLocation.id],
      probedAt, nowMs)
    return {
      label: selectedLocation.label,
      title: selectedLocation.label,
      timezone: selectedLocation.id,
      date: ticked ? ticked.date : "",
      time: ticked ? root.formatClockTime(ticked.time) : "--:--",
      local_minutes: ticked ? ticked.localMinutes : 0,
      notation: ticked ? ticked.notation : "",
      day: ""
    }
  }
  readonly property var weatherDetailData:
    weatherDetailKey !== "" ? (weatherByKey[weatherDetailKey] || null) : null
  readonly property var weatherDetailHourlyForecast: {
    var forecast = weatherDetailData
      && Array.isArray(weatherDetailData.hourly_forecast)
      ? weatherDetailData.hourly_forecast : []
    var currentMoment = root.weatherUtcMoment(referenceUtc)
    if (!isFinite(currentMoment)) return forecast
    var currentAndFuture = []
    for (var i = 0; i < forecast.length; i++) {
      var forecastStart = root.weatherUtcMoment(forecast[i].reference_utc)
      if (isFinite(forecastStart) && forecastStart + 3600000 > currentMoment)
        currentAndFuture.push(forecast[i])
    }
    return currentAndFuture
  }
  readonly property var weatherDetailDailyForecast: {
    var days = []
    if (!weatherDetailData) return days
    if (weatherDetailData.today) days.push(weatherDetailData.today)
    var forecast = Array.isArray(weatherDetailData.forecast)
      ? weatherDetailData.forecast : []
    for (var i = 0; i < forecast.length; i++) days.push(forecast[i])
    return days
  }
  readonly property string weatherDetailLocalDate: weatherDetailClock
    ? String(weatherDetailClock.date || "") : ""
  readonly property int weatherDetailTodayIndex: {
    for (var i = 0; i < weatherDetailDailyForecast.length; i++) {
      if (String(weatherDetailDailyForecast[i].date || "")
          === weatherDetailLocalDate) return i
    }
    return -1
  }
  readonly property var weatherDetailToday:
    weatherDetailTodayIndex >= 0
      ? weatherDetailDailyForecast[weatherDetailTodayIndex] : null
  readonly property var weatherDetailForecast:
    weatherDetailTodayIndex >= 0
      ? weatherDetailDailyForecast.slice(
          weatherDetailTodayIndex + 1, weatherDetailTodayIndex + 5) : []

  // What the bar widget paints: home, always.
  readonly property var homeWeather:
    homeKey !== "" ? (weatherByKey[homeKey] || null) : null
  readonly property string barGlyph: homeWeather ? weatherGlyph(homeWeather) : ""
  readonly property color barGlyphColor: weatherGlyphColor(homeWeather)
  readonly property string barTemperature: homeWeather
    ? weatherTemperatureCompact(homeWeather.temperature_celsius) : ""
  readonly property string barTooltip: {
    if (!home) return "Weather"
    if (!homeWeather) return "Weather · " + home.label
    return home.label + "  ·  "
      + weatherTemperature(homeWeather.temperature_celsius) + "  ·  "
      + String(homeWeather.condition || "")
  }

  function open() {
    // Always land on home, whatever was showing last time.
    selectedKey = homeKey
    root.controller.show()
    shellFile.reload()
    // With nothing loaded yet, an open is reason enough to retry a
    // failed first fetch instead of waiting out the error cooldown.
    probe()
    refreshFacts(weatherLastUpdatedAt === 0)
    Qt.callLater(function() {
      if (root.opened && detail.visible) detail.focusInitialControl()
    })
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    probe()
    refreshFacts(false)
  }

  function refreshWeatherNow() {
    probe()
    refreshFacts(true)
  }

  function selectLocation(key) {
    selectedKey = String(key || "")
    Qt.callLater(function() {
      if (root.opened && detail.visible) detail.focusInitialControl()
    })
  }

  function moveSelection(step) {
    if (locations.length === 0) return
    var index = 0
    for (var i = 0; i < locations.length; i++)
      if (Model.factsKey(locations[i]) === weatherDetailKey) index = i
    var next = (index + step + locations.length) % locations.length
    selectLocation(Model.factsKey(locations[next]))
  }

  function probe() {
    if (probeProc.running) { probeQueued = true; return }
    var ids = []
    var seen = ({})
    for (var i = 0; i < locations.length; i++) {
      if (!seen[locations[i].id]) { seen[locations[i].id] = true; ids.push(locations[i].id) }
    }
    probeProc.command = Model.probeCommand(ids)
    probeProc.running = true
  }

  function coordsFor(key) {
    return coords[key] || fallbackCoords[key] || null
  }

  function refreshFacts(force) {
    if (locations.length === 0) return
    if (geoProc.running || weatherProc.running) { factsQueued = true; return }
    var missing = locations.filter(function(row) {
      return !coords[Model.factsKey(row)]
    })
    if (missing.length === 0) { fetchWeather(force); return }
    geoProc.rows = missing
    geoProc.command = ["bash", "-c",
      'for url; do curl -fsS --max-time 8 "$url"; printf "\\n\\036\\n"; done', "bash"]
      .concat(missing.map(function(row) { return Model.geocodeUrl(row.label) }))
    geoProc.running = true
  }

  function fetchWeather(force) {
    var rows = locations.filter(function(row) {
      return coordsFor(Model.factsKey(row)) !== null
    })
    if (rows.length === 0) return
    if (!force && !Model.weatherStale(weatherLastUpdatedAt, Date.now(),
        refreshMinutes * 60000)) return
    // Keep a failed network from turning each refresh tick into a burst.
    if (!force && weatherError
        && Date.now() - weatherLastAttemptAt < 2 * 60000) return
    weatherLastAttemptAt = Date.now()
    weatherProc.rows = rows
    weatherProc.command = ["curl", "-fsS", "--max-time", "10",
      Model.forecastUrl(rows.map(function(row) {
        return coordsFor(Model.factsKey(row))
      }))]
    weatherProc.running = true
  }

  function formatClockTime(hhmm) {
    var match = /^(\d{2}):(\d{2})$/.exec(String(hhmm || ""))
    if (!match) return "--:--"
    if (hour24) return match[1] + ":" + match[2]
    var hour = Number(match[1])
    var suffix = hour >= 12 ? "PM" : "AM"
    var displayHour = hour % 12
    if (displayHour === 0) displayHour = 12
    return String(displayHour) + ":" + match[2] + " " + suffix
  }

  function clockDayLabel(clock) {
    var date = new Date(String(clock && clock.date || "") + "T12:00:00")
    return isNaN(date.getTime()) ? "" : Qt.formatDate(date, "dddd")
  }

  function mixColor(base, tint, amount) {
    var ratio = Math.max(0, Math.min(1, Number(amount)))
    return Qt.rgba(
      base.r * (1 - ratio) + tint.r * ratio,
      base.g * (1 - ratio) + tint.g * ratio,
      base.b * (1 - ratio) + tint.b * ratio,
      1)
  }


  // ---- weather formatting, from the World Clock panel
  function weatherNumber(value) {
    if (value === null || value === undefined || value === "") return NaN
    return Number(value)
  }

  function weatherTemperature(value) {
    var celsius = weatherNumber(value)
    if (!isFinite(celsius)) return ""
    var temperature = weatherUseImperial ? celsius * 9 / 5 + 32 : celsius
    return String(Math.round(temperature)) + "°" + (weatherUseImperial ? "F" : "C")
  }

  function weatherTemperatureCompact(value) {
    return weatherTemperature(value).replace(/[FC]$/, "")
  }

  function weatherTemperatureOrDash(value) {
    return isFinite(weatherNumber(value)) ? weatherTemperature(value) : "—"
  }

  function weatherWind(value) {
    var speed = weatherNumber(value)
    if (!isFinite(speed)) return "—"
    if (weatherUseImperial) return String(Math.round(speed * 0.621371)) + " mph"
    return String(Math.round(speed)) + " km/h"
  }

  function weatherHumidity(value) {
    var humidity = weatherNumber(value)
    return isFinite(humidity) ? String(Math.round(humidity)) + "%" : "—"
  }

  function weatherProbability(value) {
    var probability = weatherNumber(value)
    return isFinite(probability) ? String(Math.round(probability)) + "%" : "—"
  }

  function weatherPrecipitation(value) {
    var millimeters = weatherNumber(value)
    if (!isFinite(millimeters)) return "—"
    if (weatherUseImperial) {
      var inches = millimeters / 25.4
      return inches.toFixed(inches < 0.1 ? 2 : 1) + " in"
    }
    return millimeters.toFixed(millimeters < 10 ? 1 : 0) + " mm"
  }

  function weatherWindDirection(value) {
    var degrees = weatherNumber(value)
    if (!isFinite(degrees)) return ""
    var directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    var index = Math.round(((degrees % 360) + 360) % 360 / 45) % 8
    return directions[index]
  }

  function weatherWindDetailed(speedValue, directionValue, gustValue) {
    var speed = weatherNumber(speedValue)
    if (!isFinite(speed)) return "—"
    var displaySpeed = weatherUseImperial ? speed * 0.621371 : speed
    var direction = weatherWindDirection(directionValue)
    var result = (direction ? direction + "  " : "")
      + String(Math.round(displaySpeed))
    var gust = weatherNumber(gustValue)
    if (isFinite(gust) && gust > speed + 1) {
      var displayGust = weatherUseImperial ? gust * 0.621371 : gust
      result += "  ·  G" + String(Math.round(displayGust))
    }
    return result + (weatherUseImperial ? " mph" : " km/h")
  }

  function weatherPressure(value) {
    var pressure = weatherNumber(value)
    if (!isFinite(pressure)) return "—"
    if (weatherUseImperial) return (pressure * 0.0295299830714).toFixed(2) + " inHg"
    return String(Math.round(pressure)) + " hPa"
  }

  function weatherVisibility(value) {
    var meters = weatherNumber(value)
    if (!isFinite(meters)) return "—"
    if (weatherUseImperial) {
      var miles = meters / 1609.344
      return (miles < 10 ? miles.toFixed(1) : String(Math.round(miles))) + " mi"
    }
    var kilometers = meters / 1000
    return (kilometers < 10 ? kilometers.toFixed(1)
      : String(Math.round(kilometers))) + " km"
  }

  function weatherLocalTime(value) {
    var match = String(value || "").match(/T(\d{2}):(\d{2})/)
    if (!match) return "—"
    var hour = Number(match[1])
    var minute = match[2]
    if (hour24)
      return String(match[1]) + ":" + minute
    var suffix = hour >= 12 ? "PM" : "AM"
    var displayHour = hour % 12
    if (displayHour === 0) displayHour = 12
    return String(displayHour) + ":" + minute + " " + suffix
  }

  function weatherUtcMoment(value) {
    var milliseconds = Date.parse(String(value || ""))
    return isFinite(milliseconds) ? milliseconds : NaN
  }

  function weatherHourlyIsCurrent(item) {
    var currentMoment = weatherUtcMoment(referenceUtc)
    var forecastStart = weatherUtcMoment(item ? item.reference_utc : "")
    return isFinite(currentMoment) && isFinite(forecastStart)
      && currentMoment >= forecastStart
      && currentMoment < forecastStart + 3600000
  }

  function weatherHourlyTime(item) {
    if (weatherHourlyIsCurrent(item)) return "NOW"
    var formatted = weatherLocalTime(item ? item.time : "")
    if (formatted === "—") return formatted
    return formatted.replace(":00", "")
  }

  function weatherUv(value) {
    var uv = weatherNumber(value)
    if (!isFinite(uv)) return "—"
    var rounded = Math.round(uv)
    var level = rounded >= 11 ? "Extreme"
      : (rounded >= 8 ? "Very high"
        : (rounded >= 6 ? "High" : (rounded >= 3 ? "Moderate" : "Low")))
    return String(rounded) + "  " + level
  }

  function weatherNextHourForecast() {
    for (var i = 0; i < weatherDetailHourlyForecast.length - 1; i++) {
      if (weatherHourlyIsCurrent(weatherDetailHourlyForecast[i]))
        return weatherDetailHourlyForecast[i + 1]
    }
    return null
  }

  function weatherNextHourProbability() {
    var nextHour = weatherNextHourForecast()
    return nextHour
      ? weatherProbability(nextHour.precipitation_probability_percent) : "—"
  }

  function weatherForecastDay(dateValue) {
    var date = new Date(String(dateValue || "") + "T12:00:00")
    return isNaN(date.getTime()) ? "" : Qt.formatDate(date, "ddd").toUpperCase()
  }

  function weatherForecastGlyph(item) {
    return weatherGlyph({ weather_code: item ? item.weather_code : 3, is_day: true })
  }

  function weatherForecastGlyphColor(item) {
    return weatherGlyphColor({ weather_code: item ? item.weather_code : 3, is_day: true })
  }

  // Match the weather-icons glyph vocabulary already used by Omarchy's
  // native weather panel, including day/night-aware clear and cloud icons.
  function weatherGlyph(item) {
    if (!item) return ""
    var code = Number(item.weather_code)
    var night = item.is_day === false
    if (code === 0) return night ? "" : ""
    if (code === 1 || code === 2) return night ? "" : ""
    if (code === 3) return ""
    if (code === 45 || code === 48) return night ? "" : ""
    if (code === 51 || code === 53 || code === 55 || code === 56
        || code === 57 || code === 61) return ""
    if (code === 63 || code === 65 || code === 66 || code === 67
        || code === 80 || code === 81 || code === 82) return ""
    if (code === 71 || code === 73 || code === 75 || code === 77
        || code === 85 || code === 86) return ""
    if (code === 95 || code === 96 || code === 99) return ""
    return ""
  }

  function weatherGlyphColor(item) {
    var muted = Qt.darker(root.contentForeground, 1.45)
    if (!item) return muted
    var code = Number(item.weather_code)
    if (item.is_day === false)
      return mixColor(muted, Qt.rgba(0.50, 0.60, 0.90, 1), 0.66)
    if (code === 0 || code === 1 || code === 2)
      return mixColor(muted, Qt.rgba(0.96, 0.72, 0.27, 1), 0.68)
    if (code === 45 || code === 48 || code === 3)
      return mixColor(muted, Qt.rgba(0.58, 0.68, 0.73, 1), 0.52)
    if (code === 51 || code === 53 || code === 55 || code === 56
        || code === 57 || code === 61 || code === 63 || code === 65
        || code === 66 || code === 67 || code === 80 || code === 81
        || code === 82)
      return mixColor(muted, Qt.rgba(0.35, 0.66, 0.84, 1), 0.64)
    if (code === 71 || code === 73 || code === 75 || code === 77
        || code === 85 || code === 86)
      return mixColor(muted, Qt.rgba(0.72, 0.86, 0.92, 1), 0.58)
    if (code === 95 || code === 96 || code === 99)
      return mixColor(muted, Qt.rgba(0.66, 0.48, 0.84, 1), 0.64)
    return muted
  }

  function weatherText(item) {
    if (!item) return "WEATHER UNAVAILABLE"
    return weatherTemperature(item.temperature_celsius)
  }

  // ---- sources

  FileView {
    id: shellFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.elsewhenSettings = Model.parseElsewhenSettings(text())
      root.probe()
      root.refreshFacts(false)
    }
    onLoadFailed: root.elsewhenSettings =
      ({ zonesSpec: "", homeCity: "", units: "", hour24: "" })
  }

  FileView {
    id: zoneTab
    path: "/usr/share/zoneinfo/zone1970.tab"
    printErrors: false
  }

  Process {
    id: probeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var probedLocal = Model.localZoneFromProbe(text)
        if (probedLocal !== "") root.localZone = probedLocal
        root.probedClocks = Model.parseProbe(text)
        root.probedAt = Date.now()
        root.nowMs = Date.now()
        Qt.callLater(function() {
          if (!root.probeQueued) return
          root.probeQueued = false
          root.probe()
        })
      }
    }
  }

  Process {
    id: geoProc
    property var rows: []
    stdout: StdioCollector {
      onStreamFinished: {
        var answers = text.split("\n\u001e\n")
        var nextCoords = Object.assign({}, root.coords)
        var nextFallback = Object.assign({}, root.fallbackCoords)
        geoProc.rows.forEach(function(row, i) {
          var key = Model.factsKey(row)
          var found = Model.pickGeocode(answers[i] || "", row.id)
          var place = found.place || Model.zoneTabCoords(zoneTab.text(), row.id)
          if (!place) return
          if (found.answered) nextCoords[key] = place
          else nextFallback[key] = place
        })
        root.coords = nextCoords
        root.fallbackCoords = nextFallback
        root.fetchWeather(true)
        Qt.callLater(function() {
          if (!root.factsQueued) return
          root.factsQueued = false
          root.refreshFacts(false)
        })
      }
    }
  }

  Process {
    id: weatherProc
    property var rows: []
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = Model.parseWeather(text, weatherProc.rows)
        var count = 0
        for (var key in parsed) count++
        if (count > 0) {
          root.weatherByKey = Object.assign({}, root.weatherByKey, parsed)
          root.weatherLastUpdatedAt = Date.now()
          root.weatherError = count < weatherProc.rows.length
        } else {
          root.weatherError = true
        }
        Qt.callLater(function() {
          if (!root.factsQueued) return
          root.factsQueued = false
          root.refreshFacts(false)
        })
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.weatherError = true
    }
  }

  SystemClock {
    id: minuteClock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.nowMs = Date.now()
      if (root.opened) root.probe()
    }
  }

  // Background refresh keeps the bar's home temperature current; the
  // interval is the plugin's refreshMinutes setting.
  Timer {
    interval: root.refreshMinutes * 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    shellFile.reload()
    probe()
  }

  onLocationsChanged: refreshFacts(false)
  onHomeKeyChanged: {
    if (!opened) selectedKey = homeKey
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(960))
    contentHeight: panel.fittedContentHeight(
      contentColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveSelection(dx)
        else if (dy !== 0 && detail.visible) detail.scrollByDirection(dy)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(8)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Flow {
            width: parent.width - refreshButton.width - Style.space(6)
            spacing: Style.space(6)

            Repeater {
              model: root.locations

              Button {
                required property var modelData
                readonly property string locationKey:
                  Model.factsKey(modelData)
                text: modelData.label
                selected: locationKey === root.weatherDetailKey
                tooltipText: modelData.id
                  + (locationKey === root.homeKey ? "  ·  Home" : "")
                onClicked: root.selectLocation(locationKey)
              }
            }
          }

          Button {
            id: refreshButton
            text: "Refresh"
            tooltipText: "Refresh weather"
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(5)
            onClicked: root.refreshWeatherNow()
          }
        }

        WeatherDetail {
          id: detail
          visible: root.weatherDetailData !== null
          width: parent.width
          controller: root
          onBackRequested: root.close()
          onAttributionRequested:
            Qt.openUrlExternally("https://open-meteo.com/")
        }

        Text {
          textFormat: Text.PlainText
          visible: !detail.visible
          width: parent.width
          height: Style.space(120)
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: root.locations.length === 0
            ? "No Elsewhen locations found.\nAdd the Elsewhen world clock to the bar to choose locations."
            : (root.weatherError && !root.weatherLoading
              ? "Weather unavailable. Check the network, then refresh."
              : "Loading weather…")
          color: Qt.darker(root.contentForeground, 1.35)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}

