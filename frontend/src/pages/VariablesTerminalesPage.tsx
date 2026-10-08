import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Info, Loader2, Lock, Search } from "lucide-react";

import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { ConfiguracionTerminalesLayout } from "../components/ConfiguracionTerminalesLayout";
import { SinAccesoTerminales } from "../components/SinAccesoTerminales";
import { formatearFechaCorta } from "../lib/calendario";
import { ErrorApi, apiJson, codigoDe, mensajeDeNegocio } from "../lib/errorApi";
import { useSesion } from "../lib/useSesion";
import {
  CLAVE_CADUCIDAD,
  type SimulacionCaducidad,
  type VariableTerminal,
  type VigenciaVariable,
} from "../lib/terminales";

const RUTA = "/api/terminales/configuracion/variables";
const NOMBRES_VISIBLES = 5;
const MAX_NOMBRE = 50;

type Estado = "cargando" | "listo" | "error" | "sin_acceso";
type EstadoSimulacion = "cargando" | "listo" | "error";

type Edicion = {
  clave: string;
  texto: string;
  valorBase: number;
  errorCampo: string | null;
  guardando: boolean;
  // Se avisó que el valor vigente cambió mientras se editaba: se muestra el vigente actual junto al campo.
  huboConflicto: boolean;
  simulacion: { estado: EstadoSimulacion; datos: SimulacionCaducidad | null } | null;
};

type Aviso = { tipo: "exito" | "info"; texto: string };

function normalizar(texto: string): string {
  return texto
    .normalize("NFD")
    .replace(new RegExp("[\\u0300-\\u036f]", "g"), "")
    .toLowerCase();
}

function esVariables(datos: unknown): datos is VariableTerminal[] {
  return Array.isArray(datos) && datos.every((v) => v && typeof v.clave === "string" && typeof v.valor === "number");
}

function aEntero(texto: string): number | null {
  if (!/^-?\d+$/.test(texto.trim())) return null;
  return Number(texto.trim());
}

export function VariablesTerminalesPage() {
  const { sesion, cargando: cargandoSesion } = useSesion();
  const sinAccesoPorSesion = sesion?.puede_ver_terminales === false;
  const puedeEditar = sesion?.puede_editar_config_terminales === true;

  const [variables, setVariables] = useState<VariableTerminal[]>([]);
  const [historial, setHistorial] = useState<VigenciaVariable[]>([]);
  const [estado, setEstado] = useState<Estado>("cargando");
  const [edicion, setEdicion] = useState<Edicion | null>(null);
  const [alerta, setAlerta] = useState<string | null>(null);
  const [aviso, setAviso] = useState<Aviso | null>(null);
  const [busqueda, setBusqueda] = useState("");
  const [orden, setOrden] = useState<"recientes" | "variable">("recientes");

  const cargar = useCallback(() => {
    setEstado("cargando");
    Promise.all([
      apiJson<VariableTerminal[]>(RUTA),
      apiJson<VigenciaVariable[]>(`${RUTA}/historial`).catch(() => [] as VigenciaVariable[]),
    ])
      .then(([vars, hist]) => {
        if (!esVariables(vars)) throw new Error("forma inesperada");
        setVariables(vars);
        setHistorial(Array.isArray(hist) ? hist : []);
        setEstado("listo");
      })
      .catch((error) => setEstado(error instanceof ErrorApi && error.status === 403 ? "sin_acceso" : "error"));
  }, []);

  useEffect(() => {
    if (cargandoSesion || sinAccesoPorSesion) return;
    cargar();
  }, [cargandoSesion, sinAccesoPorSesion, cargar]);

  const porClave = useMemo(() => new Map(variables.map((v) => [v.clave, v])), [variables]);

  const historialVisible = useMemo(() => {
    const consulta = normalizar(busqueda.trim());
    const filtrado = historial.filter((fila) => {
      if (!consulta) return true;
      const etiqueta = porClave.get(fila.clave)?.etiqueta ?? fila.clave;
      return normalizar(`${etiqueta} ${fila.modificado_por_nombre ?? ""}`).includes(consulta);
    });
    if (orden === "variable") {
      return [...filtrado].sort((a, b) =>
        (porClave.get(a.clave)?.etiqueta ?? a.clave).localeCompare(porClave.get(b.clave)?.etiqueta ?? b.clave),
      );
    }
    return filtrado;
  }, [historial, busqueda, orden, porClave]);

  function empezarEdicion(variable: VariableTerminal) {
    setAlerta(null);
    setAviso(null);
    setEdicion({ clave: variable.clave, texto: String(variable.valor), valorBase: variable.valor, errorCampo: null, guardando: false, huboConflicto: false, simulacion: null });
  }

  // Valor entero dentro del rango del catálogo, o null (y el mensaje de campo).
  function validar(variable: VariableTerminal, texto: string): { valor: number } | { error: string } {
    const valor = aEntero(texto);
    if (valor === null || valor < variable.minimo || valor > variable.maximo) {
      return { error: `Debe ser un entero entre ${variable.minimo} y ${variable.maximo}.` };
    }
    return { valor };
  }

  const simular = useCallback(async (valor: number) => {
    setEdicion((e) => (e ? { ...e, simulacion: { estado: "cargando", datos: null } } : e));
    try {
      const datos = await apiJson<SimulacionCaducidad>(`${RUTA}/${CLAVE_CADUCIDAD}/simular`, {
        method: "POST",
        body: JSON.stringify({ valor }),
      });
      setEdicion((e) => (e ? { ...e, simulacion: { estado: "listo", datos } } : e));
    } catch {
      setEdicion((e) => (e ? { ...e, simulacion: { estado: "error", datos: null } } : e));
    }
  }, []);

  function revisarImpacto(variable: VariableTerminal) {
    if (!edicion) return;
    const r = validar(variable, edicion.texto);
    if ("error" in r) {
      setEdicion({ ...edicion, errorCampo: r.error });
      return;
    }
    setEdicion({ ...edicion, errorCampo: null });
    void simular(r.valor);
  }

  async function guardar(variable: VariableTerminal) {
    if (!edicion) return;
    const r = validar(variable, edicion.texto);
    if ("error" in r) {
      setEdicion({ ...edicion, errorCampo: r.error });
      return;
    }
    setAlerta(null);
    setEdicion({ ...edicion, errorCampo: null, guardando: true });
    try {
      const resp = await apiJson<{ resultado: "actualizada" | "sin_cambio"; clave: string; valor: number }>(
        `${RUTA}/${variable.clave}`,
        { method: "PATCH", body: JSON.stringify({ valor: r.valor, valor_base: edicion.valorBase }) },
      );
      setEdicion(null);
      setAviso(
        resp.resultado === "sin_cambio"
          ? { tipo: "info", texto: `${variable.etiqueta} ya tenía ese valor (${resp.valor} ${variable.unidad}); no se cambió nada.` }
          : { tipo: "exito", texto: `${variable.etiqueta} actualizada a ${resp.valor} ${variable.unidad}. Vigente desde hoy.` },
      );
      cargar();
    } catch (fallo) {
      const actual = fallo instanceof ErrorApi && fallo.status === 409 ? fallo.cuerpo?.valor_actual : undefined;
      if (typeof actual === "number") {
        // El valor cambió mientras se editaba: se muestra el vigente nuevo, se conserva lo escrito y
        // el siguiente guardado ya usa ese valor como base.
        setVariables((vs) => vs.map((v) => (v.clave === variable.clave ? { ...v, valor: actual } : v)));
        setAlerta(
          `${variable.etiqueta} cambió mientras la editabas: ahora es ${actual} ${variable.unidad} (tú viste ${edicion.valorBase}). Tu valor sigue en el campo; revisa si todavía lo quieres y vuelve a guardar.`,
        );
        setEdicion({ ...edicion, valorBase: actual, guardando: false, huboConflicto: true, simulacion: null });
        return;
      }
      if (codigoDe(fallo) === "valor_desactualizado") {
        // El servidor dice que cambió pero no mandó el valor: se recargan las variables y se conserva lo escrito.
        setAlerta(mensajeDeNegocio(fallo, "La variable cambió mientras la editabas; vuelve a leerla."));
        setEdicion({ ...edicion, guardando: false, simulacion: null });
        cargar();
        return;
      }
      setAlerta(mensajeDeNegocio(fallo, "No se pudo guardar. Inténtalo de nuevo."));
      setEdicion({ ...edicion, guardando: false });
    }
  }

  const sinAcceso = sinAccesoPorSesion || estado === "sin_acceso";

  return (
    <ConfiguracionTerminalesLayout activa="variables">
      {sinAcceso && <SinAccesoTerminales />}

      {!sinAcceso && estado === "cargando" && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando variables…
        </p>
      )}

      {!sinAcceso && estado === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudieron cargar las variables
          </strong>
          <p>Ocurrió un problema al consultar la configuración.</p>
          <Button onClick={cargar}>Reintentar</Button>
        </div>
      )}

      {!sinAcceso && estado === "listo" && (
        <>
          {!puedeEditar && (
            <div className="banner-aviso banner-aviso--info" role="note">
              <Lock size={16} aria-hidden="true" />
              <div>
                <strong>Puedes consultar las variables, no modificarlas.</strong> Cambiarlas requiere{" "}
                <span className="chip-permiso">terminal_config_edicion</span> (Gerente o Encargado de TI, Gerente
                General).
              </div>
            </div>
          )}

          {aviso && (
            <div className="banner-aviso banner-aviso--info" role="status">
              {aviso.tipo === "exito" ? <CheckCircle2 size={16} aria-hidden="true" /> : <Info size={16} aria-hidden="true" />}
              <div>{aviso.texto}</div>
            </div>
          )}

          {alerta && (
            <div className="tarjeta-error" role="alert">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                No se guardó
              </strong>
              <p>{alerta}</p>
            </div>
          )}

          <Card>
            <h3>Valores vigentes</h3>
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Variable</th>
                    <th>Valor</th>
                    <th>Unidad</th>
                    <th>Rango permitido</th>
                    <th>Vigente desde</th>
                    <th>Acción</th>
                  </tr>
                </thead>
                <tbody>
                  {variables.map((variable) => {
                    const editando = edicion?.clave === variable.clave ? edicion : null;
                    const esCaducidad = variable.clave === CLAVE_CADUCIDAD;
                    const propuesto = editando ? aEntero(editando.texto) : null;
                    const acortaCliente = esCaducidad && propuesto !== null && propuesto < variable.valor;
                    const sim = editando?.simulacion ?? null;
                    const acorta = acortaCliente || sim?.datos?.acorta === true;
                    const puedeConfirmar = !acorta || sim?.estado === "listo";
                    return (
                      <FilaVariable key={variable.clave}>
                        <tr className={editando ? "fila-editando" : undefined}>
                          <td>
                            <strong>{variable.etiqueta}</strong>
                            <p className="ayuda-campo">{variable.descripcion}</p>
                            {variable.valor_ilegible && (
                              <>
                                <Badge variante="aviso">Valor ilegible</Badge>
                                <p className="ayuda-campo">
                                  El valor guardado no se pudo leer; se muestra el valor por defecto.
                                </p>
                              </>
                            )}
                          </td>
                          <td className="num">
                            {editando ? (
                              <>
                                <input
                                  type="number"
                                  step={1}
                                  value={editando.texto}
                                  disabled={editando.guardando}
                                  aria-label={`${variable.etiqueta}, en ${variable.unidad}`}
                                  aria-invalid={editando.errorCampo ? true : undefined}
                                  style={{ width: "7rem" }}
                                  onChange={(evento) =>
                                    setEdicion({ ...editando, texto: evento.target.value, errorCampo: null, simulacion: null })
                                  }
                                />
                                {editando.errorCampo && <p className="mensaje-campo">{editando.errorCampo}</p>}
                                {editando.huboConflicto && <p className="rango">vigente actual: {variable.valor}</p>}
                              </>
                            ) : (
                              variable.valor
                            )}
                          </td>
                          <td>{variable.unidad}</td>
                          <td className="rango">
                            {variable.minimo} – {variable.maximo}
                          </td>
                          <td className="num">
                            {variable.vigente_desde ? formatearFechaCorta(variable.vigente_desde) : "valor por defecto"}
                          </td>
                          <td>
                            {puedeEditar &&
                              (editando ? (
                                <div className="botonera">
                                  <Button disabled={editando.guardando} onClick={() => setEdicion(null)}>
                                    Cancelar
                                  </Button>
                                  {esCaducidad ? (
                                    <Button variante="primario" disabled={editando.guardando || sim !== null} onClick={() => revisarImpacto(variable)}>
                                      Revisar impacto…
                                    </Button>
                                  ) : (
                                    <Button
                                      variante="primario"
                                      cargando={editando.guardando}
                                      textoCargando="Guardando…"
                                      onClick={() => guardar(variable)}
                                    >
                                      Guardar
                                    </Button>
                                  )}
                                </div>
                              ) : (
                                <Button disabled={edicion !== null} onClick={() => empezarEdicion(variable)}>
                                  {`Editar ${variable.etiqueta}`}
                                </Button>
                              ))}
                          </td>
                        </tr>
                        {editando && esCaducidad && sim && (
                          <tr>
                            <td colSpan={6}>
                              <PanelImpacto
                                sim={sim}
                                propuesto={propuesto ?? 0}
                                guardando={editando.guardando}
                                puedeConfirmar={puedeConfirmar}
                                acorta={acorta}
                                onVolver={() => setEdicion({ ...editando, simulacion: null })}
                                onReintentar={() => propuesto !== null && simular(propuesto)}
                                onConfirmar={() => guardar(variable)}
                              />
                            </td>
                          </tr>
                        )}
                      </FilaVariable>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <ul className="leyenda-estados" style={{ marginTop: "1rem" }}>
              <li>Un cambio rige desde <strong>hoy</strong> (no se agenda a futuro) y no reescribe el pasado.</li>
              <li>Un segundo cambio del mismo día reemplaza al primero.</li>
            </ul>
          </Card>

          <Card style={{ marginTop: "1.25rem" }}>
            <h3>Historial de cambios</h3>
            <div className="barra-filtros">
              <div className="campo-con-icono">
                <Search size={16} className="icono-campo" aria-hidden="true" />
                <input
                  type="search"
                  placeholder="Buscar por variable o persona"
                  aria-label="Buscar por variable o persona"
                  value={busqueda}
                  onChange={(evento) => setBusqueda(evento.target.value)}
                />
              </div>
              <div className="grupo-filtros-secundarios">
                <select aria-label="Ordenar por" value={orden} onChange={(evento) => setOrden(evento.target.value as "recientes" | "variable")}>
                  <option value="recientes">Más recientes primero</option>
                  <option value="variable">Variable (A-Z)</option>
                </select>
              </div>
            </div>
            {historial.length === 0 ? (
              <div className="estado-vacio">
                <p>Todavía no hay cambios registrados. Los valores iniciales son los del alta del módulo.</p>
              </div>
            ) : (
              <div className="tabla-desplazable">
                <table>
                  <thead>
                    <tr>
                      <th>Variable</th>
                      <th>Valor</th>
                      <th>Vigente desde</th>
                      <th>Vigente hasta</th>
                      <th>Modificado por</th>
                      <th>Estado</th>
                    </tr>
                  </thead>
                  <tbody>
                    {historialVisible.map((fila, indice) => {
                      const variable = porClave.get(fila.clave);
                      return (
                        <tr key={`${fila.clave}-${fila.vigente_desde}-${indice}`}>
                          <td>{variable?.etiqueta ?? fila.clave}</td>
                          <td className="num">
                            {fila.valor_ilegible ? (
                              <Badge variante="aviso">Valor ilegible</Badge>
                            ) : (
                              `${fila.valor}${variable ? ` ${variable.unidad}` : ""}`
                            )}
                          </td>
                          <td className="num">{formatearFechaCorta(fila.vigente_desde) ?? "—"}</td>
                          <td className="num">{fila.vigente_hasta ? formatearFechaCorta(fila.vigente_hasta) : "—"}</td>
                          <td>{fila.modificado_por_nombre ?? "—"}</td>
                          <td>
                            <Badge variante={fila.estado === "vigente" ? "exito" : "neutra"}>
                              {fila.estado === "vigente" ? "Vigente" : "Reemplazada"}
                            </Badge>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
    </ConfiguracionTerminalesLayout>
  );
}

// Agrupa la fila y su fila de impacto sin añadir un nodo al DOM de la tabla.
function FilaVariable({ children }: { children: React.ReactNode }) {
  return <>{children}</>;
}

function recortar(nombre: string | null): string {
  const limpio = nombre ?? "—";
  return limpio.length > MAX_NOMBRE ? `${limpio.slice(0, MAX_NOMBRE)}…` : limpio;
}

type PropsPanel = {
  sim: { estado: EstadoSimulacion; datos: SimulacionCaducidad | null };
  propuesto: number;
  guardando: boolean;
  puedeConfirmar: boolean;
  acorta: boolean;
  onVolver: () => void;
  onReintentar: () => void;
  onConfirmar: () => void;
};

// Impacto previo de cambiar la caducidad (aplica también a las altas ya en espera). Al ACORTAR, ver
// el impacto es obligatorio: «Confirmar» queda inerte hasta que el cálculo termine bien.
function PanelImpacto({ sim, propuesto, guardando, puedeConfirmar, acorta, onVolver, onReintentar, onConfirmar }: PropsPanel) {
  const datos = sim.datos;
  const total = datos?.altas_que_caducarian_ya_total ?? 0;
  const visibles = datos?.altas_que_caducarian_ya.slice(0, NOMBRES_VISIBLES) ?? [];
  const restantes = Math.max(0, total - visibles.length);
  return (
    <div className="panel-confirmar" role="alertdialog" aria-labelledby="impacto-titulo" style={acorta ? { borderColor: "#b3261e", background: "#fff" } : undefined}>
      <strong id="impacto-titulo" style={{ fontSize: "1rem" }}>
        Cambiar la caducidad a {propuesto} h
      </strong>
      <p style={{ margin: 0, fontSize: "0.88rem" }}>
        El cambio aplica desde hoy <strong>también a las altas que ya están esperando huella</strong>.
        {acorta && " Ver el impacto es obligatorio para poder confirmar."}
      </p>

      {sim.estado === "cargando" && (
        <p className="boton-con-icono" role="status" style={{ margin: 0 }}>
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Calculando cuántas altas se verían afectadas…
        </p>
      )}

      {sim.estado === "error" && (
        <div className="tarjeta-error" role="note">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo calcular el impacto
          </strong>
          <p>{acorta ? "Sin ver el impacto no se puede confirmar este cambio." : "Puedes confirmar sin verlo, pero conviene reintentar."}</p>
          <Button onClick={onReintentar}>Reintentar el cálculo</Button>
        </div>
      )}

      {sim.estado === "listo" && datos && datos.acorta && (
        <>
          <div className="banner-aviso" role="status" style={{ margin: 0 }}>
            <AlertTriangle size={16} aria-hidden="true" />
            <div>
              <strong>{total} altas caerían en la próxima corrida</strong> (de {datos.altas_en_espera} en «Esperando huella»)
              {visibles.length > 0 && <>: {visibles.map((a) => recortar(a.persona_nombre)).join(", ")}{restantes > 0 ? ` y ${restantes} más` : ""}</>}
              . Se pedirá su baja y el puente borrará su usuario del aparato.
            </div>
          </div>
          {datos.altas_por_caducar_nuevas > 0 && (
            <p className="rango" style={{ margin: 0 }}>
              {datos.altas_por_caducar_nuevas === 1
                ? "1 alta más quedará «por caducar» (menos de 1 h)."
                : `${datos.altas_por_caducar_nuevas} altas más quedarán «por caducar» (menos de 1 h).`}
            </p>
          )}
          {total > datos.tope_por_corrida && (
            <p className="rango" style={{ margin: 0 }}>
              La baja se procesa de a {datos.tope_por_corrida} por corrida (cada ~10 min).
            </p>
          )}
          <p className="rango" style={{ margin: 0 }}>
            Si alguna debe conservarse, enrola su huella antes de confirmar. Para volver a enrolar una caducada hay que
            asignarla de nuevo.
          </p>
        </>
      )}

      {sim.estado === "listo" && datos && !datos.acorta && (
        <div className="banner-aviso banner-aviso--info" role="status" style={{ margin: 0 }}>
          <Info size={16} aria-hidden="true" />
          <div>
            <strong>
              {datos.altas_que_ganan_plazo} de {datos.altas_en_espera} altas
            </strong>{" "}
            en «Esperando huella» ganan plazo. Ninguna alta cambia de estado ahora.
          </div>
        </div>
      )}

      <div className="botonera">
        <Button disabled={guardando} onClick={onVolver}>
          Volver
        </Button>
        <Button
          className={acorta ? "boton-peligro" : undefined}
          variante={acorta ? undefined : "primario"}
          cargando={guardando}
          textoCargando="Guardando…"
          disabled={!puedeConfirmar}
          onClick={onConfirmar}
        >
          {acorta && datos ? `Confirmar: ${total} altas caerán en la próxima corrida` : `Confirmar cambio a ${propuesto} h`}
        </Button>
      </div>
    </div>
  );
}
