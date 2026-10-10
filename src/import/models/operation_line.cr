# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Ligne d'une opération en attente, telle que l'émetteur l'a écrite :
  # rang dans l'opération, numéro de ligne du fichier, code (compte ou
  # fiche ; article ou compte d'une facture ; contrepartie d'un extrait),
  # compte auxiliaire d'un FEC et libellés, libellé de la ligne, sens et
  # montant (opérations diverses, FEC), montant hors taxe, quantité, code
  # et montant de TVA (achats, ventes), montant signé (financier), postes
  # analytiques, code de lettrage. Après transfert : ligne d'écriture
  # produite (`entry_line_id`) et lettrage repris (`matching_id`). Interne.
  class OperationLine < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :operation_id, :big_int, index: true
    field :position, :int
    field :row, :int
    field :code, :string, max_size: 100, blank: true, default: ""
    field :code_label, :string, max_size: 255, blank: true, default: ""
    field :aux, :string, max_size: 100, blank: true, default: ""
    field :aux_label, :string, max_size: 255, blank: true, default: ""
    field :label, :string, max_size: 255, blank: true, default: ""
    field :side, :string, max_size: 8, blank: true, default: ""
    field :amount, :decimal, max_digits: 20, decimal_places: 4
    field :quantity, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :vat_code, :string, max_size: 20, blank: true, default: ""
    field :vat_amount, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :analytic, :string, max_size: 100, blank: true, default: ""
    field :letter, :string, max_size: 50, blank: true, default: ""
    field :entry_line_id, :big_int, blank: true, null: true
    field :matching_id, :big_int, blank: true, null: true
  end
end
