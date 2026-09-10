"""Script de una sola vez: vacía auth.users por completo, vía Admin API.

Contexto: rebuild total de la base (2026-09-04) -- 4 cuentas de dev/QA quedaron
atrapadas por la inmutabilidad de la bitácora (imposible borrarlas quirúrgicamente),
así que se tira todo (`db` dropea personas/tiempo en paralelo con esto) y se reconstruye
desde el DDL versionado. auth.users no se puede reconstruir desde DDL -- vive fuera de
los esquemas personas/tiempo -- así que hay que vaciarlo aparte, acá.

NUNCA DELETE SQL directo sobre auth.users (mismo criterio que bootstrap_usuario_base.py):
usa exclusivamente `admin.list_users` / `admin.delete_user` de supabase-py, que es lo
único soportado por Supabase para borrar cuentas de Auth sin dejar estado huérfano en
GoTrue.

No es reusable a propósito -- es una operación de una sola vez, confirmada explícita
por el usuario. Exige escribir la frase de confirmación exacta antes de borrar nada,
como segunda barrera además de la confirmación ya dada fuera de este script.

No recibe argumentos. Lee SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY del entorno (ya
exportadas desde .env por quien invoque esto).
"""
import os
import sys

from supabase import create_client

FRASE_CONFIRMACION = "BORRAR TODO auth.users"


def main() -> int:
    url = os.environ["SUPABASE_URL"]
    service_key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    db = create_client(url, service_key)

    usuarios = []
    pagina = 1
    while True:
        lote = db.auth.admin.list_users(page=pagina, per_page=200)
        if not lote:
            break
        usuarios.extend(lote)
        pagina += 1

    if not usuarios:
        print("auth.users ya está vacío -- nada que borrar.")
        return 0

    print(f"Se van a borrar {len(usuarios)} cuentas de auth.users (TODAS, sin excepción):")
    for u in usuarios:
        print(f"  - {u.id}  {u.email}")

    respuesta = input(f'\nEscribí exactamente "{FRASE_CONFIRMACION}" para continuar: ')
    if respuesta != FRASE_CONFIRMACION:
        print("Confirmación no coincide -- no se borró nada.", file=sys.stderr)
        return 1

    borrados = 0
    fallidos = []
    for u in usuarios:
        try:
            db.auth.admin.delete_user(u.id)
            borrados += 1
        except Exception as error:  # noqa: BLE001 -- se reporta cada falla, no se detiene el lote
            fallidos.append((u.id, u.email, str(error)))

    print(f"\nBorrados: {borrados}/{len(usuarios)}")
    if fallidos:
        print("Fallaron:", file=sys.stderr)
        for auth_id, correo, error in fallidos:
            print(f"  - {auth_id} ({correo}): {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
