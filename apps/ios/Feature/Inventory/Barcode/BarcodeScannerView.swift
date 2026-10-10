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

  func makeUIViewController(context: Context) -> ScannerHostController {
    ScannerHostController(onScan: onScan)
  }

  func updateUIViewController(_ uiViewController: ScannerHostController, context: Context) {}

  /// `DataScannerViewController` is not `open`, so it can't be subclassed outside
  /// VisionKit — this host owns it as a child controller instead and the delegate
  /// observer (a plain NSObject) receives recognition callbacks.
  final class ScannerHostController: UIViewController {
    private let scanner: DataScannerViewController
    private let observer: ScanObserver

    init(onScan: @escaping (String) -> Void) {
      self.scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode()],
        qualityMode: .balanced,
        isHighlightingEnabled: true
      )
      self.observer = ScanObserver()
      super.init(nibName: nil, bundle: nil)
      observer.onScan = onScan
      scanner.delegate = observer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)

      if scanner.parent == nil {
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
      }

      do {
        try scanner.startScanning()
      } catch {
        Logger(subsystem: "samgu.FridgeLuck", category: "BarcodeScanner")
          .error("Scanner failed to start: \(error.localizedDescription)")
      }
    }

    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      scanner.stopScanning()
    }
  }

  /// Delegate observer — dedupes payloads so a barcode held steady in frame fires once.
  final class ScanObserver: NSObject, DataScannerViewControllerDelegate {
    var onScan: ((String) -> Void)?
    private var seenPayloads: Set<String> = []

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
}
