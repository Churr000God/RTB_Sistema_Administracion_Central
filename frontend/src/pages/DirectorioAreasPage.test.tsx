import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DirectorioAreasPage } from "./DirectorioAreasPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const AREAS = [
  {
    id: "1",
    nombre_area: "Comercial",
    activo: true,
    creado_en: "2026-08-31T00:00:00+00:00",
    actualizado_en: "2026-08-31T00:00:00+00:00",
  },
  {
    id: "2",
    nombre_area: "Operaciones",
    activo: false,
    creado_en: "2026-08-31T00:00:00+00:00",
    actualizado_en: "2026-08-31T00:00:00+00:00",
  },
];

// AppShell hace su propio GET /api/sesion al montar — cada consumidor necesita su propio
// Response (el body sólo se puede leer una vez), y una respuesta sin acceso_permitido:true
// dispararía el guard de sesión y redirigiría, rompiendo el resto del test.
function mockApiFetch(respuestaAreas: Response) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    return Promise.resolve(respuestaAreas);
  });
}

describe("DirectorioAreasPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("lista las áreas devueltas por el backend", async () => {
    mockApiFetch(new Response(JSON.stringify(AREAS)));

    render(<DirectorioAreasPage />);

    await waitFor(() => expect(screen.getByText("Comercial")).toBeInTheDocument());
    expect(screen.getByText("Operaciones")).toBeInTheDocument();
  });

  it("calcula las métricas (total, activas, inactivas)", async () => {
    mockApiFetch(new Response(JSON.stringify(AREAS)));

    render(<DirectorioAreasPage />);

    await waitFor(() => expect(screen.getByText("Comercial")).toBeInTheDocument());
    expect(screen.getByText("Activas").closest(".metrica")).toHaveTextContent("1");
    expect(screen.getByText("Inactivas").closest(".metrica")).toHaveTextContent("1");
  });

  it("filtra por texto de búsqueda", async () => {
    mockApiFetch(new Response(JSON.stringify(AREAS)));

    render(<DirectorioAreasPage />);
    await waitFor(() => expect(screen.getByText("Comercial")).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/buscar por nombre/i), "operaciones");

    expect(screen.queryByText("Comercial")).not.toBeInTheDocument();
    expect(screen.getByText("Operaciones")).toBeInTheDocument();
  });

  it("muestra el estado vacío cuando no hay áreas", async () => {
    mockApiFetch(new Response(JSON.stringify([])));

    render(<DirectorioAreasPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no hay áreas registradas o tu cuenta no tiene acceso al catálogo/i)
      ).toBeInTheDocument()
    );
  });

  it("muestra el estado de error con opción de reintentar", async () => {
    mockApiFetch(new Response(null, { status: 500 }));

    render(<DirectorioAreasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el listado de áreas/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });
});
