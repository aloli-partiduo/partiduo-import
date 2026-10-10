# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Correspondance d'un code de l'émetteur vers le dossier (D-IMP-006) :
  #
  # * `ledger` : code de journal du fichier → code d'un journal du dossier ;
  # * `vat` : code de TVA du fichier → code d'un taux du dossier (fonction
  #   de l'extension legacy de correspondance des codes de TVA) ;
  # * `code` : compte ou fiche de l'émetteur (compte général, compte
  #   auxiliaire, quick code) → compte (`target_type` `account`) ou fiche
  #   (`card`) du dossier.
  #
  # Un code source n'a qu'une correspondance par genre, sans égard à la
  # casse. Interne.
  class Mapping < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :kind, :string, max_size: 16
    field :source, :string, max_size: 100
    field :target_type, :string, max_size: 16
    field :target, :string, max_size: 100
    field :note, :string, max_size: 255, blank: true, default: ""

    with_timestamp_fields
  end
end
