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

// Guarda de UI para una ruta directa: si la sesión dice que NO puede ver el módulo, muestra un aviso de
// acceso no autorizado en vez de la pantalla. Es sólo UX: la autorización real es backend/RLS (que
// responden 403 o vacío). Mientras la sesión carga no se monta la pantalla (evita pedir datos de más), y
// si la sesión no se pudo leer se deja pasar (fail-open, mismo criterio que AppShell).
export function ProtegidaPorModulo({ campo, children }: Props) {
  const { sesion, cargando } = useSesion();
  if (cargando) return <AppShell><p className="contenedor-pagina">Verificando acceso…</p></AppShell>;
  if (sesion && sesion[campo] === false) {
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
