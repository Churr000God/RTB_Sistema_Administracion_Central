import { useEffect, useState } from "react";

import { consultarSesion, type SesionOut } from "./sesion";

// Sesión del caller para decidir qué mostrar (banderas de permisos). consultarSesion() deduplica la
// petición en vuelo, así que usarlo junto con AppShell no duplica GET /api/sesion. Si falla, sesion
// queda en null: cada pantalla decide su fail-open (la autorización real siempre es la RLS/backend).
export function useSesion(): { sesion: SesionOut | null; cargando: boolean } {
  const [sesion, setSesion] = useState<SesionOut | null>(null);
  const [cargando, setCargando] = useState(true);

  useEffect(() => {
    let vivo = true;
    consultarSesion()
      .then((datos) => {
        if (vivo) setSesion(datos);
      })
      .catch(() => {
        if (vivo) setSesion(null);
      })
      .finally(() => {
        if (vivo) setCargando(false);
      });
    return () => {
      vivo = false;
    };
  }, []);

  return { sesion, cargando };
}
