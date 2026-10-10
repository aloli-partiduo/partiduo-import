# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Ui
    # `/ext/IMPORT/import` : import d'un fichier d'opérations, en deux temps
    # sur le même écran — fichier (ou texte collé), genre (CSV au format
    # enregistré, ou FEC), journal ; puis aperçu : chaque opération essayée
    # à blanc par le service d'écriture de la Comptabilité, avec la pièce
    # qu'elle recevrait ou les motifs de son refus, doublons et écritures
    # semblables signalés ; et import dans la zone d'attente. Le fichier
    # passe d'une étape à l'autre encodé en base64. Rien n'est passé en
    # comptabilité.
    class ImportHandler < Handler
      PREVIEW_OPERATIONS = 200

      def get
        show_start(nil, 200, default_values)
      end

      def post
        upload = request.data.fetch("file", nil).as?(Marten::HTTP::UploadedFile)
        content, filename = read_content(upload)
        values = submitted(filename)
        return show_start(I18n.t("import_ui.import.too_large"), 422, values) if content.size > Api::MAX_BYTES
        input = Api::ImportInput.new(filename: filename, content: content, kind: values["kind"],
          format_id: id_field("format_id"), ledger_id: id_field("ledger_id"), encoding: values["encoding"],
          allow_same_file: field("allow_same_file") == "1")
        if field("step") == "import"
          result = Api.import_file(actor, input)
          if result.success?
            view = result.value!
            flash["success"] = I18n.t("import_ui.import.done", count: view.pending_count, refused: view.refused_count,
              duplicates: view.duplicate_count)
            return go(Ui.url("batch_detail", id: view.id))
          end
          preview = Api.preview(actor, input)
          return show_preview(input, preview.value!, values, messages(result)) if preview.success?
          return show_start(messages(result), 422, values)
        end
        preview = Api.preview(actor, input)
        return show_start(messages(preview), 422, values) if preview.failure?
        show_preview(input, preview.value!, values, nil)
      ensure
        upload.try { |file| file.io.delete rescue nil }
      end

      private def default_values : Hash(String, String)
        format = Api.formats(actor).first?
        {"kind" => "auto", "format_id" => format.try(&.id.to_s) || "", "ledger_id" => format.try(&.ledger_id.to_s) || "",
         "encoding" => "auto", "filename" => ""}
      end

      private def submitted(filename : String) : Hash(String, String)
        {"kind" => field("kind").presence || "auto", "format_id" => field("format_id"), "ledger_id" => field("ledger_id"),
         "encoding" => field("encoding").presence || "auto", "filename" => filename}
      end

      # Contenu : fichier déposé, sinon reçu de l'aperçu (base64), sinon
      # texte collé ; et nom du fichier.
      private def read_content(upload : Marten::HTTP::UploadedFile?) : {Bytes, String}
        if upload && upload.size > 0
          io = upload.io
          io.rewind
          return {io.getb_to_end, upload.filename.presence || pasted_name}
        end
        if payload = field("payload").presence
          bytes = begin
            Base64.decode(payload)
          rescue Base64::Error
            Bytes.empty
          end
          return {bytes, field("filename").presence || pasted_name}
        end
        {field("content", strip: false).to_slice, field("filename").presence || pasted_name}
      end

      private def pasted_name : String
        "#{I18n.t("import_ui.import.pasted_name")}-#{Partiduo::Api::Core.today.to_s("%Y%m%d")}.txt"
      end

      private def base_values : Hash(String, (String | Array(Screen::Crumb) | Array(Row))?)
        {
          "title"  => I18n.t("import.menu.import_run"),
          "crumbs" => crumbs({I18n.t("import.menu.import_run"), nil}).as(Array(Screen::Crumb)),
        } of String => (String | Array(Screen::Crumb) | Array(Row))?
      end

      private def show_start(error : String?, status : Int32, values : Hash(String, String)) : Marten::HTTP::Response
        page_values = base_values
        page_values["step"] = "start"
        page_values["error"] = error
        page_values["kinds"] = choice_rows([option("auto", I18n.t("import_ui.import.kind_auto"))] +
                                           code_options(Api::KINDS, "import.kinds"), values["kind"])
        formats = Api.formats(actor).map do |item|
          option(item.id.to_s, "#{item.name} · #{I18n.t(item.ledger_kind_key)}")
        end
        page_values["formats"] = choice_rows([blank_option] + formats, values["format_id"])
        page_values["ledgers"] = choice_rows([blank_option("import_ui.import.ledger_from_file")] + ledger_options, values["ledger_id"])
        page_values["encodings"] = choice_rows([option("auto", I18n.t("import_ui.import.encoding_auto"))] +
                                               code_options(Api::ENCODINGS, "import.encodings"), values["encoding"])
        page_values["no_format"] = Ui.flag(Api.formats(actor).empty?)
        page_values["can_admin"] = Ui.flag(can_admin?)
        page("import/import.html", page_values, status: status)
      end

      private def show_preview(input : Api::ImportInput, preview : Api::PreviewView, values : Hash(String, String),
                               error : String?) : Marten::HTTP::Response
        page_values = base_values
        codes = ledger_codes
        page_values["step"] = "preview"
        page_values["error"] = error
        page_values["payload"] = Base64.strict_encode(input.content)
        page_values["filename"] = input.filename
        page_values["kind"] = preview.kind
        page_values["kind_label"] = I18n.t("import.kinds.#{preview.kind}")
        page_values["ledger_kind"] = preview.ledger_kind.presence.try { |kind| I18n.t("import.ledger_kinds.#{kind}") }
        page_values["encoding"] = values["encoding"]
        page_values["encoding_label"] = preview.encoding.presence.try { |code| I18n.t("import.encodings.#{code}") }
        page_values["format_id"] = values["format_id"]
        page_values["ledger_id"] = values["ledger_id"]
        page_values["summary"] = I18n.t("import_ui.import.summary", count: preview.operations.size,
          accepted: preview.accepted_count, refused: preview.refused_count, duplicates: preview.duplicate_count)
        page_values["same_file"] = preview.same_file_batch_id.try { |id| Ui.url("batch_detail", id: id) }
        page_values["issues"] = preview.issues.map { |issue| Ui.row({"message" => fmt.message(issue)}) }
        page_values["rows"] = preview.operations.first(PREVIEW_OPERATIONS).map do |operation|
          Ui.row({
            "position"       => operation.position.to_s,
            "date"           => fmt.date(operation.date),
            "label"          => operation.label.presence || operation.group_key,
            "receipt"        => operation.receipt.presence,
            "third_party"    => operation.third_party.presence,
            "ledger"         => operation.ledger_id.try { |id| codes[id]? } || operation.ledger_code.presence,
            "total"          => fmt.amount(operation.total),
            "count"          => operation.lines.size.to_s,
            "posted_receipt" => operation.posted_receipt,
            "duplicate"      => Ui.flag(operation.duplicate),
            "recorded"       => Ui.flag(!operation.recorded_entry_id.nil?),
            "accepted"       => Ui.flag(operation.accepted?),
          }, {"problems" => operation.problems.map { |problem| Ui.row({"message" => fmt.message(problem)}) },
              "lines"    => Present.lines(operation.lines, fmt)})
        end
        page_values["truncated"] = preview.operations.size > PREVIEW_OPERATIONS ? I18n.t("import_ui.import.truncated", count: PREVIEW_OPERATIONS) : nil
        page_values["importable"] = preview.operations.empty? ? nil : I18n.t("import_ui.import.submit", count: preview.operations.size)
        page("import/import.html", page_values, status: error ? 422 : 200)
      end
    end
  end
end
