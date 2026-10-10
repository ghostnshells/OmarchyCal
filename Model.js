// Calendar model: ICS parsing, recurrence expansion, event-type
// categorization, month-grid construction. Pure functions so the panel
// stays declarative. No Qt dependencies except an optional formatter.

function parseSettings(raw) {
  var out = { ics: "", weekStart: 1 }
  try {
    var data = JSON.parse(String(raw || "{}"))
    if (!data || typeof data !== "object") return out
    if (typeof data.ics === "string") out.ics = data.ics
    // Backwards compat: single url field.
    if (!out.ics && typeof data.url === "string") out.ics = data.url
    if (typeof data.icsUrls === "string" && !out.ics) out.ics = data.icsUrls
    var ws = parseInt(data.weekStart, 10)
    if (ws === 0 || ws === 1 || ws === 6) out.weekStart = ws
    return out
  } catch (e) {
    return out
  }
}

function splitIcsUrls(icsText) {
  var parts = String(icsText || "").split(/[\n,]+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var u = parts[i].replace(/^\s+|\s+$/g, "")
    if (u !== "") out.push(u)
  }
  return out
}

// ---- Event-type categorization (drives color highlighting) ----
function categories() {
  return [
    { key: "urgent",   label: "Urgent",   color: "__urgent__",
      keywords: ["urgent", "deadline", "due", "asap", "critical", "exam", "interview", "launch", "release"] },
    { key: "meeting",  label: "Meetings", color: "#849ce3",
      keywords: ["meeting", "meet", "call", "sync", "standup", "stand-up", "1:1", "1-1", "review", "zoom", "teams", "meetup"] },
    { key: "work",     label: "Work",     color: "#637eaf",
      keywords: ["work", "sprint", "deploy", "office", "client", "project", "workshop", "desk", "shift", "oncall", "on-call"] },
    { key: "health",   label: "Health",   color: "#5caac3",
      keywords: ["gym", "workout", "run", "yoga", "swim", "doctor", "dentist", "health", "med", "therapy", "physio", "dentist"] },
    { key: "personal", label: "Personal", color: "#cac082",
      keywords: ["personal", "family", "home", "birthday", "anniversary", "chore", "errand", "bill", "appointment"] },
    { key: "social",   label: "Social",   color: "#e0d89b",
      keywords: ["dinner", "lunch", "coffee", "drinks", "party", "friends", "wedding", "date", "social", "concert", "game"] },
    { key: "travel",   label: "Travel",   color: "#b3844e",
      keywords: ["flight", "travel", "trip", "hotel", "train", "airport", "vacation", "holiday", "airbnb"] }
  ]
}

function categorizeEvent(summary, description, location) {
  var hay = (String(summary || "") + " " + String(description || "") + " " + String(location || "")).toLowerCase()
  var cats = categories()
  for (var i = 0; i < cats.length; i++) {
    var kws = cats[i].keywords
    for (var j = 0; j < kws.length; j++) {
      if (hay.indexOf(kws[j]) !== -1) return cats[i]
    }
  }
  return { key: "default", label: "Other", color: "__accent__" }
}

// ---- ICS parsing ----
function unfoldIcs(text) {
  var lines = String(text || "").split(/\r\n|\n|\r/)
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if ((line.charAt(0) === " " || line.charAt(0) === "\t") && out.length > 0) {
      out[out.length - 1] += line.slice(1)
    } else {
      out.push(line)
    }
  }
  return out
}

function parseIcsDateTime(value, params) {
  // VALUE=DATE all-day: 20261010. Timed: 20261010T090000Z / with TZID / floating.
  value = String(value || "").replace(/^\s+|\s+$/g, "")
  if (/^\d{8}$/.test(value)) {
    var y = parseInt(value.slice(0, 4), 10)
    var m = parseInt(value.slice(4, 6), 10) - 1
    var d = parseInt(value.slice(6, 8), 10)
    return { date: new Date(y, m, d, 0, 0, 0, 0), allDay: true }
  }
  var mt = value.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z)?$/)
  if (mt) {
    var yy = parseInt(mt[1], 10)
    var mo = parseInt(mt[2], 10) - 1
    var dd = parseInt(mt[3], 10)
    var hh = parseInt(mt[4], 10)
    var mi = parseInt(mt[5], 10)
    var ss = mt[6] ? parseInt(mt[6], 10) : 0
    if (mt[7] === "Z") return { date: new Date(Date.UTC(yy, mo, dd, hh, mi, ss)), allDay: false }
    // TZID / floating: treat as local wall time (good enough for a popup).
    return { date: new Date(yy, mo, dd, hh, mi, ss), allDay: false }
  }
  // Fallback: let Date try (covers 2026-10-10, ISO with offsets, etc).
  var parsed = new Date(value)
  if (!isNaN(parsed.getTime())) {
    var allDay = /^\d{4}-\d{2}-\d{2}$/.test(value)
    return { date: parsed, allDay: allDay }
  }
  return null
}

function parseIcsUntil(value) {
  if (!value) return null
  value = String(value).replace(/^\s+|\s+$/g, "")
  var r = parseIcsDateTime(value, "")
  return r ? r.date : null
}

function parseRrule(value) {
  var rule = { freq: "", interval: 1, count: 0, until: null, byday: [] }
  var parts = String(value || "").split(";")
  for (var i = 0; i < parts.length; i++) {
    var kv = parts[i].split("=")
    if (kv.length < 2) continue
    var k = kv[0].toUpperCase()
    var v = kv.slice(1).join("=")
    if (k === "FREQ") rule.freq = v.toUpperCase()
    else if (k === "INTERVAL") rule.interval = Math.max(1, parseInt(v, 10) || 1)
    else if (k === "COUNT") rule.count = Math.max(0, parseInt(v, 10) || 0)
    else if (k === "UNTIL") rule.until = parseIcsUntil(v)
    else if (k === "BYDAY") rule.byday = v.toUpperCase().split(",")
  }
  return rule
}

function parseIcsEvents(raw) {
  var events = []
  var lines = unfoldIcs(raw)
  var inEvent = false
  var cur = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "BEGIN:VEVENT") {
      inEvent = true
      cur = { summary: "", description: "", location: "", start: null, end: null, allDay: false, rrule: null }
      continue
    }
    if (line === "END:VEVENT") {
      if (inEvent && cur && cur.start && cur.summary !== "") events.push(cur)
      inEvent = false
      cur = null
      continue
    }
    if (!inEvent || !cur) continue
    var idx = line.indexOf(":")
    if (idx === -1) continue
    var left = line.slice(0, idx)
    var val = line.slice(idx + 1)
    var prop = left.split(";")[0].toUpperCase()
    if (prop === "SUMMARY") cur.summary = unescapeIcsText(val)
    else if (prop === "DESCRIPTION") cur.description = unescapeIcsText(val)
    else if (prop === "LOCATION") cur.location = unescapeIcsText(val)
    else if (prop === "DTSTART") {
      var s = parseIcsDateTime(val, left)
      if (s) { cur.start = s.date; cur.allDay = s.allDay }
    } else if (prop === "DTEND") {
      var e = parseIcsDateTime(val, left)
      if (e) cur.end = e.date
    } else if (prop === "RRULE") {
      cur.rrule = parseRrule(val)
    }
  }
  return events
}

function unescapeIcsText(v) {
  return String(v || "").replace(/\\n/gi, "\n").replace(/\\,/g, ",").replace(/\\;/g, ";").replace(/\\\\/g, "\\")
}

function dayKey(d) {
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function addDays(d, n) {
  var c = new Date(d.getTime())
  c.setDate(c.getDate() + n)
  return c
}

// Expand recurrence for the window [rangeStart, rangeEnd). Caps output.
function expandEvents(baseEvents, rangeStart, rangeEnd) {
  var out = []
  for (var i = 0; i < baseEvents.length && out.length < 800; i++) {
    var ev = baseEvents[i]
    if (!ev.start) continue
    var durationMs = ev.end && ev.end > ev.start ? ev.end - ev.start : (ev.allDay ? 24 * 3600 * 1000 : 3600 * 1000)
    var occurrences = expandOne(ev, rangeStart, rangeEnd)
    for (var j = 0; j < occurrences.length && out.length < 800; j++) {
      var start = occurrences[j]
      var cat = categorizeEvent(ev.summary, ev.description, ev.location)
      out.push({
        title: ev.summary,
        description: ev.description,
        location: ev.location,
        start: start,
        end: new Date(start.getTime() + durationMs),
        allDay: ev.allDay,
        category: cat.key,
        categoryLabel: cat.label,
        color: cat.color,
        dayKeys: spannedDayKeys(start, new Date(start.getTime() + durationMs), ev.allDay)
      })
    }
  }
  out.sort(function(a, b) { return a.start - b.start })
  return out
}

function expandOne(ev, rangeStart, rangeEnd) {
  var out = []
  var rule = ev.rrule
  if (!rule || !rule.freq || (rule.freq !== "DAILY" && rule.freq !== "WEEKLY")) {
    if (ev.start < rangeEnd && new Date(ev.start.getTime() + 24 * 3600 * 1000) > rangeStart) out.push(ev.start)
    // Multi-day: include if it overlaps the window at all.
    else if (ev.end && ev.end > rangeStart && ev.start < rangeEnd) out.push(ev.start)
    return out
  }
  var maxCount = rule.count > 0 ? Math.min(rule.count, 400) : 400
  var cursor = new Date(ev.start.getTime())
  var until = rule.until
  var guard = 0
  var step = rule.freq === "DAILY" ? rule.interval : rule.interval * 7
  while (guard < maxCount && cursor < rangeEnd) {
    guard++
    if ((!until || cursor <= until) && cursor >= rangeStart) out.push(new Date(cursor.getTime()))
    else if (!until && cursor < rangeStart) { /* skip, keep stepping */ }
    // Note: WEEKLY BYDAY expansion is approximated by the base weekday;
    // full BYDAY fan-out is overkill for a popup.
    if (until && cursor > until) break
    cursor = addDays(cursor, step)
    if (guard > 500) break
  }
  return out
}

function spannedDayKeys(start, end, allDay) {
  var keys = []
  var s = new Date(start.getFullYear(), start.getMonth(), start.getDate())
  var last = new Date(end.getTime())
  // Google treats DTEND as exclusive; an all-day event ending at midnight
  // should not paint the next day.
  if (allDay) last = new Date(last.getTime() - 1000)
  var e = new Date(last.getFullYear(), last.getMonth(), last.getDate())
  var cursor = s
  var guard = 0
  while (cursor <= e && guard < 14) {
    keys.push(dayKey(cursor))
    cursor = addDays(cursor, 1)
    guard++
  }
  if (keys.length === 0) keys.push(dayKey(s))
  return keys
}

function groupByDay(events) {
  var map = {}
  for (var i = 0; i < events.length; i++) {
    var ev = events[i]
    for (var j = 0; j < ev.dayKeys.length; j++) {
      var k = ev.dayKeys[j]
      if (!map[k]) map[k] = []
      map[k].push(ev)
    }
  }
  return map
}

// Month grid: 6 rows x 7 cols, Monday-first by default. Each cell:
// { date, key, inMonth, isToday, events, dots } where dots is <=3 colors.
function buildMonthCells(year, month, eventsByDay, weekStart, todayKey) {
  var first = new Date(year, month, 1)
  var jsDay = first.getDay() // 0=Sun
  var ws = weekStart === 0 ? 0 : (weekStart === 6 ? 6 : 1)
  var offset = (jsDay - ws + 7) % 7
  var startDate = addDays(first, -offset)
  var cells = []
  for (var i = 0; i < 42; i++) {
    var d = addDays(startDate, i)
    var key = dayKey(d)
    var dayEvents = eventsByDay[key] || []
    cells.push({
      date: d,
      day: d.getDate(),
      key: key,
      inMonth: d.getMonth() === month,
      isToday: key === todayKey,
      events: dayEvents,
      dots: dotsForDay(dayEvents)
    })
  }
  return cells
}

function dotsForDay(dayEvents) {
  var seen = []
  var colors = []
  for (var i = 0; i < dayEvents.length && colors.length < 3; i++) {
    var c = dayEvents[i].color
    if (seen.indexOf(c) === -1) {
      seen.push(c)
      colors.push(c)
    }
  }
  return colors
}

function weekdayNames(weekStart, short) {
  var all = short ? ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                  : ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
  if (weekStart === 0) return ["Sun"].concat(all.slice(0, 6))
  if (weekStart === 6) return ["Sat", "Sun"].concat(all.slice(0, 5))
  return all
}

function monthLabel(year, month, formatter) {
  var d = new Date(year, month, 1, 12, 0, 0)
  if (formatter) return formatter(d)
  return ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"][month] + " " + year
}

function formatTime(date, allDay) {
  if (allDay) return "All day"
  var h = date.getHours()
  var m = date.getMinutes()
  var suffix = h >= 12 ? "PM" : "AM"
  var h12 = h % 12
  if (h12 === 0) h12 = 12
  if (m === 0) return h12 + " " + suffix
  return h12 + ":" + pad2(m) + " " + suffix
}

function formatDayHeader(date, fmtDay, fmtWeekday) {
  var dayNum = fmtDay ? fmtDay(date) : String(date.getDate())
  var wd = fmtWeekday ? fmtWeekday(date) : ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][date.getDay()]
  return { dayNum: dayNum, weekday: wd }
}

function demoEvents(today) {
  var base = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 12, 0, 0)
  function at(dayOffset, h, min, durH, title, location) {
    var s = addDays(base, dayOffset)
    s.setHours(h, min, 0, 0)
    var cat = categorizeEvent(title, "", location)
    return {
      title: title, description: "", location: location || "",
      start: s, end: new Date(s.getTime() + durH * 3600 * 1000),
      allDay: false, category: cat.key, categoryLabel: cat.label, color: cat.color,
      dayKeys: spannedDayKeys(s, new Date(s.getTime() + durH * 3600 * 1000), false),
      demo: true
    }
  }
  return [
    at(0, 10, 0, 1, "Design review", "Studio"),
    at(0, 18, 30, 2, "Dinner with friends", "Downtown"),
    at(1, 9, 0, 1, "Sprint standup", "Office"),
    at(1, 17, 0, 1, "Gym session", ""),
    at(2, 14, 0, 1, "Dentist appointment", "Clinic"),
    at(4, 8, 0, 48, "Trip to the coast", "")
  ]
}

if (typeof module !== "undefined") {
  module.exports = {
    parseSettings: parseSettings,
    splitIcsUrls: splitIcsUrls,
    categories: categories,
    categorizeEvent: categorizeEvent,
    parseIcsDateTime: parseIcsDateTime,
    parseIcsEvents: parseIcsEvents,
    expandEvents: expandEvents,
    groupByDay: groupByDay,
    buildMonthCells: buildMonthCells,
    weekdayNames: weekdayNames,
    monthLabel: monthLabel,
    formatTime: formatTime,
    dayKey: dayKey,
    demoEvents: demoEvents
  }
}
