import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AltaDepartamentoPage } from "./AltaDepartamentoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const AREAS_ACTIVAS = [
  { id: "area-1", nombre_area: "Comercial", activo: true },
  { id: "area-2", nombre_area: "Operaciones", activo: true },
];

function mockApiFetch(respuestaAreas: Response, respuestaPost?: Response) {
  vi.mocked(apiFetch).mockImplementation((path: string, opciones?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/areas") {
      return Promise.resolve(respuestaAreas);
    }
    if (path === "/api/departamentos" && opciones?.method === "POST") {
      return Promise.resolve(respuestaPost ?? new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("AltaDepartamentoPage", () => {
  it("envía area_id y nombre a POST /api/departamentos", async () => {
    mockApiFetch(new Response(JSON.stringify(AREAS_ACTIVAS)));

    render(<AltaDepartamentoPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^área$/i), "area-1");
    await userEvent.type(screen.getByLabelText(/nombre del departamento/i), "Ventas");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/departamentos",
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamadaPost = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => path === "/api/departamentos")!;
    const cuerpo = JSON.parse(llamadaPost[1]!.body as string);
    expect(cuerpo.area_id).toBe("area-1");
    expect(cuerpo.nombre_departamento).toBe("Ventas");
  });

  it("muestra el mensaje de área inválida cuando el backend responde 422", async () => {
    mockApiFetch(new Response(JSON.stringify(AREAS_ACTIVAS)), new Response(null, { status: 422 }));

    render(<AltaDepartamentoPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^área$/i), "area-1");
    await userEvent.type(screen.getByLabelText(/nombre del departamento/i), "Ventas");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/el área seleccionada no existe o ya no está activa/i)
      ).toBeInTheDocument()
    );
  });

  it("deshabilita el select y el botón cuando no hay áreas activas", async () => {
    mockApiFetch(new Response(JSON.stringify([{ id: "area-1", nombre_area: "Comercial", activo: false }])));

    render(<AltaDepartamentoPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no hay áreas activas\. da de alta o reactiva un área antes de crear un departamento/i)
      ).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/^área$/i)).toBeDisabled();
    expect(screen.getByRole("button", { name: /registrar/i })).toBeDisabled();
  });
});
