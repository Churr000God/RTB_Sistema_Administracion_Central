"""Provisiona la llave de una terminal (SCJ-DEC-12 §1 / B4). Lo corre TI, no el backend ni el Pi.

    uv run python scripts/alta_credencial_terminal.py --serie SERIE-DE-LA-TERMINAL --etiqueta "Pi original"

Genera una llave `scjt_…` (secrets.token_urlsafe), guarda en `tiempo.terminal_credencial` SÓLO su
hash SHA-256 (con service_role, leyendo el .env de siempre) y muestra la llave UNA sola vez en
pantalla. La llave no es un argumento (no queda en el historial del shell), no se escribe en
archivos ni se registra, y el hash no se imprime. Si algo falla antes de guardar el hash, no se
muestra ninguna llave. Copiar la llave al `.env` del Pi (permisos 600) en ese momento: no se puede
recuperar después, sólo rotar.

Rotación: correr el script otra vez (ambas llaves quedan vigentes: es el traslape), configurar el
Pi y revocar la vieja (`revocada_en`)."""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from postgrest import ReturnMethod  # noqa: E402

from app.terminal_auth import generar_llave, hash_llave  # noqa: E402

LONGITUD_MAXIMA_ETIQUETA = 60  # tiempo.terminal_credencial.etiqueta varchar(60)
# Mismo saneo que usa SQL para texto del Pi (regexp_replace [[:cntrl:]]): controles ASCII y C1.
CARACTERES_DE_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def sanear_etiqueta(etiqueta: str | None) -> str | None:
    if etiqueta is None:
        return None
    limpia = CARACTERES_DE_CONTROL.sub("", etiqueta).strip()
    return limpia or None


class ErrorProvision(Exception):
    pass


def registrar_credencial(db, serie: str, etiqueta: str | None) -> str:
    """Devuelve la llave en claro (la única copia). `db` es un cliente service_role."""
    tabla = db.postgrest.schema("tiempo").table
    filas = tabla("terminal").select("id, terminal_id, activa").eq("terminal_id", serie).execute().data
    if not filas:
        raise ErrorProvision(f"No existe una terminal con la serie '{serie}'.")
    terminal = filas[0]
    if not terminal["activa"]:
        raise ErrorProvision(f"La terminal '{serie}' no está activa; no se le emite una llave.")

    llave = generar_llave()
    tabla("terminal_credencial").insert(
        {"terminal_id": terminal["id"], "hash": hash_llave(llave), "etiqueta": sanear_etiqueta(etiqueta)},
        returning=ReturnMethod.minimal,
    ).execute()
    return llave


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Emite la llave de una terminal (la muestra una vez).",
        epilog=(
            "La llave se imprime UNA sola vez en pantalla. NO redirijas la salida a un archivo ni a un "
            "log, ni la ejecutes dentro de algo que registre la salida. Después de copiarla al .env "
            "del Pi, limpia el scrollback de la terminal (clear, o cierra la ventana)."
        ),
    )
    parser.add_argument("--serie", required=True, help="serie de la terminal (tiempo.terminal.terminal_id)")
    parser.add_argument(
        "--etiqueta",
        default=None,
        help=f"nombre para distinguir la llave (máx. {LONGITUD_MAXIMA_ETIQUETA})",
    )
    return parser


def main(argv: list[str] | None = None, db=None) -> int:
    args = _parser().parse_args(argv)
    if len(sanear_etiqueta(args.etiqueta) or "") > LONGITUD_MAXIMA_ETIQUETA:
        _parser().error(f"--etiqueta admite como máximo {LONGITUD_MAXIMA_ETIQUETA} caracteres")

    try:
        if db is None:
            from app.config import get_settings
            from app.deps import get_service_client

            db = get_service_client(get_settings())
        llave = registrar_credencial(db, args.serie, args.etiqueta)
    except ErrorProvision as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"Error: no se pudo guardar la credencial ({type(error).__name__}).", file=sys.stderr)
        return 1

    print("Llave de la terminal (se muestra UNA sola vez; cópiala ahora al .env del Pi):")
    print(llave)
    print("Listo. Copia la llave al .env del Pi (chmod 600) y limpia el scrollback de esta terminal.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
