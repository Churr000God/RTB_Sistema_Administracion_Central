import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { supabase } from "../lib/supabaseClient";
import { VerificarTotpPage } from "./VerificarTotpPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getSession: vi.fn().mockResolvedValue({ data: { session: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
      mfa: {
        challenge: vi.fn().mockResolvedValue({ data: { id: "challenge-1" }, error: null }),
        verify: vi.fn(),
      },
    },
  },
}));

describe("VerificarTotpPage", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.mfa.verify).mockReset();
  });

  it("navega tras un código correcto", async () => {
    vi.mocked(supabase.auth.mfa.verify).mockResolvedValue({
      data: { access_token: "tok" },
      error: null,
    } as never);

    render(<VerificarTotpPage factorId="factor-1" />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("123456");
    await userEvent.click(screen.getByRole("button", { name: /verificar/i }));

    await waitFor(() =>
      expect(supabase.auth.mfa.verify).toHaveBeenCalledWith({
        factorId: "factor-1",
        challengeId: "challenge-1",
        code: "123456",
      })
    );
  });

  it("marca inválido, limpia el casillero y devuelve el foco a la celda 1 tras un código incorrecto", async () => {
    vi.mocked(supabase.auth.mfa.verify).mockResolvedValue({
      data: null,
      error: {
        message: "Invalid code",
        name: "AuthApiError",
        status: 400,
        code: "mfa_verification_failed",
      },
    } as never);

    render(<VerificarTotpPage factorId="factor-1" />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("000000");
    await userEvent.click(screen.getByRole("button", { name: /verificar/i }));

    await waitFor(() => expect(screen.getByText(/el código no coincide/i)).toBeInTheDocument());
    expect(screen.getByLabelText("Dígito 1 de 6")).toHaveValue("");
    await waitFor(() => expect(screen.getByLabelText("Dígito 1 de 6")).toHaveFocus());
  });
});

describe("VerificarTotpPage · destino tras verificar", () => {
  const originalLocation = window.location;
  let href = "";

  beforeEach(() => {
    href = "";
    vi.mocked(supabase.auth.mfa.verify).mockReset();
    vi.mocked(supabase.auth.mfa.verify).mockResolvedValue({ data: { access_token: "tok" }, error: null } as never);
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
    vi.mocked(apiFetch).mockReset();
  });

  async function verificarConSesion(sesion: Record<string, unknown> | null) {
    vi.mocked(apiFetch).mockImplementation(() =>
      sesion ? Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, ...sesion }))) : Promise.reject(new Error("sin red")),
    );
    render(<VerificarTotpPage factorId="factor-1" />);
    await userEvent.click(screen.getByLabelText("Dígito 1 de 6"));
    await userEvent.keyboard("123456");
    await userEvent.click(screen.getByRole("button", { name: /verificar/i }));
    await waitFor(() => expect(href).not.toBe(""));
  }

  it("con módulo 1: /inicio (destino por defecto de todos)", async () => {
    await verificarConSesion({ puede_ver_modulo_1: true, puede_ver_modulo_2: false, puede_ver_modulo_3: false });
    expect(href).toBe("/inicio");
  });

  it("sin ningún módulo: /inicio", async () => {
    await verificarConSesion({ puede_ver_modulo_1: false, puede_ver_modulo_2: false, puede_ver_modulo_3: false });
    expect(href).toBe("/inicio");
  });

  it("si /api/sesion falla: también /inicio (Inicio verifica la sesión por su cuenta)", async () => {
    await verificarConSesion(null);
    expect(href).toBe("/inicio");
  });
});
