import { useCallback, useEffect, useState } from "react";
import { AlertCircle, CheckCircle2, Info, Loader2 } from "lucide-react";

import { Badge } from "./Badge";
import { Button } from "./Button";
import { Modal } from "./Modal";
import { formatearHoraMexico } from "../lib/calendario";
import { ErrorApi, apiJson, codigoDe, mensajeDeNegocio } from "../lib/errorApi";
import {
  ETIQUETA_RAZON_NO_ELEGIBLE,
  esConflictoDeConsentimiento,
  esConsentimientoCompleto,
  MAX_LOTE_RECONSENTIMIENTO,
  type ConsentimientoVigente,
  type NoElegible,
  type RespuestaConsentimiento,
  type ResultadoReconsentimiento,
} from "../lib/terminales";

const RUTA_CONSENTIMIENTO = "/api/terminales/configuracion/consentimiento";
const MENSAJE_GENERICO = "No se pudo registrar. Inténtalo de nuevo.";
const NOMBRES_VISIBLES = 5;

type AltaElegida = { id: number; persona_nombre: string | null };

type Props = {
  terminalId: number;
  altas: AltaElegida[];
  // refrescar=true cuando la lista cambió (se registró, o hubo un 409 que la dejó vieja).
  onCerrar: (refrescar: boolean) => void;
};

type Fase = "editando" | "enviando" | "ok";

function formatearDesde(fecha: string): string {
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "—";
  return formatearHoraMexico(valor, { day: "2-digit", month: "short", year: "numeric" });
}

function noElegiblesDelCuerpo(error: ErrorApi): NoElegible[] | null {
  const lista = error.cuerpo?.no_elegibles;
  if (!Array.isArray(lista)) return null;
  return lista.filter((n): n is NoElegible => !!n && typeof n === "object" && typeof (n as NoElegible).tu_id === "number");
}

// Registra que existe el reconsentimiento FIRMADO de una o varias altas con el texto vigente. No
// reenrola huellas ni cambia estados. Todo o nada; máximo 200 por vez; la propia alta de quien
// registra no es elegible (lo decide el servidor, aquí sólo se explica).
export function ReconsentimientoModal({ terminalId, altas, onCerrar }: Props) {
  const ids = [...new Set(altas.map((a) => a.id))];
  const nombres = [...new Map(altas.map((a) => [a.id, a.persona_nombre ?? "—"])).values()];
  const esLote = ids.length > 1;
  const excede = ids.length > MAX_LOTE_RECONSENTIMIENTO;

  const [vigente, setVigente] = useState<ConsentimientoVigente | null>(null);
  const [estadoTexto, setEstadoTexto] = useState<"cargando" | "listo" | "error">("cargando");
  const [declarado, setDeclarado] = useState(false);
  const [faltaDeclarar, setFaltaDeclarar] = useState(false);
  const [fase, setFase] = useState<Fase>("editando");
  const [error, setError] = useState<string | null>(null);
  const [noElegibles, setNoElegibles] = useState<NoElegible[] | null>(null);
  const [conflicto, setConflicto] = useState(false);
  const [resultado, setResultado] = useState<ResultadoReconsentimiento | null>(null);

  const cargarTexto = useCallback(() => {
    setEstadoTexto("cargando");
    apiJson<RespuestaConsentimiento>(RUTA_CONSENTIMIENTO)
      .then((datos) => {
        setVigente(datos.vigente);
        setEstadoTexto("listo");
      })
      .catch(() => setEstadoTexto("error"));
  }, []);

  useEffect(() => {
    cargarTexto();
  }, [cargarTexto]);

  const enviando = fase === "enviando";

  async function registrar() {
    if (!declarado) {
      setFaltaDeclarar(true);
      return;
    }
    if (!vigente || excede) return;
    setFaltaDeclarar(false);
    setError(null);
    setNoElegibles(null);
    setFase("enviando");
    const ruta = esLote
      ? `/api/terminales/${terminalId}/usuarios/reconsentimientos`
      : `/api/terminales/${terminalId}/usuarios/${ids[0]}/reconsentimiento`;
    const cuerpo = esLote
      ? { tu_ids: ids, consentimiento_id: vigente.id, declaracion_documentos: true }
      : { consentimiento_id: vigente.id, declaracion_documentos: true };
    try {
      const r = await apiJson<ResultadoReconsentimiento>(ruta, { method: "POST", body: JSON.stringify(cuerpo) });
      setResultado(r);
      setFase("ok");
    } catch (fallo) {
      setFase("editando");
      if (fallo instanceof ErrorApi && fallo.status === 409) {
        const lista = noElegiblesDelCuerpo(fallo);
        const candidato = fallo.cuerpo?.consentimiento_vigente;
        if (lista || codigoDe(fallo) === "lote_no_elegible") {
          setNoElegibles(lista);
          setConflicto(true);
        } else if (esConflictoDeConsentimiento(fallo)) {
          // El texto cambió mientras estaba abierto: se toma el nuevo (si viene completo) o se vuelve a
          // leer, y se pide declarar otra vez.
          setDeclarado(false);
          if (esConsentimientoCompleto(candidato)) setVigente(candidato);
          else cargarTexto();
        } else {
          setConflicto(true);
        }
      }
      setError(mensajeDeNegocio(fallo, MENSAJE_GENERICO));
    }
  }

  if (fase === "ok") {
    const restantes = resultado?.pendientes_restantes;
    return (
      <Modal titulo={<><CheckCircle2 size={22} aria-hidden="true" /> Reconsentimiento registrado</>} onCancelar={() => onCerrar(true)}>
        <div role="status" style={{ display: "contents" }}>
          <p className="modal__contexto">
            Quedó registrado el reconsentimiento de <strong>{resultado?.registradas ?? ids.length} {(resultado?.registradas ?? ids.length) === 1 ? "alta" : "altas"}</strong>{" "}
            con el texto v{vigente?.version}. Su alta y su huella no cambian.
            {typeof restantes === "number" && ` Quedan ${restantes} pendientes.`}
          </p>
          {resultado?.omitidas && resultado.omitidas.length > 0 && (
            <p className="rango">{resultado.omitidas.length} altas se omitieron porque dejaron de ser elegibles mientras se registraba.</p>
          )}
        </div>
        <div className="modal__botonera">
          <Button variante="primario" onClick={() => onCerrar(true)}>
            Cerrar
          </Button>
        </div>
      </Modal>
    );
  }

  return (
    <Modal
      titulo="Registrar reconsentimiento"
      descripcion={
        esLote ? (
          <>
            Se registrará el reconsentimiento de <strong>{ids.length} personas</strong> ({nombres.slice(0, NOMBRES_VISIBLES).join(", ")}
            {nombres.length > NOMBRES_VISIBLES ? ` y ${nombres.length - NOMBRES_VISIBLES} más` : ""}) con el texto vigente.
          </>
        ) : (
          <>
            Se registrará el reconsentimiento de <strong>{nombres[0]}</strong> con el texto vigente.
          </>
        )
      }
      bloqueado={enviando}
      onCancelar={() => onCerrar(false)}
    >
      {estadoTexto === "cargando" && (
        <p className="boton-con-icono" role="status">
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Cargando el texto de consentimiento…
        </p>
      )}
      {estadoTexto === "error" && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se pudo cargar el texto de consentimiento
          </strong>
          <p>Sin el texto vigente no se puede registrar.</p>
          <Button onClick={cargarTexto}>Reintentar</Button>
        </div>
      )}

      {estadoTexto === "listo" && vigente && (
        <>
          <div className="vista-previa" style={{ background: "#fff" }}>
            <h4>
              Texto de la versión {vigente.version}
              {vigente.cambio_material ? " · cambio material" : ""} · vigente desde {formatearDesde(vigente.vigente_desde)}
              {vigente.provisional && <> · <Badge variante="aviso">Provisional</Badge></>}
            </h4>
            <p style={{ whiteSpace: "pre-line", margin: 0, fontSize: "0.88rem", color: "var(--navy)" }}>{vigente.texto}</p>
          </div>
          <p className="ayuda-campo" style={{ margin: 0 }}>
            Lee el texto antes de confirmar: el reconsentimiento que registres debe corresponder a <strong>esta</strong>{" "}
            versión. Se registran como máximo {MAX_LOTE_RECONSENTIMIENTO} por vez, todo o nada.
          </p>
          <div className="modal__advertencia" role="note" style={{ background: "var(--superficie)", borderColor: "var(--linea)", color: "var(--navy-medio)" }}>
            <Info size={16} aria-hidden="true" />
            <div>
              Registra, a nombre tuyo y con la fecha de hoy, que el nuevo consentimiento existe. No reenrola ninguna huella,
              no cambia el estado de las altas ni las da de baja. Si una persona no reconsiente, no la registres: solicita su
              baja (pasa a captura manual).
            </div>
          </div>

          {excede && (
            <div className="tarjeta-error" role="note">
              <strong>
                <AlertCircle size={16} aria-hidden="true" />
                Son demasiadas para una sola vez
              </strong>
              <p>
                Seleccionaste {ids.length} altas y el máximo es {MAX_LOTE_RECONSENTIMIENTO} por vez. Registra primero{" "}
                {MAX_LOTE_RECONSENTIMIENTO} y repite con el resto.
              </p>
            </div>
          )}

          <div className={`casilla-consentimiento${faltaDeclarar ? " campo-error" : ""}`}>
            <input
              type="checkbox"
              id="reconsentimiento-declaracion"
              checked={declarado}
              disabled={enviando}
              aria-describedby="reconsentimiento-declaracion-ayuda"
              onChange={(evento) => {
                setDeclarado(evento.target.checked);
                if (evento.target.checked) setFaltaDeclarar(false);
              }}
            />
            <label htmlFor="reconsentimiento-declaracion" style={{ margin: 0, fontWeight: 500, color: "var(--navy)" }}>
              <strong>Confirmo que los documentos firmados existen.</strong>
              <span id="reconsentimiento-declaracion-ayuda" style={{ display: "block", fontWeight: 400, color: "var(--navy-medio)" }}>
                {esLote
                  ? `Los reconsentimientos firmados de las ${ids.length} personas, con el texto de la versión ${vigente.version}, están en sus expedientes de RH. El registro en lote no distingue personas: revisa que no falte ninguno.`
                  : `El reconsentimiento firmado de la persona, con el texto de la versión ${vigente.version}, está en su expediente de RH.`}
              </span>
            </label>
          </div>
          {faltaDeclarar && (
            <p className="mensaje-campo">
              <AlertCircle size={14} aria-hidden="true" />
              Confirma que existen los documentos firmados para poder registrar.
            </p>
          )}
        </>
      )}

      {error && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se registró
          </strong>
          <p>{error}</p>
          {noElegibles && noElegibles.length > 0 && (
            <div className="tabla-desplazable">
              <table>
                <thead>
                  <tr>
                    <th>Persona</th>
                    <th>Por qué no es elegible</th>
                  </tr>
                </thead>
                <tbody>
                  {noElegibles.map((n) => (
                    <tr key={n.tu_id}>
                      <td>{n.persona_nombre ?? "—"}</td>
                      <td>{ETIQUETA_RAZON_NO_ELEGIBLE[n.razon] ?? "No es elegible ahora."}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      <div className="modal__botonera">
        <Button disabled={enviando} onClick={() => onCerrar(false)}>
          Cancelar
        </Button>
        {conflicto && (
          <Button variante="primario" onClick={() => onCerrar(true)}>
            Actualizar lista
          </Button>
        )}
        <Button
          variante="primario"
          cargando={enviando}
          textoCargando="Registrando…"
          disabled={estadoTexto !== "listo" || excede}
          onClick={registrar}
        >
          Registrar reconsentimiento
        </Button>
      </div>
    </Modal>
  );
}
