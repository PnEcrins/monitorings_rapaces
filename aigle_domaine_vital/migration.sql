
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


CREATE OR REPLACE FUNCTION gn_monitoring.fct_trg_maj_domaine_vital_aire()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_id_base_site INTEGER := NEW.id_base_site;
  v_geom geometry;
  v_id_base_site_domaine_vital INTEGER;
BEGIN
  -- Ne rien faire si le site concerné n'est pas une aire du module aigle.
  IF NOT EXISTS (
    SELECT 1
    FROM gn_monitoring.cor_site_type cst
      JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
      JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle'
    WHERE cst.id_base_site = v_id_base_site
  ) THEN
    RETURN NEW;
  END IF;

  SELECT geom INTO v_geom
    FROM gn_monitoring.t_base_sites
   WHERE id_base_site = v_id_base_site;

  -- Domaine vital (module domaine_vital) dont la géométrie contient celle
  -- de l'aire. En cas de chevauchement de plusieurs domaines vitaux, on ne
  -- garde que le premier trouvé.
  SELECT dv.id_base_site
    INTO v_id_base_site_domaine_vital
    FROM gn_monitoring.t_base_sites dv
    WHERE EXISTS (
      SELECT 1
      FROM gn_monitoring.cor_site_type cst
        JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
        JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'domaine_vital'
      WHERE cst.id_base_site = dv.id_base_site
    )
    AND ST_Contains(dv.geom, v_geom)
    LIMIT 1;

  INSERT INTO gn_monitoring.t_site_complements (id_base_site, data)
  VALUES (v_id_base_site, jsonb_build_object('id_base_site_domaine_vital', v_id_base_site_domaine_vital))
  ON CONFLICT (id_base_site)
  DO UPDATE SET data =
    COALESCE(gn_monitoring.t_site_complements.data, '{}'::jsonb)
    || jsonb_build_object('id_base_site_domaine_vital', v_id_base_site_domaine_vital);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cor_site_type_maj_domaine_vital_aire ON gn_monitoring.cor_site_type;
CREATE TRIGGER trg_cor_site_type_maj_domaine_vital_aire
AFTER INSERT ON gn_monitoring.cor_site_type
FOR EACH ROW
EXECUTE FUNCTION gn_monitoring.fct_trg_maj_domaine_vital_aire();

DROP TRIGGER IF EXISTS trg_site_geom_maj_domaine_vital_aire ON gn_monitoring.t_base_sites;
CREATE TRIGGER trg_site_geom_maj_domaine_vital_aire
AFTER UPDATE OF geom ON gn_monitoring.t_base_sites
FOR EACH ROW
EXECUTE FUNCTION gn_monitoring.fct_trg_maj_domaine_vital_aire();

