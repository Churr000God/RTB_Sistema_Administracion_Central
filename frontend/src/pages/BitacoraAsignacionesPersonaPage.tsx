import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertCircle, Loader2, Repeat } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Badge } from "../components/Badge";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
};

type Asignacion = {
  id: string;
  persona_id: string;
  puesto_id: string;
  nombre_puesto: string;
  nombre_departamento: string;
  nombre_area: string;
  vigente_desde: string;
  vigente_hasta: string | null;
};

type EstadoCarga = "cargando" | "listo" | "error";

const ETIQUETA_ESTADO: Record<string, string> = {
  activo: "Activo",
  suspension: "Suspendido",
  baja_definitiva: "Baja",
};

const VARIANTE_ESTADO: Record<string, "exito" | "aviso" | "peligro"> = {
  activo: "exito",
  suspension: "aviso",
  baja_definitiva: "peligro",
};

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha.includes("T") ? fecha : `${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

export function BitacoraAsignacionesPersonaPage() {
  const { id } = useParams<{ id: string }>();
  const [persona, setPersona] = useState<Persona | null>(null);
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");

  useEffect(() => {
    setEstadoCarga("cargando");
    Promise.all([
      apiFetch(`/api/personas/${id}`).then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
      apiFetch("/api/asignaciones").then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      }),
    ])
      .then(([datosPersona, datosAsignaciones]: [Persona, Asignacion[]]) => {
        setPersona(datosPersona);
        setAsignaciones(datosAsignaciones.filter((a) => a.persona_id === id));
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }, [id]);

  const ordenadas = useMemo(
    () => [...asignaciones].sort((a, b) => new Date(b.vigente_desde).getTime() - new Date(a.vigente_desde).getTime()),
    [asignaciones],
  );

  const agrupadasPorAnio = useMemo(() => {
    const grupos = new Map<string, Asignacion[]>();
    for (const asignacion of ordenadas) {
      const anio = new Date(asignacion.vigente_desde).getFullYear().toString();
      const lista = grupos.get(anio) ?? [];
      lista.push(asignacion);
      grupos.set(anio, lista);
    }
    return grupos;
  }, [ordenadas]);

  const nombreCompleto = persona ? `${persona.primer_nombre} ${persona.apellido_paterno}` : "";
  const iniciales = persona
    ? `${persona.primer_nombre[0] ?? ""}${persona.apellido_paterno[0] ?? ""}`.toUpperCase()
    : "";

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/personas">Personas</a>
          {persona && (
            <>
              {" / "}
              <a href={`/personas/${id}`}>{nombreCompleto}</a>
            </>
          )}
          {" / "}
          <strong>Bitácora de puestos</strong>
        </nav>
        <h1>Bitácora de puestos</h1>
        <p className="subtitulo-pagina">Historial completo de asignaciones de esta persona a puestos.</p>

        {estadoCarga === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando bitácora…
          </p>
        )}

        {estadoCarga === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar la bitácora de puestos
            </strong>
            <p>Ocurrió un problema al consultar el historial.</p>
          </div>
        )}

        {estadoCarga === "listo" && persona && (
          <div className="cabecera-persona cabecera-bitacora">
            <div className="identidad">
              <span className="avatar-iniciales">{iniciales}</span>
              <strong>{nombreCompleto}</strong>
            </div>
            <div className="metricas-cabecera">
              <div>
                <span className="etiqueta-metrica">Asignaciones</span>
                <strong>{ordenadas.length}</strong>
              </div>
            </div>
            <Badge variante={VARIANTE_ESTADO[persona.estado] ?? "neutra"}>
              {ETIQUETA_ESTADO[persona.estado] ?? persona.estado}
            </Badge>
          </div>
        )}

        {estadoCarga === "listo" && ordenadas.length === 0 && (
          <p>Esta persona no tiene asignaciones registradas todavía.</p>
        )}

        {estadoCarga === "listo" && ordenadas.length > 0 && (
            <div className="linea-tiempo">
              {[...agrupadasPorAnio.entries()].map(([anio, items]) => (
                <div key={anio} className="grupo-anio">
                  <h2 className="titulo-anio">{anio}</h2>
                  {items.map((asignacion) => (
                    <article key={asignacion.id} className="tarjeta-movimiento">
                      <div className="fila-movimiento">
                        <time dateTime={asignacion.vigente_desde}>
                          {formatearFecha(asignacion.vigente_desde)}
                          {" — "}
                          {asignacion.vigente_hasta ? formatearFecha(asignacion.vigente_hasta) : "Vigente"}
                        </time>
                        <Badge variante={asignacion.vigente_hasta ? "neutra" : "exito"}>
                          {asignacion.vigente_hasta ? "Terminada" : "Vigente"}
                        </Badge>
                      </div>
                      <p style={{ fontWeight: 600, margin: 0 }}>
                        {asignacion.nombre_puesto}
                      </p>
                      <p className="ayuda-campo">
                        {asignacion.nombre_departamento} · {asignacion.nombre_area}
                      </p>
                      {!asignacion.vigente_hasta && (
                        <div className="botonera" style={{ justifyContent: "flex-start", marginTop: "0.6rem" }}>
                          <a href={`/estructura/asignaciones/${asignacion.id}/terminar`}>Terminar</a>
                          <Button
                            href={`/estructura/asignaciones/${asignacion.id}/cambiar-puesto`}
                            variante="primario"
                            icono={Repeat}
                            posicionIcono="izquierda"
                            tamanoIcono={14}
                          >
                            Cambiar de puesto
                          </Button>
                        </div>
                      )}
                    </article>
                  ))}
                </div>
              ))}
            </div>
        )}
      </div>
    </AppShell>
  );
}
