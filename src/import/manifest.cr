# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension d'import d'opérations en masse (ADR-003 D2),
# successeur de l'import avancé de l'application d'origine (table « Sort
# des extensions amont » d'ADR-003) et de sa correspondance des codes de
# TVA (D-OUT-001 du cœur).
#
# * Dépendance : `ACCOUNTING` — les opérations lues deviennent des
#   écritures passées par le service d'écriture du module (`post_entry`,
#   `post_purchase`, `post_sale`, `post_financial`), avec sa numérotation.
# * Aucune incompatibilité : un dossier foyer tient aussi la Comptabilité
#   et peut reprendre l'historique d'un autre logiciel (D-IMP-002).
# * Permissions (D4) : `import.read` (zone d'attente, historique, formats et
#   correspondances), `import.run` (lire un fichier, l'aperçu à blanc,
#   importer, vérifier, transférer, écarter, reprendre le lettrage),
#   `import.admin` (formats, correspondances, création des comptes
#   manquants, suppression d'un import, purge). Le contrat du cœur exige en
#   plus ses propres droits, avec l'acteur réel : `core.attachment.write`,
#   `accounting.entry.post` et l'écriture dans le journal,
#   `analytic.operation.write` pour une ventilation,
#   `accounting.matching.write` pour le lettrage,
#   `accounting.account.write` pour créer un compte (D-IMP-004).
# * Menu (D6 d'ADR-003) : rubrique « Import d'opérations » entre la Saisie
#   et la Consultation ; formats et correspondances sous « Paramètres ».
# * Abonnement : `entry.cancelled` — une opération transférée dont
#   l'écriture est extournée redevient à traiter (D-IMP-010).
Partiduo::Modules.register do
  code "IMPORT"
  name "import.module.name"
  version Import::VERSION
  requires_core "~> 0.1"
  depends_on "ACCOUNTING"

  permission "import.read"
  permission "import.run"
  permission "import.admin"

  menu "IMPORT", order: 37, permission: "import.read"
  menu "IMPORT_RUN", parent: "IMPORT", order: 10, route: "import:import", permission: "import.run"
  menu "IMPORT_OPERATIONS", parent: "IMPORT", order: 20, route: "import:operations", permission: "import.read"
  menu "IMPORT_HISTORY", parent: "IMPORT", order: 30, route: "import:batches", permission: "import.read"
  menu "IMPORT_FORMATS", parent: "SETTINGS", order: 93, route: "import:formats", permission: "import.admin"
  menu "IMPORT_MAPPINGS", parent: "SETTINGS", order: 94, route: "import:mappings", permission: "import.admin"

  ui "bulma", path: "ui/bulma"

  on("entry.cancelled") { |event| Import::Subscriptions.entry_cancelled(event) }
end
