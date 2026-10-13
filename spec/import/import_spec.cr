# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api
private alias Acc = Partiduo::Api::Accounting

describe "Aperçu à blanc et zone d'attente d'un CSV (D-IMP-007)" do
  it "essaie chaque opération à blanc : rien n'est écrit, la pièce du cœur est annoncée, le déséquilibre refusé" do
    S.setup
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    preview = Api.preview(S.importer, S.input("od.csv", format.id)).value!
    preview.kind.should eq("csv")
    preview.ledger_kind.should eq("misc")
    preview.operations.size.should eq(2)
    good, bad = preview.operations
    good.accepted?.should be_true
    good.ledger_id.should eq(S.ledger("O01").id)
    good.posted_receipt.should eq("O-00001")
    bad.accepted?.should be_false
    error = bad.problems.find! { |item| item.key == "import.errors.operation.unbalanced" }
    error.params.should eq({"debit" => "10.00", "credit" => "9.00", "difference" => "1.00"})
    error.message.should eq("Écriture déséquilibrée : débit 10.00, crédit 9.00 (écart 1.00).")
    Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.ledger("O01").id)).should be_empty
    Api.batches(S.reader).should be_empty
    S.ledger("O01").last_receipt_number.should eq(0)
  end

  it "met les opérations en attente avec leurs motifs, conserve le fichier en pièce jointe, ne passe rien" do
    S.setup
    format = S.misc_format
    batch = S.import("od.csv", format.id)
    batch.operation_count.should eq(2)
    batch.pending_count.should eq(2)
    batch.refused_count.should eq(2)
    attachment = Partiduo::Api::Core.attachment(S.accountant, present(batch.attachment_id))
    {attachment.filename, attachment.content_type}.should eq({"od.csv", "text/csv"})
    operations = S.operations(batch.id)
    S.keys(operations.first).should eq(["import.errors.ledger.unknown"])
    operations.first.problems.first.params.should eq({"code" => "OD"})
    Acc.entries(S.accountant).should be_empty

    # Correspondance ajoutée, nouvelle vérification.
    Api.unknown_codes(S.accountant).map { |code| {code.kind, code.source, code.count} }.should eq([{"ledger", "OD", 2}])
    S.mapping("ledger", "OD", "ledger", "O01")
    Api.check(S.importer).value!.should eq(Api::CheckReportView.new(1, 1))
    first, second = S.operations(batch.id)
    first.ready?.should be_true
    first.ledger_id.should eq(S.ledger("O01").id)
    S.keys(second).should eq(["import.errors.operation.unbalanced"])
    Api.unknown_codes(S.accountant).should be_empty
  end

  it "importe des factures d'achat : tiers, articles ou comptes, codes de TVA de l'émetteur, échéance" do
    S.setup
    S.card("SUPPLIER", "Fournitures du Centre", "FOURN1")
    format = S.purchase_format
    batch = S.import("achats.csv", format.id)
    S.operations(batch.id).flat_map { |view| view.problems.map { |error| error.params["code"]? } }.uniq!.should eq(["T20", "T55"])
    S.mapping("vat", "T20", "vat", "NOR")
    S.mapping("vat", "t55", "vat", "TR55")
    Api.check(S.importer).value!.ready.should eq(2)
    report = Api.transfer(S.importer, S.operations(batch.id).map(&.id)).value!
    report.failed.should be_empty
    invoice = Acc.entry(S.accountant, present(report.transferred.first.entry_id))
    invoice.ledger_code.should eq("A01")
    invoice.receipt.should eq("A-00001")
    invoice.due_date.should eq(S.date("2026-10-10"))
    invoice.source.should eq("import:operation:#{report.transferred.first.id}")
    invoice.attachment_id.should eq(batch.attachment_id)
    invoice.lines.find! { |line| line.card_code == "FOURN1" }.amount.should eq(S.d("180"))
    invoice.lines.select(&.account_number.in?("603", "627")).map { |line| {line.account_number, line.amount, line.vat_rate_code} }
      .should eq([{"603", S.d("100"), "NOR"}, {"627", S.d("50"), "NOR"}])
    invoice.lines.find! { |line| line.account_number == "445661" }.amount.should eq(S.d("30"))
    second = Acc.entry(S.accountant, present(report.transferred.last.entry_id))
    second.lines.find! { |line| line.card_code == "FOURN1" }.amount.should eq(S.d("211"))
  end

  it "lit un CSV en Windows-1252" do
    S.setup
    S.card("SUPPLIER", "Fournitures du Centre", "FOURN1")
    S.mapping("vat", "T20", "vat", "NOR")
    format = S.purchase_format("windows-1252")
    batch = S.import("achats-1252.csv", format.id)
    batch.encoding.should eq("windows-1252")
    operation = S.operations(batch.id).first
    operation.lines.first.label.should eq("Matériel € éco")
    operation.ready?.should be_true
  end

  it "importe un extrait financier : une contrepartie par ligne, montant signé" do
    S.setup
    S.card("CUSTOMER", "Client Un", "CLIENT1")
    format = S.bank_format
    batch = S.import("banque.csv", format.id)
    S.operations(batch.id).all?(&.ready?).should be_true
    report = Api.transfer(S.importer, S.operations(batch.id).map(&.id)).value!
    report.transferred.size.should eq(2)
    entry = Acc.entry(S.accountant, present(report.transferred.first.entry_id))
    entry.ledger_code.should eq("F01")
    entry.lines.find! { |line| line.card_code == "CLIENT1" }.side.should eq(Acc::Side::Credit)
    fees = Acc.entry(S.accountant, present(report.transferred.last.entry_id))
    fees.lines.find! { |line| line.account_number == "627" }.amount.should eq(S.d("15.30"))
  end

  it "refuse un journal d'un autre genre que le format, et un journal fermé à l'acteur" do
    S.setup
    S.card("CUSTOMER", "Client Un", "CLIENT1")
    format = S.bank_format
    batch = S.import("banque.csv", format.id, ledger_id: S.ledger("O01").id)
    S.keys(S.operations(batch.id).first).should eq(["import.errors.ledger.kind"])
  end

  it "signale les doublons d'un fichier déjà importé, et refuse le même fichier sans confirmation" do
    S.setup
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    first = S.import("od.csv", format.id)
    refused = Api.import_file(S.accountant, S.input("od.csv", format.id))
    refused.errors.map(&.key).should eq(["import.errors.file.already_imported"])
    refused.errors.first.params["id"].should eq(first.id.to_s)
    # Date de l'import dans le fuseau du dossier : 23 h 30 UTC le 9 mars est
    # le 10 mars à Paris.
    Marten::DB::Connection.default.open(&.exec("UPDATE import_batch SET created_at = '2026-03-09 23:30:00+00' WHERE id = $1", first.id))
    Api.import_file(S.accountant, S.input("od.csv", format.id)).errors.first.params["date"].should eq("2026-03-10")
    preview = Api.preview(S.accountant, S.input("od.csv", format.id)).value!
    preview.same_file_batch_id.should eq(first.id)
    preview.duplicate_count.should eq(2)
    again = S.import("od.csv", format.id, allow_same_file: true)
    again.duplicate_count.should eq(2)
    duplicates = S.operations(again.id)
    duplicates.map(&.status).should eq(%w[duplicate duplicate])
    duplicates.first.duplicate_of_id.should eq(S.operations(first.id).first.id)

    # Un doublon n'est jamais transféré ; repris, il redevient à traiter.
    Api.transfer(S.importer, [duplicates.first.id]).value!.transferred.should be_empty
    Api.restore(S.importer, [duplicates.first.id]).value!.should eq(1)
    Api.operation(S.reader, duplicates.first.id).ready?.should be_true
    Api.discard(S.importer, [duplicates.first.id]).value!.should eq(1)
    Api.purge(S.accountant).value!.should eq(2)
  end

  it "signale une écriture semblable déjà passée hors de l'extension" do
    S.setup
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    lines = [Acc::EntryLineInput.new("627", Acc::Side::Debit, S.d("12.50")),
             Acc::EntryLineInput.new("510001", Acc::Side::Credit, S.d("12.50"))]
    manual = Acc.post_entry(S.system, Acc::EntryInput.new(ledger_id: S.ledger("O01").id, date: S.date("2026-09-15"),
      lines: lines, label: "Frais saisis")).value!
    batch = S.import("od.csv", format.id)
    S.operations(batch.id).first.recorded_entry_id.should eq(manual.id)
  end

  it "refuse un fichier vide, binaire ou sans format, et exige les droits du cœur" do
    S.setup
    format = S.misc_format
    blank = Api::ImportInput.new(filename: "x.csv", content: Bytes.empty, format_id: format.id)
    Api.preview(S.importer, blank).errors.map(&.key).should eq(["import.errors.file.blank"])
    binary = Api::ImportInput.new(filename: "x.csv", content: Bytes[1, 0, 2], format_id: format.id)
    Api.preview(S.importer, binary).errors.map(&.key).should eq(["import.errors.file.binary"])
    Api.preview(S.importer, S.input("od.csv")).errors.map(&.key).should eq(["import.errors.format.blank"])
    expect_raises(Partiduo::Api::Forbidden) { Api.preview(S.reader, S.input("od.csv", format.id)) }
    poster = S.actor("bruno@example.com", [Api::READ, Api::RUN])
    expect_raises(Partiduo::Api::Forbidden) { Api.preview(poster, S.input("od.csv", format.id)) }
  end
end
