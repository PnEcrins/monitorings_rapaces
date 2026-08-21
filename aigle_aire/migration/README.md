# Migration Aigle vers monitoring

Le problème majeur vient du fait que les géométrie des territoire on évolué.
Voici un tableau qui analyse quels changements ont eu lieu sur les territoire

| Cas                                                                                  | Diagnostic (vérifié par géométrie)                                                                                                                      |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Saint-Maurive-en-Valgodemar (2009, secteur 5) vs Saint-Maurice-en-Valgodemar (2010+) | Faute de frappe — IoU = 1.000, même polygone exact                                                                                                      |
| Molines en Champsaur secteur 4 (2009-2010) vs secteur 5 (2011+)                      | Secteur corrigé — IoU = 0.935, même territoire                                                                                                          |
| Malaval secteur 7 (2009 seul) vs secteur 1 (2010+)                                   | Erreur de saisie du secteur en 2009 — distance 0, polygones qui se recouvrent                                                                           |
| Pelvoux + Ailefroide (2009-2015) → Pelvoux-Ailefroide (2016+)                        | Fusion — union des 2 polygones 2015 = IoU 0.985 avec le polygone 2016                                                                                   |
| Roche de Rame Ascension (2010-2020) → Roche de Rame (2021+)                          | Renommage + retracé — IoU 0.339, même secteur/zone                                                                                                      |
| L'Argentière (2010-2018) → absorbé par Montbrison-Prelles à partir de 2019           | Fusion — 88% de la surface 2018 de L'Argentière recouverte par Montbrison-Prelles 2019 (explique aussi son IoU anormalement bas cette année-là : 0.186) |
| Montbrison-Prelles (2009-2020) → Montbrison (2021+)                                  | Renommage + retracé (IoU 0.590)                                                                                                                         |
| Guillestre (nouveau 2021)                                                            | Vraiment nouveau — 5.7% seulement de recouvrement avec un territoire 2020                                                                               |
| Les Infournas (nouveau 2015)                                                         | Vraiment nouveau — 2.2% de recouvrement                                                                                                                 |
| Autane (nouveau 2019)                                                                | Scission — 41.5% de sa surface vient d'Ancelle 2018                                                                                                     |
| Reyssas (nouveau 2013)                                                               | Scission — 58.4% vient de Mont-Guillaume + 37.8% de Réallon (2012)                                                                                      |

Deux cas de fusion :

D'après l'analyse géométrique (deux territoires qui existent simultanément avant de fusionner en un seul), il y a 2 cas de fusion depuis 2009 :

Fusion Détail
Pelvoux + Ailefroide → Pelvoux-Ailefroide (2016) Coexistent 2009-2015 (secteur 2), fusionnent proprement en 2016 — union des deux polygones 2015 = 98,5% du polygone fusionné. Fusion nette, sans ambiguïté.
L'Argentière (2010-2018) → absorbé par ses voisins Coexiste avec Roche de Rame Ascension (2012-2018) et avec Montbrison-Prelles (2010-2011). Contrairement à Pelvoux/Ailefroide, ce n'est pas une fusion propre en un seul nouveau territoire : selon l'année, la géométrie de L'Argentière matche tantôt mieux Roche de Rame (43-50%), tantôt Montbrison — c'est le cas ambigu que je vous signalais en warning dans le script (recouvrement < 50%, à vérifier manuellement).

-> jamais aucun succès sur l'argentière
-> jamais aucun succès simultannée sur Pelvoux + Ailefroide

# Cas des "statut de repro" expert et calculés

Les statuts de reproduction sont stocké dans la table pr_aigle.t_territoire, ou chaque territoire est dupliqué par année. Dans monitorins on ne peux pas stocké cette info au niveau de la table "site", on a donc du créer une visite "factice" pour stocker le bilan final avec les statuts de reproduction. On a mis cette visite au 1er novembre de chaque année pour chaque site.

VOir ce domaine qui a 2 statut expert :
http://127.0.0.1:4200/#/monitorings/object/domaine_vital/visit/12637?parents_path=module&parents_path=site
