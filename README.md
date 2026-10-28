# Modules monitorings

Ce repo regroupe les modules monitorings utilisé au PNE pour le suivi des rapaces.
Il regroupe les modules de suivi de la reproduction de l'aigle royal (aigle + domaine vital), le module de suivi de la reproduction des gypaètes barbus et le module de veille territoirial de toutes les aires de rapaces.

Les modules monitoring aigles et gypaètes sont complétés par le module "monitoring_year_synthese" qui permet d'avoir un vue cartographique de la reproduction année par année. Les modules contiennent donc des vues d'exports spécifiques pour ce module

Le module de veille territorial "aire de rapaces" a vocation a regrouper toutes les aires de rapaces connu sur le PNE pour avoir un vue d'ensemble des aires existantes (notamment utiles pour les autorisation de survols et autres). Ce module regroupe donc les trois "type de sites" : aigle, gypaète et "autre aire de rapace".

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
python media/monitorings/aigle_aire/migration/migrate.py --module domaine_vital --id-dataset <ID> [--dry-run]
python media/monitorings/aigle_aire/migration/migrate.py --module aigle         --id-dataset <ID> [--dry-run]
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

- Certaines anciennes valeurs de `bib_activites` (aigle) et `bib_comportements`
  (domaine_vital) ne sont plus des nomenclatures dans le nouveau modèle : elles sont
  devenues des champs entiers de comptage (`nb_adulte`, `nb_jeune_blanc`,
  `nb_jeune_noir`, `nb_jeune_envole` côté aigle ; `nb_jeune_seul`,
  `nb_jeune_avec_adulte` côté domaine_vital).
  Ce changement est fait pour éviter de mélanger des dénombrement et des comportements.

- le statut de reproduction, anciennement stocké au niveau du domaine vital (par année) est maintenant stocké au niveau de la visite. En effet le modèle de monitoring ne permet pas de stocker des valeurs temporelles au niveau du site. On a donc aujourd'hui potentiellement plusieurs "statut de reproduction" pour une année et pour un site. Le module "monitoring_year_synthese" se charge lui de remettre à plat le statut de repro par année et par domaine vital (en gardant le statut "max" -le plus important- -> les cd_nomenclatures de cet nomenclature on été ordonné pour faire ce calcul)
  Les champs "statut de reproduction expert" et "statut de reproduction calculé" situé dans l'ancienne table `pr_aigle.t_territoire` sont remplacé par un seul champs "id_nomenclature_statut_reproduction" qui est uniquement "saisi" par les gardes.
  Le statut "calculé" est réalisé par le module "monitoring_year_synthese" (voir la vue `gn_monitoring.v_export_domaine_vital_repro_status` qui remet à plat les différents statuts de repro des visites de l'année mais va aussi chercher des informations dans les visites d'aire associé au domaine vital); Le statut de reproduction ne peux pas être "baissé" par les obs d'une visite, mais il peut être "augmenté". Par exemple si une visite note "jeune mort" ou "oeuf mort" alors le statut passe à "échec de la repro" meme si le statut de repro d'une visite sur le domaine vital avait mis "succès de la repro" (même comportement qu'en v1)

Pour la migration on a donc dû créer une visite "bilan" par domaine vital et par année non issue de vrai contôle, datée arbitrairement au 1er novembre de l'année du
territoire (avant le début de la saison suivante)

Notes :

Dans la V1 :
Contrairement aux "activités" sur les aires, les "comportements" noté lors d'une "rencontre" sur un domaine vital n'entraine pas un véritable changement du statut de repro. Même si on note deun comportement "deux jeunes avec les adultes", le statut de repro est mis à "aucune conclusion possible". Sans la V2, on ne change le statut de repro à partir des visites sur les domaine vitaux. Il faut explicitement modifier le statut de repro pour que celui-ci s'affiche en couleur sur la carte

### Problème de non-unicité des domaines vitaux

`pr_aigle.t_territoires` n'a pas d'identifiant stable pour les domaines vitaux : une
ligne est recréée chaque année pour chaque territoire, et les territoires ont parfois
été renommés, refusionnés, scindés ou même supprimés. Or les visites sont rattaché à ces id_territoire qui ont bougé dans le temps...

Stratégie retenue (`fetch_territoire_site_matches()`) : le site créé pour chaque
domaine vital correspond au territoire de l'année la plus récente (2026), et les visites rattaché aux anciens domaines vitaux leur sont rattaché par
recouvrement géométrique (le domaine vital dont la géométrie recouvre le
plus la surface de l'ancien domaine).

Cas particuliers identifiés dans `aigle_aire/migration/README.md`) :

### Rattachement aire ↔ domaine vital (`id_base_site_domaine_vital`)

Le module "aigle" historique calcul un statut de reproduction automatique à partir des visites et des comportements notés sur les aire. Dans la v2 on a perdu tout lien entre les domaine vitaux et les aire. On a donc du refaire ce lien via le champs additionnel `id_base_site_domaine_vital` stocké sur les aires

Cette correspondance a été faire à partir de `pr_aigle.cor_aire_territoire` en prenant le dernier rattachement d'une aire à son domaine (c'était historiquement une many to many)

### Autres changement lié à la migration

- Le champs `gn_monitoring.t_base_visit.first_use_date` est obligatoire. Au niveau de `pr_aigle.t_territoires` on a que l'année de découverte. Le champs a donc été rempli en mettant le 1 janvier de l'année.

### Trigger de synchronisation du statut de reproduction

Pour garder le lien entre les sites et les domaines vitaux (utile pour calculer le statut de repro à partir des visites sur les aires), un trigger est déclenché à l'insertion ou à la modification de la géométrie du site ( -> voir `gn_monitoring.fct_trg_maj_domaine_vital_aire()`)

Le script "migration.sql" contient ce trigger ainsi que des requêtes SQL nécessaire au fonctionnement des vues (utilisé pour le module 'monitoring-year-synthese')
