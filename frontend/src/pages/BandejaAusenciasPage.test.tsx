import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { BandejaAusenciasPage } from "./BandejaAusenciasPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const AUSENCIA_PENDIENTE = {
  id: 1,
  persona_id: "persona-1",
  persona_nombre: "Persona Ficticia",
  tipo_de_ausencia: "falta",
  fecha_inicio: "2026-09-06",
  fecha_fin: "2026-09-06",
  estado_autorizacion: "pendiente",
  documento_ref: null,
  aprobador_id: null,
  aprobador_nombre: null,
  motivo: null,
  decidido_en: null,
};

const AUSENCIA_AUTORIZADA = {
  id: 2,
  persona_id: "persona-2",
  persona_nombre: "Otra Persona",
  tipo_de_ausencia: "vacaciones",
  fecha_inicio: "2026-09-01",
  fecha_fin: "2026-09-05",
  estado_autorizacion: "autorizada",
  documento_ref: "DOC-123",
  aprobador_id: "persona-9",
  aprobador_nombre: "Jefa RH",
  motivo: "Vacaciones programadas.",
  decidido_en: "2026-08-30T10:00:00Z",
};

const AUSENCIA_RECHAZADA = {
  id: 3,
  persona_id: "persona-3",
  persona_nombre: "Tercera Persona",
  tipo_de_ausencia: "falta",
  fecha_inicio: "2026-09-03",
  fecha_fin: "2026-09-03",
  estado_autorizacion: "rechazada",
  documento_ref: null,
  aprobador_id: "persona-9",
  aprobador_nombre: "Jefa RH",
  motivo: "No justificó la ausencia.",
  decidido_en: "2026-09-04T10:00:00Z",
};

function mockApiFetch(opciones: { ausencias?: Response; resolver?: Response } = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path.startsWith("/api/ausencias?")) {
      return Promise.resolve(
        opciones.ausencias ??
          new Response(JSON.stringify({ total: 1, ausencias: [AUSENCIA_PENDIENTE] })),
      );
    }
    if (path.endsWith("/resolver") && init?.method === "POST") {
      return Promise.resolve(
        opciones.resolver ??
          new Response(JSON.stringify({ ...AUSENCIA_PENDIENTE, estado_autorizacion: "autorizada" })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("BandejaAusenciasPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("muestra la leyenda con las 5 descripciones de tipo de ausencia", async () => {
    mockApiFetch();

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());

    expect(screen.getByText("Toma el día completo como trabajado.")).toBeInTheDocument();
    expect(
      screen.getByText("Toma el día completo como trabajado, con goce de sueldo."),
    ).toBeInTheDocument();
    expect(screen.getByText("El día cuenta como no trabajado (0 horas).")).toBeInTheDocument();
    expect(
      screen.getByText("Toma el día completo como trabajado, respaldada por documento."),
    ).toBeInTheDocument();
    expect(
      screen.getByText(
        "Ausencia no justificada; si no se autoriza, el día cuenta como no trabajado.",
      ),
    ).toBeInTheDocument();
  });

  it("lista todas las ausencias, no sólo las pendientes", async () => {
    mockApiFetch({
      ausencias: new Response(
        JSON.stringify({
          total: 3,
          ausencias: [AUSENCIA_PENDIENTE, AUSENCIA_AUTORIZADA, AUSENCIA_RECHAZADA],
        }),
      ),
    });

    render(<BandejaAusenciasPage />);

    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    expect(screen.getByText("Otra Persona")).toBeInTheDocument();
    expect(screen.getByText("Tercera Persona")).toBeInTheDocument();
  });

  it('badge "Pendiente" aparece igual para estado pendiente y rechazada', async () => {
    mockApiFetch({
      ausencias: new Response(
        JSON.stringify({ total: 2, ausencias: [AUSENCIA_PENDIENTE, AUSENCIA_RECHAZADA] }),
      ),
    });

    render(<BandejaAusenciasPage />);

    const filaPendiente = await waitFor(() =>
      screen.getByRole("row", { name: /persona ficticia/i }),
    );
    expect(within(filaPendiente).getByText("Pendiente")).toBeInTheDocument();

    const filaRechazada = screen.getByRole("row", { name: /tercera persona/i });
    expect(within(filaRechazada).getByText("Pendiente")).toBeInTheDocument();
    expect(within(filaRechazada).queryByText("Rechazada")).not.toBeInTheDocument();
  });

  it("botón Resolver sólo aparece en filas genuinamente pendientes", async () => {
    mockApiFetch({
      ausencias: new Response(
        JSON.stringify({
          total: 3,
          ausencias: [AUSENCIA_PENDIENTE, AUSENCIA_AUTORIZADA, AUSENCIA_RECHAZADA],
        }),
      ),
    });

    render(<BandejaAusenciasPage />);

    const filaPendiente = await waitFor(() =>
      screen.getByRole("row", { name: /persona ficticia/i }),
    );
    expect(within(filaPendiente).getByRole("button", { name: /resolver/i })).toBeInTheDocument();

    const filaAutorizada = screen.getByRole("row", { name: /otra persona/i });
    expect(within(filaAutorizada).queryByRole("button", { name: /resolver/i })).not.toBeInTheDocument();

    const filaRechazada = screen.getByRole("row", { name: /tercera persona/i });
    expect(within(filaRechazada).queryByRole("button", { name: /resolver/i })).not.toBeInTheDocument();
  });

  it('columna "Aprobado por" muestra nombre y motivo cuando existen, "—" cuando no', async () => {
    mockApiFetch({
      ausencias: new Response(
        JSON.stringify({ total: 2, ausencias: [AUSENCIA_PENDIENTE, AUSENCIA_AUTORIZADA] }),
      ),
    });

    render(<BandejaAusenciasPage />);

    const filaAutorizada = await waitFor(() => screen.getByRole("row", { name: /otra persona/i }));
    expect(within(filaAutorizada).getByText("Jefa RH")).toBeInTheDocument();
    expect(within(filaAutorizada).getByText("Vacaciones programadas.")).toBeInTheDocument();

    const filaPendiente = screen.getByRole("row", { name: /persona ficticia/i });
    const celdaAprobadoPor = within(filaPendiente).getAllByRole("cell")[6];
    expect(celdaAprobadoPor).toHaveTextContent("—");
  });

  it("flujo completo: autorizar con reclasificación dispara el POST correcto y recarga", async () => {
    mockApiFetch();

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /resolver/i }));
    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeDisabled();

    await userEvent.click(screen.getByLabelText(/^autorizar$/i));
    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeDisabled();

    await userEvent.selectOptions(screen.getByLabelText(/reclasificar a/i), "vacaciones");
    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeEnabled();

    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/ausencias/1/resolver",
        expect.objectContaining({ method: "POST" }),
      ),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => path === "/api/ausencias/1/resolver")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.decision).toBe("autorizada");
    expect(cuerpo.tipo_de_ausencia).toBe("vacaciones");

    const llamadasListado = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => (path as string).startsWith("/api/ausencias?"));
    expect(llamadasListado.length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText(/resolver la ausencia de/i)).not.toBeInTheDocument();
  });

  it("rechazar no exige tipo de reclasificación", async () => {
    mockApiFetch();

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /resolver/i }));
    await userEvent.click(screen.getByLabelText(/rechazar/i));
    expect(screen.getByRole("button", { name: /^confirmar$/i })).toBeEnabled();
    expect(screen.queryByLabelText(/reclasificar a/i)).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    const llamada = await waitFor(() =>
      vi.mocked(apiFetch).mock.calls.find(([path]) => path === "/api/ausencias/1/resolver")!,
    );
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.decision).toBe("rechazada");
    expect(cuerpo.tipo_de_ausencia).toBeUndefined();
  });

  it("muestra el error del backend si la ausencia ya fue resuelta y no cierra la fila", async () => {
    mockApiFetch({
      resolver: new Response(
        JSON.stringify({ detail: "Esta ausencia ya fue resuelta -- alguien más se te adelantó." }),
        { status: 409 },
      ),
    });

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /resolver/i }));
    await userEvent.click(screen.getByLabelText(/rechazar/i));
    await userEvent.click(screen.getByRole("button", { name: /^confirmar$/i }));

    await waitFor(() =>
      expect(screen.getByText(/alguien más se te adelantó/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/resolver la ausencia de/i)).toBeInTheDocument();
  });

  it("cancelar cierra la fila sin disparar POST", async () => {
    mockApiFetch();

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /resolver/i }));

    await userEvent.click(screen.getByRole("button", { name: /cancelar/i }));

    expect(screen.queryByText(/resolver la ausencia de/i)).not.toBeInTheDocument();
    expect(
      vi.mocked(apiFetch).mock.calls.some(([path]) => (path as string).endsWith("/resolver")),
    ).toBe(false);
  });

  it("escribir en el buscador manda busqueda_persona en la query tras el debounce", async () => {
    mockApiFetch();

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());

    vi.useFakeTimers({ shouldAdvanceTime: true });
    const usuario = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    await usuario.type(screen.getByLabelText(/buscar por persona/i), "ana");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(300);
    });

    await vi.waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/ausencias?"));
      expect(llamadas.at(-1)![0]).toContain("busqueda_persona=ana");
    });
  });

  it("cambiar el filtro de tipo resetea la paginación y manda tipo= en la query", async () => {
    mockApiFetch({
      ausencias: new Response(
        JSON.stringify({
          total: 25,
          ausencias: Array.from({ length: 20 }, (_, i) => ({ ...AUSENCIA_PENDIENTE, id: 100 + i })),
        }),
      ),
    });

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Página 1")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /^siguiente$/i }));
    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/ausencias?"));
      expect(llamadas.at(-1)![0]).toContain("desplazamiento=20");
    });

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por tipo/i), "vacaciones");

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/ausencias?"));
      const ultima = llamadas.at(-1)![0] as string;
      expect(ultima).toContain("tipo=vacaciones");
      expect(ultima).toContain("desplazamiento=0");
    });
  });

  it("paginación deshabilita Anterior en la primera página y Siguiente en la última", async () => {
    mockApiFetch({
      ausencias: new Response(
        JSON.stringify({
          total: 20,
          ausencias: Array.from({ length: 20 }, (_, i) => ({ ...AUSENCIA_PENDIENTE, id: 100 + i })),
        }),
      ),
    });

    render(<BandejaAusenciasPage />);
    await waitFor(() => expect(screen.getByText("Página 1")).toBeInTheDocument());

    expect(screen.getByRole("button", { name: /^anterior$/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /^siguiente$/i })).toBeDisabled();
  });

  it("muestra estado vacío cuando no hay ausencias", async () => {
    mockApiFetch({ ausencias: new Response(JSON.stringify({ total: 0, ausencias: [] })) });

    render(<BandejaAusenciasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay ausencias que coincidan/i)).toBeInTheDocument(),
    );
  });

  it("muestra el estado de error con Reintentar", async () => {
    mockApiFetch({ ausencias: new Response(null, { status: 500 }) });

    render(<BandejaAusenciasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar la bandeja de ausencias/i)).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });
});
