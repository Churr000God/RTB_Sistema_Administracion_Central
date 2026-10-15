import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { supabase } from "../lib/supabaseClient";
import { LoginPage } from "./LoginPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      signInWithPassword: vi.fn(),
      signOut: vi.fn().mockResolvedValue({ error: null }),
      mfa: {
        getAuthenticatorAssuranceLevel: vi
          .fn()
          .mockResolvedValue({ data: { currentLevel: "aal2", nextLevel: "aal2" } }),
      },
    },
  },
}));

describe("LoginPage", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.signInWithPassword).mockReset();
    vi.mocked(supabase.auth.signOut).mockClear();
    vi.mocked(supabase.auth.mfa.getAuthenticatorAssuranceLevel).mockClear();
    vi.mocked(apiFetch).mockReset();
    vi.mocked(apiFetch).mockResolvedValue(new Response(null, { status: 500 }));
  });

  it("muestra error de credenciales inválidas sin salir de la pantalla", async () => {
    vi.mocked(supabase.auth.signInWithPassword).mockResolvedValue({
      data: { user: null, session: null },
      error: { message: "Invalid login credentials", name: "AuthApiError", status: 400 },
    } as never);

    render(<LoginPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(screen.getByLabelText("Contraseña"), "malacontrasena");
    await userEvent.click(screen.getByRole("button", { name: /iniciar sesión/i }));

    await waitFor(() =>
      expect(screen.getByText(/credenciales inválidas/i)).toBeInTheDocument()
    );
    expect(screen.getByText(/te quedan 4 intentos/i)).toBeInTheDocument();
  });

  it("cambia el título y la bajada del panel cuando hay error", async () => {
    vi.mocked(supabase.auth.signInWithPassword).mockResolvedValue({
      data: { user: null, session: null },
      error: { message: "Invalid login credentials", name: "AuthApiError", status: 400 },
    } as never);

    render(<LoginPage />);
    expect(screen.getByText("Entregamos confianza,")).toBeInTheDocument();

    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(screen.getByLabelText("Contraseña"), "malacontrasena");
    await userEvent.click(screen.getByRole("button", { name: /iniciar sesión/i }));

    await waitFor(() =>
      expect(screen.getByText("No pudimos verificar tu acceso.")).toBeInTheDocument()
    );
    expect(
      screen.queryByText("Entregamos confianza,")
    ).not.toBeInTheDocument();
  });

  it("marca el campo de contraseña como inválido y muestra el hint tras un error", async () => {
    vi.mocked(supabase.auth.signInWithPassword).mockResolvedValue({
      data: { user: null, session: null },
      error: { message: "Invalid login credentials", name: "AuthApiError", status: 400 },
    } as never);

    render(<LoginPage />);
    const contrasena = screen.getByLabelText("Contraseña");
    expect(contrasena).not.toHaveAttribute("aria-invalid");

    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(contrasena, "malacontrasena");
    await userEvent.click(screen.getByRole("button", { name: /iniciar sesión/i }));

    await waitFor(() => expect(contrasena).toHaveAttribute("aria-invalid", "true"));
    expect(screen.getByText(/distingue mayúsculas y minúsculas/i)).toBeInTheDocument();
    expect(contrasena).toHaveAttribute("aria-describedby", "hint-contrasena");
  });

  it("cuando la sesión no está permitida, cierra sesión y redirige a /cuenta-suspendida sin llegar a la bifurcación MFA", async () => {
    vi.mocked(supabase.auth.signInWithPassword).mockResolvedValue({
      data: { user: { id: "u1" }, session: { access_token: "tok" } },
      error: null,
    } as never);
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(
        JSON.stringify({ acceso_permitido: false, motivo_bloqueo: "suspension" }),
        { status: 200 }
      )
    );

    render(<LoginPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(screen.getByLabelText("Contraseña"), "buenacontrasena");
    await userEvent.click(screen.getByRole("button", { name: /iniciar sesión/i }));

    await waitFor(() => expect(supabase.auth.signOut).toHaveBeenCalled());
    expect(supabase.auth.mfa.getAuthenticatorAssuranceLevel).not.toHaveBeenCalled();
  });

  it("si /api/sesion falla, sigue el login normal (fail-open)", async () => {
    vi.mocked(supabase.auth.signInWithPassword).mockResolvedValue({
      data: { user: { id: "u1" }, session: { access_token: "tok" } },
      error: null,
    } as never);
    vi.mocked(apiFetch).mockRejectedValue(new Error("network down"));

    render(<LoginPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(screen.getByLabelText("Contraseña"), "buenacontrasena");
    await userEvent.click(screen.getByRole("button", { name: /iniciar sesión/i }));

    await waitFor(() =>
      expect(supabase.auth.mfa.getAuthenticatorAssuranceLevel).toHaveBeenCalled()
    );
    expect(supabase.auth.signOut).not.toHaveBeenCalled();
  });

  it("el enlace a Recursos Humanos es un mailto: real", () => {
    render(<LoginPage />);

    expect(screen.getByRole("link", { name: /recursos humanos/i })).toHaveAttribute(
      "href",
      expect.stringMatching(/^mailto:.+@/)
    );
  });
});

describe("LoginPage · destino tras iniciar sesión", () => {
  const originalLocation = window.location;
  let href = "";

  beforeEach(() => {
    href = "";
    vi.mocked(supabase.auth.signInWithPassword).mockReset();
    vi.mocked(supabase.auth.signInWithPassword).mockResolvedValue({
      data: { user: { id: "u1" }, session: { access_token: "tok" } },
      error: null,
    } as never);
    vi.mocked(supabase.auth.mfa.getAuthenticatorAssuranceLevel).mockResolvedValue({ data: { currentLevel: "aal2", nextLevel: "aal2" } } as never);
    vi.mocked(apiFetch).mockReset();
    Object.defineProperty(window, "location", {
      configurable: true,
      value: {
        ...originalLocation,
        get href() {
          return href;
        },
        set href(valor: string) {
          href = valor;
        },
      },
    });
  });

  afterEach(() => {
    Object.defineProperty(window, "location", { configurable: true, value: originalLocation });
  });

  async function iniciarSesionCon(sesion: Record<string, unknown> | null) {
    vi.mocked(apiFetch).mockImplementation(() =>
      sesion ? Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, ...sesion }))) : Promise.reject(new Error("sin red")),
    );
    render(<LoginPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(screen.getByLabelText("Contraseña"), "buenacontrasena");
    await userEvent.click(screen.getByRole("button", { name: /iniciar sesión/i }));
    await waitFor(() => expect(href).not.toBe(""));
  }

  it("con módulo 1: /personas (comportamiento actual)", async () => {
    await iniciarSesionCon({ puede_ver_modulo_1: true, puede_ver_modulo_2: false, puede_ver_modulo_3: false });
    expect(href).toBe("/personas");
  });

  it("sin módulo 1 pero con Tiempo: va al primer módulo que sí ve", async () => {
    await iniciarSesionCon({ puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: true });
    expect(href).toBe("/tiempo/asignacion-jornada");
  });

  it("sin ningún módulo: /inicio", async () => {
    await iniciarSesionCon({ puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: false });
    expect(href).toBe("/inicio");
  });

  it("si /api/sesion falla (fail-open): /personas como hasta ahora", async () => {
    await iniciarSesionCon(null);
    expect(href).toBe("/personas");
  });

  it("la bifurcación de 2FA no cambia: nivel aal1 -> /configurar-2fa aunque no tenga módulos", async () => {
    vi.mocked(supabase.auth.mfa.getAuthenticatorAssuranceLevel).mockResolvedValue({ data: { currentLevel: "aal1", nextLevel: "aal1" } } as never);
    await iniciarSesionCon({ puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: false });
    expect(href).toBe("/configurar-2fa");
  });
});
