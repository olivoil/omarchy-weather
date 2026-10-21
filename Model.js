// Pure data layer for the standalone Weather plugin.
//
// Locations, home city, and temperature units are Elsewhen's
// (omarchy.elsewhen) bar-widget settings in ~/.config/omarchy/shell.json,
// read live so this plugin always tracks the official world clock. Weather
// comes from Open-Meteo, shaped exactly like the World Clock Rust backend
// shaped it, so the copied WeatherDetail view renders unchanged.
//
// QML has no Intl, so each zone's local clock comes from a `date` probe,
// the same way Elsewhen does it.

var MAX_LOCATIONS = 24
var MAX_LABEL_LENGTH = 80

var ZONE_ID = /^[A-Za-z0-9_+\-\/]+$/

function cleanLabel(label) {
  var text = String(label || "").replace(/[,|]/g, " ").replace(/\s+/g, " ").trim()
  return text.slice(0, MAX_LABEL_LENGTH)
}

function labelForZoneId(id) {
  return String(id || "").split("/").pop().replace(/_/g, " ")
}

// "Los Angeles|America/Los_Angeles, Asia/Tokyo" -> [{label, id}, ...].
// Same parsing as Elsewhen's Model.parseZones.
function parseZones(spec) {
  var text = String(spec === undefined || spec === null ? "" : spec)
  var out = []
  var parts = text.split(",")
  for (var i = 0; i < parts.length && out.length < MAX_LOCATIONS; i++) {
    var entry = parts[i].trim()
    if (entry === "") continue
    var fields = entry.split("|")
    var label = ""
    var id = ""
    if (fields.length >= 2) {
      label = cleanLabel(fields[0])
      id = fields[1].trim()
    } else {
      id = entry
      label = labelForZoneId(entry)
    }
    if (id === "" || !ZONE_ID.test(id)) continue
    if (label === "") label = labelForZoneId(id)
    out.push({ label: label, id: id })
  }
  return out
}

// Coordinates and weather are keyed by "label|zone", like Elsewhen.
function factsKey(zone) {
  return String(zone.label) + "|" + String(zone.id)
}

// Find an object with a given `id` anywhere in parsed shell.json: Elsewhen
// may sit in a bar section, the tray, or a tray widget's nested `entry`.
function findWidgetEntry(node, id, depth) {
  if (!node || typeof node !== "object" || depth > 12) return null
  if (!Array.isArray(node) && node.id === id) return node
  if (Array.isArray(node)) {
    for (var i = 0; i < node.length; i++) {
      var inArray = findWidgetEntry(node[i], id, depth + 1)
      if (inArray) return inArray
    }
    return null
  }
  for (var key in node) {
    if (!Object.prototype.hasOwnProperty.call(node, key)) continue
    var found = findWidgetEntry(node[key], id, depth + 1)
    if (found) return found
  }
  return null
}

// Elsewhen's settings out of raw shell.json text. Missing widget or blank
// zones returns null zones-spec so the caller can fall back visibly.
function parseElsewhenSettings(shellJsonText) {
  var empty = { zonesSpec: "", homeCity: "", units: "", hour24: "" }
  var parsed
  try { parsed = JSON.parse(String(shellJsonText || "")) } catch (e) { return empty }
  var entry = findWidgetEntry(parsed, "omarchy.elsewhen", 0)
  if (!entry) return empty
  return {
    zonesSpec: typeof entry.zones === "string" ? entry.zones.slice(0, 4096) : "",
    homeCity: cleanLabel(entry.homeCity),
    units: typeof entry.units === "string" ? entry.units : "",
    hour24: (entry.hour24 === true || entry.hour24 === false)
      ? entry.hour24 : ""
  }
}

// Elsewhen's home: the `homeCity` override wins; otherwise the system
// zone names a representative city.
function homeZone(homeCitySetting, localZone) {
  var zone = String(localZone || "")
  if (zone === "" || !ZONE_ID.test(zone)) return null
  var override = cleanLabel(homeCitySetting)
  return { label: override !== "" ? override : labelForZoneId(zone), id: zone }
}

// The list the panel offers: home first, then Elsewhen's zones, with a
// zone also used as home appearing once (under its home label, since that
// is what Elsewhen calls the place you are in).
function locationList(zones, home) {
  var out = []
  var seen = {}
  function push(zone) {
    if (!zone || !zone.id) return
    var key = factsKey(zone)
    if (seen[key]) return
    seen[key] = true
    out.push({ label: zone.label, id: zone.id })
  }
  push(home)
  for (var i = 0; i < (zones || []).length; i++) push(zones[i])
  return out.slice(0, MAX_LOCATIONS)
}

// An explicit "C" or "F" wins; anything else follows the system.
function resolveUnits(setting, auto) {
  var explicit = String(setting === undefined || setting === null
    ? "" : setting).trim().toUpperCase()
  if (explicit === "C" || explicit === "F") return explicit
  return String(auto).toUpperCase() === "F" ? "F" : "C"
}

// ---- the date probe

// argv for one `date` per zone, printing "Zone|YYYY-MM-DD|HH:MM|Abbr"
// (local clock), plus a "LOCAL|<system zone>" line first. Zones are
// arguments, never script text.
function probeCommand(ids) {
  var script = "tz=$(timedatectl show -p Timezone --value); "
    + "printf 'LOCAL|%s\\n' \"$tz\"; "
    + "for z in \"$@\"; do TZ=\"$z\" date \"+$z|%Y-%m-%d|%H:%M|%Z\"; done"
  var out = ["bash", "-c", script, "bash"]
  var list = ids || []
  for (var i = 0; i < list.length; i++) {
    if (ZONE_ID.test(String(list[i]))) out.push(String(list[i]))
  }
  return out
}

function localZoneFromProbe(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("|")
    if (f.length >= 2 && f[0].trim() === "LOCAL") {
      var zone = f[1].trim()
      return ZONE_ID.test(zone) ? zone : ""
    }
  }
  return ""
}

// Probe stdout -> { "Zone": { date, time, localMinutes, notation } }.
// `time` stays 24-hour; the panel formats it for display.
function parseProbe(text) {
  var map = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("|")
    if (f.length < 4) continue
    var id = f[0].trim()
    if (id === "" || id === "LOCAL" || !ZONE_ID.test(id)) continue
    var m = /^(\d{2}):(\d{2})$/.exec(f[2].trim())
    if (!m || !/^\d{4}-\d{2}-\d{2}$/.test(f[1].trim())) continue
    map[id] = {
      date: f[1].trim(),
      time: f[2].trim(),
      localMinutes: parseInt(m[1], 10) * 60 + parseInt(m[2], 10),
      notation: f[3].trim().slice(0, 16)
    }
  }
  return map
}

// Advance probed clocks to `nowMs` so rows tick between probes. Each clock
// was probed at `probedAtMs`; local elapsed time is the same everywhere.
function tickedClock(probed, probedAtMs, nowMs) {
  if (!probed) return null
  var elapsed = Math.max(0, Math.floor((nowMs - probedAtMs) / 60000))
  var minutes = probed.localMinutes + elapsed
  var date = probed.date
  if (minutes >= 1440) {
    var days = Math.floor(minutes / 1440)
    minutes = minutes % 1440
    var base = new Date(probed.date + "T12:00:00Z")
    if (!isNaN(base.getTime())) {
      base.setUTCDate(base.getUTCDate() + days)
      date = base.toISOString().slice(0, 10)
    }
  }
  var hh = Math.floor(minutes / 60)
  var mm = minutes % 60
  return {
    date: date,
    time: (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm,
    localMinutes: minutes,
    notation: probed.notation
  }
}

// ---- coordinates

function geocodeUrl(label) {
  return "https://geocoding-api.open-meteo.com/v1/search?count=10&language=en&format=json&name="
    + encodeURIComponent(label)
}

function validPoint(lat, lon) {
  var la = Number(lat)
  var lo = Number(lon)
  if (!isFinite(la) || !isFinite(lo)) return null
  if (la < -90 || la > 90 || lo < -180 || lo > 180) return null
  return { lat: la, lon: lo }
}

// { place, answered }: a place in the row's own zone beats the top result,
// and `answered` is false when the request itself failed.
function pickGeocode(text, zone) {
  var results
  try { results = JSON.parse(text).results || [] } catch (e) { return { place: null, answered: false } }
  if (!Array.isArray(results)) return { place: null, answered: false }
  var best = null
  for (var i = 0; i < results.length && i < 25 && !best; i++)
    if (results[i] && results[i].timezone === zone) best = results[i]
  if (!best && results.length > 0) best = results[0]
  return { place: best ? validPoint(best.latitude, best.longitude) : null, answered: true }
}

// The zone's representative city from zone1970.tab (ISO 6709), the offline fallback.
function zoneTabCoords(tabText, zone) {
  var lines = String(tabText || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (lines[i].charAt(0) === "#" || parts.length < 3 || parts[2] !== zone) continue
    var m = /^([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?$/.exec(parts[1])
    if (!m) return null
    function dec(sign, d, mm, ss) { return (sign === "-" ? -1 : 1) * (Number(d) + Number(mm) / 60 + Number(ss || 0) / 3600) }
    return validPoint(
      Math.round(dec(m[1], m[2], m[3], m[4]) * 1e4) / 1e4,
      Math.round(dec(m[5], m[6], m[7], m[8]) * 1e4) / 1e4)
  }
  return null
}

// ---- weather

var HOURLY_FORECAST_COUNT = 24
var DAILY_FORECAST_COUNT = 4
var MAX_RESPONSE_CHARS = 1024 * 1024

// The same Open-Meteo request the World Clock backend made.
function forecastUrl(points) {
  return "https://api.open-meteo.com/v1/forecast"
    + "?latitude=" + points.map(function(p) { return p.lat }).join(",")
    + "&longitude=" + points.map(function(p) { return p.lon }).join(",")
    + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,pressure_msl,visibility,wind_speed_10m,wind_direction_10m,wind_gusts_10m,weather_code,is_day"
    + "&hourly=temperature_2m,precipitation_probability,precipitation,uv_index,wind_speed_10m,wind_gusts_10m,weather_code,is_day"
    + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"
    + "&temperature_unit=celsius&wind_speed_unit=kmh"
    + "&forecast_hours=24&forecast_days=5&timezone=auto"
}

function condition(code) {
  var c = Number(code)
  if (c === 0) return "Clear"
  if (c === 1) return "Mostly clear"
  if (c === 2) return "Partly cloudy"
  if (c === 3) return "Overcast"
  if (c === 45 || c === 48) return "Fog"
  if (c === 51 || c === 53 || c === 55) return "Drizzle"
  if (c === 56 || c === 57) return "Freezing drizzle"
  if (c === 61 || c === 63 || c === 65) return "Rain"
  if (c === 66 || c === 67) return "Freezing rain"
  if (c === 71 || c === 73 || c === 75 || c === 77) return "Snow"
  if (c >= 80 && c <= 82) return "Showers"
  if (c >= 85 && c <= 86) return "Snow showers"
  if (c === 95 || c === 96 || c === 99) return "Thunderstorm"
  return "Conditions unavailable"
}

function finiteOrNull(value) {
  var n = Number(value)
  return (value === null || value === undefined || value === "" || !isFinite(n))
    ? null : n
}

function arrayAt(values, index) {
  return Array.isArray(values) && index < values.length ? values[index] : null
}

function stringAt(values, index) {
  var value = arrayAt(values, index)
  return typeof value === "string" && value !== "" ? value.slice(0, 40) : null
}

function dailyAt(daily, index) {
  if (!daily) return null
  var max = finiteOrNull(arrayAt(daily.temperature_2m_max, index))
  var min = finiteOrNull(arrayAt(daily.temperature_2m_min, index))
  var code = finiteOrNull(arrayAt(daily.weather_code, index))
  var date = stringAt(daily.time, index)
  if (max === null || min === null || code === null || !date) return null
  return {
    date: date,
    temperature_max_celsius: max,
    temperature_min_celsius: min,
    weather_code: Math.round(code),
    condition: condition(code),
    precipitation_probability_percent: finiteOrNull(
      arrayAt(daily.precipitation_probability_max, index)),
    sunrise: stringAt(daily.sunrise, index),
    sunset: stringAt(daily.sunset, index),
    uv_index_max: finiteOrNull(arrayAt(daily.uv_index_max, index))
  }
}

// Open-Meteo renders timestamps in the response's applied offset; reversing
// it gives the UTC instant, like the backend's hourly_reference_utc.
function hourlyReferenceUtc(localTime, utcOffsetSeconds) {
  var m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(localTime || ""))
  var offset = finiteOrNull(utcOffsetSeconds)
  if (!m || offset === null) return null
  var ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
    Number(m[4]), Number(m[5])) - offset * 1000
  return isFinite(ms) ? new Date(ms).toISOString() : null
}

function hourlyAt(hourly, index, utcOffsetSeconds) {
  var temperature = finiteOrNull(arrayAt(hourly.temperature_2m, index))
  var code = finiteOrNull(arrayAt(hourly.weather_code, index))
  var time = stringAt(hourly.time, index)
  var referenceUtc = time ? hourlyReferenceUtc(time, utcOffsetSeconds) : null
  if (temperature === null || code === null || !time || !referenceUtc) return null
  return {
    time: time.slice(0, 16),
    reference_utc: referenceUtc,
    temperature_celsius: temperature,
    weather_code: Math.round(code),
    condition: condition(code),
    is_day: Number(arrayAt(hourly.is_day, index)) !== 0,
    precipitation_probability_percent: finiteOrNull(
      arrayAt(hourly.precipitation_probability, index)),
    precipitation_mm: finiteOrNull(arrayAt(hourly.precipitation, index)),
    uv_index: finiteOrNull(arrayAt(hourly.uv_index, index)),
    wind_speed_kmh: finiteOrNull(arrayAt(hourly.wind_speed_10m, index)),
    wind_gusts_kmh: finiteOrNull(arrayAt(hourly.wind_gusts_10m, index))
  }
}

// Open-Meteo answers one point as an object and several as an array, in
// request order. `locations` are the requested rows ({label, id}). Returns
// { "label|zone": LocationWeather } in the World Clock backend's shape;
// locations without usable current weather are simply absent.
function parseWeather(text, locations) {
  var out = {}
  var raw = String(text || "")
  if (raw.length > MAX_RESPONSE_CHARS) return out
  var payload
  try { payload = JSON.parse(raw) } catch (e) { return out }
  if (!Array.isArray(payload)) payload = [payload]
  var rows = locations || []
  for (var i = 0; i < rows.length && i < payload.length; i++) {
    var forecast = payload[i]
    if (!forecast || typeof forecast !== "object") continue
    var current = forecast.current
    if (!current || typeof current !== "object") continue
    var temperature = finiteOrNull(current.temperature_2m)
    var code = finiteOrNull(current.weather_code)
    if (temperature === null || code === null) continue

    var hourly = []
    if (forecast.hourly && Array.isArray(forecast.hourly.time)) {
      var count = Math.min(forecast.hourly.time.length, HOURLY_FORECAST_COUNT)
      for (var h = 0; h < count; h++) {
        var hour = hourlyAt(forecast.hourly, h, forecast.utc_offset_seconds)
        if (hour) hourly.push(hour)
      }
    }
    var daily = []
    if (forecast.daily && Array.isArray(forecast.daily.time)) {
      var dayCount = Math.min(forecast.daily.time.length,
        DAILY_FORECAST_COUNT + 1)
      for (var d = 1; d < dayCount; d++) {
        var day = dailyAt(forecast.daily, d)
        if (day) daily.push(day)
      }
    }

    out[factsKey(rows[i])] = {
      id: i + 1,
      timezone: rows[i].id,
      label: rows[i].label,
      temperature_celsius: temperature,
      apparent_temperature_celsius: finiteOrNull(current.apparent_temperature),
      relative_humidity_percent: finiteOrNull(current.relative_humidity_2m),
      wind_speed_kmh: finiteOrNull(current.wind_speed_10m),
      wind_direction_degrees: finiteOrNull(current.wind_direction_10m),
      wind_gusts_kmh: finiteOrNull(current.wind_gusts_10m),
      precipitation_mm: finiteOrNull(current.precipitation),
      pressure_hpa: finiteOrNull(current.pressure_msl),
      visibility_meters: finiteOrNull(current.visibility),
      weather_code: Math.round(code),
      condition: condition(code),
      is_day: Number(current.is_day) !== 0,
      today: dailyAt(forecast.daily, 0),
      hourly_forecast: hourly,
      forecast: daily
    }
  }
  return out
}

function weatherStale(updatedAtMs, nowMs, ttlMs) {
  var updated = Number(updatedAtMs)
  if (!isFinite(updated) || updated <= 0) return true
  // A wall-clock adjustment into the past counts as age zero.
  return nowMs >= updated && nowMs - updated >= ttlMs
}

// Node test hook; inert in QML.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    parseZones: parseZones,
    labelForZoneId: labelForZoneId,
    factsKey: factsKey,
    parseElsewhenSettings: parseElsewhenSettings,
    homeZone: homeZone,
    locationList: locationList,
    resolveUnits: resolveUnits,
    probeCommand: probeCommand,
    localZoneFromProbe: localZoneFromProbe,
    parseProbe: parseProbe,
    tickedClock: tickedClock,
    geocodeUrl: geocodeUrl,
    pickGeocode: pickGeocode,
    zoneTabCoords: zoneTabCoords,
    forecastUrl: forecastUrl,
    condition: condition,
    parseWeather: parseWeather,
    weatherStale: weatherStale
  }
}


