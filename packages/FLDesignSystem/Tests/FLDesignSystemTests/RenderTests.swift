// FLDesignSystem render tests.
//
// Dual-platform by construction, because they run in two places:
//
// - iOS simulator, inside the FridgeLuckTests target that the existing
//   `.github/workflows/ios-ci.yml` already runs on macos-26 (hooked via the
//   project.yml.hook.md diff at the repo root of this delivery). Every state
//   renders and is asserted non-empty there.
// - macOS (`swift test` from a checkout, or the staged
//   `ci/pending-workflows/design-system-renders.yml`): the same matrix, plus
//   NSImage-based contact-sheet assembly, writing 2x PNGs into FL_RENDERS_DIR
//   (created when missing; tmp fallback).
//
// On Linux the whole file is inactive (`canImport(UIKit)` is false there), so
// the test suite is empty and passes — which is what lets the Ubuntu job
// verify the token package.
//
// These are render/evidence tests, not pixel-golden tests: they verify each
// component renders without crashing in each state and produce reviewable
// PNGs. Visual judgement happens on the contact sheets.
#if canImport(UIKit) || canImport(AppKit)
import XCTest
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
@testable import FLDesignSystem
import FLDesignTokens

// ImageRenderer and the components are MainActor-isolated, so every render
// runs on the main actor — same shape as HitRegionTests.
@MainActor
final class RenderTests: XCTestCase {

    // MARK: Output plumbing

    /// Destination directory: FL_RENDERS_DIR when set (macOS / CI), otherwise
    /// a tmp dir. Created when missing. Writable on iOS simulators too.
    private var rendersDir: URL {
        let env = ProcessInfo.processInfo.environment["FL_RENDERS_DIR"]
        let url: URL
        if let env, !env.isEmpty {
            url = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("FLDesignSystemRenders", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Platform renderer → PNG data: ImageRenderer.uiImage on iOS,
    /// ImageRenderer.nsImage (via TIFF rep) on macOS.
    private func pngData<Content: View>(from renderer: ImageRenderer<Content>, name: String) throws -> Data {
        #if canImport(AppKit)
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no NSImage for \(name)")
        let tiff = try XCTUnwrap(image.tiffRepresentation, "no TIFF for \(name)")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff), "no bitmap rep for \(name)")
        return try XCTUnwrap(
            rep.representation(using: .png, properties: [:]),
            "no PNG data for \(name)"
        )
        #elseif canImport(UIKit)
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer produced no UIImage for \(name)")
        return try XCTUnwrap(image.pngData(), "no PNG data for \(name)")
        #endif
    }

    private func renderPNG(_ name: String, size: CGSize, _ view: some View) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let png = try pngData(from: renderer, name: name)
        let url = rendersDir.appendingPathComponent("fl-\(name).png")
        try png.write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing render \(url.lastPathComponent)")
        try assertRendersContent(png, name: name)
    }

    /// Decodes PNG data and counts distinct pixel colours. A blank render
    /// is exactly one flat colour; anything drawn adds antialiasing or a
    /// second tone, so the content guard asks for at least two.
    private func distinctPixelValues(in png: Data, name: String) throws -> Int {
        #if canImport(AppKit)
        let nsImage = try XCTUnwrap(NSImage(data: png), "undecodable PNG for \(name)")
        let cgImage = try XCTUnwrap(nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil), "no CGImage for \(name)")
        #elseif canImport(UIKit)
        let uiImage = try XCTUnwrap(UIImage(data: png), "undecodable PNG for \(name)")
        let cgImage = try XCTUnwrap(uiImage.cgImage, "no CGImage for \(name)")
        #endif
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            "no bitmap context for \(name)"
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Set(pixels).count
    }

    private func assertRendersContent(_ png: Data, name: String) throws {
        let distinct = try distinctPixelValues(in: png, name: name)
        XCTAssertGreaterThanOrEqual(
            distinct, 2,
            "blank render for \(name): \(distinct) distinct pixel colour; a drawn component has at least two"
        )
    }

    // MARK: Surfaces

    private func paper(_ view: some View) -> some View {
        view
            .flScheme(.paper)
            .background(Theme.swiftColor(.bg, in: .paper))
    }

    private func hob(_ view: some View) -> some View {
        view
            .flScheme(.hob)
            .background(Theme.swiftColor(.bg, in: .hob))
    }

    private func dark(_ view: some View) -> some View {
        view
            .flScheme(.dark)
            .background(Theme.swiftColor(.bg, in: .dark))
    }

    private func xxl(_ view: some View) -> some View {
        view.environment(\.dynamicTypeSize, .accessibility5)
    }

    /// A flat 1:1 placeholder photo (no assets, no network).
    private func flatPhoto(red: CGFloat, green: CGFloat, blue: CGFloat) -> Image {
        let side = 400
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let cg = ctx.makeImage()!
        #if canImport(AppKit)
        return Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: side, height: side)))
        #elseif canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cg))
        #endif
    }

    // MARK: Fixtures (synthetic copy — no real user data)

    private func fitMeter() -> FLFitMeter { FLFitMeter(have: 9, total: 10, swaps: 1) }
    private func quantityRow(_ state: FLQuantityState) -> FLQuantityRow {
        FLQuantityRow(name: "Fusilli 500 g", quantity: "200 g", state: state)
    }
    private func timerTile(paused: Bool = false) -> FLTimerTile {
        FLTimerTile(label: "Simmer", remaining: 487, total: 600, paused: paused)
    }
    private func cookCard(photo: Image?, note: String?) -> FLCookCard {
        FLCookCard(
            name: "Fusilli al limone",
            who: "Sam",
            when: "last Tuesday",
            note: note,
            photo: photo,
            fitHave: 9,
            fitTotal: 10,
            fitSwaps: 1,
            buttonTitle: "Cook this"
        ) {}
    }
    private func tasteSentence(rejected: Bool) -> FLTasteSentence {
        FLTasteSentence(
            sentence: "Less lemon, more zest next time.",
            evidenceCount: 3,
            initiallyRejected: rejected
        ) {} onWrong: {} onUndo: {}
    }

    // MARK: The render matrix

    private func renderAll() throws {
        // Fit meter: paper, hob, dark, XXL.
        try renderPNG("fit-meter-paper", size: CGSize(width: 320, height: 80), paper(fitMeter()))
        try renderPNG("fit-meter-hob", size: CGSize(width: 320, height: 80), hob(fitMeter()))
        try renderPNG("fit-meter-dark", size: CGSize(width: 320, height: 80), dark(fitMeter()))
        try renderPNG("fit-meter-xxl", size: CGSize(width: 360, height: 120), xxl(paper(fitMeter())))

        // Quantity rows: the seven stock states + XXL.
        try renderPNG("quantity-row-have", size: CGSize(width: 360, height: 56), paper(quantityRow(.have)))
        try renderPNG("quantity-row-short", size: CGSize(width: 360, height: 56), paper(quantityRow(.short)))
        try renderPNG("quantity-row-missing", size: CGSize(width: 360, height: 56), paper(quantityRow(.missing)))
        try renderPNG("quantity-row-unconfirmed", size: CGSize(width: 360, height: 56), paper(quantityRow(.unconfirmed)))
        try renderPNG("quantity-row-unknown-quantity", size: CGSize(width: 360, height: 56), paper(quantityRow(.quantityUnknown)))
        try renderPNG("quantity-row-assumed", size: CGSize(width: 360, height: 56), paper(quantityRow(.assumed)))
        try renderPNG("quantity-row-stale", size: CGSize(width: 360, height: 56), paper(quantityRow(.stale)))
        try renderPNG("quantity-row-xxl", size: CGSize(width: 420, height: 96), xxl(paper(quantityRow(.unconfirmed))))

        // Timer tile: native hob, ambient paper (tile stays hob), paused, XXL.
        try renderPNG("timer-tile-hob", size: CGSize(width: 240, height: 240), hob(timerTile()))
        try renderPNG("timer-tile-on-paper", size: CGSize(width: 240, height: 240), paper(timerTile()))
        try renderPNG("timer-tile-paused", size: CGSize(width: 240, height: 240), hob(timerTile(paused: true)))
        try renderPNG("timer-tile-xxl", size: CGSize(width: 300, height: 300), xxl(hob(timerTile())))

        // Cook cards: with photo + note, without photo.
        try renderPNG(
            "cook-card-photo-note",
            size: CGSize(width: 360, height: 620),
            paper(cookCard(photo: flatPhoto(red: 0.85, green: 0.82, blue: 0.72), note: "Took 3 min less — pull it early."))
        )
        try renderPNG(
            "cook-card-no-photo",
            size: CGSize(width: 360, height: 400),
            paper(cookCard(photo: nil, note: nil))
        )
        try renderPNG(
            "cook-card-xxl",
            size: CGSize(width: 420, height: 760),
            xxl(paper(cookCard(photo: nil, note: "Took 3 min less.")))
        )

        // Taste sentence: open and corrected (Wrong) states.
        try renderPNG("taste-sentence-open", size: CGSize(width: 360, height: 150), paper(tasteSentence(rejected: false)))
        try renderPNG("taste-sentence-wrong", size: CGSize(width: 360, height: 150), paper(tasteSentence(rejected: true)))

        // Buttons: three kinds on paper; primary on hob.
        try renderPNG("button-primary-paper", size: CGSize(width: 320, height: 72), paper(FLButton(.primary, "Cook this", haptic: .mediumCommit) {}))
        try renderPNG("button-secondary-paper", size: CGSize(width: 320, height: 72), paper(FLButton(.secondary, "Something else") {}))
        try renderPNG("button-text-paper", size: CGSize(width: 320, height: 48), paper(FLButton(.text, "Undo") {}))
        try renderPNG("button-primary-hob", size: CGSize(width: 320, height: 72), hob(FLButton(.primary, "Cook this") {}))

        // Chips: selected / not.
        try renderPNG("chip-selected-paper", size: CGSize(width: 220, height: 52), paper(FLChip("In your kitchen", isSelected: true) {}))
        try renderPNG("chip-unselected-paper", size: CGSize(width: 220, height: 52), paper(FLChip("One swap", isSelected: false) {}))

        // Section label (sentence case, never uppercase) and hairline row.
        try renderPNG("section-label-paper", size: CGSize(width: 320, height: 44), paper(FLSectionLabel("In your kitchen")))
        try renderPNG(
            "hairline-row-paper",
            size: CGSize(width: 360, height: 68),
            paper(
                FLHairlineRow(haptic: .lightConfirm) {
                    Text("Fusilli al limone")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: .paper))
                }
            )
        )

        // Empty/loading line: sweeping, reduced motion (static), idle.
        try renderPNG("empty-loading-line-sweep", size: CGSize(width: 320, height: 16), paper(FLEmptyLoadingLine(isLoading: true)))
        try renderPNG(
            "empty-loading-line-reduced-motion",
            size: CGSize(width: 320, height: 16),
            paper(FLEmptyLoadingLine(isLoading: true).environment(\.flReduceMotion, true))
        )
        try renderPNG("empty-loading-line-idle", size: CGSize(width: 320, height: 16), paper(FLEmptyLoadingLine(isLoading: false)))
    }

    // MARK: Contact sheets (macOS-only assembly)

    #if canImport(AppKit)

    /// Assembles one contact sheet per component from the PNGs in
    /// FL_RENDERS_DIR: `contact-<component>.png` next to them. Runs after
    /// renderAll(); composes whatever exists, so it is safe to call after a
    /// partial matrix too.
    @discardableResult
    public func makeContactSheets() throws -> [URL] {
        let components = [
            "fit-meter", "quantity-row", "timer-tile", "cook-card",
            "taste-sentence", "button", "chip", "section-label",
            "hairline-row", "empty-loading-line",
        ]
        let all = try FileManager.default.contentsOfDirectory(
            at: rendersDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }

        var sheets: [URL] = []
        for component in components {
            // Sort by filename, then decode — NSImage.name is nil for
            // data-inited images, so it cannot order them.
            let urls = all
                .filter { $0.lastPathComponent.hasPrefix("fl-\(component)-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let images = urls.compactMap { url -> NSImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return NSImage(data: data)
            }
            if images.isEmpty { continue }
            sheets.append(try writeSheet(component: component, images: images))
        }
        return sheets
    }

    private func writeSheet(component: String, images: [NSImage]) throws -> URL {
        let cols = 2
        let cell = CGSize(width: 360, height: 320)
        let gap: CGFloat = 16
        let rows = (images.count + cols - 1) / cols
        let sheetSize = CGSize(
            width: CGFloat(cols) * cell.width + CGFloat(cols + 1) * gap,
            height: CGFloat(rows) * cell.height + CGFloat(rows + 1) * gap
        )

        let sheet = NSImage(size: sheetSize, flipped: false) { rect in
            // Paper ground as an NSColor (SwiftUI.Color has no setFill()).
            let ground = Theme.color(.bg, in: .paper)
            NSColor(srgbRed: ground.red, green: ground.green, blue: ground.blue, alpha: 1).setFill()
            rect.fill()
            for (index, image) in images.enumerated() {
                let col = CGFloat(index % cols)
                let row = CGFloat(index / cols)
                let origin = NSPoint(
                    x: gap + col * (cell.width + gap),
                    y: rect.height - gap - cell.height - row * (cell.height + gap)
                )
                image.draw(
                    in: NSRect(origin: origin, size: cell),
                    from: .zero,
                    operation: .sourceOver,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.medium]
                )
            }
            return true
        }

        let tiff = try XCTUnwrap(sheet.tiffRepresentation, "no TIFF for sheet \(component)")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff), "no rep for sheet \(component)")
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "no PNG for sheet \(component)")
        let url = rendersDir.appendingPathComponent("contact-\(component).png")
        try png.write(to: url)
        return url
    }
    #endif

    // MARK: Tests

    /// The full state matrix renders everywhere this suite compiles
    /// (iOS simulator in CI, macOS locally).
    func testRenderAllComponentsAndStates() throws {
        try renderAll()
        let files = try FileManager.default.contentsOfDirectory(at: rendersDir, includingPropertiesForKeys: nil)
        let pngs = files.filter { $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix("fl-") }
        XCTAssertGreaterThanOrEqual(pngs.count, 24, "expected the full render matrix, got \(pngs.count)")
    }

    /// Renders + contact sheets. Sheet assembly is macOS-only (NSImage); on
    /// iOS the matrix still renders above and the sheet step skips loudly.
    func testRenderAllThenContactSheets() throws {
        try renderAll()
        #if canImport(AppKit)
        let sheets = try makeContactSheets()
        XCTAssertGreaterThanOrEqual(sheets.count, 10, "one sheet per component")
        #else
        throw XCTSkip("Contact sheets assemble on macOS only; the render matrix still ran.")
        #endif
    }

    /// Teeth for the content guard: a deliberately blank view must FAIL
    /// the check. The expected-failure wrapper records the trip; if the
    /// guard ever stopped detecting blanks, this test fails instead.
    func testBlankRenderTripsTheContentCheck() throws {
        let blank = ImageRenderer(content: Color.white.frame(width: 32, height: 32))
        blank.scale = 2
        let png = try pngData(from: blank, name: "blank-control")
        let distinct = try distinctPixelValues(in: png, name: "blank-control")
        XCTAssertEqual(distinct, 1, "the blank control should be one flat colour")
        try XCTExpectFailure("the content check must reject the blank control") {
            try assertRendersContent(png, name: "blank-control")
        }
    }
}
#endif
