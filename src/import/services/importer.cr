# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Lecture et mise en attente d'un fichier (D-IMP-005, D-IMP-007) : genre
  # reconnu, format, lecture, essai à blanc (`Checker`), doublons, puis
  # enregistrement de l'import et de ses opérations, à traiter. Rien n'est
  # passé en comptabilité. Interne.
  module Importer
    alias Api = Import::Api
    alias FieldError = Partiduo::Api::FieldError

    # Fichier lu : genre, genre de journal, format, lecture.
    record Reading, kind : String, ledger_kind : String, format : Format?, parsed : Parsers::Parsed

    # Genre reconnu au contenu : un FEC commence par l'en-tête de l'arrêté.
    def self.detect_kind(content : Bytes) : String
      head, _ = Parsers::Text.guess(content[0, Math.min(content.size, 2048)])
      header = head.lines.first?.to_s.downcase
      header.includes?("journalcode") && header.includes?("ecriturenum") ? "fec" : "csv"
    end

    # Lit le fichier selon son genre et son format ; erreurs de saisie
    # dans `errors`.
    def self.read(input : Api::ImportInput, errors : Array(FieldError)) : Reading?
      return unless content_ok?(input, errors)
      kind = input.kind == "auto" ? detect_kind(input.content) : input.kind
      unless Api::KINDS.includes?(kind)
        errors << Records.error("kind", "choice.invalid", {"value" => input.kind})
        return
      end
      kind == "fec" ? read_fec(input, errors) : read_csv(input, errors)
    end

    # Fichier non vide, texte, de taille admise, nommé.
    private def self.content_ok?(input : Api::ImportInput, errors : Array(FieldError)) : Bool
      if input.content.empty?
        errors << Records.error("content", "file.blank")
      elsif input.content.size > Api::MAX_BYTES
        errors << Records.error("content", "file.too_large", {"max" => (Api::MAX_BYTES // (1024 * 1024)).to_s})
      elsif input.content.includes?(0_u8)
        errors << Records.error("content", "file.binary")
      end
      errors << Records.error("filename", "file.filename_blank") if input.filename.strip.empty?
      errors.empty?
    end

    private def self.read_fec(input : Api::ImportInput, errors : Array(FieldError)) : Reading?
      unless input.encoding == "auto" || Api::ENCODINGS.includes?(input.encoding)
        errors << Records.error("encoding", "choice.invalid", {"value" => input.encoding})
        return
      end
      Reading.new("fec", "", nil, Parsers::FecReader.parse(input.content, input.encoding))
    end

    private def self.read_csv(input : Api::ImportInput, errors : Array(FieldError)) : Reading?
      format_id = input.format_id
      if format_id.nil?
        errors << Records.error("format_id", "format.blank")
        return
      end
      format = Format.filter(id: format_id).first
      if format.nil?
        errors << Records.error("format_id", "format.unknown")
        return
      end
      Reading.new("csv", format.ledger_kind.to_s, format, Parsers::CsvReader.parse(input.content, Records.settings(format)))
    end

    # Erreurs qui empêchent toute lecture (fichier illisible, vide, trop
    # long).
    def self.fatal(reading : Reading) : Array(FieldError)
      errors = reading.parsed.issues.select(&.fatal?).map(&.to_error)
      rows = reading.parsed.operations.sum(&.lines.size)
      errors << Records.error("content", "file.too_many_rows", {"max" => Api::MAX_ROWS.to_s}) if rows > Api::MAX_ROWS
      errors
    end

    # Journal d'un CSV sans colonne de journal : celui choisi, sinon celui
    # du format.
    def self.default_ledger_id(input : Api::ImportInput, reading : Reading) : Int64?
      input.ledger_id || reading.format.try(&.ledger_id.try(&.to_i64))
    end

    def self.same_file(content : Bytes) : Batch?
      Batch.filter(sha256: Digest::SHA256.hexdigest(content)).order("-id").first
    end

    # Aperçu : lecture, essai à blanc, doublons ; rien n'est écrit.
    def self.preview(actor : Partiduo::Api::Actor, input : Api::ImportInput, reading : Reading) : Api::PreviewView
      default = default_ledger_id(input, reading)
      operations = reading.parsed.operations
      resolver = Resolver.new(actor, reading.kind, reading.ledger_kind, default)
      outcomes = Checker.run(actor, resolver, operations, operations.map { "import:preview" })
      prints = operations.map { |operation| Duplicates.fingerprint(reading.kind, reading.ledger_kind, default, operation) }
      duplicates = Duplicates.matches(prints)
      views = operations.map_with_index do |operation, index|
        outcome = outcomes[index]
        Api::PreviewOperationView.new(
          position: operation.position, group_key: operation.group_key, ledger_code: operation.ledger_code,
          ledger_id: outcome.ledger.try(&.id), date: operation.date, receipt: operation.receipt, label: operation.label,
          third_party: operation.third_party, total: operation.total(reading.kind == "fec" ? "misc" : reading.ledger_kind),
          duplicate: !duplicates[index].nil?, recorded_entry_id: outcome.recorded_entry_id,
          posted_receipt: outcome.problems.empty? ? outcome.receipt : nil, problems: outcome.problems,
          lines: operation.lines.map_with_index { |line, position| Records.parsed_line_view(line, position) },
        )
      end
      Api::PreviewView.new(reading.kind, reading.ledger_kind, reading.parsed.encoding, views,
        Records.issues_to_errors(reading.parsed.issues.reject(&.fatal?)), same_file(input.content).try(&.id!.to_i64))
    end

    # Enregistre l'import et ses opérations, puis les vérifie (essai à
    # blanc) avec l'acteur. Les doublons sont mis de côté.
    def self.record!(actor : Partiduo::Api::Actor, input : Api::ImportInput, reading : Reading, attachment_id : Int64) : Batch
      default = default_ledger_id(input, reading)
      operations = reading.parsed.operations
      ledger_kind = reading.kind == "fec" ? "misc" : reading.ledger_kind
      prints = operations.map { |operation| Duplicates.fingerprint(reading.kind, reading.ledger_kind, default, operation) }
      duplicates = Duplicates.matches(prints)
      batch = Batch.create!(
        kind: reading.kind, ledger_kind: reading.ledger_kind, format_id: reading.format.try(&.id),
        ledger_id: default, filename: input.filename.strip[0, 255], attachment_id: attachment_id,
        sha256: Digest::SHA256.hexdigest(input.content), encoding: reading.parsed.encoding,
        operation_count: operations.size, duplicate_count: duplicates.count { |item| !item.nil? },
        issues: Records.dump(Records.issues_to_errors(reading.parsed.issues)), created_by_id: actor.user_id,
      )
      rows = operations.map_with_index do |operation, index|
        row = Operation.create!(
          batch_id: batch.id, position: operation.position, group_key: operation.group_key[0, 100],
          ledger_code: operation.ledger_code, date: operation.date, receipt: operation.receipt, label: operation.label,
          due_date: operation.due_date, third_party: operation.third_party, currency: operation.currency,
          total: operation.total(ledger_kind), fingerprint: prints[index],
          status: duplicates[index] ? "duplicate" : "pending", duplicate_of_id: duplicates[index],
          read_problems: Records.dump(operation.problems.map(&.to_error)),
        )
        operation.lines.each_with_index do |line, position|
          OperationLine.create!(
            operation_id: row.id, position: position, row: line.row, code: line.code, code_label: line.code_label,
            aux: line.aux, aux_label: line.aux_label, label: line.label, side: line.side, amount: line.amount,
            quantity: line.quantity, vat_code: line.vat_code, vat_amount: line.vat_amount, analytic: line.analytic,
            letter: line.letter,
          )
        end
        row
      end
      Verification.check!(actor, rows.select(&.status.==("pending")))
      batch
    end
  end
end
