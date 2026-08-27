-- gn_monitoring.v_synthese_aigle
--
-- Exécutée via `geonature monitoring install_monitoring_module aigle` (process_sql_files
-- appelle ce fichier avec le bind param :module_code = 'aigle').

DROP VIEW IF EXISTS gn_monitoring.v_synthese_aigle;
CREATE VIEW gn_monitoring.v_synthese_aigle AS

WITH source AS (
    SELECT id_source
    FROM gn_synthese.t_sources
    WHERE name_source = CONCAT('MONITORING_', UPPER(:module_code))
    LIMIT 1
), observers AS (
    SELECT
        array_agg(r.id_role) AS ids_observers,
        string_agg(concat(r.nom_role, ' ', r.prenom_role), ' ; ') AS observers,
        cvo.id_base_visit
    FROM gn_monitoring.cor_visit_observer cvo
    JOIN utilisateurs.t_roles r ON r.id_role = cvo.id_role
    GROUP BY cvo.id_base_visit
), counts AS (
    -- Total des effectifs comptés sur la visite (adultes + jeunes, tous stades).
    -- 0 si aucun champ de comptage n'est renseigné (pas de distinction avec un vrai 0 saisi).
    SELECT
        vc.id_base_visit,
        COALESCE((vc.data ->> 'nb_adulte')::int, 0)
            + COALESCE((vc.data ->> 'nb_jeune_blanc')::int, 0)
            + COALESCE((vc.data ->> 'nb_jeune_noir')::int, 0)
            + COALESCE((vc.data ->> 'nb_jeune_envole')::int, 0) AS total,
        COALESCE((vc.data ->> 'nb_adulte')::int, 0) > 0 AS has_adulte,
        (
            COALESCE((vc.data ->> 'nb_jeune_envole')::int, 0) > 0
            OR COALESCE((vc.data ->> 'nb_jeune_blanc')::int, 0) > 0
            OR COALESCE((vc.data ->> 'nb_jeune_noir')::int, 0) > 0
        ) AS has_jeune
    FROM gn_monitoring.t_visit_complements vc
), activities AS (
    SELECT
        vc.id_base_visit,
        bool_or(n.cd_nomenclature NOT IN ('AUCUNE_ACTIVITÉ_CONSTATÉE', 'AIRE_VIDE')) AS has_real_activity,
        bool_or(n.cd_nomenclature IN ('ACCOUPLEMENT_SUR_L''AIRE', 'COUVAISON')) AS has_reproduction,
        bool_or(n.cd_nomenclature = 'JEUNE(S)_MORT(S)') AS has_dead_young,
        -- match AIGLE_ACTIVITE_AIRE -> OCC_COMPORTEMENT ; en priorité le nourrissage s'il est aussi présent.
        CASE
            WHEN bool_or(n.cd_nomenclature = 'NOURRISSAGE')
                THEN ref_nomenclatures.get_id_nomenclature('OCC_COMPORTEMENT', '14')
            WHEN bool_or(n.cd_nomenclature = 'ACCOUPLEMENT_SUR_L''AIRE')
                THEN ref_nomenclatures.get_id_nomenclature('OCC_COMPORTEMENT', '19')
        END AS id_nomenclature_behaviour
    FROM gn_monitoring.t_visit_complements vc
    CROSS JOIN LATERAL jsonb_array_elements_text(
        CASE
            WHEN jsonb_typeof(vc.data -> 'activite_aire') = 'array' THEN vc.data -> 'activite_aire'
            ELSE '[]'::jsonb
        END
    ) AS act(id_nomenclature)
    JOIN ref_nomenclatures.t_nomenclatures n ON n.id_nomenclature = act.id_nomenclature::int
    GROUP BY vc.id_base_visit
)
SELECT
    v.uuid_base_visit AS unique_id_sinp,
    v.uuid_base_visit AS unique_id_sinp_grp,
    source.id_source,
    v.id_module,
    v.id_base_visit::varchar AS entity_source_pk_value,
    v.id_dataset,
    ref_nomenclatures.get_id_nomenclature('NAT_OBJ_GEO', 'St') AS id_nomenclature_geo_object_nature,
    v.id_nomenclature_grp_typ,
    v.id_nomenclature_tech_collect_campanule,
    CASE WHEN c.total > 0 THEN ref_nomenclatures.get_id_nomenclature('OBJ_DENBR', 'IND') END
        AS id_nomenclature_obj_count,
    CASE WHEN c.total > 0 THEN ref_nomenclatures.get_id_nomenclature('TYP_DENBR', 'Co') END
        AS id_nomenclature_type_count,
    ref_nomenclatures.get_id_nomenclature('STATUT_OBS', 'Pr') AS id_nomenclature_observation_status,
    ref_nomenclatures.get_id_nomenclature('STATUT_SOURCE', 'Te') AS id_nomenclature_source_status,
    ref_nomenclatures.get_id_nomenclature('TYP_INF_GEO', '1') AS id_nomenclature_info_geo_type,
    CASE WHEN act.has_reproduction THEN ref_nomenclatures.get_id_nomenclature('STATUT_BIO', '3') END
        AS id_nomenclature_bio_status,
    CASE WHEN act.has_dead_young THEN ref_nomenclatures.get_id_nomenclature('ETA_BIO', '3') END
        AS id_nomenclature_bio_condition,
    act.id_nomenclature_behaviour,
    -- Adulte si seul nb_adulte est renseigné, Juvénile si seuls les nb_jeune* le sont ;
    -- si adulte(s) ET jeune(s) sont tous les deux renseignés (stade mixte, pas de valeur
    -- STADE_VIE dédiée) ou si aucun des deux, on laisse la valeur par défaut de la synthèse.
    CASE
        WHEN c.has_adulte AND NOT c.has_jeune THEN ref_nomenclatures.get_id_nomenclature('STADE_VIE', '2')
        WHEN c.has_jeune AND NOT c.has_adulte THEN ref_nomenclatures.get_id_nomenclature('STADE_VIE', '3')
    END AS id_nomenclature_life_stage,
    c.total AS count_min,
    c.total AS count_max,
    t.cd_nom,
    t.nom_complet AS nom_cite,
    s.altitude_min,
    s.altitude_max,
    s.geom AS the_geom_4326,
    ST_centroid(s.geom) AS the_geom_point,
    s.geom_local AS the_geom_local,
    s.base_site_name AS place_name,
    v.visit_date_min AS date_min,
    COALESCE(v.visit_date_max, v.visit_date_min) AS date_max,
    obs.observers,
    obs.ids_observers,
    v.id_digitiser,
    v.comments AS comment_description,
    COALESCE(vc.data, '{}'::jsonb) AS additional_data,
    -- ## Colonnes complémentaires utilisées par gn_module_monitoring / import_from_table,
    -- sans équivalent dans gn_synthese.synthese
    v.id_base_site,
    v.id_base_visit
FROM gn_monitoring.t_base_visits v
JOIN gn_monitoring.t_base_sites s ON s.id_base_site = v.id_base_site
JOIN gn_commons.t_modules m ON m.id_module = v.id_module
JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = v.id_base_visit
LEFT JOIN counts c ON c.id_base_visit = v.id_base_visit
LEFT JOIN activities act ON act.id_base_visit = v.id_base_visit
LEFT JOIN observers obs ON obs.id_base_visit = v.id_base_visit
JOIN taxonomie.taxref t ON t.cd_nom = 2645 -- Aquila chrysaetos : espèce unique de ce protocole
JOIN source ON true
WHERE m.module_code = :module_code
  -- Ne remonter en synthèse que les visites qui témoignent réellement d'une présence :
  -- au moins une activité réelle (cf. CTE activities) ou un dénombrement strictement positif.
  AND (COALESCE(act.has_real_activity, false) OR c.total > 0);
