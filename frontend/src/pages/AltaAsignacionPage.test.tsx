import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AltaAsignacionPage } from "./AltaAsignacionPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONAS_ACTIVAS = [
  { id: "persona-ficticia-1", primer_nombre: "Persona", apellido_paterno: "Ficticia Uno", estado: "activo" },
];

const PUESTOS_ACTIVOS = [
  { id: "puesto-ficticio-1", nombre_puesto: "Puesto Ficticio Uno", plazas_totales: 2, activo: true },
];

function mockApiFetch(opciones: {
  personas?: Response;
  puestos?: Response;
  asignaciones?: Response;
  post?: Response;
}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/personas") {
      return Promise.resolve(opciones.personas ?? new Response(JSON.stringify(PERSONAS_ACTIVAS)));
    }
    if (path === "/api/puestos") {
      return Promise.resolve(opciones.puestos ?? new Response(JSON.stringify(PUESTOS_ACTIVOS)));
    }
    if (path === "/api/asignaciones" && init?.method === "POST") {
      return Promise.resolve(opciones.post ?? new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(opciones.asignaciones ?? new Response(JSON.stringify([])));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("AltaAsignacionPage", () => {
  it("envía persona, puesto y fecha a POST /api/asignaciones", async () => {
    mockApiFetch({});

    render(<AltaAsignacionPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^persona$/i), "persona-ficticia-1");
    await userEvent.selectOptions(screen.getByLabelText(/^puesto$/i), "puesto-ficticio-1");
    await userEvent.type(screen.getByLabelText(/vigente desde/i), "2026-01-01");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/asignaciones",
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamadaPost = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/asignaciones" && (init as RequestInit)?.method === "POST")!;
    const cuerpo = JSON.parse(llamadaPost[1]!.body as string);
    expect(cuerpo.persona_id).toBe("persona-ficticia-1");
    expect(cuerpo.puesto_id).toBe("puesto-ficticio-1");
    expect(cuerpo.vigente_desde).toBe("2026-01-01");
  });

  it("muestra el detail real del backend en 422 (ej. persona ya no activa)", async () => {
    mockApiFetch({
      post: new Response(JSON.stringify({ detail: "La persona no existe o no está activa." }), {
        status: 422,
      }),
    });

    render(<AltaAsignacionPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^persona$/i), "persona-ficticia-1");
    await userEvent.selectOptions(screen.getByLabelText(/^puesto$/i), "puesto-ficticio-1");
    await userEvent.type(screen.getByLabelText(/vigente desde/i), "2026-01-01");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(screen.getByText("La persona no existe o no está activa.")).toBeInTheDocument()
    );
  });

  it("muestra el detail real del backend cuando el gate rechaza con 403 (sin asignacion_edicion)", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({
          detail: "No tenés el permiso necesario (asignacion_edicion) para esta acción.",
        }),
        { status: 403 }
      ),
    });

    render(<AltaAsignacionPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^persona$/i), "persona-ficticia-1");
    await userEvent.selectOptions(screen.getByLabelText(/^puesto$/i), "puesto-ficticio-1");
    await userEvent.type(screen.getByLabelText(/vigente desde/i), "2026-01-01");
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(
        screen.getByText("No tenés el permiso necesario (asignacion_edicion) para esta acción.")
      ).toBeInTheDocument()
    );
  });

  it("deshabilita el formulario cuando no hay personas activas", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify([])) });

    render(<AltaAsignacionPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay personas activas para asignar/i)).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/^persona$/i)).toBeDisabled();
    expect(screen.getByRole("button", { name: /registrar/i })).toBeDisabled();
  });

  it("deshabilita el formulario cuando no hay puestos activos", async () => {
    mockApiFetch({ puestos: new Response(JSON.stringify([])) });

    render(<AltaAsignacionPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay puestos activos disponibles/i)).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/^puesto$/i)).toBeDisabled();
    expect(screen.getByRole("button", { name: /registrar/i })).toBeDisabled();
  });

  it("muestra las plazas ocupadas del puesto seleccionado, calculadas contra /api/asignaciones", async () => {
    mockApiFetch({
      asignaciones: new Response(
        JSON.stringify([{ puesto_id: "puesto-ficticio-1", vigente_hasta: null }])
      ),
    });

    render(<AltaAsignacionPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^puesto$/i), "puesto-ficticio-1");

    await waitFor(() => expect(screen.getByText(/1\/2 ocupadas/i)).toBeInTheDocument());
  });

  it("avisa 'sin plazas libres' cuando todas las plazas del puesto están ocupadas", async () => {
    mockApiFetch({
      puestos: new Response(
        JSON.stringify([
          { id: "puesto-ficticio-1", nombre_puesto: "Puesto Ficticio Uno", plazas_totales: 1, activo: true },
        ])
      ),
      asignaciones: new Response(
        JSON.stringify([{ puesto_id: "puesto-ficticio-1", vigente_hasta: null }])
      ),
    });

    render(<AltaAsignacionPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/^puesto$/i), "puesto-ficticio-1");

    await waitFor(() => expect(screen.getByText(/sin plazas libres/i)).toBeInTheDocument());
  });
});
