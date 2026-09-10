import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AltaPuestoPage } from "./AltaPuestoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const DEPARTAMENTOS_ACTIVOS = [{ id: "dep-1", nombre_departamento: "Ventas", activo: true }];
const PUESTOS_ACTIVOS = [{ id: "puesto-1", nombre_puesto: "Director Comercial", activo: true }];

function mockApiFetch(opciones: {
  departamentos?: Response;
  puestos?: Response;
  post?: Response;
}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/departamentos") {
      return Promise.resolve(
        opciones.departamentos ?? new Response(JSON.stringify(DEPARTAMENTOS_ACTIVOS))
      );
    }
    if (path === "/api/puestos" && init?.method === "POST") {
      return Promise.resolve(opciones.post ?? new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    }
    if (path === "/api/puestos") {
      return Promise.resolve(opciones.puestos ?? new Response(JSON.stringify(PUESTOS_ACTIVOS)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("AltaPuestoPage", () => {
  it("envía departamento, superior, nombre, nivel y plazas a POST /api/puestos", async () => {
    mockApiFetch({});

    render(<AltaPuestoPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^departamento$/i), "dep-1");
    await userEvent.selectOptions(screen.getByLabelText(/reporta a/i), "puesto-1");
    await userEvent.type(screen.getByLabelText(/nombre del puesto/i), "Ejecutivo de Ventas");
    await userEvent.selectOptions(screen.getByLabelText(/^nivel$/i), "operativo");
    const plazas = screen.getByLabelText(/plazas totales/i);
    await userEvent.clear(plazas);
    await userEvent.type(plazas, "5");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/puestos",
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamadaPost = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/puestos" && (init as RequestInit)?.method === "POST")!;
    const cuerpo = JSON.parse(llamadaPost[1]!.body as string);
    expect(cuerpo.departamento_id).toBe("dep-1");
    expect(cuerpo.reporta_a_id).toBe("puesto-1");
    expect(cuerpo.nombre_puesto).toBe("Ejecutivo de Ventas");
    expect(cuerpo.nivel).toBe("operativo");
    expect(cuerpo.plazas_totales).toBe(5);
  });

  it("muestra el detail real del backend cuando el departamento o el superior son inválidos (422)", async () => {
    mockApiFetch({
      post: new Response(JSON.stringify({ detail: "El departamento no existe o está inactivo." }), {
        status: 422,
      }),
    });

    render(<AltaPuestoPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^departamento$/i), "dep-1");
    await userEvent.selectOptions(screen.getByLabelText(/reporta a/i), "puesto-1");
    await userEvent.type(screen.getByLabelText(/nombre del puesto/i), "Ejecutivo de Ventas");
    await userEvent.selectOptions(screen.getByLabelText(/^nivel$/i), "operativo");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(screen.getByText("El departamento no existe o está inactivo.")).toBeInTheDocument()
    );
  });

  it("deshabilita el formulario cuando no hay departamentos activos", async () => {
    mockApiFetch({
      departamentos: new Response(
        JSON.stringify([{ id: "dep-1", nombre_departamento: "Ventas", activo: false }])
      ),
    });

    render(<AltaPuestoPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no hay departamentos activos\. da de alta o reactiva uno antes de crear un puesto/i)
      ).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/^departamento$/i)).toBeDisabled();
    expect(screen.getByRole("button", { name: /registrar/i })).toBeDisabled();
  });

  it("deshabilita el formulario cuando no hay puestos activos a los que reportar", async () => {
    mockApiFetch({ puestos: new Response(JSON.stringify([])) });

    render(<AltaPuestoPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay puestos activos a los que reportar/i)).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/reporta a/i)).toBeDisabled();
    expect(screen.getByRole("button", { name: /registrar/i })).toBeDisabled();
  });
});
