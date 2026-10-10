# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api

describe "Formats enregistrés et correspondances (D-IMP-005, D-IMP-006)" do
  it "enregistre un format CSV et contrôle ses réglages" do
    S.setup
    format = S.misc_format
    format.columns.should eq(%w[date ledger group receipt account line_label amount side])
    format.column_of("amount").should eq(7)
    Api.formats(S.reader).map(&.name).should eq(["Opérations diverses"])
    bad = Api::FormatInput.new(name: "opérations diverses", ledger_kind: "misc", columns: %w[date account amount],
      decimal_separator: "comma", thousands_separator: "comma", skip_lines: 99)
    Api.create_format(S.accountant, bad).errors.map(&.key).should eq([
      "import.errors.format.name.taken", "import.errors.format.thousands_separator.same",
      "import.errors.format.skip_lines.range", "import.errors.format.columns.missing",
    ])
    wrong_ledger = Api::FormatInput.new(name: "Banque", ledger_kind: "financial", columns: %w[date account amount],
      ledger_id: S.ledger("A01").id)
    Api.create_format(S.accountant, wrong_ledger).errors.map(&.key).should eq(["import.errors.ledger.kind"])
    expect_raises(Partiduo::Api::Forbidden) { Api.create_format(S.importer, bad) }
    updated = Api.update_format(S.accountant, format.id, Api::FormatInput.new(name: "OD", ledger_kind: "misc",
      columns: ["date", "", "account", "debit", "credit", "", ""])).value!
    updated.columns.should eq(["date", "", "account", "debit", "credit"])
    Api.delete_format(S.accountant, format.id).success?.should be_true
  end

  it "découpe un fichier d'exemple pour régler les colonnes" do
    S.setup
    sample = Api.sample(S.reader, S.fixture("od.csv"), "semicolon", "double", "utf-8")
    sample.first.should eq(%w[Date Journal Groupe Pièce Compte Libellé Montant Sens])
    Api.sample(S.reader, S.fixture("od.csv"), "colon", "double", "utf-8").should be_empty
  end

  it "enregistre les correspondances vers un journal, un taux, un compte ou une fiche existants" do
    S.setup
    S.card("SUPPLIER", "Fournitures du Centre", "FOURN1")
    ledger = S.mapping("ledger", "AC", "ledger", "a01")
    ledger.target.should eq("A01")
    ledger.target_label.should_not be_nil
    S.mapping("vat", "T20", "vat", "NOR").target_label.should_not be_nil
    S.mapping("code", "401DUPONT", "card", "fourn1").target.should eq("FOURN1")
    S.mapping("code", "6xx", "account", "627").target_label.should eq("Services bancaires et assimilés")
    errors = ->(input : Api::MappingInput) { Api.create_mapping(S.accountant, input).errors.map(&.key) }
    errors.call(Api::MappingInput.new("vat", "t20", "vat", "INT")).should eq(["import.errors.mapping.source.taken"])
    errors.call(Api::MappingInput.new("vat", "T10", "account", "627")).should eq(["import.errors.choice.invalid"])
    errors.call(Api::MappingInput.new("code", "X", "account", "999999")).should eq(["import.errors.mapping.target.unknown"])
    errors.call(Api::MappingInput.new("ledger", "", "ledger", "")).should eq(["import.errors.mapping.source.blank",
                                                                              "import.errors.mapping.target.blank"])
    Api.mappings(S.reader, "code").map(&.source).should eq(["401DUPONT", "6xx"])
    id = Api.mappings(S.reader, "vat").first.id
    Api.update_mapping(S.accountant, id, Api::MappingInput.new("vat", "T20", "vat", "INT")).value!.target.should eq("INT")
    Api.delete_mapping(S.accountant, id).success?.should be_true
  end
end
