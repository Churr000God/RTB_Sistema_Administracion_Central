from pydantic import BaseModel, EmailStr


class UsuarioCreate(BaseModel):
    persona_id: str
    correo: EmailStr
    nombre_usuario: str


class UsuarioOut(BaseModel):
    auth_user_id: str
    persona_id: str
    nombre_usuario: str
    estado: str
