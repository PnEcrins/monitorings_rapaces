-- Visites d'une aire de gypaète, utilisée par gn_module_monitoring_year_synthese
-- (visit_export_name = "site_visit") pour le panneau de détail des visites.
DROP VIEW IF EXISTS gn_monitoring.v_export_nidif_gypa_visit;
CREATE OR REPLACE VIEW gn_monitoring.v_export_nidif_gypa_site_visit
AS
SELECT s.id_base_site,
    s.base_site_name AS nom,
    tbv.id_base_visit,
    tbv.visit_date_min,
    EXTRACT(year FROM tbv.visit_date_min)::integer AS annee,
    m.module_code,
    concat(to_char(tbv.visit_date_min::timestamp with time zone, 'DD/MM/YYYY'::text), ' - ', obs.observateurs, ' - ', s.base_site_name) AS visite_label,
    obs.observateurs,
    (tvc.data ->> 'obs_txt'::text) AS "Observateur(s) hors PNE",
    (tvc.data ->> 'hour_min'::text) AS "Heure début",
    (tvc.data ->> 'hour_max'::text) AS "Heure fin",
    (tvc.data ->> 'visibility'::text) AS "Visibilité",
    (tvc.data ->> 'etat_aire'::text) AS "Etat de l'aire",
    nb_obs.nb_observations AS "Nb observations",
    tn_statut.label_default AS "Statut de reproduction",
    tbv.comments AS commentaire,
    tbv.id_dataset
   FROM gn_monitoring.t_base_visits tbv
     JOIN gn_monitoring.t_base_sites s ON s.id_base_site = tbv.id_base_site
     JOIN gn_commons.t_modules m ON m.id_module = tbv.id_module AND m.module_code::text = 'nidif_gypa'::text
     LEFT JOIN gn_monitoring.t_visit_complements tvc ON tvc.id_base_visit = tbv.id_base_visit
     LEFT JOIN ref_nomenclatures.t_nomenclatures tn_statut ON tn_statut.id_nomenclature = ((tvc.data ->> 'statut_reproduction'::text)::integer)
     LEFT JOIN LATERAL ( SELECT string_agg(concat(tr.nom_role, ' ', tr.prenom_role), ', '::text) AS observateurs
           FROM gn_monitoring.cor_visit_observer cvo
             JOIN utilisateurs.t_roles tr ON tr.id_role = cvo.id_role
          WHERE cvo.id_base_visit = tbv.id_base_visit) obs ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS nb_observations
           FROM gn_monitoring.t_observations o
          WHERE o.id_base_visit = tbv.id_base_visit) nb_obs ON true
;
