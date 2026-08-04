#!/bin/zsh
# Couverture de la couche logique — la métrique que vise la solidification.
#
# La cible applicative fait ~69 000 lignes dont plus de la moitié sont des corps
# de vues SwiftUI, qu'un test unitaire ne peut pas exercer. Le chiffre global
# n'est donc pas pilotable. Ce script sépare les deux couches en s'appuyant sur
# le rangement du projet : Views/, DesignSystem/ et App/ d'un côté, tout le
# reste de l'autre.
#
# Usage : ./coverage.sh [-s <id ou nom de simulateur>]
set -e
cd "$(dirname "$0")/.."

SIM="${1:-}"
if [[ -z "$SIM" ]]; then
  SIM=$(xcodebuild -project Nemoris.xcodeproj -scheme Nemoris -showdestinations 2>/dev/null \
        | grep "platform:iOS Simulator" | grep -i iphone | grep -v placeholder \
        | head -1 | sed -E 's/.*id:([^,]+),.*/\1/')
fi
[[ -z "$SIM" ]] && { echo "Aucun simulateur iPhone disponible."; exit 1; }

# DerivedData dédié : Xcode et la ligne de commande partagent sinon la même
# build.db, et deux compilations simultanées la verrouillent — l'échec se
# présente alors comme une erreur de compilation trompeuse dans un fichier en
# cours d'édition. build/ est ignoré par git.
DD="$PWD/build/cli-dd"

echo "Simulateur : $SIM"
xcodebuild test -project Nemoris.xcodeproj -scheme Nemoris \
  -destination "id=$SIM" -derivedDataPath "$DD" -enableCodeCoverage YES 2>&1 \
  | grep -E "^\*\* |error:" || true

BUNDLE=$(ls -td "$DD"/Logs/Test/*.xcresult | head -1)

xcrun xccov view --report --files-for-target Nemoris.app "$BUNDLE" 2>/dev/null \
| python3 -c '
import re, sys

# "  <chemin> <couverts>/<total>" ou pourcentage — on lit les deux entiers finaux
rows = []
for line in sys.stdin:
    m = re.search(r"(/\S+\.swift).*?\((\d+)/(\d+)\)", line)
    if m:
        rows.append((m.group(1), int(m.group(2)), int(m.group(3))))

def bucket(path):
    if "/NemorisTests/" in path: return None
    if "/Views/" in path or "/DesignSystem/" in path or "/Nemoris/App/" in path:
        return "presentation"
    return "logique"

tot = {"logique": [0, 0], "presentation": [0, 0]}
per_file = []
for path, cov, total in rows:
    b = bucket(path)
    if not b: continue
    tot[b][0] += cov; tot[b][1] += total
    if b == "logique":
        per_file.append((cov / total if total else 1.0, total, path))

def pct(c, t): return f"{100.0*c/t:5.1f} %" if t else "  n/a"

print()
print("=" * 62)
for name, label in (("logique", "COUCHE LOGIQUE  (cible : 90 %)"), ("presentation", "Présentation    (hors cible)")):
    c, t = tot[name]
    print(f"  {label:34} {pct(c,t)}   {c:6}/{t}")
print("=" * 62)

per_file.sort(key=lambda r: (r[0], -r[1]))
print("\n  Fichiers de logique les moins couverts (les plus gros d abord) :\n")
for ratio, total, path in [r for r in per_file if r[1] >= 40][:15]:
    short = path.split("/Nemoris/")[-1]
    print(f"    {100*ratio:5.1f} %  {total:5} l.  {short}")
'
