from pydantic import BaseModel, EmailStr

from app.tipos_id import IdUuid


class UsuarioCreate(BaseModel):
    persona_id: IdUuid
    correo: EmailStr
    nombre_usuario: str


class UsuarioOut(BaseModel):
    auth_user_id: str
    persona_id: str
    nombre_usuario: str
    estado: str
