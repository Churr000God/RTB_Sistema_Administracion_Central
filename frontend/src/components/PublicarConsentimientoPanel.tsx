import { useCallback, useEffect, useState } from "react";
import { AlertCircle, AlertTriangle, Loader2 } from "lucide-react";

import { Button } from "./Button";
import { ErrorApi, apiJson, mensajeDeNegocio } from "../lib/errorApi";
import { esConsentimientoCompleto, type ConsentimientoVigente, type ImpactoConsentimiento, type ResultadoPublicar } from "../lib/terminales";

const RUTA = "/api/terminales/configuracion/consentimiento";
const MAX_MOTIVO = 200;
const MENSAJE_GENERICO = "No se pudo publicar. Inténtalo de nuevo.";

type Props = {
  texto: string;
  vigente: ConsentimientoVigente;
  onVolver: () => void;
  onPublicado: (resultado: ResultadoPublicar) => void;
  // Otra persona publicó mientras se editaba: el padre recibe la versión nueva (si el cuerpo la trae).
  onConflicto: (detalle: string, nueva: ConsentimientoVigente | null) => void;
};

type EstadoImpacto = "cargando" | "listo" | "error";

// Publicar en dos pasos: este panel (motivo, cambio material, impacto, confirmación explícita) y el
// POST. La versión que se publica es siempre una nueva (inmutable); nunca se manda `provisional`:
// dejar de ser provisional es publicar una versión nueva.
export function PublicarConsentimientoPanel({ texto, vigente, onVolver, onPublicado, onConflicto }: Props) {
  const [material, setMaterial] = useState(false);
  const [forzado, setForzado] = useState(vigente.provisional);
  const [impacto, setImpacto] = useState<ImpactoConsentimiento | null>(null);
  const [estadoImpacto, setEstadoImpacto] = useState<EstadoImpacto>("cargando");
  const [motivo, setMotivo] = useState("");
  const [motivoInvalido, setMotivoInvalido] = useState(false);
  const [confirmado, setConfirmado] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const siguiente = vigente.version + 1;
  const efectivo = forzado || material;

  const cargarImpacto = useCallback(() => {
    setEstadoImpacto("cargando");
    apiJson<ImpactoConsentimiento>(`${RUTA}/impacto?cambio_material=${efectivo ? "true" : "false"}`)
      .then((datos) => {
        setImpacto(datos);
        setEstadoImpacto("listo");
        // El servidor manda: publicar la primera definitiva fuerza el cambio material.
        if (datos.forzado) setForzado(true);
      })
      .catch(() => setEstadoImpacto("error"));
  }, [efectivo]);

  useEffect(() => {
    cargarImpacto();
  }, [cargarImpacto]);

  async function publicar() {
    if (motivo.length > MAX_MOTIVO) {
      setMotivoInvalido(true);
      return;
    }
    setMotivoInvalido(false);
    setError(null);
    setEnviando(true);
    const cuerpo: Record<string, unknown> = { texto, cambio_material: efectivo, base_version: vigente.version };
    if (motivo.trim()) cuerpo.motivo_cambio = motivo.trim();
    try {
      const resultado = await apiJson<ResultadoPublicar>(RUTA, { method: "POST", body: JSON.stringify(cuerpo) });
      onPublicado(resultado);
    } catch (fallo) {
      setEnviando(false);
      if (fallo instanceof ErrorApi && fallo.status === 409 && fallo.detail) {
        const candidato = fallo.cuerpo?.consentimiento_vigente;
        onConflicto(fallo.detail, esConsentimientoCompleto(candidato) ? candidato : null);
        return;
      }
      setError(mensajeDeNegocio(fallo, MENSAJE_GENERICO));
    }
  }

  const listoParaPublicar = confirmado && estadoImpacto === "listo" && !enviando;

  return (
    <div className="panel-confirmar" role="alertdialog" aria-labelledby="publicar-titulo">
      <strong id="publicar-titulo" style={{ fontSize: "1rem" }}>
        {forzado ? `Publicar la versión ${siguiente} — la primera definitiva` : `Publicar la versión ${siguiente}`}
      </strong>
      <ul style={{ margin: 0, paddingLeft: "1.1rem", fontSize: "0.86rem", lineHeight: 1.5 }}>
        <li>
          Las <strong>asignaciones nuevas</strong> mostrarán este texto desde ahora.
        </li>
        <li>
          Las <strong>altas ya hechas no cambian</strong>: conservan la versión con la que se confirmaron. Una versión
          publicada no se edita ni se borra.
        </li>
        <li>Queda registrado quién la publicó y cuándo.</li>
      </ul>

      <div className={motivoInvalido ? "campo-error" : undefined}>
        <label htmlFor="publicar-motivo" style={{ marginBottom: "0.25rem" }}>
          Motivo del cambio (opcional, hasta {MAX_MOTIVO} caracteres)
        </label>
        <input
          id="publicar-motivo"
          type="text"
          value={motivo}
          disabled={enviando}
          aria-invalid={motivoInvalido || undefined}
          placeholder="Ej.: se agregó la referencia a Sistemas para revocar."
          onChange={(evento) => {
            setMotivo(evento.target.value);
            if (motivoInvalido) setMotivoInvalido(false);
          }}
        />
        {motivoInvalido && (
          <p className="mensaje-campo">
            <AlertCircle size={14} aria-hidden="true" />
            El motivo del cambio puede tener hasta {MAX_MOTIVO} caracteres.
          </p>
        )}
      </div>

      <label className="casilla-consentimiento" style={{ margin: 0, background: forzado ? "var(--superficie)" : undefined }}>
        <input
          type="checkbox"
          checked={efectivo}
          disabled={forzado || enviando}
          onChange={(evento) => setMaterial(evento.target.checked)}
        />
        <span>
          <strong>Cambio material (exige reconsentimiento).</strong>{" "}
          {forzado ? (
            <span style={{ display: "block", color: "var(--navy-medio)" }}>
              Marcado y bloqueado: esta es la primera versión definitiva y reemplaza al texto provisional, así que
              todas las personas con alta pendiente o activa deben reconsentir con el texto definitivo.
            </span>
          ) : (
            "Opcional: márcalo si el cambio altera la finalidad, el plazo, la forma de borrado o la revocación. Las personas con alta pendiente o activa deberán reconsentir."
          )}
        </span>
      </label>

      {estadoImpacto === "cargando" && (
        <p className="boton-con-icono" role="status" style={{ margin: 0 }}>
          <Loader2 size={16} className="icono-girando" aria-hidden="true" />
          Calculando cuántas altas quedarían pendientes…
        </p>
      )}
      {estadoImpacto === "error" && (
        <div role="note" className="banner-aviso" style={{ margin: 0 }}>
          <AlertTriangle size={16} aria-hidden="true" />
          <div>
            <strong>No se pudo calcular cuántas altas quedarían pendientes.</strong> Sin esa cifra no se puede
            publicar (publicar un cambio material a ciegas no es seguro).{" "}
            <Button onClick={cargarImpacto}>Reintentar</Button>
          </div>
        </div>
      )}
      {estadoImpacto === "listo" && impacto?.cambio_material_efectivo && (
        <div className="banner-aviso" role="note" style={{ margin: 0 }}>
          <AlertTriangle size={16} aria-hidden="true" />
          <div>
            <strong>
              {impacto.altas_que_quedarian_pendientes} altas quedarían con «Reconsentimiento pendiente»
            </strong>{" "}
            ({impacto.en_proceso} en proceso de alta —pendiente de alta o esperando huella— y {impacto.activas}{" "}
            activas). <strong>No se bloquea ninguna marca</strong>: sólo se señala en «Usuarios de la terminal», en
            la ficha y en el tablero de anomalías, hasta que RH registre el reconsentimiento. No cuentan las altas en
            baja ni pendientes de baja.
          </div>
        </div>
      )}

      <label className="casilla-consentimiento" style={{ margin: 0 }}>
        <input
          type="checkbox"
          checked={confirmado}
          disabled={enviando}
          onChange={(evento) => setConfirmado(evento.target.checked)}
        />
        <span>Confirmo que revisé la vista previa y que quiero publicar esta versión.</span>
      </label>

      {error && (
        <div className="tarjeta-error" role="alert">
          <strong>
            <AlertCircle size={16} aria-hidden="true" />
            No se publicó
          </strong>
          <p>{error}</p>
        </div>
      )}

      <div className="botonera">
        <Button disabled={enviando} onClick={onVolver}>
          Volver al editor
        </Button>
        <Button
          variante="primario"
          cargando={enviando}
          textoCargando="Publicando…"
          disabled={!listoParaPublicar && !enviando}
          onClick={publicar}
        >
          {`Publicar versión ${siguiente}`}
        </Button>
      </div>
    </div>
  );
}
