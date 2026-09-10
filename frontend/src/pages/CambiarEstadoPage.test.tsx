import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { CambiarEstadoPage } from "./CambiarEstadoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

describe("CambiarEstadoPage", () => {
  it("exige motivo y envía el movimiento elegido", async () => {
    // Tres consumidores de apiFetch en esta pantalla: AppShell (GET /api/sesion), la propia
    // página (GET /api/personas/:id) y el submit (POST /movimientos) — cada uno necesita su
    // propio Response, no uno compartido (el body sólo se lee una vez).
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(JSON.stringify({ id: "m1" }), { status: 201 }));
    });

    render(
      <MemoryRouter initialEntries={["/personas/1/movimiento"]}>
        <Routes>
          <Route path="/personas/:id/movimiento" element={<CambiarEstadoPage />} />
        </Routes>
      </MemoryRouter>
    );

    await userEvent.click(await screen.findByLabelText(/suspensión/i));
    await userEvent.type(screen.getByLabelText(/motivo/i), "Licencia sin goce de sueldo");
    await userEvent.click(screen.getByRole("button", { name: /confirmar/i }));

    expect(apiFetch).toHaveBeenCalledWith(
      "/api/personas/1/movimientos",
      expect.objectContaining({ method: "POST" })
    );
  });
});
