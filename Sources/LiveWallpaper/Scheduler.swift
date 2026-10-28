import AppKit
import CoreLocation
import os

/// Switches the default wallpaper on a schedule: at set times of day, at sunrise and sunset, or with
/// macOS's Light/Dark appearance. Wakes only at the next change (and after sleep or a clock change).
@MainActor
final class Scheduler: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Mode: String, CaseIterable, PrefValue {
        case off, times, sun, appearance
        var title: String {
            switch self {
            case .off: "Off"
            case .times: "By time of day"
            case .sun: "Sunrise & sunset"
            case .appearance: "Light & Dark mode"
            }
        }
    }

    /// From `minutes` after midnight, show `wallpaper` (a library file name).
    struct TimeRule: Codable, Hashable {
        var minutes: Int
        var wallpaper: String
    }

    /// Called with the file name of the wallpaper that should be showing now.
    var onApply: ((String) -> Void)?

    var mode: Mode {
        get { Prefs.value("scheduleMode", Mode.off) }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue.rawValue, forKey: "scheduleMode"); refresh() }
    }

    var rules: [TimeRule] {
        get { (UserDefaults.standard.data(forKey: "scheduleTimes").flatMap { try? JSONDecoder().decode([TimeRule].self, from: $0) }) ?? [] }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue.sorted { $0.minutes < $1.minutes }), forKey: "scheduleTimes")
            refresh()
        }
    }

    /// Daytime / Light-mode wallpaper and night / Dark-mode wallpaper (file names).
    var dayWallpaper: String {
        get { Prefs.value("scheduleDay", "") }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "scheduleDay"); refresh() }
    }
    var nightWallpaper: String {
        get { Prefs.value("scheduleNight", "") }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "scheduleNight"); refresh() }
    }

    /// Where sunrise and sunset are worked out for (degrees; east and north positive).
    var latitude: Double? {
        get { UserDefaults.standard.object(forKey: "scheduleLatitude") as? Double }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "scheduleLatitude"); refresh() }
    }
    var longitude: Double? {
        get { UserDefaults.standard.object(forKey: "scheduleLongitude") as? Double }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "scheduleLongitude"); refresh() }
    }
    @Published private(set) var locationMessage: String?

    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private let locationManager = CLLocationManager()
    private let log = Logger(subsystem: "LiveWallpaper", category: "schedule")

    override init() {
        super.init()
        locationManager.delegate = self
        let ws = NSWorkspace.shared.notificationCenter
        for (center, name) in [(ws, NSWorkspace.didWakeNotification), (NotificationCenter.default, .NSSystemClockDidChange),
                               (DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification"))] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The appearance notification arrives just before the change lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
            })
        }
    }

    var isActive: Bool { mode != .off }

    /// Applies what should show now and arms a timer for the next change.
    func refresh() {
        timer?.invalidate()
        timer = nil
        guard mode != .off else { return }
        let now = Date()
        if let wallpaper = wallpaper(at: now), !wallpaper.isEmpty { onApply?(wallpaper) }
        guard let next = nextChange(after: now) else { return }
        log.notice("next scheduled change at \(next, privacy: .public)")
        timer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSinceNow + 1, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The wallpaper the schedule wants at `date`.
    func wallpaper(at date: Date) -> String? {
        switch mode {
        case .off: return nil
        case .times: return Self.activeRule(rules, minutes: Self.minutes(of: date))?.wallpaper
        case .appearance:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? nightWallpaper : dayWallpaper
        case .sun:
            guard let latitude, let longitude, let sun = Self.sunTimes(on: date, latitude: latitude, longitude: longitude) else {
                return dayWallpaper
            }
            return (sun.sunrise...sun.sunset).contains(date) ? dayWallpaper : nightWallpaper
        }
    }

    private func nextChange(after date: Date) -> Date? {
        switch mode {
        case .off, .appearance: return nil
        case .times:
            let now = Self.minutes(of: date)
            guard let next = rules.map(\.minutes).sorted().first(where: { $0 > now }) ?? rules.map(\.minutes).min() else { return nil }
            let day = Calendar.current.startOfDay(for: date)
            let candidate = Calendar.current.date(byAdding: .minute, value: next, to: day)!
            return candidate > date ? candidate : Calendar.current.date(byAdding: .day, value: 1, to: candidate)
        case .sun:
            guard let latitude, let longitude else { return nil }
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date)!
            let times = [date, tomorrow].compactMap { Self.sunTimes(on: $0, latitude: latitude, longitude: longitude) }
                .flatMap { [$0.sunrise, $0.sunset] }
            return times.filter { $0 > date }.min()
        }
    }

    // MARK: Location

    /// Asks macOS for this Mac's approximate location (once) to work out sunrise and sunset.
    func useCurrentLocation() {
        locationMessage = "Finding your location…"
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationMessage = "Location access is off for LiveWallpaper (System Settings › Privacy & Security › Location Services). Enter your latitude and longitude instead."
        default: locationManager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard locationMessage != nil else { return }
            if status == .authorizedAlways || status == .authorized { manager.requestLocation() }
            else if status == .denied || status == .restricted {
                locationMessage = "Location access was declined. Enter your latitude and longitude instead."
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            // Rounded to about a kilometre: plenty for sunrise times, and no more precise than needed.
            latitude = (location.coordinate.latitude * 100).rounded() / 100
            longitude = (location.coordinate.longitude * 100).rounded() / 100
            locationMessage = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { locationMessage = "Couldn't find your location (\(error.localizedDescription)). Enter it below instead." }
    }

    // MARK: Pure helpers (tested)

    static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The rule in effect at `minutes`: the latest one at or before it, wrapping to yesterday's last rule.
    static func activeRule(_ rules: [TimeRule], minutes: Int) -> TimeRule? {
        let sorted = rules.sorted { $0.minutes < $1.minutes }
        return sorted.last { $0.minutes <= minutes } ?? sorted.last
    }

    /// Sunrise and sunset on `date`'s day (the sunrise equation; within a couple of minutes of NOAA).
    /// nil during polar day or night.
    static func sunTimes(on date: Date, latitude: Double, longitude: Double) -> (sunrise: Date, sunset: Date)? {
        let rad = Double.pi / 180
        // Julian day number of local noon, then the mean solar day count since J2000.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let julian = noon.timeIntervalSince1970 / 86400 + 2440587.5
        let n = (julian - 2451545.0 + 0.0008).rounded()
        let meanNoon = n - longitude / 360
        let anomaly = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sin(anomaly * rad) + 0.0200 * sin(2 * anomaly * rad) + 0.0003 * sin(3 * anomaly * rad)
        let ecliptic = (anomaly + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let transit = 2451545.0 + meanNoon + 0.0053 * sin(anomaly * rad) - 0.0069 * sin(2 * ecliptic * rad)
        let declination = asin(sin(ecliptic * rad) * sin(23.4397 * rad))
        let cosHour = (sin(-0.833 * rad) - sin(latitude * rad) * sin(declination)) / (cos(latitude * rad) * cos(declination))
        guard abs(cosHour) <= 1 else { return nil }
        let hour = acos(cosHour) / rad
        func fromJulian(_ j: Double) -> Date { Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }
        return (fromJulian(transit - hour / 360), fromJulian(transit + hour / 360))
    }
}
