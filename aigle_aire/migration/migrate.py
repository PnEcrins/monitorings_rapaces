"""
Usage :
    cd backend
    source venv/bin/activate
    python media/monitorings/aigle_aire/migration/migrate.py --module domaine_vital --id-dataset <ID_DATASET> [--dry-run]
    python media/monitorings/aigle_aire/migration/migrate.py --module aigle --id-dataset <ID_DATASET> [--dry-run]

Le script suppose une base cible vide (pas de site, ni de visite pour ces modules)
"""

import argparse
import logging
from datetime import date

from sqlalchemy import text
from geoalchemy2.elements import WKTElement

from geonature import create_app
from pypnusershub.db.models import User
from geonature.utils.env import DB
from geonature.core.gn_monitoring.models import BibTypeSite
from gn_module_monitoring.monitoring.models import TMonitoringSites, TMonitoringVisits

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger("migrate_monitoring")

ID_MODULE_AIGLE = None
ID_TYPE_SITE_AIRE_AIGLE = None

ID_MODULE_DOMAINE_VITAL = None
ID_TYPE_SITE_DOMAINE_VITAL = None

# Utilisateurs par défaut pour remplir les champs observateur et digitizer (dans le schéma pr_aigle, certain id_role ne pointe vers aucun utilisateurs rééls)
DEFAULT_USER = 1251

# Tables de nomenclatures pr_aigle à faire correspondre aux nomenclatures
# ref_nomenclatures du même type, par libellé (label_default)

NOMENCLATURE_SOURCES_AIGLE = {
    "topology": ("bib_topologies", "id_topologie", "topologie", "AIGLE_AIRE_TOPOLOGY"),
    "position": ("bib_positions", "id_position", "positionnement", "AIGLE_POSITION_FALAISE"),
    "orientation": ("bib_orientations", "id_orientation", "orientation", "AIGLE_ORIENTATION_AIRE"),
    "substratum": ("bib_substrats", "id_substrat", "substrat", "AIGLE_SUBSTRAT"),
    "activity": ("bib_activites", "id_activite", "activite", "AIGLE_ACTIVITE_AIRE"),
}

NOMENCLATURE_SOURCES_DOMAINE_VITAL = {
    "comportement": (
        "bib_comportements", "id_comportement", "comportement", "AIGLE_COMPORTEMENT_DOMAINE_VITAL",
    ),
    "reproduction_status": (
        "bib_statut_reproduction", "id_statut_repro", "statut_repro", "AIGLE_STATUT_REPRODUCTION",
    ),
}

# Anciennes activités (pr_aigle.bib_activites) de comptage d'individus : elles ne
# sont plus des nomenclatures d'activité mais des champs entiers du site.json 
COUNT_ACTIVITY_LABELS = {
    "nb_adulte": {"1 adulte sur l'aire": 1, "2 adultes sur l'aire": 2},
    "nb_jeune_blanc": {"1 jeune blanc vu": 1, "2 jeunes blancs vus": 2},
    "nb_jeune_noir": {"1 jeunes noir vu": 1, "2 jeunes noirs vus": 2},
    "nb_jeune_envole": {"1 jeune envolé": 1, "2 jeunes envolés": 2},
}

# Idem pour les anciens comportements (pr_aigle.bib_comportements) de comptage de
# jeunes, portés par visit.json (nb_jeune_seul, nb_jeune_avec_adulte).
COUNT_COMPORTEMENT_LABELS = {
    "nb_jeune_seul": {"1 jeune seul": 1, "2 jeunes seuls": 2},
    "nb_jeune_avec_adulte": {"1 jeune avec les adultes": 1, "2 jeunes avec les adultes": 2},
}


# --------------------------------------------------------------------------------
# Helpers génériques, partagés entre les migrations aigle et domaine_vital
# --------------------------------------------------------------------------------


def load_nomenclature_by_type(nomenclature_type_code):
    """
    Retourne (label_default normalisé -> id_nomenclature, id_nomenclature -> label_default)
    pour un type de nomenclature ref_nomenclatures.
    """
    rows = DB.session.execute(
        text(
            """
            SELECT n.label_default, n.id_nomenclature
            FROM ref_nomenclatures.t_nomenclatures n
            JOIN ref_nomenclatures.bib_nomenclatures_types t ON t.id_type = n.id_type
            WHERE t.mnemonique = :type_code
            """
        ),
        {"type_code": nomenclature_type_code},
    ).all()
    id_by_label = {label.strip().lower(): id_nomenclature for label, id_nomenclature in rows}
    label_by_id = {id_nomenclature: label for label, id_nomenclature in rows}
    return id_by_label, label_by_id


def load_nomenclature_mappings(sources):
    """
    Construit, pour chaque table pr_aigle.bib_* de `sources` (au format de
    NOMENCLATURE_SOURCES_AIGLE / NOMENCLATURE_SOURCES_DOMAINE_VITAL)
    """
    mappings = {}
    for key, (table, id_column, label_column, type_code) in sources.items():
        id_by_label, label_by_id = load_nomenclature_by_type(type_code)
        old_rows = DB.session.execute(
            text(f"SELECT {id_column}, {label_column} FROM pr_aigle.{table}")
        ).all()

        mapping = {}
        for old_id, label in old_rows:
            new_id = id_by_label.get((label or "").strip().lower())
            if new_id is None:
                logger.warning(
                    "%s.%s (id=%s) : aucune nomenclature %s pour le libellé %r",
                    table, id_column, old_id, type_code, label,
                )
                mapping[old_id] = (None, None)
            else:
                mapping[old_id] = (new_id, label_by_id[new_id])
        mappings[key] = mapping
    return mappings


def load_count_label_mapping(table, id_column, label_column, count_labels):
    """
    {ancien id (pr_aigle.<table>) -> (champ JSON, valeur)} pour les anciennes
    valeurs de comptage (COUNT_ACTIVITY_LABELS / COUNT_COMPORTEMENT_LABELS),
    identifiées par libellé.
    """
    label_to_field_count = {
        label.strip().lower(): (field, count)
        for field, labels in count_labels.items()
        for label, count in labels.items()
    }
    rows = DB.session.execute(
        text(f"SELECT {id_column}, {label_column} FROM pr_aigle.{table}")
    ).all()
    return {
        old_id: label_to_field_count[(label or "").strip().lower()]
        for old_id, label in rows
        if (label or "").strip().lower() in label_to_field_count
    }


def load_existing_site_map(old_id_key):
    """
    {ancien id -> id_base_site} pour les sites déjà migrés portant `old_id_key` dans
    leur data. Utilisé par resolve_aire_domaine_vital_sites() pour retrouver les sites
    domaine_vital déjà migrés (ce module doit tourner avant aigle).
    """
    rows = DB.session.execute(
        text(
            f"SELECT id_base_site, (data->>'{old_id_key}')::int AS old_id "
            f"FROM gn_monitoring.t_site_complements WHERE data ? '{old_id_key}'"
        )
    ).all()
    return {row.old_id: row.id_base_site for row in rows}


def user_exists(id_role):
    """Vérifie si un utilisateur existe dans la base."""
    if id_role is None:
        return False
    return DB.session.execute(
        text("SELECT 1 FROM utilisateurs.t_roles WHERE id_role = :id"),
        {"id": id_role}
    ).scalar() is not None


def load_observer(id_role):
    """
    Retourne l'utilisateur (User) correspondant à id_role, ou None s'il n'existe pas.
    Contrairement à id_digitiser/id_inventor (qui retombent sur DEFAULT_USER),
    un observateur introuvable est simplement ignoré (juste loggé).
    """
    if id_role is None:
        return None
    user = DB.session.get(User, id_role)
    if user is None:
        logger.warning(f"Observateur {id_role} introuvable, ignoré des observers")
    return user


def load_module_id(module_code):
    """Charge l'ID d'un module monitoring à partir de son code mnémonique."""
    module_id = DB.session.execute(
        text("SELECT id_module FROM gn_commons.t_modules WHERE module_code = :code"),
        {"code": module_code},
    ).scalar()
    if module_id is None:
        raise RuntimeError(f"Module '{module_code}' introuvable dans gn_commons.t_modules")
    return module_id


def load_nomenclature_type_id(type_code):
    """Charge l'ID de nomenclature d'un type de site à partir de son code mnémonique."""
    type_id = DB.session.execute(
        text(
            """
            SELECT id_nomenclature FROM ref_nomenclatures.t_nomenclatures n
            JOIN ref_nomenclatures.bib_nomenclatures_types t ON t.id_type = n.id_type
            WHERE t.mnemonique = 'TYPE_SITE' AND n.cd_nomenclature = :code
            """
        ),
        {"code": type_code},
    ).scalar()
    if type_id is None:
        raise RuntimeError(f"Nomenclature TYPE_SITE/{type_code} introuvable")
    return type_id


# --------------------------------------------------------------------------------
# Module "aigle"
# --------------------------------------------------------------------------------


def fetch_aires():
    return DB.session.execute(
        text(
            """
            SELECT id_aire, id_observateur, id_topologie, id_orientation, id_substrat,
                   id_position, num_aire, nom_aire, annee_decouverte, altitude,
                   hauteur_falaise, validation,
                   ST_AsText(ST_Transform(the_geom, 4326)) AS geom_wkt
            FROM pr_aigle.t_aires
            ORDER BY id_aire
            """
        )
    ).mappings().all()


def fetch_visites():
    return DB.session.execute(
        text(
            """
            SELECT id_visite, id_observateur, id_redacteur, id_aire, date_visite,
                   remarques, duree
            FROM pr_aigle.t_visites
            ORDER BY id_visite
            """
        )
    ).mappings().all()


def fetch_activities_by_visite():
    rows = DB.session.execute(
        text("SELECT id_visite, id_activite FROM pr_aigle.cor_visite_activite")
    ).all()
    activities = {}
    for id_visite, id_activite in rows:
        activities.setdefault(id_visite, []).append(id_activite)
    return activities


def fetch_cor_aire_territoire():
    return DB.session.execute(
        text("SELECT id_aire, id_territoire FROM pr_aigle.cor_aire_territoire")
    ).all()


def resolve_aire_domaine_vital_sites(reference_year):
    """
    Pour chaque aire pr_aigle.t_aires, résout l'id_base_site (gn_monitoring) du
    domaine vital auquel elle est actuellement rattachée, via
    pr_aigle.cor_aire_territoire. 

    Retourne {id_aire -> id_base_site (ou None)}.
    """
    site_match = fetch_territoire_site_matches(reference_year)
    existing_domaine_vital_sites = load_existing_site_map("old_id_territoire")
    territoires_by_id = {t["id_territoire"]: t for t in fetch_territoires()}

    territoire_ids_by_aire = {}
    for id_aire, id_territoire in fetch_cor_aire_territoire():
        territoire_ids_by_aire.setdefault(id_aire, []).append(id_territoire)

    id_base_site_by_aire = {}
    for id_aire, territoire_ids in territoire_ids_by_aire.items():
        territoire_id = next(
            (tid for tid in territoire_ids if territoires_by_id[tid]["annee"] == reference_year),
            None,
        )
        if territoire_id is None:
            territoire_id = max(territoire_ids, key=lambda tid: territoires_by_id[tid]["annee"])

        id_territoire_ref = site_match.get(territoire_id)
        id_base_site = (
            existing_domaine_vital_sites.get(id_territoire_ref) if id_territoire_ref else None
        )
        if id_base_site is None:
            logger.warning(
                "pr_aigle.t_aires (id=%s) : domaine vital (territoire réf. %s) sans site "
                "gn_monitoring migré, id_base_site_domaine_vital laissé vide",
                id_aire, id_territoire_ref,
            )
        id_base_site_by_aire[id_aire] = id_base_site
    return id_base_site_by_aire


def build_visit_aigle(
    visite, id_dataset, activities_by_visite, activity_mapping, count_activity_mapping
):
    old_id = visite["id_visite"]
    old_activities = activities_by_visite.get(old_id, [])

    mapped_activities = [
        activity_mapping[old_activity]
        for old_activity in old_activities
        if activity_mapping.get(old_activity, (None, None))[0] is not None
    ]
    activity_ids = [new_id for new_id, _label in mapped_activities]
    activity_labels = [label for _new_id, label in mapped_activities]

    counts = {
        "nb_adulte": None, "nb_jeune_blanc": None, "nb_jeune_noir": None, "nb_jeune_envole": None,
    }
    for old_activity in old_activities:
        match = count_activity_mapping.get(old_activity)
        if match is not None:
            field, count = match
            counts[field] = max(counts[field] or 0, count)

    id_digitiser = visite["id_redacteur"] or visite["id_observateur"]
    if not user_exists(id_digitiser):
        logger.warning(f"Utilisateur {id_digitiser} introuvable, utilisation de DEFAULT_USER")
        id_digitiser = DEFAULT_USER

    observer = load_observer(visite["id_observateur"])
    observers = [observer] if observer else []

    return TMonitoringVisits(
        id_dataset=id_dataset,
        id_module=ID_MODULE_AIGLE,
        id_digitiser=id_digitiser,
        visit_date_min=visite["date_visite"],
        visit_date_max=visite["date_visite"],
        comments=visite["remarques"],
        observers=observers,
        data={
            "old_id_visite": old_id,
            "visit_duration": visite["duree"],
            "activite_aire": activity_ids,
            "_label_activite_aire": activity_labels,
            "nb_adulte": counts["nb_adulte"],
            "nb_jeune_blanc": counts["nb_jeune_blanc"],
            "nb_jeune_noir": counts["nb_jeune_noir"],
            "nb_jeune_envole": counts["nb_jeune_envole"],
        },
    )


def build_site_aigle(aire, bib_type_site, visits, nomenclature_mappings, id_base_site_domaine_vital):
    old_id = aire["id_aire"]

    topology_id, topology_label = nomenclature_mappings["topology"].get(
        aire["id_topologie"], (None, None)
    )
    position_id, position_label = nomenclature_mappings["position"].get(
        aire["id_position"], (None, None)
    )
    orientation_id, orientation_label = nomenclature_mappings["orientation"].get(
        aire["id_orientation"], (None, None)
    )
    substratum_id, substratum_label = nomenclature_mappings["substratum"].get(
        aire["id_substrat"], (None, None)
    )

    first_use_date = date(aire["annee_decouverte"], 1, 1) if aire["annee_decouverte"] else None
    site_name = aire["nom_aire"] or aire["num_aire"] or f"Aire {old_id}"

    id_observateur = aire["id_observateur"]
    if not user_exists(id_observateur):
        logger.warning(f"Utilisateur {id_observateur} introuvable, utilisation de DEFAULT_USER")
        id_observateur = DEFAULT_USER

    return TMonitoringSites(
        id_inventor=id_observateur,
        id_digitiser=id_observateur,
        base_site_name=site_name,
        base_site_code=aire["num_aire"],
        first_use_date=first_use_date,
        altitude_min=aire["altitude"],
        altitude_max=aire["altitude"],
        geom=WKTElement(aire["geom_wkt"], srid=4326) if aire["geom_wkt"] else None,
        types_site=[bib_type_site],
        visits=visits,
        data={
            "old_id_aire": old_id,
            "id_nomenclature_topology": topology_id,
            "_label_id_nomenclature_topology": topology_label,
            "heigth": aire["hauteur_falaise"],
            "id_nomenclature_position_cliff": position_id,
            "_label_id_nomenclature_position_cliff": position_label,
            "id_nomenclature_orientation": orientation_id,
            "_label_id_nomenclature_orientation": orientation_label,
            "id_nomenclature_substratum": substratum_id,
            "_label_id_nomenclature_substratum": substratum_label,
            "valid": bool(aire["validation"]),
            "id_base_site_domaine_vital": id_base_site_domaine_vital,
        },
    )


def migrate_aigle(id_dataset):
    bib_type_site = DB.session.get(BibTypeSite, ID_TYPE_SITE_AIRE_AIGLE)
    if bib_type_site is None:
        raise RuntimeError(
            f"gn_monitoring.bib_type_site introuvable pour id_nomenclature_type_site="
            f"{ID_TYPE_SITE_AIRE_AIGLE} (AIRE_AIGLE)"
        )

    nomenclature_mappings = load_nomenclature_mappings(NOMENCLATURE_SOURCES_AIGLE)
    count_activity_mapping = load_count_label_mapping(
        "bib_activites", "id_activite", "activite", COUNT_ACTIVITY_LABELS
    )

    reference_year = DB.session.execute(text("SELECT max(annee) FROM pr_aigle.t_territoires")).scalar()
    id_base_site_domaine_vital_by_aire = resolve_aire_domaine_vital_sites(reference_year)

    aires = fetch_aires()
    visites = fetch_visites()
    activities_by_visite = fetch_activities_by_visite()

    visites_by_aire = {}
    for visite in visites:
        visites_by_aire.setdefault(visite["id_aire"], []).append(visite)

    n_sites_created = 0
    n_visits_created = 0

    for aire in aires:
        old_id_aire = aire["id_aire"]
        id_base_site_domaine_vital = id_base_site_domaine_vital_by_aire.get(old_id_aire)

        new_visits = [
            build_visit_aigle(
                visite, id_dataset, activities_by_visite,
                nomenclature_mappings["activity"], count_activity_mapping,
            )
            for visite in visites_by_aire.get(old_id_aire, [])
        ]

        site = build_site_aigle(
            aire, bib_type_site, new_visits, nomenclature_mappings, id_base_site_domaine_vital
        )
        DB.session.add(site)
        n_sites_created += 1
        n_visits_created += len(new_visits)

    logger.info(
        "Aigle : %s sites créés, %s visites créées.", n_sites_created, n_visits_created,
    )


# --------------------------------------------------------------------------------
# Module "domaine_vital"
# --------------------------------------------------------------------------------


def fetch_territoires():
    return DB.session.execute(
        text(
            """
            SELECT id_territoire, num_territoire, nom_territoire, annee,
                   id_statut_repro_expert, id_statut_repro_calcul,
                   ST_AsText(ST_Transform(the_geom, 4326)) AS geom_wkt
            FROM pr_aigle.t_territoires
            ORDER BY id_territoire
            """
        )
    ).mappings().all()


def fetch_rencontres():
    return DB.session.execute(
        text(
            """
            SELECT id_rencontre, id_observateur, id_redacteur, id_territoire,
                   date_rencontre, remarques, duree
            FROM pr_aigle.t_rencontres
            ORDER BY id_rencontre
            """
        )
    ).mappings().all()


def fetch_comportements_by_rencontre():
    rows = DB.session.execute(
        text("SELECT id_rencontre, id_comportement FROM pr_aigle.cor_rencontre_comportement")
    ).all()
    comportements = {}
    for id_rencontre, id_comportement in rows:
        comportements.setdefault(id_rencontre, []).append(id_comportement)
    return comportements


def fetch_territoire_site_matches(reference_year):
    """
    Associe chaque territoire pr_aigle.t_territoires (une ligne par territoire et par
    année) au territoire de `reference_year` (l'état le plus récent du domaine vital)
    dont la géométrie le recouvre le mieux.
    """
    rows = DB.session.execute(
        text(
            """
            WITH cur AS (
                SELECT id_territoire, the_geom FROM pr_aigle.t_territoires WHERE annee = :annee
            ),
            best AS (
                SELECT
                    h.id_territoire,
                    c.id_territoire AS id_territoire_ref,
                    ST_Area(ST_Intersection(h.the_geom, c.the_geom))
                        / NULLIF(ST_Area(h.the_geom), 0) AS part_couverte,
                    row_number() OVER (
                        PARTITION BY h.id_territoire
                        ORDER BY ST_Area(ST_Intersection(h.the_geom, c.the_geom)) DESC
                    ) AS rk
                FROM pr_aigle.t_territoires h
                JOIN cur c ON ST_Intersects(h.the_geom, c.the_geom)
            )
            SELECT id_territoire, id_territoire_ref, part_couverte FROM best WHERE rk = 1
            """
        ),
        {"annee": reference_year},
    ).all()

    matches = {}
    for id_territoire, id_territoire_ref, part_couverte in rows:
        if part_couverte < 0.5:
            logger.warning(
                "pr_aigle.t_territoires (id=%s) : correspondance incertaine avec le domaine "
                "vital %s actuel (%.0f%% de sa surface recouverte), à vérifier",
                id_territoire, id_territoire_ref, part_couverte * 100,
            )
        matches[id_territoire] = id_territoire_ref

    all_ids = DB.session.execute(text("SELECT id_territoire FROM pr_aigle.t_territoires")).scalars().all()
    for id_territoire in all_ids:
        if id_territoire not in matches:
            logger.warning(
                "pr_aigle.t_territoires (id=%s) : aucun domaine vital actuel ne recouvre sa "
                "géométrie, rencontres ignorées",
                id_territoire,
            )
    return matches


def build_visit_domaine_vital(
    rencontre, id_dataset, comportements_by_rencontre,
    comportement_mapping, count_comportement_mapping
):
    old_id = rencontre["id_rencontre"]
    old_comportements = comportements_by_rencontre.get(old_id, [])

    mapped_comportements = [
        comportement_mapping[old_comportement]
        for old_comportement in old_comportements
        if comportement_mapping.get(old_comportement, (None, None))[0] is not None
    ]
    comportement_ids = [new_id for new_id, _label in mapped_comportements]
    comportement_labels = [label for _new_id, label in mapped_comportements]

    counts = {"nb_jeune_seul": None, "nb_jeune_avec_adulte": None}
    for old_comportement in old_comportements:
        match = count_comportement_mapping.get(old_comportement)
        if match is not None:
            field, count = match
            counts[field] = max(counts[field] or 0, count)

    id_digitiser = rencontre["id_redacteur"] or rencontre["id_observateur"]
    if not user_exists(id_digitiser):
        logger.warning(f"Utilisateur {id_digitiser} introuvable, utilisation de DEFAULT_USER")
        id_digitiser = DEFAULT_USER

    observer = load_observer(rencontre["id_observateur"])
    observers = [observer] if observer else []

    return TMonitoringVisits(
        id_dataset=id_dataset,
        id_module=ID_MODULE_DOMAINE_VITAL,
        id_digitiser=id_digitiser,
        visit_date_min=rencontre["date_rencontre"],
        visit_date_max=rencontre["date_rencontre"],
        comments=rencontre["remarques"],
        observers=observers,
        data={
            "old_id_rencontre": old_id,
            "visit_duration": rencontre["duree"],
            "comportement_domaine_vital": comportement_ids,
            "_label_comportement_domaine_vital": comportement_labels,
            "nb_jeune_seul": counts["nb_jeune_seul"],
            "nb_jeune_avec_adulte": counts["nb_jeune_avec_adulte"],
            "statut_reproduction": None,
        },
    )


def build_bilan_visit_domaine_vital(territoire, id_dataset, reproduction_status_mapping):
    """
    Visite "bilan" synthétique, une par territoire pr_aigle (donc par domaine vital et
    par année), portant le statut de reproduction expert/calculé de ce territoire.
    """
    status_expert_id, status_expert_label = reproduction_status_mapping.get(
        territoire["id_statut_repro_expert"], (None, None)
    )
    status_calcul_id, status_calcul_label = reproduction_status_mapping.get(
        territoire["id_statut_repro_calcul"], (None, None)
    )
    bilan_date = date(territoire["annee"], 11, 1)

    return TMonitoringVisits(
        id_dataset=id_dataset,
        id_module=ID_MODULE_DOMAINE_VITAL,
        visit_date_min=bilan_date,
        visit_date_max=bilan_date,
        comments=(
            "Bilan de la saison de reproduction (visite générée lors de la migration, "
            "non issue d'une rencontre pr_aigle)."
        ),
        observers=[],
        data={
            "old_id_territoire_bilan": territoire["id_territoire"],
            "visit_duration": None,
            "comportement_domaine_vital": [],
            "_label_comportement_domaine_vital": [],
            "nb_jeune_seul": None,
            "nb_jeune_avec_adulte": None,
            "statut_reproduction": status_expert_id,
            "_label_statut_reproduction": status_expert_label,
        },
    )


def build_site_domaine_vital(
    territoire_ref, first_use_year, old_ids_territoire, bib_type_site, visits, inventor_id, digitiser_id
):
    old_id = territoire_ref["id_territoire"]
    site_name = territoire_ref["nom_territoire"] or (
        f"Territoire {territoire_ref['num_territoire']}"
        if territoire_ref["num_territoire"]
        else f"Territoire {old_id}"
    )

    if inventor_id and not user_exists(inventor_id):
        logger.warning(f"Utilisateur {inventor_id} introuvable, utilisation de DEFAULT_USER")
        inventor_id = DEFAULT_USER
    if digitiser_id and not user_exists(digitiser_id):
        logger.warning(f"Utilisateur {digitiser_id} introuvable, utilisation de DEFAULT_USER")
        digitiser_id = DEFAULT_USER

    return TMonitoringSites(
        id_inventor=inventor_id,
        id_digitiser=digitiser_id,
        base_site_name=site_name,
        base_site_code=str(territoire_ref["num_territoire"]) if territoire_ref["num_territoire"] else None,
        first_use_date=date(first_use_year, 1, 1),
        geom=WKTElement(territoire_ref["geom_wkt"], srid=4326) if territoire_ref["geom_wkt"] else None,
        types_site=[bib_type_site],
        visits=visits,
        data={
            "old_id_territoire": old_id,
            "old_ids_territoire": sorted(old_ids_territoire),
        },
    )


def migrate_domaine_vital(id_dataset):
    bib_type_site = DB.session.get(BibTypeSite, ID_TYPE_SITE_DOMAINE_VITAL)
    if bib_type_site is None:
        raise RuntimeError(
            f"gn_monitoring.bib_type_site introuvable pour id_nomenclature_type_site="
            f"{ID_TYPE_SITE_DOMAINE_VITAL} (DOMAINE_VITAL)"
        )

    domaine_vital_mappings = load_nomenclature_mappings(NOMENCLATURE_SOURCES_DOMAINE_VITAL)
    comportement_mapping = domaine_vital_mappings["comportement"]
    reproduction_status_mapping = domaine_vital_mappings["reproduction_status"]
    count_comportement_mapping = load_count_label_mapping(
        "bib_comportements", "id_comportement", "comportement", COUNT_COMPORTEMENT_LABELS
    )

    reference_year = DB.session.execute(text("SELECT max(annee) FROM pr_aigle.t_territoires")).scalar()
    territoires = fetch_territoires()
    territoires_by_id = {t["id_territoire"]: t for t in territoires}
    site_match = fetch_territoire_site_matches(reference_year)

    territoire_ids_by_site = {}
    for id_territoire, id_site in site_match.items():
        territoire_ids_by_site.setdefault(id_site, []).append(id_territoire)

    rencontres = fetch_rencontres()
    comportements_by_rencontre = fetch_comportements_by_rencontre()

    rencontres_by_site = {}
    for rencontre in rencontres:
        id_site = site_match.get(rencontre["id_territoire"])
        if id_site is not None:
            rencontres_by_site.setdefault(id_site, []).append(rencontre)

    n_sites_created = 0
    n_visits_created = 0
    n_bilans_created = 0

    for id_site, old_ids_territoire in territoire_ids_by_site.items():
        site_rencontres = sorted(
            rencontres_by_site.get(id_site, []), key=lambda rencontre: rencontre["date_rencontre"]
        )

        new_visits = [
            build_visit_domaine_vital(
                rencontre, id_dataset, comportements_by_rencontre,
                comportement_mapping, count_comportement_mapping,
            )
            for rencontre in site_rencontres
        ]

        # Une visite bilan par territoire pr_aigle (donc par domaine vital et par
        # année), même les années sans rencontre réelle : le statut de reproduction
        #  existe indépendamment des rencontres sur pr_aigle.t_territoires.
        new_bilan_visits = [
            build_bilan_visit_domaine_vital(
                territoires_by_id[territoire_id], id_dataset, reproduction_status_mapping
            )
            for territoire_id in old_ids_territoire
        ]
        n_bilans_created += len(new_bilan_visits)

        # Le territoire n'a pas d'observateur propre (contrairement à l'aire) : le
        # site reprend l'observateur/rédacteur de sa première rencontre.
        first_rencontre = site_rencontres[0] if site_rencontres else None
        inventor_id = first_rencontre["id_observateur"] if first_rencontre else None
        digitiser_id = (
            (first_rencontre["id_redacteur"] or first_rencontre["id_observateur"])
            if first_rencontre
            else None
        )
        first_use_year = min(territoires_by_id[tid]["annee"] for tid in old_ids_territoire)
        site = build_site_domaine_vital(
            territoires_by_id[id_site], first_use_year, old_ids_territoire, bib_type_site,
            new_visits + new_bilan_visits, inventor_id, digitiser_id,
        )
        DB.session.add(site)
        n_sites_created += 1
        n_visits_created += len(new_visits)

    logger.info(
        "Domaine vital : %s sites créés, %s visites créées, %s bilans créés.",
        n_sites_created, n_visits_created, n_bilans_created,
    )


MIGRATIONS = {
    "aigle": migrate_aigle,
    "domaine_vital": migrate_domaine_vital,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--module", choices=sorted(MIGRATIONS), required=True,
        help="Module à migrer",
    )
    parser.add_argument(
        "--id-dataset", type=int, required=True,
        help="id_dataset (gn_meta.t_datasets) à associer aux visites migrées",
    )

    parser.add_argument(
        "--dry-run", action="store_true",
        help="Exécute la migration puis annule la transaction (aucune écriture en base)",
    )
    args = parser.parse_args()

    app = create_app()
    with app.app_context():
        global ID_MODULE_AIGLE, ID_TYPE_SITE_AIRE_AIGLE
        global ID_MODULE_DOMAINE_VITAL, ID_TYPE_SITE_DOMAINE_VITAL
        global DEFAULT_USER

        ID_MODULE_AIGLE = load_module_id("aigle_aire")
        ID_TYPE_SITE_AIRE_AIGLE = load_nomenclature_type_id("AIRE_AIGLE")
        ID_MODULE_DOMAINE_VITAL = load_module_id("aigle_domaine_vital")
        ID_TYPE_SITE_DOMAINE_VITAL = load_nomenclature_type_id("DOMAINE_VITAL")

        try:
            MIGRATIONS[args.module](args.id_dataset)
            if args.dry_run:
                DB.session.rollback()
                logger.info("Dry-run : transaction annulée, aucune donnée écrite.")
            else:
                DB.session.commit()
                logger.info("Migration terminée et validée.")
        except Exception:
            DB.session.rollback()
            logger.exception("Erreur durant la migration, transaction annulée.")
            raise


if __name__ == "__main__":
    main()
