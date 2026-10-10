# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension d'import d'opérations en masse (ADR-005
# D4) : import d'un fichier (aperçu à blanc puis import), opérations à
# traiter (vérification d'une opération en HTMX, actions groupées),
# historique des imports et reprise du lettrage d'un FEC, formats CSV,
# correspondances (codes inconnus complétés sur place, en HTMX). Montée par
# `partiduo-ui-bulma` sous `/ext/IMPORT/` (ADR-003 D3). La distribution la
# requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-import"
# require "partiduo-import/ui/bulma"
# ```
#
# puis ajoute `Import::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Import::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle
# d'accès est fait par l'interface, avant le handler, à partir du montage,
# puis par le contrat.
require "base64"

require "../../src/partiduo-import"

require "./presenters"
require "./handlers/base"
require "./handlers/**"
require "./dashboard_tile"

module Import
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/import/`), fichiers statiques (`assets/import/`) et
    # libellés d'écran (`locales/`, clés `import_ui.*`).
    class App < Marten::App
      label "import_ui"
    end

    INSTALLED_APPS = [Import::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/IMPORT/`, nommées `import:<nom>` : celles
    # que citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Import::Ui::IndexHandler, name: "index"
      path "/import", Import::Ui::ImportHandler, name: "import"
      path "/operations", Import::Ui::OperationsHandler, name: "operations"
      path "/operations/action", Import::Ui::OperationsActionHandler, name: "operations_action"
      path "/operations/<id:int>/check", Import::Ui::OperationCheckHandler, name: "operation_check"
      path "/batches", Import::Ui::BatchesHandler, name: "batches"
      path "/batches/<id:int>", Import::Ui::BatchDetailHandler, name: "batch_detail"
      path "/batches/<id:int>/file", Import::Ui::BatchFileHandler, name: "batch_file"
      path "/batches/<id:int>/lettering", Import::Ui::BatchLetteringHandler, name: "batch_lettering"
      path "/batches/<id:int>/delete", Import::Ui::BatchDeleteHandler, name: "batch_delete"
      path "/purge", Import::Ui::PurgeHandler, name: "purge"
      path "/formats", Import::Ui::FormatsHandler, name: "formats"
      path "/formats/new", Import::Ui::FormatNewHandler, name: "format_new"
      path "/formats/<id:int>", Import::Ui::FormatEditHandler, name: "format_edit"
      path "/formats/<id:int>/delete", Import::Ui::FormatDeleteHandler, name: "format_delete"
      path "/mappings", Import::Ui::MappingsHandler, name: "mappings"
      path "/mappings/new", Import::Ui::MappingNewHandler, name: "mapping_new"
      path "/mappings/quick", Import::Ui::MappingQuickHandler, name: "mapping_quick"
      path "/mappings/account", Import::Ui::AccountCreateHandler, name: "account_create"
      path "/mappings/<id:int>", Import::Ui::MappingEditHandler, name: "mapping_edit"
      path "/mappings/<id:int>/delete", Import::Ui::MappingDeleteHandler, name: "mapping_delete"
    end

    # Routes qui importent ou traitent les opérations : `import.run` ;
    # paramétrage, suppression et purge : `import.admin` ; les autres :
    # `import.read`. Le contrat vérifie encore les permissions du cœur
    # (pièce jointe, écriture, lettrage, plan comptable).
    RUN_ROUTES   = %w[import operations_action operation_check batch_lettering]
    ADMIN_ROUTES = %w[batch_delete purge formats format_new format_edit format_delete mappings mapping_new mapping_quick
      account_create mapping_edit mapping_delete]
  end
end

PartiduoUi::Extensions.mount Import::CODE, Import::Ui::ROUTES, permission: Import::Api::READ,
  permissions: Import::Ui::RUN_ROUTES.to_h { |route| {route, Import::Api::RUN} }
    .merge(Import::Ui::ADMIN_ROUTES.to_h { |route| {route, Import::Api::ADMIN} })

# Compteur du menu « Opérations à traiter » et ligne de « À traiter » du
# tableau de bord du dossier.
PartiduoUi::Extensions.counter("IMPORT_OPERATIONS", route: "import:operations", todo: "import_ui.todo", tone: "warn") do |actor|
  Import::Api.pending_count(actor)
end
