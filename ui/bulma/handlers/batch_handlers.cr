# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Ui
    # `/ext/IMPORT/batches` : historique des imports — fichier, genre, date,
    # période, opérations lues, à traiter, refusées, transférées, doublons.
    class BatchesHandler < Handler
      def get
        columns = [
          Table::Column.new("created", I18n.t("import_ui.batches.created"), "mono"),
          Table::Column.new("filename", I18n.t("import_ui.batches.filename")),
          Table::Column.new("kind", I18n.t("import_ui.batches.kind"), secondary: true),
          Table::Column.new("period", I18n.t("import_ui.batches.period"), secondary: true),
          Table::Column.new("operations", I18n.t("import_ui.batches.operations"), "number"),
          Table::Column.new("pending", I18n.t("import_ui.batches.pending"), "number"),
          Table::Column.new("refused", I18n.t("import_ui.batches.refused"), "number"),
          Table::Column.new("transferred", I18n.t("import_ui.batches.transferred"), "number"),
          Table::Column.new("duplicates", I18n.t("import_ui.batches.duplicates"), "number"),
        ]
        rows = Api.batches(actor, limit: 1000).map do |view|
          url = Ui.url("batch_detail", id: view.id)
          kind = [I18n.t(view.kind_key), view.ledger_kind.presence.try { |code| I18n.t("import.ledger_kinds.#{code}") }].compact.join(" · ")
          Table::Row.new([
            Table::Cell.new(fmt.date(view.created_at), url, sort: view.created_at.to_s("%Y-%m-%d %H:%M:%S")),
            Table::Cell.new(view.filename, url),
            Table::Cell.new(kind),
            Table::Cell.new(view.first_date.try { |first| "#{fmt.date(first)} – #{fmt.date(view.last_date)}" } || "",
              sort: view.first_date.try(&.to_s("%Y-%m-%d")) || ""),
            Table::Cell.new(view.operation_count.to_s, sort: BigDecimal.new(view.operation_count)),
            Table::Cell.new(view.pending_count.to_s, sort: BigDecimal.new(view.pending_count)),
            Table::Cell.new(view.refused_count.to_s, sort: BigDecimal.new(view.refused_count)),
            Table::Cell.new(view.transferred_count.to_s, sort: BigDecimal.new(view.transferred_count)),
            Table::Cell.new(view.duplicate_count.to_s, sort: BigDecimal.new(view.duplicate_count)),
          ])
        end
        table = Table.new(I18n.t("import.menu.import_history"), columns, rows, Ui.url("batches"),
          empty_message: I18n.t("import_ui.batches.none"), id: "imp-batches")
        actions = can_run? ? [link_action("import.menu.import_run", Ui.url("import"), "primary", "upload")] : [] of Screen::Action
        list_page(I18n.t("import.menu.import_history"), table, crumbs({I18n.t("import.menu.import_history"), nil}),
          "import_ui.batches.csv_name", actions)
      end
    end

    # `/ext/IMPORT/batches/<id>` : un import — fichier, genre, format,
    # encodage, compteurs, anomalies de lecture, opérations ; reprise du
    # lettrage d'un FEC ; téléchargement du fichier ; suppression tant
    # qu'aucune opération n'a été transférée.
    class BatchDetailHandler < Handler
      def get
        view = Api.batch(actor, id_param)
        operations = Api.operations(actor, Api::OperationQuery.new(batch_id: view.id, status: nil, limit: Api::MAX_LIMIT))
        codes = ledger_codes
        page("import/batch_detail.html", {
          "title"   => view.filename,
          "crumbs"  => crumbs({I18n.t("import.menu.import_history"), Ui.url("batches")}, {view.filename, nil}),
          "actions" => detail_actions(view),
          "batch"   => Present.batch(view, fmt, codes),
          "format"  => view.format_name,
          "issues"  => view.issues.map { |issue| Ui.row({"message" => fmt.message(issue)}) },
          "rows"    => operations.map { |operation| Present.operation(operation, fmt, false, codes) },
        })
      end

      private def detail_actions(view : Api::BatchView) : Array(Screen::Action)
        actions = [] of Screen::Action
        if view.pending_count > 0
          actions << link_action("import_ui.batches.process", "#{Ui.url("operations")}?batch=#{view.id}", "primary", "check")
        end
        if can_run? && view.kind == "fec" && view.letter_count > 0 && view.transferred_count > 0
          actions << post_action("import_ui.batches.lettering", Ui.url("batch_lettering", id: view.id), nil, "", "refresh-cw")
        end
        actions << link_action("import_ui.batches.download", Ui.url("batch_file", id: view.id), "", "download") if view.attachment_id
        if can_admin? && view.transferred_count.zero?
          actions << post_action("import_ui.batches.delete", Ui.url("batch_delete", id: view.id), "import_ui.batches.delete_confirm",
            "danger", "x")
        end
        actions
      end
    end

    # Fichier importé, relu dans les pièces jointes du socle.
    class BatchFileHandler < Handler
      def get
        found = Api.batch_content(actor, id_param)
        return PartiduoUi::ErrorPage.render(request, 404) if found.nil?
        filename, content_type, bytes = found
        response = Marten::HTTP::Response.new(String.new(bytes), content_type: content_type)
        response.headers["Content-Disposition"] = %(attachment; filename="#{filename.gsub(/["\\\r\n]/, "_")}")
        response
      rescue Partiduo::Api::AccessDenied
        PartiduoUi::ErrorPage.render(request, 403)
      end
    end

    # Reprend le lettrage d'un FEC.
    class BatchLetteringHandler < Handler
      def get
        go(Ui.url("batch_detail", id: id_param))
      end

      def post
        url = Ui.url("batch_detail", id: id_param)
        result = Api.apply_lettering(actor, id_param)
        if result.failure?
          flash["danger"] = messages(result)
          return go(url)
        end
        report = result.value!
        flash["success"] = I18n.t("import_ui.flash.lettered", count: report.matched)
        flash["danger"] = report.problems.map { |problem| fmt.message(problem) }.uniq!.join(" ") unless report.problems.empty?
        go(url)
      end
    end

    class BatchDeleteHandler < Handler
      def get
        go(Ui.url("batches"))
      end

      def post
        result = Api.delete_batch(actor, id_param)
        return after(result, "import_ui.flash.batch_deleted", Ui.url("batches")) if result.success?
        after(result, "", Ui.url("batch_detail", id: id_param))
      end
    end
  end
end
