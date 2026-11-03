import Foundation
import CoreLocation

/// One-shot location lookups for weather and "near me" questions.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways: return true
        #if os(iOS)
        case .authorizedWhenInUse: return true
        #endif
        default: return false
        }
    }

    func currentLocation() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                authorizationWaiters.append(continuation)
            }
        }
        guard isAuthorized else {
            throw ToolError.invalid("Location access is off. Ask the user for a city name, or enable Location for JARVIS in Settings.")
        }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -600 { return recent }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            locationWaiters.append(continuation)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let waiters = self.locationWaiters
            self.locationWaiters = []
            waiters.forEach { $0.resume(returning: location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let waiters = self.locationWaiters
            self.locationWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let waiters = self.authorizationWaiters
            self.authorizationWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    static func placeName(for location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ", ")
    }

    static func geocode(_ query: String) async throws -> (location: CLLocation, name: String) {
        guard let placemark = try await CLGeocoder().geocodeAddressString(query).first, let location = placemark.location else {
            throw ToolError.invalid("Couldn't find a place called \"\(query)\".")
        }
        let name = [placemark.locality ?? placemark.name, placemark.country].compactMap { $0 }.joined(separator: ", ")
        return (location, name.isEmpty ? query : name)
    }
}
