import type { ReactNode } from "react";
import { Lock } from "lucide-react";

import { AppShell } from "../layouts/AppShell";
import { useSesion } from "../lib/useSesion";
import type { SesionOut } from "../lib/sesion";

type Props = {
  // Bandera de /api/sesion que da acceso a la pantalla (p. ej. puede_ver_modulo_1).
  campo: keyof Pick<SesionOut, "puede_ver_modulo_1" | "puede_ver_modulo_2" | "puede_ver_modulo_3">;
  children: ReactNode;
};

// Guarda de UI para una ruta directa. Tres estados de la sesión (ya no hay fail-open):
//  - cargando o error: no se monta la pantalla; AppShell muestra «Verificando acceso…» o el error con
//    «Reintentar» (usa la misma consulta, deduplicada);
//  - cargada sin la bandera en true (false o ausente): aviso de acceso no autorizado;
//  - cargada con la bandera: la pantalla.
// Es sólo UX: la autorización real es backend/RLS (que responden 403 o vacío).
export function ProtegidaPorModulo({ campo, children }: Props) {
  const { sesion, cargando, error } = useSesion();
  if (cargando || error || !sesion) {
    return (
      <AppShell>
        <></>
      </AppShell>
    );
  }
  if (sesion[campo] !== true) {
    return (
      <AppShell>
        <div className="contenedor-pagina">
          <div className="estado-vacio">
            <Lock size={40} aria-hidden="true" />
            <p>
              <strong>No tienes acceso a esta sección.</strong>
              <br />
              Si crees que deberías verla, avisa a Recursos Humanos. <a href="/inicio">Ir a Inicio</a>
            </p>
          </div>
        </div>
      </AppShell>
    );
  }
  return <>{children}</>;
}
