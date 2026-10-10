# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Import::SpecSupport
private alias P = Import::Parsers

private def settings(kind : String, columns : Array(String), **options) : P::CsvSettings
  P::CsvSettings.new(**options.merge(ledger_kind: kind, columns: columns))
end

describe "Lecture des fichiers d'opérations (D-IMP-005, D-IMP-011)" do
  it "lit les montants en BigDecimal, séparateurs et signes compris" do
    P::Amounts.parse("1 234,56", ',', ' ').should eq(S.d("1234.56"))
    P::Amounts.parse("1.234,56", ',', '.').should eq(S.d("1234.56"))
    P::Amounts.parse("(12,50)", ',', nil).should eq(S.d("-12.50"))
    P::Amounts.parse("12,50-", ',', nil).should eq(S.d("-12.50"))
    P::Amounts.parse("1200,00", nil, nil).should eq(S.d("1200"))
    P::Amounts.parse("abc", ',', nil).should be_nil
  end

  it "lit les huit formats de date d'origine et l'AAAAMMJJ du FEC" do
    P::Dates.parse("15.09.2026", "dd.mm.yyyy").should eq(S.date("2026-09-15"))
    P::Dates.parse("15-09-26", "dd-mm-yy").should eq(S.date("2026-09-15"))
    P::Dates.parse("2026-09-15", "yyyy-mm-dd").should eq(S.date("2026-09-15"))
    P::Dates.parse("20260915", "yyyymmdd").should eq(S.date("2026-09-15"))
    P::Dates.parse("31/02/2026", "dd/mm/yyyy").should be_nil
    P::Dates.compact("20260930").should eq(S.date("2026-09-30"))
  end

  it "reconnaît les sens D et C en français, anglais et néerlandais" do
    {"D" => "debit", "c" => "credit", "Débit" => "debit", "debet" => "debit", "-1" => "credit"}.each do |text, side|
      P.side(text).should eq(side)
    end
    P.side("X").should be_nil
  end

  it "décode UTF-8, Windows-1252 et ISO 8859-15, ou reconnaît l'encodage" do
    P::Text.decode("é€".encode("WINDOWS-1252"), "windows-1252")[0].should eq("é€")
    P::Text.decode(Bytes[0xA4, 0xE9], "iso-8859-15")[0].should eq("€é")
    P::Text.guess(Bytes[0x80, 0xE9])[1].should eq("windows-1252")
    P::Text.guess(Bytes[0xA4, 0xE9])[1].should eq("iso-8859-15")
    P::Text.guess("\u{FEFF}é".to_slice).should eq({"é", "utf-8"})
  end

  it "regroupe les lignes d'un CSV par code de regroupement, et lit sens et montants" do
    parsed = P::CsvReader.parse(S.fixture("od.csv"), settings("misc", %w[date ledger group receipt account line_label amount side]))
    parsed.issues.should be_empty
    parsed.operations.map(&.group_key).should eq(%w[G1 G2])
    first = parsed.operations.first
    {first.ledger_code, first.date, first.receipt, first.label}.should eq({"OD", S.date("2026-09-15"), "OD-1", "Frais bancaires"})
    first.lines.map { |line| {line.row, line.code, line.side, line.amount} }.should eq([
      {2, "627", "debit", S.d("12.50")}, {3, "510001", "credit", S.d("12.50")},
    ])
    first.total("misc").should eq(S.d("12.50"))
  end

  it "regroupe par pièce à défaut de code de regroupement, et calcule la TVA du toutes taxes" do
    columns = %w[date receipt third_party account line_label quantity amount vat_code amount_incl due_date]
    parsed = P::CsvReader.parse(S.fixture("achats.csv"), settings("purchase", columns))
    parsed.issues.should be_empty
    parsed.operations.map(&.receipt).should eq(%w[FA-101 FA-102])
    invoice = parsed.operations.first
    invoice.third_party.should eq("FOURN1")
    invoice.due_date.should eq(S.date("2026-10-10"))
    invoice.lines.map { |line| {line.amount, line.vat_code, line.vat_amount} }.should eq([
      {S.d("100"), "T20", S.d("20")}, {S.d("50"), "T20", S.d("10")},
    ])
    invoice.total("purchase").should eq(S.d("180"))
  end

  it "bloque l'opération d'une ligne illisible, sans la retrancher en silence" do
    content = "Date;Groupe;Compte;Montant;Sens\n15/09/2026;G1;627;abc;D\n15/09/2026;G1;510001;12,50;X\n16/09/2026;G1;627;1;D\nxx;G9;627;1;D\n"
    parsed = P::CsvReader.parse(content.to_slice, settings("misc", %w[date group account amount side]))
    operation = parsed.operations.first
    operation.lines.size.should eq(3)
    operation.problems.map(&.key).should eq(["import.errors.line.amount", "import.errors.line.side", "import.errors.line.date_mismatch"])
    parsed.operations.size.should eq(1)
    parsed.issues.map(&.row).should contain(5)
  end

  it "signale un CSV vide ou malformé" do
    P::CsvReader.parse("Date\n".to_slice, settings("misc", %w[date])).issues.map(&.key).should eq(["import.errors.file.empty"])
    P::CsvReader.parse("a;\"b\n".to_slice, settings("misc", %w[date])).fatal?.should be_true
  end

  it "lit un FEC : zones par leur nom, ISO 8859-15, lignes groupées par journal et numéro d'écriture" do
    parsed = P::FecReader.parse(S.fixture(S::FEC))
    parsed.issues.should be_empty
    parsed.encoding.should eq("iso-8859-15")
    parsed.operations.map { |operation| {operation.ledger_code, operation.group_key, operation.lines.size} }.should eq([
      {"VT", "VT1", 3}, {"BQ", "BQ1", 2}, {"OD", "OD1", 2},
    ])
    sale = parsed.operations.first
    sale.receipt.should eq("F2026-1")
    line = sale.lines.first
    {line.code, line.aux, line.aux_label, line.side, line.amount, line.letter}.should eq({"411000", "CLI01", "Client Un", "debit", S.d("1200"), "A"})
    sale.lines[2].code_label.should eq("TVA collectée")
  end

  it "accepte Montant et Sens, la barre verticale, et signale un en-tête incomplet" do
    content = "JournalCode|EcritureNum|EcritureDate|CompteNum|EcritureLib|Montant|Sens\nOD|1|20260901|627|X|10,00|D\nOD|1|20260901|510001|X|10,00|C\n"
    parsed = P::FecReader.parse(content.to_slice)
    parsed.operations.first.lines.map(&.side).should eq(%w[debit credit])
    P::FecReader.parse("JournalCode\tEcritureNum\n".to_slice).issues.map(&.key).should eq(["import.errors.fec.columns"])
    short = "JournalCode\tEcritureNum\tEcritureDate\tCompteNum\tDebit\tCredit\nOD\t1\t20260901\t627\t10\n"
    P::FecReader.parse(short.to_slice).issues.map(&.key).should eq(["import.errors.fec.field_count"])
  end

  it "contrôle la correspondance des colonnes selon le genre de journal" do
    errors = ->(kind : String, columns : Array(String)) { P::Fields.errors(kind, columns).map(&.key.split('.').last) }
    errors.call("misc", %w[date account amount side]).should be_empty
    errors.call("misc", %w[date account debit credit]).should be_empty
    errors.call("misc", %w[date account amount]).should eq(["missing"])
    errors.call("misc", %w[date account amount side debit credit]).should eq(["amount_both"])
    errors.call("financial", %w[date account amount vat_code]).should eq(["not_allowed"])
    errors.call("purchase", %w[date date account amount]).should eq(["repeated", "missing"])
  end
end
