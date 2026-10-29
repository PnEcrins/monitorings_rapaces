
WITH comportement_mapping (comportement, cd_nomenclature) AS (
  VALUES
    -- cd_nomenclature de STATUT_REPRO_GYPA : 3 = succès, 2 = reproduction en
    -- cours, 1 = pas de conclusion possible
    ('Jeune envolé', '3'),
    ('Accouplement', '2'),
    ('Couvaison', '2'),
    ('Jeune au nid', '2'),
    ('Aire vide', '1'),
    ('Posé', '1'),
    ('Tandem', '1'),
    ('Territorial', '1')
),
visit_comportements AS (
  SELECT
    vc.id_base_visit,
    jsonb_array_elements_text(oc.data -> 'comportement') AS comportement
  FROM gn_monitoring.t_visit_complements vc
  JOIN gn_monitoring.t_base_visits v ON v.id_base_visit = vc.id_base_visit
  JOIN gn_monitoring.t_observations o ON o.id_base_visit = vc.id_base_visit
  JOIN gn_monitoring.t_observation_complements oc ON oc.id_observation = o.id_observation
  WHERE v.id_module = (SELECT id_module FROM gn_commons.t_modules WHERE module_code = 'nidif_gypa')
    AND jsonb_typeof(oc.data -> 'comportement') = 'array'
),
visit_status AS (
  -- une ligne par visite : le statut le plus élevé parmi ses comportements
  SELECT DISTINCT ON (vco.id_base_visit)
    vco.id_base_visit,
    cm.cd_nomenclature
  FROM visit_comportements vco
  JOIN comportement_mapping cm ON cm.comportement = vco.comportement
  ORDER BY vco.id_base_visit, cm.cd_nomenclature::integer DESC
)
UPDATE gn_monitoring.t_visit_complements vc
SET data = vc.data
  || jsonb_build_object('statut_reproduction', n.id_nomenclature)
  || jsonb_build_object('_label_statut_reproduction', n.label_default)
FROM visit_status vs
JOIN ref_nomenclatures.t_nomenclatures n
  ON n.cd_nomenclature = vs.cd_nomenclature
 AND n.id_type = (
      SELECT id_type FROM ref_nomenclatures.bib_nomenclatures_types
      WHERE mnemonique = 'STATUT_REPRO_GYPA'
    )
WHERE vc.id_base_visit = vs.id_base_visit
  AND EXISTS (
    SELECT 1 FROM gn_monitoring.t_base_visits v
    WHERE v.id_base_visit = vc.id_base_visit
      AND v.id_module = (SELECT id_module FROM gn_commons.t_modules WHERE module_code = 'nidif_gypa')
  )
  AND (vc.data ->> 'statut_reproduction') IS NULL;
