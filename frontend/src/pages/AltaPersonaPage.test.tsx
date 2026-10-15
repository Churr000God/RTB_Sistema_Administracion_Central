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
    await userEvent.type(screen.getByLabelText(/documento_ref/i), "RTB-RH-EIT-2026-06");
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

describe("AltaPersonaPage · folio del expediente y errores del backend", () => {
  function mockApi(post: () => Response) {
    vi.mocked(apiFetch).mockReset();
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })));
      }
      return Promise.resolve(post());
    });
  }

  async function llenar(folio: string) {
    render(<AltaPersonaPage />);
    await userEvent.type(await screen.findByLabelText(/primer nombre/i), "Mariana");
    await userEvent.type(screen.getByLabelText(/apellido paterno/i), "Alcántara");
    await userEvent.type(screen.getByLabelText(/curp/i), "AARM910427MDFLVR03");
    await userEvent.type(screen.getByLabelText(/rfc/i), "AARM910427H8A");
    await userEvent.type(screen.getByLabelText(/nss/i), "62119145338");
    await userEvent.type(screen.getByLabelText(/fecha de nacimiento/i), "1991-04-27");
    await userEvent.type(screen.getByLabelText(/fecha de ingreso/i), "2026-01-01");
    if (folio) await userEvent.type(screen.getByLabelText(/documento_ref/i), folio);
    await userEvent.click(screen.getByRole("button", { name: /registrar alta/i }));
  }

  const postsAPersonas = () => vi.mocked(apiFetch).mock.calls.filter(([p, init]) => p === "/api/personas" && init?.method === "POST");

  it("la ayuda y el placeholder dicen el formato real, no «RTB-__-__»", async () => {
    mockApi(() => new Response("{}"));
    render(<AltaPersonaPage />);
    const campo = await screen.findByLabelText(/documento_ref/i);
    expect(campo).toHaveAttribute("placeholder", "RTB-RH-EIT-2026-06");
    expect(screen.getByText(/formato RTB-RH-EIT-<año>-<número>, por ejemplo RTB-RH-EIT-2026-06/i)).toBeInTheDocument();
    expect(screen.queryByText(/RTB-__-__/)).not.toBeInTheDocument();
  });

  it.each([["RTB-2026-001"], ["RTB-RH-EIT-26-06"], ["RTB-RH-EIT-2026-"], ["RTB-RH-EIT-2026-06A"], ["rtb-rh-eit-2026-06"], ["RTB-RH-EIT-2026-06 x"]])(
    "folio mal formado %s: se avisa en el campo y NO se envía",
    async (folio) => {
      mockApi(() => new Response(JSON.stringify({ id: "1" }), { status: 201 }));
      await llenar(folio);
      expect(await screen.findByText(/el folio debe tener el formato RTB-RH-EIT-<año de 4 dígitos>-<número>/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/documento_ref/i)).toHaveAttribute("aria-invalid", "true");
      expect(postsAPersonas()).toHaveLength(0);
      expect(screen.getByRole("button", { name: /registrar alta/i })).toBeEnabled();
    },
  );

  it("folio válido (con espacios alrededor): se envía recortado", async () => {
    mockApi(() => new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    await llenar("  RTB-RH-EIT-2026-06  ");
    await waitFor(() => expect(postsAPersonas()).toHaveLength(1));
    expect(JSON.parse(postsAPersonas()[0][1]!.body as string).documento_ref).toBe("RTB-RH-EIT-2026-06");
  });

  it("corregir el campo limpia el error del folio", async () => {
    mockApi(() => new Response(JSON.stringify({ id: "1" }), { status: 201 }));
    await llenar("RTB-2026-001");
    await screen.findByText(/el folio debe tener el formato/i);
    await userEvent.type(screen.getByLabelText(/documento_ref/i), "x");
    expect(screen.queryByText(/el folio debe tener el formato/i)).not.toBeInTheDocument();
  });

  it("409: dice qué choca (CURP, RFC, NSS o número de documento) y conserva lo escrito", async () => {
    mockApi(() =>
      new Response(JSON.stringify({ detail: "CURP, RFC, NSS o número de documento ya está en uso por otra persona." }), { status: 409 }),
    );
    await llenar("RTB-RH-EIT-2026-06");
    expect(await screen.findByRole("alert")).toHaveTextContent("CURP, RFC, NSS o número de documento ya está en uso por otra persona.");
    expect(screen.getByLabelText(/curp/i)).toHaveValue("AARM910427MDFLVR03");
    expect(screen.getByRole("button", { name: /registrar alta/i })).toBeEnabled();
  });

  it("409 sin texto: mensaje local de duplicado", async () => {
    mockApi(() => new Response("{}", { status: 409 }));
    await llenar("RTB-RH-EIT-2026-06");
    expect(await screen.findByRole("alert")).toHaveTextContent(/ya está en uso por otra persona/i);
  });

  it("422 por folio: el mensaje del backend se marca en el campo documento_ref", async () => {
    mockApi(() =>
      new Response(JSON.stringify({ detail: "El folio del expediente debe tener el formato RTB-RH-EIT-<año>-<número> (ej. RTB-RH-EIT-2026-06)." }), { status: 422 }),
    );
    await llenar("RTB-RH-EIT-2026-06");
    expect(await screen.findByText(/el folio del expediente debe tener el formato/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/documento_ref/i)).toHaveAttribute("aria-invalid", "true");
  });

  it("422 de validación genérica (detail como lista): mensaje local claro, no «No se pudo registrar el alta»", async () => {
    mockApi(() => new Response(JSON.stringify({ detail: [{ loc: ["body", "curp"], msg: "x" }] }), { status: 422 }));
    await llenar("RTB-RH-EIT-2026-06");
    expect(await screen.findByRole("alert")).toHaveTextContent("Alguno de los datos no es válido; revísalos y vuelve a intentarlo.");
  });

  it("403: texto de permiso", async () => {
    mockApi(() => new Response(JSON.stringify({ detail: "interno" }), { status: 403 }));
    await llenar("RTB-RH-EIT-2026-06");
    expect(await screen.findByRole("alert")).toHaveTextContent("No tienes permiso para dar de alta personas.");
    expect(screen.getByRole("alert")).not.toHaveTextContent(/interno/);
  });

  it("502 (respuesta sin id del RPC): cae al genérico y no pinta el mensaje del servidor", async () => {
    mockApi(() => new Response(JSON.stringify({ detail: "El servicio devolvió una respuesta inesperada <b>interna</b>." }), { status: 502 }));
    await llenar("RTB-RH-EIT-2026-06");
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent("No se pudo registrar el alta.");
    expect(alerta).not.toHaveTextContent(/inesperada|interna/);
    expect(screen.queryByText(/no vuelvas a enviar/i)).not.toBeInTheDocument();
  });

  it("500: genérico, sin detail del servidor", async () => {
    mockApi(() => new Response(JSON.stringify({ detail: "stack interno" }), { status: 500 }));
    await llenar("RTB-RH-EIT-2026-06");
    expect(await screen.findByRole("alert")).toHaveTextContent("No se pudo registrar el alta.");
    expect(screen.getByRole("alert")).not.toHaveTextContent(/stack interno/);
  });
});

