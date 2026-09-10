import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { FichaDepartamentoPage } from "./FichaDepartamentoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const AREA = { id: "area-1", nombre_area: "Comercial" };

const DEPARTAMENTO = {
  id: "55555555-5555-5555-5555-555555555555",
  area_id: AREA.id,
  nombre_departamento: "Ventas",
  activo: true,
  creado_en: "2026-08-31T00:00:00+00:00",
  actualizado_en: "2026-08-31T00:00:00+00:00",
};

function mockApiFetch(
  departamento = DEPARTAMENTO,
  area: Record<string, unknown> | null = AREA,
  puestos: unknown[] | Response = [],
  asignaciones: unknown[] | Response = []
) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === `/api/areas/${departamento.area_id}`) {
      return Promise.resolve(area ? new Response(JSON.stringify(area)) : new Response(null, { status: 404 }));
    }
    if (path === "/api/puestos") {
      return Promise.resolve(puestos instanceof Response ? puestos : new Response(JSON.stringify(puestos)));
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(
        asignaciones instanceof Response ? asignaciones : new Response(JSON.stringify(asignaciones))
      );
    }
    return Promise.resolve(new Response(JSON.stringify(departamento)));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/estructura/departamentos/${DEPARTAMENTO.id}`]}>
      <Routes>
        <Route path="/estructura/departamentos/:id" element={<FichaDepartamentoPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("FichaDepartamentoPage", () => {
  it("muestra el nombre, estado y el nombre del área padre", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() => expect(screen.getAllByText("Ventas").length).toBeGreaterThan(0));
    expect(screen.getByText("Activo")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByText("Comercial")).toBeInTheDocument());
  });

  it("renombra el departamento vía PATCH /api/departamentos/:id", async () => {
    let renombrado = false;
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}`) {
        return Promise.resolve(new Response(JSON.stringify(AREA)));
      }
      if (path === `/api/departamentos/${DEPARTAMENTO.id}` && opciones?.method === "PATCH") {
        renombrado = true;
        return Promise.resolve(
          new Response(JSON.stringify({ ...DEPARTAMENTO, nombre_departamento: "Ventas Nacionales" }))
        );
      }
      if (path === "/api/puestos" || path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify(DEPARTAMENTO)));
    });

    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Ventas").length).toBeGreaterThan(0));

    const campoNombre = screen.getByLabelText(/^nombre$/i);
    await userEvent.clear(campoNombre);
    await userEvent.type(campoNombre, "Ventas Nacionales");
    await userEvent.click(screen.getByRole("button", { name: /guardar/i }));

    await waitFor(() => expect(renombrado).toBe(true));
    await waitFor(() =>
      expect(screen.getAllByText("Ventas Nacionales").length).toBeGreaterThan(0)
    );
  });

  it("desactiva el departamento vía PATCH /api/departamentos/:id/estado", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}`) {
        return Promise.resolve(new Response(JSON.stringify(AREA)));
      }
      if (path === `/api/departamentos/${DEPARTAMENTO.id}/estado` && opciones?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ ...DEPARTAMENTO, activo: false })));
      }
      if (path === "/api/puestos" || path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify(DEPARTAMENTO)));
    });

    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Ventas").length).toBeGreaterThan(0));
    await userEvent.click(screen.getByRole("button", { name: /desactivar departamento/i }));

    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: /reactivar departamento/i })).toBeInTheDocument();
  });

  it("reactiva un departamento inactivo vía PATCH /api/departamentos/:id/estado", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === `/api/areas/${AREA.id}`) {
        return Promise.resolve(new Response(JSON.stringify(AREA)));
      }
      if (path === `/api/departamentos/${DEPARTAMENTO.id}/estado` && opciones?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ ...DEPARTAMENTO, activo: true })));
      }
      if (path === "/api/puestos" || path === "/api/asignaciones") {
        return Promise.resolve(new Response(JSON.stringify([])));
      }
      return Promise.resolve(new Response(JSON.stringify({ ...DEPARTAMENTO, activo: false })));
    });

    renderPagina();
    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /reactivar departamento/i }));

    await waitFor(() => expect(screen.getByText("Activo")).toBeInTheDocument());
  });

  it("si GET /api/departamentos/:id falla, muestra error con reintentar", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(null, { status: 500 }));
    });

    renderPagina();

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar este departamento/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });

  describe("personas del departamento (opción B: dos columnas)", () => {
    const PUESTOS = [
      { id: "puesto-1", departamento_id: DEPARTAMENTO.id, activo: true },
      { id: "puesto-2", departamento_id: DEPARTAMENTO.id, activo: true },
      { id: "puesto-3", departamento_id: DEPARTAMENTO.id, activo: false },
      { id: "puesto-otro-depto", departamento_id: "otro-departamento", activo: true },
    ];

    const ASIGNACION_MARIANA = {
      persona_id: "persona-mariana",
      persona_nombre: "Mariana Torres",
      nombre_puesto: "Gerente de Ventas",
      nombre_departamento: DEPARTAMENTO.nombre_departamento,
      vigente_hasta: null,
    };
    const ASIGNACION_LUIS = {
      persona_id: "persona-luis",
      persona_nombre: "Luis Fernández",
      nombre_puesto: "Ejecutivo de Cuenta",
      nombre_departamento: DEPARTAMENTO.nombre_departamento,
      vigente_hasta: null,
    };
    // Carla tiene 2 asignaciones activas en puestos distintos del mismo departamento.
    const ASIGNACION_CARLA_1 = {
      persona_id: "persona-carla",
      persona_nombre: "Carla Jiménez",
      nombre_puesto: "Ejecutivo de Cuenta",
      nombre_departamento: DEPARTAMENTO.nombre_departamento,
      vigente_hasta: null,
    };
    const ASIGNACION_CARLA_2 = {
      persona_id: "persona-carla",
      persona_nombre: "Carla Jiménez",
      nombre_puesto: "Analista de Ventas",
      nombre_departamento: DEPARTAMENTO.nombre_departamento,
      vigente_hasta: null,
    };
    const ASIGNACION_TERMINADA = {
      persona_id: "persona-vieja",
      persona_nombre: "Persona Ya No Vigente",
      nombre_puesto: "Ejecutivo de Cuenta",
      nombre_departamento: DEPARTAMENTO.nombre_departamento,
      vigente_hasta: "2025-01-01",
    };
    const ASIGNACION_OTRO_DEPTO = {
      persona_id: "persona-otro-depto",
      persona_nombre: "No Debería Aparecer",
      nombre_puesto: "Puesto de otro depto",
      nombre_departamento: "Otro Departamento",
      vigente_hasta: null,
    };

    it("muestra el resumen (puestos activos, personas asignadas) y el desglose por puesto", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, PUESTOS, [
        ASIGNACION_MARIANA,
        ASIGNACION_LUIS,
        ASIGNACION_CARLA_1,
        ASIGNACION_CARLA_2,
        ASIGNACION_TERMINADA,
        ASIGNACION_OTRO_DEPTO,
      ]);
      renderPagina();

      await waitFor(() => expect(screen.getByText("Resumen")).toBeInTheDocument());
      const tarjetaResumen = screen.getByText("Resumen").closest(".tarjeta-resumen") as HTMLElement;
      // 2 puestos activos de este departamento (puesto-3 inactivo y el de otro depto no cuentan)
      expect(within(tarjetaResumen).getByText("2")).toBeInTheDocument();
      // 3 personas distintas (Mariana, Luis, Carla una sola vez pese a sus 2 asignaciones)
      expect(within(tarjetaResumen).getByText("3")).toBeInTheDocument();

      const tarjetaPorPuesto = screen.getByText("Por puesto").closest(".tarjeta-resumen") as HTMLElement;
      expect(within(tarjetaPorPuesto).getByText("Gerente de Ventas")).toBeInTheDocument();
      // Ejecutivo de Cuenta: Luis + Carla = 2 asignaciones
      const filaEjecutivo = within(tarjetaPorPuesto).getByText("Ejecutivo de Cuenta").closest("li")!;
      expect(filaEjecutivo).toHaveTextContent("2");
      expect(within(tarjetaPorPuesto).getByText("Analista de Ventas")).toBeInTheDocument();
    });

    it("lista las personas del departamento y filtra por búsqueda", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, PUESTOS, [ASIGNACION_MARIANA, ASIGNACION_LUIS]);
      renderPagina();

      await waitFor(() => expect(screen.getByText("Mariana Torres")).toBeInTheDocument());
      expect(screen.getByText("Luis Fernández")).toBeInTheDocument();
      expect(screen.getByRole("link", { name: /mariana torres/i })).toHaveAttribute(
        "href",
        "/personas/persona-mariana"
      );

      await userEvent.type(screen.getByLabelText(/buscar por nombre/i), "mariana");

      expect(screen.getByText("Mariana Torres")).toBeInTheDocument();
      expect(screen.queryByText("Luis Fernández")).not.toBeInTheDocument();
    });

    it("una persona con 2 asignaciones activas en el mismo departamento aparece una sola vez, con ambos puestos", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, PUESTOS, [ASIGNACION_CARLA_1, ASIGNACION_CARLA_2]);
      renderPagina();

      await waitFor(() => expect(screen.getAllByText("Carla Jiménez")).toHaveLength(1));
      const fila = screen.getByText("Carla Jiménez").closest("li")!;
      expect(fila).toHaveTextContent("Ejecutivo de Cuenta, Analista de Ventas");
    });

    it("si GET /api/puestos da 403, el resumen degrada sólo el conteo de puestos sin romper la lista de personas", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, new Response(null, { status: 403 }), [ASIGNACION_MARIANA]);
      renderPagina();

      await waitFor(() => expect(screen.getByText("Mariana Torres")).toBeInTheDocument());
      expect(screen.getByText("Sin permiso para ver puestos.")).toBeInTheDocument();
      // "Personas asignadas" sigue contando bien pese al 403 de puestos
      const tarjetaResumen = screen.getByText("Resumen").closest(".tarjeta-resumen") as HTMLElement;
      expect(within(tarjetaResumen).getByText("1")).toBeInTheDocument();
      expect(within(tarjetaResumen).getByText("—")).toBeInTheDocument();
    });

    it("si GET /api/asignaciones da 403, la lista de personas y el desglose avisan sin romper el resto de la ficha", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, PUESTOS, new Response(null, { status: 403 }));
      renderPagina();

      await waitFor(() =>
        expect(
          screen.getByText("No tienes permiso para ver las personas de este departamento.")
        ).toBeInTheDocument()
      );
      expect(screen.getByText("No tienes permiso para ver el desglose por puesto.")).toBeInTheDocument();
      // el conteo de puestos activos, independiente, sigue mostrándose
      expect(screen.getByText("2")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /desactivar departamento/i })).toBeInTheDocument();
    });

    it("cada fila usa avatar-iniciales + persona-celda (jerarquía visual real, no texto plano)", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, PUESTOS, [ASIGNACION_MARIANA]);
      renderPagina();

      const enlace = await screen.findByRole("link", { name: /mariana torres/i });
      expect(enlace).toHaveClass("persona-celda");
      expect(enlace.querySelector(".avatar-iniciales")).toHaveTextContent("MT");
    });

    it("la lista de personas tiene la clase de scroll interno (no crece sin límite)", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, PUESTOS, [ASIGNACION_MARIANA]);
      renderPagina();

      await waitFor(() => expect(screen.getByText("Mariana Torres")).toBeInTheDocument());
      expect(screen.getByText("Mariana Torres").closest("ul")).toHaveClass("lista-desplazable");
    });

    it("muestra un estado vacío si el departamento no tiene personas asignadas", async () => {
      mockApiFetch(DEPARTAMENTO, AREA, PUESTOS, []);
      renderPagina();

      await waitFor(() =>
        expect(
          screen.getByText("Este departamento no tiene personas asignadas actualmente.")
        ).toBeInTheDocument()
      );
      expect(screen.getByText("Sin personas asignadas por puesto todavía.")).toBeInTheDocument();
    });
  });
});
