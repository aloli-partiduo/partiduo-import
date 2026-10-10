# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Parsers
    # Lecture des montants : en `BigDecimal`, jamais en flottant. Signe en
    # tête ou en fin (`12,50-`), parenthèses comptables, symbole ou code de
    # la devise et espaces (insécables comprises) ignorés.
    module Amounts
      SEPARATORS = {"comma" => ',', "dot" => '.'}
      THOUSANDS  = {"none" => nil, "space" => ' ', "dot" => '.', "comma" => ',', "apostrophe" => '\''}

      # Montant écrit avec les séparateurs donnés ; `decimal` nul : séparateur
      # reconnu (le dernier de `,` et `.`). `nil` si le texte n'est pas un
      # montant.
      def self.parse(text : String, decimal : Char? = nil, thousands : Char? = nil) : BigDecimal?
        value = text.strip
        return if value.empty?
        value, negative = sign(value, thousands, decimal)
        value = decimal ? normalize(value, decimal) : guess(value)
        return if value.nil? || !value.matches?(/\A\d+(\.\d+)?\z/)
        amount = BigDecimal.new(value)
        negative ? -amount : amount
      rescue InvalidBigDecimalException
        nil
      end

      private def self.sign(text : String, thousands : Char?, decimal : Char?) : {String, Bool}
        value = text
        negative = false
        if value.starts_with?('(') && value.ends_with?(')')
          negative = true
          value = value[1..-2]
        end
        value = value.gsub(/[\s\x{00A0}\x{202F}]|€|EUR|\$|£|CHF/i, "")
        value = value.gsub(thousands, "") if thousands && thousands != decimal
        negative = !negative if value.ends_with?('-') || value.starts_with?('-')
        {value.strip('+').strip('-'), negative}
      end

      private def self.guess(value : String) : String?
        comma = value.rindex(',')
        dot = value.rindex('.')
        return normalize(value, comma > dot ? ',' : '.') if comma && dot
        separator = comma ? ',' : (dot ? '.' : nil)
        return value if separator.nil?
        return value.delete(separator) if value.count(separator) > 1
        normalize(value, separator)
      end

      private def self.normalize(value : String, decimal : Char) : String?
        other = decimal == ',' ? '.' : ','
        value = value.delete(other) if value.includes?(decimal)
        parts = value.split(decimal)
        return if parts.size > 2
        parts.size == 2 ? "#{parts[0].empty? ? "0" : parts[0]}.#{parts[1]}" : value
      end
    end
  end
end
