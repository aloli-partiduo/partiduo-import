# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Un fichier importé (historique, D-IMP-009) : genre (`csv`, `fec`),
  # genre de journal d'un CSV, format employé, journal choisi par défaut,
  # nom du fichier, pièce jointe du socle qui le conserve (`attachment_id`,
  # sans clé étrangère : D-IMP-003), empreinte SHA-256 (un même fichier
  # importé deux fois est refusé, sauf confirmation), encodage lu,
  # compteurs, anomalies de lecture (JSON : ligne, clé, paramètres).
  # Interne.
  class Batch < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :kind, :string, max_size: 8
    field :ledger_kind, :string, max_size: 16, blank: true, default: ""
    field :format_id, :big_int, blank: true, null: true
    field :ledger_id, :big_int, blank: true, null: true
    field :filename, :string, max_size: 255
    field :attachment_id, :big_int, blank: true, null: true
    field :sha256, :string, max_size: 64, index: true
    field :encoding, :string, max_size: 16, blank: true, default: ""
    field :operation_count, :int, default: 0
    field :duplicate_count, :int, default: 0
    field :issues, :text, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
