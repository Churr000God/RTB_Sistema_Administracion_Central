import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { BancoDeHorasPage } from "./BancoDeHorasPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const RESUMEN = {
  total_personas: 2,
  en_deuda: 1,
  sin_deuda: 1,
  horas_adeudadas: 4.5,
  horas_fuera_ventana: 0,
  personas_fuera_ventana: 0,
  personas_corte_pendiente: 0,
  personas_en_aviso: 0,
  personas_en_escalamiento: 0,
  aviso_pct: 100,
  escalamiento_pct: 200,
  ventana_meses: 6,
  top_en_deuda: [
    { persona_id: "persona-1", persona_nombre: "Persona Endeudada", monto: 4.5, meses_antiguedad_max: 1 },
  ],
};

const SALDO_ENDEUDADO = {
  persona_id: "persona-1",
  persona_nombre: "Persona Endeudada",
  monto: 4.5,
  vivo_desde: "2026-09-01T00:00:00Z",
  actualizado_en: "2026-09-06T10:00:00Z",
  horas_reciente: 4.5,
  horas_media: 0,
  horas_fuera_ventana: 0,
  meses_antiguedad_max: 1,
  conciliado: true,
  corte_pendiente: false,
  jornada_semanal_horas: 45,
  porcentaje_jornada_semanal: 10.0,
  nivel_alerta: "sin_alerta",
};

const SALDO_AL_CORRIENTE = {
  persona_id: "persona-2",
  persona_nombre: "Persona Al Corriente",
  monto: 0,
  vivo_desde: null,
  actualizado_en: "2026-09-06T10:00:00Z",
  horas_reciente: 0,
  horas_media: 0,
  horas_fuera_ventana: 0,
  meses_antiguedad_max: 0,
  conciliado: true,
  corte_pendiente: false,
  jornada_semanal_horas: 45,
  porcentaje_jornada_semanal: 0,
  nivel_alerta: "sin_alerta",
};

const SALDO_SINTETICO_CORTE_PENDIENTE = {
  persona_id: "persona-3",
  persona_nombre: "Persona Sin Marcar",
  monto: 0,
  vivo_desde: null,
  actualizado_en: null,
  horas_reciente: 0,
  horas_media: 0,
  horas_fuera_ventana: 0,
  meses_antiguedad_max: 0,
  conciliado: true,
  corte_pendiente: true,
  jornada_semanal_horas: null,
  porcentaje_jornada_semanal: null,
  nivel_alerta: null,
};

const MOVIMIENTOS = [
  {
    id: 2,
    creado_en: "2026-08-29T12:00:00Z",
    tipo: "cubrir",
    monto: -2.0,
    motivo: "cubrió falta",
    autor_nombre: null,
    saldo_corrido: 3.0,
    vivo: false,
  },
  {
    id: 1,
    creado_en: "2026-08-19T12:00:00Z",
    tipo: "generado_quincena",
    monto: 5.0,
    motivo: null,
    autor_nombre: null,
    saldo_corrido: 5.0,
    vivo: true,
  },
];

function mockApiFetch(
  opciones: { banco?: Response; movimientos?: Response; movimientoManual?: Response } = {},
) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path.startsWith("/api/banco-de-horas?")) {
      // .clone() -- este test dispara cargar() más de una vez contra el mismo Response fijo
      // (ej. refetch tras un movimiento manual exitoso), y el body de un Response sólo se puede
      // leer una vez.
      return Promise.resolve(
        opciones.banco
          ? opciones.banco.clone()
          : new Response(
              JSON.stringify({ total: 2, resumen: RESUMEN, saldos: [SALDO_ENDEUDADO, SALDO_AL_CORRIENTE] }),
            ),
      );
    }
    if (path.endsWith("/movimientos") && init?.method === "POST") {
      return Promise.resolve(
        opciones.movimientoManual ??
          new Response(JSON.stringify({ total: 3, movimientos: MOVIMIENTOS })),
      );
    }
    if (path.endsWith("/movimientos")) {
      return Promise.resolve(
        opciones.movimientos ?? new Response(JSON.stringify({ total: 2, movimientos: MOVIMIENTOS })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("BancoDeHorasPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("lista los saldos y muestra las métricas desde resumen", async () => {
    mockApiFetch();

    render(<BancoDeHorasPage />);

    const tabla = await screen.findByRole("table");
    await waitFor(() => expect(within(tabla).getByText("Persona Endeudada")).toBeInTheDocument());
    expect(within(tabla).getByText("Persona Al Corriente")).toBeInTheDocument();

    expect(screen.getByText("Personas con saldo").nextElementSibling).toHaveTextContent("2");
    expect(screen.getByText(/^en deuda$/i).nextElementSibling).toHaveTextContent("1");
    expect(screen.getByText("4.50 h acumuladas")).toBeInTheDocument();
    expect(screen.getByText(/fuera de ventana/i)).toBeInTheDocument();
    expect(screen.getByText(/mostrando 2 de 2 personas/i)).toBeInTheDocument();
  });

  it("muestra el top en deuda con gráfica de barras y la lista de personas sin deuda", async () => {
    mockApiFetch();

    render(<BancoDeHorasPage />);

    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Top en deuda" })).toBeInTheDocument(),
    );
    expect(screen.getByRole("heading", { name: "Sin deuda" })).toBeInTheDocument();
    const tabla = screen.getByRole("table");
    expect(within(tabla).getByText("Persona Al Corriente")).toBeInTheDocument();
  });

  it("filtro por tramo de antigüedad manda tramo_antiguedad= en la query y resetea la página", async () => {
    mockApiFetch();

    render(<BancoDeHorasPage />);
    const tablaTramo = await screen.findByRole("table");
    await waitFor(() => expect(within(tablaTramo).getByText("Persona Endeudada")).toBeInTheDocument());

    await userEvent.selectOptions(
      screen.getByLabelText(/filtrar por tramo de antigüedad/i),
      "fuera_ventana",
    );

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/banco-de-horas?"));
      const ultima = llamadas.at(-1)![0] as string;
      expect(ultima).toContain("tramo_antiguedad=fuera_ventana");
      expect(ultima).toContain("desplazamiento=0");
    });
  });

  it("escribir en el buscador manda busqueda_persona en la query tras el debounce", async () => {
    mockApiFetch();

    render(<BancoDeHorasPage />);
    const tablaBusqueda = await screen.findByRole("table");
    await waitFor(() =>
      expect(within(tablaBusqueda).getByText("Persona Endeudada")).toBeInTheDocument(),
    );

    vi.useFakeTimers({ shouldAdvanceTime: true });
    const usuario = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    await usuario.type(screen.getByLabelText(/buscar por nombre/i), "ana");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(300);
    });

    await vi.waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/banco-de-horas?"));
      expect(llamadas.at(-1)![0]).toContain("busqueda_persona=ana");
    });
  });

  it("paginación: Siguiente manda desplazamiento= y respeta los bordes", async () => {
    mockApiFetch({
      banco: new Response(
        JSON.stringify({
          total: 25,
          resumen: RESUMEN,
          saldos: Array.from({ length: 20 }, (_, i) => ({ ...SALDO_ENDEUDADO, persona_id: `p-${i}` })),
        }),
      ),
    });

    render(<BancoDeHorasPage />);
    await waitFor(() => expect(screen.getByText("Página 1")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: /^anterior$/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /^siguiente$/i })).toBeEnabled();

    await userEvent.click(screen.getByRole("button", { name: /^siguiente$/i }));

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/banco-de-horas?"));
      expect(llamadas.at(-1)![0]).toContain("desplazamiento=20");
    });
  });

  it("celda de horas fuera de ventana muestra badge peligro sólo si > 0", async () => {
    const conFueraVentana = { ...SALDO_ENDEUDADO, horas_fuera_ventana: 3.0 };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({ total: 1, resumen: RESUMEN, saldos: [conFueraVentana, SALDO_AL_CORRIENTE] }),
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const filaConDeuda = await waitFor(() =>
      within(tabla).getByRole("row", { name: /persona endeudada/i }),
    );
    expect(within(filaConDeuda).getByText("3.00 h")).toBeInTheDocument();

    const filaAlCorriente = within(tabla).getByRole("row", { name: /persona al corriente/i });
    // índice 5: Persona(0)/Saldo(1)/Nivel(2)/reciente(3)/media(4)/fuera_ventana(5)
    const celdaFueraVentana = within(filaAlCorriente).getAllByRole("cell")[5];
    expect(celdaFueraVentana).toHaveTextContent("—");
  });

  it("conciliado=false muestra el badge de aproximado", async () => {
    const sinConciliar = { ...SALDO_ENDEUDADO, conciliado: false };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({ total: 1, resumen: RESUMEN, saldos: [sinConciliar, SALDO_AL_CORRIENTE] }),
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));
    expect(within(fila).getByText("Aproximado")).toBeInTheDocument();

    const filaOk = within(tabla).getByRole("row", { name: /persona al corriente/i });
    expect(within(filaOk).queryByText("Aproximado")).not.toBeInTheDocument();
  });

  it("fila expandible pide el ledger y lo cachea (no refetch al reabrir)", async () => {
    let llamadasMovimientos = 0;
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
        );
      }
      if (path.startsWith("/api/banco-de-horas?")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({ total: 2, resumen: RESUMEN, saldos: [SALDO_ENDEUDADO, SALDO_AL_CORRIENTE] }),
          ),
        );
      }
      if (path === "/api/banco-de-horas/persona-1/movimientos") {
        llamadasMovimientos += 1;
        return Promise.resolve(new Response(JSON.stringify({ total: 2, movimientos: MOVIMIENTOS })));
      }
      return Promise.reject(new Error(`ruta no mockeada: ${path}`));
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));

    await userEvent.click(fila);
    await waitFor(() => expect(screen.getByText("cubrió falta")).toBeInTheDocument());
    expect(screen.getByText("Vigente")).toBeInTheDocument();
    expect(screen.getByText("Consumido")).toBeInTheDocument();
    expect(screen.getAllByText("Sistema")).toHaveLength(2);

    // colapsar
    await userEvent.click(fila);
    expect(screen.queryByText("cubrió falta")).not.toBeInTheDocument();

    // reabrir no refetchea
    await userEvent.click(fila);
    await waitFor(() => expect(screen.getByText("cubrió falta")).toBeInTheDocument());
    expect(llamadasMovimientos).toBe(1);
  });

  it('badge "Corte pendiente" aparece en la fila real y muestra la métrica nueva', async () => {
    const conCortePendiente = { ...SALDO_ENDEUDADO, corte_pendiente: true };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({
          total: 2,
          resumen: { ...RESUMEN, personas_corte_pendiente: 1 },
          saldos: [conCortePendiente, SALDO_AL_CORRIENTE],
        }),
      ),
    });

    const { container } = render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));
    expect(within(fila).getByText("Corte pendiente")).toBeInTheDocument();

    const filaOk = within(tabla).getByRole("row", { name: /persona al corriente/i });
    expect(within(filaOk).queryByText("Corte pendiente")).not.toBeInTheDocument();

    const bandaMetricas = container.querySelector(".banda-metricas") as HTMLElement;
    expect(within(bandaMetricas).getByText(/^corte pendiente$/i).nextElementSibling).toHaveTextContent(
      "1",
    );
  });

  it("fila sintética con actualizado_en null muestra — y el badge de corte pendiente", async () => {
    mockApiFetch({
      banco: new Response(
        JSON.stringify({
          total: 1,
          resumen: { ...RESUMEN, personas_corte_pendiente: 1 },
          saldos: [SALDO_SINTETICO_CORTE_PENDIENTE],
        }),
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() =>
      within(tabla).getByRole("row", { name: /persona sin marcar/i }),
    );
    expect(within(fila).getByText("Corte pendiente")).toBeInTheDocument();
    // índice 7: Persona(0)/Saldo(1)/Nivel(2)/reciente(3)/media(4)/fuera_ventana(5)/deuda desde(6)/actualizado(7)
    const celdaActualizado = within(fila).getAllByRole("cell")[7];
    expect(celdaActualizado).toHaveTextContent("—");
  });

  it("formulario de movimiento manual NO aparece si horas_fuera_ventana === 0", async () => {
    mockApiFetch();

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));

    await userEvent.click(fila);

    await waitFor(() => expect(screen.getByText("cubrió falta")).toBeInTheDocument());
    expect(screen.queryByLabelText(/^acción$/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/resolver deuda con/i)).not.toBeInTheDocument();
  });

  it("formulario de movimiento manual aparece si horas_fuera_ventana > 0, con max ligado al valor real", async () => {
    const conFueraVentana = { ...SALDO_ENDEUDADO, horas_fuera_ventana: 3.5 };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({ total: 1, resumen: RESUMEN, saldos: [conFueraVentana, SALDO_AL_CORRIENTE] }),
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));

    await userEvent.click(fila);

    expect(screen.getByText(/resolver deuda con/i)).toBeInTheDocument();
    const inputMonto = screen.getByLabelText(/monto \(horas\)/i) as HTMLInputElement;
    expect(inputMonto.max).toBe("3.5");
    expect(inputMonto.value).toBe("3.50");
  });

  it("botón Confirmar del movimiento manual queda deshabilitado sin motivo", async () => {
    const conFueraVentana = { ...SALDO_ENDEUDADO, horas_fuera_ventana: 3.5 };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({ total: 1, resumen: RESUMEN, saldos: [conFueraVentana, SALDO_AL_CORRIENTE] }),
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));
    await userEvent.click(fila);

    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeDisabled();

    await userEvent.type(screen.getByLabelText(/^motivo$/i), "Se perdona por acuerdo con RH.");
    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeEnabled();
  });

  it("POST exitoso actualiza el ledger mostrado y dispara un refetch de la lista principal", async () => {
    const conFueraVentana = { ...SALDO_ENDEUDADO, horas_fuera_ventana: 8 };
    const movimientosArrastre = [
      { id: 11, creado_en: "2026-02-20T12:00:00Z", tipo: "arrastrar", monto: 8.0, motivo: "renovación", autor_nombre: null, saldo_corrido: 0.0, vivo: true },
      { id: 10, creado_en: "2026-02-20T12:00:00Z", tipo: "arrastrar", monto: -8.0, motivo: "renovación", autor_nombre: null, saldo_corrido: -8.0, vivo: false },
    ];
    mockApiFetch({
      banco: new Response(
        JSON.stringify({ total: 1, resumen: RESUMEN, saldos: [conFueraVentana, SALDO_AL_CORRIENTE] }),
      ),
      movimientoManual: new Response(JSON.stringify({ total: 2, movimientos: movimientosArrastre })),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));
    await userEvent.click(fila);
    await waitFor(() => expect(screen.getByText("cubrió falta")).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/^motivo$/i), "renovación");
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/banco-de-horas/persona-1/movimientos",
        expect.objectContaining({ method: "POST" }),
      ),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(
        ([path, init]) =>
          path === "/api/banco-de-horas/persona-1/movimientos" &&
          (init as RequestInit)?.method === "POST",
      )!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.tipo).toBe("arrastrar");
    expect(cuerpo.monto).toBe(8);
    expect(cuerpo.motivo).toBe("renovación");

    // ledger actualizado con los 2 movimientos nuevos de "renovar"
    await waitFor(() => expect(screen.getAllByText("Arrastre")).toHaveLength(2));
    expect(screen.queryByText("cubrió falta")).not.toBeInTheDocument();

    // refetch de la lista principal
    const llamadasListado = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => (path as string).startsWith("/api/banco-de-horas?"));
    expect(llamadasListado.length).toBeGreaterThanOrEqual(2);
  });

  it("error del servidor al aplicar el movimiento se muestra inline sin cerrar el formulario", async () => {
    const conFueraVentana = { ...SALDO_ENDEUDADO, horas_fuera_ventana: 3 };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({ total: 1, resumen: RESUMEN, saldos: [conFueraVentana, SALDO_AL_CORRIENTE] }),
      ),
      movimientoManual: new Response(
        JSON.stringify({
          detail:
            "El monto excede la porción de deuda con 6+ meses de antigüedad de esta persona (3.00 h).",
        }),
        { status: 422 },
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const fila = await waitFor(() => within(tabla).getByRole("row", { name: /persona endeudada/i }));
    await userEvent.click(fila);

    await userEvent.type(screen.getByLabelText(/^motivo$/i), "intento inválido");
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() => expect(screen.getByText(/excede la porción de deuda/i)).toBeInTheDocument());
    // el formulario sigue ahí, con lo que la persona ya escribió
    expect(screen.getByLabelText(/^motivo$/i)).toHaveValue("intento inválido");
  });

  it("muestra estado vacío cuando la búsqueda no coincide con nadie", async () => {
    mockApiFetch({
      banco: new Response(JSON.stringify({ total: 0, resumen: RESUMEN, saldos: [] })),
    });

    render(<BancoDeHorasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay saldos que coincidan con la búsqueda/i)).toBeInTheDocument(),
    );
  });

  it("muestra el estado de error con Reintentar", async () => {
    mockApiFetch({ banco: new Response(null, { status: 500 }) });

    render(<BancoDeHorasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el banco de horas/i)).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });

  it("columna Nivel muestra el badge correcto para escalamiento, aviso, sin_alerta y null", async () => {
    const enEscalamiento = { ...SALDO_ENDEUDADO, persona_id: "p-esc", persona_nombre: "En Escalamiento", nivel_alerta: "escalamiento" };
    const enAviso = { ...SALDO_ENDEUDADO, persona_id: "p-avi", persona_nombre: "En Aviso", nivel_alerta: "aviso" };
    const sinAlerta = { ...SALDO_ENDEUDADO, persona_id: "p-sin", persona_nombre: "Sin Alerta", nivel_alerta: "sin_alerta" };
    const nivelNulo = { ...SALDO_ENDEUDADO, persona_id: "p-null", persona_nombre: "Sin Jornada", nivel_alerta: null };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({
          total: 4,
          resumen: RESUMEN,
          saldos: [enEscalamiento, enAviso, sinAlerta, nivelNulo],
        }),
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    await waitFor(() => expect(within(tabla).getByText("En Escalamiento")).toBeInTheDocument());

    const filaEscalamiento = within(tabla).getByRole("row", { name: /en escalamiento/i });
    expect(within(filaEscalamiento).getByText("Escalamiento")).toBeInTheDocument();

    const filaAviso = within(tabla).getByRole("row", { name: /^en aviso/i });
    expect(within(filaAviso).getByText("Aviso")).toBeInTheDocument();

    const filaSinAlerta = within(tabla).getByRole("row", { name: /sin alerta/i });
    // índice 2: Persona(0)/Saldo(1)/Nivel(2)
    expect(within(filaSinAlerta).getAllByRole("cell")[2]).toHaveTextContent("—");

    const filaNula = within(tabla).getByRole("row", { name: /sin jornada/i });
    expect(within(filaNula).getAllByRole("cell")[2]).toHaveTextContent("—");
  });

  it("filtro por nivel de alerta manda nivel_alerta= en la query y resetea la página", async () => {
    mockApiFetch();

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    await waitFor(() => expect(within(tabla).getByText("Persona Endeudada")).toBeInTheDocument());

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por nivel de alerta/i), "escalamiento");

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/banco-de-horas?"));
      const ultima = llamadas.at(-1)![0] as string;
      expect(ultima).toContain("nivel_alerta=escalamiento");
      expect(ultima).toContain("desplazamiento=0");
    });
  });

  it("banda de métricas muestra los contadores nuevos de aviso y escalamiento", async () => {
    mockApiFetch({
      banco: new Response(
        JSON.stringify({
          total: 2,
          resumen: { ...RESUMEN, personas_en_aviso: 3, personas_en_escalamiento: 1 },
          saldos: [SALDO_ENDEUDADO, SALDO_AL_CORRIENTE],
        }),
      ),
    });

    const { container } = render(<BancoDeHorasPage />);
    await waitFor(() => expect(screen.getByText("En aviso")).toBeInTheDocument());

    const bandaMetricas = container.querySelector(".banda-metricas") as HTMLElement;
    expect(within(bandaMetricas).getByText("En aviso").nextElementSibling).toHaveTextContent("3");
    expect(within(bandaMetricas).getByText("En escalamiento").nextElementSibling).toHaveTextContent(
      "1",
    );
  });

  it("fila expandida muestra la jornada semanal y el % de deuda, o el motivo cuando es null", async () => {
    const conJornada = { ...SALDO_ENDEUDADO, jornada_semanal_horas: 45, porcentaje_jornada_semanal: 10.0 };
    const sinJornada = { ...SALDO_AL_CORRIENTE, persona_id: "p-conf", persona_nombre: "De Confianza", jornada_semanal_horas: null, porcentaje_jornada_semanal: null, nivel_alerta: null };
    mockApiFetch({
      banco: new Response(
        JSON.stringify({ total: 2, resumen: RESUMEN, saldos: [conJornada, sinJornada] }),
      ),
    });

    render(<BancoDeHorasPage />);
    const tabla = await screen.findByRole("table");
    const filaConJornada = await waitFor(() =>
      within(tabla).getByRole("row", { name: /persona endeudada/i }),
    );
    await userEvent.click(filaConJornada);
    await waitFor(() =>
      expect(screen.getByText(/10% de una jornada semanal de 45.00 h/)).toBeInTheDocument(),
    );

    const filaSinJornada = within(tabla).getByRole("row", { name: /de confianza/i });
    await userEvent.click(filaSinJornada);
    await waitFor(() =>
      expect(
        screen.getByText(/sin jornada normal\/flexible vigente/i),
      ).toBeInTheDocument(),
    );
  });
});
