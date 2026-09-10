import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { CapturaManualMarcaPage } from "./CapturaManualMarcaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONAS_ACTIVAS = [
  { id: "persona-ficticia-1", primer_nombre: "Persona", apellido_paterno: "Ficticia Uno", estado: "activo" },
];

function mockApiFetch(opciones: { post?: Response }) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/personas") {
      return Promise.resolve(new Response(JSON.stringify(PERSONAS_ACTIVAS)));
    }
    if (path === "/api/marcas/captura-manual" && init?.method === "POST") {
      return Promise.resolve(
        opciones.post ??
          new Response(
            JSON.stringify({
              evento_id: "evento-1",
              duplicado: false,
              momento_dispositivo: "2026-09-06T10:00:00Z",
              momento_recepcion: "2026-09-06T12:00:00Z",
              requiere_revision: false,
              motivos_revision: [],
            }),
            { status: 201 },
          ),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

async function enviarCaptura() {
  await userEvent.selectOptions(await screen.findByLabelText(/^persona$/i), "persona-ficticia-1");
  await userEvent.click(screen.getByRole("button", { name: /confirmar marca/i }));
}

describe("CapturaManualMarcaPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("envío feliz: registra la marca y muestra la hora del servidor", async () => {
    mockApiFetch({});

    render(<CapturaManualMarcaPage />);
    await enviarCaptura();

    await waitFor(() => expect(screen.getByText(/marca registrada/i)).toBeInTheDocument());
    expect(screen.getAllByText(/06 sep 2026/i).length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText(/quedó marcada para revisión/i)).not.toBeInTheDocument();

    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => path === "/api/marcas/captura-manual")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.persona_id).toBe("persona-ficticia-1");
    expect(cuerpo.terminal_id).toBe("rh-captura-01");
    expect(typeof cuerpo.evento_id).toBe("string");
    expect(cuerpo.evento_id.length).toBeGreaterThan(0);
    expect(typeof cuerpo.momento_dispositivo).toBe("string");
    expect(Number.isNaN(new Date(cuerpo.momento_dispositivo).getTime())).toBe(false);
  });

  it("requiere_revision=true muestra los motivos combinados", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({
          evento_id: "evento-2",
          duplicado: false,
          momento_dispositivo: "2026-09-06T10:00:00Z",
          momento_recepcion: "2026-09-06T12:00:00Z",
          requiere_revision: true,
          motivos_revision: ["fuera_de_horario", "dia_cerrado"],
        }),
        { status: 201 },
      ),
    });

    render(<CapturaManualMarcaPage />);
    await enviarCaptura();

    await waitFor(() =>
      expect(screen.getByText(/quedó marcada para revisión/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/fuera de horario, día ya cerrado/i)).toBeInTheDocument();
  });

  it("evento_id duplicado (200) muestra 'Ya estaba registrada' sin insertar de nuevo", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({
          evento_id: "evento-3",
          duplicado: true,
          momento_dispositivo: "2026-09-06T10:00:00Z",
          momento_recepcion: "2026-09-06T12:00:00Z",
          requiere_revision: false,
          motivos_revision: [],
        }),
        { status: 200 },
      ),
    });

    render(<CapturaManualMarcaPage />);
    await enviarCaptura();

    await waitFor(() => expect(screen.getByText(/ya estaba registrada/i)).toBeInTheDocument());
    expect(screen.queryByText(/^marca registrada/i)).not.toBeInTheDocument();
  });

  it("envía la hora elegida por el usuario en el input, no la de ahora", async () => {
    mockApiFetch({});

    render(<CapturaManualMarcaPage />);
    const inputHora = await screen.findByLabelText(/momento del evento/i);
    fireEvent.change(inputHora, { target: { value: "2026-01-01T08:30" } });
    await enviarCaptura();

    await waitFor(() => expect(screen.getByText(/marca registrada/i)).toBeInTheDocument());
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => path === "/api/marcas/captura-manual")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.momento_dispositivo).toBe(new Date("2026-01-01T08:30").toISOString());
  });

  it("422 por hora futura o ventana vencida muestra el mensaje del backend", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({ detail: "La hora del dispositivo no puede ser futura." }),
        { status: 422 },
      ),
    });

    render(<CapturaManualMarcaPage />);
    await enviarCaptura();

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(
        /la hora del dispositivo no puede ser futura/i,
      ),
    );
  });
});
