# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Lecture des fichiers d'opérations (D-IMP-005) : CSV au format enregistré
  # et fichier des écritures comptables (FEC, lu par le lecteur commun du
  # cœur, `FecFile`). Chaque lecture rend un `Parsed` — opérations
  # regroupées, anomalies — sans rien écrire. Montants
  # en `BigDecimal`, jamais en flottant. Interne.
  module Parsers
    # Anomalie d'une ligne du fichier (`row` > 0) ou du fichier entier
    # (`row` = 0) : clé i18n complète et paramètres, comme
    # `Partiduo::Api::FieldError`. `warning` : remarque qui n'empêche pas la
    # lecture (encodage douteux d'un FEC), même sur le fichier entier.
    record Issue, row : Int32, key : String, params : Hash(String, String) = {} of String => String,
      warning : Bool = false do
      def fatal? : Bool
        row.zero? && !warning
      end

      def to_error : Partiduo::Api::FieldError
        Partiduo::Api::FieldError.new(row.zero? ? "content" : "rows[#{row}]", key, params.merge({"row" => row.to_s}))
      end
    end

    # Ligne d'une opération, telle que l'émetteur l'a écrite.
    #
    # * `code` : compte ou fiche (opérations diverses, FEC), article ou
    #   compte (achats, ventes), contrepartie (financier) ; `aux` : compte
    #   auxiliaire d'un FEC ; `code_label`, `aux_label` : leurs libellés ;
    # * `side` et `amount` (positif) : opérations diverses, FEC ;
    # * `amount` hors taxe (négatif pour un avoir), `quantity`, `vat_code`,
    #   `vat_amount` (`nil` : calculée par la Comptabilité) : achats, ventes ;
    # * `amount` signé (positif : entrée en banque) : financier ;
    # * `analytic` : codes des postes analytiques, un par plan ;
    # * `letter` : code de lettrage d'un FEC.
    class ParsedLine
      property row : Int32
      property code : String
      property code_label : String = ""
      property aux : String = ""
      property aux_label : String = ""
      property label : String = ""
      property side : String = ""
      property amount : BigDecimal = BigDecimal.new(0)
      property quantity : BigDecimal? = nil
      property vat_code : String = ""
      property vat_amount : BigDecimal? = nil
      property analytic : String = ""
      property letter : String = ""

      def initialize(@row : Int32, @code : String)
      end

      def debit? : Bool
        side == "debit"
      end
    end

    # Opération : lignes d'un même groupe (code de regroupement, ou pièce,
    # ou ligne seule ; journal et numéro d'écriture d'un FEC). Les données
    # de l'en-tête sont celles de sa première ligne.
    class ParsedOperation
      property position : Int32
      property group_key : String
      property ledger_code : String = ""
      property date : Time
      property receipt : String = ""
      property label : String = ""
      property due_date : Time? = nil
      property third_party : String = ""
      property currency : String = ""
      getter lines = [] of ParsedLine
      # Défauts de lecture de ses lignes : l'opération ne sera jamais
      # transférée (D-IMP-007).
      getter problems = [] of Issue

      def initialize(@position : Int32, @group_key : String, @date : Time)
      end

      # Total : débits (opérations diverses, FEC), toutes taxes (achats,
      # ventes), montant absolu (financier).
      def total(ledger_kind : String) : BigDecimal
        zero = BigDecimal.new(0)
        case ledger_kind
        when "purchase", "sale"
          lines.sum(zero) { |line| line.amount + (line.vat_amount || zero) }
        when "financial"
          lines.sum(zero, &.amount.abs)
        else
          lines.select(&.debit?).sum(zero, &.amount)
        end
      end
    end

    # Résultat d'une lecture : opérations, anomalies, encodage retenu.
    class Parsed
      getter operations = [] of ParsedOperation
      getter issues = [] of Issue
      property encoding : String = ""

      def issue(row : Int32, key : String, params = {} of String => String) : Nil
        @issues << Issue.new(row, "import.errors.#{key}", params)
      end

      # Anomalie qui empêche toute lecture du fichier.
      def fatal? : Bool
        @issues.any?(&.fatal?)
      end
    end

    # Texte ramené à une seule ligne, sans espaces superflus, borné.
    def self.clean(text : String, max : Int32 = 255) : String
      text.gsub(/[[:cntrl:]]/, " ").gsub(/\s+/, " ").strip[0, max]
    end

    # Sens écrit dans un fichier : `D`, `C`, débit, crédit (fr, en, nl, D-IMP-019),
    # `+1` et `-1` du FEC ; `nil` si illisible.
    def self.side(text : String) : String?
      case text.strip.downcase.unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
      when "d", "debit", "debet", "+1", "1", "+" then "debit"
      when "c", "credit", "-1", "-"              then "credit"
      end
    end
  end
end
