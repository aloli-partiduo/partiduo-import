# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Ui
    # `/ext/IMPORT/formats` : formats CSV enregistrés (`import.admin`,
    # D-IMP-005).
    class FormatsHandler < Handler
      def get
        columns = [
          Table::Column.new("name", I18n.t("import_ui.formats.name")),
          Table::Column.new("ledger_kind", I18n.t("import_ui.formats.ledger_kind")),
          Table::Column.new("separator", I18n.t("import_ui.formats.separator"), secondary: true),
          Table::Column.new("date_format", I18n.t("import_ui.formats.date_format"), "mono", secondary: true),
          Table::Column.new("columns", I18n.t("import_ui.formats.columns_count"), "number", secondary: true),
          Table::Column.new("batches", I18n.t("import_ui.formats.batches"), "number"),
        ]
        rows = Api.formats(actor).map do |view|
          url = Ui.url("format_edit", id: view.id)
          Table::Row.new([
            Table::Cell.new(view.name, url),
            Table::Cell.new(I18n.t(view.ledger_kind_key)),
            Table::Cell.new(I18n.t("import.separators.#{view.separator}")),
            Table::Cell.new(Ui.date_format_label(view.date_format)),
            Table::Cell.new(view.columns.size.to_s, sort: BigDecimal.new(view.columns.size)),
            Table::Cell.new(view.batch_count.to_s, sort: BigDecimal.new(view.batch_count)),
          ])
        end
        table = Table.new(I18n.t("import.menu.import_formats"), columns, rows, Ui.url("formats"),
          empty_message: I18n.t("import_ui.formats.none"), id: "imp-formats")
        list_page(I18n.t("import.menu.import_formats"), table,
          settings_crumbs({I18n.t("import.menu.import_formats"), nil}), "import_ui.formats.csv_name",
          [link_action("import_ui.formats.new", Ui.url("format_new"), "primary", "plus")],
          intro: I18n.t("import_ui.formats.intro"))
      end
    end

    # Formulaire d'un format CSV (création, modification) : réglages de
    # lecture, puis rang de la colonne de chaque champ (correspondance des
    # colonnes).
    abstract class FormatScreen < Handler
      SETTINGS = %w[name description ledger_kind ledger_id separator quote encoding skip_lines date_format decimal_separator
        thousands_separator]

      def values_of(view : Api::FormatView?) : Hash(String, String)
        unless view
          return {"ledger_kind" => "misc", "separator" => "semicolon", "quote" => "double", "encoding" => "utf-8",
                  "skip_lines" => "1", "date_format" => "dd/mm/yyyy", "decimal_separator" => "comma",
                  "thousands_separator" => "none"}
        end
        values = {
          "name" => view.name, "description" => view.description, "ledger_kind" => view.ledger_kind,
          "ledger_id" => view.ledger_id.to_s, "separator" => view.separator, "quote" => view.quote,
          "encoding" => view.encoding, "skip_lines" => view.skip_lines.to_s, "date_format" => view.date_format,
          "decimal_separator" => view.decimal_separator, "thousands_separator" => view.thousands_separator,
        }
        Api::FIELDS.each { |name| values["column.#{name}"] = view.column_of(name).to_s }
        values
      end

      def submitted : Hash(String, String)
        values = SETTINGS.to_h { |name| {name, field(name)} }
        Api::FIELDS.each { |name| values["column.#{name}"] = field("column.#{name}") }
        values
      end

      def format_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        general = [
          Form::Field.new("name", I18n.t("import_ui.formats.name"), value: value.call("name"), required: true, maxlength: 100),
          Form::Field.new("description", I18n.t("import_ui.formats.description"), value: value.call("description"), maxlength: 255),
          Form::Field.new("ledger_kind", I18n.t("import_ui.formats.ledger_kind"), "select", value.call("ledger_kind"),
            options: code_options(Api::LEDGER_KINDS, "import.ledger_kinds"), required: true,
            help: I18n.t("import_ui.formats.ledger_kind_help")),
          Form::Field.new("ledger_id", I18n.t("import_ui.formats.ledger"), "select", value.call("ledger_id"),
            options: [blank_option] + ledger_options, help: I18n.t("import_ui.formats.ledger_help")),
        ]
        reading = [
          Form::Field.new("separator", I18n.t("import_ui.formats.separator"), "select", value.call("separator"),
            options: code_options(Api::SEPARATORS, "import.separators"), required: true),
          Form::Field.new("quote", I18n.t("import_ui.formats.quote"), "select", value.call("quote"),
            options: code_options(Api::QUOTES, "import.quotes"), required: true),
          Form::Field.new("encoding", I18n.t("import_ui.formats.encoding"), "select", value.call("encoding"),
            options: code_options(Api::ENCODINGS, "import.encodings"), required: true),
          Form::Field.new("skip_lines", I18n.t("import_ui.formats.skip_lines"), "number", value.call("skip_lines"),
            mono: true, help: I18n.t("import_ui.formats.skip_lines_help")),
          Form::Field.new("date_format", I18n.t("import_ui.formats.date_format"), "select", value.call("date_format"),
            options: date_format_options, required: true),
          Form::Field.new("decimal_separator", I18n.t("import_ui.formats.decimal_separator"), "select",
            value.call("decimal_separator"), options: code_options(Api::DECIMAL_SEPARATORS, "import.decimal_separators")),
          Form::Field.new("thousands_separator", I18n.t("import_ui.formats.thousands_separator"), "select",
            value.call("thousands_separator"), options: code_options(Api::THOUSANDS_SEPARATORS, "import.thousands_separators")),
        ]
        columns = Api::FIELDS.map do |name|
          Form::Field.new("column.#{name}", I18n.t("import.fields.#{name}"), "number", value.call("column.#{name}"), mono: true,
            help: I18n.t("import_ui.formats.field_help.#{name}"))
        end
        Form.new([Form::Group.new(nil, general), Form::Group.new(I18n.t("import_ui.formats.reading"), reading),
                  Form::Group.new(I18n.t("import_ui.formats.columns_legend"), columns)])
      end

      # Entrée du contrat ; la correspondance des colonnes est rebâtie à
      # partir du rang donné à chaque champ.
      def read_input(form : Form) : Api::FormatInput?
        ranks = {} of String => Int32
        Api::FIELDS.each do |name|
          text = field("column.#{name}")
          next if text.empty?
          rank = text.to_i32?
          if rank.nil? || !(1..Api::MAX_COLUMNS).includes?(rank)
            form.add_error("column.#{name}", I18n.t("import_ui.formats.rank_invalid", max: Api::MAX_COLUMNS))
          elsif ranks.values.includes?(rank)
            form.add_error("column.#{name}", I18n.t("import_ui.formats.rank_taken"))
          else
            ranks[name] = rank
          end
        end
        skip = int_field("skip_lines")
        form.add_error("skip_lines", I18n.t("ui.forms.invalid_integer")) if skip.nil? && !field("skip_lines").empty?
        return if form.invalid
        columns = Array.new(ranks.values.max? || 0, "")
        ranks.each { |name, rank| columns[rank - 1] = name }
        Api::FormatInput.new(name: field("name"), description: field("description"), ledger_kind: field("ledger_kind"),
          columns: columns, ledger_id: id_field("ledger_id"), separator: field("separator"), quote: field("quote"),
          encoding: field("encoding"), skip_lines: skip || 0, date_format: field("date_format"),
          decimal_separator: field("decimal_separator"), thousands_separator: field("thousands_separator"))
      end

      def format_crumbs(title : String) : Array(Screen::Crumb)
        settings_crumbs({I18n.t("import.menu.import_formats"), Ui.url("formats")}, {title, nil})
      end
    end

    class FormatNewHandler < FormatScreen
      def get
        show(format_form(values_of(nil)))
      end

      def post
        form = format_form(submitted)
        if input = read_input(form)
          result = Api.create_format(actor, input)
          if result.success?
            flash["success"] = I18n.t("import_ui.flash.saved")
            return go(Ui.url("formats"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("import_ui.formats.new")
        form_page(title, format_crumbs(title), form, Ui.url("format_new"), I18n.t("ui.forms.create"), Ui.url("formats"),
          intro: I18n.t("import_ui.formats.form_intro"))
      end
    end

    class FormatEditHandler < FormatScreen
      def get
        view = Api.format(actor, id_param)
        show(view, format_form(values_of(view)))
      end

      def post
        view = Api.format(actor, id_param)
        form = format_form(submitted)
        if input = read_input(form)
          result = Api.update_format(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("import_ui.flash.saved")
            return go(Ui.url("formats"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::FormatView, form : Form) : Marten::HTTP::Response
        actions = [post_action("import_ui.formats.delete", Ui.url("format_delete", id: view.id),
          "import_ui.formats.delete_confirm", "danger", "x")]
        form_page(view.name, format_crumbs(view.name), form, Ui.url("format_edit", id: view.id), I18n.t("ui.forms.save"),
          Ui.url("formats"), actions, intro: I18n.t("import_ui.formats.form_intro"))
      end
    end

    class FormatDeleteHandler < Handler
      def get
        go(Ui.url("formats"))
      end

      def post
        after(Api.delete_format(actor, id_param), "import_ui.flash.deleted", Ui.url("formats"))
      end
    end
  end
end
