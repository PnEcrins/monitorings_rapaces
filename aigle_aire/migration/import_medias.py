"""
Import des photos des aires d'aigle (pr_aigle.t_photos_aires) dans gn_commons.t_medias.

Chaque photo est rattachée au site monitoring de l'aire (gn_monitoring.t_base_sites) :
  - uuid_attached_row = t_base_sites.uuid_base_site
  - id_table_location = gn_commons.bib_tables_location (gn_monitoring.t_base_sites)
La correspondance aire -> site se fait via t_site_complements.data->>'old_id_aire'
(renseigné par migrate.py --module aigle_aire, qui doit donc avoir tourné avant).

Les fichiers sont copiés dans <MEDIA_FOLDER>/attachments/<id_table_location>/<id_media>_<nom>
(même convention que l'upload GeoNature). Les vignettes sont générées par GeoNature
à la volée au premier affichage.

Le script est rejouable : une photo déjà importée (même site, même nom de fichier) est ignorée.

Usage :
    cd backend
    source venv/bin/activate
    python media/monitorings/aigle_aire/migration/import_medias.py \
        --photos-dir /home/theo/workspace/aires [--author "..."] [--dry-run]
"""

import argparse
import logging
import shutil
from pathlib import Path

from sqlalchemy import text
from werkzeug.utils import secure_filename

from geonature import create_app
from geonature.utils.env import DB
from geonature.core.gn_commons.models import TMedias
from geonature.core.gn_commons.repositories import get_table_location_id

logger = logging.getLogger("import_medias_aigle")
logger.setLevel(logging.INFO)
logger.propagate = False
_handler = logging.StreamHandler()
_handler.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
logger.addHandler(_handler)

# Nomenclature TYPE_MEDIA "Photo"
CD_NOMENCLATURE_PHOTO = "2"


def load_photo_nomenclature_id():
    id_nomenclature = DB.session.execute(
        text("SELECT ref_nomenclatures.get_id_nomenclature('TYPE_MEDIA', :cd)"),
        {"cd": CD_NOMENCLATURE_PHOTO},
    ).scalar()
    if id_nomenclature is None:
        raise RuntimeError(f"Nomenclature TYPE_MEDIA/{CD_NOMENCLATURE_PHOTO} (Photo) introuvable")
    return id_nomenclature


def load_site_uuid_by_aire():
    """{ancien id_aire -> uuid_base_site} pour les sites aigle_aire migrés."""
    rows = DB.session.execute(
        text(
            """
            SELECT (sc.data->>'old_id_aire')::int AS id_aire, bs.uuid_base_site
            FROM gn_monitoring.t_site_complements sc
            JOIN gn_monitoring.t_base_sites bs ON bs.id_base_site = sc.id_base_site
            WHERE sc.data ? 'old_id_aire'
            """
        )
    ).all()
    return {row.id_aire: row.uuid_base_site for row in rows}


def fetch_photos():
    return DB.session.execute(
        text(
            """
            SELECT id_photo, id_aire, chemin, legend, nom_photo
            FROM pr_aigle.t_photos_aires
            ORDER BY id_photo
            """
        )
    ).mappings().all()


def media_already_imported(uuid_site, id_table_location, filename):
    return DB.session.execute(
        text(
            """
            SELECT 1 FROM gn_commons.t_medias
            WHERE uuid_attached_row = :uuid
              AND id_table_location = :id_table_location
              AND media_path LIKE :pattern
            """
        ),
        {
            "uuid": uuid_site,
            "id_table_location": id_table_location,
            "pattern": f"%\\_{filename}",
        },
    ).first() is not None


def import_medias(photos_dir, author):
    id_table_location = get_table_location_id("gn_monitoring", "t_base_sites")
    if id_table_location is None:
        raise RuntimeError("gn_monitoring.t_base_sites absent de gn_commons.bib_tables_location")
    id_nomenclature_photo = load_photo_nomenclature_id()
    site_uuid_by_aire = load_site_uuid_by_aire()

    dest_dir = TMedias.base_dir() / str(id_table_location)
    copied_files = []
    stats = {"imported": 0, "skipped_existing": 0, "missing_site": 0, "missing_file": 0}

    try:
        for photo in fetch_photos():
            uuid_site = site_uuid_by_aire.get(photo["id_aire"])
            if uuid_site is None:
                logger.warning(
                    "Photo %s : aucun site migré pour l'aire %s, ignorée",
                    photo["id_photo"], photo["id_aire"],
                )
                stats["missing_site"] += 1
                continue

            src = photos_dir / (photo["nom_photo"] or "")
            if not photo["nom_photo"] or not src.is_file():
                logger.warning("Photo %s : fichier '%s' introuvable, ignorée", photo["id_photo"], src)
                stats["missing_file"] += 1
                continue

            filename = secure_filename(photo["nom_photo"])
            if media_already_imported(uuid_site, id_table_location, filename):
                stats["skipped_existing"] += 1
                continue

            media = TMedias(
                id_nomenclature_media_type=id_nomenclature_photo,
                id_table_location=id_table_location,
                uuid_attached_row=uuid_site,
                title_fr=photo["legend"] or photo["nom_photo"],
                author=author,
                is_public=True,
            )
            DB.session.add(media)
            DB.session.flush()  # récupère id_media pour nommer le fichier

            relative_path = Path(str(id_table_location)) / f"{media.id_media}_{filename}"
            media.media_path = str(relative_path)

            dest = TMedias.base_dir() / relative_path
            dest_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            copied_files.append(dest)
            stats["imported"] += 1

        DB.session.flush()
    except Exception:
        _cleanup(copied_files)
        raise

    logger.info(
        "Photos importées : %(imported)s | déjà présentes : %(skipped_existing)s | "
        "aire sans site : %(missing_site)s | fichier absent : %(missing_file)s",
        stats,
    )
    return copied_files


def _cleanup(files):
    for f in files:
        f.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--photos-dir", type=Path, required=True,
        help="Répertoire contenant les photos (nom_photo de pr_aigle.t_photos_aires)",
    )
    parser.add_argument("--author", default=None, help="Auteur à renseigner sur les médias")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Exécute l'import puis annule la transaction et supprime les fichiers copiés",
    )
    args = parser.parse_args()

    if not args.photos_dir.is_dir():
        parser.error(f"{args.photos_dir} n'est pas un répertoire")

    app = create_app()
    with app.app_context():
        copied_files = []
        try:
            copied_files = import_medias(args.photos_dir, args.author)
            if args.dry_run:
                DB.session.rollback()
                _cleanup(copied_files)
                logger.info("Dry-run : transaction annulée, fichiers copiés supprimés.")
            else:
                DB.session.commit()
                logger.info("Import terminé et validé.")
        except Exception:
            DB.session.rollback()
            _cleanup(copied_files)
            logger.exception("Erreur durant l'import, transaction annulée.")
            raise


if __name__ == "__main__":
    main()
