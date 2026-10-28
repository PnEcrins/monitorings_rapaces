-- gn_monitoring.v_export_rapaces_activite_aire source
drop VIEW gn_monitoring.v_export_rapace_activite_aire;
CREATE OR REPLACE VIEW gn_monitoring.v_export_rapace_activite_aire
AS WITH sites AS (
         SELECT DISTINCT s.id_base_site,
            mod.module_code,
            s.base_site_name,
            s.base_site_code,
            st_asgeojson(s.geom) AS geom
           FROM gn_monitoring.t_base_sites s
             JOIN gn_monitoring.cor_site_type cst ON cst.id_base_site = s.id_base_site
             JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
             JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module
          WHERE mod.module_code::text = ANY (ARRAY['aigle_aire'::character varying, 'nidif_gypa'::character varying, 'rapace'::character varying]::text[])
        ), aigle_activite_type AS (
         SELECT bib_nomenclatures_types.id_type
           FROM ref_nomenclatures.bib_nomenclatures_types
          WHERE bib_nomenclatures_types.mnemonique::text = 'AIGLE_ACTIVITE_AIRE'::text
        ), aigle_visit_activite AS (
         SELECT bv.id_base_site,
            EXTRACT(year FROM bv.visit_date_min)::integer AS annee,
            bool_or((EXISTS ( SELECT 1
                   FROM jsonb_array_elements_text(
                        CASE
                            WHEN jsonb_typeof(vc.data -> 'activite_aire'::text) = 'array'::text THEN vc.data -> 'activite_aire'::text
                            ELSE '[]'::jsonb
                        END) act(id_nomenclature)
                     JOIN ref_nomenclatures.t_nomenclatures n ON n.id_nomenclature = act.id_nomenclature::integer AND n.id_type = (( SELECT aigle_activite_type.id_type
                           FROM aigle_activite_type))
                  WHERE n.cd_nomenclature::text <> ALL (ARRAY['AIRE_VIDE'::character varying, 'AUCUNE_ACTIVITÉ_CONSTATÉE'::character varying, 'AUTRE_(VOIR_REMARQUES)'::character varying]::text[]))) OR COALESCE((vc.data ->> 'nb_adulte'::text)::integer, 0) > 0 OR COALESCE((vc.data ->> 'nb_jeune_blanc'::text)::integer, 0) > 0 OR COALESCE((vc.data ->> 'nb_jeune_noir'::text)::integer, 0) > 0 OR COALESCE((vc.data ->> 'nb_jeune_envole'::text)::integer, 0) > 0) AS activite_aire
           FROM gn_monitoring.t_base_visits bv
             JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code::text = 'aigle_aire'::text
             JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
          GROUP BY bv.id_base_site, (EXTRACT(year FROM bv.visit_date_min)::integer)
        ), gypa_status_type AS (
         SELECT bib_nomenclatures_types.id_type
           FROM ref_nomenclatures.bib_nomenclatures_types
          WHERE bib_nomenclatures_types.mnemonique::text = 'STATUT_REPRO_GYPA'::text
        ), gypa_visit_activite AS (
         SELECT bv.id_base_site,
            EXTRACT(year FROM bv.visit_date_min)::integer AS annee,
            bool_or(n.cd_nomenclature IS NOT NULL AND n.cd_nomenclature::text <> 'AUCUNE_ACTIVITÉ_CONSTATÉE'::text OR (EXISTS ( SELECT 1
                   FROM gn_monitoring.t_observations obs
                     JOIN taxonomie.taxref t ON t.cd_nom = obs.cd_nom
                  WHERE obs.id_base_visit = bv.id_base_visit AND t.cd_ref = 2852))) AS activite_aire
           FROM gn_monitoring.t_base_visits bv
             JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code::text = 'nidif_gypa'::text
             JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
             LEFT JOIN ref_nomenclatures.t_nomenclatures n ON n.id_nomenclature = ((vc.data ->> 'statut_reproduction'::text)::integer) AND n.id_type = (( SELECT gypa_status_type.id_type
                   FROM gypa_status_type))
          GROUP BY bv.id_base_site, (EXTRACT(year FROM bv.visit_date_min)::integer)
        ), rapace_status_type AS (
         SELECT bib_nomenclatures_types.id_type
           FROM ref_nomenclatures.bib_nomenclatures_types
          WHERE bib_nomenclatures_types.mnemonique::text = 'RAPACE_STATUT_REPRODUCTION'::text
        ), rapace_activite_type AS (
         SELECT bib_nomenclatures_types.id_type
           FROM ref_nomenclatures.bib_nomenclatures_types
          WHERE bib_nomenclatures_types.mnemonique::text = 'ACTIVITE_AIRE_RAPACES'::text
        ), rapace_visit_activite AS (
         SELECT bv.id_base_site,
            EXTRACT(year FROM bv.visit_date_min)::integer AS annee,
            bool_or(n.cd_nomenclature IS NOT NULL AND n.cd_nomenclature::text <> 'PAS_DE_REPRODUCTION_CONSTATÉE'::text OR (EXISTS ( SELECT 1
                   FROM jsonb_array_elements_text(
                        CASE
                            WHEN jsonb_typeof(vc.data -> 'activite_aire_rapaces'::text) = 'array'::text THEN vc.data -> 'activite_aire_rapaces'::text
                            ELSE '[]'::jsonb
                        END) act(id_nomenclature)
                     JOIN ref_nomenclatures.t_nomenclatures na ON na.id_nomenclature = act.id_nomenclature::integer AND na.id_type = (( SELECT rapace_activite_type.id_type
                           FROM rapace_activite_type))
                  WHERE na.cd_nomenclature::text <> ALL (ARRAY['AIRE_VIDE'::character varying, 'NON_RENSEIGNÉ'::character varying]::text[])))) AS activite_aire
           FROM gn_monitoring.t_base_visits bv
             JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code::text = 'rapace'::text
             JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
             LEFT JOIN ref_nomenclatures.t_nomenclatures n ON n.id_nomenclature = ((vc.data ->> 'statut_reproduction'::text)::integer) AND n.id_type = (( SELECT rapace_status_type.id_type
                   FROM rapace_status_type))
          GROUP BY bv.id_base_site, (EXTRACT(year FROM bv.visit_date_min)::integer)
        ), visit_activite AS (
         SELECT aigle_visit_activite.id_base_site,
            aigle_visit_activite.annee,
            aigle_visit_activite.activite_aire
           FROM aigle_visit_activite
        UNION ALL
         SELECT gypa_visit_activite.id_base_site,
            gypa_visit_activite.annee,
            gypa_visit_activite.activite_aire
           FROM gypa_visit_activite
        UNION ALL
         SELECT rapace_visit_activite.id_base_site,
            rapace_visit_activite.annee,
            rapace_visit_activite.activite_aire
           FROM rapace_visit_activite
        ), annees AS (
         SELECT generate_series(COALESCE(( SELECT min(visit_activite.annee) AS min
                   FROM visit_activite), EXTRACT(year FROM CURRENT_DATE)::integer), EXTRACT(year FROM CURRENT_DATE)::integer) AS annee
        )
 SELECT sites.id_base_site,
    sites.module_code,
    concat(sites.base_site_name, ' (' , sites.module_code, ')') as base_site_name ,
    sites.base_site_code,
    sites.geom,
    a.jname ->> 'COM'::text AS commune,
    a.jname ->> 'SEC'::text AS secteur,
    annees.annee,
    COALESCE(va.activite_aire, false) AS _activite_aire
   FROM sites
     CROSS JOIN annees
     LEFT JOIN visit_activite va ON va.id_base_site = sites.id_base_site AND va.annee = annees.annee
     LEFT JOIN LATERAL ( SELECT json_object_agg(d_1.type_code, d_1.o_name) AS jname
           FROM ( SELECT sa.id_base_site,
                    ta.type_code,
                    string_agg(DISTINCT a_1.area_name::text, ','::text) AS o_name
                   FROM gn_monitoring.cor_site_area sa
                     JOIN ref_geo.l_areas a_1 ON sa.id_area = a_1.id_area
                     JOIN ref_geo.bib_areas_types ta ON ta.id_type = a_1.id_type
                  WHERE sa.id_base_site = sites.id_base_site
                  GROUP BY sa.id_base_site, ta.type_code) d_1) a ON true;




