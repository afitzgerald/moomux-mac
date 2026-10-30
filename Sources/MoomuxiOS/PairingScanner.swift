import AVFoundation
import SwiftUI
import UIKit
import VisionKit

/// Whether the camera can scan here, and if not, why.
enum ScanAvailability: Equatable {
    case scanning, asking, off, unsupported

    /// Support before access, so a device that can't scan never prompts.
    /// Read when the Connect screen appears: changing the answer in Settings
    /// relaunches the app.
    @MainActor static var current: ScanAvailability {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return DataScannerViewController.isAvailable ? .scanning : .unsupported
        case .notDetermined: return .asking
        case .denied, .restricted: return .off
        @unknown default: return .unsupported
        }
    }

    var showsViewfinder: Bool { self == .scanning || self == .asking }
}

/// The connect screen's camera, reading QR codes for the pairing link.
///
/// It only reports what it read. Whether a code is a pairing link, and asking
/// before connecting to one, is the app's, on the same path as a link opened
/// from outside, so a scanned code cannot connect without a tap either. Where
/// the camera can't run, one line says why instead.
struct PairingScanner: View {
    @Binding var camera: ScanAvailability
    /// Keeps the camera off, the permission prompt included.
    let paused: Bool
    let onCode: (String) -> Void

    var body: some View {
        switch camera {
        case .scanning:
            viewfinder(QRScanner(paused: paused, onCode: onCode, onUnavailable: { why in
                camera = why == .cameraRestricted ? .off : .unsupported
            }))
        case .asking:
            // The scanner calls itself unavailable until access is granted,
            // so the prompt is ours to raise, and not over anything else.
            viewfinder(EmptyView())
                .task(id: paused) {
                    guard !paused else { return }
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    camera = .current
                }
        case .off:
            Text("Camera access is off. Allow it in Settings, or connect manually.")
            Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
        case .unsupported:
            Text("This iPhone can't scan here. Scan the code with the Camera app, or connect manually.")
        }
    }

    /// Square, as wide as the row up to a cap, with no row behind it.
    private func viewfinder(_ inside: some View) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .overlay { inside }
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

/// VisionKit's scanner, QR codes only.
private struct QRScanner: UIViewControllerRepresentable {
    let paused: Bool
    let onCode: (String) -> Void
    /// The camera went away mid-session; a frozen square would say nothing.
    let onUnavailable: (DataScannerViewController.ScanningUnavailable) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        if paused {
            scanner.stopScanning()
        } else if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: QRScanner
        /// The code last handed over, ignored until it leaves the frame. The
        /// camera restarts when the alert it raised closes, and a code still
        /// in view would otherwise raise it again the moment Cancel is tapped.
        private var answered: String?

        init(parent: QRScanner) { self.parent = parent }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case let .barcode(code) in addedItems {
                guard let payload = code.payloadStringValue, payload != answered else { continue }
                answered = payload
                parent.onCode(payload)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            // Not while paused: stopping may drop what is tracked, while the
            // code is most likely still in front of the camera.
            guard !parent.paused else { return }
            let inView = allItems.contains {
                if case let .barcode(code) = $0 { return code.payloadStringValue == answered }
                return false
            }
            if !inView { answered = nil }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            parent.onUnavailable(error)
        }
    }
}
