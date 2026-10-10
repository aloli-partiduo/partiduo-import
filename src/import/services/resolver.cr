# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Traduction d'une opération lue en entrée du service d'écriture de la
  # Comptabilité (D-IMP-006, D-IMP-007) : journal, comptes et fiches, codes
  # de TVA et postes analytiques de l'émetteur remplacés par ceux du dossier
  # — par les correspondances enregistrées, à défaut par un code identique —
  # puis contrôles propres à l'import (équilibre, genre du journal). Tout
  # ce qui n'est pas reconnu est un motif de refus nommé : rien n'est deviné
  # ni passé d'office. Les lectures se font avec les droits de l'acteur.
  # Interne.
  class Resolver
    alias Acc = Partiduo::Api::Accounting
    alias Analytic = Partiduo::Api::Analytic
    alias FieldError = Partiduo::Api::FieldError

    # Entrée prête pour le service d'écriture : genre d'écriture (`entry`,
    # `purchase`, `sale`, `financial`), journal, entrée correspondante et
    # ventilation analytique des lignes saisies.
    record Planned,
      kind : String,
      ledger : Acc::LedgerView,
      entry : Acc::EntryInput? = nil,
      document : Acc::DocumentInput? = nil,
      financial : Acc::FinancialInput? = nil,
      distributions : Array(Analytic::InputDistributionInput) = [] of Analytic::InputDistributionInput

    # Contrepartie reconnue : compte (`account`) ou fiche (`card`).
    record Target, type : String, value : String

    @mappings : Hash({String, String}, Mapping)
    @ledgers : Array(Acc::LedgerView)?
    @cards = {} of String => String?
    @accounts = {} of String => Bool
    @rates = {} of String => String?
    @posts : Array(Analytic::PostView)?

    # `kind` : genre du fichier (`csv`, `fec`) ; `ledger_kind` : genre de
    # journal d'un CSV ; `default_ledger_id` : journal d'un CSV sans
    # colonne de journal.
    def initialize(@actor : Partiduo::Api::Actor, @kind : String, @ledger_kind : String, @default_ledger_id : Int64?)
      @mappings = Mapping.all.to_a.to_h { |row| { {row.kind.to_s, row.source.to_s.downcase}, row } }
    end

    # Entrée prévue, ou motifs du refus.
    def resolve(operation : Parsers::ParsedOperation, source : String,
                attachment_id : Int64?) : {Planned?, Array(FieldError), Acc::LedgerView?}
      errors = [] of FieldError
      ledger = ledger(operation, errors)
      if operation.lines.empty?
        errors << error("lines", "operation.no_line")
        return {nil, errors, ledger}
      end
      planned = if @kind == "fec" || @ledger_kind == "misc"
                  entry(operation, ledger, errors, source, attachment_id)
                elsif @ledger_kind == "financial"
                  financial(operation, ledger, errors, source, attachment_id)
                else
                  document(operation, ledger, errors, source, attachment_id)
                end
      errors.empty? ? {planned, errors, ledger} : {nil, errors, ledger}
    end

    # --- Journal ---------------------------------------------------------------

    private def ledger(operation : Parsers::ParsedOperation, errors : Array(FieldError)) : Acc::LedgerView?
      code = operation.ledger_code
      found = if code.empty?
                if @kind == "fec"
                  nil
                elsif id = @default_ledger_id
                  ledgers.find(&.id.==(id))
                else
                  errors << error("ledger", "ledger.blank")
                  return
                end
              else
                target = @mappings[{"ledger", code.downcase}]?.try(&.target.to_s) || code
                ledgers.find { |item| item.code.downcase == target.downcase }
              end
      if found.nil?
        errors << error("ledger", "ledger.unknown", {"code" => code})
        return
      end
      if @kind == "csv" && found.kind.code != @ledger_kind
        errors << error("ledger", "ledger.kind", {"code" => found.code, "kind" => @ledger_kind})
      end
      unless found.access.write?
        errors << error("ledger", "ledger.not_writable", {"code" => found.code})
      end
      found
    end

    private def ledgers : Array(Acc::LedgerView)
      @ledgers ||= Records.visible_ledgers(@actor)
    end

    # --- Écritures ligne à ligne (opérations diverses, FEC) ------------------

    private def entry(operation : Parsers::ParsedOperation, ledger : Acc::LedgerView?, errors : Array(FieldError),
                      source : String, attachment_id : Int64?) : Planned?
      lines = [] of Acc::EntryLineInput
      zero = BigDecimal.new(0)
      operation.lines.each_with_index do |line, index|
        target = @kind == "fec" ? fec_target(line, index, errors) : code_target(line.code, "", "lines[#{index}].code", errors)
        side = line.debit? ? Acc::Side::Debit : Acc::Side::Credit
        next if target.nil?
        lines << if target.type == "card"
          Acc::EntryLineInput.new("", side, line.amount, card: target.value, label: line.label)
        else
          Acc::EntryLineInput.new(target.value, side, line.amount, label: line.label)
        end
      end
      if operation.lines.size < 2
        errors << error("lines", "operation.single_line")
      else
        debit = operation.lines.select(&.debit?).sum(zero, &.amount)
        credit = operation.lines.reject(&.debit?).sum(zero, &.amount)
        if debit != credit
          errors << error("lines", "operation.unbalanced", {"debit" => Records.amount(debit), "credit" => Records.amount(credit),
                                                            "difference" => Records.amount((debit - credit).abs)})
        end
      end
      distributions = distributions(operation, errors)
      return unless errors.empty? && ledger
      input = Acc::EntryInput.new(ledger_id: ledger.id, date: operation.date, lines: lines, label: label(operation),
        due_date: operation.due_date, currency_code: operation.currency.presence, attachment_id: attachment_id,
        source: source)
      Planned.new("entry", ledger, entry: input, distributions: distributions)
    end

    # Ligne d'un FEC : le compte auxiliaire désigne la fiche (ou le compte
    # qu'on lui fait correspondre) ; sans compte auxiliaire, le compte
    # général, par sa correspondance ou son numéro.
    private def fec_target(line : Parsers::ParsedLine, index : Int32, errors : Array(FieldError)) : Target?
      unless line.aux.empty?
        if mapping = @mappings[{"code", line.aux.downcase}]?
          return Target.new(mapping.target_type.to_s, mapping.target.to_s)
        end
        return Target.new("card", line.aux) if card_code(line.aux, "lines[#{index}].aux", errors)
        errors << error("lines[#{index}].aux", "code.unknown", {"code" => line.aux, "label" => line.aux_label}) if errors.none?(&.field.==("lines[#{index}].aux"))
        return
      end
      if mapping = @mappings[{"code", line.code.downcase}]?
        return Target.new(mapping.target_type.to_s, mapping.target.to_s)
      end
      return Target.new("account", line.code) if account?(line.code, "lines[#{index}].code", errors)
      if errors.none?(&.field.==("lines[#{index}].code"))
        errors << error("lines[#{index}].code", "code.unknown_account", {"code" => line.code, "label" => line.code_label})
      end
      nil
    end

    # Compte ou fiche d'un CSV : correspondance, sinon fiche de ce quick
    # code, sinon compte de ce numéro.
    private def code_target(code : String, label : String, field : String, errors : Array(FieldError)) : Target?
      if mapping = @mappings[{"code", code.downcase}]?
        return Target.new(mapping.target_type.to_s, mapping.target.to_s)
      end
      if found = card_code(code, field, errors)
        return Target.new("card", found)
      end
      return Target.new("account", code) if account?(code, field, errors)
      errors << error(field, "code.unknown", {"code" => code, "label" => label}) if errors.none?(&.field.==(field))
      nil
    end

    private def card_code(code : String, field : String, errors : Array(FieldError)) : String?
      @cards.put_if_absent(code.downcase) { Partiduo::Api::Cards.card_by_code(@actor, code).try(&.code) }
    rescue ex : Partiduo::Api::AccessDenied
      errors << denied(field, ex)
      nil
    end

    private def account?(number : String, field : String, errors : Array(FieldError)) : Bool
      @accounts.put_if_absent(number) do
        Acc.account(@actor, number)
        true
      rescue Partiduo::Api::NotFound
        false
      end
    rescue ex : Partiduo::Api::AccessDenied
      errors << denied(field, ex)
      false
    end

    # --- Factures d'achat et de vente -------------------------------------------

    private def document(operation : Parsers::ParsedOperation, ledger : Acc::LedgerView?, errors : Array(FieldError),
                         source : String, attachment_id : Int64?) : Planned?
      third = code_target(operation.third_party, "", "third_party", errors) unless operation.third_party.empty?
      if operation.third_party.empty?
        errors << error("third_party", "third_party.blank")
      elsif third && third.type != "card"
        errors << error("third_party", "third_party.not_card", {"code" => operation.third_party})
      end
      lines = operation.lines.each_with_index.compact_map do |line, index|
        target = code_target(line.code, "", "lines[#{index}].code", errors)
        rate = vat_rate(line.vat_code, "lines[#{index}].vat_code", errors)
        next if target.nil?
        Acc::DocumentLineInput.new(amount: line.amount, item: target.type == "card" ? target.value : nil,
          account: target.type == "account" ? target.value : nil, vat_rate: rate, vat_amount: line.vat_amount,
          label: line.label, quantity: line.quantity)
      end.to_a
      distributions = distributions(operation, errors)
      return unless errors.empty? && ledger && third
      input = Acc::DocumentInput.new(ledger_id: ledger.id, date: operation.date, third_party: third.value, lines: lines,
        label: label(operation), due_date: operation.due_date, currency_code: operation.currency.presence,
        attachment_id: attachment_id, source: source)
      Planned.new(@ledger_kind, ledger, document: input, distributions: distributions)
    end

    # Code de TVA du dossier : correspondance, sinon code identique ; vide :
    # pas de TVA.
    private def vat_rate(code : String, field : String, errors : Array(FieldError)) : String?
      return if code.empty?
      target = @mappings[{"vat", code.downcase}]?.try(&.target.to_s) || code
      found = @rates.put_if_absent(target.downcase) { Partiduo::Api::Vat.rate_by_code(@actor, target).try(&.code) }
      errors << error(field, "vat.unknown", {"code" => code}) if found.nil?
      found
    rescue ex : Partiduo::Api::AccessDenied
      errors << denied(field, ex)
      nil
    end

    # --- Extraits financiers -------------------------------------------------------

    private def financial(operation : Parsers::ParsedOperation, ledger : Acc::LedgerView?, errors : Array(FieldError),
                          source : String, attachment_id : Int64?) : Planned?
      errors << error("lines", "operation.financial_lines") if operation.lines.size > 1
      unless operation.lines.all?(&.analytic.empty?)
        errors << error("lines", "analytic.financial")
      end
      lines = operation.lines.each_with_index.compact_map do |line, index|
        target = code_target(line.code, "", "lines[#{index}].code", errors) || next
        Acc::PaymentLineInput.new(line.amount, card: target.type == "card" ? target.value : nil,
          account: target.type == "account" ? target.value : nil, label: line.label.presence || label(operation))
      end.to_a
      return unless errors.empty? && ledger
      input = Acc::FinancialInput.new(ledger_id: ledger.id, date: operation.date, lines: lines,
        currency_code: operation.currency.presence, attachment_id: attachment_id, source: source)
      Planned.new("financial", ledger, financial: input)
    end

    # --- Analytique --------------------------------------------------------------------

    # Ventilation de chaque ligne entière : un poste par plan, désignés par
    # leur code (séparés par une espace, `/`, `|` ou `;`).
    private def distributions(operation : Parsers::ParsedOperation,
                              errors : Array(FieldError)) : Array(Analytic::InputDistributionInput)
      list = [] of Analytic::InputDistributionInput
      operation.lines.each_with_index do |line, index|
        next if line.analytic.empty?
        field = "lines[#{index}].analytic"
        unless Partiduo::Modules.active?(Analytic::MODULE_CODE)
          errors << error(field, "analytic.inactive")
          next
        end
        ids = line.analytic.split(/[\s\/|;]+/).reject(&.empty?).compact_map do |code|
          found = posts.select { |post| post.code.downcase == code.downcase }
          if found.empty?
            errors << error(field, "analytic.unknown", {"code" => code})
          elsif found.size > 1
            errors << error(field, "analytic.ambiguous", {"code" => code})
          end
          found.size == 1 ? found.first.id : nil
        end
        list << Analytic::InputDistributionInput.new(index, post_ids: ids) unless ids.empty?
      end
      list
    rescue ex : Partiduo::Api::AccessDenied
      errors << denied("lines", ex)
      [] of Analytic::InputDistributionInput
    end

    private def posts : Array(Analytic::PostView)
      @posts ||= Analytic.posts(@actor, active_only: true)
    end

    # --- Outils --------------------------------------------------------------------------

    private def label(operation : Parsers::ParsedOperation) : String
      operation.label.presence || operation.lines.first?.try(&.label) || ""
    end

    private def error(field : String, key : String, params = {} of String => String) : FieldError
      Records.error(field, key, params)
    end

    private def denied(field : String, ex : Partiduo::Api::AccessDenied) : FieldError
      case ex
      when Partiduo::Api::ModuleDisabled then error(field, "access.module", {"module" => ex.module_code})
      when Partiduo::Api::Forbidden      then error(field, "access.forbidden", {"permission" => ex.permission.to_s})
      else                                    error(field, "access.forbidden", {"permission" => ""})
      end
    end
  end
end
