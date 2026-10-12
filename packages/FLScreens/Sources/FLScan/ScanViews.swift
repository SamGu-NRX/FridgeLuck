// FLScan — the SwiftUI flow.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
//
// Craft rules this file encodes (the scan-review mock + the binding
// constraints):
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius, photo geometry through PhotoLayoutRule —
//   the screen contains no visual value of its own.
// - Density: scan review and the capture chrome are dense surfaces
//   (`Density.dense` — the token doc names scan review dense).
// - The dock is the review's only extra surface, drawn as a native
//   `safeAreaInset` bar on the token background (Part 3's adaptation of
//   the mock's glass platter); no hand-rolled floating chrome.
// - The camera preview is the host's: this layer never constructs a
//   capture pipeline. On iOS it accepts the host's `AVCaptureSession`-
//   backed preview through `FLCameraPreview`; elsewhere the capture
//   surface shows the placeholder and the shutter still routes through
//   the host.
// - The mock's swipe-to-remove is adapted to a context menu on the row
//   (Part 3's adaptation of gesture affordances); nothing is removed
//   without an explicit named action.
// - No number-to-weigh is rendered anywhere; the header count and
//   the dock count are the only numbers besides quantities.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

#if os(iOS) && canImport(AVFoundation)
import AVFoundation

/// The camera preview, behind the same canImport guard pattern as the
/// rest of the package. The HOST owns the `AVCaptureSession` and its
/// lifecycle — services arrive through seams; this layer invents none.
/// Never compiled on Linux; never rendered by this package's checks.
public struct FLCameraPreview: UIViewControllerRepresentable {

    /// The host's session. The host starts and stops it; the view only
    /// displays its output layer.
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = controller.view.bounds
        controller.view.layer.addSublayer(previewLayer)
        controller.view.backgroundColor = .clear
        return controller
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {
        if let previewLayer = controller.view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = controller.view.bounds
        }
    }
}
#endif

/// The Scan destination — the capture-and-review grocery flow. The host
/// wires it into the existing shell's search-role tab slot; Tonight's and
/// Kitchen's prominent scan actions navigate here. `capturePreview` is
/// the host-supplied camera preview (iOS only); nil falls back to the
/// placeholder surface with the shutter still host-routed.
public struct ScanView: View {

    @Binding var state: ScanViewState
    let onIntent: (ScanIntent) -> Void
    /// Host-supplied camera preview, built around the host's session.
    let capturePreview: AnyView?

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: Binding<ScanViewState>,
        onIntent: @escaping (ScanIntent) -> Void,
        capturePreview: AnyView? = nil
    ) {
        _state = state
        self.onIntent = onIntent
        self.capturePreview = capturePreview
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            switch state.stage {
            case .idle:
                IdleLanding(state: state, onIntent: onIntent)
            case .capturing:
                CaptureSurface(state: state, onIntent: onIntent, capturePreview: capturePreview)
            case .recognizing:
                AnalysingSurface(state: state, onIntent: onIntent)
            case .reviewing, .saving, .committed:
                ReviewSurface(state: state, onIntent: onIntent)
            }
        }
        .animation(reduceMotion ? nil : .fl(.fade), value: state.stage)
        .accessibilityIdentifier("fl.scan.screen")
    }
}

// MARK: - Idle landing

/// The flow's landing: what this is, and the two doors — the camera or
/// manual entry. Manual entry is first-class, never a failure state.
private struct IdleLanding: View {
    let state: ScanViewState
    let onIntent: (ScanIntent) -> Void

    @Environment(\.flScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
            Text("Scan")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.scan.title")

            Text("Point at a shelf of groceries and I'll read it. Add by hand any time — both count the same.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .accessibilityIdentifier("fl.scan.idleCaption")

            Spacer()

            FLButton(.primary, "Start scanning", haptic: .lightConfirm) {
                onIntent(.startCapture)
            }
            .accessibilityIdentifier("fl.scan.start")
            FLButton(.secondary, "Add by name") {
                onIntent(.openManualEntry)
            }
            .accessibilityIdentifier("fl.scan.addByName")
        }
        .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Capture

/// The capture surface. With a host preview it is a full-bleed camera
/// view with the shutter over it; without one (refusal, failure, or no
/// host pipeline) it is the escape — never an error dead end.
private struct CaptureSurface: View {
    let state: ScanViewState
    let onIntent: (ScanIntent) -> Void
    let capturePreview: AnyView?

    @Environment(\.flScheme) private var scheme

    var body: some View {
        ZStack {
            if let failure = state.cameraFailure {
                refusedSurface(failure)
            } else {
                liveSurface
            }
        }
        .accessibilityIdentifier("fl.scan.capture")
    }

    @ViewBuilder
    private var liveSurface: some View {
        ZStack {
            // The host's preview, or the placeholder for it. The photo
            // surface is a placeholder here — the analysing screen's
            // framed photo obeys PhotoLayoutRule; the live view is
            // full-bleed chrome, not a photo area.
            (capturePreview ?? AnyView(
                Rectangle()
                    .fill(Theme.swiftColor(.pillGone, in: scheme))
                    .ignoresSafeArea()
            ))
            .ignoresSafeArea()
            .accessibilityIdentifier("fl.scan.preview")

            VStack {
                if let issue = state.captureIssue {
                    // Detected before upload, over the photo — never an
                    // alert.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.captureIssueDisplay ?? "")
                            .flType(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            .accessibilityIdentifier("fl.scan.qualityIssue")
                        FLButton(.secondary, "Retake") {
                            onIntent(.retake)
                        }
                        .accessibilityIdentifier("fl.scan.retake")
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                            .fill(Theme.swiftColor(.bg, in: scheme))
                    )
                    .padding(CGFloat(Density.dense.sideMargin))
                    .accessibilityElement(children: .contain)
                }
                Spacer()
                shutter
                    .padding(.bottom, 24)
            }
        }
    }

    private var shutter: some View {
        Button {
            onIntent(.shutter)
        } label: {
            Circle()
                .stroke(Theme.swiftColor(.ink, in: scheme), lineWidth: 3)
                .background(Circle().fill(Theme.swiftColor(.ink, in: scheme)).padding(4))
                .frame(width: 72, height: 72)
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Take photo")
        .accessibilityIdentifier("fl.scan.shutter")
    }

    private func refusedSurface(_ failure: ScanViewState.CameraFailure) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
            Text(state.cameraFailureDisplay ?? "")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.scan.cameraRefused")
            Spacer()
            FLButton(.primary, "Add by hand") {
                onIntent(.openManualEntry)
            }
            .accessibilityIdentifier("fl.scan.addByHand")
            FLButton(.secondary, "Close") {
                onIntent(.closeCapture)
            }
            .accessibilityIdentifier("fl.scan.captureClose")
        }
        .padding(.horizontal, CGFloat(Density.dense.sideMargin))
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Analysing

/// The mock's analysing state: the photo framed at the top, "Looking",
/// and rows appearing as recognised — no scanning laser, no shimmer.
private struct AnalysingSurface: View {
    let state: ScanViewState
    let onIntent: (ScanIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
                photoArea
                Text("Looking")
                    .flType(.screenTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.scan.analysingTitle")
                // One indeterminate line under the title. Under reduce
                // motion it is a still hairline.
                Rectangle()
                    .fill(Theme.swiftColor(.rule2, in: scheme))
                    .frame(height: 2)
                    .opacity(reduceMotion ? 1 : 0.6)
                    .accessibilityIdentifier("fl.scan.progressLine")
                arrivalList
            }
            .padding(.horizontal, CGFloat(Density.dense.sideMargin))
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("fl.scan.analysing")
    }

    /// 3:2, capped at 40% of the available height — the round decision
    /// supersedes the mock's 4:5 analysing frame.
    @ViewBuilder
    private var photoArea: some View {
        GeometryReader { geo in
            let height = PhotoLayoutRule.height(
                forWidth: Double(geo.size.width),
                availableHeight: Double(geo.size.height)
            )
            photoPlaceholder
                .frame(height: CGFloat(height), alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(height: CGFloat(PhotoLayoutRule.height(
            forWidth: 300,
            availableHeight: 852 * PhotoLayoutRule.maxHeightFraction
        )))
        .accessibilityIdentifier("fl.scan.analysingPhoto")
    }

    private var photoPlaceholder: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.pillGone, in: scheme))
            if let caption = state.photoCaption {
                Text(caption)
                    .flTracking(.evidence)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .padding(12)
            }
        }
    }

    @ViewBuilder
    private var arrivalList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.sureItems) { item in
                FLQuantityRow(name: item.name, quantity: item.quantityDisplay, state: .have)
                    .accessibilityIdentifier("fl.scan.item.\(item.id)")
            }
            ForEach(state.uncertainItems) { item in
                FLHairlineRow {
                    Text(item.observedLine)
                        .flType(.secondary)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                }
                .accessibilityIdentifier("fl.scan.uncertain.\(item.id)")
            }
        }
        .animation(reduceMotion ? nil : .fl(.fade), value: state.sureItems)
    }
}

// MARK: - Review

/// The review screen: "Needs you" first and alone, then "Looks right" as
/// a skim list, the plate offer when the run saw a meal, and the dock.
private struct ReviewSurface: View {
    let state: ScanViewState
    let onIntent: (ScanIntent) -> Void

    @Environment(\.flScheme) private var scheme

    var body: some View {
        reviewList
            .safeAreaInset(edge: .bottom) { dock }
    }

    private var reviewList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
                header
                if state.recognitionProblem != nil {
                    problemSection
                } else {
                    if state.showsPlateOffer {
                        plateOffer
                    }
                    if !state.uncertainItems.isEmpty {
                        needsYouSection
                    }
                    if !state.sureItems.isEmpty {
                        looksRightSection
                    }
                    addRow
                }
            }
            .padding(.horizontal, CGFloat(Density.dense.sideMargin))
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("fl.scan.review")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.titleDisplay)
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.scan.title")
            Spacer()
            if let count = state.headerCountDisplay {
                Text(count)
                    .flTracking(.evidence)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.scan.count")
            }
        }
        .accessibilityElement(children: .contain)
        // "All look right." rides the header as its subtitle.
        .accessibilityHint(state.subtitleDisplay ?? "")
    }

    // MARK: Needs you

    private var needsYouSection: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.dense.sectionGap ?? 24) / 2) {
            HStack(alignment: .firstTextBaseline) {
                FLSectionLabel("Needs you")
                    .accessibilityIdentifier("fl.scan.needsYouLabel")
                Spacer()
                Text("\(state.needsALookCount)")
                    .flTracking(.evidence)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.scan.needsYouCount")
            }
            ForEach(state.uncertainItems) { item in
                uncertainRow(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.scan.needsYou")
    }

    private func uncertainRow(_ item: ScanViewState.UncertainItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: CGFloat(Density.dense.rowInner ?? 12)) {
                thumb(for: item)
                Text(item.observedLine)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.scan.uncertainLine.\(item.id)")
            }
            HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                    FLChip(option) {
                        onIntent(.answerUncertain(itemID: item.id, name: option))
                    }
                    .accessibilityIdentifier("fl.scan.uncertainOption.\(item.id).\(index)")
                }
                FLChip("Neither", isSelected: false) {
                    onIntent(.rejectUncertain(itemID: item.id))
                }
                .accessibilityIdentifier("fl.scan.uncertainNeither.\(item.id)")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.scan.uncertain.\(item.id)")
    }

    /// The 48 pt identity crop the mock shows on each "needs you" row —
    /// placeholder ground until the host supplies crops; an identity
    /// thumb, not a photo area (the 3:2 rule governs photo areas).
    private func thumb(for item: ScanViewState.UncertainItem) -> some View {
        RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
            .fill(Theme.swiftColor(.pillGone, in: scheme))
            .frame(width: 48, height: 48)
            .overlay(alignment: .bottomLeading) {
                if let caption = item.thumbCaption {
                    Text(caption)
                        .flType(.evidence)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        .lineLimit(1)
                }
            }
            .accessibilityHidden(true)
    }

    // MARK: Looks right

    private var looksRightSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                FLSectionLabel("Looks right")
                    .accessibilityIdentifier("fl.scan.looksRightLabel")
                Spacer()
                Text("\(state.sureCount)")
                    .flTracking(.evidence)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.scan.looksRightCount")
            }
            ForEach(state.sureItems) { item in
                sureRow(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.scan.looksRight")
    }

    private func sureRow(_ item: ScanViewState.RecognizedItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FLQuantityRow(
                name: item.name,
                quantity: item.isExisting
                    ? (item.dedup == .boughtMore ? item.quantityDisplay : (item.existingQuantityDisplay ?? "?"))
                    : item.quantityDisplay,
                state: .have
            )
            .contextMenu {
                Button("Remove from this scan") {
                    onIntent(.removeItem(itemID: item.id))
                }
            }
            .accessibilityIdentifier("fl.scan.item.\(item.id)")
            .accessibilityValue(item.quantityDisplay)

            if let line = item.receiptLine {
                Text(line)
                    .flTracking(.evidence)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .accessibilityIdentifier("fl.scan.receiptLine.\(item.id)")
            }

            if item.isExisting {
                // The observe-versus-purchase reconciliation: a scan
                // observes, it never adds on its own.
                VStack(alignment: .leading, spacing: 4) {
                    Text("In your kitchen already — a scan never adds")
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .accessibilityIdentifier("fl.scan.duplicateNote.\(item.id)")
                    HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                        FLChip("Still \(item.existingQuantityDisplay ?? "?")", isSelected: item.dedup == .stillThere) {
                            onIntent(.answerDuplicate(itemID: item.id, stillThere: true))
                        }
                        .accessibilityIdentifier("fl.scan.duplicateStill.\(item.id)")
                        FLChip("Bought more", isSelected: item.dedup == .boughtMore) {
                            onIntent(.answerDuplicate(itemID: item.id, stillThere: false))
                        }
                        .accessibilityIdentifier("fl.scan.duplicateBoughtMore.\(item.id)")
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Offers, problems, the add row

    @ViewBuilder
    private var plateOffer: some View {
        HStack(spacing: CGFloat(Density.dense.rowInner ?? 12)) {
            Text("This looks like a meal. Log it instead?")
                .flType(.secondary)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.scan.plateOffer")
            FLChip("Yes") {
                onIntent(.logMeal)
                onIntent(.answerPlateSwitch(logMeal: true))
            }
            .accessibilityIdentifier("fl.scan.plateYes")
            FLChip("No") {
                onIntent(.answerPlateSwitch(logMeal: false))
            }
            .accessibilityIdentifier("fl.scan.plateNo")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.yolkSoft, in: scheme))
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var problemSection: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap) / 2) {
            // The photo stays over the problem — retry keeps it.
            ZStack {
                RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                    .fill(Theme.swiftColor(.pillGone, in: scheme))
                    .frame(height: CGFloat(PhotoLayoutRule.height(
                        forWidth: 300,
                        availableHeight: 852 * PhotoLayoutRule.maxHeightFraction
                    )))
                if let caption = state.photoCaption {
                    Text(caption)
                        .flType(.evidence)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        .padding(12)
                }
            }
            .accessibilityIdentifier("fl.scan.problemPhoto")

            Text(state.problemDisplay ?? "")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.scan.problem")

            // Retry keeps the photo; no re-capture required. The
            // nothing-recognised state's doors are Retake and Add by name.
            if state.recognitionProblem == .requestFailed {
                FLButton(.primary, "Try again") {
                    onIntent(.retryRecognition)
                }
                .accessibilityIdentifier("fl.scan.retry")
            }
            FLButton(.secondary, "Retake") {
                onIntent(.retake)
            }
            .accessibilityIdentifier("fl.scan.retake")
            FLButton(.text, "Add by name") {
                onIntent(.addByName)
            }
            .accessibilityIdentifier("fl.scan.problemAddByName")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.scan.problemSection")
    }

    private var addRow: some View {
        FLHairlineRow(action: { onIntent(.addByName) }) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                Text("Missed something? Add by name")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            }
        }
        .accessibilityIdentifier("fl.scan.addByNameRow")
    }

    // MARK: The dock

    private var dock: some View {
        VStack(spacing: 8) {
            if state.commitFailed {
                Text("Couldn't save. Nothing changed — try again.")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.error, in: scheme))
                    .accessibilityIdentifier("fl.scan.commitError")
            }
            FLButton(
                .primary,
                state.stage == .saving ? "Adding…" : state.commitButtonTitle,
                haptic: state.stage == .saving ? nil : .mediumCommit
            ) {
                onIntent(.confirmCommit)
            }
            .accessibilityIdentifier("fl.scan.confirm")
            Text(state.commitCaption)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("fl.scan.confirmCaption")
            if state.stage == .committed {
                Text("Added to your kitchen.")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.scan.committed")
            }
        }
        .padding(.horizontal, CGFloat(Density.dense.sideMargin))
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(Theme.swiftColor(.bg, in: scheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.scan.dock")
    }
}
#endif
