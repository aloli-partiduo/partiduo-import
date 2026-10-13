# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Contrat public de l'extension d'import d'opérations en masse, sur le
  # modèle de `Partiduo::Api` (DECISIONS C2 du cœur) : acteur en premier
  # argument, contrôle d'accès en première ligne (extension active et
  # permission), objets de vue immuables, toute écriture par une commande
  # qui rend un `Result` avec ses erreurs par champ, dans une transaction.
  # L'interface de l'extension (`ui/bulma/`) ne voit que ce module et
  # `Partiduo::Api`.
  #
  # Référence : `doc/api/import.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias Transaction = Partiduo::Api::Transaction
    alias Acc = Partiduo::Api::Accounting

    MODULE_CODE = Import::CODE
    READ        = "import.read"
    RUN         = "import.run"
    ADMIN       = "import.admin"

    # Permissions du cœur exigées en plus, avec l'acteur réel (D-IMP-004) :
    # lire un fichier l'essaie à blanc par le service d'écriture ; l'importer
    # le conserve en pièce jointe.
    POST_PERMISSION       = "accounting.entry.post"
    ATTACHMENT_PERMISSION = "core.attachment.write"

    MAX_LIMIT = 1000

    # --- Formats CSV -------------------------------------------------------------

    def self.formats(actor : Actor) : Array(FormatView)
      authorize!(actor, READ)
      Format.all.order(:name, :id).to_a.map { |row| Records.format_view(row) }
    end

    def self.format(actor : Actor, id : Int64) : FormatView
      authorize!(actor, READ)
      Records.format_view(Records.format!(id))
    end

    def self.check_format(actor : Actor, input : FormatInput, id : Int64? = nil) : Result(Nil)
      authorize!(actor, ADMIN)
      errors = Checks.format_errors(actor, input, id)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    def self.create_format(actor : Actor, input : FormatInput) : Result(FormatView)
      authorize!(actor, ADMIN)
      errors = Checks.format_errors(actor, input, nil)
      return Result(FormatView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Checks.apply_format(Format.new, input)
        row.save!
        Result(FormatView).success(Records.format_view(row))
      end
    end

    def self.update_format(actor : Actor, id : Int64, input : FormatInput) : Result(FormatView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.format!(id)
        errors = Checks.format_errors(actor, input, id)
        next Result(FormatView).failure(errors) unless errors.empty?
        Checks.apply_format(row, input).save!
        Result(FormatView).success(Records.format_view(row))
      end
    end

    # Supprime un format ; les imports qui l'ont employé le perdent de vue.
    def self.delete_format(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        Records.format!(id).delete
        Result(Nil).success(nil)
      end
    end

    # Premières lignes d'un fichier d'exemple découpées selon le séparateur,
    # le délimiteur et l'encodage, pour régler les colonnes d'un format.
    def self.sample(actor : Actor, content : Bytes, separator : String, quote : String, encoding : String) : Array(Array(String))
      authorize!(actor, READ)
      return [] of Array(String) unless SEPARATORS.includes?(separator) && QUOTES.includes?(quote) && ENCODINGS.includes?(encoding)
      Parsers::CsvReader.sample(content[0, Math.min(content.size, MAX_BYTES)], separator, quote, encoding)
    end

    # --- Correspondances ---------------------------------------------------------

    def self.mappings(actor : Actor, kind : String? = nil) : Array(MappingView)
      authorize!(actor, READ)
      rows = Mapping.all
      rows = rows.filter(kind: kind) if kind
      rows.order(:kind, :source).to_a.map { |row| Records.mapping_view(actor, row) }
    end

    def self.mapping(actor : Actor, id : Int64) : MappingView
      authorize!(actor, READ)
      Records.mapping_view(actor, Records.mapping!(id))
    end

    def self.create_mapping(actor : Actor, input : MappingInput) : Result(MappingView)
      authorize!(actor, ADMIN)
      errors = Checks.mapping_errors(actor, input, nil)
      return Result(MappingView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Checks.apply_mapping(Mapping.new, input)
        row.save!
        Result(MappingView).success(Records.mapping_view(actor, row))
      end
    end

    def self.update_mapping(actor : Actor, id : Int64, input : MappingInput) : Result(MappingView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.mapping!(id)
        errors = Checks.mapping_errors(actor, input, id)
        next Result(MappingView).failure(errors) unless errors.empty?
        Checks.apply_mapping(row, input).save!
        Result(MappingView).success(Records.mapping_view(actor, row))
      end
    end

    def self.delete_mapping(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        Records.mapping!(id).delete
        Result(Nil).success(nil)
      end
    end

    # Codes de l'émetteur sans correspondance, relevés dans les motifs des
    # opérations à traiter visibles (D-IMP-006) : de quoi compléter les
    # correspondances avant de vérifier de nouveau.
    def self.unknown_codes(actor : Actor) : Array(UnknownCodeView)
      authorize!(actor, READ)
      kinds = {"import.errors.ledger.unknown" => "ledger", "import.errors.vat.unknown" => "vat",
               "import.errors.code.unknown" => "code", "import.errors.code.unknown_account" => "account"}
      found = {} of {String, String} => {String, Int32}
      Records.visible_operations(actor).filter(status: "pending").exclude(problems: "").each do |row|
        Records.load(row.problems).compact_map { |error| kinds[error.key]?.try { |kind| {kind, error} } }.uniq!.each do |(kind, error)|
          code = error.params["code"]? || next
          next if code.empty?
          key = {kind, code}
          label, count = found[key]? || {error.params["label"]? || "", 0}
          found[key] = {label, count + 1}
        end
      end
      found.map { |(kind, code), (label, count)| UnknownCodeView.new(kind, code, label, count) }
        .sort_by! { |view| {MAPPING_KINDS.index(view.kind) || 3, view.source} }
    end

    # Crée dans le plan comptable un compte qu'un FEC cite et que le
    # dossier n'a pas (D-IMP-011), avec son libellé du fichier : le plan
    # est complété *explicitement*, compte par compte, par
    # `Partiduo::Api::Accounting.create_account` (exige aussi
    # `accounting.account.write`). Rien n'est créé d'office.
    def self.create_account(actor : Actor, number : String, label : String) : Result(Acc::AccountView)
      authorize!(actor, ADMIN)
      Acc.create_account(actor, Acc::AccountInput.new(number: number.strip, label: label.strip.presence || number.strip))
    end

    # --- Import --------------------------------------------------------------------

    # Genre reconnu au contenu (`csv`, `fec`).
    def self.detect_kind(actor : Actor, content : Bytes) : String
      authorize!(actor, READ)
      Importer.detect_kind(content)
    end

    # Lit le fichier et essaie chaque opération à blanc, sans rien écrire
    # (D-IMP-007) : journal retenu, pièce que donnerait le cœur, doublons,
    # écritures semblables déjà passées, motifs des refus. Exige aussi
    # `accounting.entry.post`.
    def self.preview(actor : Actor, input : ImportInput) : Result(PreviewView)
      authorize!(actor, RUN)
      Guard.authorize!(actor, POST_PERMISSION)
      errors = [] of FieldError
      reading = Importer.read(input, errors)
      return Result(PreviewView).failure(errors) unless errors.empty? && reading
      fatal = Importer.fatal(reading)
      return Result(PreviewView).failure(fatal) unless fatal.empty?
      Result(PreviewView).success(Importer.preview(actor, input, reading))
    end

    # Importe le fichier dans la zone d'attente (D-IMP-007) : pièce jointe
    # du socle, opérations à traiter vérifiées à blanc, doublons mis de
    # côté. Rien n'est passé en comptabilité. Exige aussi
    # `core.attachment.write` et `accounting.entry.post`.
    #
    # Erreurs : `import.errors.file.*` (`blank`, `too_large`, `binary`,
    # `empty`, `malformed_csv`, `already_imported`, `too_many_rows`),
    # `.fec.*`, `.format.*`, `.choice.invalid` ; celles du socle pour la
    # pièce jointe.
    def self.import_file(actor : Actor, input : ImportInput) : Result(BatchView)
      authorize!(actor, RUN)
      Guard.authorize!(actor, ATTACHMENT_PERMISSION)
      Guard.authorize!(actor, POST_PERMISSION)
      errors = [] of FieldError
      reading = Importer.read(input, errors)
      return Result(BatchView).failure(errors) unless errors.empty? && reading
      fatal = Importer.fatal(reading)
      return Result(BatchView).failure(fatal) unless fatal.empty?
      if !input.allow_same_file && (same = Importer.same_file(input.content))
        # Date de l'import dans le fuseau du dossier, pas en UTC.
        date = (same.created_at || Time.utc).in(Partiduo::Api::Core.time_zone).to_s("%Y-%m-%d")
        return Result(BatchView).failure(Records.error("content", "file.already_imported", {"date" => date, "id" => same.id.to_s}))
      end
      Transaction.run do
        content_type = reading.kind == "fec" ? "text/plain" : "text/csv"
        stored = Partiduo::Api::Core.store_attachment(actor, Partiduo::Api::Core::AttachmentInput.new(
          input.filename.strip, content_type, IO::Memory.new(input.content)))
        next Result(BatchView).failure(stored.errors) if stored.failure?
        batch = Importer.record!(actor, input, reading, stored.value!.id)
        Result(BatchView).success(Records.batch_views([batch]).first)
      end
    end

    def self.batches(actor : Actor, offset : Int32 = 0, limit : Int32 = 100) : Array(BatchView)
      authorize!(actor, READ)
      Records.batch_views(page(Batch.all.order("-created_at", "-id"), offset, limit))
    end

    def self.batch(actor : Actor, id : Int64) : BatchView
      authorize!(actor, READ)
      Records.batch_views([Records.batch!(id)]).first
    end

    # Fichier importé, relu dans les pièces jointes du socle : nom, type et
    # contenu. Exige aussi `core.attachment.read`.
    def self.batch_content(actor : Actor, id : Int64) : {String, String, Bytes}?
      authorize!(actor, READ)
      attachment_id = Records.batch!(id).attachment_id.try(&.to_i64) || return
      view = Partiduo::Api::Core.attachment(actor, attachment_id)
      {view.filename, view.content_type, Partiduo::Api::Core.attachment_content(actor, attachment_id)}
    rescue Partiduo::Api::NotFound
      nil
    end

    # Supprime un import dont aucune opération n'a été transférée, avec ses
    # opérations et son fichier. `import.admin`.
    def self.delete_batch(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.batch!(id)
        if Operation.filter(batch_id: id, status: "transferred").exists?
          next Result(Nil).failure(Records.error(FieldError::BASE, "batch.in_use"))
        end
        attachment_id = row.attachment_id.try(&.to_i64)
        row.delete
        if attachment_id && actor.can?(ATTACHMENT_PERMISSION)
          Partiduo::Api::Core.delete_attachment(actor, attachment_id)
        end
        Result(Nil).success(nil)
      end
    end

    # --- Zone d'attente ---------------------------------------------------------------

    def self.operations(actor : Actor, query : OperationQuery = OperationQuery.new) : Array(OperationView)
      authorize!(actor, READ)
      Records.operation_views(page(operation_rows(actor, query).order(:date, :id), query.offset, query.limit))
    end

    def self.count_operations(actor : Actor, query : OperationQuery = OperationQuery.new) : Int64
      authorize!(actor, READ)
      operation_rows(actor, query).count.to_i64
    end

    def self.operation(actor : Actor, id : Int64) : OperationView
      authorize!(actor, READ)
      Records.operation_view(Records.operation!(actor, id))
    end

    # Vérifie de nouveau des opérations à traiter (toutes celles visibles si
    # `ids` est nul), après avoir complété les correspondances ou le plan :
    # essai à blanc par le service d'écriture (D-IMP-007). Exige aussi
    # `accounting.entry.post`.
    def self.check(actor : Actor, ids : Array(Int64)? = nil) : Result(CheckReportView)
      authorize!(actor, RUN)
      Guard.authorize!(actor, POST_PERMISSION)
      rows = Records.visible_operations(actor).filter(status: "pending")
      rows = rows.filter(id__in: ids.uniq) if ids
      list = rows.order(:batch_id, :position, :id).to_a
      ready, refused = Verification.check!(actor, list)
      Result(CheckReportView).success(CheckReportView.new(ready, refused))
    end

    # Transfère des opérations à traiter dans la Comptabilité (D-IMP-007) :
    # une écriture par opération, par le service d'écriture du cœur, avec
    # l'acteur réel, la numérotation du journal et le fichier en pièce
    # jointe. Une opération refusée reste à traiter, avec ses motifs. Exige
    # aussi `accounting.entry.post` et l'écriture dans le journal.
    def self.transfer(actor : Actor, ids : Array(Int64)) : Result(TransferReportView)
      authorize!(actor, RUN)
      Guard.authorize!(actor, POST_PERMISSION)
      return Result(TransferReportView).failure(Records.error("ids", "operation.none_selected")) if ids.empty?
      rows = Records.visible_operations(actor).filter(id__in: ids.uniq).order(:batch_id, :position, :id).to_a
      done, failed = Transfer.run(actor, rows)
      Result(TransferReportView).success(TransferReportView.new(Records.operation_views(done), Records.operation_views(failed)))
    end

    # Écarte des opérations à traiter : elles ne seront pas transférées,
    # mais restent pour l'historique et la détection des doublons.
    def self.discard(actor : Actor, ids : Array(Int64)) : Result(Int32)
      change_status(actor, ids, from: %w[pending], to: "discarded")
    end

    # Rend à traiter des opérations écartées, ou des doublons qu'on juge
    # distincts ; elles devront être vérifiées de nouveau.
    def self.restore(actor : Actor, ids : Array(Int64)) : Result(Int32)
      change_status(actor, ids, from: %w[discarded duplicate], to: "pending")
    end

    # Supprime les opérations écartées et les doublons visibles.
    # `import.admin`.
    def self.purge(actor : Actor) : Result(Int32)
      authorize!(actor, ADMIN)
      Transaction.run do
        rows = Records.visible_operations(actor).filter(status__in: %w[discarded duplicate])
        ids = rows.pluck(:id).map(&.first.as(Int64))
        Operation.filter(duplicate_of_id__in: ids).update(duplicate_of_id: nil) unless ids.empty?
        Operation.filter(id__in: ids).delete unless ids.empty?
        Result(Int32).success(ids.size)
      end
    end

    # Reprend le lettrage d'un FEC sur ses lignes transférées (D-IMP-012).
    # Exige aussi `accounting.matching.write`.
    def self.apply_lettering(actor : Actor, batch_id : Int64) : Result(LetteringReportView)
      authorize!(actor, RUN)
      batch = Records.batch!(batch_id)
      return Result(LetteringReportView).failure(Records.error(FieldError::BASE, "lettering.not_fec")) unless batch.kind == "fec"
      Transaction.run do
        matched, problems = Lettering.run(actor, batch)
        Result(LetteringReportView).success(LetteringReportView.new(matched, problems))
      end
    end

    # --- Tableau de bord ---------------------------------------------------------------

    # Opérations à traiter visibles, pour la tuile et le compteur du menu ;
    # `nil` si l'extension est inactive ou l'acteur sans droit.
    def self.tile(actor : Actor) : TileView?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      rows = Records.visible_operations(actor).filter(status: "pending").to_a
      refused = rows.count { |row| !row.problems.to_s.empty? || !row.read_problems.to_s.empty? }
      ready = rows.count { |row| row.checked_at && row.problems.to_s.empty? && row.read_problems.to_s.empty? }
      TileView.new(rows.size, ready, refused, rows.min_of?(&.date!))
    end

    def self.pending_count(actor : Actor) : Int64?
      tile(actor).try(&.pending_count.to_i64)
    end

    # --- Outils ------------------------------------------------------------------------

    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
    end

    private def self.page(rows, offset : Int32, limit : Int32)
      start = Math.max(offset, 0)
      rows[start...(start + limit.clamp(1, MAX_LIMIT))].to_a
    end

    private def self.operation_rows(actor : Actor, query : OperationQuery)
      rows = Records.visible_operations(actor)
      query.batch_id.try { |batch_id| rows = rows.filter(batch_id: batch_id) }
      query.status.try { |status| rows = rows.filter(status: status) }
      query.ledger_id.try { |ledger_id| rows = rows.filter(ledger_id: ledger_id) }
      rows = rows.filter { -q(problems: "") | -q(read_problems: "") } if query.refused_only
      if text = query.search.try(&.strip).presence
        rows = rows.filter do
          q(label__icontains: text) | q(receipt__icontains: text) | q(third_party__icontains: text) | q(group_key__icontains: text)
        end
      end
      rows
    end

    private def self.change_status(actor : Actor, ids : Array(Int64), from : Array(String), to : String) : Result(Int32)
      authorize!(actor, RUN)
      return Result(Int32).failure(Records.error("ids", "operation.none_selected")) if ids.empty?
      Transaction.run do
        rows = Records.visible_operations(actor).filter(id__in: ids.uniq, status__in: from).lock.to_a
        rows.each do |row|
          row.status = to
          if to == "pending"
            row.duplicate_of_id = nil
            row.checked_at = nil
          end
          row.save!
        end
        Verification.check!(actor, rows) if to == "pending" && actor.can?(POST_PERMISSION)
        Result(Int32).success(rows.size)
      end
    end
  end
end
