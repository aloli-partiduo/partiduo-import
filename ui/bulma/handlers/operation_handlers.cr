# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Ui
    # `/ext/IMPORT/operations` : zone d'attente. Filtres (statut, import,
    # texte, refusées seulement) ; pour chaque opération, ses lignes, le
    # journal retenu, la pièce de l'émetteur, les motifs du refus et sa
    # vérification en HTMX ; actions groupées sur les opérations cochées :
    # vérifier, transférer, écarter, reprendre.
    class OperationsHandler < Handler
      def get
        status = query("status").presence || "pending"
        status = "pending" unless status == "all" || Api::STATUSES.includes?(status)
        query_input = Api::OperationQuery.new(batch_id: query("batch").to_i64?, status: status == "all" ? nil : status,
          search: query("q").presence, refused_only: query("refused") == "1", limit: 500)
        views = Api.operations(actor, query_input)
        total = Api.count_operations(actor, query_input)
        codes = ledger_codes
        unknown = can_admin? && status == "pending" ? Api.unknown_codes(actor).size : 0
        page("import/operations.html", {
          "title"     => I18n.t("import.menu.import_operations"),
          "crumbs"    => crumbs({I18n.t("import.menu.import_operations"), nil}),
          "actions"   => header_actions,
          "rows"      => views.map { |view| Present.operation(view, fmt, can_run?, codes) },
          "summary"   => I18n.t("import_ui.operations.summary", count: total),
          "truncated" => total > views.size ? I18n.t("import_ui.operations.truncated", count: views.size) : nil,
          "statuses"  => choice_rows([option("all", I18n.t("import_ui.operations.all_statuses"))] +
                                    code_options(Api::STATUSES, "import.statuses"), status),
          "q"          => query("q"),
          "batch"      => query("batch"),
          "refused"    => Ui.flag(query("refused") == "1"),
          "can_run"    => Ui.flag(can_run?),
          "pending"    => Ui.flag(status == "pending"),
          "restorable" => Ui.flag(status == "discarded" || status == "duplicate" || status == "all"),
          "unknown"    => unknown > 0 ? I18n.t("import_ui.operations.unknown", count: unknown) : nil,
          "next"       => request.full_path,
        })
      end

      private def header_actions : Array(Screen::Action)
        actions = [] of Screen::Action
        actions << link_action("import.menu.import_run", Ui.url("import"), "primary", "upload") if can_run?
        actions << link_action("import.menu.import_mappings", Ui.url("mappings"), "", "sliders-horizontal") if can_admin?
        actions << post_action("import_ui.operations.purge", Ui.url("purge"), "import_ui.operations.purge_confirm", "", "x") if can_admin?
        actions
      end
    end

    # Vérifie une opération (essai à blanc) ; en HTMX, l'opération mise à
    # jour remplace l'ancienne.
    class OperationCheckHandler < Handler
      def get
        go(Ui.url("operations"))
      end

      def post
        result = Api.check(actor, [id_param])
        if htmx?
          view = Api.operation(actor, id_param)
          return render("import/_operation.html", {
            "operation"  => Present.operation(view, fmt, can_run?, ledger_codes),
            "form_error" => result.success? ? nil : messages(result),
            "next"       => field("next"),
          }, status: result.success? ? 200 : 422)
        end
        after(result, "import_ui.flash.checked", back(Ui.url("operations")))
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(back(Ui.url("operations")))
      end
    end

    # Actions groupées sur les opérations cochées.
    class OperationsActionHandler < Handler
      def get
        go(Ui.url("operations"))
      end

      def post
        ids = checked_ids
        url = back(Ui.url("operations"))
        case field("action")
        when "check"
          result = Api.check(actor, ids.empty? ? nil : ids)
          if result.success?
            report = result.value!
            flash["success"] = I18n.t("import_ui.flash.check_report", ready: report.ready, refused: report.refused)
          else
            flash["danger"] = messages(result)
          end
          go(url)
        when "transfer"
          result = Api.transfer(actor, ids)
          if result.failure?
            flash["danger"] = messages(result)
            return go(url)
          end
          report = result.value!
          flash["success"] = I18n.t("import_ui.flash.transferred", count: report.transferred.size) unless report.transferred.empty?
          flash["danger"] = I18n.t("import_ui.flash.transfer_failed", count: report.failed.size) unless report.failed.empty?
          go(url)
        when "discard"
          after_count(Api.discard(actor, ids), "import_ui.flash.discarded", url)
        when "restore"
          after_count(Api.restore(actor, ids), "import_ui.flash.restored", url)
        else
          go(url)
        end
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(back(Ui.url("operations")))
      end
    end

    # Supprime les opérations écartées et les doublons.
    class PurgeHandler < Handler
      def get
        go(Ui.url("operations"))
      end

      def post
        after_count(Api.purge(actor), "import_ui.flash.purged", Ui.url("operations"))
      end
    end
  end
end
