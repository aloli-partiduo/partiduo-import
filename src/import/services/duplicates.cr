# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Doublons (D-IMP-008) : une opération déjà importée, à traiter ou
  # transférée, a la même empreinte — genre du fichier, journal de
  # l'émetteur (ou journal choisi), date, pièce, total, libellé normalisé et
  # nombre de lignes. Les occurrences sont comptées : deux opérations
  # identiques d'un même fichier restent deux opérations tant que le
  # dossier n'en connaît qu'une. Un doublon est signalé et mis de côté, pas
  # supprimé ; on peut le reprendre. Interne.
  module Duplicates
    def self.fingerprint(kind : String, ledger_kind : String, default_ledger_id : Int64?,
                         operation : Parsers::ParsedOperation) : String
      label = operation.label.downcase.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").gsub(/[^a-z0-9]+/, " ").strip
      ledger = operation.ledger_code.presence || "##{default_ledger_id}"
      total = (operation.total(kind == "fec" ? "misc" : ledger_kind) * 10_000).to_big_i.to_s
      Digest::SHA256.hexdigest([kind, ledger_kind, ledger.downcase, operation.date.to_s("%Y-%m-%d"), operation.receipt.downcase,
                                total, label, operation.lines.size.to_s].join('|'))
    end

    # Pour chaque empreinte, opérations déjà connues (à traiter ou
    # transférées) dans l'ordre de leur import.
    def self.known(fingerprints : Array(String)) : Hash(String, Array(Int64))
      return {} of String => Array(Int64) if fingerprints.empty?
      Operation.filter(fingerprint__in: fingerprints.uniq, status__in: %w[pending transferred]).order(:id).to_a
        .group_by(&.fingerprint.to_s).transform_values(&.map(&.id!.to_i64))
    end

    # Opération connue dont chaque opération du fichier serait le doublon
    # (`nil` : nouvelle), en comptant les occurrences.
    def self.matches(fingerprints : Array(String)) : Array(Int64?)
      known = known(fingerprints)
      seen = Hash(String, Int32).new(0)
      fingerprints.map do |print|
        rank = seen[print]
        seen[print] += 1
        known[print]?.try(&.[rank]?)
      end
    end
  end
end
