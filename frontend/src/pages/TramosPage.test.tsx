import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { TramosPage } from "./TramosPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const TRAMO_1 = {
  id: 1,
  fecha: "2026-09-07",
  persona_id: "persona-1",
  persona_nombre: "Persona Ficticia Uno",
  inicio: "2026-09-07T08:00:00Z",
  fin: "2026-09-07T17:00:00Z",
  minutos_trabajados: 450,
  dia_estado: "cerrado",
  tipo: "ordinario",
};

const TRAMO_ABIERTO = {
  id: 2,
  fecha: "2026-09-07",
  persona_id: "persona-2",
  persona_nombre: "Otra Persona",
  inicio: "2026-09-07T08:00:00Z",
  fin: null,
  minutos_trabajados: null,
  dia_estado: "abierto",
  tipo: null,
};

function mockApiFetch(opciones: { tramos?: Response } = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path.startsWith("/api/tramos?")) {
      return Promise.resolve(
        opciones.tramos ?? new Response(JSON.stringify({ total: 1, tramos: [TRAMO_1] })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("TramosPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renderiza filas con persona, día, inicio, fin y minutos formateados", async () => {
    mockApiFetch();

    render(<TramosPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    const celdas = within(fila).getAllByRole("cell");
    expect(celdas[1]).toHaveTextContent("07 sep 2026");
    expect(celdas[3]).toHaveTextContent("02:00");
    expect(celdas[4]).toHaveTextContent("11:00");
    expect(celdas[5]).toHaveTextContent("7h 30m");
  });

  it("tramo abierto muestra el badge En curso y — en fin/minutos", async () => {
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [TRAMO_ABIERTO] })) });

    render(<TramosPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /otra persona/i }));
    expect(within(fila).getByText("En curso")).toBeInTheDocument();
    const celdas = within(fila).getAllByRole("cell");
    expect(celdas[5]).toHaveTextContent("—");
  });

  it("fin=null con dia_estado bloqueado muestra Sin cierre (día bloqueado), no En curso", async () => {
    const tramo = { ...TRAMO_ABIERTO, dia_estado: "bloqueado" };
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [tramo] })) });

    render(<TramosPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /otra persona/i }));
    expect(within(fila).getByText("Sin cierre (día bloqueado)")).toBeInTheDocument();
    expect(within(fila).queryByText("En curso")).not.toBeInTheDocument();
  });

  it("fin=null con dia_estado revisado muestra Sin cierre (día revisado)", async () => {
    const tramo = { ...TRAMO_ABIERTO, dia_estado: "revisado" };
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [tramo] })) });

    render(<TramosPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /otra persona/i }));
    expect(within(fila).getByText("Sin cierre (día revisado)")).toBeInTheDocument();
  });

  it("dia_estado bloqueado muestra el badge de alerta", async () => {
    const tramo = { ...TRAMO_1, dia_estado: "bloqueado" };
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [tramo] })) });

    render(<TramosPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    expect(within(fila).getByText(/bloqueado.*necesita revisión/i)).toBeInTheDocument();
  });

  it("dia_estado abierto no muestra badge de estado del día", async () => {
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [TRAMO_ABIERTO] })) });

    render(<TramosPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /otra persona/i }));
    const celdaEstadoDia = within(fila).getAllByRole("cell")[6];
    expect(celdaEstadoDia).toHaveTextContent("—");
  });

  it("tipo ordinario/reposicion/extra muestran su badge correspondiente", async () => {
    const tramoOrdinario = { ...TRAMO_1, tipo: "ordinario" };
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [tramoOrdinario] })) });
    const { unmount: unmount1 } = render(<TramosPage />);
    let fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    expect(within(fila).getByText("Ordinario")).toBeInTheDocument();
    unmount1();

    const tramoReposicion = { ...TRAMO_1, tipo: "reposicion" };
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [tramoReposicion] })) });
    const { unmount: unmount2 } = render(<TramosPage />);
    fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    expect(within(fila).getByText("Reposición")).toBeInTheDocument();
    unmount2();

    const tramoExtra = { ...TRAMO_1, tipo: "extra" };
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [tramoExtra] })) });
    render(<TramosPage />);
    fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    expect(within(fila).getByText("Extra")).toBeInTheDocument();
  });

  it("tipo null muestra Sin clasificar sin badge", async () => {
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 1, tramos: [TRAMO_ABIERTO] })) });

    render(<TramosPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /otra persona/i }));
    expect(within(fila).getByText("Sin clasificar")).toBeInTheDocument();
  });

  it("escribir en el buscador manda busqueda_persona en la query tras el debounce", async () => {
    mockApiFetch();

    render(<TramosPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Persona Ficticia Uno")).toBeInTheDocument(),
    );

    vi.useFakeTimers({ shouldAdvanceTime: true });
    const usuario = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    await usuario.type(screen.getByLabelText(/buscar por persona/i), "ana");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(300);
    });

    await vi.waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/tramos?"));
      expect(llamadas.at(-1)![0]).toContain("busqueda_persona=ana");
    });
  });

  it("cambiar el orden manda orden= y redispara la carga", async () => {
    mockApiFetch();

    render(<TramosPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Persona Ficticia Uno")).toBeInTheDocument(),
    );

    await userEvent.selectOptions(screen.getByLabelText(/ordenar por/i), "minutos_desc");

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/tramos?"));
      expect(llamadas.at(-1)![0]).toContain("orden=minutos_desc");
    });
  });

  it("muestra estado vacío y estado de error con Reintentar", async () => {
    mockApiFetch({ tramos: new Response(JSON.stringify({ total: 0, tramos: [] })) });

    const { unmount } = render(<TramosPage />);
    await waitFor(() =>
      expect(screen.getByText(/no hay tramos que coincidan/i)).toBeInTheDocument(),
    );
    unmount();

    mockApiFetch({ tramos: new Response(null, { status: 500 }) });
    render(<TramosPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudieron cargar los tramos/i)).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });
});
