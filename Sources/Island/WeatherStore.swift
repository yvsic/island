import AppKit
import CoreLocation
import SwiftUI

struct WeatherNow: Equatable {
    var temperature: Double
    var high: Double
    var low: Double
    var code: Int
    var isDay: Bool
    var place: String

    var symbol: String { WeatherCode.symbol(code, isDay: isDay) }
    var summary: String { WeatherCode.summary(code) }
}

/// The next day, hour by hour: enough to see a storm, a gale or a frost coming.
struct WeatherOutlook: Equatable {
    struct Hour: Equatable {
        var date: Date
        var code: Int
        /// Strongest gust in the hour, km/h.
        var gust: Double
        /// In the unit chosen in Settings.
        var temperature: Double
        var uv: Double
        /// Millimetres in the hour.
        var rain: Double
    }

    var hours: [Hour]
    var fahrenheit: Bool

    static let stormCodes: Set<Int> = [95, 96, 99]

    /// Hours still ahead (the hour in progress counts).
    func ahead(_ now: Date = .now, within hoursAhead: Double = 24) -> [Hour] {
        hours.filter { $0.date > now - 3600 && $0.date < now + hoursAhead * 3600 }
    }

    /// The first hour with a thunderstorm in it.
    func storm(_ now: Date = .now) -> Hour? { ahead(now).first { Self.stormCodes.contains($0.code) } }
    /// The strongest gust ahead, if it is worth a mention (50 km/h and up).
    func gale(_ now: Date = .now) -> Hour? {
        ahead(now).max { $0.gust < $1.gust }.flatMap { $0.gust >= 50 ? $0 : nil }
    }
    func heavyRain(_ now: Date = .now) -> Hour? {
        ahead(now, within: 12).first { [65, 67, 82].contains($0.code) || $0.rain >= 7.5 }
    }
    func snow(_ now: Date = .now) -> Hour? { ahead(now, within: 18).first { [71, 73, 75, 77, 85, 86].contains($0.code) } }
    func freezingRain(_ now: Date = .now) -> Hour? { ahead(now, within: 18).first { [56, 57, 66, 67].contains($0.code) } }
    func frost(_ now: Date = .now) -> Hour? {
        let limit = fahrenheit ? 32.0 : 0.0
        return ahead(now, within: 18).filter { $0.temperature <= limit }.min { $0.temperature < $1.temperature }
    }
    func heat(_ now: Date = .now) -> Hour? {
        let limit = fahrenheit ? 95.0 : 35.0
        return ahead(now, within: 18).filter { $0.temperature >= limit }.max { $0.temperature < $1.temperature }
    }
    func strongSun(_ now: Date = .now) -> Hour? {
        ahead(now, within: 12).max { $0.uv < $1.uv }.flatMap { $0.uv >= 8 ? $0 : nil }
    }

    /// Weather that tends to take the power down with it, and when.
    func outageRisk(_ now: Date = .now) -> (date: Date, reason: String)? {
        var risks: [(Date, String)] = []
        if let storm = storm(now) { risks.append((storm.date, "Thunderstorms")) }
        if let gale = gale(now), gale.gust >= 75 { risks.append((gale.date, "Gale-force gusts")) }
        if let ice = freezingRain(now) { risks.append((ice.date, "Freezing rain")) }
        if let snow = ahead(now, within: 18).first(where: { [75, 86].contains($0.code) }) { risks.append((snow.date, "Heavy snow")) }
        return risks.min { $0.0 < $1.0 }.map { (date: $0.0, reason: $0.1) }
    }
}

/// Current weather from Open-Meteo (free, no account), for the Mac's location
/// or a city chosen in Settings. Coordinates are rounded to about 1 km first.
@Observable
final class WeatherStore: NSObject {
    enum LocationState: Equatable { case unknown, locating, denied, ready }

    private(set) var now: WeatherNow?
    /// Today's and tomorrow's sunrises and sunsets.
    private(set) var sunrises: [Date] = []
    private(set) var sunsets: [Date] = []
    /// When rain is due to start, if it's dry now and rain is within the hour.
    private(set) var rainStart: Date?
    /// Called when a fetch finds rain on the way.
    @ObservationIgnored var onRain: ((Date) -> Void)?
    @ObservationIgnored private var announcedRain: Date?
    /// The next 24 hours, for storm, wind and frost warnings.
    private(set) var outlook: WeatherOutlook?
    /// Called once per storm, when a thunderstorm is under an hour and a half away.
    @ObservationIgnored var onStorm: ((Date) -> Void)?
    @ObservationIgnored private var announcedStorm: Date?
    private(set) var locationState: LocationState = .unknown
    private(set) var lastError: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let locations = CLLocationManager()
    @ObservationIgnored private var coordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var fetchedAt = Date.distantPast
    @ObservationIgnored private var refresher: Task<Void, Never>?

    private var prefs: Preferences { Preferences.shared }

    func start() {
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyKilometer
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh(force: true)
                // Often enough for a rain warning to be worth having.
                try? await Task.sleep(for: .seconds(10 * 60))
            }
        }
    }

    /// Fetches again if the reading is older than 15 minutes (or always, if forced).
    func refresh(force: Bool = false) {
        guard prefs.showWeather else {
            if now != nil { now = nil; onChange?() }
            return
        }
        guard force || Date.now.timeIntervalSince(fetchedAt) > 15 * 60 else { return }
        if prefs.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty {
            locateThenFetch()
        } else {
            Task { await fetchForCity(prefs.weatherCity) }
        }
    }

    // MARK: Location

    private func locateThenFetch() {
        switch locations.authorizationStatus {
        case .notDetermined:
            locationState = .locating
            locations.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationState = .denied
            clear()
        default:
            locationState = .locating
            locations.requestLocation()
        }
    }

    // MARK: Fetching

    /// No disk cache and no cookies: where you are never lands in a file.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private func fetchForCity(_ city: String) async {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        guard let url = parts.url,
              let (data, _) = try? await Self.session.data(from: url),
              let result = try? JSONDecoder().decode(GeocodeResponse.self, from: data),
              let place = result.results?.first else {
            lastError = "Couldn't find \u{201C}\(city)\u{201D}"
            clear()
            return
        }
        lastError = nil
        await fetch(latitude: place.latitude, longitude: place.longitude, place: place.name)
    }

    private func fetch(latitude: Double, longitude: Double, place: String) async {
        // Two decimals is about 1 km: enough for weather, no more precise than that.
        let lat = (latitude * 100).rounded() / 100, lon = (longitude * 100).rounded() / 100
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day,precipitation"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "minutely_15", value: "precipitation"),
            .init(name: "forecast_minutely_15", value: "8"),
            .init(name: "hourly", value: "weather_code,wind_gusts_10m,temperature_2m,uv_index,precipitation"),
            .init(name: "forecast_hours", value: "24"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "temperature_unit", value: prefs.useFahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await Self.session.data(from: url),
              let forecast = try? JSONDecoder().decode(ForecastResponse.self, from: data) else {
            lastError = "Weather isn't available right now"
            return
        }
        lastError = nil
        fetchedAt = .now
        let reading = WeatherNow(temperature: forecast.current.temperature_2m,
                                 high: forecast.daily.temperature_2m_max.first ?? forecast.current.temperature_2m,
                                 low: forecast.daily.temperature_2m_min.first ?? forecast.current.temperature_2m,
                                 code: forecast.current.weather_code,
                                 isDay: forecast.current.is_day == 1,
                                 place: place)
        sunrises = (forecast.daily.sunrise ?? []).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        sunsets = (forecast.daily.sunset ?? []).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        findRain(forecast)
        readOutlook(forecast)
        let appeared = now == nil
        if reading != now { now = reading }
        if appeared { onChange?() }
    }

    /// Dry now, wet soon: the first quarter-hour ahead with real rain in it.
    private func findRain(_ forecast: ForecastResponse) {
        rainStart = nil
        guard let slots = forecast.minutely_15, (forecast.current.precipitation ?? 0) < 0.05 else { return }
        for (time, amount) in zip(slots.time, slots.precipitation) {
            let start = Date(timeIntervalSince1970: TimeInterval(time))
            guard start > .now, start.timeIntervalSinceNow < 60 * 60, (amount ?? 0) >= 0.1 else { continue }
            rainStart = start
            // One warning per shower, not one per fetch.
            if announcedRain.map({ abs($0.timeIntervalSince(start)) > 45 * 60 }) ?? true {
                announcedRain = start
                onRain?(start)
            }
            return
        }
    }

    private func readOutlook(_ forecast: ForecastResponse) {
        guard let hourly = forecast.hourly else {
            outlook = nil
            return
        }
        // Every list is read by position; a short one just ends the outlook early.
        let count = [hourly.time.count, hourly.weather_code.count, hourly.wind_gusts_10m.count,
                     hourly.temperature_2m.count, hourly.uv_index.count, hourly.precipitation.count].min() ?? 0
        let hours = (0..<count).map { i in
            WeatherOutlook.Hour(date: Date(timeIntervalSince1970: TimeInterval(hourly.time[i])),
                                code: hourly.weather_code[i] ?? 0, gust: hourly.wind_gusts_10m[i] ?? 0,
                                temperature: hourly.temperature_2m[i] ?? 0, uv: hourly.uv_index[i] ?? 0,
                                rain: hourly.precipitation[i] ?? 0)
        }
        let reading = WeatherOutlook(hours: hours, fahrenheit: prefs.useFahrenheit)
        if reading != outlook { outlook = reading }
        // One warning per storm, when it is close enough to act on.
        if let storm = reading.storm(), storm.date.timeIntervalSinceNow < 90 * 60,
           announcedStorm.map({ abs($0.timeIntervalSince(storm.date)) > 3 * 3600 }) ?? true {
            announcedStorm = storm.date
            onStorm?(max(storm.date, .now))
        }
    }

    /// The next sunrise or sunset, if it is within `lead` minutes.
    func sunEvent(at date: Date = .now, lead: Int) -> (isSunrise: Bool, date: Date)? {
        let events = sunrises.map { (true, $0) } + sunsets.map { (false, $0) }
        guard let next = events.filter({ $0.1 > date }).min(by: { $0.1 < $1.1 }),
              next.1.timeIntervalSince(date) <= Double(lead) * 60 else { return nil }
        return next
    }

    private func clear() {
        outlook = nil
        guard now != nil else { return }
        now = nil
        onChange?()
    }

    func openWeatherApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    /// For snapshots.
    func setPreview(_ reading: WeatherNow?, sunsetIn minutes: Double? = nil, outlook: WeatherOutlook? = nil) {
        now = reading
        sunsets = minutes.map { [Date.now + $0 * 60] } ?? []
        self.outlook = outlook
    }
}

extension WeatherStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways:
                self.locationState = .locating
                self.locations.requestLocation()
            case .denied, .restricted:
                self.locationState = .denied
                self.clear()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            self.coordinate = coordinate
            self.locationState = .ready
            await self.fetch(latitude: coordinate.latitude, longitude: coordinate.longitude, place: "Current Location")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Keep the last reading; try again next refresh.
            if self.locationState == .locating { self.locationState = .unknown }
        }
    }
}

// MARK: - Open-Meteo responses

nonisolated private struct GeocodeResponse: Decodable {
    struct Place: Decodable { let name: String; let latitude: Double; let longitude: Double }
    let results: [Place]?
}

nonisolated private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double; let weather_code: Int; let is_day: Int; let precipitation: Double?
    }
    struct Daily: Decodable {
        let temperature_2m_max: [Double]; let temperature_2m_min: [Double]
        let sunrise: [Int]?; let sunset: [Int]?
    }
    struct Minutely: Decodable { let time: [Int]; let precipitation: [Double?] }
    struct Hourly: Decodable {
        let time: [Int]; let weather_code: [Int?]; let wind_gusts_10m: [Double?]
        let temperature_2m: [Double?]; let uv_index: [Double?]; let precipitation: [Double?]
    }
    let current: Current
    let daily: Daily
    let minutely_15: Minutely?
    let hourly: Hourly?
}

/// WMO weather codes, as Open-Meteo reports them.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func summary(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing Drizzle"
        case 61, 63, 80, 81: "Rain"
        case 65, 82: "Heavy Rain"
        case 66, 67: "Freezing Rain"
        case 71, 73, 75, 77, 85, 86: "Snow"
        case 95, 96, 99: "Thunderstorms"
        default: "Cloudy"
        }
    }
}

/// The moon's phase, worked out from the date alone.
enum MoonPhase {
    static func now(_ date: Date = .now) -> (name: String, symbol: String) {
        // Days since a known new moon (6 January 2000, 18:14 UTC), in lunar months.
        let age = (date.timeIntervalSince1970 - 947_182_440) / 86_400 / 29.530588853
        let phase = age - age.rounded(.down)
        let index = Int((phase * 8).rounded()) % 8
        return [("New Moon", "moonphase.new.moon"), ("Waxing Crescent", "moonphase.waxing.crescent"),
                ("First Quarter", "moonphase.first.quarter"), ("Waxing Gibbous", "moonphase.waxing.gibbous"),
                ("Full Moon", "moonphase.full.moon"), ("Waning Gibbous", "moonphase.waning.gibbous"),
                ("Last Quarter", "moonphase.last.quarter"), ("Waning Crescent", "moonphase.waning.crescent")][index]
    }
}
