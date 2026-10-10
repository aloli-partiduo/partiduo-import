# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Lecture des enregistrements et construction des vues du contrat
  # (interne).
  module Records
    alias Api = Import::Api
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      FieldError.new(field, "import.errors.#{key}", params)
    end

    # Montant d'un message, à deux décimales au moins, point décimal
    # (l'interface le présente dans la langue de l'utilisateur).
    def self.amount(value : BigDecimal) : String
      cents = (value.abs * 100).round.to_big_i
      "#{value < 0 ? "-" : ""}#{cents // 100}.#{(cents % 100).to_s.rjust(2, '0')}"
    end

    # --- Recherche ---------------------------------------------------------------

    def self.format!(id : Int64) : Format
      Format.filter(id: id).first || raise Partiduo::Api::NotFound.new("import_format", id)
    end

    def self.mapping!(id : Int64) : Mapping
      Mapping.filter(id: id).first || raise Partiduo::Api::NotFound.new("import_mapping", id)
    end

    def self.batch!(id : Int64) : Batch
      Batch.filter(id: id).first || raise Partiduo::Api::NotFound.new("import_batch", id)
    end

    # Opération visible de l'acteur (journal retenu visible, ou pas encore
    # de journal) ; `NotFound` sinon.
    def self.operation!(actor : Partiduo::Api::Actor, id : Int64, lock : Bool = false) : Operation
      query = Operation.filter(id: id)
      query = query.lock if lock
      row = query.first
      raise Partiduo::Api::NotFound.new("import_operation", id) if row.nil? || !visible?(actor, row)
      row
    end

    # Journaux visibles de l'acteur (droits par journal du socle) ; l'acteur
    # système les voit tous.
    def self.visible_ledgers(actor : Partiduo::Api::Actor) : Array(Acc::LedgerView)
      Acc.ledgers(actor)
    rescue Partiduo::Api::AccessDenied
      [] of Acc::LedgerView
    end

    def self.visible_ledger_ids(actor : Partiduo::Api::Actor) : Array(Int64)
      visible_ledgers(actor).map(&.id)
    end

    def self.visible?(actor : Partiduo::Api::Actor, row : Operation, ids : Array(Int64)? = nil) : Bool
      ledger_id = row.ledger_id.try(&.to_i64) || return true
      (ids || visible_ledger_ids(actor)).includes?(ledger_id)
    end

    # Opérations visibles : journal retenu visible, ou pas encore de journal
    # (opération jamais vérifiée, ou journal inconnu).
    def self.visible_operations(actor : Partiduo::Api::Actor)
      ids = visible_ledger_ids(actor)
      Operation.filter { q(ledger_id__in: ids) | q(ledger_id__isnull: true) }
    end

    # --- Motifs (JSON) -----------------------------------------------------------

    def self.dump(errors : Array(FieldError)) : String
      return "" if errors.empty?
      errors.map { |error| {"field" => error.field, "key" => error.key, "params" => error.params} }.to_json
    end

    def self.load(text : String?) : Array(FieldError)
      value = text.to_s
      return [] of FieldError if value.empty?
      JSON.parse(value).as_a.map do |item|
        params = item["params"]?.try(&.as_h.transform_values(&.as_s)) || {} of String => String
        FieldError.new(item["field"].as_s, item["key"].as_s, params)
      end
    rescue JSON::ParseException | TypeCastError
      [] of FieldError
    end

    def self.issues_to_errors(issues : Array(Parsers::Issue)) : Array(FieldError)
      issues.map(&.to_error)
    end

    # --- Données d'une opération ----------------------------------------------

    # Opération enregistrée relue comme une opération lue, pour la vérifier
    # ou la transférer.
    def self.data(row : Operation, lines : Array(OperationLine)? = nil) : Parsers::ParsedOperation
      operation = Parsers::ParsedOperation.new(row.position!.to_i32, row.group_key.to_s, row.date!)
      operation.ledger_code = row.ledger_code.to_s
      operation.receipt = row.receipt.to_s
      operation.label = row.label.to_s
      operation.due_date = row.due_date
      operation.third_party = row.third_party.to_s
      operation.currency = row.currency.to_s
      (lines || OperationLine.filter(operation_id: row.id).order(:position).to_a).each do |item|
        line = Parsers::ParsedLine.new(item.row!.to_i32, item.code.to_s)
        line.code_label = item.code_label.to_s
        line.aux = item.aux.to_s
        line.aux_label = item.aux_label.to_s
        line.label = item.label.to_s
        line.side = item.side.to_s
        line.amount = item.amount!
        line.quantity = item.quantity
        line.vat_code = item.vat_code.to_s
        line.vat_amount = item.vat_amount
        line.analytic = item.analytic.to_s
        line.letter = item.letter.to_s
        operation.lines << line
      end
      operation
    end

    # --- Vues --------------------------------------------------------------------

    def self.format_view(row : Format) : Api::FormatView
      Api::FormatView.new(
        id: row.id!.to_i64, name: row.name.to_s, description: row.description.to_s, ledger_kind: row.ledger_kind.to_s,
        ledger_id: row.ledger_id.try(&.to_i64), separator: row.separator.to_s, quote: row.quote.to_s,
        encoding: row.encoding.to_s, skip_lines: row.skip_lines!.to_i32, date_format: row.date_format.to_s,
        decimal_separator: row.decimal_separator.to_s, thousands_separator: row.thousands_separator.to_s,
        columns: Parsers::Fields.parse_map(row.column_map.to_s), batch_count: Batch.filter(format_id: row.id).count.to_i32,
      )
    end

    def self.settings(row : Format) : Parsers::CsvSettings
      Parsers::CsvSettings.new(
        ledger_kind: row.ledger_kind.to_s, columns: Parsers::Fields.parse_map(row.column_map.to_s),
        separator: row.separator.to_s, quote: row.quote.to_s, encoding: row.encoding.to_s,
        skip_lines: row.skip_lines!.to_i32, date_format: row.date_format.to_s,
        decimal_separator: row.decimal_separator.to_s, thousands_separator: row.thousands_separator.to_s,
      )
    end

    def self.mapping_view(actor : Partiduo::Api::Actor, row : Mapping) : Api::MappingView
      Api::MappingView.new(
        id: row.id!.to_i64, kind: row.kind.to_s, source: row.source.to_s, target_type: row.target_type.to_s,
        target: row.target.to_s, target_label: target_label(actor, row.target_type.to_s, row.target.to_s),
        note: row.note.to_s,
      )
    end

    # Nom de la cible d'une correspondance, relu par le contrat du cœur ;
    # `nil` si elle n'existe plus ou si l'acteur ne peut pas la lire.
    def self.target_label(actor : Partiduo::Api::Actor, target_type : String, target : String) : String?
      case target_type
      when "ledger"  then Acc.ledger_by_code(actor, target).name
      when "vat"     then Partiduo::Api::Vat.rate_by_code(actor, target).try(&.label)
      when "account" then Acc.account(actor, target).label
      when "card"    then Partiduo::Api::Cards.card_by_code(actor, target).try(&.name)
      end
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      nil
    end

    def self.line_view(row : OperationLine) : Api::OperationLineView
      Api::OperationLineView.new(
        position: row.position!.to_i32, row: row.row!.to_i32, code: row.code.to_s, code_label: row.code_label.to_s,
        aux: row.aux.to_s, aux_label: row.aux_label.to_s, label: row.label.to_s, side: row.side.to_s,
        amount: row.amount!, quantity: row.quantity, vat_code: row.vat_code.to_s, vat_amount: row.vat_amount,
        analytic: row.analytic.to_s, letter: row.letter.to_s, entry_line_id: row.entry_line_id.try(&.to_i64),
      )
    end

    def self.parsed_line_view(line : Parsers::ParsedLine, position : Int32) : Api::OperationLineView
      Api::OperationLineView.new(
        position: position, row: line.row, code: line.code, code_label: line.code_label, aux: line.aux,
        aux_label: line.aux_label, label: line.label, side: line.side, amount: line.amount, quantity: line.quantity,
        vat_code: line.vat_code, vat_amount: line.vat_amount, analytic: line.analytic, letter: line.letter,
        entry_line_id: nil,
      )
    end

    def self.operation_views(rows : Array(Operation)) : Array(Api::OperationView)
      return [] of Api::OperationView if rows.empty?
      ids = rows.map(&.id!.to_i64)
      lines = OperationLine.filter(operation_id__in: ids).order(:position).to_a.group_by(&.operation_id!.to_i64)
      batches = Batch.filter(id__in: rows.map(&.batch_id!.to_i64).uniq!).to_a.index_by(&.id!.to_i64)
      rows.map do |row|
        batch = batches[row.batch_id!.to_i64]
        Api::OperationView.new(
          id: row.id!.to_i64, batch_id: row.batch_id!.to_i64, batch_kind: batch.kind.to_s,
          ledger_kind: batch.ledger_kind.to_s, position: row.position!.to_i32, group_key: row.group_key.to_s,
          ledger_code: row.ledger_code.to_s, ledger_id: row.ledger_id.try(&.to_i64), date: row.date!,
          receipt: row.receipt.to_s, label: row.label.to_s, due_date: row.due_date, third_party: row.third_party.to_s,
          currency: row.currency.to_s, total: row.total!, status: row.status.to_s,
          duplicate_of_id: row.duplicate_of_id.try(&.to_i64), recorded_entry_id: row.recorded_entry_id.try(&.to_i64),
          entry_id: row.entry_id.try(&.to_i64), posted_receipt: row.posted_receipt.to_s,
          reversed_entry_id: row.reversed_entry_id.try(&.to_i64), problems: load(row.problems),
          read_problems: load(row.read_problems), checked_at: row.checked_at,
          lines: (lines[row.id!.to_i64]? || [] of OperationLine).map { |line| line_view(line) },
        )
      end
    end

    def self.operation_view(row : Operation) : Api::OperationView
      operation_views([row]).first
    end

    def self.batch_views(rows : Array(Batch)) : Array(Api::BatchView)
      return [] of Api::BatchView if rows.empty?
      ids = rows.map(&.id!.to_i64)
      operations = Operation.filter(batch_id__in: ids).to_a.group_by(&.batch_id!.to_i64)
      letter_counts = letter_counts(ids)
      formats = Format.filter(id__in: rows.compact_map(&.format_id)).to_a.to_h { |row| {row.id!.to_i64, row.name.to_s} }
      zero = BigDecimal.new(0)
      rows.map do |row|
        id = row.id!.to_i64
        own = operations[id]? || [] of Operation
        kept = own.reject(&.status.in?("duplicate", "discarded"))
        dates = own.map(&.date!)
        pending = own.select(&.status.==("pending"))
        Api::BatchView.new(
          id: id, kind: row.kind.to_s, ledger_kind: row.ledger_kind.to_s, format_id: row.format_id.try(&.to_i64),
          format_name: row.format_id.try { |format_id| formats[format_id.to_i64]? }, ledger_id: row.ledger_id.try(&.to_i64),
          filename: row.filename.to_s, attachment_id: row.attachment_id.try(&.to_i64), encoding: row.encoding.to_s,
          operation_count: own.size, pending_count: pending.size,
          refused_count: pending.count { |operation| !operation.problems.to_s.empty? || !operation.read_problems.to_s.empty? },
          transferred_count: own.count(&.status.==("transferred")), duplicate_count: own.count(&.status.==("duplicate")),
          discarded_count: own.count(&.status.==("discarded")), first_date: dates.min?, last_date: dates.max?,
          total: kept.sum(zero, &.total!), issues: load(row.issues), letter_count: letter_counts[id]? || 0,
          created_by_id: row.created_by_id.try(&.to_i64), created_at: row.created_at || Time.utc,
        )
      end
    end

    # Lignes porteuses d'un code de lettrage, par import.
    private def self.letter_counts(batch_ids : Array(Int64)) : Hash(Int64, Int32)
      operations = Operation.filter(batch_id__in: batch_ids).to_a.to_h { |row| {row.id!.to_i64, row.batch_id!.to_i64} }
      return {} of Int64 => Int32 if operations.empty?
      counts = {} of Int64 => Int32
      OperationLine.filter(operation_id__in: operations.keys).exclude(letter: "").each do |line|
        batch_id = operations[line.operation_id!.to_i64]
        counts[batch_id] = (counts[batch_id]? || 0) + 1
      end
      counts
    end
  end
end
