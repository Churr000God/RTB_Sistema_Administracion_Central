import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { PanelCorridasBatchPage } from "./PanelCorridasBatchPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const CORRIDAS = [
  {
    id: 1,
    tipo_batch: "de_confianza",
    fecha: "2026-09-06",
    estado: "exitosa",
    intentos: 1,
    iniciado_en: "2026-09-06T10:00:00Z",
    terminado_en: "2026-09-06T10:00:05Z",
    detalle: "1 día(s) creado(s), 0 ya existían.",
  },
];

function mockApiFetch(opciones: {
  listado?: Response;
  disparar?: Response;
  dispararCorteQuincenal?: Response;
  dispararCierreDia?: Response;
}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/corridas-batch" && (!init || init.method === undefined)) {
      return Promise.resolve(opciones.listado ?? new Response(JSON.stringify(CORRIDAS)));
    }
    if (path === "/api/corridas-batch/de-confianza" && init?.method === "POST") {
      return Promise.resolve(
        opciones.disparar ?? new Response(JSON.stringify({ ...CORRIDAS[0], intentos: 2 })),
      );
    }
    if (path === "/api/corridas-batch/cierre-dia" && init?.method === "POST") {
      return Promise.resolve(
        opciones.dispararCierreDia ??
          new Response(
            JSON.stringify({
              id: 3,
              tipo_batch: "cierre_dia",
              fecha: "2026-09-08",
              estado: "exitosa",
              intentos: 1,
              iniciado_en: "2026-09-08T10:00:00Z",
              terminado_en: "2026-09-08T10:00:05Z",
              detalle: "3 día(s) cerrado(s), 0 con falta.",
            }),
          ),
      );
    }
    if (path === "/api/corridas-batch/corte-quincenal" && init?.method === "POST") {
      return Promise.resolve(
        opciones.dispararCorteQuincenal ??
          new Response(
            JSON.stringify({
              id: 2,
              tipo_batch: "corte_quincenal",
              fecha: "2026-09-16",
              estado: "exitosa",
              intentos: 1,
              iniciado_en: "2026-09-16T10:00:00Z",
              terminado_en: "2026-09-16T10:00:05Z",
              detalle: "periodo 2026-09-01 a 2026-09-15: 1 procesada(s), 0 con déficit, 0 ya procesada(s), 0 pendiente(s) de cierre de día.",
            }),
          ),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("PanelCorridasBatchPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("lista las corridas devueltas por GET /api/corridas-batch", async () => {
    mockApiFetch({});

    render(<PanelCorridasBatchPage />);

    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Jornada de confianza")).toBeInTheDocument(),
    );
    expect(screen.getByText("2026-09-06")).toBeInTheDocument();
    expect(screen.getByText("Exitosa")).toBeInTheDocument();
    expect(screen.getByText("1 día(s) creado(s), 0 ya existían.")).toBeInTheDocument();
  });

  it("muestra estado vacío cuando no hay corridas", async () => {
    mockApiFetch({ listado: new Response(JSON.stringify([])) });

    render(<PanelCorridasBatchPage />);

    await waitFor(() =>
      expect(screen.getByText(/todavía no hay corridas registradas/i)).toBeInTheDocument(),
    );
  });

  it("dispara la corrida manual de_confianza y recarga el listado", async () => {
    mockApiFetch({});

    render(<PanelCorridasBatchPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Jornada de confianza")).toBeInTheDocument(),
    );

    await userEvent.click(screen.getByRole("button", { name: /disparar jornada de confianza/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/corridas-batch/de-confianza",
        expect.objectContaining({ method: "POST" }),
      ),
    );
    // recarga: un segundo GET a /api/corridas-batch después del POST
    const llamadasListado = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path, init]) => path === "/api/corridas-batch" && !init?.method);
    expect(llamadasListado.length).toBeGreaterThanOrEqual(2);
  });

  it("muestra un error legible cuando el backend rechaza el disparo manual", async () => {
    mockApiFetch({
      disparar: new Response(
        JSON.stringify({ detail: "No tenés el permiso necesario (corrida_batch_edicion)." }),
        { status: 403 },
      ),
    });

    render(<PanelCorridasBatchPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Jornada de confianza")).toBeInTheDocument(),
    );

    await userEvent.click(screen.getByRole("button", { name: /disparar jornada de confianza/i }));

    await waitFor(() =>
      expect(
        screen.getByText("No tenés el permiso necesario (corrida_batch_edicion)."),
      ).toBeInTheDocument(),
    );
  });

  it("muestra el estado de error cuando falla la carga del listado", async () => {
    mockApiFetch({ listado: new Response(null, { status: 500 }) });

    render(<PanelCorridasBatchPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el listado de corridas/i)).toBeInTheDocument(),
    );
  });

  it("lista una corrida de corte_quincenal con la etiqueta correcta y dispara el tercer botón", async () => {
    mockApiFetch({
      listado: new Response(
        JSON.stringify([
          {
            id: 2,
            tipo_batch: "corte_quincenal",
            fecha: "2026-09-01",
            estado: "exitosa",
            intentos: 1,
            iniciado_en: "2026-09-01T10:00:00Z",
            terminado_en: "2026-09-01T10:00:05Z",
            detalle: "periodo 2026-08-16 a 2026-08-31: 1 procesada(s), 0 con déficit, 0 ya procesada(s), 0 pendiente(s) de cierre de día.",
          },
        ]),
      ),
    });

    render(<PanelCorridasBatchPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Corte quincenal")).toBeInTheDocument(),
    );

    await userEvent.click(screen.getByRole("button", { name: /disparar corte quincenal/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/corridas-batch/corte-quincenal",
        expect.objectContaining({ method: "POST" }),
      ),
    );
  });

  it("manda la fecha elegida en el body del POST al disparar de_confianza", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date(2026, 8, 9, 12, 0, 0));
    mockApiFetch({});

    render(<PanelCorridasBatchPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Jornada de confianza")).toBeInTheDocument(),
    );

    await userEvent.click(screen.getByRole("button", { name: /disparar jornada de confianza/i }));

    await waitFor(() => {
      const llamada = vi
        .mocked(apiFetch)
        .mock.calls.find(
          ([path, init]) => path === "/api/corridas-batch/de-confianza" && init?.method === "POST",
        );
      expect(llamada).toBeDefined();
      expect(llamada?.[1]?.headers).toMatchObject({ "Content-Type": "application/json" });
      expect(JSON.parse(llamada?.[1]?.body as string)).toEqual({ fecha: "2026-09-09" });
    });

    vi.useRealTimers();
  });

  it("inicializa cierre_dia con ayer y los otros dos batches con hoy", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date(2026, 8, 9, 12, 0, 0));
    mockApiFetch({});

    render(<PanelCorridasBatchPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Jornada de confianza")).toBeInTheDocument(),
    );

    const inputs = screen.getAllByLabelText(/fecha a procesar/i) as HTMLInputElement[];
    const [deConfianza, cierreDia, corteQuincenal] = inputs;
    expect(deConfianza.value).toBe("2026-09-09");
    expect(cierreDia.value).toBe("2026-09-08");
    expect(corteQuincenal.value).toBe("2026-09-09");

    vi.useRealTimers();
  });

  it("cambiar la fecha del selector y disparar refleja la fecha nueva en el body del POST", async () => {
    mockApiFetch({});

    render(<PanelCorridasBatchPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Jornada de confianza")).toBeInTheDocument(),
    );

    const inputs = screen.getAllByLabelText(/fecha a procesar/i) as HTMLInputElement[];
    const inputDeConfianza = inputs[0];
    fireEvent.change(inputDeConfianza, { target: { value: "2026-08-15" } });

    await userEvent.click(screen.getByRole("button", { name: /disparar jornada de confianza/i }));

    await waitFor(() => {
      const llamada = vi
        .mocked(apiFetch)
        .mock.calls.find(
          ([path, init]) => path === "/api/corridas-batch/de-confianza" && init?.method === "POST",
        );
      expect(JSON.parse(llamada?.[1]?.body as string)).toEqual({ fecha: "2026-08-15" });
    });
  });

  it("muestra un 422 del backend (bloqueo horario de cierre_dia) como texto en el alert", async () => {
    mockApiFetch({
      dispararCierreDia: new Response(
        JSON.stringify({ detail: "Todavía no es la hora de correr el cierre de día." }),
        { status: 422 },
      ),
    });

    render(<PanelCorridasBatchPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Jornada de confianza")).toBeInTheDocument(),
    );

    await userEvent.click(screen.getByRole("button", { name: /disparar cierre de día/i }));

    await waitFor(() =>
      expect(
        screen.getByText("Todavía no es la hora de correr el cierre de día."),
      ).toBeInTheDocument(),
    );
  });
});
