-- Export des domaines vitaux
CREATE OR REPLACE VIEW gn_monitoring.v_export_aigle_domaine_vital_sites
AS
SELECT
  s.id_base_site AS id_site,
  s.base_site_name AS nom_site,
  s.base_site_code AS code_domaine_vital,
  st_astext(s.geom) AS geom,
  s.base_site_description AS description_site,
  s.first_use_date AS date_decouverte,
  inv.nom_role AS nom_inventeur,
  inv.prenom_role AS prenom_inventeur,
  a.jname ->> 'SEC'::text AS secteur
FROM gn_monitoring.t_base_sites s
  LEFT JOIN utilisateurs.t_roles inv ON inv.id_role = s.id_inventor
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
WHERE EXISTS (
  -- Le lien site <-> module ne passe pas par cor_site_module (vide dans ce
  -- jeu de données) mais par le type de site : cor_site_type (site -> type)
  -- puis cor_module_type (type -> module), comme le fait TMonitoringSites.modules
  -- côté ORM (gn_module_monitoring/monitoring/models.py).
  SELECT 1
  FROM gn_monitoring.cor_site_type cst
    JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
    JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = :module_code
  WHERE cst.id_base_site = s.id_base_site
)
;

DROP VIEW IF EXISTS gn_monitoring.v_export_domaine_vital_visits;
CREATE OR REPLACE VIEW gn_monitoring.v_export_domaine_vital_visits
AS
SELECT s.id_base_site,
    s.base_site_name AS nom,
    tbv.id_base_visit,
    tbv.visit_date_min,
    EXTRACT(year FROM tbv.visit_date_min)::integer AS annee,
    m.module_code,
    concat(to_char(tbv.visit_date_min::timestamp with time zone, 'DD/MM/YYYY'::text), ' - ', obs.observateurs, ' - ', s.base_site_name) AS visite_label,
    obs.observateurs,
    (tvc.data ->> 'visit_duration'::text)::numeric AS "Durée visite",
    comp.comportements AS "Comportement(s)",
    (tvc.data ->> 'nb_jeune_seul'::text)::integer AS "Nb jeune seul",
    (tvc.data ->> 'nb_jeune_avec_adulte'::text)::integer AS "Nb jeune avec adulte",
    tn_statut.label_default AS "Statut de reproduction",
    tbv.comments AS commentaire,
    tbv.id_dataset
   FROM gn_monitoring.t_base_visits tbv
     JOIN gn_monitoring.t_base_sites s ON s.id_base_site = tbv.id_base_site
     JOIN gn_commons.t_modules m ON m.id_module = tbv.id_module AND m.module_code::text = 'domaine_vital'::text
     LEFT JOIN gn_monitoring.t_visit_complements tvc ON tvc.id_base_visit = tbv.id_base_visit
     LEFT JOIN ref_nomenclatures.t_nomenclatures tn_statut ON tn_statut.id_nomenclature = ((tvc.data ->> 'statut_reproduction'::text)::integer)
     LEFT JOIN LATERAL ( SELECT string_agg(concat(tr.nom_role, ' ', tr.prenom_role), ', '::text) AS observateurs
           FROM gn_monitoring.cor_visit_observer cvo
             JOIN utilisateurs.t_roles tr ON tr.id_role = cvo.id_role
          WHERE cvo.id_base_visit = tbv.id_base_visit) obs ON true
     LEFT JOIN LATERAL ( SELECT string_agg(DISTINCT tn.label_default::text, ', '::text) AS comportements
           FROM jsonb_array_elements_text(
                CASE
                    WHEN jsonb_typeof(tvc.data -> 'comportement_domaine_vital'::text) = 'array'::text THEN tvc.data -> 'comportement_domaine_vital'::text
                    ELSE '[]'::jsonb
                END) id_nomenclature_comportement(value)
             JOIN ref_nomenclatures.t_nomenclatures tn ON tn.id_nomenclature = id_nomenclature_comportement.value::integer) comp ON true
;