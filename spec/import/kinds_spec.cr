# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api
private alias Acc = Partiduo::Api::Accounting

private def misc_analytic_format : Api::FormatView
  input = Api::FormatInput.new(name: "OD ventilées", ledger_kind: "misc", ledger_id: S.ledger("O01").id,
    columns: %w[date receipt account debit credit analytic])
  Api.create_format(S.accountant, input).value!
end

describe "Ventilation analytique et dossier foyer (D-IMP-002, D-IMP-013)" do
  it "ventile chaque ligne sur les postes analytiques désignés par leur code" do
    S.setup
    plan = Partiduo::Api::Analytic.create_plan(S.system, Partiduo::Api::Analytic::PlanInput.new("Chantiers")).value!
    post = Partiduo::Api::Analytic.create_post(S.system, Partiduo::Api::Analytic::PostInput.new(plan.id, "CH1")).value!
    content = "Date;Pièce;Compte;Débit;Crédit;Analytique\n15/09/2026;P1;627;40,00;;ch1\n15/09/2026;P1;510001;;40,00;\n" \
              "16/09/2026;P2;627;5,00;;INCONNU\n16/09/2026;P2;510001;;5,00;\n"
    format = misc_analytic_format
    batch = Api.import_file(S.accountant, Api::ImportInput.new(filename: "od.csv", content: content.to_slice,
      format_id: format.id)).value!
    good, bad = S.operations(batch.id)
    good.ready?.should be_true
    S.keys(bad).should eq(["import.errors.analytic.unknown"])
    entry_id = present(Api.transfer(S.importer, [good.id]).value!.transferred.first.entry_id)
    distributions = Partiduo::Api::Analytic.entry_distributions(S.accountant, entry_id)
    distributions.size.should eq(1)
    distributions.first.rows.first.posts.map(&.id).should eq([post.id])
  end

  it "refuse la ventilation quand le module Analytique est inactif" do
    S.setup
    Partiduo::Api::Modules.deactivate(S.system, "ANALYTIC")
    content = "Date;Pièce;Compte;Débit;Crédit;Analytique\n15/09/2026;P1;627;40,00;;CH1\n15/09/2026;P1;510001;;40,00;\n"
    format = misc_analytic_format
    preview = Api.preview(S.importer, Api::ImportInput.new(filename: "od.csv", content: content.to_slice, format_id: format.id)).value!
    preview.operations.first.problems.map(&.key).should eq(["import.errors.analytic.inactive"])
  end

  it "sert un dossier foyer : extrait financier sur ses catégories, sans TVA" do
    with_active_modules("accounting") do
      settings = Partiduo::Api::Core::SettingsInput.new(company_name: "Foyer Martin", tax_regime: "fr", country_code: "FR",
        domain: "martin.partiduo.localhost")
      Partiduo::Api::Core.provision(S.system, Partiduo::Api::Core::ProvisionInput.new(settings: settings,
        modules: ["accounting"], kind: Partiduo::Api::InitialData::HOUSEHOLD)).value!
      PartiduoUi::Reference.fiscal_year(2026)
      S.user("alice@example.com", "Alice")
      S.user("bruno@example.com", "Bruno")
      S.activate
      Partiduo::Api::Core.settings(S.system).household?.should be_true
      format = Api.create_format(S.accountant, Api::FormatInput.new(name: "Compte courant", ledger_kind: "financial",
        ledger_id: S.ledger("F01").id, columns: %w[date line_label account amount])).value!
      content = "Date;Libellé;Catégorie;Montant\n05/09/2026;Don association;601;-50,00\n"
      batch = Api.import_file(S.accountant, Api::ImportInput.new(filename: "compte.csv", content: content.to_slice,
        format_id: format.id)).value!
      operation = S.operations(batch.id).first
      operation.ready?.should be_true
      entry_id = present(Api.transfer(S.importer, [operation.id]).value!.transferred.first.entry_id)
      Acc.entry(S.accountant, entry_id).lines.find! { |line| line.account_number == "601" }.amount.should eq(S.d("50"))
    end
  end
end
