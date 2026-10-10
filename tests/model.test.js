const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("parses view-only ICS settings", () => {
  assert.deepEqual(Model.parseSettings('{"ics":"https://example.test/calendar.ics"}'), {
    ics: "https://example.test/calendar.ics",
    weekStart: 1,
  })
})

test("splits multiple ICS URLs", () => {
  assert.deepEqual(Model.splitIcsUrls("https://a.test/a.ics,\n https://b.test/b.ics "), [
    "https://a.test/a.ics",
    "https://b.test/b.ics",
  ])
})

test("parses event details and categorizes a calendar meeting", () => {
  const ics = [
    "BEGIN:VCALENDAR",
    "BEGIN:VEVENT",
    "DTSTART:20261010T100000Z",
    "DTEND:20261010T110000Z",
    "SUMMARY:Team meeting",
    "LOCATION:Studio",
    "END:VEVENT",
    "END:VCALENDAR",
  ].join("\r\n")
  const [event] = Model.parseIcsEvents(ics)
  assert.equal(event.summary, "Team meeting")
  assert.equal(event.location, "Studio")
  assert.equal(Model.categorizeEvent(event.summary, event.description, event.location).key, "meeting")
})

test("expands an event into its day and shows its category color dot", () => {
  const start = new Date(2026, 9, 10, 10, 0)
  const end = new Date(2026, 9, 10, 11, 0)
  const category = Model.categorizeEvent("Project review", "", "")
  const event = {
    title: "Project review",
    start,
    end,
    allDay: false,
    category: category.key,
    categoryLabel: category.label,
    color: category.color,
    dayKeys: [Model.dayKey(start)],
  }
  const byDay = Model.groupByDay([event])
  const cells = Model.buildMonthCells(2026, 9, byDay, 1, "2026-10-10")
  const selected = cells.find((cell) => cell.key === "2026-10-10")
  assert.equal(selected.events.length, 1)
  assert.deepEqual(selected.dots, [category.color])
})
