import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { CambiarPuestoAsignacionPage } from "./CambiarPuestoAsignacionPage";

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
  puesto_id: "puesto-ficticio-actual",
  nombre_puesto: "Puesto Ficticio Actual",
};

const PUESTOS = [
  { id: "puesto-ficticio-actual", nombre_puesto: "Puesto Ficticio Actual", plazas_totales: 2, activo: true },
  { id: "puesto-ficticio-destino", nombre_puesto: "Puesto Ficticio Destino", plazas_totales: 1, activo: true },
];

function mockApiFetch(overrides: {
  asignacion?: Response;
  puestos?: Response;
  asignaciones?: Response;
  post?: (init: RequestInit) => Response;
}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === `/api/asignaciones/${ASIGNACION_ID}/cambiar-puesto` && init?.method === "POST") {
      return Promise.resolve(
        overrides.post ? overrides.post(init) : new Response(JSON.stringify(ASIGNACION))
      );
    }
    if (path === `/api/asignaciones/${ASIGNACION_ID}`) {
      return Promise.resolve(overrides.asignacion ?? new Response(JSON.stringify(ASIGNACION)));
    }
    if (path === "/api/puestos") {
      return Promise.resolve(overrides.puestos ?? new Response(JSON.stringify(PUESTOS)));
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(overrides.asignaciones ?? new Response(JSON.stringify([])));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/estructura/asignaciones/${ASIGNACION_ID}/cambiar-puesto`]}>
      <Routes>
        <Route
          path="/estructura/asignaciones/:id/cambiar-puesto"
          element={<CambiarPuestoAsignacionPage />}
        />
      </Routes>
    </MemoryRouter>
  );
}

describe("CambiarPuestoAsignacionPage", () => {
  it("muestra la persona y el puesto actual, y excluye el puesto actual de las opciones de destino", async () => {
    mockApiFetch({});
    renderPagina();

    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    expect(screen.getByText(/puesto actual: puesto ficticio actual/i)).toBeInTheDocument();

    const select = screen.getByLabelText(/puesto nuevo/i);
    expect(
      Array.from(select.querySelectorAll("option")).map((o) => o.textContent)
    ).not.toEqual(expect.arrayContaining([expect.stringMatching(/^Puesto Ficticio Actual/)]));
    expect(screen.getByRole("option", { name: /puesto ficticio destino/i })).toBeInTheDocument();
  });

  it("envía puesto_nuevo_id y fecha a POST /api/asignaciones/:id/cambiar-puesto", async () => {
    mockApiFetch({});
    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    await userEvent.selectOptions(screen.getByLabelText(/puesto nuevo/i), "puesto-ficticio-destino");
    await userEvent.type(screen.getByLabelText(/fecha del cambio/i), "2026-07-01");
    await userEvent.click(screen.getByRole("button", { name: /confirmar cambio/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        `/api/asignaciones/${ASIGNACION_ID}/cambiar-puesto`,
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(
        ([path, init]) =>
          path === `/api/asignaciones/${ASIGNACION_ID}/cambiar-puesto` &&
          (init as RequestInit)?.method === "POST"
      )!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.puesto_nuevo_id).toBe("puesto-ficticio-destino");
    expect(cuerpo.fecha).toBe("2026-07-01");
  });

  it("muestra el detail real del backend cuando el RPC rechaza el cambio (422)", async () => {
    mockApiFetch({
      post: () =>
        new Response(
          JSON.stringify({ detail: "La asignación no existe o ya está cerrada." }),
          { status: 422 }
        ),
    });
    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    await userEvent.selectOptions(screen.getByLabelText(/puesto nuevo/i), "puesto-ficticio-destino");
    await userEvent.type(screen.getByLabelText(/fecha del cambio/i), "2026-07-01");
    await userEvent.click(screen.getByRole("button", { name: /confirmar cambio/i }));

    await waitFor(() =>
      expect(
        screen.getByText("La asignación no existe o ya está cerrada.")
      ).toBeInTheDocument()
    );
  });
});
