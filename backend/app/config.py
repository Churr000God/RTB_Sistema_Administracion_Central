"""Configuración leída de variables de entorno (.env en la raíz del repo)."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Dos rutas candidatas: "../.env" para correr uvicorn desde backend/ en local,
    # ".env" para el contenedor Docker (WORKDIR /app, sin la carpeta backend/ encima).
    # pydantic-settings usa el archivo que exista; si ninguno existe, cae a variables
    # de entorno reales (las que inyecta docker-compose) sin fallar.
    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")

    supabase_url: str
    supabase_anon_key: str
    supabase_service_role_key: str
    frontend_url: str = "http://localhost:5173"

    # --- Terminal Hikvision / puente (SCJ-DEC-12 §1, §7). Ninguno es un secreto: la llave de la
    # terminal vive en el Pi y su hash en la base, no en la configuración del backend. ---
    # HTTPS obligatorio en /api/terminal/*. Falla cerrada: sólo desarrollo debe ponerlo en false.
    terminal_requiere_https: bool = True
    # Proxies cuyas cabeceras X-Forwarded-Proto / X-Forwarded-For SÍ se honran: IPs o CIDR
    # separados por coma. Vacío = no se confía en ninguna cabecera (sólo el esquema real).
    # NUNCA 0.0.0.0/0 ni ::/0 (se ignoran). Despliegue: el proxy debe SOBRESCRIBIR
    # X-Forwarded-Proto y AÑADIR al final de X-Forwarded-For; y FORWARDED_ALLOW_IPS de uvicorn nunca
    # "*" (al arrancar se emite un WARNING). limit_req y client_max_body_size son del proxy (devops).
    terminal_proxies_confianza: str = ""
    # Backoff por IP (en memoria, por proceso): tras N respuestas 401 consecutivas la IP recibe 429
    # durante `bloqueo_base` segundos, que se duplican con cada reincidencia (tope 1 h). Valores
    # iniciales ajustables (SCJ-DEC-12 §7).
    terminal_max_fallos_por_ip: int = 10
    terminal_ventana_fallos_seg: int = 300
    terminal_bloqueo_base_seg: int = 60


@lru_cache
def get_settings() -> Settings:
    return Settings()


def parse_frontend_urls(valor: str) -> list[str]:
    """FRONTEND_URL admite varios orígenes separados por coma (ej. localhost + una IP de
    Tailscale al mismo tiempo, para probar desde escritorio y celular sin reiniciar) -- separa,
    recorta espacios y descarta vacíos. Un solo valor sin comas sigue devolviendo una lista de
    uno, mismo comportamiento que antes."""
    return [origen.strip() for origen in valor.split(",") if origen.strip()]
