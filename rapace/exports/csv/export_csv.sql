-- Export des sites
CREATE OR REPLACE VIEW gn_monitoring.v_export_rapace_sites
AS
SELECT
  s.id_base_site AS id_site,
  s.base_site_name AS nom_site,
  s.base_site_code AS code_site,
  st_astext(s.geom) AS geom,
  ts.type_site,
  s.base_site_description AS description_site,
  s.first_use_date AS date_decouverte,
  a.jname ->> 'COM'::text AS commune,
  a.jname ->> 'SEC'::text AS secteur
FROM gn_monitoring.t_base_sites s
  JOIN gn_monitoring.cor_site_module csm ON csm.id_base_site = s.id_base_site
  JOIN gn_commons.t_modules mod ON mod.id_module = csm.id_module AND mod.module_code = 'rapace'
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT tn.label_default, ', ') AS type_site
    FROM gn_monitoring.cor_site_type cst
      JOIN ref_nomenclatures.t_nomenclatures tn ON tn.id_nomenclature = cst.id_type_site
    WHERE cst.id_base_site = s.id_base_site
  ) ts ON true
  LEFT JOIN LATERAL (
    SELECT json_object_agg(d_1.type_code, d_1.o_name) AS jname
    FROM (
      SELECT sa.id_base_site,
        ta.type_code,
        string_agg(DISTINCT a_1.area_name::text, ',') AS o_name
      FROM gn_monitoring.cor_site_area sa
        JOIN ref_geo.l_areas a_1 ON sa.id_area = a_1.id_area
        JOIN ref_geo.bib_areas_types ta ON ta.id_type = a_1.id_type
      WHERE sa.id_base_site = s.id_base_site
      GROUP BY sa.id_base_site, ta.type_code
    ) d_1
  ) a ON true
;

-- Export des visites
CREATE OR REPLACE VIEW gn_monitoring.v_export_rapace_visits
AS
WITH observers AS (
  SELECT
    cvo.id_base_visit,
    string_agg(concat(tr.nom_role, ' ', tr.prenom_role), ', '::text) AS observateurs
  FROM gn_monitoring.cor_visit_observer cvo
    JOIN utilisateurs.t_roles tr ON tr.id_role = cvo.id_role
  GROUP BY cvo.id_base_visit
),
activites AS (
  SELECT
    tvc.id_base_visit,
    string_agg(DISTINCT tn.label_default, ', ') AS activites
  FROM gn_monitoring.t_visit_complements tvc,
    jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(tvc.data -> 'activite_aire_rapaces') = 'array'
        THEN tvc.data -> 'activite_aire_rapaces'
        ELSE '[]'::jsonb
      END
    ) AS id_nomenclature_activite
    JOIN ref_nomenclatures.t_nomenclatures tn ON tn.id_nomenclature = id_nomenclature_activite::integer
  GROUP BY tvc.id_base_visit
)
SELECT
  s.id_base_site AS id_site,
  s.base_site_name AS nom_site,
  tbv.id_base_visit AS id_visite,
  tbv.visit_date_min AS date_visite,
  obs.observateurs,
  t.cd_nom,
  t.lb_nom AS tax_nom_scientifique,
  act.activites AS activite_aire,
  tn_statut.label_default AS statut_reproduction,
  tbv.comments AS commentaire,
  tbv.id_dataset
FROM gn_monitoring.t_base_visits tbv
  JOIN gn_monitoring.t_base_sites s ON s.id_base_site = tbv.id_base_site
  JOIN gn_commons.t_modules m ON m.id_module = tbv.id_module AND m.module_code = 'rapace'
  LEFT JOIN gn_monitoring.t_visit_complements tvc ON tvc.id_base_visit = tbv.id_base_visit
  LEFT JOIN observers obs ON obs.id_base_visit = tbv.id_base_visit
  LEFT JOIN activites act ON act.id_base_visit = tbv.id_base_visit
  LEFT JOIN taxonomie.taxref t ON t.cd_nom = (tvc.data ->> 'cd_nom')::integer
  LEFT JOIN ref_nomenclatures.t_nomenclatures tn_statut ON tn_statut.id_nomenclature = (tvc.data ->> 'statut_reproduction')::integer
;
