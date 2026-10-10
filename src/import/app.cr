# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "json"
require "digest/sha256"

require "./manifest"
require "./models/**"
require "./parsers/parsed"
require "./parsers/**"
require "./services/**"
require "./api/**"

# Extension d'import d'opérations en masse de Partiduo (ADR-003) : écritures
# des journaux d'achats, de ventes, financiers et d'opérations diverses lues
# dans un CSV au format enregistré, ou dans un fichier des écritures
# comptables (FEC) ; correspondance des journaux, des codes de TVA, des
# comptes et des fiches de l'émetteur ; aperçu à blanc
# (`Partiduo::Api::Transaction.dry_run`), zone d'attente, doublons
# signalés ; passage par le service d'écriture de la Comptabilité avec sa
# numérotation, fichier conservé en pièce jointe. Même plan qu'une
# application du cœur (DECISIONS C1 du cœur) : `manifest.cr`, `models/`,
# `migrations/`, `parsers/` et `services/` (internes), `api/` (contrat
# public `Import::Api`), `locales/`.
module Import
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `import` dans `PARTIDUO_MODULES`.
  CODE = "IMPORT"

  # Application Marten du métier : modèles (tables `import_*`), migrations
  # et libellés.
  class App < Marten::App
    label "import"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Import::App] of Marten::Apps::Config.class
end
