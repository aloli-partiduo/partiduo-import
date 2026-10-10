# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Parsers
    # Décodage d'un fichier (D-IMP-005) : UTF-8 (marque d'ordre retirée),
    # Windows-1252, ISO 8859-15 (l'encodage de l'arrêté du FEC), ou reconnu :
    # UTF-8 s'il est valide, sinon Windows-1252 si le fichier contient des
    # octets 0x80 à 0x9F (€, apostrophes typographiques), sinon ISO 8859-15.
    # Décodage par table, sans iconv.
    module Text
      ENCODINGS = %w[utf-8 windows-1252 iso-8859-15]

      # Caractères 0x80 à 0x9F de Windows-1252 (Latin-1 au-delà).
      CP1252 = {
        0x80 => '€', 0x82 => '‚', 0x83 => 'ƒ', 0x84 => '„', 0x85 => '…', 0x86 => '†', 0x87 => '‡', 0x88 => 'ˆ',
        0x89 => '‰', 0x8A => 'Š', 0x8B => '‹', 0x8C => 'Œ', 0x8E => 'Ž', 0x91 => '‘', 0x92 => '’', 0x93 => '“',
        0x94 => '”', 0x95 => '•', 0x96 => '–', 0x97 => '—', 0x98 => '˜', 0x99 => '™', 0x9A => 'š', 0x9B => '›',
        0x9C => 'œ', 0x9E => 'ž', 0x9F => 'Ÿ',
      }

      # Huit caractères d'ISO 8859-15 qui diffèrent de Latin-1.
      LATIN9 = {
        0xA4 => '€', 0xA6 => 'Š', 0xA8 => 'š', 0xB4 => 'Ž', 0xB8 => 'ž', 0xBC => 'Œ', 0xBD => 'œ', 0xBE => 'Ÿ',
      }

      # Texte du fichier et encodage retenu (`auto` : reconnu).
      def self.decode(bytes : Bytes, encoding : String) : {String, String}
        case encoding
        when "windows-1252" then {cp1252(bytes), encoding}
        when "iso-8859-15"  then {latin9(bytes), encoding}
        when "utf-8"        then {utf8(bytes), encoding}
        else                     guess(bytes)
        end
      end

      def self.guess(bytes : Bytes) : {String, String}
        text = String.new(bytes)
        return {text.lchop('\u{FEFF}'), "utf-8"} if text.valid_encoding?
        return {cp1252(bytes), "windows-1252"} if bytes.any? { |byte| 0x80 <= byte <= 0x9F }
        {latin9(bytes), "iso-8859-15"}
      end

      def self.utf8(bytes : Bytes) : String
        String.new(bytes).scrub.lchop('\u{FEFF}')
      end

      def self.cp1252(bytes : Bytes) : String
        String.build(bytes.size) do |io|
          bytes.each { |byte| io << (CP1252[byte.to_i32]? || byte.unsafe_chr) }
        end
      end

      def self.latin9(bytes : Bytes) : String
        String.build(bytes.size) do |io|
          bytes.each { |byte| io << (LATIN9[byte.to_i32]? || byte.unsafe_chr) }
        end
      end
    end
  end
end
