import { AlertCircle, Loader2 } from "lucide-react";

import { AppShell } from "../layouts/AppShell";
import { modulosVisibles } from "../lib/destinoInicial";
import { useSesion } from "../lib/useSesion";

const ETIQUETA_ESTADO: Record<string, string> = {
  activo: "Activo",
  suspension: "Suspensión",
  baja_definitiva: "Baja",
};

// Pantalla de inicio MÍNIMA y fácil de reemplazar por el diseño definitivo. Es el destino por defecto de
// toda persona con sesión. Según la sesión REAL (no un texto fijo):
//  - sin ningún módulo: el aviso de que su acceso está en configuración;
//  - con algún módulo: un saludo corto y los accesos a los módulos que sí puede ver.
// Sólo muestra los datos de la propia sesión; nunca lista ni consulta datos de otras personas. Si la
// sesión no se puede verificar no adivina: muestra el error con «Reintentar».
export function InicioPage() {
  const { sesion, cargando, error, reintentar } = useSesion();
  const modulos = sesion ? modulosVisibles(sesion) : [];

  return (
    <AppShell>
      <div className="contenedor-pagina">
        <h1>Inicio</h1>
        {cargando && !error && (
          <p className="boton-con-icono" role="status">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando…
          </p>
        )}
        {error && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No pudimos verificar tu acceso
            </strong>
            <p>Revisa tu conexión e inténtalo de nuevo; si sigue fallando, avisa a Sistemas.</p>
            <button type="button" className="boton-con-icono" onClick={reintentar}>
              Reintentar
            </button>
          </div>
        )}
        {!cargando && sesion && (
          <div className="tarjeta-resumen">
            <h2>{sesion.nombre_usuario ? `Hola, ${sesion.nombre_usuario}` : "Hola"}</h2>
            <dl style={{ margin: "0.5rem 0 0", display: "grid", gridTemplateColumns: "max-content 1fr", gap: "0.25rem 1rem" }}>
              <dt className="rango">Estado</dt>
              <dd style={{ margin: 0 }}>
                {sesion.persona_estado ? (ETIQUETA_ESTADO[sesion.persona_estado] ?? sesion.persona_estado) : "—"}
              </dd>
              <dt className="rango">Correo</dt>
              <dd style={{ margin: 0 }}>{sesion.correo ?? "—"}</dd>
            </dl>
            {modulos.length === 0 ? (
              <p style={{ marginTop: "1rem" }}>
                Tu acceso está en configuración. Avisa a Recursos Humanos para que te asignen un puesto.
              </p>
            ) : (
              <>
                <p style={{ marginTop: "1rem" }}>Estos son tus accesos:</p>
                <ul>
                  {modulos.map((modulo) => (
                    <li key={modulo.href}>
                      <a href={modulo.href}>{modulo.etiqueta}</a>
                    </li>
                  ))}
                </ul>
              </>
            )}
          </div>
        )}
      </div>
    </AppShell>
  );
}
