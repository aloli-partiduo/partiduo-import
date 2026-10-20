# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/IMPORT/` servie en `GET` (liste tirée du routeur de Marten),
# obtenue en fr, en et nl par un administrateur, sur plusieurs imports
# (opérations diverses transférées ou écartées ; FEC transféré en partie,
# à lettrer, au compte inconnu ; achats ; banque), trois formats et les
# correspondances du FEC. Contrôle de l'interface (`PartiduoUi::Translations`) :
# ni marqueur de traduction absente, ni clé brute, ni interpolation non
# résolue, et toute route atteinte par les liens des pages.

private alias S = Import::SpecSupport
private alias Api = Import::Api

describe "Traductions des écrans IMPORT (fr, en, nl)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    browser = PartiduoUi::Books.admin
    S.user("bruno@example.com", "Bruno")
    S.activate

    # Journaux, comptes et tiers du FEC ; le compte 6061 reste inconnu.
    S.card("CUSTOMER", "Client Un", "CLIENT1")
    S.fec_mappings
    batch = S.import("od.csv", S.misc_format.id)
    first, second = S.operations(batch.id)
    Api.transfer(S.accountant, [first.id, second.id])
    Api.discard(S.accountant, [second.id])
    # FEC transféré en partie : lettrage à reprendre, code inconnu.
    fec = S.import(S::FEC)
    Api.transfer(S.accountant, S.operations(fec.id).map(&.id))
    S.import("achats.csv", S.purchase_format.id)
    S.import("banque.csv", S.bank_format.id)

    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("import:"))
    begin
      explorer.crawl(browser, "IMPORT")
    ensure
      # L'exploration laisse active la dernière langue obtenue (nl) ; les
      # specs suivantes attendent la langue par défaut.
      I18n.activate(Marten.settings.i18n.default_locale)
    end
    puts "\nTraductions de IMPORT : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
