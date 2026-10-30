import AVFoundation
import SwiftUI
import UIKit
import VisionKit

/// The connect screen's camera, reading QR codes for the pairing link.
///
/// It only reports what it read. Whether a code is a pairing link, and asking
/// before connecting to one, is the app's, on the same path as a link opened
/// from outside, so a scanned code cannot connect without a tap either. Where
/// the camera can't run, one line says why instead.
struct PairingScanner: View {
    /// Stops the camera while an alert or a sheet is up over it.
    let paused: Bool
    let onCode: (String) -> Void

    /// Read once: changing the answer in Settings relaunches the app.
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    private enum Availability { case scanning, asking, off, unsupported }

    private var availability: Availability {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch access {
        case .authorized: return DataScannerViewController.isAvailable ? .scanning : .unsupported
        case .notDetermined: return .asking
        case .denied, .restricted: return .off
        @unknown default: return .unsupported
        }
    }

    var body: some View {
        switch availability {
        case .scanning:
            viewfinder(Scanner(paused: paused, onCode: onCode))
        case .asking:
            // The scanner calls itself unavailable until access is granted,
            // so the prompt is ours to raise.
            viewfinder(EmptyView())
                .task {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    access = AVCaptureDevice.authorizationStatus(for: .video)
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
private struct Scanner: UIViewControllerRepresentable {
    let paused: Bool
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.paused = paused
        if paused {
            scanner.stopScanning()
        } else if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var paused = false
        /// The code last handed over, ignored until it leaves the frame. The
        /// camera restarts when the alert it raised closes, and a code still
        /// in view would otherwise raise it again the moment Cancel is tapped.
        private var answered: String?

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case let .barcode(code) in addedItems {
                guard let payload = code.payloadStringValue, payload != answered else { continue }
                answered = payload
                onCode(payload)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            // Not while paused: stopping may drop what is tracked, while the
            // code is most likely still in front of the camera.
            guard !paused else { return }
            let inView = allItems.contains {
                if case let .barcode(code) = $0 { return code.payloadStringValue == answered }
                return false
            }
            if !inView { answered = nil }
        }
    }
}
