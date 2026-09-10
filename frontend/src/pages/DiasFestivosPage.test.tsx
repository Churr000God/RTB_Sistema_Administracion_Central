import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { aFechaISO } from "../lib/calendario";
import { DiasFestivosPage } from "./DiasFestivosPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

// Fechas fijas y deterministas para filtros — festivos reales de México, no dependen de "hoy".
const FESTIVOS_FIJOS = [
  { id: 4, fecha: "2025-12-25", nombre: "Navidad" },
  { id: 3, fecha: "2025-01-01", nombre: "Año Nuevo" },
  { id: 2, fecha: "2024-05-01", nombre: "Día del Trabajo" },
  { id: 1, fecha: "2024-01-01", nombre: "Año Nuevo" },
];

function manana(): string {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  return aFechaISO(d);
}

function ayer(): string {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return aFechaISO(d);
}

function hoy(): string {
  return aFechaISO(new Date());
}

function mockApiFetch(opciones: {
  festivos?: Festivo[];
  listado?: Response;
  post?: Response;
  delete?: Response | ((id: string) => Response);
} = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/dias-festivos" && (!init || init.method === undefined)) {
      return Promise.resolve(
        opciones.listado ?? new Response(JSON.stringify(opciones.festivos ?? FESTIVOS_FIJOS)),
      );
    }
    if (path === "/api/dias-festivos" && init?.method === "POST") {
      return Promise.resolve(opciones.post ?? new Response(JSON.stringify({ id: 99 }), { status: 201 }));
    }
    if (path.startsWith("/api/dias-festivos/") && init?.method === "DELETE") {
      const id = path.split("/").pop()!;
      if (typeof opciones.delete === "function") return Promise.resolve(opciones.delete(id));
      return Promise.resolve(opciones.delete ?? new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path} ${init?.method ?? "GET"}`));
  });
}

type Festivo = { id: number; fecha: string; nombre: string };

describe("DiasFestivosPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("carga con una sola llamada GET sin query string", async () => {
    mockApiFetch();

    render(<DiasFestivosPage />);

    await screen.findByText("Navidad");
    const llamadas = vi.mocked(apiFetch).mock.calls.filter(([path]) => path === "/api/dias-festivos");
    expect(llamadas).toHaveLength(1);
  });

  it("alta feliz recarga el listado", async () => {
    mockApiFetch();

    render(<DiasFestivosPage />);
    await screen.findByText("Navidad");

    await userEvent.type(screen.getByLabelText(/^fecha$/i), "2026-01-06");
    await userEvent.type(screen.getByLabelText(/^nombre$/i), "Día de Reyes");
    await userEvent.click(screen.getByRole("button", { name: /registrar día festivo/i }));

    await waitFor(() => {
      const llamadasGet = vi.mocked(apiFetch).mock.calls.filter(([path]) => path === "/api/dias-festivos");
      expect(llamadasGet.length).toBeGreaterThanOrEqual(2);
    });
    const llamadaPost = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/dias-festivos" && (init as RequestInit)?.method === "POST")!;
    expect(JSON.parse(llamadaPost[1]!.body as string)).toEqual({ fecha: "2026-01-06", nombre: "Día de Reyes" });
  });

  it("alta con 409 muestra el error y no recarga", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({ detail: "Ya existe un día festivo registrado en esa fecha." }),
        { status: 409 },
      ),
    });

    render(<DiasFestivosPage />);
    await screen.findByText("Navidad");

    await userEvent.type(screen.getByLabelText(/^fecha$/i), "2024-01-01");
    await userEvent.type(screen.getByLabelText(/^nombre$/i), "Año Nuevo");
    await userEvent.click(screen.getByRole("button", { name: /registrar día festivo/i }));

    await waitFor(() =>
      expect(
        screen.getByText("Ya existe un día festivo registrado en esa fecha."),
      ).toBeInTheDocument(),
    );
    const llamadasGet = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path, init]) => path === "/api/dias-festivos" && init?.method === undefined);
    expect(llamadasGet).toHaveLength(1); // sólo la carga inicial, no hubo recarga
  });

  it("filtra por año, mes y fecha exacta combinando con AND", async () => {
    mockApiFetch();

    render(<DiasFestivosPage />);
    const tabla = await screen.findByRole("table");
    expect(within(tabla).getAllByRole("row")).toHaveLength(5); // encabezado + 4

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por año/i), "2024");
    expect(within(tabla).getAllByRole("row")).toHaveLength(3); // encabezado + 2 de 2024

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por mes/i), "05");
    expect(within(tabla).getAllByRole("row")).toHaveLength(2); // encabezado + Día del Trabajo

    await userEvent.type(screen.getByLabelText(/fecha exacta/i), "2024-01-01");
    // año=2024 AND mes=05 AND fecha=2024-01-01 -> ninguno coincide a la vez
    await waitFor(() =>
      expect(screen.getByText(/ningún día festivo coincide con los filtros/i)).toBeInTheDocument(),
    );

    await userEvent.click(screen.getByRole("button", { name: /limpiar filtros/i }));
    expect(within(await screen.findByRole("table")).getAllByRole("row")).toHaveLength(5);
  });

  it("el botón Eliminar está deshabilitado para hoy/pasado y habilitado para futuro", async () => {
    const festivos = [
      { id: 10, fecha: manana(), nombre: "Festivo futuro" },
      { id: 11, fecha: hoy(), nombre: "Festivo de hoy" },
      { id: 12, fecha: ayer(), nombre: "Festivo pasado" },
    ];
    mockApiFetch({ festivos });

    render(<DiasFestivosPage />);
    await screen.findByText("Festivo futuro");

    expect(screen.getByRole("button", { name: /^eliminar festivo futuro$/i })).toBeEnabled();
    expect(
      screen.getByRole("button", { name: /no podés eliminar festivo de hoy/i }),
    ).toBeDisabled();
    expect(
      screen.getByRole("button", { name: /no podés eliminar festivo pasado/i }),
    ).toBeDisabled();
  });

  it("pide confirmación antes de eliminar, sin llamar DELETE hasta confirmar", async () => {
    const festivos = [{ id: 10, fecha: manana(), nombre: "Festivo futuro" }];
    mockApiFetch({ festivos });

    render(<DiasFestivosPage />);
    await screen.findByText("Festivo futuro");

    await userEvent.click(screen.getByRole("button", { name: /^eliminar festivo futuro$/i }));

    expect(screen.getByRole("alert")).toHaveTextContent(/¿eliminar el día festivo/i);
    expect(vi.mocked(apiFetch).mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(false);
  });

  it("confirmar elimina el id correcto y recarga", async () => {
    const festivos = [{ id: 10, fecha: manana(), nombre: "Festivo futuro" }];
    mockApiFetch({ festivos });

    render(<DiasFestivosPage />);
    await screen.findByText("Festivo futuro");

    await userEvent.click(screen.getByRole("button", { name: /^eliminar festivo futuro$/i }));
    await userEvent.click(screen.getByRole("button", { name: /sí, eliminar/i }));

    await waitFor(() => {
      const llamadaDelete = vi
        .mocked(apiFetch)
        .mock.calls.find(([, init]) => init?.method === "DELETE")!;
      expect(llamadaDelete[0]).toBe("/api/dias-festivos/10");
    });
    await waitFor(() => {
      const llamadasGet = vi.mocked(apiFetch).mock.calls.filter(([path]) => path === "/api/dias-festivos");
      expect(llamadasGet.length).toBeGreaterThanOrEqual(2);
    });
  });

  it("un 422 al eliminar se muestra sin cerrar la confirmación", async () => {
    const festivos = [{ id: 10, fecha: manana(), nombre: "Festivo futuro" }];
    mockApiFetch({
      festivos,
      delete: new Response(
        JSON.stringify({ detail: "Ya no se puede eliminar: la fecha dejó de ser futura." }),
        { status: 422 },
      ),
    });

    render(<DiasFestivosPage />);
    await screen.findByText("Festivo futuro");

    await userEvent.click(screen.getByRole("button", { name: /^eliminar festivo futuro$/i }));
    await userEvent.click(screen.getByRole("button", { name: /sí, eliminar/i }));

    await waitFor(() =>
      expect(
        screen.getByText("Ya no se puede eliminar: la fecha dejó de ser futura."),
      ).toBeInTheDocument(),
    );
    // la confirmación sigue abierta -- el botón "Sí, eliminar" sigue en pantalla.
    expect(screen.getByRole("button", { name: /sí, eliminar/i })).toBeInTheDocument();
  });

  it("dos estados vacíos distintos: sin festivos vs. ninguno coincide con los filtros", async () => {
    mockApiFetch({ festivos: [] });
    render(<DiasFestivosPage />);
    await waitFor(() =>
      expect(screen.getByText(/no hay días festivos registrados/i)).toBeInTheDocument(),
    );
  });

  it("muestra el estado de error con Reintentar", async () => {
    mockApiFetch({ listado: new Response(null, { status: 500 }) });

    render(<DiasFestivosPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no se pudo cargar el catálogo de días festivos/i),
      ).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });

  it("cambiar entre Lista y Calendario no dispara una nueva llamada a la API", async () => {
    mockApiFetch();

    render(<DiasFestivosPage />);
    await screen.findByText("Navidad");

    await userEvent.click(screen.getByRole("tab", { name: "Calendario" }));
    expect(screen.getByRole("tab", { name: "Mensual" })).toBeInTheDocument();

    await userEvent.click(screen.getByRole("tab", { name: "Lista" }));
    await screen.findByRole("table");

    const llamadas = vi.mocked(apiFetch).mock.calls.filter(([path]) => path === "/api/dias-festivos");
    expect(llamadas).toHaveLength(1);
  });

  it("resalta la celda del festivo en la vista mensual", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2024-01-15T12:00:00"));
    mockApiFetch();

    await act(async () => {
      render(<DiasFestivosPage />);
    });
    await act(async () => {
      await screen.findByText("Navidad");
    });

    await act(async () => {
      await userEvent.click(screen.getByRole("tab", { name: "Calendario" }));
    });

    expect(screen.getByText("Enero 2024")).toBeInTheDocument();
    const celdaFestivo = screen.getByText("Año Nuevo").closest(".celda-mes");
    expect(celdaFestivo).toHaveClass("celda-mes--festivo");
    expect(within(celdaFestivo as HTMLElement).getByText("1")).toBeInTheDocument();
  });

  it("navega mes anterior/siguiente/hoy en la vista mensual", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-03-15T12:00:00"));
    mockApiFetch();

    await act(async () => {
      render(<DiasFestivosPage />);
    });
    await act(async () => {
      await screen.findByText("Navidad");
    });
    await act(async () => {
      await userEvent.click(screen.getByRole("tab", { name: "Calendario" }));
    });

    expect(screen.getByText("Marzo 2026")).toBeInTheDocument();

    await act(async () => {
      await userEvent.click(screen.getByRole("button", { name: /anterior/i }));
    });
    expect(screen.getByText("Febrero 2026")).toBeInTheDocument();

    await act(async () => {
      await userEvent.click(screen.getByRole("button", { name: /siguiente/i }));
      await userEvent.click(screen.getByRole("button", { name: /siguiente/i }));
    });
    expect(screen.getByText("Abril 2026")).toBeInTheDocument();

    await act(async () => {
      await userEvent.click(screen.getByRole("button", { name: "Hoy" }));
    });
    expect(screen.getByText("Marzo 2026")).toBeInTheDocument();
  });

  it("navega semana anterior/siguiente en la vista semanal", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-09-09T12:00:00")); // miércoles, semana del 07 al 13 de sep
    mockApiFetch();

    await act(async () => {
      render(<DiasFestivosPage />);
    });
    await act(async () => {
      await screen.findByText("Navidad");
    });
    await act(async () => {
      await userEvent.click(screen.getByRole("tab", { name: "Calendario" }));
    });
    await act(async () => {
      await userEvent.click(screen.getByRole("tab", { name: "Semanal" }));
    });

    expect(screen.getByText(/07 sep 2026.*13 sep 2026/)).toBeInTheDocument();

    await act(async () => {
      await userEvent.click(screen.getByRole("button", { name: /siguiente/i }));
    });
    expect(screen.getByText(/14 sep 2026.*20 sep 2026/)).toBeInTheDocument();

    await act(async () => {
      await userEvent.click(screen.getByRole("button", { name: /anterior/i }));
      await userEvent.click(screen.getByRole("button", { name: /anterior/i }));
    });
    expect(screen.getByText(/31 ago 2026.*06 sep 2026/)).toBeInTheDocument();
  });
});
