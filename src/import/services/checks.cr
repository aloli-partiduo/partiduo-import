# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Contrôles des formats et des correspondances (interne).
  module Checks
    alias Api = Import::Api
    alias FieldError = Partiduo::Api::FieldError

    def self.format_errors(actor : Partiduo::Api::Actor, input : Api::FormatInput, id : Int64?) : Array(FieldError)
      errors = [] of FieldError
      name = input.name.strip
      if name.empty?
        errors << Records.error("name", "format.name.blank")
      elsif name.size > 100
        errors << Records.error("name", "format.name.too_long", {"max" => "100"})
      elsif Format.all.to_a.any? { |row| row.name.to_s.downcase == name.downcase && row.id != id }
        errors << Records.error("name", "format.name.taken")
      end
      errors << Records.error("description", "format.description.too_long", {"max" => "255"}) if input.description.size > 255
      reading_errors(input, errors)
      column_errors(input, errors)
      ledger_errors(actor, input, errors)
      errors
    end

    # Réglages de lecture : valeurs admises, séparateurs distincts, lignes
    # d'en-tête.
    private def self.reading_errors(input : Api::FormatInput, errors : Array(FieldError)) : Nil
      choice(errors, "ledger_kind", input.ledger_kind, Api::LEDGER_KINDS)
      choice(errors, "separator", input.separator, Api::SEPARATORS)
      choice(errors, "quote", input.quote, Api::QUOTES)
      choice(errors, "encoding", input.encoding, Api::ENCODINGS)
      choice(errors, "date_format", input.date_format, Api::DATE_FORMATS)
      choice(errors, "decimal_separator", input.decimal_separator, Api::DECIMAL_SEPARATORS)
      choice(errors, "thousands_separator", input.thousands_separator, Api::THOUSANDS_SEPARATORS)
      if input.thousands_separator == input.decimal_separator
        errors << Records.error("thousands_separator", "format.thousands_separator.same")
      end
      errors << Records.error("skip_lines", "format.skip_lines.range") unless (0..50).includes?(input.skip_lines)
    end

    private def self.column_errors(input : Api::FormatInput, errors : Array(FieldError)) : Nil
      if input.columns.size > Api::MAX_COLUMNS
        errors << Records.error("columns", "format.columns.too_many", {"max" => Api::MAX_COLUMNS.to_s})
      elsif input.columns.any?(&.includes?(','))
        errors << Records.error("columns", "choice.invalid", {"value" => input.columns.join(" ")})
      elsif Api::LEDGER_KINDS.includes?(input.ledger_kind)
        errors.concat(Parsers::Fields.errors(input.ledger_kind, input.columns))
      end
    end

    # Journal proposé : visible de l'acteur et du genre du format.
    private def self.ledger_errors(actor : Partiduo::Api::Actor, input : Api::FormatInput, errors : Array(FieldError)) : Nil
      if ledger_id = input.ledger_id
        ledger = Records.visible_ledgers(actor).find(&.id.==(ledger_id))
        if ledger.nil?
          errors << Records.error("ledger_id", "ledger.invalid")
        elsif ledger.kind.code != input.ledger_kind
          errors << Records.error("ledger_id", "ledger.kind", {"code" => ledger.code, "kind" => input.ledger_kind})
        end
      end
    end

    def self.apply_format(row : Format, input : Api::FormatInput) : Format
      row.name = input.name.strip
      row.description = input.description.strip
      row.ledger_kind = input.ledger_kind
      row.ledger_id = input.ledger_id
      row.separator = input.separator
      row.quote = input.quote
      row.encoding = input.encoding
      row.skip_lines = input.skip_lines
      row.date_format = input.date_format
      row.decimal_separator = input.decimal_separator
      row.thousands_separator = input.thousands_separator
      columns = input.columns.map(&.strip)
      while columns.last?.try(&.empty?)
        columns.pop
      end
      row.column_map = Parsers::Fields.dump_map(columns)
      row
    end

    # Une correspondance vise un journal, un taux, un compte ou une fiche
    # existants, lus avec les droits de l'acteur.
    def self.mapping_errors(actor : Partiduo::Api::Actor, input : Api::MappingInput, id : Int64?) : Array(FieldError)
      errors = [] of FieldError
      choice(errors, "kind", input.kind, Api::MAPPING_KINDS)
      return errors unless errors.empty?
      choice(errors, "target_type", input.target_type, Api::TARGET_TYPES[input.kind])
      source = input.source.strip
      target = input.target.strip
      if source.empty?
        errors << Records.error("source", "mapping.source.blank")
      elsif source.size > 100
        errors << Records.error("source", "mapping.source.too_long", {"max" => "100"})
      elsif Mapping.filter(kind: input.kind).to_a.any? { |row| row.source.to_s.downcase == source.downcase && row.id != id }
        errors << Records.error("source", "mapping.source.taken", {"code" => source})
      end
      errors << Records.error("note", "mapping.note.too_long", {"max" => "255"}) if input.note.size > 255
      if target.empty?
        errors << Records.error("target", "mapping.target.blank")
      elsif errors.empty? && Records.target_label(actor, input.target_type, target).nil?
        errors << Records.error("target", "mapping.target.unknown", {"code" => target})
      end
      errors
    end

    def self.apply_mapping(row : Mapping, input : Api::MappingInput) : Mapping
      row.kind = input.kind
      row.source = input.source.strip
      row.target_type = input.target_type
      row.target = normalized_target(input.target_type, input.target.strip)
      row.note = input.note.strip
      row
    end

    private def self.normalized_target(type : String, target : String) : String
      case type
      when "card"          then Partiduo::Api::Cards.format_code(target)
      when "ledger", "vat" then target.upcase
      else                      target
      end
    end

    private def self.choice(errors : Array(FieldError), field : String, value : String, allowed : Array(String)) : Nil
      errors << Records.error(field, "choice.invalid", {"value" => value}) unless allowed.includes?(value)
    end
  end
end
