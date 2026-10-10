# SPDX-License-Identifier: AGPL-3.0-or-later

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration.
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

# Valeur attendue présente : échoue clairement sinon (plutôt que `not_nil!`).
def present(value : T?) : T forall T
  value.nil? ? raise("valeur attendue, nil obtenu") : value
end

module Import
  # Outils des specs : dossier FR provisionné par le contrat du cœur
  # (journaux A01, V01, F01, O01), exercice 2026, extension activée,
  # acteurs, formats et correspondances des fichiers d'exemple.
  module SpecSupport
    alias Api = Import::Api
    alias Acc = Partiduo::Api::Accounting

    FIXTURES = File.join(ROOT, "spec", "fixtures")
    FEC      = "732829320FEC20260930.txt"

    # Permissions du cœur d'un comptable qui importe et transfère.
    CORE_PERMISSIONS = ["core.attachment.read", "core.attachment.write", "accounting.ledger.read", "accounting.entry.read",
                        "accounting.entry.post", "accounting.entry.cancel", "accounting.account.read",
                        "accounting.account.write", "accounting.matching.write", "cards.card.read", "vat.rate.read",
                        "analytic.plan.read", "analytic.operation.write"]

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    def self.fixture(name : String) : Bytes
      File.open(File.join(FIXTURES, name), &.getb_to_end)
    end

    # Dossier FR (plan comptable, journaux, taux, fiches), exercice 2026,
    # utilisateurs de test, extension active.
    def self.setup : Nil
      PartiduoUi::Reference.provision
      PartiduoUi::Reference.fiscal_year(2026)
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
      activate
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(system, Import::CODE).value!
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    def self.actor(email : String, permissions : Array(String)) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), permissions, level: 3)
    end

    # Comptable : toute l'extension et les droits du cœur qu'elle emploie.
    def self.accountant : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::RUN, Api::ADMIN] + CORE_PERMISSIONS)
    end

    # Importe et transfère, sans paramétrer.
    def self.importer : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, Api::RUN] + CORE_PERMISSIONS)
    end

    def self.reader : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, "accounting.ledger.read"])
    end

    def self.ledger(code : String) : Acc::LedgerView
      Acc.ledger_by_code(system, code)
    end

    def self.card(category : String, name : String, code : String) : Partiduo::Api::Cards::CardView
      PartiduoUi::Books.card(category, name, code)
    end

    def self.mapping(kind : String, source : String, type : String, target : String) : Api::MappingView
      Api.create_mapping(accountant, Api::MappingInput.new(kind, source, type, target)).value!
    end

    # `Date;Journal;Groupe;Pièce;Compte;Libellé;Montant;Sens`.
    def self.misc_format : Api::FormatView
      input = Api::FormatInput.new(name: "Opérations diverses", ledger_kind: "misc",
        columns: %w[date ledger group receipt account line_label amount side])
      Api.create_format(accountant, input).value!
    end

    # `Date;Pièce;Fournisseur;Compte;Libellé;Quantité;HT;TVA;TTC;Échéance`.
    def self.purchase_format(encoding : String = "utf-8") : Api::FormatView
      input = Api::FormatInput.new(name: "Achats #{encoding}", ledger_kind: "purchase", ledger_id: ledger("A01").id,
        columns: %w[date receipt third_party account line_label quantity amount vat_code amount_incl due_date],
        encoding: encoding)
      Api.create_format(accountant, input).value!
    end

    # `Date;Libellé;Contrepartie;Montant`.
    def self.bank_format : Api::FormatView
      input = Api::FormatInput.new(name: "Banque", ledger_kind: "financial", ledger_id: ledger("F01").id,
        columns: %w[date line_label account amount])
      Api.create_format(accountant, input).value!
    end

    # Correspondances du FEC d'exemple : journaux, comptes, tiers.
    def self.fec_mappings : Nil
      mapping("ledger", "VT", "ledger", "V01")
      mapping("ledger", "BQ", "ledger", "F01")
      mapping("ledger", "OD", "ledger", "O01")
      mapping("code", "706000", "account", "706")
      mapping("code", "445710", "account", "44571")
      mapping("code", "512000", "account", "510001")
      mapping("code", "CLI01", "card", "CLIENT1")
    end

    def self.input(name : String, format_id : Int64? = nil, ledger_id : Int64? = nil, kind : String = "auto",
                   allow_same_file : Bool = false) : Api::ImportInput
      Api::ImportInput.new(filename: name, content: fixture(name), kind: kind, format_id: format_id, ledger_id: ledger_id,
        allow_same_file: allow_same_file)
    end

    def self.import(name : String, format_id : Int64? = nil, ledger_id : Int64? = nil,
                    actor : Partiduo::Api::Actor = accountant, allow_same_file : Bool = false) : Api::BatchView
      result = Api.import_file(actor, input(name, format_id, ledger_id, allow_same_file: allow_same_file))
      raise "import refusé : #{result.errors.map(&.key).join(", ")}" if result.failure?
      result.value!
    end

    def self.operations(batch_id : Int64, status : String? = nil) : Array(Api::OperationView)
      Api.operations(accountant, Api::OperationQuery.new(batch_id: batch_id, status: status))
    end

    def self.keys(view : Api::OperationView) : Array(String)
      (view.read_problems + view.problems).map(&.key)
    end
  end
end
