import { type FormEvent, useEffect, useState } from "react";
import { AlertCircle, Loader2, Mail, Send, User } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";

type PersonaOpcion = { id: string; primer_nombre: string; apellido_paterno: string };

type EstadoPersonas = "cargando" | "listo" | "error";

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function AltaUsuarioPage() {
  const [personas, setPersonas] = useState<PersonaOpcion[]>([]);
  const [estadoPersonas, setEstadoPersonas] = useState<EstadoPersonas>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [enviado, setEnviado] = useState(false);
  const [enviando, setEnviando] = useState(false);
  // Deep-link desde "Crear acceso a Kairos" en la ficha de persona (?persona_id=...) — precarga
  // la selección así no hay que volver a buscar a la misma persona de la que se vino.
  const [personaId, setPersonaId] = useState(
    () => new URLSearchParams(window.location.search).get("persona_id") ?? ""
  );

  function cargarPersonas() {
    setEstadoPersonas("cargando");
    apiFetch("/api/personas")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: PersonaOpcion[]) => {
        setPersonas(datos);
        setEstadoPersonas("listo");
      })
      .catch(() => setEstadoPersonas("error"));
  }

  useEffect(() => {
    cargarPersonas();
  }, []);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    setEnviando(true);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/usuarios", {
      method: "POST",
      body: JSON.stringify({
        persona_id: f.get("persona_id"),
        correo: f.get("correo"),
        nombre_usuario: f.get("nombre_usuario"),
      }),
    });
    if (!respuesta.ok) {
      setError(await mensajeDeError(respuesta, "No se pudo enviar la invitación."));
      setEnviando(false);
      return;
    }
    setEnviado(true);
  }

  if (enviado) {
    return (
      <AppShell>
        <p className="contenedor-pagina" style={{ marginTop: "2.5rem" }}>
          Invitación enviada.
        </p>
      </AppShell>
    );
  }

  return (
    <AppShell>
      <div className="contenedor-pagina">
        <nav className="migas">
          <a href="/personas">Personas</a> / <strong>Alta de usuario</strong>
        </nav>
        <h1>Alta de usuario</h1>
        <p className="subtitulo-pagina">
          Selecciona a una persona ya registrada y envíale una invitación de acceso.
        </p>

        {estadoPersonas === "cargando" && (
          <p className="boton-con-icono">
            <Loader2 size={16} className="icono-girando" aria-hidden="true" />
            Cargando personas…
          </p>
        )}

        {estadoPersonas === "error" && (
          <div className="tarjeta-error" role="alert">
            <strong>
              <AlertCircle size={16} aria-hidden="true" />
              No se pudo cargar el listado de personas
            </strong>
            <p>Ocurrió un problema al consultar el padrón.</p>
            <button type="button" onClick={cargarPersonas}>
              Reintentar
            </button>
          </div>
        )}

        {estadoPersonas === "listo" && (
          <form onSubmit={handleSubmit}>
            <fieldset className="fieldset-formulario">
              <legend className="encabezado-fieldset">
                <span className="icono-seccion">
                  <User size={16} aria-hidden="true" />
                </span>
                Datos de acceso
              </legend>
              <label htmlFor="persona_id">Persona</label>
              <select
                id="persona_id"
                name="persona_id"
                required
                value={personaId}
                onChange={(evento) => setPersonaId(evento.target.value)}
              >
                <option value="">Selecciona una persona</option>
                {personas.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.primer_nombre} {p.apellido_paterno}
                  </option>
                ))}
              </select>
              <label htmlFor="correo">Correo</label>
              <div className="campo-con-icono">
                <Mail size={16} className="icono-campo" aria-hidden="true" />
                <input id="correo" name="correo" type="email" required aria-describedby="correo-ayuda" />
              </div>
              <small className="ayuda-campo" id="correo-ayuda">
                A esta dirección llega el enlace de activación. Vigencia de 72 horas.
              </small>
              <label htmlFor="nombre_usuario">Nombre de usuario</label>
              <input id="nombre_usuario" name="nombre_usuario" required />
            </fieldset>
            {error && <p role="alert">{error}</p>}
            <div className="botonera">
              <a href="/personas">Cancelar</a>
              <Button type="submit" icono={Send} cargando={enviando} textoCargando="Enviando…">
                Enviar invitación
              </Button>
            </div>
          </form>
        )}
      </div>
    </AppShell>
  );
}
