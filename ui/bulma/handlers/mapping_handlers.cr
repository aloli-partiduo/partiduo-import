# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Ui
    # `/ext/IMPORT/mappings` : correspondances des codes de l'émetteur
    # (`import.admin`, D-IMP-006) — journaux, codes de TVA, comptes et
    # fiches — et, en tête, les codes inconnus des opérations à traiter,
    # chacun avec un petit formulaire envoyé en HTMX (et, pour un compte
    # d'un FEC, « Créer le compte »).
    class MappingsHandler < Handler
      def get
        mappings = Api.mappings(actor).map do |view|
          Ui.row({
            "kind"   => I18n.t(view.kind_key),
            "source" => view.source,
            "target" => view.target,
            "type"   => I18n.t(view.target_type_key),
            "label"  => view.target_label,
            "note"   => view.note.presence,
            "url"    => Ui.url("mapping_edit", id: view.id),
          })
        end
        page("import/mappings.html", {
          "title"    => I18n.t("import.menu.import_mappings"),
          "crumbs"   => settings_crumbs({I18n.t("import.menu.import_mappings"), nil}),
          "actions"  => [link_action("import_ui.mappings.new", Ui.url("mapping_new"), "primary", "plus")],
          "unknown"  => Api.unknown_codes(actor).map { |view| UnknownRow.build(view) },
          "mappings" => mappings,
        })
      end
    end

    # Ligne d'un code inconnu (gabarit `_unknown.html`).
    module UnknownRow
      def self.build(view : Api::UnknownCodeView, done : String? = nil, error : String? = nil) : Row
        kind = view.kind == "account" ? "code" : view.kind
        types = Api::TARGET_TYPES[kind].map do |type|
          Ui.row({"value" => type, "label" => I18n.t("import.target_types.#{type}"),
                  "selected" => Ui.flag(type == (view.kind == "account" ? "account" : Api::TARGET_TYPES[kind].first))})
        end
        Ui.row({
          "id"        => "imp-unknown-#{view.kind}-#{view.source.gsub(/[^A-Za-z0-9]+/, "-")}",
          "kind"      => kind,
          "kind_name" => I18n.t("import.mapping_kinds.#{kind}"),
          "source"    => view.source,
          "label"     => view.label.presence,
          "count"     => I18n.t("import_ui.mappings.count", count: view.count),
          "count_raw" => view.count.to_s,
          "raw_kind"  => view.kind,
          "creatable" => Ui.flag(view.kind == "account"),
          "done"      => done,
          "error"     => error,
        }, {"types" => types})
      end
    end

    # Formulaire d'une correspondance (création, modification).
    abstract class MappingScreen < Handler
      FIELDS = %w[kind source target_type target note]

      def values_of(view : Api::MappingView?) : Hash(String, String)
        return {"kind" => query("kind").presence || "code", "source" => query("source"), "target_type" => "account"} unless view
        {"kind" => view.kind, "source" => view.source, "target_type" => view.target_type, "target" => view.target, "note" => view.note}
      end

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name)} }
      end

      def mapping_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        types = Api::TARGET_TYPES.values.flatten.uniq!
        Form.new([Form::Group.new(nil, [
          Form::Field.new("kind", I18n.t("import_ui.mappings.kind"), "select", value.call("kind"),
            options: code_options(Api::MAPPING_KINDS, "import.mapping_kinds"), required: true),
          Form::Field.new("source", I18n.t("import_ui.mappings.source"), value: value.call("source"), required: true,
            maxlength: 100, mono: true, help: I18n.t("import_ui.mappings.source_help")),
          Form::Field.new("target_type", I18n.t("import_ui.mappings.target_type"), "select", value.call("target_type"),
            options: code_options(types, "import.target_types"), required: true),
          Form::Field.new("target", I18n.t("import_ui.mappings.target"), value: value.call("target"), required: true,
            maxlength: 100, mono: true, help: I18n.t("import_ui.mappings.target_help")),
          Form::Field.new("note", I18n.t("import_ui.mappings.note"), value: value.call("note"), maxlength: 255),
        ])])
      end

      def input : Api::MappingInput
        Api::MappingInput.new(kind: field("kind"), source: field("source"), target_type: field("target_type"),
          target: field("target"), note: field("note"))
      end

      def mapping_crumbs(title : String) : Array(Screen::Crumb)
        settings_crumbs({I18n.t("import.menu.import_mappings"), Ui.url("mappings")}, {title, nil})
      end
    end

    class MappingNewHandler < MappingScreen
      def get
        show(mapping_form(values_of(nil)))
      end

      def post
        form = mapping_form(submitted)
        result = Api.create_mapping(actor, input)
        if result.success?
          flash["success"] = I18n.t("import_ui.flash.saved")
          return go(Ui.url("mappings"))
        end
        show(form.add_errors(result.errors, fmt))
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("import_ui.mappings.new")
        form_page(title, mapping_crumbs(title), form, Ui.url("mapping_new"), I18n.t("ui.forms.create"), Ui.url("mappings"),
          intro: I18n.t("import_ui.mappings.intro"))
      end
    end

    class MappingEditHandler < MappingScreen
      def get
        view = Api.mapping(actor, id_param)
        show(view, mapping_form(values_of(view)))
      end

      def post
        view = Api.mapping(actor, id_param)
        form = mapping_form(submitted)
        result = Api.update_mapping(actor, view.id, input)
        if result.success?
          flash["success"] = I18n.t("import_ui.flash.saved")
          return go(Ui.url("mappings"))
        end
        show(view, form.add_errors(result.errors, fmt))
      end

      private def show(view : Api::MappingView, form : Form) : Marten::HTTP::Response
        actions = [post_action("import_ui.mappings.delete", Ui.url("mapping_delete", id: view.id),
          "import_ui.mappings.delete_confirm", "danger", "x")]
        form_page(view.source, mapping_crumbs(view.source), form, Ui.url("mapping_edit", id: view.id), I18n.t("ui.forms.save"),
          Ui.url("mappings"), actions, intro: I18n.t("import_ui.mappings.intro"))
      end
    end

    class MappingDeleteHandler < Handler
      def get
        go(Ui.url("mappings"))
      end

      def post
        after(Api.delete_mapping(actor, id_param), "import_ui.flash.deleted", Ui.url("mappings"))
      end
    end

    # Correspondance saisie sur la ligne d'un code inconnu ; en HTMX, la
    # ligne est remplacée par la réponse (faite, ou refusée avec son
    # message).
    class MappingQuickHandler < MappingScreen
      def get
        go(Ui.url("mappings"))
      end

      def post
        result = Api.create_mapping(actor, input)
        respond(result.success?, result.success? ? I18n.t("import_ui.mappings.done", target: field("target")) : messages(result))
      end

      def respond(success : Bool, message : String) : Marten::HTTP::Response
        unless htmx?
          flash[success ? "success" : "danger"] = message
          return go(Ui.url("mappings"))
        end
        kind = field("unknown_kind").presence || field("kind")
        view = Api::UnknownCodeView.new(kind, field("source"), field("label"), field("count").to_i32? || 0)
        render("import/_unknown.html", {"code" => UnknownRow.build(view, success ? message : nil, success ? nil : message)},
          status: success ? 200 : 422)
      end
    end

    # Crée dans le plan le compte qu'un FEC cite, avec son libellé.
    class AccountCreateHandler < MappingQuickHandler
      def post
        result = Api.create_account(actor, field("source"), field("label"))
        respond(result.success?, result.success? ? I18n.t("import_ui.mappings.account_created", number: field("source")) : messages(result))
      rescue ex : Partiduo::Api::Forbidden
        respond(false, I18n.t(ex.key))
      end
    end
  end
end
