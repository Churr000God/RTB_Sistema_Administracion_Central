import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { TerminarAsignacionPage } from "./TerminarAsignacionPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const ASIGNACION_ID = "asignacion-ficticia-1";

const ASIGNACION = {
  id: ASIGNACION_ID,
  persona_id: "persona-ficticia-1",
  persona_nombre: "Persona Ficticia Uno",
  nombre_puesto: "Puesto Ficticio Uno",
  nombre_departamento: "Departamento Ficticio Uno",
};

function mockApiFetch(overrides: { get?: Response; patch?: (init: RequestInit) => Response }) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === `/api/asignaciones/${ASIGNACION_ID}/terminar` && init?.method === "PATCH") {
      return Promise.resolve(
        overrides.patch ? overrides.patch(init) : new Response(JSON.stringify(ASIGNACION))
      );
    }
    if (path === `/api/asignaciones/${ASIGNACION_ID}`) {
      return Promise.resolve(overrides.get ?? new Response(JSON.stringify(ASIGNACION)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/estructura/asignaciones/${ASIGNACION_ID}/terminar`]}>
      <Routes>
        <Route path="/estructura/asignaciones/:id/terminar" element={<TerminarAsignacionPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("TerminarAsignacionPage", () => {
  it("muestra la persona y el puesto de la asignación a terminar", async () => {
    mockApiFetch({});
    renderPagina();

    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    expect(screen.getByText(/puesto ficticio uno/i)).toBeInTheDocument();
  });

  it("envía vigente_hasta a PATCH /api/asignaciones/:id/terminar", async () => {
    mockApiFetch({});
    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/vigente hasta/i), "2026-07-01");
    await userEvent.click(screen.getByRole("button", { name: /confirmar término/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        `/api/asignaciones/${ASIGNACION_ID}/terminar`,
        expect.objectContaining({ method: "PATCH" })
      )
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(
        ([path, init]) =>
          path === `/api/asignaciones/${ASIGNACION_ID}/terminar` &&
          (init as RequestInit)?.method === "PATCH"
      )!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.vigente_hasta).toBe("2026-07-01");
  });

  it("muestra el detail real del backend cuando la asignación ya está cerrada (422)", async () => {
    mockApiFetch({
      patch: () =>
        new Response(JSON.stringify({ detail: "Esta asignación ya está cerrada." }), {
          status: 422,
        }),
    });
    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/vigente hasta/i), "2026-07-01");
    await userEvent.click(screen.getByRole("button", { name: /confirmar término/i }));

    await waitFor(() =>
      expect(screen.getByText("Esta asignación ya está cerrada.")).toBeInTheDocument()
    );
  });
});
