# Modules monitoring aigle

En 2026 le PNE migre son ancienne application aigle vers le module monitoring.
Pour répondre au besoin du protocole (saisie de visites aux niveau des domaines vitaux et des aires), deux sous-modules monitoring sont créés.
Ce répo contient les configurations et migrations de données des deux sous modules.

## Détail de la migration des données

La migration part du schéma métier historique `pr_aigle`
vers le schéma générique `gn_monitoring`, pour les deux sous-modules. Le script
`aigle_aire/migration/migrate.py` (partagé entre les deux modules), est lancé une fois par
module :

```bash
cd backend && source venv/bin/activate
python media/monitorings/aigle/migration/migrate.py --module domaine_vital --id-dataset <ID> [--dry-run]
python media/monitorings/aigle/migration/migrate.py --module aigle         --id-dataset <ID> [--dry-run]
```

`domaine_vital` a été lancé avant `aigle` pour inscrire l'id_base_visit_domaine_vital dans chaque aire (nécessaire pour le trigger plus bas)

### Correspondance des tables

| Module        | Ancien (pr_aigle)                             | Nouveau (gn_monitoring)                                              |
| ------------- | --------------------------------------------- | -------------------------------------------------------------------- |
| aigle         | `t_aires`                                     | `t_base_sites` + `t_site_complements` (type de site `AIRE_AIGLE`)    |
| aigle         | `t_visites` + `cor_visite_activite`           | `t_base_visits` + `t_visit_complements`                              |
| domaine_vital | `t_territoires`                               | `t_base_sites` + `t_site_complements` (type de site `DOMAINE_VITAL`) |
| domaine_vital | `t_rencontres` + `cor_rencontre_comportement` | `t_base_visits` + `t_visit_complements`                              |

### Changement de structure

Certaines anciennes valeurs de `bib_activites` (aigle) et `bib_comportements`
(domaine_vital) ne sont plus des nomenclatures dans le nouveau modèle : elles sont
devenues des champs entiers de comptage (`nb_adulte`, `nb_jeune_blanc`,
`nb_jeune_noir`, `nb_jeune_envole` côté aigle ; `nb_jeune_seul`,
`nb_jeune_avec_adulte` côté domaine_vital).
Ce changement est fait pour éviter de mélanger des dénombrement et des comportements.

### Problème de non-unicité des domaines vitaux

`pr_aigle.t_territoires` n'a pas d'identifiant stable pour les domaines vitaux : une
ligne est recréée chaque année pour chaque territoire, et les territoires ont parfois
été renommés, refusionnés, scindés ou même supprimés. Or les visites sont rattaché à ces id_territoire qui ont bougé dans le temps...

Stratégie retenue (`fetch_territoire_site_matches()`) : le site créé pour chaque
domaine vital correspond au territoire de l'année la plus récente (2026), et les visites rattaché aux anciens domaines vitaux leur sont rattaché par
recouvrement géométrique (le domaine vital dont la géométrie recouvre le
plus la surface de l'ancien domaine).

Cas particuliers identifiés dans `aigle_aire/migration/README.md`) :

### La visite "bilan" pour le statut de reproduction (domaine_vital)

`pr_aigle.t_territoires` a deux statuts de reproduction par territoire et par année :
`id_statut_repro_expert` et `id_statut_repro_calcul`. Le modèle générique
`gn_monitoring` ne permet pas de stocker cette info au niveau du site (une seule
géométrie/entité par site, pas de possibilité de stocké des variables "temporelles" ).
On a donc dû créer une visite "bilan" par domaine vital et par année non issue de vrai contôle, datée arbitrairement au 1er novembre de l'année du
territoire (avant le début de la saison suivante)

### Rattachement aire ↔ domaine vital (`id_base_site_domaine_vital`)

Le module "aigle" historique calcul un statut de reproduction automatique à partir des visites et des comportements notés sur les aire. Dans la v2 on a perdu tout lien entre les domaine vitaux et les aire. On a donc du refaire ce lien via le champs additionnel `id_base_site_domaine_vital` stocké sur les aires

Cette correspondance a été faire à partir de `pr_aigle.cor_aire_territoire` en prenant le dernier rattachement d'une aire à son domaine (c'était historiquement une many to many)

### Autres changement lié à la migration

- Le champs `gn_monitoring.t_base_visit.first_use_date` est obligatoire. Au niveau de `pr_aigle.t_territoires` on a que l'année de découverte. Le champs a donc été rempli en mettant le 1 janvier de l'année.

### Trigger de synchronisation du statut de reproduction

Pour garder la fonctionnalité de calcul automatique du statut de reproduction à partir des données de visite d'aire, un trigger a été rajouté sur la table `gn_monitoring.t_visit_complements`

- `trg_aigle_visit_statut_repro` (AFTER INSERT OR UPDATE ON
  `gn_monitoring.t_visit_complements`) ne s'exécute que pour les visites du module
  aigle.
- Il retrouve le domaine vital de l'aire via `t_site_complements.data->>
'id_base_site_domaine_vital'`
- Il calcule le statut de reproduction induit par la visite : le plus élevé parmi les
  activités cochées (via la table de correspondance
  `gn_monitoring.bib_correspondance_activite_statut_repro`, qui reprend les mêmes
  codes `0`..`9` que l'ancien `pr_aigle.bib_statut_reproduction`) et les champs de
  comptage (`nb_jeune_blanc`/`nb_jeune_noir` > 0 ⇒ au moins "reproduction en cours" ;
  `nb_jeune_envole` = 1 ou ≥ 2 ⇒ "1/2 jeune(s) envolé(s)").
- Il compare ce statut au meilleur statut déjà connu pour ce domaine vital sur la même
  saison (année de la visite) : si le statut de reproduction est "supérieur" au statut existant, on crée
  une nouvelle visite sur le domaine_vital. Cette visite a un commentaire spécifique qui dit qu'elle a été créé automatiquement et ne contient aucun "observateur"

Dans le V1 :
Contrairement aux "activités" sur les aires, les "comportements" noté lors d'une "rencontre" sur un domaine vital n'entraine pas un véritable changement du statut de repro. Même si on note deun comportement "deux jeunes avec les adultes", le statut de repro est mis à "aucune conclusion possible". Sans la V2, on ne change pas automatiquement via trigger le statut de repro à partir des visites sur les domaine vitaux. Il faut explicitement modifier le statut de repro pour que celui-ci s'affiche en couleur sur la carte
