import SwiftUI
import VisionKit
import os

/// On-device barcode scanning via VisionKit `DataScannerViewController`. Availability is
/// guarded by `isSupported`/`isAvailable` — when either is false (no camera, simulator,
/// permission denied) the intake screen falls back to manual GTIN entry.
struct BarcodeScannerView: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  static func isScannerAvailable() -> Bool {
    DataScannerViewController.isSupported && DataScannerViewController.isAvailable
  }

  func makeUIViewController(context: Context) -> ScannerController {
    let controller = ScannerController()
    controller.onScan = onScan
    return controller
  }

  func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

  final class ScannerController: DataScannerViewController {
    var onScan: ((String) -> Void)?
    private var seenPayloads: Set<String> = []

    init() {
      super.init(
        recognizedDataTypes: [.barcode()],
        qualityMode: .balanced,
        isHighlightingEnabled: true
      )
      delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      do {
        try startScanning()
      } catch {
        Logger(subsystem: "samgu.FridgeLuck", category: "BarcodeScanner")
          .error("Scanner failed to start: \(error.localizedDescription)")
      }
    }

    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      stopScanning()
    }
  }
}

extension BarcodeScannerView.ScannerController: DataScannerViewControllerDelegate {
  func dataScanner(
    _ dataScanner: DataScannerViewController,
    didAdd addedItems: [RecognizedItem],
    allItems: [RecognizedItem]
  ) {
    for item in addedItems {
      guard case .barcode(let barcode) = item,
        let payload = barcode.payloadStringValue
      else { continue }
      let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, seenPayloads.insert(normalized).inserted else { continue }
      onScan?(normalized)
    }
  }
}
