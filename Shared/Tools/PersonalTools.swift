import Foundation
import EventKit
import CoreLocation

// MARK: - EventKit (Calendar & Reminders)

enum EventKitAccess {
    static let store = EKEventStore()

    static func requireEvents() async throws {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if !granted { throw ToolError.invalid("Calendar access isn't allowed. Enable it in Settings › Privacy › Calendars › JARVIS.") }
    }

    static func requireReminders() async throws {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if !granted { throw ToolError.invalid("Reminders access isn't allowed. Enable it in Settings › Privacy › Reminders › JARVIS.") }
    }

    static func line(for event: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        let time = DateFormatter()
        time.timeStyle = .short
        var text = formatter.string(from: event.startDate)
        text += event.isAllDay ? " (all day)" : " \(time.string(from: event.startDate))–\(time.string(from: event.endDate))"
        text += " · \(event.title ?? "Untitled")"
        if let location = event.location, !location.isEmpty { text += " @ \(location)" }
        if let calendar = event.calendar?.title { text += " [\(calendar)]" }
        return text
    }
}

struct AddCalendarEventTool: AgentTool {
    let name = "add_calendar_event"
    let activityLabel = "Adding to Calendar"
    let description = "Add an event to the user's Calendar app. Use the current date from context to resolve words like \"tomorrow\"."
    let parameters = Schema.object([
        "title": Schema.string("Event title."),
        "start": Schema.string("Start, local time: \"yyyy-MM-dd HH:mm\" (or \"yyyy-MM-dd\" for all-day)."),
        "end": Schema.string("End, same format (optional)."),
        "duration_minutes": Schema.integer("Length if no end is given (default 60)."),
        "location": Schema.string("Location (optional)."),
        "notes": Schema.string("Notes (optional)."),
        "alert_minutes_before": Schema.integer("Alert this many minutes before (optional).")
    ], required: ["title", "start"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitAccess.requireEvents()
        let startText = try args.requiredString("start")
        guard let start = DateParser.parse(startText) else { throw ToolError.invalid("Couldn't understand the start date \"\(startText)\".") }
        let store = EventKitAccess.store
        let event = EKEvent(eventStore: store)
        event.title = try args.requiredString("title")
        event.startDate = start
        event.isAllDay = DateParser.isDateOnly(startText)
        if let endText = args.optionalString("end"), let end = DateParser.parse(endText), end > start {
            event.endDate = end
        } else {
            let minutes = args.int("duration_minutes") ?? (event.isAllDay ? 24 * 60 : 60)
            event.endDate = start.addingTimeInterval(TimeInterval(max(minutes, 5) * 60))
        }
        event.location = args.optionalString("location")
        event.notes = args.optionalString("notes")
        if let alert = args.int("alert_minutes_before") { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alert * 60))) }
        guard let calendar = store.defaultCalendarForNewEvents else { throw ToolError.invalid("No default calendar is set up.") }
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return ToolOutput(text: "Added to Calendar: \(EventKitAccess.line(for: event))")
    }
}

struct ListCalendarEventsTool: AgentTool {
    let name = "list_calendar_events"
    let activityLabel = "Checking your calendar"
    let description = "List the user's calendar events for a day or range (default: today)."
    let parameters = Schema.object([
        "start_date": Schema.string("First day \"yyyy-MM-dd\" (default today)."),
        "days": Schema.integer("Number of days to include (default 1, max 31).")
    ])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitAccess.requireEvents()
        let calendar = Calendar.current
        let firstDay = args.optionalString("start_date").flatMap { DateParser.parse($0) } ?? Date()
        let start = calendar.startOfDay(for: firstDay)
        let days = min(max(args.int("days") ?? 1, 1), 31)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return ToolOutput(text: "Invalid range.") }
        let store = EventKitAccess.store
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if events.isEmpty { return ToolOutput(text: "No events between \(DateParser.describe(start, includeTime: false)) and \(DateParser.describe(end, includeTime: false)).") }
        return ToolOutput(text: "\(events.count) event(s):\n" + events.prefix(100).map(EventKitAccess.line).joined(separator: "\n"))
    }
}

struct AddReminderTool: AgentTool {
    let name = "add_reminder"
    let activityLabel = "Adding a reminder"
    let description = "Add a reminder to the user's Reminders app, optionally with a due date/time alert."
    let parameters = Schema.object([
        "title": Schema.string("What to remember."),
        "due": Schema.string("Due date/time \"yyyy-MM-dd HH:mm\" (optional)."),
        "notes": Schema.string("Notes (optional)."),
        "priority": Schema.string("Priority.", options: ["none", "low", "medium", "high"])
    ], required: ["title"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitAccess.requireReminders()
        let store = EventKitAccess.store
        let reminder = EKReminder(eventStore: store)
        reminder.title = try args.requiredString("title")
        reminder.notes = args.optionalString("notes")
        switch args.optionalString("priority") {
        case "high": reminder.priority = 1
        case "medium": reminder.priority = 5
        case "low": reminder.priority = 9
        default: reminder.priority = 0
        }
        var dueText = ""
        if let raw = args.optionalString("due"), let due = DateParser.parse(raw) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            if !DateParser.isDateOnly(raw) { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            dueText = " due \(DateParser.describe(due, includeTime: !DateParser.isDateOnly(raw)))"
        }
        guard let list = store.defaultCalendarForNewReminders() else { throw ToolError.invalid("No default Reminders list is set up.") }
        reminder.calendar = list
        try store.save(reminder, commit: true)
        return ToolOutput(text: "Added reminder \"\(reminder.title ?? "")\"\(dueText) to \(list.title).")
    }
}

private func fetchReminders(_ predicate: NSPredicate) async -> [EKReminder] {
    await withCheckedContinuation { continuation in
        EventKitAccess.store.fetchReminders(matching: predicate) { reminders in
            continuation.resume(returning: reminders ?? [])
        }
    }
}

struct ListRemindersTool: AgentTool {
    let name = "list_reminders"
    let activityLabel = "Checking reminders"
    let description = "List the user's open (incomplete) reminders."
    let parameters = Schema.object([:])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitAccess.requireReminders()
        let predicate = EventKitAccess.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders = await fetchReminders(predicate)
        if reminders.isEmpty { return ToolOutput(text: "No open reminders.") }
        let lines = reminders.prefix(100).map { reminder -> String in
            var line = "• \(reminder.title ?? "Untitled")"
            if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) {
                line += " (due \(DateParser.describe(date, includeTime: due.hour != nil)))"
            }
            return line + " [\(reminder.calendar?.title ?? "")]"
        }
        return ToolOutput(text: "\(reminders.count) open reminder(s):\n" + lines.joined(separator: "\n"))
    }
}

struct CompleteReminderTool: AgentTool {
    let name = "complete_reminder"
    let activityLabel = "Ticking off reminder"
    let description = "Mark an open reminder as done, matched by (part of) its title."
    let parameters = Schema.object(["title": Schema.string("Title or part of it.")], required: ["title"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await EventKitAccess.requireReminders()
        let query = try args.requiredString("title").lowercased()
        let predicate = EventKitAccess.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let matches = await fetchReminders(predicate).filter { ($0.title ?? "").lowercased().contains(query) }
        guard let reminder = matches.first else { return ToolOutput(text: "No open reminder matches \"\(query)\".") }
        reminder.isCompleted = true
        try EventKitAccess.store.save(reminder, commit: true)
        return ToolOutput(text: "Marked \"\(reminder.title ?? "")\" as done." + (matches.count > 1 ? " (\(matches.count - 1) other match(es) left open.)" : ""))
    }
}

// MARK: - Location & weather

struct CurrentLocationTool: AgentTool {
    let name = "get_current_location"
    let activityLabel = "Finding your location"
    let description = "Get the user's approximate current location (city, country, coordinates)."
    let parameters = Schema.object([:])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let location = try await LocationService.shared.currentLocation()
        let place = await LocationService.placeName(for: location) ?? "Unknown place"
        return ToolOutput(text: String(format: "%@ (%.4f, %.4f)", place, location.coordinate.latitude, location.coordinate.longitude))
    }
}

enum WeatherCodes {
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61, 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71, 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80, 81: return "rain showers"
        case 82: return "violent rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "weather code \(code)"
        }
    }
}

struct WeatherTool: AgentTool {
    let name = "get_weather"
    let activityLabel = "Checking the weather"
    let description = "Current weather and forecast for a place (default: the user's current location). Free Open-Meteo data."
    let parameters = Schema.object([
        "location": Schema.string("City or place (optional; default current location)."),
        "days": Schema.integer("Forecast days, 1–7 (default 3).")
    ])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let coordinate: CLLocationCoordinate2D
        let place: String
        if let query = args.optionalString("location") {
            let result = try await LocationService.geocode(query)
            coordinate = result.location.coordinate
            place = result.name
        } else {
            let location = try await LocationService.shared.currentLocation()
            coordinate = location.coordinate
            place = await LocationService.placeName(for: location) ?? "your location"
        }
        let days = min(max(args.int("days") ?? 3, 1), 7)
        let imperial = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "temperature_unit", value: imperial ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: imperial ? "mph" : "kmh")
        ]
        let (data, _) = try await HTTP.session.data(from: components.url!)
        let json = try JSONValue.parse(data)
        if let reason = json["reason"]?.stringValue { throw ToolError.invalid("Weather service: \(reason)") }
        let unit = imperial ? "°F" : "°C"
        let wind = imperial ? "mph" : "km/h"
        var lines = ["Weather for \(place):"]
        if let current = json["current"] {
            let temp = current["temperature_2m"]?.doubleValue ?? 0
            let feels = current["apparent_temperature"]?.doubleValue ?? temp
            let code = current["weather_code"]?.intValue ?? -1
            lines.append(String(format: "Now: %.0f%@ (feels %.0f%@), %@, humidity %ld%%, wind %.0f %@",
                                temp, unit, feels, unit, WeatherCodes.describe(code),
                                current["relative_humidity_2m"]?.intValue ?? 0, current["wind_speed_10m"]?.doubleValue ?? 0, wind))
        }
        if let daily = json["daily"], let dates = daily["time"]?.arrayValue {
            for (index, date) in dates.enumerated() {
                let high = daily["temperature_2m_max"]?[index]?.doubleValue ?? 0
                let low = daily["temperature_2m_min"]?[index]?.doubleValue ?? 0
                let rain = daily["precipitation_probability_max"]?[index]?.intValue ?? 0
                let code = daily["weather_code"]?[index]?.intValue ?? -1
                lines.append(String(format: "%@: %@, %.0f/%.0f%@, rain %ld%%", date.stringValue ?? "", WeatherCodes.describe(code), high, low, unit, rain))
            }
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

// MARK: - Timers

struct SetTimerTool: AgentTool {
    let name = "set_timer"
    let activityLabel = "Setting a timer"
    let description = "Set a timer or a quick reminder that pops up as a notification after a delay or at a time today/another day."
    let parameters = Schema.object([
        "minutes": Schema.number("Minutes from now (optional)."),
        "seconds": Schema.integer("Seconds from now (optional)."),
        "at": Schema.string("Exact time \"yyyy-MM-dd HH:mm\" (optional, instead of minutes)."),
        "title": Schema.string("Notification title, e.g. \"Tea is ready\"."),
        "message": Schema.string("Notification text (optional).")
    ], required: ["title"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var delay: TimeInterval = 0
        if let at = args.optionalString("at"), let date = DateParser.parse(at) {
            delay = date.timeIntervalSinceNow
        } else {
            delay = (args["minutes"]?.doubleValue ?? 0) * 60 + Double(args.int("seconds") ?? 0)
        }
        guard delay >= 1 else { throw ToolError.invalid("The timer needs a time in the future.") }
        let title = try args.requiredString("title")
        let fire = try await Notifier.schedule(title: title, body: args.optionalString("message") ?? "Timer from JARVIS", after: delay)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = delay > 20 * 3600 ? .medium : .none
        return ToolOutput(text: "Timer \"\(title)\" set for \(formatter.string(from: fire)) (in \(Int(delay / 60)) min \(Int(delay) % 60) s).")
    }
}

// MARK: - Memory

struct RememberTool: AgentTool {
    let name = "remember"
    let activityLabel = "Remembering"
    let description = "Save a lasting fact or preference about the user (name, family, likes, routines, goals) to long-term memory. Use when the user shares something worth remembering or says \"remember…\"."
    let parameters = Schema.object(["fact": Schema.string("The fact, written in third person, e.g. \"Prefers metric units\".")], required: ["fact"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let fact = try args.requiredString("fact")
        let saved = await MemoryStore.shared.add(fact)
        return ToolOutput(text: saved == nil ? "Nothing to remember." : "Remembered: \(fact)")
    }
}

struct ForgetTool: AgentTool {
    let name = "forget"
    let activityLabel = "Forgetting"
    let description = "Delete memories containing the given text."
    let parameters = Schema.object(["query": Schema.string("Text the memory contains.")], required: ["query"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let removed = await MemoryStore.shared.remove(matching: try args.requiredString("query"))
        return ToolOutput(text: removed.isEmpty ? "No matching memories." : "Forgot: " + removed.map(\.text).joined(separator: "; "))
    }
}

struct RecallTool: AgentTool {
    let name = "recall_memories"
    let activityLabel = "Recalling"
    let description = "List everything JARVIS remembers about the user."
    let parameters = Schema.object([:])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let items = await MemoryStore.shared.items
        return ToolOutput(text: items.isEmpty ? "No memories saved yet." : items.map { "- \($0.text)" }.joined(separator: "\n"))
    }
}
