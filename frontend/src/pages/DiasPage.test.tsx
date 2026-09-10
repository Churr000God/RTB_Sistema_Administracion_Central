import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DiasPage } from "./DiasPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const DIA_BLOQUEADO = {
  id: 10,
  fecha: "2026-09-07",
  persona_id: "persona-1",
  persona_nombre: "Persona Ficticia Uno",
  estado: "bloqueado",
  horas_totales: null,
  origen: null,
  primera_marca: "2026-09-07T08:00:00Z",
  ultima_marca: "2026-09-07T17:00:00Z",
  alerta_entrada: "retardo",
  alerta_salida: "salida_tardia",
  excepciones_pendientes: 0,
};

const DIA_ABIERTO = {
  id: 11,
  fecha: "2026-09-07",
  persona_id: "persona-2",
  persona_nombre: "Otra Persona",
  estado: "abierto",
  horas_totales: 0,
  origen: null,
  primera_marca: null,
  ultima_marca: null,
  alerta_entrada: null,
  alerta_salida: null,
  excepciones_pendientes: 0,
};

const DIA_REVISADO = {
  ...DIA_BLOQUEADO,
  id: 12,
  persona_nombre: "Tercera Persona",
  estado: "revisado",
  alerta_entrada: "entrada_anticipada",
  alerta_salida: "salida_anticipada",
};

function mockApiFetch(
  opciones: {
    dias?: Response;
    revisar?: Response;
    previsualizar?: Response;
    pendientesCorte?: Response;
  } = {},
) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/dias/pendientes-corte-quincenal") {
      return Promise.resolve(
        opciones.pendientesCorte ??
          new Response(
            JSON.stringify({ periodo_desde: "2026-09-01", periodo_hasta: "2026-09-15", personas: [] }),
          ),
      );
    }
    if (path.startsWith("/api/dias?")) {
      return Promise.resolve(
        opciones.dias ?? new Response(JSON.stringify({ total: 1, dias: [DIA_BLOQUEADO] })),
      );
    }
    if (path.endsWith("/previsualizar-tramos")) {
      return Promise.resolve(
        opciones.previsualizar ??
          new Response(JSON.stringify({ horas_calculadas: 7.5, tiene_huerfana_sin_pareja: false })),
      );
    }
    if (path.endsWith("/revisar") && init?.method === "POST") {
      return Promise.resolve(
        opciones.revisar ?? new Response(JSON.stringify({ ...DIA_BLOQUEADO, estado: "revisado" })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

async function abrirYCalcular() {
  await userEvent.click(screen.getByRole("button", { name: /marcar como revisado/i }));
  await userEvent.click(screen.getByRole("button", { name: /calcular tiempo total/i }));
  await waitFor(() => expect(screen.getByLabelText(/horas trabajadas/i)).toBeInTheDocument());
}

describe("DiasPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("badges de estado bloqueado/revisado y de las 4 alertas", async () => {
    mockApiFetch({
      dias: new Response(JSON.stringify({ total: 2, dias: [DIA_BLOQUEADO, DIA_REVISADO] })),
    });

    render(<DiasPage />);

    const filaBloqueado = await waitFor(() =>
      screen.getByRole("row", { name: /persona ficticia uno/i }),
    );
    expect(within(filaBloqueado).getByText(/bloqueado.*necesita revisión/i)).toBeInTheDocument();
    expect(within(filaBloqueado).getByText("Retardo")).toBeInTheDocument();
    expect(within(filaBloqueado).getByText("Salida tardía")).toBeInTheDocument();

    const filaRevisado = screen.getByRole("row", { name: /tercera persona/i });
    expect(within(filaRevisado).getByText("Revisado")).toBeInTheDocument();
    expect(within(filaRevisado).getByText("Entrada anticipada")).toBeInTheDocument();
    expect(within(filaRevisado).getByText("Salida anticipada")).toBeInTheDocument();
  });

  it("horas_totales null (día bloqueado real) muestra — y no 0h 0m", async () => {
    mockApiFetch({
      dias: new Response(JSON.stringify({ total: 1, dias: [DIA_BLOQUEADO] })),
    });

    render(<DiasPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    const celdaHoras = within(fila).getAllByRole("cell")[4];
    expect(celdaHoras).toHaveTextContent("—");
    expect(celdaHoras).not.toHaveTextContent("0h 0m");
  });

  it('botón "Marcar como revisado" sólo aparece en filas bloqueadas', async () => {
    mockApiFetch({
      dias: new Response(JSON.stringify({ total: 2, dias: [DIA_BLOQUEADO, DIA_ABIERTO] })),
    });

    render(<DiasPage />);

    const filaBloqueado = await waitFor(() =>
      screen.getByRole("row", { name: /persona ficticia uno/i }),
    );
    expect(within(filaBloqueado).getByRole("button", { name: /marcar como revisado/i })).toBeInTheDocument();

    const filaAbierto = screen.getByRole("row", { name: /otra persona/i });
    expect(within(filaAbierto).queryByRole("button", { name: /marcar como revisado/i })).not.toBeInTheDocument();
  });

  it("click en Marcar como revisado abre la confirmación sin input de horas todavía, sólo Calcular", async () => {
    mockApiFetch();

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /marcar como revisado/i }));

    expect(screen.getByText(/¿marcar como revisado el día de/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /calcular tiempo total/i })).toBeInTheDocument();
    expect(screen.queryByLabelText(/horas trabajadas/i)).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^confirmar$/i })).not.toBeInTheDocument();
    expect(
      vi.mocked(apiFetch).mock.calls.some(([path]) => (path as string).endsWith("/revisar")),
    ).toBe(false);
  });

  it("Calcular con tiene_huerfana_sin_pareja=true bloquea: mensaje, sin input ni Confirmar", async () => {
    mockApiFetch({
      previsualizar: new Response(
        JSON.stringify({ horas_calculadas: 0, tiene_huerfana_sin_pareja: true }),
      ),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /marcar como revisado/i }));
    await userEvent.click(screen.getByRole("button", { name: /calcular tiempo total/i }));

    await waitFor(() =>
      expect(screen.getByText(/marca sin pareja/i)).toBeInTheDocument(),
    );
    expect(screen.queryByLabelText(/horas trabajadas/i)).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^confirmar$/i })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /cancelar/i })).toBeInTheDocument();
  });

  it("Calcular con tiene_huerfana_sin_pareja=false precarga el input con horas_calculadas pero sigue editable", async () => {
    mockApiFetch({
      previsualizar: new Response(
        JSON.stringify({ horas_calculadas: 8.25, tiene_huerfana_sin_pareja: false }),
      ),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();

    const input = screen.getByLabelText(/horas trabajadas/i) as HTMLInputElement;
    expect(input.value).toBe("8.25");
    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeEnabled();

    await userEvent.clear(input);
    await userEvent.type(input, "6");
    expect(input.value).toBe("6");
    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeEnabled();
  });

  it("cancelar resetea el estado a calcular (no queda cacheado el cálculo)", async () => {
    mockApiFetch();

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();

    await userEvent.click(screen.getByRole("button", { name: /cancelar/i }));
    expect(screen.queryByText(/¿marcar como revisado el día de/i)).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: /marcar como revisado/i }));
    expect(screen.getByRole("button", { name: /calcular tiempo total/i })).toBeInTheDocument();
    expect(screen.queryByLabelText(/horas trabajadas/i)).not.toBeInTheDocument();
    expect(
      vi.mocked(apiFetch).mock.calls.some(([path]) => (path as string).endsWith("/revisar")),
    ).toBe(false);
  });

  it("confirmar sin horas válidas no dispara POST (botón deshabilitado)", async () => {
    mockApiFetch();

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();

    await userEvent.clear(screen.getByLabelText(/horas trabajadas/i));

    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeDisabled();
    expect(
      vi.mocked(apiFetch).mock.calls.some(([path]) => (path as string).endsWith("/revisar")),
    ).toBe(false);
  });

  it("valor de horas fuera de rango tampoco habilita Confirmar", async () => {
    mockApiFetch();

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();

    const input = screen.getByLabelText(/horas trabajadas/i);
    await userEvent.clear(input);
    await userEvent.type(input, "25");

    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeDisabled();
    expect(
      vi.mocked(apiFetch).mock.calls.some(([path]) => (path as string).endsWith("/revisar")),
    ).toBe(false);
  });

  it("confirmar con horas válidas dispara el POST con horas_totales y recarga el listado", async () => {
    mockApiFetch();

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();
    const input = screen.getByLabelText(/horas trabajadas/i);
    await userEvent.clear(input);
    await userEvent.type(input, "7.5");
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/dias/10/revisar",
        expect.objectContaining({ method: "POST" }),
      ),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => path === "/api/dias/10/revisar")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.horas_totales).toBe(7.5);

    const llamadasListado = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => (path as string).startsWith("/api/dias?"));
    expect(llamadasListado.length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText(/¿marcar como revisado el día de/i)).not.toBeInTheDocument();
  });

  it("409 muestra el mensaje del backend y NO cierra la confirmación", async () => {
    mockApiFetch({
      revisar: new Response(
        JSON.stringify({ detail: "El día ya no está bloqueado -- alguien más se te adelantó." }),
        { status: 409 },
      ),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() =>
      expect(screen.getByText(/alguien más se te adelantó/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/¿marcar como revisado el día de/i)).toBeInTheDocument();
  });

  it("404 muestra el mensaje del backend y NO cierra la confirmación", async () => {
    mockApiFetch({
      revisar: new Response(JSON.stringify({ detail: "El día no existe." }), { status: 404 }),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() => expect(screen.getByText(/el día no existe/i)).toBeInTheDocument());
    expect(screen.getByText(/¿marcar como revisado el día de/i)).toBeInTheDocument();
  });

  it("422 (horas fuera de rango que el backend rechaza) muestra el mensaje y NO cierra la confirmación", async () => {
    mockApiFetch({
      revisar: new Response(
        JSON.stringify({ detail: "Horas trabajadas inválidas: 24.5 (debe estar entre 0 y 24)" }),
        { status: 422 },
      ),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() =>
      expect(screen.getByText(/horas trabajadas inválidas/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/¿marcar como revisado el día de/i)).toBeInTheDocument();
  });

  it("409 por carrera (SCJ09, marca agregada entre calcular y confirmar) muestra el mensaje sin cerrar", async () => {
    mockApiFetch({
      revisar: new Response(
        JSON.stringify({ detail: "Se agregó una marca nueva -- volvé a calcular." }),
        { status: 409 },
      ),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    await abrirYCalcular();
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() => expect(screen.getByText(/volvé a calcular/i)).toBeInTheDocument());
    expect(screen.getByText(/¿marcar como revisado el día de/i)).toBeInTheDocument();
  });

  it("excepciones_pendientes=2 muestra el badge con el número correcto", async () => {
    const dia = { ...DIA_BLOQUEADO, excepciones_pendientes: 2 };
    mockApiFetch({ dias: new Response(JSON.stringify({ total: 1, dias: [dia] })) });

    render(<DiasPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    expect(within(fila).getByText("2 pendiente(s)")).toBeInTheDocument();
  });

  it("escribir en el buscador manda busqueda_persona en la query tras el debounce", async () => {
    mockApiFetch();

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    vi.useFakeTimers({ shouldAdvanceTime: true });
    const usuario = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    await usuario.type(screen.getByLabelText(/buscar por persona/i), "ana");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(300);
    });

    await vi.waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/dias?"));
      expect(llamadas.at(-1)![0]).toContain("busqueda_persona=ana");
    });
  });

  it("cambiar el filtro de estado resetea la paginación y manda estado= en la query", async () => {
    mockApiFetch({
      dias: new Response(JSON.stringify({ total: 25, dias: Array.from({ length: 20 }, (_, i) => ({ ...DIA_BLOQUEADO, id: 100 + i })) })),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Página 1")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /^siguiente$/i }));
    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/dias?"));
      expect(llamadas.at(-1)![0]).toContain("desplazamiento=20");
    });

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por estado/i), "bloqueado");

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/dias?"));
      const ultima = llamadas.at(-1)![0] as string;
      expect(ultima).toContain("estado=bloqueado");
      expect(ultima).toContain("desplazamiento=0");
    });
  });

  it("paginación deshabilita Anterior en la primera página y Siguiente en la última", async () => {
    mockApiFetch({
      dias: new Response(JSON.stringify({ total: 20, dias: Array.from({ length: 20 }, (_, i) => ({ ...DIA_BLOQUEADO, id: 100 + i })) })),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Página 1")).toBeInTheDocument());

    expect(screen.getByRole("button", { name: /^anterior$/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /^siguiente$/i })).toBeDisabled();
  });

  it("banner de pendientes de corte quincenal muestra el conteo y la lista de persona+fechas", async () => {
    mockApiFetch({
      pendientesCorte: new Response(
        JSON.stringify({
          periodo_desde: "2026-09-01",
          periodo_hasta: "2026-09-15",
          personas: [
            { persona_id: "p1", persona_nombre: "Ana Pérez", fechas_faltantes: ["2026-09-03", "2026-09-05"] },
            { persona_id: "p2", persona_nombre: "Beto Ruiz", fechas_faltantes: ["2026-09-07"] },
          ],
        }),
      ),
    });

    render(<DiasPage />);

    await waitFor(() =>
      expect(screen.getByText(/2 persona\(s\) con días sin marcar/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/03 sep 2026, 05 sep 2026/i)).toBeInTheDocument();
    const filaBeto = screen.getByText(/Beto Ruiz/i).closest("li")!;
    expect(within(filaBeto).getByText(/07 sep 2026/i)).toBeInTheDocument();
  });

  it("banner de pendientes de corte queda oculto cuando personas viene vacío", async () => {
    mockApiFetch();

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    expect(screen.queryByText(/días sin marcar/i)).not.toBeInTheDocument();
  });

  it("banner de pendientes de corte es colapsable", async () => {
    mockApiFetch({
      pendientesCorte: new Response(
        JSON.stringify({
          periodo_desde: "2026-09-01",
          periodo_hasta: "2026-09-15",
          personas: [{ persona_id: "p1", persona_nombre: "Ana Pérez", fechas_faltantes: ["2026-09-03"] }],
        }),
      ),
    });

    render(<DiasPage />);
    await waitFor(() => expect(screen.getByText(/Ana Pérez/i)).toBeInTheDocument());

    const boton = screen.getByRole("button", { name: /días sin marcar/i });
    expect(boton).toHaveAttribute("aria-expanded", "true");

    await userEvent.click(boton);
    expect(boton).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByText(/Ana Pérez/i)).not.toBeInTheDocument();

    await userEvent.click(boton);
    expect(boton).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText(/Ana Pérez/i)).toBeInTheDocument();
  });

  it("muestra el estado de error con Reintentar", async () => {
    mockApiFetch({ dias: new Response(null, { status: 500 }) });

    render(<DiasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudieron cargar los días/i)).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });
});
