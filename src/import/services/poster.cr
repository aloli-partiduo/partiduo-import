# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Passage d'une opération par le service d'écriture du cœur (ADR-003 D6,
  # D-IMP-007) : `post_entry`, `post_purchase`, `post_sale` ou
  # `post_financial` de la Comptabilité — ou leurs variantes ventilées de
  # l'analytique —, avec l'acteur réel, la numérotation des pièces du
  # journal et tous les contrôles du cœur. Aucune table comptable propre.
  # Interne.
  module Poster
    alias Acc = Partiduo::Api::Accounting
    alias Analytic = Partiduo::Api::Analytic
    alias Result = Partiduo::Api::Result

    # Préfixe de la référence `source` des écritures produites.
    SOURCE = "import:operation:"

    def self.post(actor : Partiduo::Api::Actor, planned : Resolver::Planned) : Result(Array(Acc::EntryView))
      distributions = planned.distributions
      case planned.kind
      when "financial"
        Acc.post_financial(actor, planned.financial.as(Acc::FinancialInput))
      when "purchase", "sale"
        input = planned.document.as(Acc::DocumentInput)
        single(if distributions.empty?
          planned.kind == "purchase" ? Acc.post_purchase(actor, input) : Acc.post_sale(actor, input)
        else
          planned.kind == "purchase" ? Analytic.post_purchase(actor, input, distributions) : Analytic.post_sale(actor, input, distributions)
        end)
      else
        input = planned.entry.as(Acc::EntryInput)
        single(distributions.empty? ? Acc.post_entry(actor, input) : Analytic.post_entry(actor, input, distributions))
      end
    rescue ex : Partiduo::Api::AccessDenied
      Result(Array(Acc::EntryView)).failure(Records.error(Partiduo::Api::FieldError::BASE, "access.forbidden",
        {"permission" => ex.as?(Partiduo::Api::Forbidden).try(&.permission).to_s}))
    end

    private def self.single(result : Result(Acc::EntryView)) : Result(Array(Acc::EntryView))
      result.success? ? Result(Array(Acc::EntryView)).success([result.value!]) : Result(Array(Acc::EntryView)).failure(result.errors)
    end
  end
end
