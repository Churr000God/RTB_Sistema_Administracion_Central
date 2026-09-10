import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AlertasDeRetardoPage } from "./AlertasDeRetardoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONAS = [
  { id: "persona-1", primer_nombre: "Persona", apellido_paterno: "Ficticia Uno" },
];

const ALERTA_1 = {
  persona_id: "persona-1",
  persona_nombre: "Persona Ficticia Uno",
  fecha: "2026-09-05",
  hora_entrada_programada: "09:00:00",
  hora_salida_programada: "18:00:00",
  primera_marca: "2026-09-05T09:20:00Z",
  ultima_marca: "2026-09-05T18:00:00Z",
  motivo: "fuera_de_tolerancia",
};

function mockApiFetch(opciones: { alertas?: Response } = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/personas") {
      return Promise.resolve(new Response(JSON.stringify(PERSONAS)));
    }
    if (path.startsWith("/api/alertas-de-retardo")) {
      return Promise.resolve(
        opciones.alertas ?? new Response(JSON.stringify({ alertas: [ALERTA_1] })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("AlertasDeRetardoPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("carga las alertas con un rango de fechas por defecto", async () => {
    mockApiFetch();

    render(<AlertasDeRetardoPage />);

    const tabla = await screen.findByRole("table");
    expect(within(tabla).getByText("Persona Ficticia Uno")).toBeInTheDocument();
    expect(within(tabla).getByText("Fuera de tolerancia")).toBeInTheDocument();

    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => (path as string).startsWith("/api/alertas-de-retardo"))!;
    expect(llamada[0]).toMatch(/^\/api\/alertas-de-retardo\?desde=\d{4}-\d{2}-\d{2}&hasta=\d{4}-\d{2}-\d{2}$/);
  });

  it("agrega persona_id a la query al filtrar por persona", async () => {
    mockApiFetch();

    render(<AlertasDeRetardoPage />);
    await screen.findByRole("table");

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por persona/i), "persona-1");

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/alertas-de-retardo"));
      expect(llamadas.at(-1)![0]).toContain("persona_id=persona-1");
    });
  });

  it("muestra estado vacío cuando no hay alertas en el rango", async () => {
    mockApiFetch({ alertas: new Response(JSON.stringify({ alertas: [] })) });

    render(<AlertasDeRetardoPage />);

    await waitFor(() =>
      expect(screen.getByText(/sin alertas de retardo en el rango/i)).toBeInTheDocument(),
    );
  });

  it("muestra el mensaje del backend cuando el rango es inválido (422)", async () => {
    mockApiFetch({
      alertas: new Response(
        JSON.stringify({ detail: "El rango no puede superar 62 días." }),
        { status: 422 },
      ),
    });

    render(<AlertasDeRetardoPage />);

    await waitFor(() =>
      expect(screen.getByText("El rango no puede superar 62 días.")).toBeInTheDocument(),
    );
  });

  it("borrar el filtro Desde no dispara fetch y muestra el mensaje de rango incompleto, no el de error", async () => {
    mockApiFetch();

    render(<AlertasDeRetardoPage />);
    await screen.findByRole("table");
    const llamadasAntes = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => (path as string).startsWith("/api/alertas-de-retardo")).length;

    await userEvent.clear(screen.getByLabelText(/^desde$/i));

    await waitFor(() =>
      expect(
        screen.getByText(/selecciona un rango de fechas \(desde y hasta\) para ver alertas/i),
      ).toBeInTheDocument(),
    );
    expect(screen.queryByText(/no se pudo cargar las alertas de retardo/i)).not.toBeInTheDocument();
    expect(screen.queryByRole("table")).not.toBeInTheDocument();

    const llamadasDespues = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => (path as string).startsWith("/api/alertas-de-retardo")).length;
    expect(llamadasDespues).toBe(llamadasAntes);
  });

  it("borrar el filtro Hasta también muestra el mensaje de rango incompleto", async () => {
    mockApiFetch();

    render(<AlertasDeRetardoPage />);
    await screen.findByRole("table");

    await userEvent.clear(screen.getByLabelText(/^hasta$/i));

    await waitFor(() =>
      expect(
        screen.getByText(/selecciona un rango de fechas \(desde y hasta\) para ver alertas/i),
      ).toBeInTheDocument(),
    );
  });
});
