import { type ChangeEvent, type FormEvent, useState } from "react";
import { ArrowRight, Briefcase, Folder, User } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";

function aMayusculas(evento: ChangeEvent<HTMLInputElement>) {
  evento.currentTarget.value = evento.currentTarget.value.toUpperCase();
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

export function AltaPersonaPage() {
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/personas", {
      method: "POST",
      body: JSON.stringify({
        primer_nombre: f.get("primer_nombre"),
        segundo_nombre: f.get("segundo_nombre") || null,
        apellido_paterno: f.get("apellido_paterno"),
        apellido_materno: f.get("apellido_materno") || null,
        curp: f.get("curp"),
        rfc: f.get("rfc"),
        nss: f.get("nss"),
        fecha_nacimiento: f.get("fecha_nacimiento"),
        fecha_ingreso: f.get("fecha_ingreso"),
        tipo_contrato: f.get("tipo_contrato"),
        documento_ref: f.get("documento_ref"),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo registrar el alta."));
      setEnviando(false);
      return;
    }
    const persona = await respuesta.json();
    window.location.href = `/personas/${persona.id}`;
  }

  return (
    <AppShell>
      <form onSubmit={handleSubmit} className="contenedor-pagina">
        <nav className="migas">
          <a href="/personas">Personas</a> / <strong>Alta de persona</strong>
        </nav>
        <h1>Alta de persona</h1>
        <p className="subtitulo-pagina">
          Registra los datos personales y la referencia de expediente.
        </p>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <User size={16} aria-hidden="true" />
            </span>
            Datos personales
          </legend>
          <div className="rejilla-campos">
            <div className="campo">
              <label htmlFor="primer_nombre">Primer nombre</label>
              <input id="primer_nombre" name="primer_nombre" required />
            </div>
            <div className="campo">
              <label htmlFor="segundo_nombre">Segundo nombre</label>
              <input id="segundo_nombre" name="segundo_nombre" />
            </div>
            <div className="campo">
              <label htmlFor="apellido_paterno">Apellido paterno</label>
              <input id="apellido_paterno" name="apellido_paterno" required />
            </div>
            <div className="campo">
              <label htmlFor="apellido_materno">Apellido materno</label>
              <input id="apellido_materno" name="apellido_materno" />
            </div>
            <div className="campo">
              <label htmlFor="fecha_nacimiento">Fecha de nacimiento</label>
              <input id="fecha_nacimiento" name="fecha_nacimiento" type="date" required />
            </div>
            <div className="campo">
              <label htmlFor="curp">CURP</label>
              <input
                id="curp"
                name="curp"
                required
                maxLength={18}
                className="campo-identificador"
                style={{ textTransform: "uppercase" }}
                onChange={aMayusculas}
                aria-describedby="curp-ayuda"
              />
              <small className="ayuda-campo" id="curp-ayuda">
                18 caracteres
              </small>
            </div>
            <div className="campo">
              <label htmlFor="rfc">RFC</label>
              <input
                id="rfc"
                name="rfc"
                required
                maxLength={13}
                className="campo-identificador"
                style={{ textTransform: "uppercase" }}
                onChange={aMayusculas}
                aria-describedby="rfc-ayuda"
              />
              <small className="ayuda-campo" id="rfc-ayuda">
                13 caracteres con homoclave
              </small>
            </div>
            <div className="campo">
              <label htmlFor="nss">NSS</label>
              <input
                id="nss"
                name="nss"
                required
                maxLength={11}
                className="campo-identificador"
                aria-describedby="nss-ayuda"
              />
              <small className="ayuda-campo" id="nss-ayuda">
                11 dígitos
              </small>
            </div>
          </div>
        </fieldset>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Briefcase size={16} aria-hidden="true" />
            </span>
            Alta laboral
          </legend>
          <div className="campo">
            <label htmlFor="fecha_ingreso">Fecha de ingreso</label>
            <input id="fecha_ingreso" name="fecha_ingreso" type="date" required />
          </div>
          <label>Tipo de contrato</label>
          <div className="opciones-seleccionables opciones-seleccionables--compacta">
            <label className="opcion-seleccionable">
              <input type="radio" name="tipo_contrato" value="indefinido" defaultChecked />
              <span className="texto-opcion">
                <strong>Indefinido</strong>
              </span>
            </label>
            <label className="opcion-seleccionable">
              <input type="radio" name="tipo_contrato" value="prestacion_servicios" />
              <span className="texto-opcion">
                <strong>Prestación de servicios</strong>
              </span>
            </label>
            <label className="opcion-seleccionable">
              <input type="radio" name="tipo_contrato" value="por_proyecto" />
              <span className="texto-opcion">
                <strong>Por proyecto</strong>
              </span>
            </label>
          </div>
        </fieldset>

        <fieldset className="fieldset-formulario">
          <legend className="encabezado-fieldset">
            <span className="icono-seccion">
              <Folder size={16} aria-hidden="true" />
            </span>
            Referencia de expediente
          </legend>
          <div className="campo">
            <label htmlFor="documento_ref">documento_ref</label>
            <input
              id="documento_ref"
              name="documento_ref"
              placeholder="RTB-__-__"
              required
              className="campo-identificador"
              aria-describedby="documento_ref-ayuda"
            />
            <small className="ayuda-campo" id="documento_ref-ayuda">
              Formato RTB-__-__ · folio del expediente físico
            </small>
          </div>
        </fieldset>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href="/personas">Cancelar</a>
          <Button type="submit" icono={ArrowRight} cargando={enviando} textoCargando="Registrando…">
            Registrar alta
          </Button>
        </div>
      </form>
    </AppShell>
  );
}
