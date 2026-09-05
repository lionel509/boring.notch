//
//  WeatherManager.swift
//  boringNotch
//
//  Current conditions for the notch's backdrop.
//

import Combine
import Defaults
import Foundation

/// What the sky is doing, reduced to the handful of states the backdrop can actually draw.
enum SkyCondition: String, Equatable {
    case clear, cloudy, fog, rain, snow, storm

    /// WMO weather codes, which is what Open-Meteo speaks.
    init(wmoCode code: Int) {
        switch code {
        case 0, 1: self = .clear
        case 2, 3: self = .cloudy
        case 45, 48: self = .fog
        case 51...57, 61...67, 80...82: self = .rain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .storm
        default: self = .cloudy
        }
    }

    var label: String {
        switch self {
        case .clear: "CLEAR"
        case .cloudy: "CLOUDY"
        case .fog: "FOG"
        case .rain: "RAIN"
        case .snow: "SNOW"
        case .storm: "STORM"
        }
    }
}

/// Fetches current conditions from Open-Meteo.
///
/// Open-Meteo rather than WeatherKit for the reason that governs everything else here: this
/// app is GPL-3.0, so any build handed to anyone ships its source, and **a key pasted into
/// it is a key published**. Open-Meteo needs no key, no account and no auth header.
/// WeatherKit would also need a paid developer account and an entitlement an ad-hoc build
/// cannot carry.
///
/// Location comes from a place name the user types, geocoded once and cached — not from an
/// IP lookup, which would hand a third party an address on every refresh. With no place set
/// the backdrop still works: it falls back to a time-of-day sky, which needs no network at
/// all and no permission.
@MainActor
final class WeatherManager: ObservableObject {
    static let shared = WeatherManager()

    struct Conditions: Equatable {
        var condition: SkyCondition
        var temperatureC: Double
        var high: Double?
        var low: Double?
        var isDay: Bool
        var sunrise: Date?
        var sunset: Date?
        var fetchedAt: Date
    }

    @Published private(set) var conditions: Conditions?
    @Published private(set) var statusMessage = "No place set"

    /// Weather changes on the hour, not the frame. One fetch per quarter hour is generous,
    /// and none happen at all while the notch is closed because nothing calls refresh().
    private static let cacheLifetime: TimeInterval = 900
    private var isFetching = false

    private init() {}

    /// True when there is no real data, so the backdrop should draw a plain time-of-day sky.
    var isUsingClockFallback: Bool { conditions == nil }

    /// Day or night without any network: good enough to pick a palette, and the only thing
    /// available before a place is set.
    var isDaytimeByClock: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return (7..<19).contains(hour)
    }

    /// How far through the daylight hours we are, 0 at sunrise and 1 at sunset. Falls back
    /// to a plain 6:30–19:30 assumption when there is no place set, which is close enough to
    /// put the sun in roughly the right part of the sky.
    var sunProgress: Double {
        let now = Date()
        let calendar = Calendar.current

        let rise = conditions?.sunrise
            ?? calendar.date(bySettingHour: 6, minute: 30, second: 0, of: now)
        let set = conditions?.sunset
            ?? calendar.date(bySettingHour: 19, minute: 30, second: 0, of: now)

        guard let rise, let set, set > rise else { return 0.5 }
        let span = set.timeIntervalSince(rise)
        return min(max(now.timeIntervalSince(rise) / span, 0), 1)
    }

    /// How far through the lunar cycle we are: 0 and 1 are new, 0.25 first quarter,
    /// 0.5 full, 0.75 last quarter.
    ///
    /// Pure arithmetic off the clock — the synodic month is 29.530588853 days and
    /// 2000-01-06 18:14 UTC was a new moon, so this needs no network, no key and no
    /// permission, which is the whole reason it is worth drawing. It ignores the small
    /// libration wobble in the true cycle; over a human lifetime the drift is under a day,
    /// which is far below what a 14 pt disc can show.
    var moonPhase: Double {
        let newMoonEpoch = Date(timeIntervalSince1970: 947_182_440)
        let synodicMonth: TimeInterval = 29.530588853 * 86_400
        let elapsed = Date().timeIntervalSince(newMoonEpoch)
        let cycles = elapsed / synodicMonth
        return cycles - floor(cycles)
    }

    /// Where the moon sits along its arc, 0 rising and 1 setting. Nil while it is below
    /// the horizon, which is most of the night for a young or old moon.
    ///
    /// The moon's elongation from the sun *is* its phase, so its daily arc is the sun's
    /// shifted by exactly that: a new moon rides with the sun and is up in daylight, a full
    /// moon is opposite it and highest at midnight. That relationship is real, so tracking
    /// it costs one subtraction and beats parking a moon in the corner all night.
    var moonProgress: Double? {
        let now = Date()
        let calendar = Calendar.current

        let rise = conditions?.sunrise
            ?? calendar.date(bySettingHour: 6, minute: 30, second: 0, of: now)
        let set = conditions?.sunset
            ?? calendar.date(bySettingHour: 19, minute: 30, second: 0, of: now)
        guard let rise, let set, set > rise else { return nil }

        // Solar noon, and how far past it we are as a fraction of the whole day.
        let noon = rise.addingTimeInterval(set.timeIntervalSince(rise) / 2)
        let sinceNoon = now.timeIntervalSince(noon) / 86_400
        // The moon trails the sun by its phase. Wrapped to -0.5...0.5 so 0 is the moon's
        // own high point and +/-0.5 is its low point.
        var fromMoonHigh = sinceNoon - moonPhase
        fromMoonHigh -= (fromMoonHigh + 0.5).rounded(.down)

        // Up for the half cycle centred on its high point; the edges are the horizon.
        guard abs(fromMoonHigh) < 0.25 else { return nil }
        return fromMoonHigh * 2 + 0.5
    }

    /// Fahrenheit or Celsius, taken from the user's own locale rather than from a
    /// setting nobody would find. Open-Meteo is asked for Celsius and converted here, so
    /// switching regions costs no refetch.
    var usesFahrenheit: Bool {
        Locale.current.measurementSystem == .us
    }

    /// The current temperature as it should be shown, or nil when there is nothing
    /// measured yet — no place set, or the first fetch still in flight.
    var temperatureText: String? {
        guard let conditions else { return nil }
        let value = usesFahrenheit
            ? conditions.temperatureC * 9 / 5 + 32
            : conditions.temperatureC
        return "\(Int(value.rounded()))°"
    }

    func refresh() {
        guard !isFetching else { return }
        if let conditions, Date().timeIntervalSince(conditions.fetchedAt) < Self.cacheLifetime {
            return
        }

        let place = Defaults[.weatherPlace].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else {
            statusMessage = "No place set — showing a time-of-day sky"
            return
        }

        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                let coordinate = try await coordinate(for: place)
                let fetched = try await currentConditions(at: coordinate)
                conditions = fetched
                statusMessage = "\(place) · \(fetched.condition.label.capitalized) "
                    + "\(Int(fetched.temperatureC.rounded()))°C"
            } catch {
                statusMessage = "Lookup failed — \((error as NSError).localizedDescription)"
            }
        }
    }

    // MARK: - Network

    /// Geocoded once per place name and cached, so a fixed location costs one lookup ever
    /// rather than one per refresh.
    private func coordinate(for place: String) async throws -> (latitude: Double, longitude: Double) {
        if Defaults[.weatherResolvedPlace] == place {
            return (Defaults[.weatherLatitude], Defaults[.weatherLongitude])
        }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: place),
            URLQueryItem(name: "count", value: "1"),
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let first = results.first,
              let latitude = first["latitude"] as? Double,
              let longitude = first["longitude"] as? Double
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        Defaults[.weatherResolvedPlace] = place
        Defaults[.weatherLatitude] = latitude
        Defaults[.weatherLongitude] = longitude
        return (latitude, longitude)
    }

    private func currentConditions(
        at coordinate: (latitude: Double, longitude: Double)
    ) async throws -> Conditions {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let daily = object["daily"] as? [String: Any]
        func firstValue(_ key: String) -> Double? {
            (daily?[key] as? [Double])?.first
        }
        // Open-Meteo returns these as local wall-clock without an offset when timezone=auto.
        let localTimes = DateFormatter()
        localTimes.locale = Locale(identifier: "en_US_POSIX")
        localTimes.dateFormat = "yyyy-MM-dd'T'HH:mm"
        func firstTime(_ key: String) -> Date? {
            ((daily?[key] as? [String])?.first).flatMap(localTimes.date(from:))
        }

        return Conditions(
            condition: SkyCondition(wmoCode: code),
            temperatureC: temperature,
            high: firstValue("temperature_2m_max"),
            low: firstValue("temperature_2m_min"),
            isDay: (current["is_day"] as? Int) != 0,
            sunrise: firstTime("sunrise"),
            sunset: firstTime("sunset"),
            fetchedAt: Date())
    }
}
