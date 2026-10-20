# SPDX-License-Identifier: AGPL-3.0-or-later

module Import
  # Taux et rôle de TVA des lignes d'une écriture de FEC passée dans un
  # journal d'achats ou de ventes (D-IMP-017), pour que la facture soit
  # reconnue par les déclarations (`EntryLineInput#vat_rate` et `#vat_role`,
  # contrat 0.14.0). Un FEC n'a ni code de TVA ni rôle : on les retrouve par
  # la table des comptes de TVA du dossier et par les montants, sans rien
  # deviner :
  #
  # . *lignes de taxe* : celles dont le compte est le compte de TVA
  #   déductible ou collectée d'un taux actif à taux non nul (un compte
  #   partagé par plusieurs taux en propose plusieurs) ;
  # . *bases possibles* : les lignes de compte (pas de fiche) des classes 2,
  #   6 et 7 — immobilisations, charges, produits ;
  # . on cherche l'affectation de chaque ligne de taxe à l'un de ses taux,
  #   et de chaque base à l'un de ces taux ou à aucun (base exonérée), telle
  #   que, pour chaque taux retenu, base × taux = taxe à un centime par
  #   ligne de base près ; la meilleure laisse le moins de bases sans taux.
  #
  # Une seule meilleure affectation : elle est appliquée. Aucune, plusieurs
  # (montants qui ne permettent pas de trancher), ou trop de combinaisons :
  # l'écriture passe sans TVA, comme avant le contrat 0.14.0 — le format CSV
  # d'achats ou de ventes reste la voie qui porte les codes de TVA. Interne.
  module FecVat
    alias Acc = Partiduo::Api::Accounting
    alias Vat = Partiduo::Api::Vat

    # Module de la TVA du socle.
    VAT_MODULE = "VAT"

    # Combinaisons essayées au plus pour une écriture.
    MAX_COMBINATIONS = 4096
    # Classes de comptes d'une base : immobilisations, charges, produits.
    BASE_CLASSES = {'2', '6', '7'}

    # Ligne d'une écriture : rang, compte du dossier (`nil` : fiche),
    # montant signé (débit positif).
    record Line, index : Int32, account : String?, signed : BigDecimal

    # Taux d'un compte de TVA : code et taux en fraction.
    record Rate, code : String, fraction : BigDecimal

    # Comptes de TVA des taux actifs à taux non nul, lus avec les droits de
    # l'acteur : compte → taux. Vide si la TVA est inactive ou illisible.
    def self.table(actor : Partiduo::Api::Actor) : Hash(String, Array(Rate))
      table = {} of String => Array(Rate)
      return table unless Partiduo::Modules.active?(VAT_MODULE)
      rates = Vat.rates(actor).reject(&.rate.zero?).to_h { |rate| {rate.code, Rate.new(rate.code, rate.fraction)} }
      Acc.vat_rate_accounts(actor).each do |row|
        rate = rates[row.vat_rate_code]? || next
        [row.deductible_account, row.collected_account].compact.map(&.number).uniq!.each do |number|
          (table[number] ||= [] of Rate) << rate
        end
      end
      table
    rescue Partiduo::Api::AccessDenied
      {} of String => Array(Rate)
    end

    # Taux et rôle par rang de ligne ; vide si rien ne se détermine.
    def self.assign(lines : Array(Line), table : Hash(String, Array(Rate))) : Hash(Int32, {String, String})
      none = {} of Int32 => {String, String}
      taxes = lines.select { |line| line.account.try { |number| table.has_key?(number) } }
      return none if taxes.empty?
      bases = lines.select do |line|
        number = line.account
        !number.nil? && !table.has_key?(number) && BASE_CLASSES.includes?(number[0]?)
      end
      choices = taxes.map { |line| table[line.account.as(String)] }
      search(taxes, choices, bases) || none
    end

    # Meilleure affectation, si elle est seule de son rang ; `nil` sinon, ou
    # au-delà de `MAX_COMBINATIONS`.
    private def self.search(taxes : Array(Line), choices : Array(Array(Rate)),
                            bases : Array(Line)) : Hash(Int32, {String, String})?
      count = choices.product(1_i64, &.size.to_i64)
      return if count > MAX_COMBINATIONS
      best = nil.as({Int32, Hash(Int32, {String, String})}?)
      ties = 0
      each_choice(choices) do |picked|
        rates = picked.uniq
        return if (rates.size + 1).to_i64 ** bases.size * count > MAX_COMBINATIONS
        each_base(bases.size, rates.size) do |slots|
          next unless valid?(taxes, picked, bases, slots, rates)
          missing = slots.count(&.==(rates.size))
          found = result(taxes, picked, bases, slots, rates)
          current = best
          if current.nil? || missing < current[0]
            best = {missing, found}
            ties = 0
          elsif missing == current[0] && found != current[1]
            ties += 1
          end
        end
      end
      found = best
      found[1] if found && ties.zero?
    end

    # Pour chaque taux retenu : au moins une base, et base × taux = taxe à
    # un centime par ligne de base près (taxe : le plus grand des deux côtés,
    # pour un taux autoliquidé qui a une ligne de chaque côté).
    private def self.valid?(taxes : Array(Line), picked : Array(Rate), bases : Array(Line), slots : Array(Int32),
                            rates : Array(Rate)) : Bool
      zero = BigDecimal.new(0)
      rates.each_with_index.all? do |rate, position|
        mine = bases.each_with_index.select { |(_, index)| slots[index] == position }.map(&.[0]).to_a
        next false if mine.empty?
        own = taxes.each_with_index.select { |(_, index)| picked[index] == rate }.map(&.[0].signed).to_a
        tax = Math.max(own.select(&.> zero).sum(zero), -own.select(&.< zero).sum(zero))
        base = mine.sum(zero, &.signed).abs
        ((base * rate.fraction) - tax).abs <= BigDecimal.new("0.01") * mine.size
      end
    end

    private def self.result(taxes : Array(Line), picked : Array(Rate), bases : Array(Line), slots : Array(Int32),
                            rates : Array(Rate)) : Hash(Int32, {String, String})
      found = {} of Int32 => {String, String}
      taxes.each_with_index { |line, index| found[line.index] = {picked[index].code, "tax"} }
      bases.each_with_index do |line, index|
        rate = rates[slots[index]]? || next
        found[line.index] = {rate.code, "base"}
      end
      found
    end

    # Chaque choix d'un taux par ligne de taxe.
    private def self.each_choice(choices : Array(Array(Rate)), & : Array(Rate) ->) : Nil
      counters = Array.new(choices.size, 0)
      loop do
        yield choices.map_with_index { |list, index| list[counters[index]] }
        position = 0
        while position < choices.size
          counters[position] += 1
          break if counters[position] < choices[position].size
          counters[position] = 0
          position += 1
        end
        break if position == choices.size
      end
    end

    # Chaque affectation des bases : rang du taux, ou `rates` (aucun taux).
    private def self.each_base(count : Int32, rates : Int32, & : Array(Int32) ->) : Nil
      slots = Array.new(count, 0)
      loop do
        yield slots
        position = 0
        while position < count
          slots[position] += 1
          break if slots[position] <= rates
          slots[position] = 0
          position += 1
        end
        break if position == count
      end
    end
  end
end
