
-- Chaque site est croisé avec chaque année (CROSS JOIN sites x annees) afin
-- qu'un site apparaisse pour toutes les années même sans visite (ou sans
-- statut_reproduction renseigné) cette année-là — sans quoi il
-- disparaîtrait des résultats filtrés par ?annee=<année> (route d'export),
-- au lieu d'apparaître en "non suivi". "non suivi" (cd_nomenclature '0' de
-- AIGLE_STATUT_REPRODUCTION) est la valeur par défaut dans ce cas.
--
-- Le statut de reproduction d'un domaine vital, pour une année donnée, est
-- le meilleur (cd_nomenclature le plus élevé) entre :
--   - le statut_reproduction renseigné directement sur les visites du
--     domaine vital (CTE best_status) ;
--   - le statut induit par les visites du module aigle (aires) rattachées à
--     ce domaine vital via gn_monitoring.cor_aire_domaine_vital_year (CTE
--     aire_status), qui reprend la logique de l'ancien trigger
--     gn_monitoring.fct_trg_aigle_visit_statut_repro (supprimé) : activités
--     cochées (bib_correspondance_activite_statut_repro) + dénombrement de
--     jeunes (nb_jeune_blanc, nb_jeune_noir, nb_jeune_envole).
--
-- Un domaine vital pouvant changer de géométrie au fil du temps, sa
-- correspondance avec les aires (cor_aire_domaine_vital_year) et sa
-- géométrie exportée (cor_domaine_vitaux_year) sont toutes deux recherchées
-- "à la date" : la dernière ligne connue dont l'année est <= à l'année
-- concernée (ces deux tables n'ont pas forcément une ligne par année,
-- seulement quand ça change).

DROP VIEW IF EXISTS gn_monitoring.v_export_domaine_vital_repro_status;
CREATE OR REPLACE VIEW gn_monitoring.v_export_domaine_vital_repro_status
AS
WITH visit_status AS (
  SELECT
    bv.id_base_site,
    EXTRACT(YEAR FROM bv.visit_date_min)::integer AS annee,
    (vc.data ->> 'statut_reproduction')::integer AS id_nomenclature_statut_repro
  FROM gn_monitoring.t_base_visits bv
    JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
    JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code = 'domaine_vital'
  WHERE (vc.data ->> 'statut_reproduction') IS NOT NULL
),
-- Toutes les valeurs de la nomenclature de statut de reproduction, utilisée
-- aussi bien pour les visites de domaine vital que pour le statut déduit des
-- visites d'aire (cf. aire_visit_code).
statut_nomenclature AS (
  SELECT n.id_nomenclature, n.cd_nomenclature, n.label_default
  FROM ref_nomenclatures.t_nomenclatures n
    JOIN ref_nomenclatures.bib_nomenclatures_types bnt ON bnt.id_type = n.id_type
  WHERE bnt.mnemonique = 'AIGLE_STATUT_REPRODUCTION'
),
-- Statut le plus élevé (meilleur) parmi les visites de domaine vital d'un
-- même site et d'une même année.
best_status AS (
  SELECT DISTINCT ON (vst.id_base_site, vst.annee)
    vst.id_base_site,
    vst.annee,
    sn.cd_nomenclature::integer AS code
  FROM visit_status vst
    JOIN statut_nomenclature sn ON sn.id_nomenclature = vst.id_nomenclature_statut_repro
  ORDER BY vst.id_base_site, vst.annee, sn.cd_nomenclature::integer DESC
),
-- Statut induit par chaque visite du module aigle (aire), rattachée à son
-- domaine vital via id_base_site_domaine_vital.
aire_visit_code AS (
  SELECT
    dv.id_base_site_domaine_vital AS id_base_site,
    EXTRACT(YEAR FROM bv.visit_date_min)::integer AS annee,
    GREATEST(
      COALESCE(act.code, 0),
      -- nb_jeune_blanc / nb_jeune_noir ne sont pas des activités nomenclaturées
      -- mais des champs de comptage : leur présence (>0) équivaut à
      -- "reproduction en cours".
      CASE
        WHEN COALESCE((vc.data ->> 'nb_jeune_blanc')::integer, 0) > 0
          OR COALESCE((vc.data ->> 'nb_jeune_noir')::integer, 0) > 0 THEN 2
        ELSE 0
      END,
      -- envolé(s) -> succès de la reproduction.
      CASE
        WHEN COALESCE((vc.data ->> 'nb_jeune_envole')::integer, 0) >= 2 THEN 4
        WHEN COALESCE((vc.data ->> 'nb_jeune_envole')::integer, 0) = 1 THEN 3
        ELSE 0
      END
    ) AS code
  FROM gn_monitoring.t_base_visits bv
    JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code = 'aigle'
    JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
    -- Domaine vital rattaché à cette aire à la date de la visite : la
    -- dernière correspondance connue (cor_aire_domaine_vital_year) dont
    -- l'année est <= l'année de la visite. JOIN LATERAL (et non LEFT) pour
    -- exclure les visites d'une aire sans correspondance connue à cette date.
    JOIN LATERAL (
      SELECT cadvy.id_base_site_domaine_vital
      FROM gn_monitoring.cor_aire_domaine_vital_year cadvy
      WHERE cadvy.id_base_site_aire = bv.id_base_site
        AND cadvy.year <= EXTRACT(YEAR FROM bv.visit_date_min)::integer
      ORDER BY cadvy.year DESC, cadvy.id DESC
      LIMIT 1
    ) dv ON true
    -- Statut induit par les activités cochées sur ce contrôle.
    LEFT JOIN LATERAL (
      SELECT MAX(bc.cd_nomenclature_statut_repro::integer) AS code
      FROM jsonb_array_elements_text(
             CASE WHEN jsonb_typeof(vc.data -> 'activite_aire') = 'array'
                  THEN vc.data -> 'activite_aire'
                  ELSE '[]'::jsonb
             END
           ) AS act_id(id_nomenclature)
        JOIN ref_nomenclatures.t_nomenclatures n ON n.id_nomenclature = act_id.id_nomenclature::integer
        JOIN gn_monitoring.bib_correspondance_activite_statut_repro bc
          ON bc.cd_nomenclature_activite = n.cd_nomenclature
    ) act ON true
),
-- Statut le plus élevé parmi les visites d'aire d'un même domaine vital et
-- d'une même année (0 = aucune visite d'aire exploitable pour cette année).
aire_status AS (
  SELECT id_base_site, annee, MAX(code) AS code
  FROM aire_visit_code
  WHERE code > 0
  GROUP BY id_base_site, annee
),
sites AS (
  SELECT
    s.id_base_site,
    s.id_inventor,
    s.base_site_name,
    s.base_site_code,
    s.first_use_date
  FROM gn_monitoring.t_base_sites s
  WHERE EXISTS (
    -- Le lien site <-> module ne passe pas par cor_site_module (vide dans ce
    -- jeu de données) mais par le type de site : cor_site_type (site -> type)
    -- puis cor_module_type (type -> module), comme le fait TMonitoringSites.modules
    -- côté ORM (gn_module_monitoring/monitoring/models.py). EXISTS plutôt qu'un
    -- JOIN pour ne pas dupliquer le site si plusieurs types renvoient au module.
    SELECT 1
    FROM gn_monitoring.cor_site_type cst
      JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
      JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'domaine_vital'
    WHERE cst.id_base_site = s.id_base_site
  )
),
-- Toutes les années couvertes par le module, de la première visite (domaine
-- vital ou aire) à aujourd'hui (année courante incluse même sans visite).
annees AS (
  SELECT generate_series(
    LEAST(
      COALESCE((SELECT MIN(annee) FROM visit_status), EXTRACT(YEAR FROM CURRENT_DATE)::integer),
      COALESCE((SELECT MIN(annee) FROM aire_visit_code), EXTRACT(YEAR FROM CURRENT_DATE)::integer)
    ),
    EXTRACT(YEAR FROM CURRENT_DATE)::integer
  ) AS annee
),
statut_calcule AS (
  SELECT
    sites.id_base_site,
    annees.annee,
    GREATEST(COALESCE(bs.code, 0), COALESCE(air.code, 0)) AS code
  FROM sites
    CROSS JOIN annees
    LEFT JOIN best_status bs ON bs.id_base_site = sites.id_base_site AND bs.annee = annees.annee
    LEFT JOIN aire_status air ON air.id_base_site = sites.id_base_site AND air.annee = annees.annee
)
SELECT
  sites.id_base_site,
  sites.base_site_name,
  sites.base_site_code,
  st_asgeojson(g.geom) AS geom,
  a.jname ->> 'SEC'::text AS secteur,
  sc.annee,
  sites.first_use_date as "date_découverte",
  concat(r.prenom_role, ' ', r.nom_role) as "découvreur",
  sn.cd_nomenclature AS cd_statut_reproduction,
  sn.label_default AS "Statut_reproduction"
FROM statut_calcule sc
  JOIN sites ON sites.id_base_site = sc.id_base_site
  JOIN statut_nomenclature sn ON sn.cd_nomenclature = sc.code::text
  -- Géométrie du domaine vital pour l'année exportée : la dernière géométrie
  -- connue (cor_domaine_vitaux_year) dont l'année est <= sc.annee. Si la
  -- géométrie n'a pas changé cette année-là (pas de ligne pour sc.annee), on
  -- retombe automatiquement sur celle de la dernière année où elle a changé.
  -- g.geom n'est NULL que pour une année antérieure à toute géométrie connue
  -- (domaine vital pas encore créé à cette date).
  LEFT JOIN LATERAL (
    SELECT cdvy.geom
    FROM gn_monitoring.cor_domaine_vitaux_year cdvy
    WHERE cdvy.id_base_site = sites.id_base_site
      AND cdvy.year <= sc.annee
    ORDER BY cdvy.year DESC, cdvy.id DESC
    LIMIT 1
  ) g ON true
  -- LEFT JOIN : un site sans inventeur (id_inventor NULL) ne doit pas
  -- disparaître de l'export.
  LEFT JOIN utilisateurs.t_roles r ON r.id_role = sites.id_inventor
  -- LEFT JOIN LATERAL : idem pour un site sans aucune cor_site_area, sinon
  -- le sous-select (agrégat sur 0 ligne) ne renvoie aucune ligne et le site
  -- disparaît entièrement du résultat.
  LEFT JOIN LATERAL ( SELECT d_1.id_base_site,
        json_object_agg(d_1.type_code, d_1.o_name) AS jname
        FROM ( SELECT sa.id_base_site,
                ta.type_code,
                string_agg(DISTINCT a_1.area_name::text, ','::text) AS o_name
                FROM gn_monitoring.cor_site_area sa
                  JOIN ref_geo.l_areas a_1 ON sa.id_area = a_1.id_area
                  JOIN ref_geo.bib_areas_types ta ON ta.id_type = a_1.id_type
              WHERE sa.id_base_site = sites.id_base_site
              GROUP BY sa.id_base_site, ta.type_code) d_1
      GROUP BY d_1.id_base_site) a ON true
;
