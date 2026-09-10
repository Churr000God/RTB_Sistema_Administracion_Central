import { Fragment, useEffect, useMemo, useState } from "react";
import { AlertCircle, Loader2, Search } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Input } from "../components/Input";

type Tipo = "entero" | "hora";

type ParametroVigente = {
  clave: string;
  valor: string;
  vigente_desde: string;
  etiqueta: string;
  descripcion: string;
  tipo: Tipo;
  unidad: string | null;
  impacta_logica: boolean;
  nota: string | null;
};

type ParametroHistorialItem = {
  id: number;
  clave: string;
  etiqueta: string;
  valor: string;
  vigente_desde: string;
  vigente_hasta: string | null;
  registrado_por: string | null;
  nombre_registrado_por: string | null;
};

type EstadoCarga = "cargando" | "listo" | "error";

type Orden = "fecha_desc" | "fecha_asc" | "parametro_asc" | "parametro_desc";

type Confirmacion = {
  clave: string;
  etiqueta: string;
  valorAnterior: string;
  unidad: string | null;
  valorNuevo: string;
};

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function formatearFecha(fecha?: string | null): string {
  if (!fecha) return "—";
  const valor = new Date(`${fecha}T00:00:00`);
  if (Number.isNaN(valor.getTime())) return "—";
  return valor.toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" });
}

function formatearValor(valor: string, unidad: string | null): string {
  return unidad ? `${valor} ${unidad}` : valor;
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

export function ParametrosSistemaPage() {
  const [vigentes, setVigentes] = useState<ParametroVigente[]>([]);
  const [estadoVigentes, setEstadoVigentes] = useState<EstadoCarga>("cargando");

  const [historial, setHistorial] = useState<ParametroHistorialItem[]>([]);
  const [estadoHistorial, setEstadoHistorial] = useState<EstadoCarga>("cargando");

  const [editandoClave, setEditandoClave] = useState<string | null>(null);
  const [valorEditado, setValorEditado] = useState("");
  const [confirmacion, setConfirmacion] = useState<Confirmacion | null>(null);
  const [errorEdicion, setErrorEdicion] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);

  const [busqueda, setBusqueda] = useState("");
  const [filtroDesde, setFiltroDesde] = useState("");
  const [filtroHasta, setFiltroHasta] = useState("");
  const [orden, setOrden] = useState<Orden>("fecha_desc");

  function cargarVigentes() {
    setEstadoVigentes("cargando");
    apiFetch("/api/parametros")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: ParametroVigente[]) => {
        setVigentes(datos);
        setEstadoVigentes("listo");
      })
      .catch(() => setEstadoVigentes("error"));
  }

  useEffect(cargarVigentes, []);

  function cargarHistorial() {
    setEstadoHistorial("cargando");
    apiFetch("/api/parametros/historial")
      .then((respuesta) => {
        if (!respuesta.ok) throw new Error(`status ${respuesta.status}`);
        return respuesta.json();
      })
      .then((datos: ParametroHistorialItem[]) => {
        setHistorial(datos);
        setEstadoHistorial("listo");
      })
      .catch(() => setEstadoHistorial("error"));
  }

  useEffect(cargarHistorial, []);

  function iniciarEdicion(fila: ParametroVigente) {
    setEditandoClave(fila.clave);
    setValorEditado(fila.valor);
    setErrorEdicion(null);
  }

  function cancelarEdicion() {
    setEditandoClave(null);
    setValorEditado("");
    setErrorEdicion(null);
  }

  function pedirConfirmacion(fila: ParametroVigente) {
    setConfirmacion({
      clave: fila.clave,
      etiqueta: fila.etiqueta,
      valorAnterior: fila.valor,
      unidad: fila.unidad,
      valorNuevo: valorEditado,
    });
    setEditandoClave(null);
    setErrorEdicion(null);
  }

  function cancelarConfirmacion() {
    setConfirmacion(null);
    setErrorEdicion(null);
  }

  async function confirmarGuardado() {
    if (!confirmacion) return;
    setGuardando(true);
    try {
      const respuesta = await apiFetch(`/api/parametros/${confirmacion.clave}`, {
        method: "PUT",
        body: JSON.stringify({ valor: confirmacion.valorNuevo }),
      });
      if (!respuesta.ok) {
        // Igual que en DiasFestivosPage: un rechazo 4xx no cierra la confirmación, muestra el
        // motivo para que la persona decida corregir o cancelar.
        setErrorEdicion(await mensajeDeError(respuesta, "No se pudo guardar el nuevo valor."));
        return;
      }
      setConfirmacion(null);
      setErrorEdicion(null);
      cargarVigentes();
      cargarHistorial();
    } catch {
      setErrorEdicion("No se pudo guardar el nuevo valor. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setGuardando(false);
    }
  }

  const hayFiltrosActivos = !!(busqueda || filtroDesde || filtroHasta);

  function limpiarFiltros() {
    setBusqueda("");
    setFiltroDesde("");
    setFiltroHasta("");
  }

  const historialFiltrado = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    const desde = filtroDesde ? new Date(`${filtroDesde}T00:00:00`) : null;
    const hasta = filtroHasta ? new Date(`${filtroHasta}T23:59:59`) : null;

    const resultado = historial.filter((fila) => {
      const coincideBusqueda =
        !consulta ||
        normalizar(fila.etiqueta).includes(consulta) ||
        normalizar(fila.clave).includes(consulta);
      const fechaVigenciaDesde = new Date(`${fila.vigente_desde}T00:00:00`);
      const coincideDesde = !desde || fechaVigenciaDesde >= desde;
      const coincideHasta = !hasta || fechaVigenciaDesde <= hasta;
      return coincideBusqueda && coincideDesde && coincideHasta;
    });

    return resultado.sort((a, b) => {
      switch (orden) {
        case "fecha_asc":
          return a.vigente_desde.localeCompare(b.vigente_desde);
        case "parametro_asc":
          return a.etiqueta.localeCompare(b.etiqueta);
        case "parametro_desc":
          return b.etiqueta.localeCompare(a.etiqueta);
        case "fecha_desc":
        default:
          return b.vigente_desde.localeCompare(a.vigente_desde);
      }
    });
  }, [historial, busqueda, filtroDesde, filtroHasta, orden]);

  return (
    <AppShell>
      <div className="contenedor-pagina contenedor-pagina--ancho">
        <nav className="migas">
          <strong>Parámetros del sistema</strong>
        </nav>
        <div className="encabezado-pagina">
          <div>
            <h1>Parámetros del sistema</h1>
            <p className="subtitulo-pagina">
              Valores de operación del subsistema Tiempo y su historial de cambios.
            </p>
          </div>
        </div>

        <Card>
          <h3>Valores vigentes</h3>
          {estadoVigentes === "cargando" && (
            <p className="boton-con-icono">
              <Loader2 size={16} className="icono-girando" aria-hidden="true" />
              Cargando…
            </p>
          )}
          {estadoVigentes === "error" && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se pudo cargar los parámetros vigentes
              </strong>
              <button type="button" onClick={cargarVigentes}>
                Reintentar
              </button>
            </div>
          )}
          {estadoVigentes === "listo" && (
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Parámetro</th>
                    <th>Valor</th>
                    <th>Vigente desde</th>
                    <th>Aviso</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {vigentes.map((fila) => {
                    const enEdicion = editandoClave === fila.clave;
                    const enConfirmacion = confirmacion?.clave === fila.clave;
                    return (
                      <Fragment key={fila.clave}>
                        <tr>
                          <td>
                            {fila.etiqueta}
                            {fila.descripcion && (
                              <p className="ayuda-campo">{fila.descripcion}</p>
                            )}
                          </td>
                          <td>
                            {enEdicion ? (
                              <input
                                type={fila.tipo === "hora" ? "time" : "number"}
                                min={fila.tipo === "entero" ? 1 : undefined}
                                value={valorEditado}
                                onChange={(evento) => setValorEditado(evento.target.value)}
                                aria-label={`Nuevo valor para ${fila.etiqueta}`}
                              />
                            ) : (
                              formatearValor(fila.valor, fila.unidad)
                            )}
                          </td>
                          <td>{formatearFecha(fila.vigente_desde)}</td>
                          <td>
                            <div className="grupo-insignias">
                              {!fila.impacta_logica && (
                                <Badge variante="neutra">Sin efecto en la lógica actual</Badge>
                              )}
                              {fila.nota && <Badge variante="aviso">{fila.nota}</Badge>}
                            </div>
                          </td>
                          <td>
                            {enEdicion ? (
                              <div className="botonera">
                                <Button type="button" onClick={cancelarEdicion}>
                                  Cancelar
                                </Button>
                                <Button
                                  type="button"
                                  variante="primario"
                                  onClick={() => pedirConfirmacion(fila)}
                                >
                                  Guardar
                                </Button>
                              </div>
                            ) : (
                              <Button type="button" onClick={() => iniciarEdicion(fila)}>
                                Editar
                              </Button>
                            )}
                          </td>
                        </tr>
                        {enConfirmacion && confirmacion && (
                          <tr>
                            <td colSpan={5}>
                              <p role="alert">
                                ¿Cambiar <strong>{confirmacion.etiqueta}</strong> de{" "}
                                {formatearValor(confirmacion.valorAnterior, confirmacion.unidad)} a{" "}
                                {formatearValor(confirmacion.valorNuevo, confirmacion.unidad)}?
                              </p>
                              {errorEdicion && <p role="alert">{errorEdicion}</p>}
                              <div className="botonera">
                                <Button type="button" onClick={cancelarConfirmacion}>
                                  Cancelar
                                </Button>
                                <Button
                                  type="button"
                                  variante="primario"
                                  cargando={guardando}
                                  textoCargando="Guardando…"
                                  onClick={confirmarGuardado}
                                >
                                  Sí, guardar
                                </Button>
                              </div>
                            </td>
                          </tr>
                        )}
                      </Fragment>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </Card>

        <Card>
          <h3>Historial de cambios</h3>

          {estadoHistorial === "listo" && historial.length > 0 && (
            <div className="barra-filtros">
              <div className="campo-con-icono">
                <Search size={16} className="icono-campo" aria-hidden="true" />
                <input
                  type="search"
                  placeholder="Buscar por parámetro"
                  value={busqueda}
                  onChange={(evento) => setBusqueda(evento.target.value)}
                  aria-label="Buscar por parámetro"
                />
              </div>
              <div className="grupo-filtros-secundarios">
                <Input
                  id="filtro-vigencia-desde"
                  label="Vigente desde"
                  type="date"
                  value={filtroDesde}
                  onChange={(evento) => setFiltroDesde(evento.target.value)}
                />
                <Input
                  id="filtro-vigencia-hasta"
                  label="Vigente hasta"
                  type="date"
                  value={filtroHasta}
                  onChange={(evento) => setFiltroHasta(evento.target.value)}
                />
                <select
                  value={orden}
                  onChange={(evento) => setOrden(evento.target.value as Orden)}
                  aria-label="Ordenar por"
                >
                  <option value="fecha_desc">Vigencia: más recientes primero</option>
                  <option value="fecha_asc">Vigencia: más antiguas primero</option>
                  <option value="parametro_asc">Parámetro (A-Z)</option>
                  <option value="parametro_desc">Parámetro (Z-A)</option>
                </select>
              </div>
            </div>
          )}

          {estadoHistorial === "cargando" && (
            <p className="boton-con-icono">
              <Loader2 size={16} className="icono-girando" aria-hidden="true" />
              Cargando…
            </p>
          )}

          {estadoHistorial === "error" && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se pudo cargar el historial de parámetros
              </strong>
              <button type="button" onClick={cargarHistorial}>
                Reintentar
              </button>
            </div>
          )}

          {estadoHistorial === "listo" && historial.length === 0 && (
            <div className="estado-vacio">
              <p>No hay cambios registrados todavía.</p>
            </div>
          )}

          {estadoHistorial === "listo" && historial.length > 0 && historialFiltrado.length === 0 && (
            <div className="estado-vacio">
              <p>Ningún cambio coincide con los filtros.</p>
              {hayFiltrosActivos && (
                <Button type="button" onClick={limpiarFiltros}>
                  Limpiar filtros
                </Button>
              )}
            </div>
          )}

          {estadoHistorial === "listo" && historialFiltrado.length > 0 && (
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Parámetro</th>
                    <th>Valor</th>
                    <th>Vigente desde</th>
                    <th>Vigente hasta</th>
                    <th>Modificado por</th>
                  </tr>
                </thead>
                <tbody>
                  {historialFiltrado.map((fila) => (
                    <tr key={fila.id}>
                      <td>{fila.etiqueta}</td>
                      <td>{fila.valor}</td>
                      <td>{formatearFecha(fila.vigente_desde)}</td>
                      <td>
                        {fila.vigente_hasta ? (
                          formatearFecha(fila.vigente_hasta)
                        ) : (
                          <Badge variante="exito">Vigente</Badge>
                        )}
                      </td>
                      <td>{fila.nombre_registrado_por ?? "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      </div>
    </AppShell>
  );
}
