import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { FichaPersonaPage } from "./FichaPersonaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONA = {
  id: "11111111-2222-3333-4444-555555555555",
  primer_nombre: "Mariana",
  segundo_nombre: "Guadalupe",
  apellido_paterno: "Alcántara",
  apellido_materno: "Ruvalcaba",
  curp: "AARM910427MDFLVR03",
  rfc: "AARM910427H8A",
  nss: "62119145338",
  fecha_nacimiento: "1991-04-27",
  fecha_ingreso: "2022-03-14",
  estado: "activo",
  tipo_contrato: "indefinido",
  documento_ref: "RTB-2026-001",
  tiene_usuario: false,
  tiene_jornada_vigente: false,
  puestos_vigentes: [] as Array<Record<string, unknown>>,
};

const MOVIMIENTOS = [
  {
    id: "m1",
    persona_id: PERSONA.id,
    tipo_movimiento: "alta",
    fecha_efectiva: "2022-03-14T09:00:00Z",
    motivo: null,
    registrado_por_nombre: null,
  },
  {
    id: "m2",
    persona_id: PERSONA.id,
    tipo_movimiento: "suspension",
    fecha_efectiva: "2023-06-01T09:00:00Z",
    motivo: "Licencia sin goce de sueldo",
    registrado_por_nombre: "mariana.renteria",
  },
];

const ASIGNACIONES: Array<Record<string, unknown>> = [];

// FichaPersonaPage hace un tercer fetch a /api/asignaciones (historial de puestos, filtrado en
// cliente por persona_id) además de /api/personas/:id y /api/personas/:id/movimientos — sin esta
// rama, el catch-all le devolvía el JSON de PERSONA y el .filter() del array explotaba (regresión
// real detectada al extender esta suite para el corte de asignación).
function mockApiFetch(asignaciones: Array<Record<string, unknown>> = ASIGNACIONES) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path.endsWith("/movimientos")) {
      return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(new Response(JSON.stringify(asignaciones)));
    }
    return Promise.resolve(new Response(JSON.stringify(PERSONA)));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/personas/${PERSONA.id}`]}>
      <Routes>
        <Route path="/personas/:id" element={<FichaPersonaPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("FichaPersonaPage", () => {
  it("muestra identidad, datos personales y expediente", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() =>
      expect(
        screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length
      ).toBeGreaterThan(0)
    );

    expect(screen.getByText(PERSONA.rfc, { selector: "strong" })).toBeInTheDocument();
    expect(screen.getByText(PERSONA.nss, { selector: "strong" })).toBeInTheDocument();
    expect(screen.getByText("27 abr 1991")).toBeInTheDocument();
    expect(screen.getByText(PERSONA.documento_ref)).toBeInTheDocument();
    expect(screen.getByText("Indefinido", { selector: "strong" })).toBeInTheDocument();
  });

  it("nunca muestra 'Indeterminado' para tipo_contrato (usa el enum real)", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() =>
      expect(screen.getByText(PERSONA.documento_ref)).toBeInTheDocument()
    );
    expect(screen.queryByText(/indeterminado/i)).not.toBeInTheDocument();
  });

  it("resume el historial de estado a los últimos movimientos, con autor y link a la bitácora completa", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() =>
      expect(screen.getByText(PERSONA.documento_ref)).toBeInTheDocument()
    );

    expect(screen.getByText("mariana.renteria")).toBeInTheDocument();
    // hay dos links "Ver bitácora completa →" (historial de estado e historial de puestos) —
    // se distingue por href.
    const linksBitacora = screen.getAllByRole("link", { name: /ver bitácora completa/i });
    expect(
      linksBitacora.some(
        (link) => link.getAttribute("href") === `/personas/${PERSONA.id}/bitacora`
      )
    ).toBe(true);
  });

  it("si GET /api/personas/:id falla, muestra un error con reintentar en vez de quedarse en Cargando…", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      // GET /api/personas/:id — el que backend confirmó que a veces devuelve 500
      return Promise.resolve(new Response(null, { status: 500 }));
    });

    renderPagina();

    await waitFor(() =>
      expect(
        screen.getByText(/no se pudo cargar la ficha de esta persona/i)
      ).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
    expect(screen.queryByText(/cargando/i)).not.toBeInTheDocument();
  });

  it("reintentar vuelve a pedir los datos y, si funciona, muestra la ficha", async () => {
    let intento = 0;
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      intento += 1;
      if (intento === 1) return Promise.resolve(new Response(null, { status: 500 }));
      return Promise.resolve(new Response(JSON.stringify(PERSONA)));
    });

    renderPagina();

    await waitFor(() =>
      expect(
        screen.getByText(/no se pudo cargar la ficha de esta persona/i)
      ).toBeInTheDocument()
    );
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));

    await waitFor(() =>
      expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
    );
  });

  it("muestra 'Crear acceso a Kairos' cuando la persona no tiene usuario vinculado", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() =>
      expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
    );
    expect(
      screen.getByRole("link", { name: /crear acceso a kairos/i })
    ).toHaveAttribute("href", `/usuarios/nuevo?persona_id=${PERSONA.id}`);
  });

  it("oculta 'Crear acceso a Kairos' cuando la persona ya tiene usuario vinculado", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      return Promise.resolve(new Response(JSON.stringify({ ...PERSONA, tiene_usuario: true })));
    });
    renderPagina();

    await waitFor(() =>
      expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
    );
    expect(
      screen.queryByRole("link", { name: /crear acceso a kairos/i })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: /nuevo movimiento/i })).toBeInTheDocument();
  });

  it("una persona sin expediente (documento_ref/tipo_contrato null) no rompe, muestra los fallbacks", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      return Promise.resolve(
        new Response(JSON.stringify({ ...PERSONA, tipo_contrato: null, documento_ref: null }))
      );
    });

    renderPagina();

    await waitFor(() =>
      expect(
        screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length
      ).toBeGreaterThan(0)
    );
    expect(screen.getByText(/sin expediente asignado/i)).toBeInTheDocument();
  });

  it("muestra 'Sin puesto asignado actualmente' cuando puestos_vigentes está vacío", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() =>
      expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
    );
    expect(screen.getByText(/sin puesto asignado actualmente/i)).toBeInTheDocument();
  });

  it("lista la asignación actual (puestos_vigentes) con acciones de terminar y cambiar de puesto", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      return Promise.resolve(
        new Response(
          JSON.stringify({
            ...PERSONA,
            puestos_vigentes: [
              {
                asignacion_id: "asignacion-ficticia-1",
                puesto_id: "puesto-ficticio-1",
                nombre_puesto: "Puesto Ficticio Uno",
                nombre_departamento: "Departamento Ficticio Uno",
                nombre_area: "Área Ficticia Uno",
              },
            ],
          })
        )
      );
    });

    renderPagina();

    await waitFor(() => expect(screen.getByText("Puesto Ficticio Uno")).toBeInTheDocument());
    expect(screen.getByText(/departamento ficticio uno/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /^terminar$/i })).toHaveAttribute(
      "href",
      "/estructura/asignaciones/asignacion-ficticia-1/terminar"
    );
    expect(screen.getByRole("link", { name: /cambiar de puesto/i })).toHaveAttribute(
      "href",
      "/estructura/asignaciones/asignacion-ficticia-1/cambiar-puesto"
    );
  });

  it("muestra 'Sin asignaciones registradas todavía' cuando el historial de puestos está vacío", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() =>
      expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
    );
    expect(screen.getByText(/sin asignaciones registradas todavía/i)).toBeInTheDocument();
  });

  it("resume el historial de puestos a las últimas asignaciones, con link a la bitácora completa", async () => {
    mockApiFetch([
      {
        id: "asignacion-ficticia-2",
        persona_id: PERSONA.id,
        nombre_puesto: "Puesto Ficticio Dos",
        vigente_desde: "2024-01-01",
        vigente_hasta: "2025-01-01",
      },
      {
        id: "asignacion-ficticia-3",
        persona_id: PERSONA.id,
        nombre_puesto: "Puesto Ficticio Tres",
        vigente_desde: "2025-01-02",
        vigente_hasta: null,
      },
      // de otra persona — el filtrado en cliente por persona_id debe excluirla
      {
        id: "asignacion-ajena",
        persona_id: "otra-persona-ficticia",
        nombre_puesto: "Puesto Ficticio Ajeno",
        vigente_desde: "2025-06-01",
        vigente_hasta: null,
      },
    ]);
    renderPagina();

    await waitFor(() => expect(screen.getByText("Puesto Ficticio Tres")).toBeInTheDocument());
    expect(screen.getByText("Puesto Ficticio Dos")).toBeInTheDocument();
    expect(screen.queryByText("Puesto Ficticio Ajeno")).not.toBeInTheDocument();
    // hay dos links "Ver bitácora completa →" (historial de puestos e historial de estado) —
    // se distingue por href.
    const linksBitacora = screen.getAllByRole("link", { name: /ver bitácora completa/i });
    expect(
      linksBitacora.some(
        (link) => link.getAttribute("href") === `/personas/${PERSONA.id}/bitacora-asignaciones`
      )
    ).toBe(true);
  });

  it("muestra las alertas de retardo de la persona con link a la pantalla completa", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      if (path.startsWith("/api/alertas-de-retardo")) {
        expect(path).toContain(`persona_id=${PERSONA.id}`);
        return Promise.resolve(
          new Response(
            JSON.stringify({
              alertas: [
                {
                  fecha: "2026-09-05",
                  hora_entrada_programada: "09:00:00",
                  hora_salida_programada: "18:00:00",
                  motivo: "fuera_de_tolerancia",
                },
              ],
            })
          )
        );
      }
      return Promise.resolve(new Response(JSON.stringify(PERSONA)));
    });

    renderPagina();

    await waitFor(() => expect(screen.getByText("Fuera de tolerancia")).toBeInTheDocument());
    expect(
      screen.getByRole("link", { name: /ver todas/i })
    ).toHaveAttribute("href", `/tiempo/alertas-retardo?persona_id=${PERSONA.id}`);
  });

  it("si /api/alertas-de-retardo falla (sin permiso), oculta la sección en vez de romper la ficha", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      if (path.startsWith("/api/alertas-de-retardo")) {
        return Promise.resolve(new Response(null, { status: 403 }));
      }
      return Promise.resolve(new Response(JSON.stringify(PERSONA)));
    });

    renderPagina();

    await waitFor(() =>
      expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
    );
    expect(screen.queryByText(/alertas de retardo/i)).not.toBeInTheDocument();
  });

  it("muestra el calendario semanal de la jornada vigente", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      if (path.startsWith("/api/alertas-de-retardo")) {
        return Promise.resolve(new Response(JSON.stringify({ alertas: [] })));
      }
      if (path.endsWith("/jornada-vigente")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              id: 1,
              persona_id: PERSONA.id,
              tipo_jornada: "normal",
              vigente_desde: "2026-08-01",
              vigente_hasta: null,
              descuento_comida_fija: false,
              minutos_descuento_comida_fija: null,
              horas_semanales_calculadas: 40,
              genera_alerta_horario: false,
              patron_semanal: [
                {
                  id: 1,
                  jornada_asignada_id: 1,
                  dia_semana: "lunes",
                  hora_entrada: "09:00:00",
                  hora_salida: "18:00:00",
                  minutos_comida: 60,
                  horas_efectivas: 8,
                },
              ],
            })
          )
        );
      }
      return Promise.resolve(new Response(JSON.stringify(PERSONA)));
    });

    renderPagina();

    await waitFor(() => expect(screen.getByText("Jornada asignada")).toBeInTheDocument());
    expect(screen.getByText(/vigente desde 01 ago 2026/i)).toBeInTheDocument();
    expect(screen.getByText("09:00–18:00")).toBeInTheDocument();
    expect(screen.getByText("60 min comida")).toBeInTheDocument();
    // Domingo no está en el patrón -> "Libre".
    expect(screen.getAllByText("Libre").length).toBe(6);
    expect(screen.getByRole("link", { name: /renovar jornada/i })).toHaveAttribute(
      "href",
      `/tiempo/asignacion-jornada?persona_id=${PERSONA.id}`,
    );
  });

  it("si la persona no tiene jornada vigente (404), muestra el estado sin jornada con link para asignar", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
      }
      if (path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
      }
      if (path.startsWith("/api/alertas-de-retardo")) {
        return Promise.resolve(new Response(JSON.stringify({ alertas: [] })));
      }
      if (path.endsWith("/jornada-vigente")) {
        return Promise.resolve(
          new Response(JSON.stringify({ detail: "La persona no tiene jornada vigente." }), {
            status: 404,
          }),
        );
      }
      return Promise.resolve(new Response(JSON.stringify(PERSONA)));
    });

    renderPagina();

    await waitFor(() => expect(screen.getByText("Sin jornada vigente asignada.")).toBeInTheDocument());
    expect(screen.getByRole("link", { name: /asignar jornada/i })).toHaveAttribute(
      "href",
      `/tiempo/asignacion-jornada?persona_id=${PERSONA.id}`,
    );
  });

  describe("edición in-place de Datos personales/Expediente", () => {
    it("al hacer click en Editar precarga los inputs con los valores actuales, sin GET nuevo", async () => {
      mockApiFetch();
      renderPagina();

      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      const llamadasAntes = vi.mocked(apiFetch).mock.calls.length;

      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));

      expect(screen.getByLabelText(/primer nombre/i)).toHaveValue(PERSONA.primer_nombre);
      expect(screen.getByLabelText(/apellido paterno/i)).toHaveValue(PERSONA.apellido_paterno);
      expect(screen.getByLabelText(/^curp$/i)).toHaveValue(PERSONA.curp);
      expect(screen.getByLabelText(/^rfc$/i)).toHaveValue(PERSONA.rfc);
      expect(screen.getByLabelText(/^nss$/i)).toHaveValue(PERSONA.nss);
      expect(screen.getByLabelText(/fecha de nacimiento/i)).toHaveValue(PERSONA.fecha_nacimiento);
      expect(screen.getByLabelText(/fecha de ingreso/i)).toHaveValue(PERSONA.fecha_ingreso);
      expect(screen.getByLabelText(/referencia de documento/i)).toHaveValue(PERSONA.documento_ref);
      expect(vi.mocked(apiFetch).mock.calls.length).toBe(llamadasAntes);
    });

    it("submit sin cambios corta antes del fetch con 'No modificaste ningún campo.'", async () => {
      mockApiFetch();
      renderPagina();

      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
      const llamadasAntes = vi.mocked(apiFetch).mock.calls.length;

      await userEvent.click(screen.getByRole("button", { name: /^guardar$/i }));

      await waitFor(() =>
        expect(screen.getByText("No modificaste ningún campo.")).toBeInTheDocument()
      );
      expect(vi.mocked(apiFetch).mock.calls.length).toBe(llamadasAntes);
    });

    it("submit con cambios manda PATCH sólo con los campos modificados, actualiza la vista y vuelve a modo lectura", async () => {
      let cuerpoPatch: unknown = null;
      vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
        if (path === "/api/sesion") {
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
          );
        }
        if (path.endsWith("/movimientos")) {
          return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
        }
        if (path === "/api/asignaciones") {
          return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
        }
        if (path === `/api/personas/${PERSONA.id}` && opciones?.method === "PATCH") {
          cuerpoPatch = JSON.parse(String(opciones.body));
          return Promise.resolve(
            new Response(JSON.stringify({ ...PERSONA, primer_nombre: "Marianela" }))
          );
        }
        return Promise.resolve(new Response(JSON.stringify(PERSONA)));
      });

      renderPagina();
      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));

      const campoPrimerNombre = screen.getByLabelText(/primer nombre/i);
      await userEvent.clear(campoPrimerNombre);
      await userEvent.type(campoPrimerNombre, "Marianela");
      await userEvent.click(screen.getByRole("button", { name: /^guardar$/i }));

      await waitFor(() =>
        expect(screen.getAllByText(/Marianela Guadalupe Alcántara Ruvalcaba/).length).toBeGreaterThan(0)
      );
      expect(cuerpoPatch).toEqual({ primer_nombre: "Marianela" });
      // vuelve a modo lectura: el botón "Editar" reaparece, ya no hay "Guardar"/"Cancelar"
      expect(screen.getByRole("button", { name: /^editar$/i })).toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /^guardar$/i })).not.toBeInTheDocument();
    });

    it("403 al guardar muestra 'No tenés permiso para editar esta persona.' y mantiene el formulario abierto", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
        if (path === "/api/sesion") {
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
          );
        }
        if (path.endsWith("/movimientos")) {
          return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
        }
        if (path === "/api/asignaciones") {
          return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
        }
        if (path === `/api/personas/${PERSONA.id}` && opciones?.method === "PATCH") {
          return Promise.resolve(new Response(null, { status: 403 }));
        }
        return Promise.resolve(new Response(JSON.stringify(PERSONA)));
      });

      renderPagina();
      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
      const campoPrimerNombre = screen.getByLabelText(/primer nombre/i);
      await userEvent.clear(campoPrimerNombre);
      await userEvent.type(campoPrimerNombre, "Marianela");
      await userEvent.click(screen.getByRole("button", { name: /^guardar$/i }));

      await waitFor(() =>
        expect(screen.getByText("No tenés permiso para editar esta persona.")).toBeInTheDocument()
      );
      expect(screen.getByLabelText(/primer nombre/i)).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /^guardar$/i })).toBeInTheDocument();
    });

    it("404 al guardar muestra 'Esta persona ya no existe.'", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
        if (path === "/api/sesion") {
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
          );
        }
        if (path.endsWith("/movimientos")) {
          return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
        }
        if (path === "/api/asignaciones") {
          return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
        }
        if (path === `/api/personas/${PERSONA.id}` && opciones?.method === "PATCH") {
          return Promise.resolve(new Response(null, { status: 404 }));
        }
        return Promise.resolve(new Response(JSON.stringify(PERSONA)));
      });

      renderPagina();
      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
      const campoPrimerNombre = screen.getByLabelText(/primer nombre/i);
      await userEvent.clear(campoPrimerNombre);
      await userEvent.type(campoPrimerNombre, "Marianela");
      await userEvent.click(screen.getByRole("button", { name: /^guardar$/i }));

      await waitFor(() =>
        expect(screen.getByText("Esta persona ya no existe.")).toBeInTheDocument()
      );
    });

    it("409/422 al guardar muestra el detail del backend tal cual", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
        if (path === "/api/sesion") {
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
          );
        }
        if (path.endsWith("/movimientos")) {
          return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
        }
        if (path === "/api/asignaciones") {
          return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
        }
        if (path === `/api/personas/${PERSONA.id}` && opciones?.method === "PATCH") {
          return Promise.resolve(
            new Response(JSON.stringify({ detail: "Ya existe una persona con ese CURP." }), {
              status: 409,
            })
          );
        }
        return Promise.resolve(new Response(JSON.stringify(PERSONA)));
      });

      renderPagina();
      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
      const campoPrimerNombre = screen.getByLabelText(/primer nombre/i);
      await userEvent.clear(campoPrimerNombre);
      await userEvent.type(campoPrimerNombre, "Marianela");
      await userEvent.click(screen.getByRole("button", { name: /^guardar$/i }));

      await waitFor(() =>
        expect(screen.getByText("Ya existe una persona con ese CURP.")).toBeInTheDocument()
      );
    });

    it("Cancelar descarta los cambios tipeados y vuelve a modo lectura con los valores originales", async () => {
      mockApiFetch();
      renderPagina();

      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
      const campoPrimerNombre = screen.getByLabelText(/primer nombre/i);
      await userEvent.clear(campoPrimerNombre);
      await userEvent.type(campoPrimerNombre, "Nombre Cambiado Que No Se Guarda");
      await userEvent.click(screen.getByRole("button", { name: /^cancelar$/i }));

      expect(screen.queryByLabelText(/primer nombre/i)).not.toBeInTheDocument();
      expect(
        screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length
      ).toBeGreaterThan(0);
      expect(screen.queryByText("Nombre Cambiado Que No Se Guarda")).not.toBeInTheDocument();

      // reabrir Editar confirma que el descarte fue real, no sólo visual
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
      expect(screen.getByLabelText(/primer nombre/i)).toHaveValue(PERSONA.primer_nombre);
    });

    it("doble submit bloqueado mientras el PATCH está en curso", async () => {
      let resolverPatch!: (respuesta: Response) => void;
      let llamadasPatch = 0;
      vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
        if (path === "/api/sesion") {
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
          );
        }
        if (path.endsWith("/movimientos")) {
          return Promise.resolve(new Response(JSON.stringify(MOVIMIENTOS)));
        }
        if (path === "/api/asignaciones") {
          return Promise.resolve(new Response(JSON.stringify(ASIGNACIONES)));
        }
        if (path === `/api/personas/${PERSONA.id}` && opciones?.method === "PATCH") {
          llamadasPatch += 1;
          return new Promise<Response>((resolver) => {
            resolverPatch = resolver;
          });
        }
        return Promise.resolve(new Response(JSON.stringify(PERSONA)));
      });

      renderPagina();
      await waitFor(() =>
        expect(screen.getAllByText("Mariana Guadalupe Alcántara Ruvalcaba").length).toBeGreaterThan(0)
      );
      await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
      const campoPrimerNombre = screen.getByLabelText(/primer nombre/i);
      await userEvent.clear(campoPrimerNombre);
      await userEvent.type(campoPrimerNombre, "Marianela");

      const botonGuardar = screen.getByRole("button", { name: /^guardar$/i });
      await userEvent.click(botonGuardar);

      await waitFor(() => expect(screen.getByRole("button", { name: /guardando/i })).toBeDisabled());
      await userEvent.click(screen.getByRole("button", { name: /guardando/i }));
      expect(llamadasPatch).toBe(1);

      resolverPatch(new Response(JSON.stringify({ ...PERSONA, primer_nombre: "Marianela" })));
      await waitFor(() =>
        expect(screen.getAllByText(/Marianela Guadalupe Alcántara Ruvalcaba/).length).toBeGreaterThan(0)
      );
    });
  });
});
