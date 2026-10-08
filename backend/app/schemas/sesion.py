from pydantic import BaseModel


class SesionOut(BaseModel):
    auth_user_id: str
    correo: str | None
    nombre_usuario: str | None
    persona_id: str | None
    persona_estado: str | None
    acceso_permitido: bool
    motivo_bloqueo: str | None  # suspension | baja_definitiva | sin_persona | sin_usuario | None
    puede_ver_modulo_1: bool = False
    puede_ver_modulo_2: bool = False
    puede_ver_modulo_3: bool = False
    # Permiso de ACCIÓN no heredable (86_*.sql): la UI sólo muestra "Descartar" a quien lo tiene. La
    # autorización real es la base (fn_excepcion_dia_cerrado_descartar), esto es sólo comodidad de UI.
    puede_descartar_excepciones: bool = False
    # Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md §7). Ver el grupo/Configuración: lectura, edición o
    # config (la misma visibilidad que la RLS de terminal_consentimiento; supuesto Q5, reversible).
    puede_ver_terminales: bool = False
    puede_editar_terminales: bool = False
    puede_editar_config_terminales: bool = False
