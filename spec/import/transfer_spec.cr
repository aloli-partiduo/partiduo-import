# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api
private alias Acc = Partiduo::Api::Accounting

describe "Transfert par le service d'écriture du cœur (D-IMP-007, D-IMP-010)" do
  it "passe une écriture par opération, avec la numérotation du journal, la pièce jointe et l'acteur réel" do
    S.setup
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    batch = S.import("od.csv", format.id)
    good, bad = S.operations(batch.id)
    report = Api.transfer(S.importer, [good.id, bad.id]).value!
    report.transferred.map(&.id).should eq([good.id])
    report.failed.map(&.id).should eq([bad.id])
    S.keys(report.failed.first).should eq(["import.errors.operation.unbalanced"])
    entry = Acc.entry(S.accountant, present(report.transferred.first.entry_id))
    entry.receipt.should eq("O-00001")
    entry.created_by_id.should eq(S.user_id("bruno@example.com"))
    entry.attachment_id.should eq(batch.attachment_id)
    entry.label.should eq("Frais bancaires")
    entry.lines.map { |line| {line.account_number, line.side, line.amount} }.should eq([
      {"627", Acc::Side::Debit, S.d("12.5")}, {"510001", Acc::Side::Credit, S.d("12.5")},
    ])
    Api.batch(S.reader, batch.id).transferred_count.should eq(1)
    Api.delete_batch(S.accountant, batch.id).errors.map(&.key).should eq(["import.errors.batch.in_use"])

    # Une opération transférée ne l'est pas deux fois.
    Api.transfer(S.importer, [good.id]).value!.transferred.should be_empty
  end

  it "laisse à traiter une opération refusée par la Comptabilité (période close), avec le motif du cœur" do
    S.setup
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    batch = S.import("od.csv", format.id)
    period = present(Partiduo::Api::Core.period_for(S.system, S.date("2026-09-15")))
    Partiduo::Api::Core.close_period(S.system, period.id).value!
    report = Api.transfer(S.importer, [S.operations(batch.id).first.id]).value!
    report.transferred.should be_empty
    S.keys(report.failed.first).first.should start_with("accounting.errors.")
    report.failed.first.pending?.should be_true
  end

  it "rend à traiter l'opération dont l'écriture est extournée" do
    S.setup
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    batch = S.import("od.csv", format.id)
    operation = S.operations(batch.id).first
    entry_id = present(Api.transfer(S.importer, [operation.id]).value!.transferred.first.entry_id)
    Acc.cancel_entry(S.accountant, Acc::CancelEntryInput.new(entry_id)).value!
    back = Api.operation(S.reader, operation.id)
    back.pending?.should be_true
    back.reversed_entry_id.should eq(entry_id)
    back.entry_id.should be_nil
  end

  it "écarte, reprend et purge ; supprime un import non transféré avec son fichier" do
    S.setup
    format = S.misc_format
    batch = S.import("od.csv", format.id)
    ids = S.operations(batch.id).map(&.id)
    Api.discard(S.importer, ids).value!.should eq(2)
    Api.transfer(S.importer, ids).value!.transferred.should be_empty
    Api.restore(S.importer, [ids.first]).value!.should eq(1)
    Api.discard(S.importer, [] of Int64).errors.map(&.key).should eq(["import.errors.operation.none_selected"])
    attachment_id = present(batch.attachment_id)
    Api.delete_batch(S.accountant, batch.id).success?.should be_true
    Api.batches(S.reader).should be_empty
    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Core.attachment(S.accountant, attachment_id) }
  end

  it "montre la tuile et le compteur des opérations à traiter" do
    S.setup
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    S.import("od.csv", format.id)
    tile = present(Api.tile(S.reader))
    {tile.pending_count, tile.ready_count, tile.refused_count}.should eq({2, 1, 1})
    tile.oldest_date.should eq(S.date("2026-09-15"))
    Api.pending_count(S.reader).should eq(2)
  end
end
