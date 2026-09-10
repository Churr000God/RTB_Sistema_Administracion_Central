"""Script de una sola vez: borra un factor MFA colgado (status 'unverified') de un usuario.

Contexto: bug real de frontend (doble-montaje de React StrictMode disparando `enroll()`
dos veces) dejó un factor TOTP sin verificar en Supabase Auth para el correo pasado por
argv. Ese factor colgado bloquea cualquier reintento de enrolar 2FA con
`mfa_factor_name_conflict`. El fix de frontend evita que vuelva a pasar; esto limpia el
estado que ya quedó colgado.

supabase-py 2.31 no expone `admin.mfa.*` (SyncGoTrueAdminAPI no lo wrapea) -- se usa
`get_user_by_id` para listar factores (vienen en `user.factors`) y una llamada HTTP
directa, autenticada con `service_role`, al endpoint REST de GoTrue
(`DELETE /auth/v1/admin/users/{user_id}/factors/{factor_id}`), que es la única vía
oficial para borrar un factor -- nunca DELETE SQL directo sobre auth.mfa_factors, mismo
criterio que auth.users.

Uso: uv run python borrar_factor_mfa_colgado.py <correo>
Sólo borra factores con status 'unverified' -- nunca toca uno 'verified'.
"""
import os
import sys

import httpx
from supabase import create_client


def main() -> int:
    if len(sys.argv) != 2:
        print("Uso: borrar_factor_mfa_colgado.py <correo>", file=sys.stderr)
        return 2
    correo = sys.argv[1]

    url = os.environ["SUPABASE_URL"]
    service_key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    db = create_client(url, service_key)

    encontrado = next(
        (u for u in db.auth.admin.list_users() if u.email == correo),
        None,
    )
    if encontrado is None:
        print(f"Error: no existe ningún auth.users con correo {correo}.", file=sys.stderr)
        return 1

    usuario = db.auth.admin.get_user_by_id(encontrado.id).user
    factores = usuario.factors or []
    if not factores:
        print(f"{correo} no tiene ningún factor MFA registrado -- nada que borrar.")
        return 0

    sin_verificar = [f for f in factores if f.status == "unverified"]
    print(f"Factores de {correo}:")
    for f in factores:
        print(f"  - {f.id}  tipo={f.factor_type}  estado={f.status}")

    if not sin_verificar:
        print("Ninguno sin verificar -- nada que borrar.")
        return 0

    endpoint_base = url.rstrip("/") + "/auth/v1/admin/users"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }
    borrados = 0
    with httpx.Client() as cliente:
        for f in sin_verificar:
            respuesta = cliente.delete(
                f"{endpoint_base}/{usuario.id}/factors/{f.id}",
                headers=headers,
            )
            if respuesta.status_code >= 300:
                print(
                    f"Error borrando factor {f.id}: {respuesta.status_code} {respuesta.text}",
                    file=sys.stderr,
                )
                continue
            borrados += 1
            print(f"Borrado: {f.id}")

    print(f"\nBorrados {borrados}/{len(sin_verificar)} factores sin verificar.")

    usuario_final = db.auth.admin.get_user_by_id(usuario.id).user
    quedan_sin_verificar = [f for f in (usuario_final.factors or []) if f.status == "unverified"]
    if quedan_sin_verificar:
        print(
            f"Quedan {len(quedan_sin_verificar)} factores sin verificar -- revisar a mano.",
            file=sys.stderr,
        )
        return 1

    print(f"Confirmado: {correo} no tiene ningún factor MFA sin verificar.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
