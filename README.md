# FinanceMobileIOS

Application iOS SwiftUI creee separement de JavaApp.

## Prerequis

- Xcode 26+
- iOS Deployment Target: 26.0

## Ouvrir le projet

1. Depuis ce dossier, generer le projet Xcode:
   - `xcodegen generate`
2. Ouvrir `FinanceMobileIOS.xcodeproj` dans Xcode.
3. Choisir un simulateur iPhone iOS 26 ou un iPhone reel iOS 26.
4. Lancer l'application.

## Notes

- Ce projet ne modifie pas JavaApp.
- La persistance SQLite est preparee en squelette (DatabaseManager), avec chemin de migration prevu depuis `finance.sqlite`.
