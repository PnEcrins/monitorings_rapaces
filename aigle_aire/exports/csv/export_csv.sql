-- Export des aires
CREATE OR REPLACE VIEW gn_monitoring.v_export_aigle_aire_sites
AS
SELECT
  s.id_base_site AS id_site,
  s.base_site_name AS nom_site,
  s.base_site_code AS numero_aire,
  st_astext(s.geom) AS geom,
  ts.type_site,
  tn_topo.label_default AS topologie,
  (tsc.data ->> 'altitude')::numeric AS altitude,
  (tsc.data ->> 'heigth')::numeric AS hauteur_falaise,
  tn_pos.label_default AS position_falaise,
  tn_orient.label_default AS orientation,
  tn_subst.label_default AS substrat,
  (tsc.data ->> 'id_base_site_domaine_vital')::integer AS id_base_site_domaine_vital,
  (tsc.data ->> 'valid')::boolean AS valide,
  s.base_site_description AS description_site,
  s.first_use_date AS date_decouverte,
  inv.nom_role AS nom_inventeur,
  inv.prenom_role AS prenom_inventeur,
  a.jname ->> 'COM'::text AS commune,
  a.jname ->> 'SEC'::text AS secteur
FROM gn_monitoring.t_base_sites s
  LEFT JOIN gn_monitoring.t_site_complements tsc ON tsc.id_base_site = s.id_base_site
  LEFT JOIN utilisateurs.t_roles inv ON inv.id_role = s.id_inventor
  LEFT JOIN ref_nomenclatures.t_nomenclatures tn_topo ON tn_topo.id_nomenclature = (tsc.data ->> 'id_nomenclature_topology')::integer
  LEFT JOIN ref_nomenclatures.t_nomenclatures tn_pos ON tn_pos.id_nomenclature = (tsc.data ->> 'id_nomenclature_position_cliff')::integer
  LEFT JOIN ref_nomenclatures.t_nomenclatures tn_orient ON tn_orient.id_nomenclature = (tsc.data ->> 'id_nomenclature_orientation')::integer
  LEFT JOIN ref_nomenclatures.t_nomenclatures tn_subst ON tn_subst.id_nomenclature = (tsc.data ->> 'id_nomenclature_substratum')::integer
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
 WHERE (EXISTS ( SELECT 1
           FROM gn_monitoring.cor_site_type cst
             JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
             JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code::text = 'domaine_vital'::text
          WHERE cst.id_base_site = s.id_base_site));
;

-- Export des contrôles
CREATE OR REPLACE VIEW gn_monitoring.v_export_aigle_visits
AS
SELECT
  s.id_base_site AS id_base_site,
  s.base_site_name AS nom_site,
  tbv.id_base_visit AS id_visite,
  tbv.visit_date_min AS date_visite,
  date_part('year', tbv.visit_date_min) as annee,
  obs.observateurs,
  concat(to_char(tbv.visit_date_min, 'DD/MM/YYYY'), ' - ', obs.observateurs) as label_visit,
  (tvc.data ->> 'visit_duration')::numeric AS "Durée visite",
  act.activites AS "Activité à l'aire",
  (tvc.data ->> 'nb_adulte')::integer AS "Nb adulte",
  (tvc.data ->> 'nb_jeune_blanc')::integer AS "Nb jeune blanc",
  (tvc.data ->> 'nb_jeune_noir')::integer AS "Nb jeune noir",
  (tvc.data ->> 'nb_jeune_envole')::integer AS "Nb jeune envolé",
  tbv.comments AS commentaire,
  tbv.id_dataset,
  a.jname ->> 'SEC'::text AS secteur,
  a.jname ->> 'COM'::text AS commune
FROM gn_monitoring.t_base_visits tbv
  JOIN gn_monitoring.t_base_sites s ON s.id_base_site = tbv.id_base_site
  JOIN gn_commons.t_modules m ON m.id_module = tbv.id_module AND m.module_code = 'aigle'
  LEFT JOIN gn_monitoring.t_visit_complements tvc ON tvc.id_base_visit = tbv.id_base_visit
  LEFT JOIN LATERAL (
    SELECT string_agg(concat(tr.nom_role, ' ', tr.prenom_role), ', ') AS observateurs
    FROM gn_monitoring.cor_visit_observer cvo
      JOIN utilisateurs.t_roles tr ON tr.id_role = cvo.id_role
    WHERE cvo.id_base_visit = tbv.id_base_visit
  ) obs ON true
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
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT tn.label_default, ', ') AS activites
    FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(tvc.data -> 'activite_aire') = 'array'
        THEN tvc.data -> 'activite_aire'
        ELSE '[]'::jsonb
      END
    ) id_nomenclature_activite
      JOIN ref_nomenclatures.t_nomenclatures tn ON tn.id_nomenclature = id_nomenclature_activite::integer
  ) act ON true
;
