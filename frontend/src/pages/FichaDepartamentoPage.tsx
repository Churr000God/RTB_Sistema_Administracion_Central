import { type FormEvent, useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertCircle, Loader2, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";

type Departamento = {
  id: string;
  area_id: string;
  nombre_departamento: string;
  activo: boolean;
  creado_en: string;
  actualizado_en: string;
};

type Area = {
  id: string;
  nombre_area: string;
};

type Puesto = {
  id: string;
  departamento_id: string;
  activo: boolean;
};

type Asignacion = {
  persona_id: string;
  persona_nombre: string;
  nombre_puesto: string;
  nombre_departamento: string;
  vigente_hasta: string | null;
};

type PersonaAgrupada = {
  persona_id: string;
  persona_nombre: string;
  puestos: string[];
};

type EstadoCarga = "cargando" | "listo" | "error";
type EstadoCatalogo = "cargando" | "listo" | "error" | "sin_permiso";

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function inicialesDe(nombre: string): string {
  const partes = nombre.trim().split(/\s+/);
  return `${partes[0]?.[0] ?? ""}${partes[partes.length - 1]?.[0] ?? ""}`.toUpperCase();
}

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function FichaDepartamentoPage() {
  const { id } = useParams<{ id: string }>();
  const [departamento, setDepartamento] = useState<Departamento | null>(null);
  const [nombreArea, setNombreArea] = useState<string | null>(null);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [estadoPuestos, setEstadoPuestos] = useState<EstadoCatalogo>("cargando");
  const [puestosActivos, setPuestosActivos] = useState(0);
  const [estadoAsignaciones, setEstadoAsignaciones] = useState<EstadoCatalogo>("cargando");
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [busqueda, setBusqueda] = useState("");
  const [guardando, setGuardando] = useState(false);
  const [cambiandoEstado, setCambiandoEstado] = useState(false);

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch(`/api/departamentos/${id}`)
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datosDepartamento: Departamento) => {
        setDepartamento(datosDepartamento);
        setEstadoCarga("listo");
        apiFetch(`/api/areas/${datosDepartamento.area_id}`)
          .then((r) => (r.ok ? r.json() : null))
          .then((datosArea: Area | null) => setNombreArea(datosArea?.nombre_area ?? null))
          .catch(() => setNombreArea(null));

        // Los dos catálogos de abajo tienen gates de permiso propios (puesto_lectura/edicion,
        // asignacion_lectura/edicion) — distintos entre sí y del departamento_lectura/edicion
        // que ya exige esta página. Se piden por separado y degradan por separado: uno puede
        // fallar sin tumbar al otro ni al resto de la ficha.
        setEstadoPuestos("cargando");
        apiFetch("/api/puestos")
          .then((r) => {
            if (r.status === 403) throw new Error("sin_permiso");
            if (!r.ok) throw new Error(`status ${r.status}`);
            return r.json();
          })
          .then((datosPuestos: Puesto[]) => {
            setPuestosActivos(
              datosPuestos.filter((p) => p.departamento_id === datosDepartamento.id && p.activo).length,
            );
            setEstadoPuestos("listo");
          })
          .catch((e: Error) => setEstadoPuestos(e.message === "sin_permiso" ? "sin_permiso" : "error"));

        // nombre_departamento es único en todo el catálogo (AltaDepartamentoPage ya lo exige
        // así) — filtrar por ese nombre denormalizado en /api/asignaciones deja este pedido
        // totalmente independiente de si /api/puestos respondió o no.
        setEstadoAsignaciones("cargando");
        apiFetch("/api/asignaciones")
          .then((r) => {
            if (r.status === 403) throw new Error("sin_permiso");
            if (!r.ok) throw new Error(`status ${r.status}`);
            return r.json();
          })
          .then((datosAsignaciones: Asignacion[]) => {
            setAsignaciones(
              datosAsignaciones.filter(
                (a) => a.nombre_departamento === datosDepartamento.nombre_departamento && !a.vigente_hasta,
              ),
            );
            setEstadoAsignaciones("listo");
          })
          .catch((e: Error) => setEstadoAsignaciones(e.message === "sin_permiso" ? "sin_permiso" : "error"));
      })
      .catch(() => setEstadoCarga("error"));
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  // Una persona puede tener 2 asignaciones activas en puestos distintos del mismo departamento
  // — se agrupa por persona_id para que aparezca una sola vez, con todos sus puestos.
  const personasAgrupadas = useMemo(() => {
    const mapa = new Map<string, PersonaAgrupada>();
    for (const a of asignaciones) {
      const existente = mapa.get(a.persona_id);
      if (existente) {
        existente.puestos.push(a.nombre_puesto);
      } else {
        mapa.set(a.persona_id, {
          persona_id: a.persona_id,
          persona_nombre: a.persona_nombre,
          puestos: [a.nombre_puesto],
        });
      }
    }
    return [...mapa.values()].sort((a, b) => a.persona_nombre.localeCompare(b.persona_nombre));
  }, [asignaciones]);

  const personasFiltradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    if (!consulta) return personasAgrupadas;
    return personasAgrupadas.filter((p) => normalizar(p.persona_nombre).includes(consulta));
  }, [personasAgrupadas, busqueda]);

  const desglosePorPuesto = useMemo(() => {
    const conteo = new Map<string, number>();
    for (const a of asignaciones) {
      conteo.set(a.nombre_puesto, (conteo.get(a.nombre_puesto) ?? 0) + 1);
    }
    return [...conteo.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  }, [asignaciones]);

  async function handleRenombrar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setGuardando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch(`/api/departamentos/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ nombre_departamento: f.get("nombre_departamento") }),
    });
    if (!respuesta.ok) {
      if (respuesta.status === 409) {
        setError("Ya existe un departamento con ese nombre.");
      } else {
        setError(await mensajeDeError(respuesta, "No se pudo guardar el cambio."));
      }
      setGuardando(false);
      return;
    }
    setDepartamento(await respuesta.json());
    setGuardando(false);
  }

  async function handleEstado(nuevoActivo: boolean) {
    setError(null);
    setCambiandoEstado(true);
    const respuesta = await apiFetch(`/api/departamentos/${id}/estado`, {
      method: "PATCH",
      body: JSON.stringify({ activo: nuevoActivo }),
    });
    if (!respuesta.ok) {
      if (respuesta.status === 400 || respuesta.status === 422) {
        setError(
          "No se pudo cambiar el estado: revisa que el área esté activa y que no tenga puestos activos debajo.",
        );
      } else {
        setError(await mensajeDeError(respuesta, "No se pudo cambiar el estado del departamento."));
      }
      setCambiandoEstado(false);
      return;
    }
    setDepartamento(await respuesta.json());
    setCambiandoEstado(false);
  }

  if (estadoCarga === "cargando") {
    return (
      <AppShell>
        <p className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          <span className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando…
          </span>
        </p>
      </AppShell>
    );
  }

  if (estadoCarga === "error" || !departamento) {
    return (
      <AppShell>
        <div className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar este departamento
            </strong>
            <p>Ocurrió un problema al consultar el catálogo.</p>
            <button type="button" onClick={cargar}>
              Reintentar
            </button>
          </div>
        </div>
      </AppShell>
    );
  }

  return (
    <AppShell>
      {/* Toda la página en el contenedor ancho (igual que AsignacionesPage/PermisosPage/
          BitacoraAsignacionesPersonaPage, los otros consumidores de .layout-bitacora): dentro
          del angosto de 720px la columna lateral "Por puesto" quedaba apretada y partía el
          texto largo del puesto en dos líneas, empujando su chip de conteo a una tercera. Las
          tarjetas de abajo (Área/Nombre/Fechas) se quedan en el mismo contenedor y en fila
          (.rejilla-tarjetas) para no quedar descolgadas y desalineadas contra este ancho. */}
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/estructura/departamentos">Departamentos</a> /{" "}
          <strong>{departamento.nombre_departamento}</strong>
        </nav>

        <div className="cabecera-persona cabecera-ficha">
          <div className="identidad">
            <div className="fila-nombre-badge">
              <strong>{departamento.nombre_departamento}</strong>
              <Badge estado={departamento.activo ? "activo" : "baja_definitiva"}>
                {departamento.activo ? "Activo" : "Inactivo"}
              </Badge>
            </div>
          </div>
          <div className="botonera">
            {departamento.activo ? (
              <Button
                type="button"
                onClick={() => handleEstado(false)}
                cargando={cambiandoEstado}
                textoCargando="Desactivando…"
              >
                Desactivar departamento
              </Button>
            ) : (
              <Button
                type="button"
                onClick={() => handleEstado(true)}
                variante="primario"
                cargando={cambiandoEstado}
                textoCargando="Reactivando…"
              >
                Reactivar departamento
              </Button>
            )}
          </div>
        </div>

        {error && <p role="alert">{error}</p>}

        <div className="layout-bitacora">
          <Card>
            <h3>Personas del departamento</h3>
            {estadoAsignaciones === "sin_permiso" && (
              <p>No tienes permiso para ver las personas de este departamento.</p>
            )}
            {estadoAsignaciones === "error" && (
              <p>No se pudieron cargar las personas de este departamento.</p>
            )}
            {estadoAsignaciones === "cargando" && (
              <p className="boton-con-icono">
                <Loader2 size={14} className="icono-girando" aria-hidden="true" />
                Cargando personas…
              </p>
            )}
            {estadoAsignaciones === "listo" && (
              <>
                <div className="campo-con-icono">
                  <Search size={16} className="icono-campo" aria-hidden="true" />
                  <input
                    type="search"
                    placeholder="Buscar por nombre"
                    value={busqueda}
                    onChange={(evento) => setBusqueda(evento.target.value)}
                    aria-label="Buscar por nombre"
                  />
                </div>
                {personasAgrupadas.length === 0 && (
                  <p>Este departamento no tiene personas asignadas actualmente.</p>
                )}
                {personasAgrupadas.length > 0 && personasFiltradas.length === 0 && (
                  <p>Ninguna persona coincide con la búsqueda.</p>
                )}
                {personasFiltradas.length > 0 && (
                  <ul className="lista-historial-resumido lista-desplazable">
                    {personasFiltradas.map((persona) => (
                      <li key={persona.persona_id}>
                        <a className="persona-celda" href={`/personas/${persona.persona_id}`}>
                          <span className="avatar-iniciales">{inicialesDe(persona.persona_nombre)}</span>
                          {persona.persona_nombre}
                        </a>
                        <span className="autor-historial">{persona.puestos.join(", ")}</span>
                      </li>
                    ))}
                  </ul>
                )}
              </>
            )}
          </Card>

          <aside>
            <Card>
              <h3>Resumen</h3>
              <div className="rejilla-resumen">
                <div>
                  <strong>{estadoPuestos === "listo" ? puestosActivos : "—"}</strong>
                  <span>Puestos activos</span>
                </div>
                <div>
                  <strong>{estadoAsignaciones === "listo" ? personasAgrupadas.length : "—"}</strong>
                  <span>Personas asignadas</span>
                </div>
              </div>
              {estadoPuestos === "sin_permiso" && (
                <small className="ayuda-campo">Sin permiso para ver puestos.</small>
              )}
              {estadoPuestos === "error" && (
                <small className="ayuda-campo">No se pudo cargar el conteo de puestos.</small>
              )}
            </Card>

            <Card>
              <h3>Por puesto</h3>
              {estadoAsignaciones === "sin_permiso" && (
                <p>No tienes permiso para ver el desglose por puesto.</p>
              )}
              {estadoAsignaciones === "error" && <p>No se pudo cargar el desglose por puesto.</p>}
              {estadoAsignaciones === "listo" && desglosePorPuesto.length === 0 && (
                <p>Sin personas asignadas por puesto todavía.</p>
              )}
              {estadoAsignaciones === "listo" && desglosePorPuesto.length > 0 && (
                <ul className="lista-historial-resumido">
                  {desglosePorPuesto.map(([nombrePuesto, cantidad]) => (
                    <li key={nombrePuesto}>
                      <span>{nombrePuesto}</span>
                      <Badge variante="neutra">{cantidad}</Badge>
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          </aside>
        </div>

        {/* Misma sección ancha de arriba, no un contenedor angosto aparte: 3 tarjetas chicas
            centradas en 720px quedaban descolgadas y desalineadas contra el borde izquierdo
            de "Personas del departamento" — puestas en fila acá comparten el mismo borde y
            usan el ancho sobrante en vez de dejarlo vacío alrededor. */}
        <div className="rejilla-tarjetas">
          <Card>
            <h3>Área</h3>
            <div className="dato">
              <span>Área a la que pertenece</span>
              <strong>{nombreArea ?? "—"}</strong>
            </div>
          </Card>

          <Card as="form" onSubmit={handleRenombrar}>
            <h3>Nombre del departamento</h3>
            <Input
              id="nombre_departamento"
              name="nombre_departamento"
              label="Nombre"
              required
              maxLength={100}
              defaultValue={departamento.nombre_departamento}
            />
            <div className="botonera">
              <Button type="submit" cargando={guardando} textoCargando="Guardando…">
                Guardar
              </Button>
            </div>
          </Card>

          <Card>
            <h3>Fechas</h3>
            <div className="rejilla-datos">
              <div className="dato">
                <span>Creado el</span>
                <strong>{formatearFecha(departamento.creado_en)}</strong>
              </div>
              <div className="dato">
                <span>Última actualización</span>
                <strong>{formatearFecha(departamento.actualizado_en)}</strong>
              </div>
            </div>
          </Card>
        </div>
      </div>
    </AppShell>
  );
}
