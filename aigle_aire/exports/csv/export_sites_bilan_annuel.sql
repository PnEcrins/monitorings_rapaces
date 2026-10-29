
CREATE OR REPLACE VIEW gn_monitoring.v_export_aigle_aire_sites_bilan_annuel
AS
WITH activite_categorie (cd_nomenclature, bilan) AS (
  VALUES
    ('JEUNE(S)_MORT(S)', 3),
    ('ŒUF(S)_ABANDONNÉ(S)', 3),
    ('ACCOUPLEMENT_SUR_L''AIRE', 2),
    ('APPORT_DE_PROIE_SUR_L''AIRE', 2),
    ('COUVAISON', 2),
    ('DÉPOT_DE_BRANCHE', 2),
    ('NOURRISSAGE', 2),
    ('RELÈVE_À_L''AIRE', 2),
    ('AIRE_VIDE', 1),
    ('AUCUNE_ACTIVITÉ_CONSTATÉE', 1),
    ('AUTRE_(VOIR_REMARQUES)', 1)
),
activite_type AS (
  SELECT id_type
  FROM ref_nomenclatures.bib_nomenclatures_types
  WHERE mnemonique = 'AIGLE_ACTIVITE_AIRE'
),
-- Bilan d'une visite : le plus élevé (3=Échec, 2=Activité, 1=Aucune
-- activité) des cd_nomenclature de la visite, 1 par défaut si elle n'a
-- aucune activité renseignée (tableau vide).
bilan_visit AS (
  SELECT
    bv.id_base_site,
    EXTRACT(YEAR FROM bv.visit_date_min)::integer AS annee,
    GREATEST(
      COALESCE((
        SELECT MAX(ac.bilan)
        FROM jsonb_array_elements_text(
          CASE WHEN jsonb_typeof(vc.data -> 'activite_aire') = 'array'
            THEN vc.data -> 'activite_aire'
            ELSE '[]'::jsonb
          END
        ) a(id_nomenclature)
          JOIN ref_nomenclatures.t_nomenclatures n
            ON n.id_nomenclature = a.id_nomenclature::integer
           AND n.id_type = (SELECT id_type FROM activite_type)
          JOIN activite_categorie ac ON ac.cd_nomenclature = n.cd_nomenclature
      ), 1),
      -- Un effectif renseigné et positif équivaut à "Activité noté sur l'aire",
      -- indépendamment de activite_aire.
      CASE WHEN COALESCE((vc.data ->> 'nb_adulte')::integer, 0) > 0
             OR COALESCE((vc.data ->> 'nb_jeune_noir')::integer, 0) > 0
             OR COALESCE((vc.data ->> 'nb_jeune_blanc')::integer, 0) > 0
             OR COALESCE((vc.data ->> 'nb_jeune_envole')::integer, 0) > 0
           THEN 2 ELSE 1 END
    ) AS bilan
  FROM gn_monitoring.t_base_visits bv
    JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
    JOIN gn_commons.t_modules m ON m.id_module = bv.id_module AND m.module_code = 'aigle_aire'
),
-- Bilan d'un site pour une année : le plus élevé des bilans de ses visites.
site_year_bilan AS (
  SELECT id_base_site, annee, MAX(bilan) AS bilan
  FROM bilan_visit
  GROUP BY id_base_site, annee
),
sites AS (
  SELECT
    s.id_base_site,
    s.base_site_name,
    s.base_site_code,
    st_asgeojson(s.geom) AS geom
  FROM gn_monitoring.t_base_sites s
  WHERE EXISTS (
    SELECT 1
    FROM gn_monitoring.cor_site_type cst
      JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
      JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_aire'
    WHERE cst.id_base_site = s.id_base_site
  )
),
-- Toutes les années couvertes par le module, de la première visite à
-- aujourd'hui (année courante incluse même sans visite).
annees AS (
  SELECT generate_series(
    COALESCE((SELECT MIN(annee) FROM bilan_visit), EXTRACT(YEAR FROM CURRENT_DATE)::integer),
    EXTRACT(YEAR FROM CURRENT_DATE)::integer
  ) AS annee
)
SELECT
  sites.id_base_site,
  sites.base_site_name,
  sites.base_site_code,
  sites.geom,
  annees.annee,
  CASE COALESCE(syb.bilan, 0)
    WHEN 3 THEN 'Échec'
    WHEN 2 THEN 'Activité noté sur l''aire'
    WHEN 1 THEN 'Aucune activité constatée'
    ELSE 'Aucune visite'
  END AS activite_aire
FROM sites
  CROSS JOIN annees
  LEFT JOIN site_year_bilan syb
    ON syb.id_base_site = sites.id_base_site AND syb.annee = annees.annee
;
