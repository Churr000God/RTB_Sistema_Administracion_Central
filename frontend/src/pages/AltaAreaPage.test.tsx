import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AltaAreaPage } from "./AltaAreaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

describe("AltaAreaPage", () => {
  it("envía el nombre a POST /api/areas", async () => {
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

    render(<AltaAreaPage />);
    await userEvent.type(await screen.findByLabelText(/nombre del área/i), "Comercial");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/areas",
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamadaPost = vi.mocked(apiFetch).mock.calls.find(([path]) => path === "/api/areas")!;
    const cuerpo = JSON.parse(llamadaPost[1]!.body as string);
    expect(cuerpo.nombre_area).toBe("Comercial");
  });

  it("muestra error de nombre duplicado cuando el backend responde 409", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(null, { status: 409 }));
    });

    render(<AltaAreaPage />);
    await userEvent.type(await screen.findByLabelText(/nombre del área/i), "Comercial");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(screen.getByText(/ya existe un área con ese nombre/i)).toBeInTheDocument()
    );
  });

  it("muestra el detail real del backend cuando el gate rechaza con 403 (sin area_edicion)", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(
        new Response(
          JSON.stringify({
            detail: "No tenés el permiso necesario (area_lectura o area_edicion) para esta acción.",
          }),
          { status: 403 }
        )
      );
    });

    render(<AltaAreaPage />);
    await userEvent.type(await screen.findByLabelText(/nombre del área/i), "Comercial");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(
        screen.getByText(
          "No tenés el permiso necesario (area_lectura o area_edicion) para esta acción."
        )
      ).toBeInTheDocument()
    );
  });

  it("requiere el nombre del área (campo obligatorio del formulario)", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    });

    render(<AltaAreaPage />);
    const campo = await screen.findByLabelText(/nombre del área/i);
    expect(campo).toBeRequired();
  });
});
