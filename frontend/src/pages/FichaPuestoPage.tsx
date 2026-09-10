import { type FormEvent, useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertCircle, Loader2, Plus, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Badge } from "../components/Badge";
import { Input } from "../components/Input";

type PuestoPermiso = {
  id: string;
  puesto_id: string;
  codigo: string;
  activo: boolean;
};

type Puesto = {
  id: string;
  departamento_id: string;
  nombre_puesto: string;
  nivel: string;
  plazas_totales: number;
  reporta_a_id: string | null;
  activo: boolean;
  creado_en: string;
  actualizado_en: string;
};

type Asignacion = {
  persona_id: string;
  persona_nombre: string;
  puesto_id: string;
  vigente_desde: string;
  vigente_hasta: string | null;
};

type EstadoCarga = "cargando" | "listo" | "error";
type EstadoCatalogo = "cargando" | "listo" | "error" | "sin_permiso";

const NIVELES = [
  { value: "direccion", label: "Dirección" },
  { value: "gerencia", label: "Gerencia" },
  { value: "mando_medio", label: "Mando medio" },
  { value: "operativo", label: "Operativo" },
];

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

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

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function FichaPuestoPage() {
  const { id } = useParams<{ id: string }>();
  const [puesto, setPuesto] = useState<Puesto | null>(null);
  const [nombreDepartamento, setNombreDepartamento] = useState<string | null>(null);
  const [nombreSuperior, setNombreSuperior] = useState<string | null>(null);
  const [permisos, setPermisos] = useState<PuestoPermiso[]>([]);
  const [estadoPermisos, setEstadoPermisos] = useState<EstadoCatalogo>("cargando");
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [asignaciones, setAsignaciones] = useState<Asignacion[]>([]);
  const [estadoAsignaciones, setEstadoAsignaciones] = useState<EstadoCatalogo>("cargando");
  const [busqueda, setBusqueda] = useState("");
  const [busquedaPermisos, setBusquedaPermisos] = useState("");
  const [guardando, setGuardando] = useState(false);
  const [cambiandoEstado, setCambiandoEstado] = useState(false);

  function cargar() {
    setEstadoCarga("cargando");
    apiFetch(`/api/puestos/${id}`)
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datosPuesto: Puesto) => {
        setPuesto(datosPuesto);
        setEstadoCarga("listo");

        apiFetch(`/api/departamentos/${datosPuesto.departamento_id}`)
          .then((r) => (r.ok ? r.json() : null))
          .then((datos: { nombre_departamento: string } | null) =>
            setNombreDepartamento(datos?.nombre_departamento ?? null),
          )
          .catch(() => setNombreDepartamento(null));

        if (datosPuesto.reporta_a_id) {
          apiFetch(`/api/puestos/${datosPuesto.reporta_a_id}`)
            .then((r) => (r.ok ? r.json() : null))
            .then((datos: { nombre_puesto: string } | null) =>
              setNombreSuperior(datos?.nombre_puesto ?? null),
            )
            .catch(() => setNombreSuperior(null));
        } else {
          setNombreSuperior(null);
        }

        // Estado de carga independiente del principal: si esto falla, la ficha degrada a "sin
        // permisos" en vez de romperse, mismo criterio que nombreDepartamento/nombreSuperior.
        // /vigentes es el estado actual (con activo real) -- /otorgados es la bitácora de
        // eventos, no sirve para saber qué tiene el puesto ahora mismo.
        setEstadoPermisos("cargando");
        apiFetch("/api/permisos/vigentes")
          .then((r) => {
            if (r.status === 403) throw new Error("sin_permiso");
            if (!r.ok) throw new Error(`status ${r.status}`);
            return r.json();
          })
          .then((datos: PuestoPermiso[]) => {
            setPermisos(datos.filter((p) => p.puesto_id === id && p.activo));
            setEstadoPermisos("listo");
          })
          .catch((e: Error) => setEstadoPermisos(e.message === "sin_permiso" ? "sin_permiso" : "error"));

        // Gate propio (asignacion_lectura/edicion), distinto del puesto_lectura/edicion que ya
        // exige esta página — se pide y degrada por separado, mismo criterio que FichaDepartamentoPage.
        setEstadoAsignaciones("cargando");
        apiFetch("/api/asignaciones")
          .then((r) => {
            if (r.status === 403) throw new Error("sin_permiso");
            if (!r.ok) throw new Error(`status ${r.status}`);
            return r.json();
          })
          .then((datosAsignaciones: Asignacion[]) => {
            setAsignaciones(
              datosAsignaciones.filter((a) => a.puesto_id === datosPuesto.id && !a.vigente_hasta),
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

  const asignacionesOrdenadas = useMemo(
    () => [...asignaciones].sort((a, b) => a.persona_nombre.localeCompare(b.persona_nombre)),
    [asignaciones],
  );

  const asignacionesFiltradas = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    if (!consulta) return asignacionesOrdenadas;
    return asignacionesOrdenadas.filter((a) => normalizar(a.persona_nombre).includes(consulta));
  }, [asignacionesOrdenadas, busqueda]);

  const permisosFiltrados = useMemo(() => {
    const consulta = normalizar(busquedaPermisos.trim());
    if (!consulta) return permisos;
    return permisos.filter((p) => normalizar(p.codigo).includes(consulta));
  }, [permisos, busquedaPermisos]);

  async function handleGuardar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setGuardando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch(`/api/puestos/${id}`, {
      method: "PATCH",
      body: JSON.stringify({
        nombre_puesto: f.get("nombre_puesto"),
        nivel: f.get("nivel"),
        plazas_totales: Number(f.get("plazas_totales")),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo guardar el cambio."));
      setGuardando(false);
      return;
    }
    setPuesto(await respuesta.json());
    setGuardando(false);
  }

  async function handleEstado(nuevoActivo: boolean) {
    setError(null);
    setCambiandoEstado(true);
    const respuesta = await apiFetch(`/api/puestos/${id}/estado`, {
      method: "PATCH",
      body: JSON.stringify({ activo: nuevoActivo }),
    });
    if (!respuesta.ok) {
      // A diferencia de área/departamento, acá el 422 SÍ es una regla real que puede
      // dispararse siempre (subordinados activos, o departamento/superior inactivo al
      // reactivar) — se muestra el detail que manda el backend, no un genérico inventado.
      setError(await mensajeDeError(respuesta, "No se pudo cambiar el estado del puesto."));
      setCambiandoEstado(false);
      return;
    }
    setPuesto(await respuesta.json());
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

  if (estadoCarga === "error" || !puesto) {
    return (
      <AppShell>
        <div className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar este puesto
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

  const plazasOcupadas = estadoAsignaciones === "listo" ? asignaciones.length : null;

  return (
    <AppShell>
      {/* Ancho, igual que FichaDepartamentoPage: la tabla de personas es el contenido
          principal (dos columnas vía .layout-bitacora), Resumen/Permisos al costado, y
          Ubicación/Datos/Fechas abajo en fila (.rejilla-tarjetas) — mismo patrón ya aprobado
          ahí, para que las dos fichas de Estructura Organizacional se sientan consistentes. */}
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <a href="/estructura/puestos">Puestos</a> / <strong>{puesto.nombre_puesto}</strong>
        </nav>

        <div className="cabecera-persona cabecera-ficha">
          <div className="identidad">
            <div className="fila-nombre-badge">
              <strong>{puesto.nombre_puesto}</strong>
              <Badge estado={puesto.activo ? "activo" : "baja_definitiva"}>
                {puesto.activo ? "Activo" : "Inactivo"}
              </Badge>
            </div>
          </div>
          <div className="botonera">
            {puesto.activo ? (
              <Button
                type="button"
                onClick={() => handleEstado(false)}
                cargando={cambiandoEstado}
                textoCargando="Desactivando…"
              >
                Desactivar puesto
              </Button>
            ) : (
              <Button
                type="button"
                onClick={() => handleEstado(true)}
                variante="primario"
                cargando={cambiandoEstado}
                textoCargando="Reactivando…"
              >
                Reactivar puesto
              </Button>
            )}
          </div>
        </div>

        {error && <p role="alert">{error}</p>}

        <div className="layout-bitacora">
          <Card>
            <h3>Personas asignadas a este puesto</h3>
            {estadoAsignaciones === "sin_permiso" && (
              <p>No tienes permiso para ver las personas asignadas a este puesto.</p>
            )}
            {estadoAsignaciones === "error" && (
              <p>No se pudieron cargar las personas asignadas a este puesto.</p>
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
                {asignacionesOrdenadas.length === 0 && (
                  <p>Este puesto no tiene personas asignadas actualmente.</p>
                )}
                {asignacionesOrdenadas.length > 0 && asignacionesFiltradas.length === 0 && (
                  <p>Ninguna persona coincide con la búsqueda.</p>
                )}
                {asignacionesFiltradas.length > 0 && (
                  <div className="tabla-desplazable bloque-desplazable">
                    <table>
                      <thead>
                        <tr>
                          <th>Nombre</th>
                          <th>Vigente desde</th>
                        </tr>
                      </thead>
                      <tbody>
                        {asignacionesFiltradas.map((asignacion) => (
                          <tr key={asignacion.persona_id}>
                            <td>
                              <a className="persona-celda" href={`/personas/${asignacion.persona_id}`}>
                                <span className="avatar-iniciales">
                                  {inicialesDe(asignacion.persona_nombre)}
                                </span>
                                {asignacion.persona_nombre}
                              </a>
                            </td>
                            <td>{formatearFecha(asignacion.vigente_desde)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </>
            )}
          </Card>

          <aside>
            <Card>
              <h3>Resumen</h3>
              <div className="rejilla-resumen">
                <div>
                  <strong>
                    {plazasOcupadas ?? "—"}/{puesto.plazas_totales}
                  </strong>
                  <span>Plazas ocupadas</span>
                </div>
                <div>
                  <strong>{estadoPermisos === "listo" ? permisos.length : "—"}</strong>
                  <span>Permisos activos</span>
                </div>
              </div>
            </Card>

            <Card>
              <div className="fila-cabecera-tarjeta">
                <h3>Permisos de este puesto</h3>
                <Button
                  href={`/estructura/permisos/otorgar?puesto_id=${puesto.id}`}
                  className="enlace-etiqueta"
                  icono={Plus}
                  posicionIcono="izquierda"
                  tamanoIcono={14}
                >
                  Otorgar permiso
                </Button>
              </div>
              {estadoPermisos === "sin_permiso" && (
                <p>No tienes permiso para ver los permisos de este puesto.</p>
              )}
              {estadoPermisos === "cargando" && (
                <p className="boton-con-icono">
                  <Loader2 size={14} className="icono-girando" aria-hidden="true" />
                  Cargando permisos…
                </p>
              )}
              {estadoPermisos === "error" && <p>No se pudieron cargar los permisos de este puesto.</p>}
              {estadoPermisos === "listo" && permisos.length === 0 && (
                <p>Este puesto no tiene permisos otorgados actualmente.</p>
              )}
              {estadoPermisos === "listo" && permisos.length > 0 && (
                <>
                  <div className="campo-con-icono">
                    <Search size={16} className="icono-campo" aria-hidden="true" />
                    <input
                      type="search"
                      placeholder="Buscar por nombre de permiso"
                      value={busquedaPermisos}
                      onChange={(evento) => setBusquedaPermisos(evento.target.value)}
                      aria-label="Buscar por nombre de permiso"
                    />
                  </div>
                  {permisosFiltrados.length === 0 && <p>Ningún permiso coincide con la búsqueda.</p>}
                  {permisosFiltrados.length > 0 && (
                    <ul className="lista-historial-resumido lista-desplazable">
                      {permisosFiltrados.map((permiso) => (
                        <li key={permiso.id}>
                          <span style={{ fontWeight: 600 }}>{permiso.codigo}</span>
                          <a href={`/estructura/permisos/${permiso.id}/revocar?puesto_id=${puesto.id}`}>
                            Revocar
                          </a>
                        </li>
                      ))}
                    </ul>
                  )}
                </>
              )}
            </Card>
          </aside>
        </div>

        <div className="rejilla-tarjetas">
          <Card>
            <h3>Ubicación en la estructura</h3>
            <div className="rejilla-datos">
              <div className="dato">
                <span>Departamento</span>
                <strong>{nombreDepartamento ?? "—"}</strong>
              </div>
              <div className="dato">
                <span>Reporta a</span>
                <strong>{puesto.reporta_a_id ? nombreSuperior ?? "—" : "— (puesto tope)"}</strong>
              </div>
            </div>
          </Card>

          <Card as="form" onSubmit={handleGuardar}>
            <h3>Datos del puesto</h3>
            <Input
              id="nombre_puesto"
              name="nombre_puesto"
              label="Nombre"
              required
              maxLength={100}
              defaultValue={puesto.nombre_puesto}
            />
            <div className="campo">
              <label htmlFor="nivel">Nivel</label>
              <select id="nivel" name="nivel" required defaultValue={puesto.nivel}>
                {NIVELES.map((nivel) => (
                  <option key={nivel.value} value={nivel.value}>
                    {nivel.label}
                  </option>
                ))}
              </select>
            </div>
            <Input
              id="plazas_totales"
              name="plazas_totales"
              label="Plazas totales"
              type="number"
              min={1}
              required
              defaultValue={puesto.plazas_totales}
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
                <strong>{formatearFecha(puesto.creado_en)}</strong>
              </div>
              <div className="dato">
                <span>Última actualización</span>
                <strong>{formatearFecha(puesto.actualizado_en)}</strong>
              </div>
            </div>
          </Card>
        </div>
      </div>
    </AppShell>
  );
}
