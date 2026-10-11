import SwiftUI
import UniformTypeIdentifiers

/// Local backup share, import, and preview, driven entirely by
/// `BackupRestoreEngine`. The view model builds its own engine against the
/// app's shared `DatabaseQueue` — it never touches `AppDatabase`'s
/// lifecycle, migrations, or any shared registrar.
struct SettingsBackupView: View {
  @EnvironmentObject private var deps: AppDependencies
  @State private var model: SettingsBackupModel?

  var body: some View {
    Form {
      exportSection
      restoreSection
    }
    .scrollContentBackground(.hidden)
    .flSettingsBottomClearance()
    .navigationTitle("Backup & Restore")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground(renderMode: .interactive)
    .onAppear {
      if model == nil {
        model = SettingsBackupModel(deps: deps)
      }
    }
    .fileImporter(
      isPresented: Binding(
        get: { model?.showingImporter ?? false },
        set: { model?.showingImporter = $0 }
      ),
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      if let url = try? result.get().first {
        model?.importArchive(from: url)
      }
    }
    .alert(
      "Backup problem",
      isPresented: Binding(
        get: { model?.errorMessage != nil },
        set: { if !$0 { model?.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model?.errorMessage ?? "")
    }
  }

  // MARK: - Export

  @ViewBuilder private var exportSection: some View {
    Section("Export backup") {
      FLSettingsFootnote(
        text:
          "Saves every profile, inventory, meal, and journal record to a single file. Bundled recipes and ingredients are included so a restore can replace them; photos are optional."
      )

      Toggle("Include meal photos", isOn: Binding(
        get: { model?.includePhotos ?? false },
        set: { model?.includePhotos = $0 }
      ))

      if let exportedURL = model?.exportedFileURL {
        ShareLink(item: exportedURL) {
          Label("Share backup file", systemImage: "square.and.arrow.up")
        }
      } else {
        Button {
          model?.exportArchive()
        } label: {
          if model?.isWorking == true {
            HStack {
              ProgressView()
              Text("Preparing backup…")
            }
          } else {
            Label("Create backup file", systemImage: "externaldrive.badge.icloud")
          }
        }
        .disabled(model?.isWorking == true)
      }
    }
  }

  // MARK: - Restore

  @ViewBuilder private var restoreSection: some View {
    Section("Restore from backup") {
      FLSettingsFootnote(
        text:
          "Restoring replaces ALL data in the app with the backup's contents. A safety copy of your current data is kept if anything goes wrong."
      )

      if let preview = model?.stagedPreview {
        RestorePreviewSection(preview: preview)
        FLSettingsDestructiveGroup(
          title: "Replace everything with this backup",
          message:
            "\(preview.totalUserRows) of your records and \(preview.totalBundledRows) bundled rows will replace what is in the app now. This cannot be partially undone.",
          actionTitle: "Restore backup"
        ) {
          model?.commitRestore()
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)

        Button("Discard preview", role: .cancel) {
          model?.discardPreview()
        }
      } else {
        Button {
          model?.showingImporter = true
        } label: {
          Label("Choose backup file…", systemImage: "square.and.arrow.down")
        }
        .disabled(model?.isWorking == true)
      }

      if let report = model?.completedReport {
        FLSettingsFootnote(
          text:
            "Restored \(report.restoredUserRows) of your records and \(report.restoredBundledRows) bundled rows.\(report.photosRestored > 0 ? " \(report.photosRestored) photos restored." : "")"
        )
      }
    }
  }
}

/// Read-only summary of what a staged archive would replace.
private struct RestorePreviewSection: View {
  let preview: RestorePreview

  var body: some View {
    Group {
      LabeledContent("Backup created", value: preview.createdAt)
      LabeledContent("Schema version", value: "v\(preview.schemaVersion)")
      if preview.includesPhotos {
        LabeledContent("Photos", value: "\(preview.photoCount)")
      }
      ForEach(preview.userRecordTables, id: \.name) { table in
        LabeledContent(table.name, value: "\(table.rowCount)")
      }
    }
  }
}

// MARK: - Model

@MainActor
@Observable
final class SettingsBackupModel {
  var includePhotos = false
  var isWorking = false
  var showingImporter = false
  var exportedFileURL: URL?
  var stagedPreview: RestorePreview?
  var completedReport: RestoreReport?
  var errorMessage: String?

  private let engine: BackupRestoreEngine

  init(deps: AppDependencies) {
    // Mirrors AppDatabase's path derivation read-only: the engine needs
    // the live SQLite path only to place its staging directory next to
    // the database. No lifecycle, migration, or registrar changes.
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first
    let databasePath = appSupport?.appendingPathComponent("fridgeluck.sqlite").path
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("fridgeluck.sqlite")
        .path
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

    engine = BackupRestoreEngine(
      writer: deps.appDatabase.dbQueue,
      databasePath: databasePath,
      documentsDirectory: documents
    )
  }

  // MARK: Export

  func exportArchive() {
    guard stagedPreview == nil else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let data = try await engine.exportArchive(
          includesPhotos: includePhotos, appVersion: appVersion)
        let stamp = Self.fileStamp()
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("FridgeLuck-backup-\(stamp).json")
        try data.write(to: url, options: .atomic)
        exportedFileURL = url
        AppPreferencesStore.haptic(.light)
      } catch {
        errorMessage = Self.describe(error)
      }
    }
  }

  // MARK: Import (stage + preview + commit)

  func importArchive(from url: URL) {
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let data: Data = try url.startAccessingSecurityScopedResource {
          try Data(contentsOf: url)
        }
        let preview = try await engine.stageRestore(archiveData: data)
        completedReport = nil
        stagedPreview = preview
        AppPreferencesStore.haptic(.light)
      } catch {
        stagedPreview = nil
        errorMessage = Self.describe(error)
      }
    }
  }

  func commitRestore() {
    guard let preview = stagedPreview else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let report = try await engine.commitRestore(preview)
        stagedPreview = nil
        completedReport = report
        AppPreferencesStore.notification(.success)
      } catch {
        // The engine rolled the transaction back and kept the safety
        // copy; live data is intact.
        errorMessage = Self.describe(error)
        AppPreferencesStore.notification(.warning)
      }
    }
  }

  func discardPreview() {
    stagedPreview = nil
  }

  // MARK: Helpers

  private static func fileStamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private static func describe(_ error: Error) -> String {
    if let validation = error as? BackupValidationError, !validation.violations.isEmpty {
      return validation.violations.prefix(3).map(\.detail).joined(separator: " ")
    }
    return String(describing: error)
  }
}

extension URL {
  /// Runs `body` while this URL's security scope is held, releasing it on
  /// scope exit.
  fileprivate func startAccessingSecurityScopedResource(
    _ body: () throws -> Data
  ) rethrows -> Data {
    let started = startAccessingSecurityScopedResource()
    defer { if started { stopAccessingSecurityScopedResource() } }
    return try body()
  }
}
