# FinanceMobileIOS - Proposition de lancement public

## 1) Nom de l'application

### Nom recommandé
**Nemoris**

Pourquoi:
- Évoque un espace personnel et structuré pour son argent.
- Internationalisable (FR/EN) et mémorisable.
- Compatible avec le positionnement "personal banking ledger".

### Alternatives solides
- **PocketLedger**
- **BankLedger**
- **MyLedger Finance**
- **FlowLedger**
- **DailyLedger**

## 2) Fonctionnalités de l'application (inventaire)

### A. Pilotage financier
- Dashboard annuel avec sélection de l'année.
- Résumé des revenus/dépenses et période active.
- Graphiques mensuels, catégories et tags.
- Filtrage par mois depuis le graphique.
- Regroupement des catégories par catégorie parente.

### B. Gestion des transactions
- Liste des transactions avec pagination.
- Filtres: texte, catégorie, tags, période, regroupement jour/semaine/mois.
- Édition d'une transaction (catégorie, tiers, moyen de paiement, etc.).
- Ajout manuel d'une transaction.
- Gestion des tags (assignation rapide et en masse).
- Gestion des remboursements (unitaire et en masse).
- Suppression multiple.
- Vue d'analyse filtrée et synthèse par tag.
- Solde période + solde réel du compte.

### C. Import CSV (classique)
- Chargement de CSV bancaire.
- Détection d'encodage (UTF-8, Windows-1252, ISO-Latin-1).
- Mapping des colonnes (libellé, montant, date, compte).
- Analyse avec parsing robuste des dates/montants.
- Prévisualisation avant import.
- Matching automatique via regex (tiers + moyen de paiement).
- Correction manuelle avant import.
- Import transactionnel avec reporting d'erreurs.

### D. Smart Import (assisté)
- Pipeline intelligent de normalisation des libellés.
- Clustering des libellés proches.
- Suggestions "créer / rattacher / ignorer".
- Validation individuelle ou validation en masse.
- Édition des décisions (nom, regex, catégorie, rattachement existant).
- Confirmation explicite avant écriture en base.

### E. Données de référence
- CRUD sur comptes, catégories, tiers, moyens de paiement.
- Catégories hiérarchiques (parent/enfant).
- Recherche et tri.
- Import CSV dédié aux tiers.
- Suppression multiple de tiers.

### F. Tricount
- Import d'un Tricount par lien/code.
- Synchronisation et rafraîchissement des groupes.
- Détail des dépenses, parts, soldes, remboursements.
- Liaison entre entrées Tricount et transactions.
- Tags et remboursements sur entrées Tricount.

### G. Données & outils
- Connexion à une base SQLite externe.
- Test de connexion + export de la base.
- Console SQL avec dossier de scripts configurable.
- Synchronisation de taux de change pour Tricount.

## 3) Cible utilisateur

### Cible principale (ICP)
- Personnes de 25-45 ans, déjà rigoureuses avec leurs dépenses.
- Utilisateurs de CSV bancaire / outils "maison" / Google Sheets.
- Besoin clé: contrôle fin, catégorisation précise, suivi des remboursements et voyages/groupe.

### Cible secondaire
- Freelances et indépendants (pilotage perso + pro léger).
- Couples/colocations qui utilisent Tricount.
- "Power users" finance perso qui veulent un outil local, souple, orienté données.

## 4) Prix recommandé (lancement)

### Stratégie
Modèle **freemium + abonnement Pro** pour accélérer l'adoption, puis monétiser les usages avancés.

### Proposition tarifaire
- **Gratuit**: fonctionnalités de base (consultation, dashboard, édition simple, 1 import limité).
- **Pro Mensuel**: **4,99 EUR / mois**.
- **Pro Annuel**: **39,99 EUR / an** (≈ 3,33 EUR / mois).
- **Option Lifetime (lancement 2-4 semaines)**: **79,99 EUR** (offre de démarrage).

### Ce qui passe en Pro
- Smart Import complet.
- Import CSV illimité.
- Tricount avancé + synchronisation complète.
- Outils avancés (console SQL, exports avancés, automatisations futures).

## 5) Positionnement (phrase courte)

**"Nemoris est l'app iOS de personal banking ledger pour les utilisateurs exigeants: import intelligent, suivi précis des transactions et gestion Tricount dans un outil local, rapide et maîtrisable."**

## 6) Plan de publication rapide

- Valider le nom final + disponibilité App Store.
- Définir la grille Free vs Pro exactement.
- Préparer 5 captures orientées bénéfices (import, dashboard, tags, Tricount, SQL/tools).
- Rédiger description App Store FR + EN.
- Lancer une beta TestFlight avec 20-50 utilisateurs ciblés.
