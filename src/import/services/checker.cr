# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Vérification des opérations (D-IMP-007) : chacune est traduite pour le
  # dossier, puis *réellement* passée par le service d'écriture dans
  # `Partiduo::Api::Transaction.dry_run`, qui annule tout à la fin — comme
  # l'aperçu des imports du cœur (D-OUT-002). On obtient ainsi tous les
  # refus de la Comptabilité (période close, fiche d'un autre journal,
  # compte non utilisable…) et la pièce que le cœur donnerait, sans rien
  # écrire. Chaque opération est essayée dans son point de sauvegarde : un
  # refus n'empêche pas les suivantes. Interne.
  module Checker
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    # Résultat de l'essai d'une opération.
    record Outcome,
      ledger : Acc::LedgerView?,
      problems : Array(FieldError),
      receipt : String?,
      recorded_entry_id : Int64?

    # Essaie les opérations dans l'ordre donné ; `sources` : référence de
    # chacune (`import:operation:<id>`, ou `import:preview`).
    def self.run(actor : Partiduo::Api::Actor, resolver : Resolver, operations : Array(Parsers::ParsedOperation),
                 sources : Array(String), attachment_id : Int64? = nil) : Array(Outcome)
      Partiduo::Api::Transaction.dry_run do
        operations.map_with_index do |operation, index|
          problems = operation.problems.map(&.to_error)
          planned, errors, ledger = resolver.resolve(operation, sources[index], attachment_id)
          problems.concat(errors)
          recorded = ledger.try { |found| recorded(actor, operation, found) }
          receipt = nil
          if planned && problems.empty?
            result = Partiduo::Api::Transaction.run { Poster.post(actor, planned) }
            if result.success?
              receipt = result.value!.first?.try(&.receipt)
            else
              problems.concat(result.errors)
            end
          end
          Outcome.new(ledger, problems, receipt, recorded)
        end
      end
    end

    # Écriture déjà passée qui ressemble à l'opération (D-IMP-008) : même
    # journal, même date, même montant — ou, pour un FEC, la référence que
    # lui donne la reprise d'un dossier (`fec:<journal>:<numéro>`).
    def self.recorded(actor : Partiduo::Api::Actor, operation : Parsers::ParsedOperation, ledger : Acc::LedgerView) : Int64?
      reference = "fec:#{operation.ledger_code}:#{operation.group_key}"
      by_source = Acc.entries(actor, Acc::EntryQuery.new(source: reference, limit: 1)).first?
      return by_source.id if by_source
      total = operation.lines.select(&.debit?).sum(BigDecimal.new(0), &.amount)
      total = operation.lines.sum(BigDecimal.new(0)) { |line| line.amount.abs + (line.vat_amount || BigDecimal.new(0)) } if total.zero?
      query = Acc::EntryQuery.new(ledger_id: ledger.id, date_from: operation.date, date_to: operation.date,
        amount_min: total, amount_max: total, include_cancelled: false, limit: 20)
      Acc.entries(actor, query).find { |entry| !entry.source.starts_with?("import:") }.try(&.id)
    rescue Partiduo::Api::AccessDenied
      nil
    end
  end
end
