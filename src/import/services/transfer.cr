# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Transfert des opérations vers la Comptabilité (D-IMP-007) : une écriture
  # par opération (une par ligne d'un extrait financier), par le service
  # d'écriture du cœur, avec l'acteur réel, la numérotation du journal et la
  # pièce jointe de l'import. Chaque opération passe dans son point de
  # sauvegarde : un refus reste sur l'opération, avec ses motifs, sans
  # empêcher les autres. Seule une opération à traiter, sans défaut de
  # lecture, est transférée ; un doublon ou une opération écartée ne l'est
  # jamais. Interne.
  module Transfer
    alias Result = Partiduo::Api::Result

    def self.run(actor : Partiduo::Api::Actor, rows : Array(Operation)) : {Array(Operation), Array(Operation)}
      done = [] of Operation
      failed = [] of Operation
      resolvers = {} of Int64 => {Resolver, Int64?}
      rows.each do |row|
        next unless row.status == "pending"
        batch_id = row.batch_id!.to_i64
        resolver, attachment_id = resolvers.put_if_absent(batch_id) do
          batch = Records.batch!(batch_id)
          {Resolver.new(actor, batch.kind.to_s, batch.ledger_kind.to_s, batch.ledger_id.try(&.to_i64)),
           batch.attachment_id.try(&.to_i64)}
        end
        if post(actor, row, resolver, attachment_id)
          done << row
        else
          failed << row
        end
      end
      {done, failed}
    end

    # Passe l'écriture d'une opération ; `false` si elle est refusée (motifs
    # gardés sur l'opération).
    private def self.post(actor : Partiduo::Api::Actor, row : Operation, resolver : Resolver, attachment_id : Int64?) : Bool
      unless row.read_problems.to_s.empty?
        return false
      end
      lines = OperationLine.filter(operation_id: row.id).order(:position).to_a
      result = Partiduo::Api::Transaction.run do
        locked = Operation.filter(id: row.id).lock.first
        next Result(Int64).failure(Records.error(Partiduo::Api::FieldError::BASE, "operation.not_pending")) unless locked.try(&.status) == "pending"
        planned, errors, ledger = resolver.resolve(Records.data(row, lines), "#{Poster::SOURCE}#{row.id}", attachment_id)
        row.ledger_id = ledger.try(&.id)
        next Result(Int64).failure(errors) if planned.nil?
        posted = Poster.post(actor, planned)
        next Result(Int64).failure(posted.errors) if posted.failure?
        entries = posted.value!
        entry = entries.first
        row.status = "transferred"
        row.entry_id = entry.id
        row.posted_receipt = entry.receipt.to_s[0, 40]
        row.problems = ""
        row.transferred_by_id = actor.user_id
        row.transferred_at = Partiduo::Config.now
        row.save!
        link_lines(entry, lines)
        Result(Int64).success(entry.id)
      end
      return true if result.success?
      row.problems = Records.dump(result.errors)
      row.checked_at = Partiduo::Config.now
      row.save!
      false
    end

    # Ligne d'écriture produite par chaque ligne saisie (`input_index`),
    # pour reprendre le lettrage d'un FEC (D-IMP-012).
    private def self.link_lines(entry : Partiduo::Api::Accounting::EntryView, lines : Array(OperationLine)) : Nil
      produced = entry.lines
      produced.each do |item|
        index = item.input_index || next
        line = lines.find(&.position.==(index)) || next
        line.entry_line_id = item.id
        line.save!
      end
    end
  end
end
