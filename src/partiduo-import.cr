# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-import` : le métier de l'extension
# d'import d'opérations en masse (manifeste, modèles, lecture des fichiers,
# correspondances, abonnements, contrat `Import::Api`), sans interface.
# L'interface Bulma est dans `ui/bulma/`, requise à part par la
# distribution : `require "partiduo-import/ui/bulma"`.
#
# La distribution ajoute ensuite `Import::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-import/cli"` à sa ligne de
# commande (migrations).
require "partiduo"

require "./import/app"
