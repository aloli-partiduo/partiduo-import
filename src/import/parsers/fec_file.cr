# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Parsers
    # Fichier des écritures comptables lu par le lecteur commun du cœur
    # (`Partiduo::Api::Accounting.read_fec`, contrat 0.14.0, D-IMP-016),
    # traduit en `Parsed` pour la zone d'attente : une opération par
    # écriture (`JournalCode` et `EcritureNum`), ses lignes dans l'ordre du
    # fichier, chaque ligne soldée d'un seul côté. Les défauts du lecteur
    # gardent leur clé (`accounting.fec_reader.issues.*`, traduite par le
    # cœur) :
    #
    # * en-tête, encodage, fichier vide ou sans écriture : le fichier entier
    #   est refusé ;
    # * défaut d'une ligne : la ligne est écartée par le lecteur ; le défaut
    #   est rendu avec le fichier *et* bloque l'opération qui la contenait
    #   (désignée par le défaut, sinon par le rang de ses lignes), qui ne
    #   sera jamais transférée (D-IMP-007) ;
    # * écriture déséquilibrée : laissée à l'import, qui la refuse avec son
    #   motif nommé (`operation.unbalanced`, débit, crédit, écart).
    #
    # Libellés et codes ramenés à une ligne et bornés comme ceux d'un CSV.
    module FecFile
      alias Acc = Partiduo::Api::Accounting

      # Encodage choisi à l'import → encodage demandé au lecteur (`nil` :
      # reconnu).
      def self.encoding(choice : String) : String?
        choice == "auto" ? nil : choice
      end

      # Encodage retenu par le lecteur → code de l'import
      # (`import.encodings.<code>`) ; l'ASCII est de l'UTF-8.
      def self.encoding_code(name : String) : String
        code = name.downcase
        code == "ascii" ? "utf-8" : code
      end

      def self.parsed(view : Acc::FecFileView) : Parsed
        parsed = Parsed.new
        parsed.encoding = encoding_code(view.encoding)
        view.issues.each do |issue|
          next if issue.key.ends_with?(".unbalanced")
          parsed.issues << Issue.new(issue.row <= 1 ? 0 : issue.row, issue.key, issue.params)
        end
        view.warnings.each { |warning| parsed.issues << Issue.new(warning.row, warning.key, warning.params, warning: true) }
        return parsed if parsed.fatal?
        view.entries.each { |entry| parsed.operations << operation(entry) }
        attach(parsed, view)
        parsed
      end

      private def self.operation(entry : Acc::FecEntryView) : ParsedOperation
        operation = ParsedOperation.new(entry.row, Parsers.clean(entry.number, 100), entry.date)
        operation.ledger_code = Parsers.clean(entry.journal_code, 50)
        operation.receipt = Parsers.clean(entry.receipt, 100)
        operation.label = Parsers.clean(entry.label)
        operation.due_date = entry.due_date
        items = entry.lines
        items.each do |item|
          line = ParsedLine.new(item.row, Parsers.clean(item.account_number, 100))
          line.code_label = Parsers.clean(item.account_label)
          line.aux = Parsers.clean(item.aux_number || "", 100)
          line.aux_label = Parsers.clean(item.aux_label || "")
          line.label = Parsers.clean(item.label)
          line.side = item.debit > 0 ? "debit" : "credit"
          line.amount = item.debit > 0 ? item.debit : item.credit
          line.letter = Parsers.clean(item.letter || "", 50)
          operation.lines << line
        end
        operation
      end

      # Défauts de ligne rattachés à leur opération : celle que le défaut
      # nomme (`<journal>/<numéro>`), sinon celle dont les lignes encadrent
      # la ligne écartée.
      private def self.attach(parsed : Parsed, view : Acc::FecFileView) : Nil
        parsed.issues.each do |issue|
          next if issue.row.zero? || issue.warning
          index = issue.params["entry"]?.try { |reference| view.entries.index(&.reference.==(reference)) }
          index ||= view.entries.index do |entry|
            rows = entry.lines.map(&.row)
            rows.min <= issue.row <= rows.max
          end
          parsed.operations[index].problems << issue if index
        end
      end
    end
  end
end
