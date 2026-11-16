# ImpotPointGouv

Addon WoW Forever pour faire de l'or en routine : suivi des gains, boîte aux lettres, conseiller de craft, scan et vente à l'HV.
Inspiré de TSM et Auctionator, avec une interface épurée.

## Installation

1. Télécharger le dépôt (bouton **Code → Download ZIP**) ou le cloner.
2. Copier le dossier dans `World of Warcraft/_forever_/Interface/AddOns/` en le nommant **`ImpotPointGouv`** (sans suffixe `-main`).
3. Relancer complètement le jeu (un `/reload` ne charge pas les nouveaux fichiers).

`/ipg` ouvre la fenêtre principale. Au premier lancement, un guide de configuration s'affiche.

## Commandes

| Commande | Effet |
|---|---|
| `/ipg` | Fenêtre principale (bilan, historique, persos, marché, réglages) |
| `/ipg list` | Routine (liste de courses, envois) |
| `/ipg de` | Fenêtre de désenchantement |
| `/ipg sold` | Ventes au marchand des 7 derniers jours, et ce qui valait plus à l'HV |
| `/ipg report` | Rapport sur 30 jours |
| `/ipg hints` | Active / coupe les avertissements chez le marchand |
| `/ipg mail` | Boîte aux lettres de l'addon ou celle de Blizzard |

## Organisation du code

Ordre de chargement : voir `ImpotPointGouv.toc`. Tous les fichiers partagent la table `ns` (`local _, ns = ...`).

| Fichier | Rôle |
|---|---|
| `Core.lua` | Base de données (`ImpotPointGouvDB`), formats d'argent, petit bus d'événements (`ns.On` / `ns.Fire`) |
| `Ledger.lua` | Registre de l'or : chaque variation est classée (HV, marchand, quête, butin, courrier…) |
| `Track.lua` | Détail des ventes au marchand, butin, temps par zone/niveau, objets qui ne se vendent pas |
| `Theme.lua` | Couleurs, boutons, bulles, éléments d'interface |
| `UI.lua`, `Chart.lua` | Fenêtre principale, onglets, graphique |
| `Mail.lua` | Boîte aux lettres (onglets Inbox / Send) |
| `Prices.lua` | Scans HV et historique des prix |
| `Craft.lua`, `Queue.lua`, `Keep.lua` | Conseiller de craft, file de fabrication, réserves à garder |
| `Routine.lua`, `Next.lua`, `Preview.lua` | Routine (courses, envois, vente marchand), aperçu avant les actions en lot |
| `Sell.lua` | Mise en vente et annulation à l'HV |
| `Market.lua` | Onglet Marché (ce qui se vend, flips) |
| `Destroy.lua` | Désenchantement |
| `Inventory.lua`, `Trainer.lua`, `Report.lua`, `Setup.lua` | Inventaire multi-persos, entraîneur, rapport, guide de démarrage |

## Contribuer

1. Faire un fork, puis une branche par sujet (`fix/mail-send`, `feat/weekly-report`…).
2. Tester en jeu (WoW Forever, client moderne, Lua 5.1).
3. Ouvrir une Pull Request avec ce qui change et comment tester.

Règles de la maison :
- Interface en anglais, commentaires du code en français.
- Peu de texte, des boutons clairs.
- Les actions protégées du jeu (poster, acheter, envoyer) demandent un clic par action : l'addon prépare, le joueur clique.
- Jamais de modification des données sauvegardées sans migration (`ns.db.version` dans `Core.lua`).

## Licence

Bibliothèques incluses dans `libs/` : licence Ace3 (voir `libs/LICENSE-Ace3.txt`). Police Inter : SIL OFL (voir `media/fonts/OFL-inter.txt`).
