# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Api
    alias FieldError = Partiduo::Api::FieldError

    # Genres de fichier (D-IMP-005, D-IMP-011). Libellé : `import.kinds.<code>`.
    KINDS = %w[csv fec]

    # Genres de journal d'un format CSV. Libellé : `import.ledger_kinds.<code>`.
    LEDGER_KINDS = Parsers::Fields::LEDGER_KINDS

    # Statuts d'une opération (D-IMP-007). Libellé : `import.statuses.<code>`.
    STATUSES = %w[pending transferred duplicate discarded]

    # Genres de correspondance et cibles (D-IMP-006). Libellés :
    # `import.mapping_kinds.<code>`, `import.target_types.<code>`.
    MAPPING_KINDS = %w[ledger vat code]
    TARGET_TYPES  = {"ledger" => %w[ledger], "vat" => %w[vat], "code" => %w[account card]}

    # Champs des colonnes d'un CSV. Libellé : `import.fields.<clé>`.
    FIELDS = Parsers::Fields::ALL

    # Réglages d'un format CSV. Libellés : `import.separators.<code>`,
    # `import.quotes.<code>`, `import.encodings.<code>`,
    # `import.decimal_separators.<code>`, `import.thousands_separators.<code>`.
    # Les formats de date ont pour code leur gabarit anglais (`dd/mm/yyyy`).
    SEPARATORS           = Parsers::CsvReader::SEPARATORS.keys
    QUOTES               = Parsers::CsvReader::QUOTES.keys
    ENCODINGS            = Parsers::Text::ENCODINGS
    DECIMAL_SEPARATORS   = Parsers::Amounts::SEPARATORS.keys
    THOUSANDS_SEPARATORS = Parsers::Amounts::THOUSANDS.keys
    DATE_FORMATS         = Parsers::Dates::FORMATS.keys

    # Taille d'un fichier (5 Mio, comme les imports du cœur) et nombre de
    # lignes lues au plus.
    MAX_BYTES = 5 * 1024 * 1024
    MAX_ROWS  = 10_000

    # Nombre de colonnes au plus d'un format.
    MAX_COLUMNS = 60

    # --- Entrées ---------------------------------------------------------------

    # Format CSV enregistré (D-IMP-005). `columns[i]` : clé du champ de la
    # colonne `i + 1` (`FIELDS`), `""` pour une colonne ignorée. `ledger_id` :
    # journal proposé quand le fichier n'a pas de colonne de journal.
    record FormatInput,
      name : String,
      ledger_kind : String,
      columns : Array(String),
      description : String = "",
      ledger_id : Int64? = nil,
      separator : String = "semicolon",
      quote : String = "double",
      encoding : String = "utf-8",
      skip_lines : Int32 = 1,
      date_format : String = "dd/mm/yyyy",
      decimal_separator : String = "comma",
      thousands_separator : String = "none"

    # Correspondance d'un code de l'émetteur (D-IMP-006) : genre (`ledger`,
    # `vat`, `code`), code du fichier, cible (`ledger` : code du journal ;
    # `vat` : code du taux ; `account` : numéro du compte ; `card` : quick
    # code de la fiche).
    record MappingInput,
      kind : String,
      source : String,
      target_type : String,
      target : String,
      note : String = ""

    # Fichier à importer.
    #
    # * `kind` : `csv`, `fec`, ou `auto` (FEC reconnu à son en-tête) ;
    # * `format_id` : format enregistré (obligatoire pour un CSV) ;
    # * `ledger_id` : journal des opérations d'un CSV sans colonne de
    #   journal (à défaut, celui du format) ;
    # * `encoding` : encodage d'un FEC (`auto` : reconnu) ;
    # * `allow_same_file` : importer un fichier déjà importé (ses opérations
    #   seront signalées comme doublons).
    record ImportInput,
      filename : String,
      content : Bytes,
      kind : String = "auto",
      format_id : Int64? = nil,
      ledger_id : Int64? = nil,
      encoding : String = "auto",
      allow_same_file : Bool = false

    # Recherche dans la zone d'attente : import, statut (`nil` : tous),
    # journal retenu, texte (libellé, pièce, tiers, code de regroupement),
    # opérations refusées seulement.
    record OperationQuery,
      batch_id : Int64? = nil,
      status : String? = "pending",
      ledger_id : Int64? = nil,
      search : String? = nil,
      refused_only : Bool = false,
      offset : Int32 = 0,
      limit : Int32 = 200

    # --- Vues ------------------------------------------------------------------

    record FormatView,
      id : Int64,
      name : String,
      description : String,
      ledger_kind : String,
      ledger_id : Int64?,
      separator : String,
      quote : String,
      encoding : String,
      skip_lines : Int32,
      date_format : String,
      decimal_separator : String,
      thousands_separator : String,
      columns : Array(String),
      batch_count : Int32 do
      def ledger_kind_key : String
        "import.ledger_kinds.#{ledger_kind}"
      end

      # Rang (à partir de 1) de la colonne d'un champ, ou `nil`.
      def column_of(field : String) : Int32?
        columns.index(field).try(&.+(1))
      end
    end

    # Correspondance ; `target_label` : nom du journal, du taux, du compte ou
    # de la fiche, relu par le contrat du cœur quand l'acteur peut le lire.
    record MappingView,
      id : Int64,
      kind : String,
      source : String,
      target_type : String,
      target : String,
      target_label : String?,
      note : String do
      def kind_key : String
        "import.mapping_kinds.#{kind}"
      end

      def target_type_key : String
        "import.target_types.#{target_type}"
      end
    end

    # Ligne d'une opération lue (zone d'attente, aperçu).
    record OperationLineView,
      position : Int32,
      row : Int32,
      code : String,
      code_label : String,
      aux : String,
      aux_label : String,
      label : String,
      side : String,
      amount : BigDecimal,
      quantity : BigDecimal?,
      vat_code : String,
      vat_amount : BigDecimal?,
      analytic : String,
      letter : String,
      entry_line_id : Int64?

    # Opération de la zone d'attente (D-IMP-007). `problems` : motifs du
    # refus de la dernière vérification ou du dernier transfert ;
    # `read_problems` : défauts de lecture, qui l'empêchent d'être
    # transférée.
    record OperationView,
      id : Int64,
      batch_id : Int64,
      batch_kind : String,
      ledger_kind : String,
      position : Int32,
      group_key : String,
      ledger_code : String,
      ledger_id : Int64?,
      date : Time,
      receipt : String,
      label : String,
      due_date : Time?,
      third_party : String,
      currency : String,
      total : BigDecimal,
      status : String,
      duplicate_of_id : Int64?,
      recorded_entry_id : Int64?,
      entry_id : Int64?,
      posted_receipt : String,
      reversed_entry_id : Int64?,
      problems : Array(FieldError),
      read_problems : Array(FieldError),
      checked_at : Time?,
      lines : Array(OperationLineView) do
      def pending? : Bool
        status == "pending"
      end

      # Vérifiée sans motif de refus : elle peut être transférée.
      def ready? : Bool
        pending? && !checked_at.nil? && problems.empty? && read_problems.empty?
      end

      def refused? : Bool
        pending? && (!problems.empty? || !read_problems.empty?)
      end

      def status_key : String
        "import.statuses.#{status}"
      end
    end

    # Un import (historique, D-IMP-009) et l'état de ses opérations.
    record BatchView,
      id : Int64,
      kind : String,
      ledger_kind : String,
      format_id : Int64?,
      format_name : String?,
      ledger_id : Int64?,
      filename : String,
      attachment_id : Int64?,
      encoding : String,
      operation_count : Int32,
      pending_count : Int32,
      refused_count : Int32,
      transferred_count : Int32,
      duplicate_count : Int32,
      discarded_count : Int32,
      first_date : Time?,
      last_date : Time?,
      total : BigDecimal,
      issues : Array(FieldError),
      letter_count : Int32,
      created_by_id : Int64?,
      created_at : Time do
      def kind_key : String
        "import.kinds.#{kind}"
      end
    end

    # Opération lue à l'aperçu, essayée à blanc (D-IMP-007) : journal
    # retenu, pièce que le cœur lui donnerait, doublon, écriture semblable
    # déjà passée, motifs du refus.
    record PreviewOperationView,
      position : Int32,
      group_key : String,
      ledger_code : String,
      ledger_id : Int64?,
      date : Time,
      receipt : String,
      label : String,
      third_party : String,
      total : BigDecimal,
      duplicate : Bool,
      recorded_entry_id : Int64?,
      posted_receipt : String?,
      problems : Array(FieldError),
      lines : Array(OperationLineView) do
      def accepted? : Bool
        problems.empty? && !duplicate
      end
    end

    # Aperçu d'un import : genre, genre de journal, encodage reconnu,
    # opérations, anomalies de lecture, import antérieur du même fichier.
    record PreviewView,
      kind : String,
      ledger_kind : String,
      encoding : String,
      operations : Array(PreviewOperationView),
      issues : Array(FieldError),
      same_file_batch_id : Int64? do
      def accepted_count : Int32
        operations.count(&.accepted?)
      end

      def refused_count : Int32
        operations.count { |operation| !operation.problems.empty? }
      end

      def duplicate_count : Int32
        operations.count(&.duplicate)
      end
    end

    # Bilan d'une vérification : opérations prêtes, refusées.
    record CheckReportView, ready : Int32, refused : Int32

    # Bilan d'un transfert : opérations passées, opérations refusées (avec
    # leurs motifs).
    record TransferReportView, transferred : Array(OperationView), failed : Array(OperationView)

    # Code de l'émetteur sans correspondance, relevé dans les motifs des
    # opérations à traiter (D-IMP-006) : genre (`ledger`, `vat`, `code`,
    # `account` : compte d'un FEC, que l'on peut créer), code, libellé lu
    # dans le fichier, nombre d'opérations concernées.
    record UnknownCodeView, kind : String, source : String, label : String, count : Int32

    # Bilan de la reprise du lettrage d'un FEC (D-IMP-012).
    record LetteringReportView, matched : Int32, problems : Array(FieldError)

    # Tuile du tableau de bord : opérations à traiter, dont prêtes et
    # refusées, et date de la plus ancienne.
    record TileView, pending_count : Int32, ready_count : Int32, refused_count : Int32, oldest_date : Time?
  end
end
