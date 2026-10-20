# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Parsers
    # Réglages de lecture d'un CSV (copie d'un `Format`).
    record CsvSettings,
      ledger_kind : String,
      columns : Array(String),
      separator : String = "semicolon",
      quote : String = "double",
      encoding : String = "utf-8",
      skip_lines : Int32 = 1,
      date_format : String = "dd/mm/yyyy",
      decimal_separator : String = "comma",
      thousands_separator : String = "none"

    # Lecture d'un CSV d'opérations selon son format (D-IMP-005) : lignes
    # d'en-tête sautées, lignes vides ignorées, cellules lues par la
    # correspondance des colonnes, lignes regroupées en opérations — par le
    # code de regroupement, à défaut par la pièce, à défaut chaque ligne
    # seule — dans un même code de journal. Une ligne illisible bloque son
    # opération (`ParsedOperation#problems`) : rien n'est retranché en
    # silence d'une facture ou d'une écriture.
    module CsvReader
      SEPARATORS = {"comma" => ',', "semicolon" => ';', "tab" => '\t', "pipe" => '|'}
      QUOTES     = {"double" => '"', "single" => '\'', "none" => '\u0000'}

      def self.parse(bytes : Bytes, settings : CsvSettings) : Parsed
        parsed = Parsed.new
        text, parsed.encoding = Text.decode(bytes, settings.encoding)
        rows = begin
          CSV.parse(text, separator: SEPARATORS[settings.separator]? || ';', quote_char: QUOTES[settings.quote]? || '"')
        rescue ex : CSV::MalformedCSVError
          parsed.issue(0, "file.malformed_csv", {"detail" => ex.message.to_s})
          return parsed
        end
        groups = {} of {String, String} => ParsedOperation
        rows.each_with_index(1) do |cells, number|
          next if number <= settings.skip_lines
          next if cells.all?(&.strip.empty?)
          read_row(parsed, groups, cells, number, settings)
        end
        parsed.issue(0, "file.empty") if parsed.operations.empty? && parsed.issues.empty?
        parsed
      end

      # Premières lignes découpées, pour régler un format sur un fichier
      # d'exemple.
      def self.sample(bytes : Bytes, separator : String, quote : String, encoding : String, rows : Int32 = 8) : Array(Array(String))
        text, _ = Text.decode(bytes, encoding)
        CSV.parse(text, separator: SEPARATORS[separator]? || ';', quote_char: QUOTES[quote]? || '"').first(rows)
      rescue CSV::MalformedCSVError
        [] of Array(String)
      end

      # Une ligne du fichier, lue par champ, avec ses défauts de lecture.
      private class Row
        getter problems = [] of Issue
        getter? unreadable = false
        @decimal : Char
        @thousands : Char?

        def initialize(@cells : Array(String), @settings : CsvSettings, @number : Int32)
          @decimal = Amounts::SEPARATORS[@settings.decimal_separator]? || ','
          @thousands = Amounts::THOUSANDS[@settings.thousands_separator]?
        end

        def [](name : String) : String
          index = @settings.columns.index(name) || return ""
          @cells[index]?.try(&.strip) || ""
        end

        def has?(name : String) : Bool
          @settings.columns.includes?(name)
        end

        def problem(key : String, params = {} of String => String) : Nil
          @problems << Issue.new(@number, "import.errors.#{key}", params)
        end

        def date(name : String, key : String) : Time?
          text = self[name]
          return if text.empty?
          found = Dates.parse(text, @settings.date_format)
          problem(key, {"value" => text}) if found.nil?
          found
        end

        # Montant d'une cellule ; `nil` si elle est vide ou illisible (défaut
        # noté).
        def amount(name : String, required : Bool = false) : BigDecimal?
          text = self[name]
          value = text.empty? ? nil : Amounts.parse(text, @decimal, @thousands)
          if value.nil? && (required || !text.empty?)
            @unreadable = true
            problem("line.amount", {"value" => text})
          end
          value
        end
      end

      private def self.read_row(parsed : Parsed, groups : Hash({String, String}, ParsedOperation), raw : Array(String),
                                number : Int32, settings : CsvSettings) : Nil
        row = Row.new(raw, settings, number)
        row.problem("line.date", {"value" => row["date"]}) if row["date"].empty?
        date = row.date("date", "line.date")
        code = Parsers.clean(row["account"], 100)
        row.problem("line.account_blank") if code.empty?
        line = ParsedLine.new(number, code)
        line.label = Parsers.clean(row["line_label"])
        line.analytic = Parsers.clean(row["analytic"], 100)
        case settings.ledger_kind
        when "misc"             then misc_amounts(line, row)
        when "purchase", "sale" then document_amounts(line, row)
        else                         financial_amount(line, row)
        end

        ledger = Parsers.clean(row["ledger"], 50)
        key = Parsers.clean(row["group"], 100).presence || Parsers.clean(row["receipt"], 100).presence || "##{number}"
        operation = groups[{ledger, key}]?
        if operation.nil?
          # Sans date, l'opération ne peut pas être gardée : la ligne est
          # signalée au fichier.
          return parsed.issues.concat(row.problems) if date.nil?
          operation = new_operation(row, number, key, ledger, date)
          groups[{ledger, key}] = operation
          parsed.operations << operation
        elsif date && date != operation.date
          row.problem("line.date_mismatch", {"value" => row["date"]})
        end
        operation.label = line.label if operation.label.empty?
        operation.lines << line
        operation.problems.concat(row.problems)
        parsed.issues.concat(row.problems)
      end

      # En-tête de l'opération, lu sur sa première ligne.
      private def self.new_operation(row : Row, number : Int32, key : String, ledger : String, date : Time) : ParsedOperation
        operation = ParsedOperation.new(number, key, date)
        operation.ledger_code = ledger
        operation.receipt = Parsers.clean(row["receipt"], 100)
        operation.label = Parsers.clean(row["label"])
        operation.third_party = Parsers.clean(row["third_party"], 100)
        operation.currency = Parsers.clean(row["currency"], 3).upcase
        operation.due_date = row.date("due_date", "line.due_date")
        row.problem("line.third_party_blank") if row.has?("third_party") && operation.third_party.empty?
        operation
      end

      # Opérations diverses : montant et sens (un montant négatif inverse le
      # sens), ou débit moins crédit ; code de TVA facultatif de la ligne
      # (D-IMP-017).
      private def self.misc_amounts(line : ParsedLine, row : Row) : Nil
        zero = BigDecimal.new(0)
        line.vat_code = Parsers.clean(row["vat_code"], 20)
        if row.has?("amount")
          value = row.amount("amount", required: true) || zero
          side = Parsers.side(row["side"])
          row.problem("line.side", {"value" => row["side"]}) if side.nil?
          line.side = signed_side(side, value)
          line.amount = value.abs
        else
          net = (row.amount("debit") || zero) - (row.amount("credit") || zero)
          line.side = net >= zero ? "debit" : "credit"
          line.amount = net.abs
        end
        row.problem("line.zero") if line.amount.zero? && !row.unreadable?
      end

      # Sens lu, inversé par un montant négatif ; vide s'il est illisible.
      private def self.signed_side(side : String?, value : BigDecimal) : String
        return "" if side.nil?
        return side unless value < 0
        side == "debit" ? "credit" : "debit"
      end

      # Achats, ventes : hors taxe, quantité, code et montant de TVA (ou toutes
      # taxes, dont la TVA est déduite).
      private def self.document_amounts(line : ParsedLine, row : Row) : Nil
        line.amount = row.amount("amount", required: true) || BigDecimal.new(0)
        line.quantity = row.amount("quantity")
        line.vat_code = Parsers.clean(row["vat_code"], 20)
        line.vat_amount = row.amount("vat_amount")
        if line.vat_amount.nil? && (incl = row.amount("amount_incl"))
          line.vat_amount = incl - line.amount
        end
      end

      # Financier : montant signé, positif pour une entrée en banque.
      private def self.financial_amount(line : ParsedLine, row : Row) : Nil
        line.amount = row.amount("amount", required: true) || BigDecimal.new(0)
        row.problem("line.zero") if line.amount.zero? && !row.unreadable?
      end
    end
  end
end
