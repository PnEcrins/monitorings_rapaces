
-- Bilan annuel du statut de reproduction de chaque aire de gypaète, utilisé
-- notamment par gn_module_monitoring_year_synthese (site_export_name =
-- "site_bilan").
--
-- Chaque site est croisé avec chaque année (CROSS JOIN sites x annees) afin
-- qu'un site apparaisse pour toutes les années même sans visite (ou sans
-- statut_reproduction renseigné) cette année-là — sans quoi il
-- disparaîtrait des résultats filtrés par ?annee=<année> (route d'export).
-- Le statut est alors NULL.
--
-- Le statut de reproduction d'une aire, pour une année donnée, est le
-- meilleur (cd_nomenclature le plus élevé) statut_reproduction renseigné sur
-- ses visites de l'année. Comme pour l'aigle, "pas de reproduction constatée"
-- (8) et "échec" (9) priment sur le succès (3) : un échec constaté après une
-- reproduction en cours/réussie l'emporte.

DROP VIEW IF EXISTS gn_monitoring.v_export_nidif_gypa_site_bilan;
CREATE OR REPLACE VIEW gn_monitoring.v_export_nidif_gypa_site_bilan
AS
WITH statut_nomenclature AS (
  SELECT n.id_nomenclature, n.cd_nomenclature, n.label_default
  FROM ref_nomenclatures.t_nomenclatures n
    JOIN ref_nomenclatures.bib_nomenclatures_types bnt ON bnt.id_type = n.id_type
  WHERE bnt.mnemonique = 'STATUT_REPRO_GYPA'
),
visit_status AS (
  SELECT
    bv.id_base_site,
    EXTRACT(YEAR FROM bv.visit_date_min)::integer AS annee,
    (vc.data ->> 'statut_reproduction')::integer AS id_nomenclature_statut_repro
  FROM gn_monitoring.t_base_visits bv
    JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
    JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code = 'nidif_gypa'
  WHERE (vc.data ->> 'statut_reproduction') IS NOT NULL
),
-- Statut le plus élevé (meilleur) parmi les visites d'une même aire et d'une
-- même année.
best_status AS (
  SELECT DISTINCT ON (vst.id_base_site, vst.annee)
    vst.id_base_site,
    vst.annee,
    sn.cd_nomenclature,
    sn.label_default
  FROM visit_status vst
    JOIN statut_nomenclature sn ON sn.id_nomenclature = vst.id_nomenclature_statut_repro
  ORDER BY vst.id_base_site, vst.annee, sn.cd_nomenclature::integer DESC
),
sites AS (
  SELECT
    s.id_base_site,
    s.base_site_name,
    s.base_site_description,
    s.id_inventor,
    s.geom
  FROM gn_monitoring.t_base_sites s
  WHERE EXISTS (
    -- Le lien site <-> module ne passe pas par cor_site_module mais par le
    -- type de site : cor_site_type (site -> type) puis cor_module_type
    -- (type -> module), comme le fait TMonitoringSites.modules côté ORM
    -- (gn_module_monitoring/monitoring/models.py).
    SELECT 1
    FROM gn_monitoring.cor_site_type cst
      JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
      JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'nidif_gypa'
    WHERE cst.id_base_site = s.id_base_site
  )
),
-- Toutes les années couvertes par le module, de la première visite à
-- aujourd'hui (année courante incluse même sans visite).
annees AS (
  SELECT generate_series(
    COALESCE(
      (SELECT MIN(EXTRACT(YEAR FROM bv.visit_date_min))::integer
       FROM gn_monitoring.t_base_visits bv
         JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code = 'nidif_gypa'),
      EXTRACT(YEAR FROM CURRENT_DATE)::integer
    ),
    EXTRACT(YEAR FROM CURRENT_DATE)::integer
  ) AS annee
)
SELECT
  sites.id_base_site,
  sites.base_site_name,
  sites.base_site_description AS description_aire,
  st_asgeojson(sites.geom) AS geom,
  a.jname ->> 'COM'::text AS commune,
  a.jname ->> 'SEC'::text AS secteur,
  annees.annee,
  concat(r.prenom_role, ' ', r.nom_role) AS "découvreur",
  bs.cd_nomenclature AS cd_statut_reproduction,
  bs.label_default AS statut_reproduction
FROM sites
  -- Un site × chaque année couverte, même sans visite cette année-là.
  CROSS JOIN annees
  LEFT JOIN best_status bs ON bs.id_base_site = sites.id_base_site AND bs.annee = annees.annee
  -- LEFT JOIN : un site sans inventeur (id_inventor NULL) ne doit pas
  -- disparaître de l'export.
  LEFT JOIN utilisateurs.t_roles r ON r.id_role = sites.id_inventor
  -- LEFT JOIN LATERAL : idem pour un site sans aucune cor_site_area.
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
