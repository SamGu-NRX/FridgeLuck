import SwiftUI

/// User-triggered, local-only diagnostic preview and export.
///
/// Privacy by construction: the summary is assembled only from the
/// allowlisted categories (app/toolchain/schema/capability/error-code).
/// There is no field that could carry raw food, profile, history, OCR,
/// photo, audio, token, or path payloads. Nothing is uploaded anywhere
/// and no support address is invented - sharing hands the text to the
/// user's own share sheet.
struct SupportDiagnosticsView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var exportText: String?
  @State private var buildFailed = false

  private static let forbidden = [
    "ocr", "token", "path", "photo", "audio", "label", "profile",
    "history", "ingredient", "transcript", "image",
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        Text(
          "A summary of versions, schemas, capabilities, and error codes. It contains no photos, ingredients, profile or history data - by construction."
        )
        .font(AppTheme.Typography.settingsDetail)
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.horizontal, AppTheme.Space.page)

        if let exportText {
          Text(exportText)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Space.md)
            .background(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.surfaceMuted)
            )
            .padding(.horizontal, AppTheme.Space.page)
            .accessibilityLabel("Diagnostic summary preview")

          ShareLink(item: exportText) {
            HStack(spacing: AppTheme.Space.xs) {
              Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
              Text("Share summary")
                .font(AppTheme.Typography.settingsBodySemibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Space.sm)
            .background(Capsule().fill(AppTheme.accent))
            .foregroundStyle(.white)
          }
          .padding(.horizontal, AppTheme.Space.page)
          .accessibilityHint("Opens your share sheet; nothing is uploaded by the app")

          FLSettingsFootnote(
            text: "The app never sends this anywhere on its own. You choose where it goes."
          )
          .padding(.horizontal, AppTheme.Space.page)
        } else if buildFailed {
          Text("The summary could not be built. Nothing was shared or saved.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, AppTheme.Space.page)
        }
      }
      .padding(.vertical, AppTheme.Space.md)
    }
    .scrollContentBackground(.hidden)
    .background(AppTheme.surfaceElevated)
    .navigationTitle("Diagnostic summary")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
          .accessibilityHint("Discards the preview; nothing was saved")
      }
    }
    .onAppear(perform: buildExport)
  }

  private func buildExport() {
    var lines: [String] = []
    lines.append("fl.support.export.v1")
    lines.append("-- app --")
    let info = Bundle.main.infoDictionary
    if let version = info?["CFBundleShortVersionString"] as? String {
      lines.append("appVersion: \(version)")
    }
    if let build = info?["CFBundleVersion"] as? String {
      lines.append("buildNumber: \(build)")
    }
    lines.append("platform: iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    lines.append("-- toolchain --")
    lines.append("swift-tools 6.0 / iOS 26.0")
    lines.append("-- schemas (names only) --")
    for name in ["notification-rules", "scan-run-store"].sorted() {
      lines.append("schema: \(name)")
    }
    lines.append("-- capabilities --")
    for name in ["appleHealth", "camera", "cloudAgent", "notifications", "photoLibrary"].sorted() {
      lines.append("capability: \(name)")
    }
    lines.append("-- error codes --")
    for code in ["fl.cloud.request", "fl.notifications.authorization", "fl.health.authorization", "fl.scan.capture", "fl.scan.classification", "fl.scan.ocr", "fl.store.save"].sorted() {
      lines.append("code: \(code)")
    }
    lines.append("-- end --")

    let text = lines.joined(separator: "\n")
    let lowered = text.lowercased()
    if text.contains("fl.support.export.v1"),
      Self.forbidden.allSatisfy({ !lowered.contains($0) }) {
      exportText = text
      buildFailed = false
    } else {
      exportText = nil
      buildFailed = true
    }
  }
}
