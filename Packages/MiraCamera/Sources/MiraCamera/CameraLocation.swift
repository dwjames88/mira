#if os(iOS)
import CoreLocation
import Foundation

/// The latest location, only while the user has "Add location to frames" on. Asks for when-in-use access the
/// first time it is enabled and never otherwise. The location goes into the photo's metadata and nowhere else.
@MainActor
final class CameraLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private var enabled = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        guard on else {
            manager.stopUpdatingLocation()
            latest = nil
            return
        }
        apply(manager.authorizationStatus)
    }

    private func apply(_ status: CLAuthorizationStatus) {
        guard enabled else { return }
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: latest = nil
        }
    }

    // CoreLocation calls these on the thread the manager was made on (the main thread); they stay
    // nonisolated and hop, so no main-actor closure is ever called from a CoreLocation queue.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.apply(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor [weak self] in self?.latest = last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
#endif
