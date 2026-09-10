import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DirectorioDepartamentosPage } from "./DirectorioDepartamentosPage";

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
  { id: "area-1", nombre_area: "Comercial", activo: true, creado_en: "", actualizado_en: "" },
  { id: "area-2", nombre_area: "Operaciones", activo: true, creado_en: "", actualizado_en: "" },
];

const DEPARTAMENTOS = [
  {
    id: "1",
    area_id: "area-1",
    nombre_departamento: "Ventas",
    activo: true,
    creado_en: "2026-08-31T00:00:00+00:00",
    actualizado_en: "2026-08-31T00:00:00+00:00",
  },
  {
    id: "2",
    area_id: "area-2",
    nombre_departamento: "Logística",
    activo: false,
    creado_en: "2026-08-31T00:00:00+00:00",
    actualizado_en: "2026-08-31T00:00:00+00:00",
  },
];

// La página resuelve /api/departamentos y /api/areas con Promise.all — hay que despachar por
// path, igual que /api/sesion del guard de AppShell (el body sólo se puede leer una vez).
function mockApiFetch(respuestaDepartamentos: Response, respuestaAreas?: Response) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/areas") {
      return Promise.resolve(respuestaAreas ?? new Response(JSON.stringify(AREAS)));
    }
    return Promise.resolve(respuestaDepartamentos);
  });
}

describe("DirectorioDepartamentosPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("lista los departamentos con el nombre del área resuelto", async () => {
    mockApiFetch(new Response(JSON.stringify(DEPARTAMENTOS)));

    render(<DirectorioDepartamentosPage />);

    await waitFor(() => expect(screen.getByText("Ventas")).toBeInTheDocument());
    expect(screen.getByText("Comercial")).toBeInTheDocument();
    expect(screen.getByText("Logística")).toBeInTheDocument();
    expect(screen.getByText("Operaciones")).toBeInTheDocument();
  });

  it("calcula las métricas (total, activos, inactivos)", async () => {
    mockApiFetch(new Response(JSON.stringify(DEPARTAMENTOS)));

    render(<DirectorioDepartamentosPage />);

    await waitFor(() => expect(screen.getByText("Ventas")).toBeInTheDocument());
    expect(screen.getByText("Activos").closest(".metrica")).toHaveTextContent("1");
    expect(screen.getByText("Inactivos").closest(".metrica")).toHaveTextContent("1");
  });

  it("filtra por texto de búsqueda", async () => {
    mockApiFetch(new Response(JSON.stringify(DEPARTAMENTOS)));

    render(<DirectorioDepartamentosPage />);
    await waitFor(() => expect(screen.getByText("Ventas")).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/buscar por nombre/i), "logística");

    expect(screen.queryByText("Ventas")).not.toBeInTheDocument();
    expect(screen.getByText("Logística")).toBeInTheDocument();
  });

  it("muestra el estado vacío cuando no hay departamentos", async () => {
    mockApiFetch(new Response(JSON.stringify([])));

    render(<DirectorioDepartamentosPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no hay departamentos registrados o tu cuenta no tiene acceso al catálogo/i)
      ).toBeInTheDocument()
    );
  });

  it("muestra el estado de error con opción de reintentar si falla /api/departamentos", async () => {
    mockApiFetch(new Response(null, { status: 500 }));

    render(<DirectorioDepartamentosPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no se pudo cargar el listado de departamentos/i)
      ).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });
});
