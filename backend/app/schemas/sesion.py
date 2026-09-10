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
