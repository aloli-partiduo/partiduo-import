# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension d'import d'opérations en masse : formats CSV,
# correspondances (journaux, codes de TVA, comptes et fiches de
# l'émetteur), imports, opérations en attente et leurs lignes.
#
# Intégrité en base : genres, statuts, sens et réglages contrôlés ; un code
# source n'a qu'une correspondance par genre ; une opération transférée
# porte son écriture. Les liens vers le cœur (journal, écriture, ligne
# d'écriture, pièce jointe, lettrage) sont des identifiants relus par le
# contrat, sans clé étrangère (D-IMP-003).
class Migration::Import::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE import_format
        ADD CONSTRAINT import_format_name_check CHECK (btrim(name) <> ''),
        ADD CONSTRAINT import_format_kind_check CHECK (ledger_kind IN ('purchase', 'sale', 'financial', 'misc')),
        ADD CONSTRAINT import_format_separator_check CHECK (separator IN ('comma', 'semicolon', 'tab', 'pipe')),
        ADD CONSTRAINT import_format_quote_check CHECK (quote IN ('double', 'single', 'none')),
        ADD CONSTRAINT import_format_encoding_check CHECK (encoding IN ('utf-8', 'windows-1252', 'iso-8859-15')),
        ADD CONSTRAINT import_format_decimal_check CHECK (decimal_separator IN ('comma', 'dot')),
        ADD CONSTRAINT import_format_thousands_check CHECK (thousands_separator IN ('none', 'space', 'dot', 'comma', 'apostrophe')),
        ADD CONSTRAINT import_format_skip_check CHECK (skip_lines BETWEEN 0 AND 50),
        ADD CONSTRAINT import_format_columns_check CHECK (btrim(column_map) <> '')
      SQL
    {"CREATE UNIQUE INDEX import_format_name_unique ON import_format (lower(name))",
     "DROP INDEX IF EXISTS import_format_name_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE import_mapping
        ADD CONSTRAINT import_mapping_kind_check CHECK (kind IN ('ledger', 'vat', 'code')),
        ADD CONSTRAINT import_mapping_target_check CHECK ((kind = 'ledger' AND target_type = 'ledger')
          OR (kind = 'vat' AND target_type = 'vat') OR (kind = 'code' AND target_type IN ('account', 'card'))),
        ADD CONSTRAINT import_mapping_source_check CHECK (btrim(source) <> ''),
        ADD CONSTRAINT import_mapping_target_blank_check CHECK (btrim(target) <> '')
      SQL
    {"CREATE UNIQUE INDEX import_mapping_source_unique ON import_mapping (kind, lower(source))",
     "DROP INDEX IF EXISTS import_mapping_source_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE import_batch
        ADD CONSTRAINT import_batch_kind_check CHECK (kind IN ('csv', 'fec')),
        ADD CONSTRAINT import_batch_ledger_kind_check CHECK ((kind = 'fec' AND ledger_kind = '')
          OR (kind = 'csv' AND ledger_kind IN ('purchase', 'sale', 'financial', 'misc'))),
        ADD CONSTRAINT import_batch_format_fk FOREIGN KEY (format_id) REFERENCES import_format (id) ON DELETE SET NULL,
        ADD CONSTRAINT import_batch_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE import_operation
        ADD CONSTRAINT import_operation_status_check CHECK (status IN ('pending', 'transferred', 'duplicate', 'discarded')),
        ADD CONSTRAINT import_operation_transferred_check CHECK ((status = 'transferred') = (entry_id IS NOT NULL)),
        ADD CONSTRAINT import_operation_batch_fk FOREIGN KEY (batch_id) REFERENCES import_batch (id) ON DELETE CASCADE,
        ADD CONSTRAINT import_operation_duplicate_fk FOREIGN KEY (duplicate_of_id) REFERENCES import_operation (id) ON DELETE SET NULL,
        ADD CONSTRAINT import_operation_transferred_by_fk FOREIGN KEY (transferred_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE INDEX import_operation_status_idx ON import_operation (status, date)",
     "DROP INDEX IF EXISTS import_operation_status_idx"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE import_operation_line
        ADD CONSTRAINT import_operation_line_side_check CHECK (side IN ('', 'debit', 'credit')),
        ADD CONSTRAINT import_operation_line_operation_fk FOREIGN KEY (operation_id) REFERENCES import_operation (id) ON DELETE CASCADE
      SQL
  ]

  def plan
    create_table :import_format do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 100
      column :description, :string, max_size: 255, default: ""
      column :ledger_kind, :string, max_size: 16
      column :ledger_id, :big_int, null: true
      column :separator, :string, max_size: 16, default: "semicolon"
      column :quote, :string, max_size: 16, default: "double"
      column :encoding, :string, max_size: 16, default: "utf-8"
      column :skip_lines, :int, default: 1
      column :date_format, :string, max_size: 16, default: "dd/mm/yyyy"
      column :decimal_separator, :string, max_size: 16, default: "comma"
      column :thousands_separator, :string, max_size: 16, default: "none"
      column :column_map, :text
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :import_mapping do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 16
      column :source, :string, max_size: 100
      column :target_type, :string, max_size: 16
      column :target, :string, max_size: 100
      column :note, :string, max_size: 255, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :import_batch do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 8
      column :ledger_kind, :string, max_size: 16, default: ""
      column :format_id, :big_int, null: true
      column :ledger_id, :big_int, null: true
      column :filename, :string, max_size: 255
      column :attachment_id, :big_int, null: true
      column :sha256, :string, max_size: 64, index: true
      column :encoding, :string, max_size: 16, default: ""
      column :operation_count, :int, default: 0
      column :duplicate_count, :int, default: 0
      column :issues, :text, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :import_operation do
      column :id, :big_int, primary_key: true, auto: true
      column :batch_id, :big_int, index: true
      column :position, :int
      column :group_key, :string, max_size: 100, default: ""
      column :ledger_code, :string, max_size: 50, default: ""
      column :ledger_id, :big_int, null: true, index: true
      column :date, :date
      column :receipt, :string, max_size: 100, default: ""
      column :label, :string, max_size: 255, default: ""
      column :due_date, :date, null: true
      column :third_party, :string, max_size: 100, default: ""
      column :currency, :string, max_size: 3, default: ""
      column :total, :decimal, max_digits: 20, decimal_places: 4
      column :fingerprint, :string, max_size: 64, index: true
      column :status, :string, max_size: 16, default: "pending"
      column :duplicate_of_id, :big_int, null: true
      column :recorded_entry_id, :big_int, null: true
      column :entry_id, :big_int, null: true, index: true
      column :posted_receipt, :string, max_size: 40, default: ""
      column :reversed_entry_id, :big_int, null: true
      column :problems, :text, default: ""
      column :read_problems, :text, default: ""
      column :checked_at, :date_time, null: true
      column :transferred_by_id, :big_int, null: true
      column :transferred_at, :date_time, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :import_operation_line do
      column :id, :big_int, primary_key: true, auto: true
      column :operation_id, :big_int, index: true
      column :position, :int
      column :row, :int
      column :code, :string, max_size: 100, default: ""
      column :code_label, :string, max_size: 255, default: ""
      column :aux, :string, max_size: 100, default: ""
      column :aux_label, :string, max_size: 255, default: ""
      column :label, :string, max_size: 255, default: ""
      column :side, :string, max_size: 8, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :quantity, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :vat_code, :string, max_size: 20, default: ""
      column :vat_amount, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :analytic, :string, max_size: 100, default: ""
      column :letter, :string, max_size: 50, default: ""
      column :entry_line_id, :big_int, null: true
      column :matching_id, :big_int, null: true
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
