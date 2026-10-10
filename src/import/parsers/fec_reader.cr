# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Parsers
    # Lecture d'un fichier des écritures comptables (article A47 A-1 du livre
    # des procédures fiscales, arrêté du 29 juillet 2013), pour reprendre
    # dans un dossier *existant* des écritures venues d'un autre logiciel
    # (D-IMP-011). Première ligne d'en-tête ; zones reconnues par leur nom,
    # sans égard à la casse ; séparateur tabulation, barre verticale ou
    # point-virgule ; dates `AAAAMMJJ` ; montants à virgule (point toléré) ;
    # `Debit` et `Credit`, ou `Montant` et `Sens`. Les lignes d'un même
    # `EcritureNum` dans un même `JournalCode` forment une opération ; débit
    # et crédit d'une même ligne sont soldés ; une ligne sans montant est
    # ignorée. `Montantdevise` et `Idevise` ne sont pas repris : les montants
    # du FEC sont dans la monnaie de tenue.
    module FecReader
      REQUIRED  = %w[JournalCode EcritureNum EcritureDate CompteNum]
      DUE_DATES = %w[DateEcheance EcheanceDate DateEch]

      def self.parse(bytes : Bytes, encoding : String = "auto") : Parsed
        parsed = Parsed.new
        text, parsed.encoding = Text.decode(bytes, encoding)
        lines = text.split(/\r\n|\n|\r/)
        while lines.last?.try(&.strip.empty?)
          lines.pop
        end
        header = Header.read(parsed, lines.first?) || return parsed
        groups = {} of {String, String} => ParsedOperation
        lines.each_with_index(1) do |raw, number|
          next if number == 1 || raw.strip.empty?
          fields = header.fields(raw)
          if fields.size != header.size
            parsed.issue(number, "fec.field_count", {"count" => fields.size.to_s, "expected" => header.size.to_s})
            next
          end
          read_line(parsed, groups, Row.new(fields, header.index, number), number)
        end
        parsed.issue(0, "file.empty") if parsed.operations.empty? && parsed.issues.empty?
        parsed
      end

      # En-tête du fichier : séparateur, position de chaque zone, séparateur
      # terminal toléré.
      private class Header
        getter index : Hash(String, Int32)
        getter size : Int32

        def initialize(@separator : Char, names : Array(String), @trailing : Bool)
          @size = names.size
          @index = names.each_with_index.to_h { |name, position| {name.downcase, position} }
        end

        def self.read(parsed : Parsed, line : String?) : Header?
          if line.nil? || line.strip.empty?
            parsed.issue(0, "file.empty")
            return
          end
          separator = {'\t', '|', ';'}.find { |char| line.includes?(char) }
          if separator.nil?
            parsed.issue(0, "fec.separator")
            return
          end
          names = FecReader.split(line, separator)
          trailing = names.size > 1 && names.last.empty?
          names.pop if trailing
          header = new(separator, names, trailing)
          missing = header.missing
          return header if missing.empty?
          parsed.issue(0, "fec.columns", {"columns" => missing.join(", ")})
          nil
        end

        def missing : Array(String)
          list = REQUIRED.reject { |name| @index.has_key?(name.downcase) }
          amounts = (@index.has_key?("debit") && @index.has_key?("credit")) || (@index.has_key?("montant") && @index.has_key?("sens"))
          list << "Debit/Credit" unless amounts
          list
        end

        # Zones d'une ligne ; un séparateur terminal annoncé par l'en-tête est
        # retiré.
        def fields(line : String) : Array(String)
          values = FecReader.split(line, @separator)
          values.pop if @trailing && values.size == @size + 1 && values.last.empty?
          values
        end
      end

      protected def self.split(line : String, separator : Char) : Array(String)
        line.split(separator).map do |value|
          value = value.strip
          value.size >= 2 && value.starts_with?('"') && value.ends_with?('"') ? value[1..-2].gsub("\"\"", "\"") : value
        end
      end

      # Zones d'une ligne, lues par nom, avec ses défauts de lecture.
      private class Row
        getter problems = [] of Issue

        def initialize(@fields : Array(String), @index : Hash(String, Int32), @number : Int32)
        end

        def [](name : String) : String
          @index[name.downcase]?.try { |position| @fields[position]? } || ""
        end

        def has?(name : String) : Bool
          @index.has_key?(name.downcase)
        end

        def problem(key : String, params = {} of String => String) : Nil
          @problems << Issue.new(@number, "import.errors.#{key}", params)
        end

        def text(name : String, max : Int32 = 255) : String
          Parsers.clean(self[name], max)
        end

        # Zone obligatoire : vide, elle est un défaut.
        def required(name : String) : String
          value = text(name, 100)
          problem("fec.blank", {"column" => name}) if value.empty?
          value
        end

        def amount(name : String) : BigDecimal
          raw = self[name]
          return BigDecimal.new(0) if raw.strip.empty?
          value = Amounts.parse(raw, nil, nil)
          problem("line.amount", {"value" => raw}) if value.nil?
          value || BigDecimal.new(0)
        end

        # Débit et crédit bruts (`Debit`/`Credit`, ou `Montant` et `Sens`).
        def debit_credit : {BigDecimal, BigDecimal}
          zero = BigDecimal.new(0)
          return {amount("Debit"), amount("Credit")} if has?("Debit")
          value = amount("Montant")
          case Parsers.side(self["Sens"])
          when "debit"  then {value, zero}
          when "credit" then {zero, value}
          else
            problem("line.side", {"value" => self["Sens"]})
            {zero, zero}
          end
        end

        # Échéance d'une zone facultative reconnue (`DUE_DATES`).
        def due_date : Time?
          DUE_DATES.each do |name|
            next unless has?(name)
            raw = self[name].strip
            next if raw.empty?
            found = Dates.compact(raw)
            problem("line.due_date", {"value" => raw}) if found.nil?
            return found
          end
          nil
        end
      end

      private def self.read_line(parsed : Parsed, groups : Hash({String, String}, ParsedOperation), row : Row,
                                 number : Int32) : Nil
        journal = row.required("JournalCode")[0, 50]
        entry_number = row.required("EcritureNum")
        account = row.required("CompteNum")
        date = Dates.compact(row["EcritureDate"]) || Dates.parse(row["EcritureDate"], "yyyy-mm-dd")
        row.problem("line.date", {"value" => row["EcritureDate"]}) if date.nil?
        debit, credit = row.debit_credit
        net = debit - credit
        # Ligne sans effet : ignorée, comme le fait l'export d'origine.
        return if net.zero? && row.problems.empty?

        line = ParsedLine.new(number, account)
        line.code_label = row.text("CompteLib")
        line.aux = row.text("CompAuxNum", 100)
        line.aux_label = row.text("CompAuxLib")
        line.label = row.text("EcritureLib")
        line.side = net >= 0 ? "debit" : "credit"
        line.amount = net.abs
        line.letter = row.text("EcritureLet", 50)

        key = {journal, entry_number}
        operation = groups[key]?
        if operation.nil?
          return parsed.issues.concat(row.problems) if date.nil? || journal.empty? || entry_number.empty?
          operation = ParsedOperation.new(number, entry_number, date)
          operation.ledger_code = journal
          operation.receipt = row.text("PieceRef", 100)
          operation.label = line.label
          operation.due_date = row.due_date
          groups[key] = operation
          parsed.operations << operation
        elsif date && date != operation.date
          row.problem("line.date_mismatch", {"value" => row["EcritureDate"]})
        end
        operation.lines << line
        operation.problems.concat(row.problems)
        parsed.issues.concat(row.problems)
      end
    end
  end
end
