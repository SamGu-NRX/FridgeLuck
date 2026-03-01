struct SQLTableAlterationGenerator {
  private enum TableAlterationKind {
    case addColumn(SQLColumnGenerator)
    case addIndex(SQLIndexGenerator)
    case renameColumn(old: String, new: String)
    case dropColumn(String)
  }

  private var name: String
  private var alterations: [TableAlterationKind] = []

  func sql(_ db: Database) throws -> String {
    var statements: [String] = []

    for alteration in alterations {
      switch alteration {
      case .addColumn(let column):
        var chunks: [String] = []
        chunks.append("ALTER TABLE")
        chunks.append(name.quotedDatabaseIdentifier)
        chunks.append("ADD COLUMN")
        let sql = try column.sql(
          db, tableName: name,
          primaryKeyColumns: {
            try db.primaryKey(name).columnInfos.map { columnInfos in
              columnInfos.map { SQLColumnDescriptor($0) }
            }
          })
        chunks.append(sql)
        let statement = chunks.joined(separator: " ")
        statements.append(statement)

      case .addIndex(let index):
        try statements.append(index.sql(db))

      case .renameColumn(let oldName, let newName):
        var chunks: [String] = []
        chunks.append("ALTER TABLE")
        chunks.append(name.quotedDatabaseIdentifier)
        chunks.append("RENAME COLUMN")
        chunks.append(oldName.quotedDatabaseIdentifier)
        chunks.append("TO")
        chunks.append(newName.quotedDatabaseIdentifier)
        let statement = chunks.joined(separator: " ")
        statements.append(statement)

      case .dropColumn(let column):
        var chunks: [String] = []
        chunks.append("ALTER TABLE")
        chunks.append(name.quotedDatabaseIdentifier)
        chunks.append("DROP COLUMN")
        chunks.append(column.quotedDatabaseIdentifier)
        let statement = chunks.joined(separator: " ")
        statements.append(statement)
      }
    }

    return statements.joined(separator: "; ")
  }
}

extension SQLTableAlterationGenerator {
  init(_ tableAlteration: TableAlteration) {
    self.name = tableAlteration.name
    self.alterations = []

    for alteration in tableAlteration.alterations {
      switch alteration {
      case .add(let column):
        alterations.append(.addColumn(.columnDefinition(column)))
        if let indexDefinition = column.indexDefinition(in: name) {
          alterations.append(.addIndex(SQLIndexGenerator(index: indexDefinition)))
        }

      case .addColumnLiteral(let sql):
        alterations.append(.addColumn(.columnLiteral(sql)))

      case .rename(old: let oldName, new: let newName):
        alterations.append(.renameColumn(old: oldName, new: newName))

      case .drop(let column):
        alterations.append(.dropColumn(column))
      }
    }
  }
}
