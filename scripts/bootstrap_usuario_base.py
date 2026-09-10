"""Bootstrap del "usuario base" (SCJ-PRO-05, sección Contexto del plan de puesto_permiso).

Invocado desde scripts/desplegar.sh -- no se corre directo. Usa el cliente service_role
de supabase-py (mismo patrón que backend/app/routers/usuarios.py) porque crear el
auth.users real es la única pieza del bootstrap que no puede ser SQL puro.

Modos (sys.argv[1]):
  verificar -- imprime a stdout uno de EXISTE / FALTA / FALTA_PERSONA, sin tocar nada.
               Deja que desplegar.sh decida si hace falta pedir credenciales, sin
               preguntar de más en despliegues ya bootstrapeados.
  crear     -- crea el auth.users (Admin API, password directa, sin invitación por
               correo -- ya hay alguien esperando del otro lado del prompt) e inserta la
               fila de personas.usuario. Lee BOOTSTRAP_CORREO/BOOTSTRAP_CONTRASENA del
               entorno (nunca por argv -- argv es visible para otros usuarios de la
               misma máquina vía `ps`; el entorno de un proceso ajeno no lo es).
               Reverifica antes de crear (misma carrera que ya cubre alta_usuario en
               usuarios.py) y revierte el auth.users si el insert falla, para no dejar
               una cuenta de Auth huérfana.

SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY se leen del entorno en ambos modos --
desplegar.sh ya los exporta desde el .env de la raíz antes de invocar este script.

CURP_BOOTSTRAP es el criterio de identificación de la persona placeholder -- el mismo
valor sembrado en db/ddl/26_puesto_permiso_bootstrap_admin_generico.sql. Se usa la CURP
y no el nombre porque es la clave única y estable; el nombre ("Administrador del
Sistema") es sólo para lectura humana.
"""
import os
import sys

from supabase import create_client

CURP_BOOTSTRAP = "XEXX010101HNEXXXA9"


def _cliente():
    url = os.environ["SUPABASE_URL"]
    service_key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    return create_client(url, service_key)


def _persona_bootstrap(db):
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id")
        .eq("curp", CURP_BOOTSTRAP)
        .execute()
        .data
    )
    return filas[0]["id"] if filas else None


def _tiene_usuario(db, persona_id: str) -> bool:
    filas = (
        db.postgrest.schema("personas")
        .table("usuario")
        .select("auth_user_id")
        .eq("persona_id", persona_id)
        .execute()
        .data
    )
    return bool(filas)


def modo_verificar() -> int:
    db = _cliente()
    persona_id = _persona_bootstrap(db)
    if persona_id is None:
        print("FALTA_PERSONA")
        return 0
    print("EXISTE" if _tiene_usuario(db, persona_id) else "FALTA")
    return 0


def modo_crear() -> int:
    db = _cliente()
    persona_id = _persona_bootstrap(db)
    if persona_id is None:
        print("Error: no existe la persona de bootstrap (falta aplicar 26_*.sql).", file=sys.stderr)
        return 1
    if _tiene_usuario(db, persona_id):
        print("El usuario base ya existe -- nada que crear.")
        return 0

    correo = os.environ["BOOTSTRAP_CORREO"]
    contrasena = os.environ["BOOTSTRAP_CONTRASENA"]

    creado = db.auth.admin.create_user(
        {"email": correo, "password": contrasena, "email_confirm": True}
    )
    auth_user_id = creado.user.id

    nombre_usuario = correo.split("@", 1)[0]
    try:
        db.postgrest.schema("personas").table("usuario").insert(
            {
                "auth_user_id": auth_user_id,
                "persona_id": persona_id,
                "nombre_usuario": nombre_usuario,
            }
        ).execute()
    except Exception:
        db.auth.admin.delete_user(auth_user_id)
        raise

    print(f"Usuario base creado: {correo}")
    return 0


def main() -> int:
    modo = sys.argv[1] if len(sys.argv) > 1 else ""
    if modo == "verificar":
        return modo_verificar()
    if modo == "crear":
        return modo_crear()
    print("Uso: bootstrap_usuario_base.py <verificar|crear>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
