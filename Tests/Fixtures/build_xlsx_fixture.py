#!/usr/bin/env python3
"""Génère `statement_fixture.xlsx`, le classeur de référence du harnais.

Écrit à la main plutôt qu'avec openpyxl : la fixture doit contenir EXACTEMENT
les pièges qu'on veut couvrir, et une bibliothèque les normaliserait.

Pièges intégrés, un par un :
  • lignes d'en-tête décoratives avant le vrai tableau (bloc d'identité typique
    d'un export bancaire) ;
  • une cellule VIDE au milieu d'une ligne — absente du XML, donc décalant les
    colonnes si la référence `r` n'est pas lue ;
  • une chaîne partagée découpée en plusieurs `<t>` par un run de mise en forme ;
  • une date stockée en numéro de série Excel avec un style de date intégré ;
  • une chaîne « inline » écrite dans la cellule au lieu de la table partagée ;
  • une seconde feuille, pour vérifier le tri numérique sheet2 < sheet10.

Lancer : python3 build_xlsx_fixture.py
"""

import zipfile
from pathlib import Path

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
</Types>"""

WORKBOOK = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheets>
    <sheet name="Operations" sheetId="1" r:id="rId1"
           xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
    <sheet name="Notes" sheetId="2" r:id="rId2"
           xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
  </sheets>
</workbook>"""

# index : 0 Date · 1 Libelle · 2 Montant · 3 Devise
#         4 CARREFOUR MARKET (en DEUX runs) · 5 VIR SEPA SALAIRE
#         6 Remarques · 7 Rien a signaler
SHARED_STRINGS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="8" uniqueCount="8">
  <si><t>Date</t></si>
  <si><t>Libelle</t></si>
  <si><t>Montant</t></si>
  <si><t>Devise</t></si>
  <si><r><t>CARREFOUR </t></r><r><t>MARKET PARIS</t></r></si>
  <si><t>VIR SEPA SALAIRE ACME</t></si>
  <si><t>Remarques</t></si>
  <si><t>Rien a signaler</t></si>
</sst>"""

# Series Excel verifiees : 45840 = 2025-07-02, 45841 = 07-03, 45842 = 07-04
# (style 14 = format de date integre)
SHEET1 = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="inlineStr"><is><t>RELEVE DE COMPTE</t></is></c></row>
    <row r="2"><c r="A2" t="inlineStr"><is><t>FR76 1234 5678 9012</t></is></c></row>
    <row r="3"/>
    <row r="4">
      <c r="A4" t="s"><v>0</v></c>
      <c r="B4" t="s"><v>1</v></c>
      <c r="C4" t="s"><v>2</v></c>
      <c r="D4" t="s"><v>3</v></c>
    </row>
    <row r="5">
      <c r="A5" s="14"><v>45840</v></c>
      <c r="B5" t="s"><v>4</v></c>
      <c r="C5"><v>-42.5</v></c>
      <c r="D5" t="inlineStr"><is><t>EUR</t></is></c>
    </row>
    <row r="6">
      <c r="A6" s="14"><v>45841</v></c>
      <c r="B6" t="s"><v>5</v></c>
      <c r="C6"><v>2350</v></c>
    </row>
    <row r="7">
      <c r="A7" s="14"><v>45842</v></c>
      <c r="B7" t="inlineStr"><is><t>PRLV EDF</t></is></c>
      <c r="D7" t="inlineStr"><is><t>EUR</t></is></c>
    </row>
  </sheetData>
</worksheet>"""

SHEET2 = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="s"><v>6</v></c><c r="B1" t="s"><v>7</v></c></row>
  </sheetData>
</worksheet>"""

PARTS = {
    "[Content_Types].xml": CONTENT_TYPES,
    "xl/workbook.xml": WORKBOOK,
    "xl/sharedStrings.xml": SHARED_STRINGS,
    "xl/worksheets/sheet1.xml": SHEET1,
    "xl/worksheets/sheet2.xml": SHEET2,
}


def main() -> None:
    target = Path(__file__).with_name("statement_fixture.xlsx")
    # DEFLATE et non STORE : c'est le chemin `inflate` du lecteur ZIP qu'on
    # veut exercer, et c'est ce que produisent tous les tableurs réels.
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, body in PARTS.items():
            archive.writestr(name, body)
    print(f"écrit : {target} ({target.stat().st_size} octets)")


if __name__ == "__main__":
    main()
