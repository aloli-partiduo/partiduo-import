# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  module Ui
    # Tuile « Opérations importées » des tableaux de bord du dossier :
    # opérations à traiter, dont prêtes et refusées, et date de la plus
    # ancienne. Rien si aucune n'attend, si l'extension est inactive ou
    # l'acteur sans droit.
    module Tile
      def self.for(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) : PartiduoUi::Dashboard::Tile?
        view = Api.tile(actor) || return
        return if view.pending_count.zero?
        PartiduoUi::Dashboard::Tile.new(Import::CODE, I18n.t("import_ui.tile.label"), view.pending_count.to_s,
          sub: I18n.t("import_ui.tile.sub", ready: view.ready_count, refused: view.refused_count),
          alert: view.oldest_date.try { |date| I18n.t("import_ui.tile.oldest", date: fmt.date(date)) },
          url: Ui.url("operations"))
      end
    end
  end
end

# Point d'accroche de l'interface commune (`PartiduoUi::Extensions.tile`) :
# appelé seulement quand l'extension est active.
PartiduoUi::Extensions.tile Import::CODE do |actor, fmt|
  Import::Ui::Tile.for(actor, fmt).try { |tile| [tile] } || [] of PartiduoUi::Dashboard::Tile
end
