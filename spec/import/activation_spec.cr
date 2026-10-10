# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension IMPORT : manifeste et activation (ADR-003 D2)" do
  it "déclare une extension conforme au contrat du cœur, qui dépend de la Comptabilité, sans incompatibilité" do
    manifest = Partiduo::Modules[Import::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Import::VERSION)
    Import::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
    manifest.requires_core.should eq("~> 0.1")
    manifest.permissions.should eq(["import.read", "import.run", "import.admin"])
    manifest.depends_on.should eq(["ACCOUNTING"])
    manifest.incompatible_with.should be_empty
    manifest.subscribed_events.should eq(["entry.cancelled"])
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"IMPORT", nil, nil},
      {"IMPORT_RUN", "IMPORT", "import:import"},
      {"IMPORT_OPERATIONS", "IMPORT", "import:operations"},
      {"IMPORT_HISTORY", "IMPORT", "import:batches"},
      {"IMPORT_FORMATS", "SETTINGS", "import:formats"},
      {"IMPORT_MAPPINGS", "SETTINGS", "import:mappings"},
    ])
    Partiduo::Modules.structure_errors.should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Import::CODE, "ACCOUNTING"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Import::CODE}).should eq(["IMPORT requiert ACCOUNTING, inactif"])
  end

  it "traduit son nom, ses permissions et ses menus en fr, en et nl" do
    manifest = Partiduo::Modules[Import::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
    I18n.with_locale("fr") { I18n.t("import.menu.import").should eq("Import d'opérations") }
  end

  it "est inactive tant que l'instance ne l'active pas, puis se montre au menu" do
    PartiduoUi::Reference.provision
    S.user("alice@example.com", "Alice")
    S.user("bruno@example.com", "Bruno")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.formats(S.reader) }
    Api.tile(S.reader).should be_nil
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("import:operations")

    S.activate
    Partiduo::Modules.check!
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should contain("import:operations")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("import:import")
    menu_routes(Partiduo::Api::Modules.menu(S.accountant)).should contain("import:mappings")
  end

  it "range ses tables sous le préfixe import_ et refuse en base les valeurs hors domaine" do
    [Import::Format, Import::Mapping, Import::Batch, Import::Operation, Import::OperationLine].map(&.db_table)
      .should eq(%w[import_format import_mapping import_batch import_operation import_operation_line])
    S.setup
    sql_error = ->(sql : String) do
      Marten::DB::Connection.default.open(&.exec(sql))
      nil
  rescue ex : PQ::PQError
    ex.message
    end
    sql_error.call("INSERT INTO import_mapping (kind, source, target_type, target, note, created_at, updated_at) " \
                   "VALUES ('vat', 'T20', 'account', '627', '', now(), now())").to_s.should contain("import_mapping_target_check")
    S.mapping("vat", "T20", "vat", "NOR")
    sql_error.call("INSERT INTO import_mapping (kind, source, target_type, target, note, created_at, updated_at) " \
                   "VALUES ('vat', 't20', 'vat', 'INT', '', now(), now())").to_s.should contain("import_mapping_source_unique")
    format = S.misc_format
    sql_error.call("UPDATE import_format SET ledger_kind = 'stock' WHERE id = #{format.id}").to_s.should contain("import_format_kind_check")
    S.mapping("ledger", "OD", "ledger", "O01")
    batch = S.import("od.csv", format.id)
    sql_error.call("UPDATE import_operation SET status = 'transferred' WHERE batch_id = #{batch.id}")
      .to_s.should contain("import_operation_transferred_check")
    sql_error.call("UPDATE import_batch SET kind = 'ofx' WHERE id = #{batch.id}").to_s.should contain("import_batch_kind_check")
  end
end
