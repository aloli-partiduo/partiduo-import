# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten, B-EINV-001 du cœur).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)
      getter children : Hash(String, Array(Row))

      def initialize(values : Hash(String, String) | Hash(String, String?), @children = {} of String => Array(Row))
        @values = values.transform_values(&.as(String?))
      end

      def resolve_template_attribute(key : String)
        if list = children[key]?
          list.empty? ? nil : list
        else
          values[key]?
        end
      end
    end

    def self.row(values : Hash(String, String) | Hash(String, String?), children = {} of String => Array(Row)) : Row
      Row.new(values, children)
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("import:#{name}", **params)
    end

    def self.flag(value : Bool) : String?
      value ? "1" : nil
    end

    # Format de date affiché dans la langue (`dd/mm/yyyy` → `JJ/MM/AAAA`).
    def self.date_format_label(code : String) : String
      day, month, year = I18n.t("import_ui.date_letters").split(',')
      code.gsub("dd", day * 2).gsub("mm", month * 2).gsub("yyyy", year * 4).gsub("yy", year * 2)
    end

    # Classe Bulma du statut d'une opération.
    def self.status_class(status : String) : String
      case status
      when "transferred" then "is-success"
      when "duplicate"   then "is-warning"
      when "discarded"   then "is-light"
      else                    "is-info"
      end
    end

    # Présentation des vues du contrat (interne à l'interface).
    module Present
      alias Api = Import::Api

      def self.lines(lines : Array(Api::OperationLineView), fmt : PartiduoUi::Format) : Array(Row)
        lines.map do |line|
          code = [line.code, line.aux].reject(&.empty?).join(" / ")
          Ui.row({
            "row"       => line.row.to_s,
            "code"      => code,
            "code_name" => [line.code_label, line.aux_label].reject(&.empty?).join(" / ").presence,
            "label"     => line.label.presence,
            "side"      => line.side.presence.try { |side| I18n.t("import_ui.sides.#{side}") },
            "amount"    => fmt.amount(line.amount),
            "quantity"  => line.quantity.try { |value| fmt.amount(value) },
            "vat_code"  => line.vat_code.presence,
            "vat"       => line.vat_amount.try { |value| fmt.amount(value) },
            "analytic"  => line.analytic.presence,
            "letter"    => line.letter.presence,
          })
        end
      end

      def self.operation(view : Api::OperationView, fmt : PartiduoUi::Format, can_run : Bool, ledgers : Hash(Int64, String)) : Row
        problems = (view.read_problems + view.problems).map { |error| Ui.row({"message" => fmt.message(error)}) }
        Ui.row({
          "id"             => view.id.to_s,
          "date"           => fmt.date(view.date),
          "iso_date"       => view.date.to_s("%Y-%m-%d"),
          "label"          => view.label.presence || view.group_key,
          "receipt"        => view.receipt.presence,
          "third_party"    => view.third_party.presence,
          "ledger"         => view.ledger_id.try { |id| ledgers[id]? } || view.ledger_code.presence,
          "total"          => fmt.amount(view.total),
          "count"          => view.lines.size.to_s,
          "status"         => view.status,
          "status_label"   => I18n.t(view.status_key),
          "status_class"   => Ui.status_class(view.status),
          "ready"          => Ui.flag(view.ready?),
          "refused"        => Ui.flag(view.refused?),
          "unchecked"      => Ui.flag(view.pending? && view.checked_at.nil?),
          "recorded"       => Ui.flag(!view.recorded_entry_id.nil?),
          "recorded_url"   => view.recorded_entry_id.try { |id| Marten.routes.reverse("accounting:entry", id: id) },
          "reversed"       => Ui.flag(!view.reversed_entry_id.nil?),
          "entry_url"      => view.entry_id.try { |id| Marten.routes.reverse("accounting:entry", id: id) },
          "posted_receipt" => view.posted_receipt.presence,
          "batch_url"      => Ui.url("batch_detail", id: view.batch_id),
          "check_url"      => Ui.url("operation_check", id: view.id),
          "can_check"      => Ui.flag(can_run && view.pending?),
          "selectable"     => Ui.flag(can_run && view.status != "transferred"),
        }, {"problems" => problems, "lines" => lines(view.lines, fmt)})
      end

      def self.batch(view : Api::BatchView, fmt : PartiduoUi::Format, ledgers : Hash(Int64, String)) : Row
        Ui.row({
          "id"          => view.id.to_s,
          "url"         => Ui.url("batch_detail", id: view.id),
          "filename"    => view.filename,
          "kind"        => I18n.t(view.kind_key),
          "ledger_kind" => view.ledger_kind.presence.try { |kind| I18n.t("import.ledger_kinds.#{kind}") },
          "ledger"      => view.ledger_id.try { |id| ledgers[id]? },
          "created"     => fmt.date(view.created_at),
          "period"      => view.first_date.try { |first| "#{fmt.date(first)} – #{fmt.date(view.last_date)}" },
          "operations"  => view.operation_count.to_s,
          "pending"     => view.pending_count.to_s,
          "refused"     => view.refused_count.to_s,
          "transferred" => view.transferred_count.to_s,
          "duplicates"  => view.duplicate_count.to_s,
          "discarded"   => view.discarded_count.to_s,
          "total"       => fmt.amount(view.total),
          "encoding"    => view.encoding.presence,
        })
      end
    end
  end
end
