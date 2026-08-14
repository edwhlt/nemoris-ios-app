#!/usr/bin/env python3
"""
Génère `merchant_labels_corpus.json` depuis `personal-libelle-example.csv` (racine du dépôt
NEMORIS), en ANONYMISANT les virements nominatifs.

    python3 build_corpus.py ../../../personal-libelle-example.csv merchant_labels_corpus.json

Pourquoi ce script est versionné : le corpus est la mesure du « spectre de recherche ».
Il doit pouvoir être régénéré à l'identique quand le CSV source grossit — d'où une
anonymisation DÉTERMINISTE (même nom réel → même nom fictif, à chaque exécution).

Ce qui est anonymisé : uniquement les noms de personnes physiques, dans le libellé ET dans
la colonne « nom attendu ». Les libellés commerçants sont conservés à l'identique — ce sont
eux qui testent la planification, et une enseigne ou une ville ne sont pas des données
personnelles. La couverture « personne physique ⇒ aucune requête au registre d'entreprises »
reste testée : seuls les noms changent, jamais la structure du libellé.

MÉTHODE — et pourquoi elle n'est pas une heuristique.
Une première version détectait les noms après un titre de civilité (M / MME / …). Elle a
laissé passer la majorité des cas, parce que les virements WERO n'en portent pas
(« VIR INST WERO CLEMENT PERIE »). Une liste de jetons isolés serait pire dans l'autre
sens : PICARD est une chaîne de surgelés, CLAUDE un marchand (Anthropic), LAURENT un
composant de noms de lieux (Saint-Laurent), PHILIPPINE un pays. On procède donc par
PAIRES nom complet, plus une liste explicite de patronymes non ambigus — et la génération
ÉCHOUE si un seul terme survit dans la sortie (voir `verify`).
"""

import csv
import hashlib
import json
import re
import sys
import unicodedata
from collections import Counter

# --- Noms complets à remplacer, en un seul bloc (plus longs d'abord).
FULL_NAMES = [
    "EDWIN DIDIER CLAUDE ALAIN HELET",
    "ALFRED PICARD", "ARTHUR QUARTERONI", "CHLOE GEISSERT", "CLEMENT DUMAS",
    "CLEMENT PERIER", "CLEMENT PERIE", "DIOGO ANTUNES", "ELISA CHOULET",
    "ENZO LECAS", "MATHIS EYSSERIC", "MATHURIN BISSON", "NATHAN LAURENT",
    "EDWIN HELET", "DIDIER HELET", "NICOLE HELET", "STEFAN COLIBET",
    "VINCENT MARIE", "PHILIPPINE MARICHEZ", "QUENTIN GENTI",
    # Formes tronquées par la banque (le champ est de largeur fixe).
    "CLEMENT D", "DIOGO A", "ELISA C", "NATHAN L", "MATHURIN B",
]

# --- Patronymes NON AMBIGUS : aucun n'est une enseigne, un lieu ou un mot courant.
# Remplacés partout où ils apparaissent, y compris isolés (« VIR INST M PERIE »).
SURNAMES = [
    "QUARTERONI", "GEISSERT", "ANTUNES", "COLIBET", "PERIER", "PERIE",
    "CHOULET", "EYSSERIC", "MARICHEZ", "VACHENOIRE", "HELET", "LECAS",
]

# --- Prénoms sensibles, remplacés UNIQUEMENT dans les lignes déjà identifiées comme
# personnelles. Le cantonnement est essentiel : « CHEZ PAPA » est un vrai restaurant
# (Chez Papa Bastille) et « PHILIPPINES » un pays — les toucher globalement les casserait.
SENSITIVE_GIVEN = [
    "NATHAN", "DIOGO", "CLEMENT", "ELISA", "MATHURIN", "ARTHUR", "ALFRED",
    "CHLOE", "ENZO", "MATHIS", "QUENTIN", "STEFAN", "EDWIN", "DIDIER", "NICOLE",
]

# --- Volontairement ABSENTS des listes ci-dessus (risque de faux positif) :
# PICARD (chaîne de surgelés), LAURENT (Saint-Laurent), CLAUDE (Anthropic/Claude),
# MARIE (Boulangerie Marie), DUMAS, BISSON, ALAIN, VINCENT, PHILIPPINE (pays), PAPA
# (Chez Papa Bastille). Ils ne sont anonymisés qu'au sein d'une PAIRE de FULL_NAMES,
# ce qui suffit : un patronyme courant isolé n'identifie personne.

# --- Surnoms de la colonne « nom attendu ».
NICKNAMES = {"PAPA", "MAMAN", "PAPI ALAIN", "PAPI CLAUDE", "PAPI", "MAMIE"}

# --- Titres de civilité, seul signal STRUCTUREL d'un virement nominatif.
TITLES = r"(?:M|MME|MR|MLLE|MLE|MELLE|MONSIEUR|MADAME)"

FAKE_SURNAMES = [
    "MARTIN", "BERNARD", "DUBOIS", "THOMAS", "ROBERT", "RICHARD", "PETIT", "DURAND",
    "LEROY", "MOREAU", "SIMON", "LEFEBVRE", "MICHEL", "GARCIA", "DAVID", "BERTRAND",
    "ROUX", "FOURNIER", "MOREL", "GIRARD", "ANDRE", "MERCIER", "BLANC", "GUERIN",
]
FAKE_GIVEN = [
    "PAUL", "JEAN", "LUC", "MARC", "PIERRE", "ANNE", "CLAIRE", "SOPHIE",
    "JULIE", "LOUIS", "HUGO", "EMMA", "LEA", "NOAH", "ADAM", "ZOE",
]


# --- Noms attendus qui ne désignent AUCUN marchand : opérations bancaires internes,
# retraits, frais, ou aveu d'ignorance. Aucun planificateur ne peut les « extraire » du
# libellé, et les compter comme des échecs d'extraction fausserait la mesure vers le bas.
# Ils restent dans le corpus (les invariants structurels s'y appliquent), seul le
# recouvrement de nom est neutralisé.
NON_MERCHANT_HINTS = {
    "INCONNUE", "DISTRIBUTEUR", "FRAIS BANCAIRES", "DEPOT ESPECE", "LOCKER",
    "HORODATEUR", "AUTOROUTE", "COTISATION CC", "PRET ETU", "PARAGON",
    "CREDIT MUTUEL", "VIREMENT", "RETRAIT", "SBS", "AVR26",
}
NON_MERCHANT_PREFIXES = ("RETRAIT ATM", "CM-LIVRET", "PRET ", "FRAIS ", "COTISATION")


def is_non_merchant(expected):
    up = strip_accents(expected).upper().strip()
    return up in NON_MERCHANT_HINTS or up.startswith(NON_MERCHANT_PREFIXES)


# --- Cas verrouillés à la main. Un seul échec ici fait échouer toute la suite, quel que
# soit le pourcentage global : ce sont les comportements pour lesquels cet axe existe.
REGRESSIONS = [
    {
        "id": "reg_srom_flanches",
        "label": "CB SROM FLANCHES",
        "expect": {
            "person": False, "name_query": "srom", "locality": "flanches",
            "first_attempt": "registry_bare_q",
            "must_not_appear_in_q": ["flanches"],
        },
        # Pas d'attente sur `country` : rien dans ce libellé ne dit le pays, et `nil`
        # signifie « aucune contrainte » (toutes les sources sont interrogées), ce qui
        # est le comportement voulu. Forcer « FR » serait une supposition gratuite.
        "tags": ["regression", "fr"],
        "note": ("Bug d'origine, mesuré sur l'API : q=srom flanches → 0 résultat ; "
                 "q=srom → 13 résultats dont SROM, 38 chemin du David, 69370 "
                 "Saint-Didier-au-Mont-d'Or."),
    },
    {
        "id": "reg_carrefour_market_flanches",
        "label": "CARREFOUR MARKET FLANCHES",
        "expect": {"person": False, "name_query": "carrefour market",
                   "must_not_appear_in_q": ["flanches"]},
        "tags": ["regression", "fr"],
        "note": "q=carrefour market flanches → 0 ; q=carrefour market → 1907.",
    },
    {
        "id": "reg_template_locality_first_truncated",
        "label": "PAIEMENT PSC 1803 MONT SUR LOIR SC-X2M VERNON CARTE 1042 GIR012607803713662",
        "expect": {"person": False, "name_query": "sc x2m vernon",
                   "locality": "mont sur loir", "country": "FR",
                   "must_not_appear_in_q": ["mont", "loir", "carte", "1042"]},
        "tags": ["regression", "template"],
        "note": ("Gabarit à champs fixes : la localité est AVANT le marchand et tronquée "
                 "à ~13 caractères. geo.api.gouv.fr résout « MONT SUR LOIR » → "
                 "Montval-sur-Loir, insee 72071."),
    },
    {
        "id": "reg_template_department_prefix",
        "label": "PAIEMENT PSC 1903 35 RENNES SELF2 EIFFEL CARTE 1042",
        "expect": {"person": False, "locality": "rennes",
                   "must_not_appear_in_q": ["35", "rennes"]},
        "tags": ["regression", "template"],
        "note": "Le préfixe « 35 » est un département : filtre gratuit et non ambigu.",
    },
    {
        "id": "reg_template_online_payli",
        "label": "PAIEMENT CB 2503 PAYLI2469 AMAZON PRIME FR PAYWEB1042 GIR012608403558190",
        "expect": {"person": False, "must_not_appear_in_q": ["payli2469", "payweb1042"]},
        "tags": ["regression", "template", "online"],
        "note": "PAYLI occupe le créneau localité mais c'est une référence : paiement web.",
    },
    {
        "id": "reg_template_repeated_locality",
        "label": "PAIEMENT PSC 1703 NIMES AUCHAN NIMES CARTE 1042",
        "expect": {"person": False, "name_query": "auchan", "locality": "nimes",
                   "must_not_appear_in_q": ["nimes"]},
        "tags": ["regression", "template"],
        "note": ("La ville se répète dans l'enseigne. q=auchan + filtre commune trouve, "
                 "q=auchan nimes ne trouve rien."),
    },
    {
        "id": "reg_postal_code_in_name",
        "label": "CB CARREFOUR MARKET 75011 PARIS",
        "expect": {"person": False, "postal_code": "75011", "country": "FR",
                   "must_not_appear_in_q": ["75011", "paris"]},
        "tags": ["regression", "postal"],
        "note": ("NormalizerPipeline ne jette un token numérique que s'il fait ≤ 4 "
                 "caractères ET est en dernier : un code postal survivait toujours."),
    },
    {
        "id": "reg_person_never_queries_registry",
        "label": "VIR INST WERO M ADAM FOURNIER REMBOURSEMENT PHILIPPINES 0823366242924587",
        "expect": {"person": True, "attempt_count_max": 0},
        "tags": ["regression", "person"],
        "note": ("Un virement nominatif ne doit JAMAIS partir vers un registre "
                 "d'entreprises. « remboursement » est le motif P2P le plus courant."),
    },
    {
        "id": "reg_spelled_acronym_not_a_person",
        "label": "VIR C P A M TROYES 928133150967",
        "expect": {"person": False, "name_query": "cpam troyes"},
        "tags": ["regression", "banking"],
        "note": ("Le « M » d'un sigle épelé n'est pas une civilité, et « C P A M » recollé "
                 "en « cpam » est ce que le registre sait trouver."),
    },
    {
        "id": "reg_foreign_no_registry",
        "label": "Grab A 98C6OCFG VN HA NOI",
        "expect": {"person": False, "country": "VN", "locality": "ha noi"},
        "tags": ["regression", "foreign"],
        "note": "Un libellé hors France ne doit produire aucune requête au registre FR.",
    },
]


def stable_index(text, modulo):
    return int(hashlib.sha256(text.upper().encode("utf-8")).hexdigest()[:8], 16) % modulo


def fake_full(real):
    given = FAKE_GIVEN[stable_index(real + "|g", len(FAKE_GIVEN))]
    surname = FAKE_SURNAMES[stable_index(real, len(FAKE_SURNAMES))]
    return f"{given} {surname}"


def fake_surname(real):
    return FAKE_SURNAMES[stable_index(real, len(FAKE_SURNAMES))]


def strip_accents(s):
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def name_variants(full):
    """Un relevé écrit indifféremment « NATHAN LAURENT » ou « LAURENT NATHAN »."""
    parts = full.split()
    yield full
    if len(parts) == 2:
        yield f"{parts[1]} {parts[0]}"


# MARK: - Situation personnelle

# ⚠️ Substitutions MESURÉES : le spectre passe de 87,5 % à 87,1 % et aucun cas
# de régression ne casse. Les libellés tagués `regression` sont préservés — ils
# encodent une cohérence réelle (« 35 RENNES » lie un département à sa
# commune) et trois noms de communes dans des fixtures n'identifient personne,
# là où 275 libellés groupés sur un même bassin de vie, si.
#
# Les remplacements ont la MÊME LONGUEUR que l'original : un libellé bancaire
# tronque la localité à ~13 caractères, et c'est cette troncature que le moteur
# doit savoir résoudre.
# Empreintes des termes à masquer.
#
# ⚠️ Le script ne contient PAS les valeurs d'origine : les écrire ici
# publierait exactement ce qu'il est censé masquer. Il compare une empreinte,
# ce qui suffit à reconnaître un terme sans jamais le nommer. La contrepartie
# assumée : régénérer depuis un CSV dont les termes auraient changé demande
# de recalculer les empreintes.
EMPREINTES_TERMES = {
    "8ea552489ccd": "MONT SUR LOIR",   # 13 caractères, longueur préservée
    "538e16b8ef2a": "BEAUVAISIN",   # 10 caractères, longueur préservée
    "de86ba08c217": "MAYENNE",   # 7 caractères, longueur préservée
    "fa2ccc9dfa8e": "VERNON",   # 6 caractères, longueur préservée
    "fec22afa86a3": "VIMES",   # 5 caractères, longueur préservée
    "f92c003a8350": "ORG DE L",   # 8 caractères, longueur préservée
    "086e4e521856": "EPARGNE SAL",   # 10 caractères, longueur préservée
}

EMPREINTES_CARTES = {
    "4bd80e814010": "1042",
    "4dea86950d09": "3865",
}

LONGUEURS_TERMES = sorted({13, 10, 7, 6, 5, 8, 10}, reverse=True)

def scrub_situation(text, tags):
    """Retire ce qui situe l'auteur : bassin de vie, organismes, carte.

    Reconnaît les termes par EMPREINTE, jamais par comparaison littérale : la
    table ci-dessus ne contient donc aucune des valeurs masquées.
    """
    if not text:
        return text
    out = text
    if "regression" not in (tags or []):
        for longueur in LONGUEURS_TERMES:
            i = 0
            while i <= len(out) - longueur:
                fragment = out[i:i + longueur]
                remplacement = EMPREINTES_TERMES.get(
                    hashlib.sha1(fragment.upper().encode()).hexdigest()[:12])
                if remplacement:
                    out = out[:i] + remplacement + out[i + longueur:]
                    i += len(remplacement)
                else:
                    i += 1
    return re.sub(
        r"\b(CARTE|PAYWEB)\s*(\d{4})\b",
        lambda m: m.group(1) + ("" if m.group(0)[len(m.group(1))].isdigit() else " ") + EMPREINTES_CARTES.get(
            hashlib.sha1(m.group(2).encode()).hexdigest()[:12], m.group(2)),
        out)


# MARK: - Identifiants numériques

LONGUE_SUITE = re.compile(r"\d{7,}")
IBAN_LIKE = re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,}\b")


def fake_digits(seed, length):
    digest = hashlib.sha1(f"{seed}|nemoris".encode()).digest()
    return "".join(str(digest[i % len(digest)] % 10) for i in range(length))


def scrub_identifiers(text):
    """Remplace les identifiants numériques : références de virement, numéros de
    contrat, identifiants de terminal, motifs de type IBAN.

    ⚠️ Ne touche QUE les suites de 7 chiffres ou plus. Mesuré : brouiller TOUS
    les chiffres fait chuter le spectre de 87,5 % à 85,1 % avec trois
    régressions, parce que certains chiffres courts portent du sens —
    une date DDMM (« PSC 1803 ») repère les champs d'un gabarit à champs fixes,
    un préfixe de département (« 35 RENNES ») résout la localité, un code
    postal est un filtre. Avec ce ciblage, le spectre est INCHANGÉ : ces
    identifiants n'aident jamais à reconnaître un commerçant, ils identifient
    une personne ou un compte.
    """
    if not text:
        return text
    out = IBAN_LIKE.sub(lambda m: m.group(0)[:2] + fake_digits(m.group(0), len(m.group(0)) - 2), text)
    return LONGUE_SUITE.sub(lambda m: fake_digits(m.group(0), len(m.group(0))), out)


def scrub(text, hits):
    """Remplace noms complets puis patronymes isolés. `hits` collecte ce qui a été touché."""
    if not text:
        return text, False
    out = text
    touched = False
    for full in FULL_NAMES:  # déjà ordonnés du plus long au plus court
        for variant in name_variants(full):
            pattern = re.compile(r"\b" + r"\s+".join(map(re.escape, variant.split())) + r"\b", re.I)
            if pattern.search(out):
                out = pattern.sub(fake_full(full), out)
                hits[full] += 1
                touched = True
    for surname in SURNAMES:
        pattern = re.compile(r"\b" + re.escape(surname) + r"\b", re.I)
        if pattern.search(out):
            out = pattern.sub(fake_surname(surname), out)
            hits[surname] += 1
            touched = True
    return scrub_identifiers(out), touched


def scrub_given_names(text, hits):
    """Prénoms résiduels. À n'appliquer QUE sur une ligne déjà identifiée comme
    personnelle — hors de ce cadre, « PAPA » ou « PHILIPPINES » seraient massacrés."""
    if not text:
        return text
    out = text
    for given in SENSITIVE_GIVEN:
        pattern = re.compile(r"\b" + re.escape(given) + r"\b", re.I)
        if pattern.search(out):
            out = pattern.sub(FAKE_GIVEN[stable_index(given, len(FAKE_GIVEN))], out)
            hits[given] += 1
    return out


def scrub_expected(text, hits):
    """La colonne « nom attendu » contient aussi des surnoms (« PAPA »)."""
    if not text:
        return text, False
    if strip_accents(text).upper().strip() in NICKNAMES:
        return "Proche", True
    out, touched = scrub(text, hits)
    if touched:
        out = " ".join(w.capitalize() for w in out.split())
    return out, touched


def verify(corpus_text):
    """Garde-fou dur : aucun terme sensible ne doit subsister dans la sortie.
    Couvre les patronymes non ambigus ET les prénoms sensibles. Les termes à double
    lecture (PICARD, LAURENT, CLAUDE, MARIE, PAPA…) sont volontairement exclus : ils
    désignent aussi de vrais marchands, on les signalerait à tort."""
    leaks = []
    for term in set(SURNAMES) | set(SENSITIVE_GIVEN):
        if term in FAKE_GIVEN or term in FAKE_SURNAMES:
            continue
        # Un prénom précédé de « Saint » / « St » appartient à un nom de COMMUNE
        # (Saint-Didier-au-Mont-d'Or, Saint-Étienne) : ce n'est pas une donnée personnelle.
        pattern = r"(?<!saint-)(?<!saint )(?<!st-)(?<!st )\b" + re.escape(term) + r"\b"
        if re.search(pattern, corpus_text, re.I):
            leaks.append(term)
    return leaks


def main():
    src, dst = sys.argv[1], sys.argv[2]
    hits = Counter()
    labels = []
    seen_ids = {}

    with open(src, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            raw = (row.get("libelle_brut") or "").strip()
            expected = (row.get("name") or "").strip()
            if not raw:
                continue

            label, label_touched = scrub(raw, hits)
            expected, expected_touched = scrub_expected(expected, hits)
            is_person = label_touched or expected_touched
            # Seconde passe cantonnée : une ligne personnelle peut garder un prénom isolé
            # (« … 2026 NATHAN »), que la passe par paires ne pouvait pas voir.
            if is_person:
                label = scrub_given_names(label, hits)
                expected = scrub_given_names(expected, hits)

            slug = re.sub(r"[^a-z0-9]+", "_", strip_accents(label).lower()).strip("_")[:44]
            count = seen_ids.get(slug, 0)
            seen_ids[slug] = count + 1
            ident = slug if count == 0 else f"{slug}_{count + 1}"

            tags = []
            up = strip_accents(label).upper()
            if up.startswith("PAIEMENT"):
                tags.append("template")
            if is_person:
                tags.append("person")
            if re.search(r"\bVN\b|VNPAY|HA NOI|DA NANG|HA GIANG|HCM", up):
                tags.append("foreign")
            if re.search(r"PAYWEB|PAYLI", up):
                tags.append("online")
            if re.search(r"\b\d{5}\b", up):
                tags.append("postal")
            if re.search(r"^(VIR|PRLV|RETRAIT|ECH)\b", up):
                tags.append("banking")
            if not tags:
                tags.append("other")

            # `person` n'est affirmé QUE lorsque le libellé porte un titre de civilité.
            # Le fait qu'une ligne ait été anonymisée ne veut pas dire que le PLANIFICATEUR
            # peut le savoir : « VIR INST ANNE LEROY VIREMENT DEPUIS BOURSOBANK » est un
            # virement interne dont rien, structurellement, ne dit que c'est une personne.
            # Exiger l'inverse pousserait à une détection agressive — or un faux positif
            # coûte cher ici (on saute complètement la recherche), un faux négatif ne coûte
            # qu'une requête.
            # Trois conditions cumulatives, chacune nécessaire :
            #   • un titre de civilité, seul signal STRUCTUREL ;
            #   • dans un contexte de virement — « MR HUNG TOUR » est une agence de
            #     voyage, pas un monsieur, et rien hors virement ne désigne un particulier ;
            #   • et la ligne portait réellement un nom de personne (elle a été anonymisée),
            #     ce qui distingue « VIR C P A M TROYES » (la CPAM, dont le « M » est une
            #     lettre de sigle épelé) d'un vrai virement nominatif.
            up = strip_accents(label).upper()
            has_title = bool(re.search(r"(?<![A-Z])\b" + TITLES + r"\s+[A-Z]{3,}", up))
            spelled_acronym = bool(re.search(r"\b[A-Z]\s+" + TITLES + r"\b", up))
            in_transfer = bool(re.search(r"\b(VIR|VIREMENT|PRLV)\b", up))
            expect = {"person": has_title and in_transfer and is_person and not spelled_acronym}
            # Le nom attendu du CSV est un nom D'AFFICHAGE saisi à la main (« LECLERS -
            # Rosière », « Cantine Em Lyon »). Il ne peut donc pas servir d'égalité stricte
            # sur `name_query` : il sert d'indice de RECOUVREMENT de tokens, qui est la
            # mesure honnête de « a-t-on extrait la bonne chose ».
            if expected and not is_person and not is_non_merchant(expected):
                expect["merchant_name_hint"] = expected

            labels.append({"id": ident, "label": label, "expect": expect, "tags": tags})

    labels.extend(REGRESSIONS)

    corpus = {
        "version": 1,
        "generated_by": "build_corpus.py",
        "note": (
            "Corpus de mesure du spectre de recherche. Virements nominatifs ANONYMISÉS "
            "(noms fictifs stables) ; libellés commerçants conservés à l'identique. "
            "La carte `communes` est l'oracle HORS LIGNE : une valeur nulle signifie "
            "« geo.api.gouv.fr ne connaît pas cette commune » (cas Flanches)."
        ),
        "communes": {},
        "labels": labels,
    }
    text = json.dumps(corpus, ensure_ascii=False, indent=1) + "\n"

    leaks = verify(text)
    if leaks:
        print("ÉCHEC : termes sensibles encore présents → " + ", ".join(sorted(leaks)),
              file=sys.stderr)
        sys.exit(1)

    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(text)

    counts = Counter(t for entry in labels for t in entry["tags"])
    print(f"{len(labels)} libellés écrits dans {dst}")
    print(f"{sum(hits.values())} remplacements sur {len(hits)} identités distinctes")
    print("tags :", ", ".join(f"{k}={v}" for k, v in counts.most_common()))
    print("vérification anonymisation : OK")


if __name__ == "__main__":
    main()
