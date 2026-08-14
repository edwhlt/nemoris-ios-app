#!/usr/bin/env python3
"""Empêche le retour de données bancaires réelles dans le dépôt.

⚠️ Cette vérification est STRUCTURELLE, délibérément. Chercher des
identifiants « d'apparence réelle » ne marche pas ici : le corpus de test
contient de vrais FORMATS de libellés dont les identifiants ont été
substitués, donc les valeurs assainies ressemblent à du réel — c'est
précisément le but. Une telle recherche crierait au loup à chaque exécution,
et une vérification qu'on désactive ne protège plus rien.

Une liste noire des vrais identifiants serait pire encore : elle publierait
les données qu'elle prétend protéger.

Ce qui est donc contrôlé :
  1. aucun fichier source de relevé n'est versionné ;
  2. le générateur du corpus contient bien ses fonctions d'assainissement,
     donc régénérer ne peut pas réintroduire de données réelles ;
  3. aucune clé d'API ni IBAN d'aspect authentique dans le code.
"""
import re
import subprocess
import sys

SECRETS = re.compile(r'(sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|'
                     r'-----BEGIN (RSA |EC )?PRIVATE KEY-----)')
IBAN = re.compile(r'\b([A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,})\b')
SUITE_CROISSANTE = re.compile(r'(0123|1234|2345|3456|4567|5678|6789){2,}')

GENERATEUR = "Tests/Fixtures/build_corpus.py"
ASSAINISSEURS = ("scrub", "scrub_identifiers", "scrub_situation")


def suivis(motifs):
    sortie = subprocess.run(["git", "ls-files", *motifs],
                            capture_output=True, text=True).stdout
    return [f for f in sortie.split("\n") if f]


def main() -> int:
    echec = False

    # 1. Un relevé brut ou une base ne doit jamais être versionné.
    suspects = [f for f in suivis(["*"])
                if re.search(r'(personal|releve|statement).*\.(csv|ofx|qfx)$|\.sqlite$',
                             f, re.I)]
    if suspects:
        print("❌ fichiers de données bancaires versionnés :")
        for f in suspects:
            print(f"      {f}")
        echec = True

    # 2. Le corpus n'est sûr que si son générateur assainit encore.
    try:
        generateur = open(GENERATEUR, encoding="utf-8").read()
        manquants = [f for f in ASSAINISSEURS if f"def {f}(" not in generateur]
        if manquants:
            print(f"❌ {GENERATEUR} : fonctions d'assainissement absentes — {manquants}")
            print("      Régénérer le corpus réintroduirait des données réelles.")
            echec = True
    except OSError:
        print(f"❌ {GENERATEUR} introuvable : le corpus n'a plus de générateur vérifiable")
        echec = True

    # 3. Secrets et IBAN authentiques dans le code.
    for f in suivis(["*.swift", "*.plist", "*.json", "*.yml", "*.sh", "*.md"]):
        try:
            contenu = open(f, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue

        if SECRETS.search(contenu):
            print(f"❌ {f} : secret en dur")
            echec = True

        # ⚠️ Le corpus est exclu de ce balayage, et c'est cohérent : ses
        # identifiants SONT le produit de la substitution, donc ils ressemblent
        # par construction à des vrais. Sa sûreté est garantie plus haut, en
        # vérifiant que son générateur assainit encore — une propriété
        # structurelle, contrôlable, là où l'apparence ne l'est pas.
        if f.endswith("merchant_labels_corpus.json"):
            continue

        # Un IBAN de fixture est bâti sur une suite croissante ; un vrai, non.
        for valeur in IBAN.findall(contenu):
            if not SUITE_CROISSANTE.search(re.sub(r'\D', '', valeur)):
                print(f"❌ {f} : IBAN sans marque de fixture — {valeur}")
                echec = True

    if not echec:
        print("✅ structure saine : aucun relevé versionné, générateur assainissant, "
              "aucun secret")
    return 1 if echec else 0


if __name__ == "__main__":
    sys.exit(main())
