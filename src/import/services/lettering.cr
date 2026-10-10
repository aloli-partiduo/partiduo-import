# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Reprise du lettrage d'un FEC (D-IMP-012) : les lignes transférées d'un
  # même compte (et compte auxiliaire) qui portent le même code
  # `EcritureLet` sont lettrées ensemble par `Partiduo::Api::Accounting.
  # match_lines`, quand *toutes* les lignes de ce code dans l'import sont
  # transférées. Un lettrage refusé par la Comptabilité (comptes
  # différents après correspondance…) est signalé avec son code. Les
  # lignes lettrées ne le sont pas deux fois. Interne.
  module Lettering
    alias FieldError = Partiduo::Api::FieldError

    def self.run(actor : Partiduo::Api::Actor, batch : Batch) : {Int32, Array(FieldError)}
      operations = Operation.filter(batch_id: batch.id).to_a.index_by(&.id!.to_i64)
      lines = OperationLine.filter(operation_id__in: operations.keys).exclude(letter: "").order(:operation_id, :position).to_a
      matched = 0
      problems = [] of FieldError
      lines.group_by { |line| {line.code.to_s, line.aux.to_s, line.letter.to_s} }.each do |(code, aux, letter), group|
        next if group.size < 2 || group.all?(&.matching_id)
        ready = group.all? { |line| operations[line.operation_id!.to_i64].status == "transferred" && line.entry_line_id }
        params = {"letter" => letter, "account" => aux.presence || code}
        unless ready
          problems << Records.error("letter", "lettering.pending", params)
          next
        end
        result = Partiduo::Api::Accounting.match_lines(actor, group.compact_map(&.entry_line_id.try(&.to_i64)))
        if result.failure?
          problems.concat(result.errors.map { |error| FieldError.new("letter", error.key, error.params.merge(params)) })
          next
        end
        matching_id = result.value!.id
        group.each do |line|
          line.matching_id = matching_id
          line.save!
        end
        matched += 1
      end
      {matched, problems}
    rescue ex : Partiduo::Api::AccessDenied
      {0, [Records.error(FieldError::BASE, "access.forbidden", {"permission" => ex.as?(Partiduo::Api::Forbidden).try(&.permission).to_s})]}
    end
  end
end
