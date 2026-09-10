import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { OtorgarPermisoPage } from "./OtorgarPermisoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PUESTOS_ACTIVOS = [
  { id: "puesto-ficticio-1", nombre_puesto: "Puesto Ficticio Uno", activo: true },
];

const PERMISOS_ACTIVOS = [
  { codigo: "permiso_ficticio_uno", heredable: false, activo: true },
  { codigo: "permiso_ficticio_heredable", heredable: true, activo: true },
];

function mockApiFetch(opciones: { puestos?: Response; permisos?: Response; post?: Response }) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/puestos") {
      return Promise.resolve(opciones.puestos ?? new Response(JSON.stringify(PUESTOS_ACTIVOS)));
    }
    if (path === "/api/permisos/otorgar" && init?.method === "POST") {
      return Promise.resolve(opciones.post ?? new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    }
    if (path === "/api/permisos") {
      return Promise.resolve(opciones.permisos ?? new Response(JSON.stringify(PERMISOS_ACTIVOS)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("OtorgarPermisoPage", () => {
  it("envía puesto_id y codigo a POST /api/permisos/otorgar", async () => {
    mockApiFetch({});

    render(<OtorgarPermisoPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/puesto destino/i), "puesto-ficticio-1");
    await userEvent.selectOptions(screen.getByLabelText(/^permiso$/i), "permiso_ficticio_uno");
    await userEvent.click(screen.getByRole("button", { name: /^otorgar$/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/permisos/otorgar",
        expect.objectContaining({ method: "POST" })
      )
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/permisos/otorgar" && (init as RequestInit)?.method === "POST")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.puesto_id).toBe("puesto-ficticio-1");
    expect(cuerpo.codigo).toBe("permiso_ficticio_uno");
  });

  it("muestra el detail real del backend en 422 (auto-otorgamiento directo o por herencia)", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({ detail: "No podés otorgarte este permiso a vos mismo." }),
        { status: 422 }
      ),
    });

    render(<OtorgarPermisoPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/puesto destino/i), "puesto-ficticio-1");
    await userEvent.selectOptions(screen.getByLabelText(/^permiso$/i), "permiso_ficticio_uno");
    await userEvent.click(screen.getByRole("button", { name: /^otorgar$/i }));

    await waitFor(() =>
      expect(screen.getByText("No podés otorgarte este permiso a vos mismo.")).toBeInTheDocument()
    );
  });

  it("muestra el detail real del backend cuando el gate rechaza con 403 (sin puesto_permiso_edicion)", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({
          detail: "No tenés el permiso necesario (puesto_permiso_edicion) para esta acción.",
        }),
        { status: 403 }
      ),
    });

    render(<OtorgarPermisoPage />);
    await userEvent.selectOptions(await screen.findByLabelText(/puesto destino/i), "puesto-ficticio-1");
    await userEvent.selectOptions(screen.getByLabelText(/^permiso$/i), "permiso_ficticio_uno");
    await userEvent.click(screen.getByRole("button", { name: /^otorgar$/i }));

    await waitFor(() =>
      expect(
        screen.getByText("No tenés el permiso necesario (puesto_permiso_edicion) para esta acción.")
      ).toBeInTheDocument()
    );
  });

  it("deshabilita el formulario cuando no hay puestos activos", async () => {
    mockApiFetch({ puestos: new Response(JSON.stringify([])) });

    render(<OtorgarPermisoPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay puestos activos disponibles/i)).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/puesto destino/i)).toBeDisabled();
    expect(screen.getByRole("button", { name: /^otorgar$/i })).toBeDisabled();
  });

  it("deshabilita el formulario cuando no hay permisos activos en el catálogo", async () => {
    mockApiFetch({ permisos: new Response(JSON.stringify([])) });

    render(<OtorgarPermisoPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay permisos activos en el catálogo/i)).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/^permiso$/i)).toBeDisabled();
    expect(screen.getByRole("button", { name: /^otorgar$/i })).toBeDisabled();
  });

  it("marca los permisos heredables en las opciones del select", async () => {
    mockApiFetch({});

    render(<OtorgarPermisoPage />);

    await waitFor(() =>
      expect(
        screen.getByRole("option", { name: "permiso_ficticio_heredable (heredable)" })
      ).toBeInTheDocument()
    );
    expect(screen.getByRole("option", { name: "permiso_ficticio_uno" })).toBeInTheDocument();
  });

  it("precarga el puesto destino desde el query param persistido en la URL (deep-link)", async () => {
    window.history.pushState({}, "", "/estructura/permisos/otorgar?puesto_id=puesto-ficticio-1");
    mockApiFetch({});

    render(<OtorgarPermisoPage />);

    await waitFor(() => expect(screen.getByLabelText(/puesto destino/i)).toHaveValue("puesto-ficticio-1"));

    window.history.pushState({}, "", "/");
  });
});
