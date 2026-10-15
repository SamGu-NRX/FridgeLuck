import GRDB

/// Community subsystem migrations. Every migration registered here uses the `community_`
/// identifier prefix so the shared `grdb_migrations` table attributes it to this subsystem.
/// These run after all core `vN_` migrations and after every subsystem before this one, so a
/// migration may reference core tables and tables created by earlier subsystem migrations.
enum CommunityMigrations {
  /// Registers this subsystem's migrations in order. Each schema change adds one
  /// `migrator.registerMigration("community_<name>")` call here; identifiers are applied
  /// once and must never be renamed or reordered after they ship.
  static func register(in migrator: inout DatabaseMigrator) {}
}
