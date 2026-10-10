"""Comprueba, antes de desplegar, que la base tiene el esquema que este backend necesita (backend/app/precondiciones.py).

Invocado desde scripts/desplegar.sh (`cd backend && uv run python ../scripts/verificar_esquema.py`); SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY salen del entorno que ya exporta.
Códigos de salida: 0 = todo está; 1 = FALTA una migración (el despliegue debe abortar); 2 = no se pudo consultar la base (se avisa y se sigue)."""
import os
import sys


def principal(cliente=None) -> int:
    from app.precondiciones import PrecondicionNoVerificable, faltantes, mensaje

    try:
        if cliente is None:
            from supabase import create_client

            cliente = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])
        perdidas = faltantes(cliente)
    except (PrecondicionNoVerificable, KeyError) as error:
        print(f"Aviso: no se pudo verificar el esquema ({type(error).__name__}); se continúa.", file=sys.stderr)
        return 2
    if perdidas:
        print("Error: " + mensaje(perdidas), file=sys.stderr)
        return 1
    print("Esquema requerido: OK")
    return 0


if __name__ == "__main__":
    sys.exit(principal())
