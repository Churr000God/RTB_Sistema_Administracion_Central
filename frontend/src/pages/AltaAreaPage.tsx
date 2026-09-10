import { type FormEvent, useState } from "react";
import { ArrowRight, Building2 } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";
import { Input } from "../components/Input";

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function AltaAreaPage() {
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/areas", {
      method: "POST",
      body: JSON.stringify({
        nombre_area: f.get("nombre_area"),
      }),
    });
    if (!respuesta.ok) {
      if (respuesta.status === 409) {
        setError("Ya existe un área con ese nombre.");
      } else {
        setError(await mensajeDeError(respuesta, "No se pudo registrar el alta."));
      }
      setEnviando(false);
      return;
    }
    const area = await respuesta.json();
    window.location.href = `/estructura/areas/${area.id}`;
  }

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/areas">Áreas</a> / <strong>Nueva área</strong>
        </nav>
        <h1>Nueva área</h1>
        <p className="subtitulo-pagina">Registra un área en el catálogo organizacional.</p>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Building2 size={16} aria-hidden="true" />
            </span>
            Datos del área
          </legend>
          <Input
            id="nombre_area"
            name="nombre_area"
            label="Nombre del área"
            required
            maxLength={100}
            ayuda="Debe ser único, ej. Comercial, Operaciones."
          />
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/estructura/areas">Cancelar</a>
          <Button type="submit" icono={ArrowRight} cargando={enviando} textoCargando="Registrando…">
            Registrar
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
