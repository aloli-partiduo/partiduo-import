# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api
private alias Acc = Partiduo::Api::Accounting

describe "Import d'un FEC dans un dossier existant (D-IMP-011, D-IMP-012, D-IMP-015 à D-IMP-017)" do
  it "reconnaît le FEC, signale journaux, comptes et tiers inconnus, puis le passe une fois les correspondances faites" do
    S.setup
    S.card("CUSTOMER", "Client Un", "CLIENT1")
    Api.detect_kind(S.reader, S.fixture(S::FEC)).should eq("fec")
    batch = S.import(S::FEC)
    batch.kind.should eq("fec")
    batch.ledger_kind.should eq("")
    batch.encoding.should eq("iso-8859-15")
    attachment = Partiduo::Api::Core.attachment(S.accountant, present(batch.attachment_id))
    attachment.content_type.should eq("text/plain")
    S.operations(batch.id).map { |view| S.keys(view).uniq!.sort! }.should eq([
      ["import.errors.code.unknown", "import.errors.code.unknown_account", "import.errors.ledger.unknown"],
      ["import.errors.code.unknown", "import.errors.code.unknown_account", "import.errors.ledger.unknown"],
      ["import.errors.code.unknown_account", "import.errors.ledger.unknown"],
    ])
    unknown = Api.unknown_codes(S.accountant)
    unknown.map { |code| {code.kind, code.source} }.should eq([
      {"ledger", "BQ"}, {"ledger", "OD"}, {"ledger", "VT"}, {"code", "CLI01"},
      {"account", "445710"}, {"account", "512000"}, {"account", "6061"}, {"account", "706000"},
    ])
    unknown.find! { |code| code.source == "6061" }.label.should eq("Fournitures non stockables")

    S.fec_mappings
    Api.create_account(S.accountant, "6061", "Fournitures non stockables").value!.number.should eq("6061")
    report = Api.check(S.importer).value!
    report.should eq(Api::CheckReportView.new(3, 0))

    done = Api.transfer(S.importer, S.operations(batch.id).map(&.id)).value!
    done.failed.should be_empty
    sale = Acc.entry(S.accountant, present(done.transferred.first.entry_id))
    sale.ledger_code.should eq("V01")
    sale.receipt.should eq("V-00001")
    sale.date.should eq(S.date("2026-09-03"))
    sale.lines.map { |line| {line.account_number, line.card_code, line.side, line.amount} }.should contain({"706", nil, Acc::Side::Credit, S.d("1000")})
    sale.lines.find! { |line| line.card_code == "CLIENT1" }.amount.should eq(S.d("1200"))
    done.transferred.first.posted_receipt.should eq("V-00001")
    done.transferred.first.receipt.should eq("F2026-1")
    # Pièce de l'émetteur sur l'écriture (D-IMP-015), TVA reconnue (D-IMP-017).
    sale.external_reference.should eq("F2026-1")
    sale.lines.map { |line| {line.card_code || line.account_number, line.vat_rate_code, line.vat_role} }.sort_by!(&.[0]).should eq([
      {"44571", "NOR", "tax"}, {"706", "NOR", "base"}, {"CLIENT1", nil, nil},
    ])
    bank = Acc.entry(S.accountant, present(done.transferred[1].entry_id))
    bank.external_reference.should eq("R1")
    bank.lines.compact_map(&.vat_rate_code).should be_empty
  end

  it "reprend le lettrage du FEC sur les lignes transférées" do
    S.setup
    S.card("CUSTOMER", "Client Un", "CLIENT1")
    S.fec_mappings
    S.mapping("code", "6061", "account", "627")
    batch = S.import(S::FEC)
    operations = S.operations(batch.id)
    operations.all?(&.ready?).should be_true

    Api.transfer(S.importer, [operations.first.id]).value!.transferred.size.should eq(1)
    partial = Api.apply_lettering(S.importer, batch.id).value!
    partial.matched.should eq(0)
    partial.problems.map(&.key).should eq(["import.errors.lettering.pending"])

    Api.transfer(S.importer, operations[1..].map(&.id)).value!.failed.should be_empty
    report = Api.apply_lettering(S.importer, batch.id).value!
    report.should eq(Api::LetteringReportView.new(1, [] of Partiduo::Api::FieldError))
    sale = Acc.entry(S.accountant, present(Api.operation(S.reader, operations.first.id).entry_id))
    sale.lines.find! { |line| line.card_code == "CLIENT1" }.matching_id.should_not be_nil
    Api.apply_lettering(S.importer, batch.id).value!.matched.should eq(0)
    Api.batch(S.reader, batch.id).letter_count.should eq(2)
  end

  it "signale une écriture déjà reprise par partiduo-migrate (référence fec:<journal>:<numéro>)" do
    S.setup
    S.mapping("ledger", "OD", "ledger", "O01")
    S.mapping("code", "6061", "account", "627")
    S.mapping("code", "512000", "account", "510001")
    lines = [Acc::EntryLineInput.new("627", Acc::Side::Debit, S.d("30")), Acc::EntryLineInput.new("510001", Acc::Side::Credit, S.d("30"))]
    migrated = Acc.post_entry(S.system, Acc::EntryInput.new(ledger_id: S.ledger("O01").id, date: S.date("2026-09-25"),
      lines: lines, source: "fec:OD:OD1")).value!
    batch = S.import(S::FEC)
    S.operations(batch.id).last.recorded_entry_id.should eq(migrated.id)
  end

  it "refuse une écriture déséquilibrée du FEC avec son motif" do
    S.setup
    content = "JournalCode\tEcritureNum\tEcritureDate\tCompteNum\tEcritureLib\tDebit\tCredit\n" \
              "O01\tE1\t20260910\t627\tFrais\t10,00\t\nO01\tE1\t20260910\t510001\tFrais\t\t9,99\n"
    preview = Api.preview(S.importer, Api::ImportInput.new(filename: "fec.txt", content: content.to_slice)).value!
    preview.kind.should eq("fec")
    problem = preview.operations.first.problems.first
    problem.key.should eq("import.errors.operation.unbalanced")
    problem.params["difference"].should eq("0.01")
  end

  it "lit le FEC par le lecteur commun du cœur : zones par leur nom, ISO 8859-15, écritures par journal et numéro" do
    S.setup
    preview = Api.preview(S.importer, S.input(S::FEC)).value!
    preview.encoding.should eq("iso-8859-15")
    preview.issues.should be_empty
    preview.operations.map { |operation| {operation.ledger_code, operation.group_key, operation.lines.size} }.should eq([
      {"VT", "VT1", 3}, {"BQ", "BQ1", 2}, {"OD", "OD1", 2},
    ])
    sale = preview.operations.first
    sale.receipt.should eq("F2026-1")
    line = sale.lines.first
    {line.code, line.aux, line.aux_label, line.side, line.amount, line.letter}.should eq({"411000", "CLI01", "Client Un", "debit", S.d("1200"), "A"})
    sale.lines[2].code_label.should eq("TVA collectée")
  end

  it "accepte Montant et Sens, la barre verticale et le point-virgule ; refuse un en-tête incomplet" do
    S.setup
    preview = ->(content : String) { Api.preview(S.importer, Api::ImportInput.new(filename: "fec.txt", content: content.to_slice, kind: "fec")) }
    pipe = "JournalCode|EcritureNum|EcritureDate|CompteNum|EcritureLib|Montant|Sens\nO01|1|20260901|627|X|10,00|D\nO01|1|20260901|510001|X|10,00|C\n"
    preview.call(pipe).value!.operations.first.lines.map(&.side).should eq(%w[debit credit])
    semicolon = "JournalCode;EcritureNum;EcritureDate;CompteNum;Debit;Credit\nO01;1;20260901;627;10,00;\nO01;1;20260901;510001;;10,00\n"
    preview.call(semicolon).value!.operations.first.accepted?.should be_true
    refused = preview.call("JournalCode\tEcritureNum\n")
    refused.failure?.should be_true
    refused.errors.map(&.key).uniq!.should eq(["accounting.fec_reader.issues.missing_column"])
  end

  it "bloque l'opération d'une ligne illisible, que le lecteur a écartée, et signale la ligne au fichier" do
    S.setup
    content = "JournalCode\tEcritureNum\tEcritureDate\tCompteNum\tDebit\tCredit\n" \
              "O01\t1\t20260901\t627\t10,00\t\nO01\t1\t20260901\t627\tdix\t\nO01\t1\t20260901\t510001\t\t20,00\n" \
              "O01\t2\t20260902\t627\t5,00\t\nO01\t2\t20260902\t510001\t\t5,00\n"
    result = Api.preview(S.importer, Api::ImportInput.new(filename: "fec.txt", content: content.to_slice)).value!
    result.issues.map(&.key).should eq(["accounting.fec_reader.issues.unreadable_amount"])
    first, second = result.operations
    first.problems.map(&.key).should contain("accounting.fec_reader.issues.unreadable_amount")
    first.lines.size.should eq(2)
    second.problems.should be_empty
  end

  it "passe la facture d'un FEC avec ses taux et rôles de TVA, retrouvés par les comptes de TVA et les montants (D-IMP-017)" do
    S.setup
    S.card("CUSTOMER", "Client Un", "CLIENT1")
    content = "JournalCode\tEcritureNum\tEcritureDate\tCompteNum\tCompAuxNum\tPieceRef\tDebit\tCredit\n" \
              "V01\t1\t20260903\t411\tCLIENT1\tF-1\t1700,00\t\nV01\t1\t20260903\t706\t\tF-1\t\t1000,00\n" \
              "V01\t1\t20260903\t706\t\tF-1\t\t500,00\nV01\t1\t20260903\t44571\t\tF-1\t\t200,00\n" \
              "V01\t2\t20260904\t411\tCLIENT1\tF-2\t1150,00\t\nV01\t2\t20260904\t706\t\tF-2\t\t1000,00\n" \
              "V01\t2\t20260904\t44571\t\tF-2\t\t150,00\n"
    batch = Api.import_file(S.accountant, Api::ImportInput.new(filename: "fec.txt", content: content.to_slice)).value!
    operations = S.operations(batch.id)
    operations.all?(&.ready?).should be_true
    done = Api.transfer(S.importer, operations.map(&.id)).value!
    done.failed.should be_empty
    roles = ->(index : Int32) do
      Acc.entry(S.accountant, present(done.transferred[index].entry_id)).lines
        .map { |line| {line.card_code || line.account_number, line.amount, line.vat_rate_code, line.vat_role} }
        .sort_by! { |row| {row[0], row[1]} }
    end
    # Facture : base à 20 % et base exonérée, seule la première porte le taux.
    roles.call(0).should eq([
      {"44571", S.d("200"), "NOR", "tax"}, {"706", S.d("500"), nil, nil},
      {"706", S.d("1000"), "NOR", "base"}, {"CLIENT1", S.d("1700"), nil, nil},
    ])
    # Taxe qui ne correspond à aucune base : l'écriture passe sans TVA.
    roles.call(1).map(&.[2]).uniq!.should eq([nil])
  end
end
