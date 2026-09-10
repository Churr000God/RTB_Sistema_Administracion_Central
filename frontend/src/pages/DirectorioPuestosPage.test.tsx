import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DirectorioPuestosPage } from "./DirectorioPuestosPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const DEPARTAMENTOS = [{ id: "dep-1", nombre_departamento: "Ventas" }];

const PUESTOS = [
  {
    id: "puesto-1",
    departamento_id: "dep-1",
    nombre_puesto: "Director Comercial",
    nivel: "direccion",
    plazas_totales: 1,
    reporta_a_id: null,
    activo: true,
    creado_en: "2026-08-31T00:00:00+00:00",
    actualizado_en: "2026-08-31T00:00:00+00:00",
  },
  {
    id: "puesto-2",
    departamento_id: "dep-1",
    nombre_puesto: "Ejecutivo de Ventas",
    nivel: "operativo",
    plazas_totales: 5,
    reporta_a_id: "puesto-1",
    activo: false,
    creado_en: "2026-08-31T00:00:00+00:00",
    actualizado_en: "2026-08-31T00:00:00+00:00",
  },
];

function mockApiFetch(
  respuestaPuestos: Response,
  respuestaDepartamentos?: Response,
  respuestaAsignaciones?: Response,
) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/departamentos") {
      return Promise.resolve(respuestaDepartamentos ?? new Response(JSON.stringify(DEPARTAMENTOS)));
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(respuestaAsignaciones ?? new Response(JSON.stringify([])));
    }
    return Promise.resolve(respuestaPuestos);
  });
}

describe("DirectorioPuestosPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("lista los puestos con departamento, nivel traducido, reporta-a y plazas resueltos sin fetch extra", async () => {
    mockApiFetch(new Response(JSON.stringify(PUESTOS)));

    render(<DirectorioPuestosPage />);

    await waitFor(() =>
      expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0)
    );
    expect(screen.getAllByText("Ventas").length).toBeGreaterThan(0);
    expect(screen.getByText("Dirección")).toBeInTheDocument();
    expect(screen.getByText("Operativo")).toBeInTheDocument();
    // "reporta a" del segundo puesto se resuelve contra el propio listado de /api/puestos
    expect(screen.getByText("Ejecutivo de Ventas").closest("tr")).toHaveTextContent(
      "Director Comercial"
    );
    expect(screen.getByText("5")).toBeInTheDocument();
    expect(screen.getByText("Activo", { selector: "span.insignia" })).toBeInTheDocument();
    expect(screen.getByText("Inactivo", { selector: "span.insignia" })).toBeInTheDocument();
    // tres llamadas propias de la página (puestos, departamentos, asignaciones para el
    // organigrama) + la del guard de sesión: sin fetch extra por puesto
    expect(apiFetch).toHaveBeenCalledTimes(4);
  });

  it("calcula las métricas (total, activos, inactivos)", async () => {
    mockApiFetch(new Response(JSON.stringify(PUESTOS)));

    render(<DirectorioPuestosPage />);

    await waitFor(() =>
      expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0)
    );
    expect(screen.getByText("Activos").closest(".metrica")).toHaveTextContent("1");
    expect(screen.getByText("Inactivos").closest(".metrica")).toHaveTextContent("1");
  });

  it("filtra por texto de búsqueda", async () => {
    mockApiFetch(new Response(JSON.stringify(PUESTOS)));

    render(<DirectorioPuestosPage />);
    await waitFor(() =>
      expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0)
    );

    await userEvent.type(screen.getByLabelText(/buscar por nombre/i), "ejecutivo");

    // "Director Comercial" ya no tiene fila propia (queda sólo como texto de "reporta a" en
    // la fila de Ejecutivo de Ventas), así que se verifica por el link de la fila, no por texto.
    expect(
      screen.queryByRole("link", { name: "Director Comercial" })
    ).not.toBeInTheDocument();
    expect(screen.getByText("Ejecutivo de Ventas")).toBeInTheDocument();
  });

  it("muestra el estado vacío cuando no hay puestos", async () => {
    mockApiFetch(new Response(JSON.stringify([])));

    render(<DirectorioPuestosPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no hay puestos registrados o tu cuenta no tiene acceso al catálogo/i)
      ).toBeInTheDocument()
    );
  });

  it("muestra el estado de error con opción de reintentar", async () => {
    mockApiFetch(new Response(null, { status: 500 }));

    render(<DirectorioPuestosPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el listado de puestos/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });

  describe("organigrama (híbrido: árbol grande con toggle + click filtra el catálogo)", () => {
    const ASIGNACION_VIGENTE = { puesto_id: "puesto-1", vigente_hasta: null };

    it("por defecto muestra el catálogo; la pestaña 'Organigrama' muestra el árbol de puestos", async () => {
      mockApiFetch(new Response(JSON.stringify(PUESTOS)), undefined, new Response(JSON.stringify([])));
      render(<DirectorioPuestosPage />);

      await waitFor(() => expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0));
      expect(screen.getByRole("tab", { name: "Catálogo" })).toHaveAttribute("aria-selected", "true");

      await userEvent.click(screen.getByRole("tab", { name: "Organigrama" }));

      expect(screen.getByRole("tab", { name: "Organigrama" })).toHaveAttribute(
        "aria-selected",
        "true"
      );
      // el árbol muestra ambos puestos (activo e inactivo) — el catálogo de la tabla ya no está
      expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0);
      expect(screen.getByText("Ejecutivo de Ventas")).toBeInTheDocument();
      expect(screen.queryByRole("cell")).not.toBeInTheDocument();
    });

    it("click en un nodo vuelve al catálogo, filtrado a ese puesto y su rama, con chip removible", async () => {
      mockApiFetch(
        new Response(JSON.stringify(PUESTOS)),
        undefined,
        new Response(JSON.stringify([ASIGNACION_VIGENTE]))
      );
      render(<DirectorioPuestosPage />);

      await waitFor(() => expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0));
      await userEvent.click(screen.getByRole("tab", { name: "Organigrama" }));
      await userEvent.click(screen.getByText("Director Comercial"));

      expect(screen.getByRole("tab", { name: "Catálogo" })).toHaveAttribute("aria-selected", "true");
      expect(screen.getByText(/filtrado por: director comercial y su equipo/i)).toBeInTheDocument();
      // Director Comercial es la raíz -- su rama incluye a Ejecutivo de Ventas, así que ambos siguen
      expect(screen.getByText("Ejecutivo de Ventas")).toBeInTheDocument();

      await userEvent.click(screen.getByRole("button", { name: /quitar filtro/i }));
      expect(screen.queryByText(/filtrado por:/i)).not.toBeInTheDocument();
    });

    it("en el organigrama, un puesto sin asignaciones vigentes muestra el total de plazas sin fracción de ocupadas", async () => {
      mockApiFetch(new Response(JSON.stringify(PUESTOS)), undefined, new Response(JSON.stringify([])));
      render(<DirectorioPuestosPage />);

      await waitFor(() => expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0));
      await userEvent.click(screen.getByRole("tab", { name: "Organigrama" }));

      const nodo = screen.getByText("Director Comercial").closest('[role="button"]')!;
      expect(nodo).toHaveTextContent("1 plazas");
    });

    it("con una asignación vigente, el nodo muestra ocupadas/plazas", async () => {
      mockApiFetch(
        new Response(JSON.stringify(PUESTOS)),
        undefined,
        new Response(JSON.stringify([ASIGNACION_VIGENTE]))
      );
      render(<DirectorioPuestosPage />);

      await waitFor(() => expect(screen.getAllByText("Director Comercial").length).toBeGreaterThan(0));
      await userEvent.click(screen.getByRole("tab", { name: "Organigrama" }));

      const nodo = screen.getByText("Director Comercial").closest('[role="button"]')!;
      expect(nodo).toHaveTextContent("1/1 ocupadas");
    });
  });
});
