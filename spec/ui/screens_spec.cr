# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias Api = Import::Api

# Administrateur connecté (profil ADMIN : toutes les permissions), dossier
# provisionné, extension active.
private def signed_in : PartiduoUi::Browser
  browser = PartiduoUi::Books.admin
  S.user("bruno@example.com", "Bruno")
  S.activate
  browser
end

private def form_body(values : Hash(String, String | Array(String))) : String
  URI::Params.build do |params|
    values.each do |key, value|
      value.is_a?(Array) ? value.each { |item| params.add(key, item) } : params.add(key, value)
    end
  end
end

describe "Écrans de l'import d'opérations sous /ext/IMPORT/ (ADR-005)" do
  it "est montée sous le code de l'extension, avec ses permissions par route" do
    Marten.routes.reverse("import:operations").should eq("/ext/IMPORT/operations")
    Marten.routes.reverse("import:batch_detail", id: 4).should eq("/ext/IMPORT/batches/4")
    mount = PartiduoUi::Extensions["IMPORT"]? || raise("interface non montée")
    mount.permission.should eq("import.read")
    mount.permission_for("import:import").should eq("import.run")
    mount.permission_for("import:operation_check").should eq("import.run")
    mount.permission_for("import:operations").should eq("import.read")
    mount.permission_for("import:mappings").should eq("import.admin")
    mount.permission_for("import:account_create").should eq("import.admin")
  end

  it "n'existe pas tant que l'extension est inactive (404) et renvoie un anonyme vers la connexion" do
    browser = PartiduoUi::Books.admin
    browser.get("/ext/IMPORT/operations").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/IMPORT/operations")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FIMPORT%2Foperations")
  end

  it "importe un CSV collé en deux temps : aperçu à blanc, puis zone d'attente" do
    browser = signed_in
    format = S.misc_format
    S.mapping("ledger", "OD", "ledger", "O01")
    browser.get("/ext/IMPORT/").headers["Location"].should eq("/ext/IMPORT/operations")
    start = browser.get("/ext/IMPORT/import").html
    start.should contain("<h1>Importer des opérations")
    start.should contain("Opérations diverses · Opérations diverses")
    content = String.new(S.fixture("od.csv"))
    preview = browser.post("/ext/IMPORT/import", {"step" => "preview", "kind" => "csv", "format_id" => format.id.to_s,
                                                  "ledger_id" => "", "encoding" => "auto", "content" => content})
    preview.status.should eq(200)
    html = preview.html
    html.should contain("2 opérations lues : 1 acceptée(s), 1 refusée(s), 0 doublon(s)")
    html.should contain("O-00001")
    html.should contain("Écriture déséquilibrée : débit 10,00, crédit 9,00 (écart 1,00).")
    html.should contain("Mettre 2 opérations en attente")
    payload = html.match!(/name="payload" value="([^"]+)"/)[1]
    filename = html.match!(/name="filename" value="([^"]+)"/)[1]

    done = browser.post("/ext/IMPORT/import", {"step" => "import", "kind" => "csv", "format_id" => format.id.to_s,
                                               "ledger_id" => "", "encoding" => "auto", "payload" => payload,
                                               "filename" => filename})
    done.status.should eq(302)
    detail = browser.follow(done).html
    detail.should contain("Fichier importé : 2 opérations à traiter (dont 1 refusée(s)), 0 doublon(s) signalé(s).")
    detail.should contain("Frais bancaires")
    detail.should contain("Traiter les opérations")
    Api.batches(S.system).first.filename.should start_with("operations-collees-")
  end

  it "signale à l'aperçu une saisie refusée (422)" do
    browser = signed_in
    response = browser.post("/ext/IMPORT/import", {"step" => "preview", "kind" => "csv", "format_id" => "", "content" => "a;b"})
    response.status.should eq(422)
    response.html.should contain("Choisissez le format du fichier CSV.")
  end

  it "traite les opérations : vérification en HTMX, transfert groupé, compteur et tuile" do
    browser = signed_in
    format = S.misc_format
    batch = S.import("od.csv", format.id)
    first, second = S.operations(batch.id)
    list = browser.get("/ext/IMPORT/operations").html
    list.should contain("<h1>Opérations à traiter")
    list.should contain("2 opérations")
    list.should contain(%(id="imp-operation-#{first.id}"))
    list.should contain(%(hx-post="/ext/IMPORT/operations/#{first.id}/check"))
    list.should contain("Journal OD inconnu : ajoutez sa correspondance.")
    list.should contain("1 code de l'émetteur n'a pas de correspondance.")

    dashboard = browser.get("/").html
    dashboard.should contain(%(data-pd-count="IMPORT_OPERATIONS">2</span>))
    dashboard.should contain("2 opérations importées à traiter")
    dashboard.should contain(%(data-module="IMPORT"))

    S.mapping("ledger", "OD", "ledger", "O01")
    fragment = browser.htmx_post("/ext/IMPORT/operations/#{first.id}/check", {"next" => "/ext/IMPORT/operations"})
    fragment.status.should eq(200)
    row = fragment.html
    row.should start_with(%(<tr id="imp-operation-#{first.id}"))
    row.should contain("Prête")
    row.should contain("O01")
    row.should_not contain("<html")

    moved = browser.perform_raw("/ext/IMPORT/operations/action",
      form_body({"action" => "transfer", "ids" => [first.id.to_s, second.id.to_s], "next" => "/ext/IMPORT/operations"}))
    moved.status.should eq(302)
    after = browser.follow(moved).html
    after.should contain("1 opération transférée en comptabilité.")
    after.should contain("1 opération refusée : voyez ses motifs.")
    after.should contain("1 opération")
  end

  it "complète les codes inconnus sur place (HTMX) et crée un compte d'un FEC" do
    browser = signed_in
    S.card("CUSTOMER", "Client Un", "CLIENT1")
    S.import(S::FEC)
    page = browser.get("/ext/IMPORT/mappings").html
    page.should contain("<h1>Correspondances d'import")
    page.should contain("Codes inconnus des opérations à traiter")
    page.should contain(%(data-imp-unknown="VT"))
    page.should contain("Fournitures non stockables")
    page.should contain("Créer le compte")

    mapped = browser.htmx_post("/ext/IMPORT/mappings/quick", {"kind" => "ledger", "unknown_kind" => "ledger", "source" => "VT",
                                                              "label" => "", "count" => "1", "target_type" => "ledger", "target" => "V01"})
    mapped.status.should eq(200)
    mapped.html.should contain("Associé à V01.")
    refused = browser.htmx_post("/ext/IMPORT/mappings/quick", {"kind" => "code", "unknown_kind" => "code", "source" => "CLI01",
                                                               "label" => "Client Un", "count" => "2", "target_type" => "card", "target" => "NOPE"})
    refused.status.should eq(422)
    refused.html.should contain("NOPE n'existe pas dans le dossier.")
    created = browser.htmx_post("/ext/IMPORT/mappings/account", {"kind" => "code", "unknown_kind" => "account", "source" => "6061",
                                                                 "label" => "Fournitures non stockables", "count" => "1"})
    created.status.should eq(200)
    created.html.should contain("Compte 6061 créé.")
    Partiduo::Api::Accounting.account(S.system, "6061").label.should eq("Fournitures non stockables")
    Api.mappings(S.system, "ledger").map(&.source).should eq(["VT"])
  end

  it "paramètre un format par le rang de ses colonnes" do
    browser = signed_in
    form = browser.get("/ext/IMPORT/formats/new").html
    form.should contain("Nouveau format")
    form.should contain("Code de regroupement")
    created = browser.post("/ext/IMPORT/formats/new", {"name" => "Banque", "ledger_kind" => "financial", "separator" => "semicolon",
                                                       "quote" => "double", "encoding" => "utf-8", "skip_lines" => "1",
                                                       "date_format" => "dd/mm/yyyy", "decimal_separator" => "comma",
                                                       "thousands_separator" => "none", "column.date" => "1",
                                                       "column.line_label" => "2", "column.account" => "3", "column.amount" => "4"})
    created.status.should eq(302)
    Api.formats(S.system).first.columns.should eq(%w[date line_label account amount])
    refused = browser.post("/ext/IMPORT/formats/new", {"name" => "X", "ledger_kind" => "misc", "separator" => "semicolon",
                                                       "quote" => "double", "encoding" => "utf-8", "skip_lines" => "1",
                                                       "date_format" => "dd/mm/yyyy", "decimal_separator" => "comma",
                                                       "thousands_separator" => "none", "column.date" => "1", "column.account" => "1"})
    refused.status.should eq(422)
    refused.html.should contain("Ce rang est déjà donné à un autre champ.")
    browser.get("/ext/IMPORT/formats").html.should contain("Banque")
  end

  it "montre l'historique et le détail d'un import, le fichier se télécharge" do
    browser = signed_in
    format = S.misc_format
    batch = S.import("od.csv", format.id)
    browser.get("/ext/IMPORT/batches").html.should contain("od.csv")
    detail = browser.get("/ext/IMPORT/batches/#{batch.id}").html
    detail.should contain("Opérations diverses")
    detail.should contain("Supprimer l'import")
    file = browser.get("/ext/IMPORT/batches/#{batch.id}/file")
    file.status.should eq(200)
    file.headers["Content-Disposition"].should eq(%(attachment; filename="od.csv"))
  end
end
