import { Loader2 } from "lucide-react";

import { AppShell } from "../layouts/AppShell";
import { useSesion } from "../lib/useSesion";

const ETIQUETA_ESTADO: Record<string, string> = {
  activo: "Activo",
  suspension: "Suspensión",
  baja_definitiva: "Baja",
};

// Pantalla de inicio MÍNIMA para quien no puede ver ningún módulo (p. ej. una persona activa a la que
// todavía no le asignan un puesto). Sólo muestra los datos de la propia sesión; es deliberadamente
// simple y fácil de reemplazar por el diseño definitivo. Nunca lista ni consulta datos de otras personas.
export function InicioPage() {
  const { sesion, cargando } = useSesion();

  return (
    <AppShell>
      <div className="contenedor-pagina">
        <h1>Inicio</h1>
        {cargando && (
          <p className="boton-con-icono" role="status">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando…
          </p>
        )}
        {!cargando && (
          <div className="tarjeta-resumen">
            <h2>{sesion?.nombre_usuario ? `Hola, ${sesion.nombre_usuario}` : "Hola"}</h2>
            <dl style={{ margin: "0.5rem 0 0", display: "grid", gridTemplateColumns: "max-content 1fr", gap: "0.25rem 1rem" }}>
              <dt className="rango">Estado</dt>
              <dd style={{ margin: 0 }}>
                {sesion?.persona_estado ? (ETIQUETA_ESTADO[sesion.persona_estado] ?? sesion.persona_estado) : "—"}
              </dd>
              <dt className="rango">Correo</dt>
              <dd style={{ margin: 0 }}>{sesion?.correo ?? "—"}</dd>
            </dl>
            <p style={{ marginTop: "1rem" }}>
              Tu acceso está en configuración. Avisa a Recursos Humanos para que te asignen un puesto.
            </p>
          </div>
        )}
      </div>
    </AppShell>
  );
}
