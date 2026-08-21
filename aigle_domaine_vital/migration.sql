
DROP TABLE IF EXISTS gn_monitoring.bib_correspondance_activite_statut_repro CASCADE;

CREATE TABLE gn_monitoring.bib_correspondance_activite_statut_repro (
  id_correspondance SERIAL PRIMARY KEY,
  cd_nomenclature_activite VARCHAR(255) NOT NULL,
  cd_nomenclature_statut_repro VARCHAR(255) NOT NULL
);

-- id_activite=0, statut_repro=1 (pas de conclusion possible)
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('AUCUNE_ACTIVITÉ_CONSTATÉE', '1');

-- id_activite=2, statut_repro=1
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('DÉPOT_DE_BRANCHE', '1');

-- id_activite=3, statut_repro=p1
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('ACCOUPLEMENT_SUR_L''AIRE', '1');

-- id_activite=6, statut_repro=1
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('APPORT_DE_PROIE_SUR_L''AIRE', '1');

-- id_activite=7, statut_repro=2 (reproduction en cours)
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('RELÈVE_À_L''AIRE', '2');

-- id_activite=8, statut_repro=2
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('COUVAISON', '2');

-- id_activite=9, statut_repro=2
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('NOURRISSAGE', '2');

-- id_activite=14, statut_repro=3 (1 jeune envolé)
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('1_JEUNE_ENVOLÉ', '3');

-- id_activite=15, statut_repro=4 (2 jeunes envolés)
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('2_JEUNES_ENVOLÉS', '4');

-- id_activite=16, statut_repro=9 (échec)
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('ŒUF(S)_ABANDONNÉ(S)', '9');

-- id_activite=17, statut_repro=9
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('JEUNE(S)_MORT(S)', '9');

-- id_activite=18, statut_repro=1
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('AIRE_VIDE', '1');

-- id_activite=50, statut_repro=1
INSERT INTO gn_monitoring.bib_correspondance_activite_statut_repro
  (cd_nomenclature_activite, cd_nomenclature_statut_repro)
VALUES ('AUTRE_(VOIR_REMARQUES)', '1');


-- ============================================================================
-- Trigger : à l'insertion d'un contrôle du module aigle (t_visit_complements
-- rattaché à un t_base_visits de module 'aigle'), calcule le statut de
-- reproduction induit par les activités cochées et les comptages de jeunes,
-- via gn_monitoring.bib_correspondance_activite_statut_repro, et crée une
-- nouvelle visite dans le module domaine vital (sur le site rattaché à
-- l'aire) avec data->>'statut_reproduction' renseigné en conséquence.
--
-- Le domaine vital d'une aire est lu dans t_site_complements.data->>
-- 'id_base_site_domaine_vital' (champ posé lors de la migration pr_aigle, cf.
-- aigle_aire/migration/migrate.py). Sans cette correspondance, rien n'est fait.
--
-- On ne crée une nouvelle visite que si le statut calculé pour ce contrôle est
-- strictement supérieur (au sens numérique des cd_nomenclature '0'..'9', qui
-- reprennent les anciens id_statut_repro pr_aigle) au meilleur statut déjà connu
-- pour ce domaine vital sur la même saison. Ex. : un statut "reproduction en
-- cours" déjà posé, puis des œufs abandonnés constatés sur l'aire -> "échec"
-- (9 > 2) est bien une nouvelle information, une visite est créée. À l'inverse,
-- un statut "1/2 jeune(s) envolé(s)" déjà posé, puis une nouvelle visite ne
-- notant que des activités de type "reproduction en cours" (2 < 3 ou 4) n'ajoute
-- rien : aucune visite n'est créée.
-- ============================================================================

CREATE OR REPLACE FUNCTION gn_monitoring.fct_trg_aigle_visit_statut_repro()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_id_module_aigle INTEGER;
  v_id_module_domaine_vital INTEGER;
  v_id_type_activite INTEGER;
  v_id_type_statut INTEGER;
  v_base_visit RECORD;
  v_id_base_site_domaine_vital INTEGER;
  v_year INTEGER;
  v_new_code INTEGER;
  v_current_max_code INTEGER;
  v_new_id_base_visit INTEGER;
  v_id_nomenclature INTEGER;
  v_label TEXT;
BEGIN
  SELECT id_module INTO v_id_module_aigle
    FROM gn_commons.t_modules WHERE module_code = 'aigle';
  SELECT id_module INTO v_id_module_domaine_vital
    FROM gn_commons.t_modules WHERE module_code = 'domaine_vital';

  SELECT id_base_site, id_module, id_dataset, id_digitiser, visit_date_min, visit_date_max
    INTO v_base_visit
    FROM gn_monitoring.t_base_visits
   WHERE id_base_visit = NEW.id_base_visit;

  IF v_base_visit.id_module IS DISTINCT FROM v_id_module_aigle THEN
    RETURN NEW;
  END IF;

  SELECT (sc.data ->> 'id_base_site_domaine_vital')::INTEGER
    INTO v_id_base_site_domaine_vital
    FROM gn_monitoring.t_site_complements sc
   WHERE sc.id_base_site = v_base_visit.id_base_site;

  IF v_id_base_site_domaine_vital IS NULL THEN
    RAISE NOTICE 'aigle visit % : aire (site %) sans domaine vital rattaché, statut de reproduction non calculé',
      NEW.id_base_visit, v_base_visit.id_base_site;
    RETURN NEW;
  END IF;

  SELECT id_type INTO v_id_type_activite
    FROM ref_nomenclatures.bib_nomenclatures_types WHERE mnemonique = 'AIGLE_ACTIVITE_AIRE';
  SELECT id_type INTO v_id_type_statut
    FROM ref_nomenclatures.bib_nomenclatures_types WHERE mnemonique = 'AIGLE_STATUT_REPRODUCTION';

  -- Statut le plus élevé induit par les activités cochées sur ce contrôle
  SELECT MAX(bc.cd_nomenclature_statut_repro::INTEGER)
    INTO v_new_code
    FROM jsonb_array_elements_text(
           CASE WHEN jsonb_typeof(NEW.data -> 'activite_aire') = 'array'
                THEN NEW.data -> 'activite_aire'
                ELSE '[]'::JSONB
           END
         ) AS a(id_nomenclature)
    JOIN ref_nomenclatures.t_nomenclatures n
      ON n.id_nomenclature = a.id_nomenclature::INTEGER AND n.id_type = v_id_type_activite
    JOIN gn_monitoring.bib_correspondance_activite_statut_repro bc
      ON bc.cd_nomenclature_activite = n.cd_nomenclature;

  -- nb_jeune_blanc / nb_jeune_noir ne sont plus des activités nomenclaturées mais
  -- des champs de comptage : leur présence (>0) équivaut à "reproduction en cours"
  IF COALESCE((NEW.data ->> 'nb_jeune_blanc')::INTEGER, 0) > 0
     OR COALESCE((NEW.data ->> 'nb_jeune_noir')::INTEGER, 0) > 0 THEN
    v_new_code := GREATEST(COALESCE(v_new_code, 0), 2);
  END IF;

  -- envolé(s) -> succès de la reproduction
  IF COALESCE((NEW.data ->> 'nb_jeune_envole')::INTEGER, 0) = 1 THEN
    v_new_code := GREATEST(COALESCE(v_new_code, 0), 3);
  ELSIF COALESCE((NEW.data ->> 'nb_jeune_envole')::INTEGER, 0) >= 2 THEN
    v_new_code := GREATEST(COALESCE(v_new_code, 0), 4);
  END IF;

  IF v_new_code IS NULL THEN
    RETURN NEW;
  END IF;

  v_year := EXTRACT(YEAR FROM v_base_visit.visit_date_min)::INTEGER;

  -- Meilleur statut déjà connu pour ce domaine vital sur la même saison
  SELECT MAX(n2.cd_nomenclature::INTEGER)
    INTO v_current_max_code
    FROM gn_monitoring.t_base_visits bv
    JOIN gn_monitoring.t_visit_complements vc ON vc.id_base_visit = bv.id_base_visit
    JOIN ref_nomenclatures.t_nomenclatures n2 ON n2.id_nomenclature = (vc.data ->> 'statut_reproduction')::INTEGER
   WHERE bv.id_base_site = v_id_base_site_domaine_vital
     AND bv.id_module = v_id_module_domaine_vital
     AND EXTRACT(YEAR FROM bv.visit_date_min)::INTEGER = v_year;

  IF v_current_max_code IS NOT NULL AND v_current_max_code >= v_new_code THEN
    RETURN NEW;
  END IF;

  SELECT id_nomenclature, label_default INTO v_id_nomenclature, v_label
    FROM ref_nomenclatures.t_nomenclatures
   WHERE id_type = v_id_type_statut AND cd_nomenclature = v_new_code::TEXT;

  INSERT INTO gn_monitoring.t_base_visits
    (id_base_site, id_dataset, id_module, id_digitiser, visit_date_min, visit_date_max, comments)
  VALUES
    (v_id_base_site_domaine_vital, v_base_visit.id_dataset, v_id_module_domaine_vital, v_base_visit.id_digitiser,
     v_base_visit.visit_date_min, v_base_visit.visit_date_max,
     'Visite automatique réalisée pour calculer le statut de reproduction à partir des activités notées sur les aires.')
  RETURNING id_base_visit INTO v_new_id_base_visit;

  INSERT INTO gn_monitoring.t_visit_complements (id_base_visit, data)
  VALUES (
    v_new_id_base_visit,
    jsonb_build_object(
      'comportement_domaine_vital', '[]'::JSONB,
      'statut_reproduction', v_id_nomenclature,
      '_label_statut_reproduction', v_label
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_aigle_visit_statut_repro ON gn_monitoring.t_visit_complements;

CREATE TRIGGER trg_aigle_visit_statut_repro
AFTER INSERT OR UPDATE ON gn_monitoring.t_visit_complements
FOR EACH ROW
EXECUTE FUNCTION gn_monitoring.fct_trg_aigle_visit_statut_repro();
