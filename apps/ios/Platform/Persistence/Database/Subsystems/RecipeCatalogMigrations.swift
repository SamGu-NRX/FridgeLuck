import GRDB

/// Recipe catalog subsystem migrations. Every migration registered here uses the `recipes_`
/// identifier prefix so the shared `grdb_migrations` table attributes it to this subsystem.
/// These run after all core `vN_` migrations and after every subsystem before this one, so a
/// migration may reference core tables and tables created by earlier subsystem migrations.
enum RecipeCatalogMigrations {
  /// Registers this subsystem's migrations in order. Each schema change adds one
  /// `migrator.registerMigration("recipes_<name>")` call here; identifiers are applied once
  /// and must never be renamed or reordered after they ship.
  static func register(in migrator: inout DatabaseMigrator) {}
}
