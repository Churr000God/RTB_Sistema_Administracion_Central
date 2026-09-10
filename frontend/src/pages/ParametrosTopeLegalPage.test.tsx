import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ParametrosTopeLegalPage } from "./ParametrosTopeLegalPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const HISTORIAL = [
  { id: 2, vigente_desde: "2026-06-01", vigente_hasta: null, maximo_semanal: 48, maximo_extra: 9 },
  { id: 1, vigente_desde: "2025-01-01", vigente_hasta: "2026-05-31", maximo_semanal: 44, maximo_extra: 8 },
];

const EXCESO_CON_DATOS = {
  semana_desde: "2026-09-07",
  semana_hasta: "2026-09-13",
  maximo_semanal: 48,
  maximo_extra: 9,
  personas: [
    {
      persona_id: "p1",
      persona_nombre: "Persona Uno",
      horas_ordinarias: 50,
      horas_extra: 2,
      horas_reposicion: 0,
      supera_semanal: true,
      supera_extra: false,
      supera_combinado: false,
      exceso_semanal: 2,
      exceso_extra: 0,
      exceso_combinado: 0,
    },
    {
      persona_id: "p2",
      persona_nombre: "Persona Dos",
      horas_ordinarias: 48,
      horas_extra: 12,
      horas_reposicion: 1,
      supera_semanal: true,
      supera_extra: true,
      supera_combinado: true,
      exceso_semanal: 0.5,
      exceso_extra: 3,
      exceso_combinado: 5,
    },
  ],
};

function mockApiFetch(opciones: {
  historial?: Response;
  exceso?: Response | ((url: string) => Response);
  post?: Response | Response[];
} = {}) {
  let llamadaPost = 0;
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/tope-legal" && (!init || init.method === undefined)) {
      return Promise.resolve(opciones.historial ?? new Response(JSON.stringify(HISTORIAL)));
    }
    if (path === "/api/tope-legal" && init?.method === "POST") {
      if (Array.isArray(opciones.post)) {
        const respuesta = opciones.post[Math.min(llamadaPost, opciones.post.length - 1)];
        llamadaPost += 1;
        return Promise.resolve(respuesta);
      }
      return Promise.resolve(opciones.post ?? new Response(JSON.stringify(HISTORIAL[0]), { status: 201 }));
    }
    if (path.startsWith("/api/tope-legal/exceso-semanal")) {
      if (typeof opciones.exceso === "function") return Promise.resolve(opciones.exceso(path));
      return Promise.resolve(opciones.exceso ?? new Response(JSON.stringify(EXCESO_CON_DATOS)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("ParametrosTopeLegalPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("carga la vigencia actual y el historial completo", async () => {
    mockApiFetch();

    render(<ParametrosTopeLegalPage />);

    await waitFor(() =>
      expect(screen.getByText(/vigente desde 01 jun 2026/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/48 h semanales \/ 9 h extra/)).toBeInTheDocument();
    expect(screen.getByText(/01 ene 2025.*31 may 2026/)).toBeInTheDocument();
  });

  it("pide el exceso semanal de la semana actual por defecto (lunes correcto)", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-09-09T12:00:00")); // miércoles de la semana del 2026-09-07
    mockApiFetch();

    render(<ParametrosTopeLegalPage />);

    await act(async () => {
      await vi.waitFor(() => {
        const llamada = vi
          .mocked(apiFetch)
          .mock.calls.find(([path]) => (path as string).startsWith("/api/tope-legal/exceso-semanal"));
        expect(llamada?.[0]).toBe("/api/tope-legal/exceso-semanal?semana_de=2026-09-07");
      });
    });
  });

  it("envía el nuevo tope por POST sin confirma_cierre_vigente", async () => {
    mockApiFetch();

    render(<ParametrosTopeLegalPage />);
    await waitFor(() => expect(screen.getByText(/vigente desde 01 jun 2026/i)).toBeInTheDocument());

    await userEvent.clear(screen.getByLabelText(/máximo semanal/i));
    await userEvent.type(screen.getByLabelText(/máximo semanal/i), "50");
    await userEvent.clear(screen.getByLabelText(/máximo de horas extra/i));
    await userEvent.type(screen.getByLabelText(/máximo de horas extra/i), "10");
    await userEvent.type(screen.getByLabelText(/vigente desde/i), "2026-10-01");
    await userEvent.click(screen.getByRole("button", { name: /guardar nuevo tope/i }));

    await waitFor(() => {
      const llamada = vi
        .mocked(apiFetch)
        .mock.calls.find(
          ([path, init]) => path === "/api/tope-legal" && (init as RequestInit)?.method === "POST",
        )!;
      const cuerpo = JSON.parse(llamada[1]!.body as string);
      expect(cuerpo).toEqual({ vigente_desde: "2026-10-01", maximo_semanal: 50, maximo_extra: 10 });
    });
  });

  it("en 409 muestra el banner de confirmación y no reintenta solo", async () => {
    mockApiFetch({ post: new Response(null, { status: 409 }) });

    render(<ParametrosTopeLegalPage />);
    await waitFor(() => expect(screen.getByText(/vigente desde 01 jun 2026/i)).toBeInTheDocument());

    await userEvent.clear(screen.getByLabelText(/máximo semanal/i));
    await userEvent.type(screen.getByLabelText(/máximo semanal/i), "50");
    await userEvent.clear(screen.getByLabelText(/máximo de horas extra/i));
    await userEvent.type(screen.getByLabelText(/máximo de horas extra/i), "10");
    await userEvent.type(screen.getByLabelText(/vigente desde/i), "2026-10-01");
    await userEvent.click(screen.getByRole("button", { name: /guardar nuevo tope/i }));

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/ya hay un tope legal vigente/i),
    );
    const llamadasPost = vi
      .mocked(apiFetch)
      .mock.calls.filter(
        ([path, init]) => path === "/api/tope-legal" && (init as RequestInit)?.method === "POST",
      );
    expect(llamadasPost).toHaveLength(1);
  });

  it("al confirmar el cierre, reintenta con confirma_cierre_vigente:true", async () => {
    mockApiFetch({
      post: [
        new Response(null, { status: 409 }),
        new Response(JSON.stringify(HISTORIAL[0]), { status: 201 }),
      ],
    });

    render(<ParametrosTopeLegalPage />);
    await waitFor(() => expect(screen.getByText(/vigente desde 01 jun 2026/i)).toBeInTheDocument());

    await userEvent.clear(screen.getByLabelText(/máximo semanal/i));
    await userEvent.type(screen.getByLabelText(/máximo semanal/i), "50");
    await userEvent.clear(screen.getByLabelText(/máximo de horas extra/i));
    await userEvent.type(screen.getByLabelText(/máximo de horas extra/i), "10");
    await userEvent.type(screen.getByLabelText(/vigente desde/i), "2026-10-01");
    await userEvent.click(screen.getByRole("button", { name: /guardar nuevo tope/i }));

    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent(/ya hay un tope legal vigente/i));

    await userEvent.click(screen.getByRole("button", { name: /sí, cerrar el anterior y guardar/i }));

    await waitFor(() => {
      const llamadasPost = vi
        .mocked(apiFetch)
        .mock.calls.filter(
          ([path, init]) => path === "/api/tope-legal" && (init as RequestInit)?.method === "POST",
        );
      expect(llamadasPost).toHaveLength(2);
      const segundoCuerpo = JSON.parse(llamadasPost[1][1]!.body as string);
      expect(segundoCuerpo.confirma_cierre_vigente).toBe(true);
    });
  });

  it("cambiar la semana seleccionada dispara el GET con el lunes correcto", async () => {
    mockApiFetch();

    render(<ParametrosTopeLegalPage />);
    await waitFor(() => expect(screen.getByLabelText(/^semana$/i)).toBeInTheDocument());

    const inputSemana = screen.getByLabelText(/^semana$/i);
    await userEvent.clear(inputSemana);
    await userEvent.type(inputSemana, "2025-W01");

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/tope-legal/exceso-semanal"));
      expect(llamadas.at(-1)![0]).toBe("/api/tope-legal/exceso-semanal?semana_de=2024-12-30");
    });
  });

  it("muestra 1 badge de motivo para quien sólo supera lo semanal, y 3 para quien supera todo, con reposición sin badge propio", async () => {
    mockApiFetch();

    render(<ParametrosTopeLegalPage />);
    const tabla = await screen.findByRole("table");

    const filaUno = within(tabla).getByText("Persona Uno").closest("tr")!;
    expect(within(filaUno).getAllByText(/^Semanal|^Extra|^Combinado/)).toHaveLength(1);
    expect(within(filaUno).getByText("Semanal (+2.0 h)")).toBeInTheDocument();
    expect(within(filaUno).getByText("0.0")).toBeInTheDocument(); // horas_reposicion, sin badge

    const filaDos = within(tabla).getByText("Persona Dos").closest("tr")!;
    expect(within(filaDos).getAllByText(/^Semanal|^Extra|^Combinado/)).toHaveLength(3);
    expect(within(filaDos).getByText("Semanal (+0.5 h)")).toBeInTheDocument();
    expect(within(filaDos).getByText("Extra (+3.0 h)")).toBeInTheDocument();
    expect(within(filaDos).getByText("Combinado (+5.0 h)")).toBeInTheDocument();
    expect(within(filaDos).getByText("1.0")).toBeInTheDocument(); // horas_reposicion
  });

  it("muestra estado vacío cuando no hay tope configurado esa semana", async () => {
    mockApiFetch({
      exceso: new Response(
        JSON.stringify({ semana_desde: "2026-09-07", semana_hasta: "2026-09-13", maximo_semanal: null, maximo_extra: null, personas: [] }),
      ),
    });

    render(<ParametrosTopeLegalPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no hay un tope legal configurado para esta semana/i),
      ).toBeInTheDocument(),
    );
  });

  it("muestra estado vacío cuando hay tope pero nadie lo superó", async () => {
    mockApiFetch({
      exceso: new Response(
        JSON.stringify({ semana_desde: "2026-09-07", semana_hasta: "2026-09-13", maximo_semanal: 48, maximo_extra: 9, personas: [] }),
      ),
    });

    render(<ParametrosTopeLegalPage />);

    await waitFor(() =>
      expect(screen.getByText(/nadie superó el tope legal esta semana/i)).toBeInTheDocument(),
    );
  });
});
