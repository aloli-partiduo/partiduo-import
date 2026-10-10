# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Opération lue, dans la zone d'attente (D-IMP-007) : un groupe de lignes
  # du fichier qui deviendra une écriture.
  #
  # * données de l'émetteur : code de journal, date, pièce, libellé,
  #   échéance, tiers (achats, ventes), devise ; `group_key` : code de
  #   regroupement (numéro d'écriture d'un FEC) ;
  # * `ledger_id` : journal du dossier retenu à la dernière vérification ;
  # * `total` : total des débits (ou toutes taxes, ou montant absolu) ;
  #   `fingerprint` : empreinte des doublons (D-IMP-008) ;
  # * `status` : `pending` (à traiter), `transferred` (écriture passée,
  #   `entry_id`, `posted_receipt` : pièce du cœur), `duplicate` (doublon
  #   signalé, `duplicate_of_id`), `discarded` (écartée) ;
  # * `recorded_entry_id` : écriture du journal de même date et de même
  #   montant déjà en comptabilité (signalée, pas écartée) ;
  # * `problems` : motifs du refus de la dernière vérification ou du
  #   dernier transfert (JSON : champ, clé, paramètres) ; `read_problems` :
  #   défauts de lecture de ses lignes (date, montant, sens illisibles…),
  #   qui l'empêchent à jamais d'être transférée ;
  # * `reversed_entry_id` : écriture transférée puis extournée (D-IMP-010).
  #
  # Interne.
  class Operation < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :batch_id, :big_int, index: true
    field :position, :int
    field :group_key, :string, max_size: 100, blank: true, default: ""
    field :ledger_code, :string, max_size: 50, blank: true, default: ""
    field :ledger_id, :big_int, blank: true, null: true, index: true
    field :date, :date
    field :receipt, :string, max_size: 100, blank: true, default: ""
    field :label, :string, max_size: 255, blank: true, default: ""
    field :due_date, :date, blank: true, null: true
    field :third_party, :string, max_size: 100, blank: true, default: ""
    field :currency, :string, max_size: 3, blank: true, default: ""
    field :total, :decimal, max_digits: 20, decimal_places: 4
    field :fingerprint, :string, max_size: 64, index: true
    field :status, :string, max_size: 16, default: "pending"
    field :duplicate_of_id, :big_int, blank: true, null: true
    field :recorded_entry_id, :big_int, blank: true, null: true
    field :entry_id, :big_int, blank: true, null: true, index: true
    field :posted_receipt, :string, max_size: 40, blank: true, default: ""
    field :reversed_entry_id, :big_int, blank: true, null: true
    field :problems, :text, blank: true, default: ""
    field :read_problems, :text, blank: true, default: ""
    field :checked_at, :date_time, blank: true, null: true
    field :transferred_by_id, :big_int, blank: true, null: true
    field :transferred_at, :date_time, blank: true, null: true

    with_timestamp_fields
  end
end
