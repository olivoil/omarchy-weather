// Run: node test/model.test.cjs
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const Model = require(path.join(__dirname, "..", "Model.js"))

// parseZones follows Elsewhen's "Label|Zone" format.
assert.deepStrictEqual(
  Model.parseZones("Vancouver|America/Vancouver, Cancun|America/Cancun, Asia/Tokyo"),
  [
    { label: "Vancouver", id: "America/Vancouver" },
    { label: "Cancun", id: "America/Cancun" },
    { label: "Tokyo", id: "Asia/Tokyo" }
  ])
assert.deepStrictEqual(Model.parseZones(""), [])
// An id with characters that could never name a zone drops the entry.
assert.deepStrictEqual(Model.parseZones("Label|Bad Zone!"), [])

// Elsewhen settings are found inside a bar layout entry, and survive markup.
const shell = JSON.stringify({
  bar: { layout: { centerBegin: [
    { id: "omarchy.indicators" },
    { id: "omarchy.elsewhen", units: "C", homeCity: "",
      zones: "Vancouver|America/Vancouver, Cancun|America/Cancun" }
  ] } }
})
const settings = Model.parseElsewhenSettings(shell)
assert.strictEqual(settings.units, "C")
assert.strictEqual(settings.homeCity, "")
assert.strictEqual(settings.zonesSpec,
  "Vancouver|America/Vancouver, Cancun|America/Cancun")
assert.strictEqual(Model.parseElsewhenSettings("{}").zonesSpec, "")
assert.strictEqual(Model.parseElsewhenSettings("not json").zonesSpec, "")

// Home follows Elsewhen: override wins, else the system zone's city.
assert.deepStrictEqual(Model.homeZone("", "America/Cancun"),
  { label: "Cancun", id: "America/Cancun" })
assert.deepStrictEqual(Model.homeZone("Playa del Carmen", "America/Cancun"),
  { label: "Playa del Carmen", id: "America/Cancun" })
assert.strictEqual(Model.homeZone("", ""), null)

// Home leads the list and is not duplicated when Elsewhen also lists it.
const list = Model.locationList(Model.parseZones(settings.zonesSpec),
  Model.homeZone("", "America/Cancun"))
assert.deepStrictEqual(list, [
  { label: "Cancun", id: "America/Cancun" },
  { label: "Vancouver", id: "America/Vancouver" }
])

// Probe parsing.
const probeText = "LOCAL|America/Cancun\n"
  + "America/Cancun|2026-10-20|21:50|EST\n"
  + "Europe/Paris|2026-10-21|04:50|CEST\n"
assert.strictEqual(Model.localZoneFromProbe(probeText), "America/Cancun")
const clocks = Model.parseProbe(probeText)
assert.strictEqual(clocks["America/Cancun"].localMinutes, 21 * 60 + 50)
assert.strictEqual(clocks["Europe/Paris"].notation, "CEST")
const ticked = Model.tickedClock(clocks["America/Cancun"],
  Date.UTC(2026, 9, 21, 2, 50), Date.UTC(2026, 9, 21, 5, 20))
assert.strictEqual(ticked.time, "00:20")
assert.strictEqual(ticked.date, "2026-10-21")

// Coordinates: zone1970.tab fallback and geocode zone preference.
const tab = "MX\t+2105-08646\tAmerica/Cancun\t\n"
assert.deepStrictEqual(Model.zoneTabCoords(tab, "America/Cancun"),
  { lat: 21.0833, lon: -86.7667 })
const geo = JSON.stringify({ results: [
  { name: "Austin", latitude: 1, longitude: 2, timezone: "Elsewhere/Zone" },
  { name: "Austin", latitude: 30.2672, longitude: -97.7431, timezone: "America/Chicago" }
] })
assert.deepStrictEqual(Model.pickGeocode(geo, "America/Chicago").place,
  { lat: 30.2672, lon: -97.7431 })
assert.strictEqual(Model.pickGeocode("junk", "America/Chicago").answered, false)

// Weather parsing mirrors the World Clock backend shape.
const fixture = JSON.parse(fs.readFileSync(
  path.join(__dirname, "open-meteo.fixture.json"), "utf8"))
const rows = [
  { label: "Cancun", id: "America/Cancun" },
  { label: "Paris", id: "Europe/Paris" }
]
const weather = Model.parseWeather(JSON.stringify(fixture), rows)
const cancun = weather["Cancun|America/Cancun"]
assert.ok(cancun, "Cancun weather present")
assert.strictEqual(typeof cancun.temperature_celsius, "number")
assert.strictEqual(cancun.condition, Model.condition(cancun.weather_code))
assert.strictEqual(cancun.hourly_forecast.length, 24)
assert.strictEqual(cancun.forecast.length, 4)
assert.ok(cancun.today && cancun.today.sunrise, "today carries sunrise")
const firstHour = cancun.hourly_forecast[0]
assert.ok(!isNaN(Date.parse(firstHour.reference_utc)),
  "hourly reference_utc parses as a date")
assert.ok(weather["Paris|Europe/Paris"], "Paris weather present")

// Garbage and oversized responses yield nothing, never throw.
assert.deepStrictEqual(Model.parseWeather("nope", rows), {})
assert.deepStrictEqual(Model.parseWeather("{".repeat(2 << 20), rows), {})

console.log("model.test.cjs: all assertions passed")
