# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Parsers
    # Champs qu'une colonne d'un CSV peut alimenter, par genre de journal
    # (D-IMP-005) — héritiers des colonnes fixes de l'application d'origine,
    # dans l'ordre qu'on veut. Libellé : `import.fields.<clé>`.
    module Fields
      LEDGER_KINDS = %w[purchase sale financial misc]

      ALL = %w[date ledger group receipt label currency due_date third_party account line_label amount side debit
        credit quantity vat_code vat_amount amount_incl analytic]

      ALLOWED = {
        "misc" => %w[date ledger group receipt label currency due_date account line_label amount side debit credit vat_code
          analytic],
        "purchase" => %w[date ledger group receipt label currency due_date third_party account line_label quantity amount
          vat_code vat_amount amount_incl analytic],
        "sale" => %w[date ledger group receipt label currency due_date third_party account line_label quantity amount
          vat_code vat_amount amount_incl analytic],
        "financial" => %w[date ledger group receipt label currency account line_label amount analytic],
      }

      REQUIRED = {
        "misc"      => %w[date account],
        "purchase"  => %w[date third_party account amount],
        "sale"      => %w[date third_party account amount],
        "financial" => %w[date account amount],
      }

      # Correspondance d'un format, colonne par colonne (`""` : ignorée).
      def self.parse_map(text : String) : Array(String)
        text.split(',').map(&.strip)
      end

      def self.dump_map(columns : Array(String)) : String
        columns.map(&.strip).join(',')
      end

      # Erreurs de la correspondance des colonnes pour un genre de journal :
      # champ inconnu ou d'un autre genre, champ en double, champ exigé
      # absent, montant des opérations diverses (montant et sens, ou débit
      # et crédit).
      def self.errors(kind : String, columns : Array(String)) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        allowed = ALLOWED[kind]? || return errors
        used = columns.reject(&.empty?)
        used.each_with_index do |name, index|
          if !allowed.includes?(name)
            errors << error("not_allowed", {"field" => name})
          elsif used.index(name) != index
            errors << error("repeated", {"field" => name})
          end
        end
        REQUIRED[kind].each { |name| errors << error("missing", {"field" => name}) unless used.includes?(name) }
        misc_errors(used, errors) if kind == "misc"
        errors
      end

      # Montant d'une opération diverse : montant et sens, ou débit et
      # crédit.
      private def self.misc_errors(used : Array(String), errors : Array(Partiduo::Api::FieldError)) : Nil
        amount = used.includes?("amount")
        if amount && (used.includes?("debit") || used.includes?("credit"))
          errors << error("amount_both")
        elsif amount && !used.includes?("side")
          errors << error("missing", {"field" => "side"})
        elsif !amount && !(used.includes?("debit") && used.includes?("credit"))
          errors << error("amount_missing")
        end
      end

      private def self.error(key : String, params = {} of String => String) : Partiduo::Api::FieldError
        Partiduo::Api::FieldError.new("columns", "import.errors.format.columns.#{key}", params)
      end
    end
  end
end
