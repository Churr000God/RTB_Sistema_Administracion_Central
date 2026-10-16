import { Outlet } from "react-router-dom";

import { ProtegidaPorModulo, type CampoDeModulo } from "./ProtegidaPorModulo";

// Layout de ruta: NO monta el <Outlet/> (y por tanto ninguna pantalla hija, ni sus useEffect ni sus
// peticiones) hasta tener la sesión verificada Y la bandera del módulo en `true` explícito.
//  - cargando: «Verificando acceso…»;
//  - error de sesión: el aviso con «Reintentar» (nunca se abre nada);
//  - sesión cargada sin la bandera: «No tienes acceso a esta sección» con enlace a Inicio.
// Es UX y ahorro de peticiones inútiles; la autoridad real sigue siendo backend/RLS. Las banderas más
// específicas de cada pantalla (descartar excepciones, editar configuración de terminales…) se siguen
// evaluando dentro de la pantalla: esta guarda sólo se suma, no las reemplaza ni las afloja.
export function RutaVerificada({ campo }: { campo: CampoDeModulo }) {
  return (
    <ProtegidaPorModulo campo={campo}>
      <Outlet />
    </ProtegidaPorModulo>
  );
}
