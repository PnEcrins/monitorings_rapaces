
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





INSERT INTO gn_monitoring.cor_module_type(id_type_site, id_module) 
SELECT 
ref_nomenclatures.get_id_nomenclature(v.type_nomenc_mnemonique, v.cd_nomnclature),
m.id_module
FROM (
  VALUES ('aigle_aire', 'TYPE_SITE', 'AIRE_AIGLE' ),
   ('aigle_domaine_vital', 'TYPE_SITE', 'DOMAINE_VITAL' ),
   ('nidif_gypa', 'TYPE_SITE', 'AIRE_GYPA' ),
   ('rapace', 'TYPE_SITE', 'AIRE_RAPACE' )
) AS v ( module_code, type_nomenc_mnemonique, cd_nomnclature)
JOIN gn_commons.t_modules m ON m.module_code = v.module_code
ON CONFLICT (id_type_site, id_module) DO NOTHING;



-- table de correspondance entre un domaine vital, sa géométrie et une année
-- sert à conserver l'historique de modification des géométrie
CREATE TABLE gn_monitoring.cor_domaine_vitaux_year (
  id serial PRIMARY KEY,
  id_base_site integer NOT NULL,
  year integer NOT NULL,
  geom public.geometry(geometry, 4326) NOT NULL,
  CONSTRAINT fk_cor_domaine_vitaux_year_id_base_site FOREIGN KEY (id_base_site) REFERENCES gn_monitoring.t_base_sites(id_base_site) ON DELETE NO ACTION ON UPDATE CASCADE
);

-- Remplissage à partir de pr_aigle.t_territoires : pour chaque site de type
-- domaine_vital (gn_monitoring.t_base_sites), on retrouve tous ses anciens
-- id_territoire (gn_monitoring.t_site_complements.data->'old_ids_territoire')
-- et on récupère l'année et la géométrie (reprojetée en 4326) de chacun.
INSERT INTO gn_monitoring.cor_domaine_vitaux_year (id_base_site, year, geom)
SELECT
  tsc.id_base_site,
  ter.annee,
  ST_Transform(ter.the_geom, 4326) AS geom
FROM gn_monitoring.t_site_complements tsc
JOIN gn_monitoring.cor_site_type cst ON cst.id_base_site = tsc.id_base_site
JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_domaine_vital'
CROSS JOIN LATERAL jsonb_array_elements_text(tsc.data -> 'old_ids_territoire') AS old_id(id_territoire)
JOIN pr_aigle.t_territoires ter ON ter.id_territoire = old_id.id_territoire::integer
WHERE tsc.data ? 'old_ids_territoire';


-- Ajoute une ligne (avec l'année civile courante) à l'historique des
-- géométries d'un domaine vital, seulement si elle diffère de la dernière
-- géométrie connue pour ce domaine vital.
CREATE OR REPLACE FUNCTION gn_monitoring.fct_maj_cor_domaine_vitaux_year(
  p_id_base_site integer,
  p_geom geometry
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_year integer := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
  v_last_geom geometry;
BEGIN
  SELECT cdvy.geom
    INTO v_last_geom
    FROM gn_monitoring.cor_domaine_vitaux_year cdvy
    WHERE cdvy.id_base_site = p_id_base_site
    ORDER BY cdvy.year DESC, cdvy.id DESC
    LIMIT 1;

  IF v_last_geom IS NULL OR NOT ST_Equals(v_last_geom, p_geom) THEN
    -- Une ligne pour ce domaine vital existe peut-être déjà pour l'année
    -- courante (ex: la géométrie a déjà changé une première fois cette
    -- année) : elle est remplacée, pas cumulée.
    DELETE FROM gn_monitoring.cor_domaine_vitaux_year
    WHERE id_base_site = p_id_base_site
      AND year = v_year;

    INSERT INTO gn_monitoring.cor_domaine_vitaux_year (id_base_site, year, geom)
    VALUES (p_id_base_site, v_year, p_geom);
  END IF;
END;
$$;


-- table de correspondance entre les domaines vitaux et les aires par année
-- sert à conservé l'historique d'assocation d'une aire à un domaine vital
CREATE TABLE gn_monitoring.cor_aire_domaine_vital_year (
  id serial PRIMARY KEY,
  id_base_site_domaine_vital integer NOT NULL
    REFERENCES gn_monitoring.t_base_sites(id_base_site) ON DELETE NO ACTION ON UPDATE CASCADE,
  id_base_site_aire integer NOT NULL
    REFERENCES gn_monitoring.t_base_sites(id_base_site) ON DELETE NO ACTION ON UPDATE CASCADE,
  year integer NOT NULL,
  UNIQUE (id_base_site_aire, id_base_site_domaine_vital, year)
);

CREATE INDEX ON gn_monitoring.cor_aire_domaine_vital_year (id_base_site_aire, year DESC, id DESC);




-- Remplissage historique de gn_monitoring.cor_aire_domaine_vital_year
DO $$
DECLARE
  rec RECORD;
  v_id_aire integer;
  v_last_id_base_site_domaine_vital integer;
BEGIN
  FOR rec IN
    SELECT id_base_site, year, geom
    FROM gn_monitoring.cor_domaine_vitaux_year
    ORDER BY year ASC, id ASC
  LOOP
    FOR v_id_aire IN
      SELECT a.id_base_site
      FROM gn_monitoring.t_base_sites a
      WHERE EXISTS (
        SELECT 1
        FROM gn_monitoring.cor_site_type cst
          JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
          JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_aire'
        WHERE cst.id_base_site = a.id_base_site
      )
      AND ST_Contains(rec.geom, a.geom)
    LOOP
      SELECT cadvy.id_base_site_domaine_vital
        INTO v_last_id_base_site_domaine_vital
        FROM gn_monitoring.cor_aire_domaine_vital_year cadvy
        WHERE cadvy.id_base_site_aire = v_id_aire
        ORDER BY cadvy.year DESC, cadvy.id DESC
        LIMIT 1;

      IF v_last_id_base_site_domaine_vital IS DISTINCT FROM rec.id_base_site THEN
        INSERT INTO gn_monitoring.cor_aire_domaine_vital_year
          (id_base_site_domaine_vital, id_base_site_aire, year)
        VALUES (rec.id_base_site, v_id_aire, rec.year)
        ON CONFLICT (id_base_site_aire, id_base_site_domaine_vital, year) DO NOTHING;
      END IF;
    END LOOP;
  END LOOP;
END $$;


-- Ajoute une ligne (avec l'année civile courante) dans cor_aire_domaine_vital_year pour la paire
-- (domaine vital, aire) seulement si elle diffère de la dernière
-- correspondance connue de cette aire. U
CREATE OR REPLACE FUNCTION gn_monitoring.fct_maj_cor_aire_domaine_vital_year(
  p_id_base_site_domaine_vital integer,
  p_id_base_site_aire integer
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_year integer := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
  v_last_id_base_site_domaine_vital integer;
BEGIN
  IF p_id_base_site_domaine_vital IS NULL THEN
    RETURN;
  END IF;

  SELECT cadvy.id_base_site_domaine_vital
    INTO v_last_id_base_site_domaine_vital
    FROM gn_monitoring.cor_aire_domaine_vital_year cadvy
    WHERE cadvy.id_base_site_aire = p_id_base_site_aire
    ORDER BY cadvy.year DESC, cadvy.id DESC
    LIMIT 1;

  IF v_last_id_base_site_domaine_vital IS DISTINCT FROM p_id_base_site_domaine_vital THEN
    -- Une ligne pour cette aire existe peut-être déjà pour l'année courante
    -- (ex: l'aire a déjà changé de domaine vital une première fois cette
    -- année) : elle est remplacée, pas cumulée.
    DELETE FROM gn_monitoring.cor_aire_domaine_vital_year
    WHERE id_base_site_aire = p_id_base_site_aire
      AND year = v_year;

    INSERT INTO gn_monitoring.cor_aire_domaine_vital_year
      (id_base_site_domaine_vital, id_base_site_aire, year)
    VALUES (p_id_base_site_domaine_vital, p_id_base_site_aire, v_year);
  END IF;
END;
$$;



----------------------
----------------
-- TRIGGERS

-- Cas 1 : la géométrie d'un domaine vital change (ou le site vient d'être
-- créé/typé) -> on historise sa géométrie et on met à jour toutes les
-- aires désormais contenues dedans.
CREATE OR REPLACE FUNCTION gn_monitoring.fct_trg_maj_cor_aire_domaine_vital_year()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_id_base_site_domaine_vital integer := NEW.id_base_site;
  v_geom geometry;
  v_id_aire integer;
  v_id_base_site_chevauchant integer;
BEGIN
  -- Ne rien faire si le site concerné n'est pas un domaine vital. Utilisable
  -- aussi bien depuis un trigger sur t_base_sites (INSERT/UPDATE de geom) que
  -- sur cor_site_type (INSERT) : au moment où un site est créé, la ligne
  -- t_base_sites existe déjà mais pas encore cor_site_type 
  IF NOT EXISTS (
    SELECT 1
    FROM gn_monitoring.cor_site_type cst
      JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
      JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_domaine_vital'
    WHERE cst.id_base_site = v_id_base_site_domaine_vital
  ) THEN
    RETURN NEW;
  END IF;

  SELECT geom INTO v_geom
    FROM gn_monitoring.t_base_sites
   WHERE id_base_site = v_id_base_site_domaine_vital;

  -- Deux domaines vitaux ne doivent jamais se chevaucher.
  SELECT dv.id_base_site
    INTO v_id_base_site_chevauchant
    FROM gn_monitoring.t_base_sites dv
    WHERE dv.id_base_site <> v_id_base_site_domaine_vital
      AND EXISTS (
        SELECT 1
        FROM gn_monitoring.cor_site_type cst
          JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
          JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_domaine_vital'
        WHERE cst.id_base_site = dv.id_base_site
      )
      AND ST_Overlaps(dv.geom, v_geom)
    LIMIT 1;

  IF v_id_base_site_chevauchant IS NOT NULL THEN
    RAISE EXCEPTION 'Le domaine vital % chevauche le domaine vital % : géométries incompatibles.',
      v_id_base_site_domaine_vital, v_id_base_site_chevauchant;
  END IF;

   -- ajout d'une ligne pou l'année courante dans gn_monitoring.cor_domaine_vitaux_year
  PERFORM gn_monitoring.fct_maj_cor_domaine_vitaux_year(v_id_base_site_domaine_vital, v_geom);

  -- Pour chaque aire désormais contenue dans ce domaine vital, on n'ajoute une
  -- nouvelle ligne que si sa dernière correspondance connue pointait vers un
  -- autre domaine vital (ou n'existait pas encore) : pas de ligne systématique
  -- par année, seulement quand la correspondance change réellement.
  FOR v_id_aire IN
    SELECT a.id_base_site
    FROM gn_monitoring.t_base_sites a
    WHERE EXISTS (
      SELECT 1
      FROM gn_monitoring.cor_site_type cst
        JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
        JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_aire'
      WHERE cst.id_base_site = a.id_base_site
    )
    AND ST_Contains(v_geom, a.geom)
  LOOP
    PERFORM gn_monitoring.fct_maj_cor_aire_domaine_vital_year(v_id_base_site_domaine_vital, v_id_aire);
  END LOOP;

  RETURN NEW;
END;
$$;

-- Pas de INSERT ici : à la création d'un site, cor_site_type n'existe pas
-- encore (INSERT séparé et postérieur dans la même transaction), la fonction
-- ne ferait donc rien. C'est le trigger sur cor_site_type ci-dessous qui gère
-- la création.
DROP TRIGGER IF EXISTS trg_maj_cor_aire_domaine_vital_year ON gn_monitoring.t_base_sites;
CREATE TRIGGER trg_maj_cor_aire_domaine_vital_year
AFTER UPDATE OF geom ON gn_monitoring.t_base_sites
FOR EACH ROW
EXECUTE FUNCTION gn_monitoring.fct_trg_maj_cor_aire_domaine_vital_year();

DROP TRIGGER IF EXISTS trg_cor_site_type_maj_cor_aire_domaine_vital_year ON gn_monitoring.cor_site_type;
CREATE TRIGGER trg_cor_site_type_maj_cor_aire_domaine_vital_year
AFTER INSERT ON gn_monitoring.cor_site_type
FOR EACH ROW
EXECUTE FUNCTION gn_monitoring.fct_trg_maj_cor_aire_domaine_vital_year();

-- Cas 2 : la géométrie d'une aire change -> on retrouve le domaine vital qui
-- la contient désormais et on met à jour sa correspondance. 
CREATE OR REPLACE FUNCTION gn_monitoring.fct_trg_maj_cor_aire_domaine_vital_year_from_aire()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_id_base_site_aire integer := NEW.id_base_site;
  v_geom geometry;
  v_id_base_site_domaine_vital integer;
  v_ids_base_site_domaine_vital integer[];
BEGIN
  -- Ne rien faire si le site concerné n'est pas une aire du module aigle
  -- (voir le commentaire de fct_trg_maj_cor_aire_domaine_vital_year pour la
  -- raison de la recherche explicite de la géométrie).
  IF NOT EXISTS (
    SELECT 1
    FROM gn_monitoring.cor_site_type cst
      JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
      JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_aire'
    WHERE cst.id_base_site = v_id_base_site_aire
  ) THEN
    RETURN NEW;
  END IF;

  SELECT geom INTO v_geom
    FROM gn_monitoring.t_base_sites
   WHERE id_base_site = v_id_base_site_aire;

  SELECT array_agg(dv.id_base_site)
    INTO v_ids_base_site_domaine_vital
    FROM gn_monitoring.t_base_sites dv
    WHERE EXISTS (
      SELECT 1
      FROM gn_monitoring.cor_site_type cst
        JOIN gn_monitoring.cor_module_type cmt ON cmt.id_type_site = cst.id_type_site
        JOIN gn_commons.t_modules mod ON mod.id_module = cmt.id_module AND mod.module_code = 'aigle_domaine_vital'
      WHERE cst.id_base_site = dv.id_base_site
    )
    AND ST_Contains(dv.geom, v_geom);

  IF array_length(v_ids_base_site_domaine_vital, 1) > 1 THEN
    RAISE EXCEPTION 'L''aire % est contenue dans plusieurs domaines vitaux (%) : géométries incompatibles.',
      v_id_base_site_aire, v_ids_base_site_domaine_vital;
  END IF;

  v_id_base_site_domaine_vital := v_ids_base_site_domaine_vital[1];

  PERFORM gn_monitoring.fct_maj_cor_aire_domaine_vital_year(v_id_base_site_domaine_vital, v_id_base_site_aire);

  RETURN NEW;
END;
$$;

-- Pas de INSERT ici, même raison que trg_maj_cor_aire_domaine_vital_year.
DROP TRIGGER IF EXISTS trg_maj_cor_aire_domaine_vital_year_from_aire ON gn_monitoring.t_base_sites;
CREATE TRIGGER trg_maj_cor_aire_domaine_vital_year_from_aire
AFTER UPDATE OF geom ON gn_monitoring.t_base_sites
FOR EACH ROW
EXECUTE FUNCTION gn_monitoring.fct_trg_maj_cor_aire_domaine_vital_year_from_aire();

DROP TRIGGER IF EXISTS trg_cor_site_type_maj_cor_aire_domaine_vital_year_from_aire ON gn_monitoring.cor_site_type;
CREATE TRIGGER trg_cor_site_type_maj_cor_aire_domaine_vital_year_from_aire
AFTER INSERT ON gn_monitoring.cor_site_type
FOR EACH ROW
EXECUTE FUNCTION gn_monitoring.fct_trg_maj_cor_aire_domaine_vital_year_from_aire();

