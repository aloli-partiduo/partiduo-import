# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Vérification des opérations à traiter (D-IMP-007) : essai à blanc par
  # `Checker`, import par import (même lecture des correspondances), puis
  # enregistrement du journal retenu, des motifs de refus et de
  # l'écriture semblable déjà passée. Interne.
  module Verification
    def self.check!(actor : Partiduo::Api::Actor, rows : Array(Operation)) : {Int32, Int32}
      ready = refused = 0
      rows.group_by(&.batch_id!.to_i64).each do |batch_id, list|
        batch = Batch.filter(id: batch_id).first || next
        resolver = Resolver.new(actor, batch.kind.to_s, batch.ledger_kind.to_s, batch.ledger_id.try(&.to_i64))
        # Les défauts de lecture restent à part (`read_problems`) : ils
        # bloquent l'opération quoi que dise l'essai.
        data = list.map { |row| Records.data(row) }
        outcomes = Checker.run(actor, resolver, data, list.map { |row| "#{Poster::SOURCE}#{row.id}" },
          batch.attachment_id.try(&.to_i64))
        list.each_with_index do |row, index|
          outcome = outcomes[index]
          own = outcome.problems
          row.ledger_id = outcome.ledger.try(&.id)
          row.problems = Records.dump(own)
          row.recorded_entry_id = outcome.recorded_entry_id
          row.checked_at = Partiduo::Config.now
          row.save!
          own.empty? && row.read_problems.to_s.empty? ? (ready += 1) : (refused += 1)
        end
      end
      {ready, refused}
    end
  end
end
