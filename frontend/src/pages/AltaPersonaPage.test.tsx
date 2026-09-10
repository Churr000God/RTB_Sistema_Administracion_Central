import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AltaPersonaPage } from "./AltaPersonaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

describe("AltaPersonaPage", () => {
  it("envía los datos del formulario a POST /api/personas", async () => {
    // AppShell hace su propio GET /api/sesion al montar — mockImplementation por path para
    // no compartir un único Response entre los dos consumidores (el body sólo se puede leer
    // una vez).
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    });

    render(<AltaPersonaPage />);
    await userEvent.type(await screen.findByLabelText(/primer nombre/i), "Mariana");
    await userEvent.type(screen.getByLabelText(/apellido paterno/i), "Alcántara");
    await userEvent.type(screen.getByLabelText(/curp/i), "AARM910427MDFLVR03");
    await userEvent.type(screen.getByLabelText(/rfc/i), "AARM910427H8A");
    await userEvent.type(screen.getByLabelText(/nss/i), "62119145338");
    await userEvent.type(screen.getByLabelText(/fecha de nacimiento/i), "1991-04-27");
    await userEvent.type(screen.getByLabelText(/fecha de ingreso/i), "2026-01-01");
    await userEvent.type(screen.getByLabelText(/documento_ref/i), "RTB-2026-001");
    await userEvent.click(screen.getByRole("button", { name: /registrar alta/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/personas",
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamadaPost = vi.mocked(apiFetch).mock.calls.find(([path]) => path === "/api/personas")!;
    const cuerpo = JSON.parse(llamadaPost[1]!.body as string);
    expect(cuerpo.curp).toBe("AARM910427MDFLVR03");
  });

  it("normaliza CURP y RFC a mayúsculas aunque se tipeen en minúsculas", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    });

    render(<AltaPersonaPage />);
    const curp = await screen.findByLabelText(/curp/i);
    const rfc = screen.getByLabelText(/rfc/i);

    await userEvent.type(curp, "aarm910427mdflvr03");
    await userEvent.type(rfc, "aarm910427h8a");

    expect(curp).toHaveValue("AARM910427MDFLVR03");
    expect(rfc).toHaveValue("AARM910427H8A");
  });
});
