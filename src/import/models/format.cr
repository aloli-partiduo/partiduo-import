# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Format CSV enregistré (D-IMP-005) : genre de journal visé (`purchase`,
  # `sale`, `financial`, `misc`), journal proposé par défaut, lecture
  # (séparateur, délimiteur de texte, encodage, lignes d'en-tête, dates,
  # séparateurs décimal et de milliers) et correspondance des colonnes
  # (`column_map` : clé du champ de chaque colonne, séparées par des
  # virgules, vide pour une colonne ignorée). Interne.
  class Format < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :name, :string, max_size: 100
    field :description, :string, max_size: 255, blank: true, default: ""
    field :ledger_kind, :string, max_size: 16
    field :ledger_id, :big_int, blank: true, null: true
    field :separator, :string, max_size: 16, default: "semicolon"
    field :quote, :string, max_size: 16, default: "double"
    field :encoding, :string, max_size: 16, default: "utf-8"
    field :skip_lines, :int, default: 1
    field :date_format, :string, max_size: 16, default: "dd/mm/yyyy"
    field :decimal_separator, :string, max_size: 16, default: "comma"
    field :thousands_separator, :string, max_size: 16, default: "none"
    field :column_map, :text

    with_timestamp_fields
  end
end
