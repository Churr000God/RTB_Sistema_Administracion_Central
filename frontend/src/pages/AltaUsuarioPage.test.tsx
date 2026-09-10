import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AltaUsuarioPage } from "./AltaUsuarioPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONAS = [{ id: "1", primer_nombre: "Mariana", apellido_paterno: "Alcántara" }];

function mockApiFetch(respuestaPersonas: Response) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/personas") {
      return Promise.resolve(respuestaPersonas);
    }
    return Promise.resolve(new Response(JSON.stringify({ id: "u1" }), { status: 201 }));
  });
}

describe("AltaUsuarioPage", () => {
  it("carga las personas y envía la invitación", async () => {
    mockApiFetch(new Response(JSON.stringify(PERSONAS)));

    render(<AltaUsuarioPage />);

    await waitFor(() => expect(screen.getByLabelText(/persona/i)).toBeInTheDocument());
    await userEvent.selectOptions(screen.getByLabelText(/persona/i), "1");
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(screen.getByLabelText(/nombre de usuario/i), "mariana.alcantara");
    await userEvent.click(screen.getByRole("button", { name: /enviar invitación/i }));

    await waitFor(() => expect(screen.getByText(/invitación enviada/i)).toBeInTheDocument());
  });

  it("si GET /api/personas falla, muestra un error con reintentar en vez de reventar", async () => {
    mockApiFetch(new Response(null, { status: 500 }));

    render(<AltaUsuarioPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el listado de personas/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
    // el formulario no se renderiza sobre datos rotos
    expect(screen.queryByLabelText(/persona/i)).not.toBeInTheDocument();
  });

  it("reintentar vuelve a pedir el listado y, si funciona, muestra el formulario", async () => {
    let intento = 0;
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      if (path === "/api/personas") {
        intento += 1;
        if (intento === 1) return Promise.resolve(new Response(null, { status: 500 }));
        return Promise.resolve(new Response(JSON.stringify(PERSONAS)));
      }
      return Promise.resolve(new Response(JSON.stringify({ id: "u1" }), { status: 201 }));
    });

    render(<AltaUsuarioPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el listado de personas/i)).toBeInTheDocument()
    );
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));

    await waitFor(() => expect(screen.getByLabelText(/persona/i)).toBeInTheDocument());
  });

  it("preselecciona la persona cuando llega ?persona_id= en la URL (deep-link desde la ficha)", async () => {
    window.history.pushState({}, "", "/usuarios/nuevo?persona_id=1");
    mockApiFetch(new Response(JSON.stringify(PERSONAS)));

    render(<AltaUsuarioPage />);

    await waitFor(() => expect(screen.getByLabelText(/persona/i)).toHaveValue("1"));

    window.history.pushState({}, "", "/");
  });
});
