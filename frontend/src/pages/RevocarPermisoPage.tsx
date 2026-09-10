import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertTriangle } from "lucide-react";

import { apiFetch } from "../lib/apiClient";
import { AppShell } from "../layouts/AppShell";
import { Button } from "../components/Button";

type PuestoPermiso = {
  id: string;
  nombre_puesto: string;
  codigo: string;
  activo: boolean;
};

type EstadoCarga = "cargando" | "listo" | "error";

async function mensajeDeError(respuesta: Response, generico: string): Promise<string> {
  try {
    const cuerpo = await respuesta.json();
    if (typeof cuerpo?.detail === "string") return cuerpo.detail;
  } catch {
    // cuerpo no era JSON legible — cae al genérico
  }
  return generico;
}

export function RevocarPermisoPage() {
  const { id } = useParams<{ id: string }>();
  const [otorgamiento, setOtorgamiento] = useState<PuestoPermiso | null>(null);
  const [estadoCarga, setEstadoCarga] = useState<EstadoCarga>("cargando");
  const [error, setError] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  // Deep-link desde "Revocar" en la ficha de un puesto (?puesto_id=...) — si vino de ahí, tanto
  // cancelar como una revocación exitosa vuelven a esa ficha en vez de mandar a la pantalla
  // general de Permisos, que era la única salida antes y obligaba a renavegar todo de nuevo.
  const puestoId = new URLSearchParams(window.location.search).get("puesto_id");
  const destino = puestoId ? `/estructura/puestos/${puestoId}` : "/estructura/permisos";

  useEffect(() => {
    // Sin GET por id para puesto_permiso todavía — se busca en /api/permisos/vigentes (estado
    // actual, NO la bitácora de /otorgados que ahora son eventos con otro espacio de ids),
    // mismo patrón que BitacoraAsignacionesPersonaPage filtrando en cliente.
    apiFetch("/api/permisos/vigentes")
      .then((r) => {
        if (!r.ok) throw new Error(`status ${r.status}`);
        return r.json();
      })
      .then((datos: PuestoPermiso[]) => {
        setOtorgamiento(datos.find((o) => o.id === id) ?? null);
        setEstadoCarga("listo");
      })
      .catch(() => setEstadoCarga("error"));
  }, [id]);

  async function handleConfirmar() {
    setError(null);
    setEnviando(true);
    const respuesta = await apiFetch("/api/permisos/revocar", {
      method: "POST",
      body: JSON.stringify({ puesto_permiso_id: id }),
    });
    if (!respuesta.ok) {
      // El 422 de "última fila activa de puesto_permiso_edicion" (SCJ-PRO-05 R2/R3) es una
      // regla real que puede dispararse siempre — se muestra el detail del backend.
      setError(await mensajeDeError(respuesta, "No se pudo revocar el permiso."));
      setEnviando(false);
      return;
    }
    window.location.href = destino;
  }

  return (
    <AppShell>
      <div className="contenedor-pagina">
        <nav className="migas">
          <a href="/estructura/permisos">Permisos</a> / <strong>Revocar permiso</strong>
        </nav>
        <h1>Revocar permiso</h1>
        <p className="subtitulo-pagina">
          El puesto deja de tener este permiso de inmediato. Podés volver a otorgárselo cuando
          quieras.
        </p>

        {estadoCarga === "listo" && otorgamiento && (
          <div className="cabecera-persona">
            <div className="identidad">
              <div>
                <strong>{otorgamiento.nombre_puesto}</strong>
                <p className="meta-ficha">Permiso: {otorgamiento.codigo}</p>
              </div>
            </div>
          </div>
        )}

        {estadoCarga === "listo" && !otorgamiento && (
          <p role="alert">No se encontró este otorgamiento de permiso.</p>
        )}

        {estadoCarga === "error" && <p role="alert">No se pudo cargar este otorgamiento de permiso.</p>}

        <div className="tarjeta-info">
          <AlertTriangle size={16} aria-hidden="true" />
          <span>
            Si este es el único puesto que aún conserva `puesto_permiso_edicion` en todo el
            sistema, el backend rechaza la revocación para no dejar a nadie que pueda repartir
            permisos.
          </span>
        </div>

        {error && <p role="alert">{error}</p>}
        <div className="botonera">
          <a href={destino}>Cancelar</a>
          <Button
            type="button"
            onClick={handleConfirmar}
            disabled={!otorgamiento}
            cargando={enviando}
            textoCargando="Revocando…"
          >
            Confirmar revocación
          </Button>
        </div>
      </div>
    </AppShell>
  );
}
