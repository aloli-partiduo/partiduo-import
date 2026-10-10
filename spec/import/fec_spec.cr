# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api
private alias Acc = Partiduo::Api::Accounting

describe "Import d'un FEC dans un dossier existant (D-IMP-011, D-IMP-012)" do
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
end
