import { type FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { ArrowRight, Wrench } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";

type Excepcion = {
  id: number;
  motivo_revision: string;
  estado: "pendiente" | "resuelto";
  creado_en: string;
  marca_id: number | null;
  persona_nombre: string | null;
  momento_dispositivo: string | null;
};

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

// <input type="datetime-local"> no acepta un timestamptz con offset — recorta a
// "YYYY-MM-DDTHH:mm" en hora local del navegador, sólo para precargar el valor original.
function aDatetimeLocal(fecha: string | null): string {
  if (!fecha) return "";
  const valor = new Date(fecha);
  if (Number.isNaN(valor.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${valor.getFullYear()}-${pad(valor.getMonth() + 1)}-${pad(valor.getDate())}T${pad(
    valor.getHours(),
  )}:${pad(valor.getMinutes())}`;
}

export function CorregirMarcaPage() {
  const { id } = useParams<{ id: string }>();
  const [excepcion, setExcepcion] = useState<Excepcion | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  useEffect(() => {
    apiFetch(`/api/excepciones/${id}`)
      .then((r) => (r.ok ? r.json() : null))
      .then(setExcepcion)
      .catch(() => undefined);
  }, [id]);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    if (!excepcion?.marca_id) return;
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    try {
      const respuesta = await apiFetch("/api/correcciones", {
        method: "POST",
        body: JSON.stringify({
          marca_id: excepcion.marca_id,
          valor_corregido: new Date(String(f.get("valor_corregido"))).toISOString(),
          motivo: f.get("motivo"),
        }),
      });
      if (!respuesta.ok) {
        // El backend traduce el rechazo del trigger (ventana vencida / reordenaría marcas)
        // a un detail legible — SCJ-PRO-10 §VI.3, ver mensaje tal cual llegue.
        setError(
          await mensajeDeError(respuesta, "No se pudo registrar la corrección."),
        );
        return;
      }
      window.location.href = "/tiempo/excepciones";
    } catch {
      setError("No se pudo registrar la corrección. Revisa tu conexión e intenta de nuevo.");
    } finally {
      setEnviando(false);
    }
  }

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/tiempo/excepciones">Excepciones</a> / <strong>Corregir marca</strong>
        </nav>
        <h1>Corregir marca</h1>
        <p className="subtitulo-pagina">
          Registra el valor correcto. La marca original nunca se modifica — esto crea una
          corrección nueva que apunta a ella.
        </p>

        {excepcion && (
          <div className="cabecera-persona">
            <div className="identidad">
              <div>
                <strong>{excepcion.persona_nombre ?? "—"}</strong>
                <p className="meta-ficha">Motivo de revisión: {excepcion.motivo_revision}</p>
              </div>
            </div>
          </div>
        )}

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Wrench size={16} aria-hidden="true" />
            </span>
            Datos de la corrección
          </legend>

          <div className="campo">
            <label htmlFor="valor_corregido">Valor corregido</label>
            <input
              id="valor_corregido"
              name="valor_corregido"
              type="datetime-local"
              required
              defaultValue={aDatetimeLocal(excepcion?.momento_dispositivo ?? null)}
            />
            <small className="ayuda-campo">
              Sólo se puede ajustar la hora, no el orden frente a las marcas vecinas de la
              persona.
            </small>
          </div>

          <div className="campo">
            <label htmlFor="motivo">Motivo</label>
            <textarea id="motivo" name="motivo" required rows={3} />
          </div>
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/tiempo/excepciones">Cancelar</a>
          <Button
            type="submit"
            icono={ArrowRight}
            disabled={!excepcion?.marca_id}
            cargando={enviando}
            textoCargando="Guardando…"
          >
            Guardar corrección
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
