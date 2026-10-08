import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { hrefRevisarDia } from "../lib/enlacesDias";
import { DiasPage } from "./DiasPage";

const UUID_PERSONA = "3f2b8c1e-9a4d-4e6f-8b1a-2c3d4e5f6a7b";

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
    tardias?: Response;
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
    if (path === "/api/excepciones?tipo=dia_cerrado") {
      return Promise.resolve(opciones.tardias ?? new Response(JSON.stringify([])));
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
    window.history.replaceState(null, "", "/");
  });

  describe("filtros desde la URL (Ir a revisar el día)", () => {
    function llamadaDias() {
      return vi
        .mocked(apiFetch)
        .mock.calls.map(([path]) => path as string)
        .find((path) => path.startsWith("/api/dias?"))!;
    }

    it("dia_id de la URL se manda a GET /api/dias y avisa que hay un filtro activo", async () => {
      window.history.replaceState(null, "", "/tiempo/dias?dia_id=10");
      mockApiFetch();
      render(<DiasPage />);
      await screen.findByRole("table");
      expect(new URLSearchParams(llamadaDias().split("?")[1]).get("dia_id")).toBe("10");
      expect(screen.getByText(/mostrando un día específico/i)).toBeInTheDocument();
    });

    it("persona_id, desde y hasta de la URL se mandan y rellenan los campos de fecha", async () => {
      window.history.replaceState(
        null,
        "",
        `/tiempo/dias?persona_id=${UUID_PERSONA}&desde=2026-09-07&hasta=2026-09-07`,
      );
      mockApiFetch();
      render(<DiasPage />);
      await screen.findByRole("table");
      const params = new URLSearchParams(llamadaDias().split("?")[1]);
      expect(params.get("persona_id")).toBe(UUID_PERSONA);
      expect(params.get("desde")).toBe("2026-09-07");
      expect(params.get("hasta")).toBe("2026-09-07");
      expect(screen.getByLabelText("Desde")).toHaveValue("2026-09-07");
    });

    it("Ver todos los días quita el filtro de la URL y recarga sin él", async () => {
      window.history.replaceState(null, "", "/tiempo/dias?dia_id=10");
      mockApiFetch();
      render(<DiasPage />);
      await screen.findByRole("table");
      await userEvent.click(screen.getByRole("button", { name: /ver todos los días/i }));
      await waitFor(() => {
        const ultima = vi
          .mocked(apiFetch)
          .mock.calls.map(([path]) => path as string)
          .filter((path) => path.startsWith("/api/dias?"))
          .at(-1)!;
        expect(new URLSearchParams(ultima.split("?")[1]).has("dia_id")).toBe(false);
      });
      expect(window.location.search).toBe("");
      expect(screen.queryByText(/mostrando un día específico/i)).not.toBeInTheDocument();
    });

    it.each([
      "?dia_id=abc",
      "?dia_id=-1",
      "?dia_id=1.5",
      "?persona_id=persona-1",
      "?desde=hoy&hasta=2026-99-99",
    ])("parámetros inválidos en la URL (%s) se ignoran: no se mandan ni hay banner", async (consulta) => {
      window.history.replaceState(null, "", `/tiempo/dias${consulta}`);
      mockApiFetch();
      render(<DiasPage />);
      await screen.findByRole("table");
      const params = new URLSearchParams(llamadaDias().split("?")[1]);
      for (const clave of ["dia_id", "persona_id", "desde", "hasta"]) expect(params.has(clave)).toBe(false);
      expect(screen.queryByText(/mostrando un día específico|mostrando los días de una persona/i)).not.toBeInTheDocument();
    });

    it.each([
      [{ diaId: 21, personaId: UUID_PERSONA, fecha: "2026-09-07" }, { dia_id: "21" }],
      [
        { diaId: null, personaId: UUID_PERSONA, fecha: "2026-09-07" },
        { persona_id: UUID_PERSONA, desde: "2026-09-07", hasta: "2026-09-07" },
      ],
    ])("el enlace de hrefRevisarDia(%j) llega a DiasPage como petición a /api/dias", async (datos, esperado) => {
      window.history.replaceState(null, "", hrefRevisarDia(datos));
      mockApiFetch();
      render(<DiasPage />);
      await screen.findByRole("table");
      const params: Record<string, string> = {};
      new URLSearchParams(llamadaDias().split("?")[1]).forEach((valor, clave) => {
        params[clave] = valor;
      });
      expect(params).toMatchObject(esperado);
    });

    it("sin parámetros en la URL no manda dia_id ni persona_id", async () => {
      mockApiFetch();
      render(<DiasPage />);
      await screen.findByRole("table");
      const params = new URLSearchParams(llamadaDias().split("?")[1]);
      expect(params.has("dia_id")).toBe(false);
      expect(params.has("persona_id")).toBe(false);
    });
  });

  describe("marcas tardías de días cerrados", () => {
    const TARDIA_REVISAR = {
      id: 1,
      es_dia_cerrado: true,
      persona_id: "persona-1",
      persona_nombre: "Persona Ficticia Uno",
      momento_dispositivo: "2026-09-08T01:20:00Z",
      dia_de_la_marca_id: 10,
      dia_de_la_marca_fecha: "2026-09-07",
      dia_de_la_marca_estado: "bloqueado",
      camino_resolucion: "revisar_dia",
    };
    const TARDIA_DESCARTAR = {
      ...TARDIA_REVISAR,
      id: 2,
      persona_id: "persona-3",
      persona_nombre: "Tercera Persona",
      dia_de_la_marca_id: 12,
      dia_de_la_marca_estado: "revisado",
      camino_resolucion: "descartar",
    };

    it("resume cuántas hay, cuántas por revisar el día y cuántas por descartar, con enlaces", async () => {
      mockApiFetch({ tardias: new Response(JSON.stringify([TARDIA_REVISAR, TARDIA_DESCARTAR])) });
      render(<DiasPage />);
      expect(
        await screen.findByText(/2 marcas tardías en días ya cerrados esperan resolución \(1 por revisar el día, 1 por descartar\)/i),
      ).toBeInTheDocument();
      expect(screen.getByRole("link", { name: /revisar este día/i })).toHaveAttribute(
        "href",
        "/tiempo/dias?dia_id=10",
      );
      expect(screen.getByRole("link", { name: /descartar en excepciones/i })).toHaveAttribute(
        "href",
        "/tiempo/excepciones",
      );
      expect(screen.getByRole("link", { name: /ver todas en excepciones pendientes/i })).toHaveAttribute(
        "href",
        "/tiempo/excepciones",
      );
    });

    it("cuenta 2 por revisar y 1 por descartar, y consulta el endpoint de día cerrado", async () => {
      mockApiFetch({
        tardias: new Response(
          JSON.stringify([
            TARDIA_REVISAR,
            { ...TARDIA_REVISAR, id: 3, persona_nombre: "Cuarta Persona", dia_de_la_marca_id: 13 },
            TARDIA_DESCARTAR,
          ]),
        ),
      });
      render(<DiasPage />);
      expect(await screen.findByText(/\(2 por revisar el día, 1 por descartar\)/i)).toBeInTheDocument();
      expect(apiFetch).toHaveBeenCalledWith("/api/excepciones?tipo=dia_cerrado");
    });

    it("una tardía sin camino de resolución no cuenta ni aparece", async () => {
      mockApiFetch({
        tardias: new Response(
          JSON.stringify([
            TARDIA_REVISAR,
            { ...TARDIA_DESCARTAR, id: 9, persona_nombre: "Sin Camino", camino_resolucion: null },
          ]),
        ),
      });
      render(<DiasPage />);
      expect(await screen.findByText(/1 marca tardía en un día ya cerrado espera resolución/i)).toBeInTheDocument();
      expect(screen.queryByText(/sin camino/i)).not.toBeInTheDocument();
    });

    it("sin marcas tardías o si el resumen falla, no aparece (best-effort)", async () => {
      mockApiFetch();
      const { unmount } = render(<DiasPage />);
      await screen.findByRole("table");
      expect(screen.queryByText(/marcas? tardías? en días ya cerrados/i)).not.toBeInTheDocument();
      unmount();

      mockApiFetch({ tardias: new Response(null, { status: 500 }) });
      render(<DiasPage />);
      await screen.findByRole("table");
      expect(screen.queryByText(/marcas? tardías? en días ya cerrados/i)).not.toBeInTheDocument();
    });

    it("la fila del día con marca tardía lo indica en la columna Excepciones", async () => {
      mockApiFetch({
        dias: new Response(
          JSON.stringify({ total: 1, dias: [{ ...DIA_BLOQUEADO, excepciones_pendientes: 1 }] }),
        ),
        tardias: new Response(JSON.stringify([TARDIA_REVISAR])),
      });
      render(<DiasPage />);
      const fila = await screen.findByRole("row", { name: /persona ficticia uno/i });
      expect(within(fila).getByText(/incluye 1 marca tardía/i)).toBeInTheDocument();
    });

    it("al revisar un día con marca tardía avisa qué pasa con ella (fn_dia_revisar)", async () => {
      mockApiFetch({
        dias: new Response(
          JSON.stringify({ total: 1, dias: [{ ...DIA_BLOQUEADO, excepciones_pendientes: 1 }] }),
        ),
        tardias: new Response(JSON.stringify([TARDIA_REVISAR])),
      });
      render(<DiasPage />);
      await screen.findByRole("row", { name: /persona ficticia uno/i });
      await userEvent.click(screen.getByRole("button", { name: /marcar como revisado/i }));
      expect(
        await screen.findByText(/las marcas tardías que queden dentro de un tramo se resuelven solas/i),
      ).toBeInTheDocument();
      expect(screen.getByText(/si alguna quedara sin pareja, no se revisa el día/i)).toBeInTheDocument();
    });
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
