Module monitoring de veille territoriale des aires de rapaces (hors gypaètes et aigles).

Module de suivi simplifié à deux niveaux : site + visite (pas de niveau observation).

### SITES

Contient les types de site"Autre aire de rapace" + "aigle d'aigle" + "aire de gypaète"

### Synthèse

Ce module ne dispose pas de vue `synthese.sql` : il n'y a **pas de synchronisation vers la synthèse**.

### Exports CSV

Deux vues d'export sont définies dans `exports/csv/export_csv.sql` :

- `gn_monitoring.v_export_rapace_sites`
- `gn_monitoring.v_export_rapace_visits`
