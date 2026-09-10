import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { supabase } from "../lib/supabaseClient";
import { RestablecerContrasenaPage } from "./RestablecerContrasenaPage";

vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getSession: vi.fn().mockResolvedValue({ data: { session: null } }),
      onAuthStateChange: vi.fn().mockReturnValue({
        data: { subscription: { unsubscribe: vi.fn() } },
      }),
      updateUser: vi.fn(),
      signOut: vi.fn().mockResolvedValue({ error: null }),
      mfa: {
        getAuthenticatorAssuranceLevel: vi.fn(),
        listFactors: vi.fn(),
        challenge: vi.fn().mockResolvedValue({ data: { id: "challenge-1" }, error: null }),
        verify: vi.fn(),
      },
    },
  },
}));

const CONTRASENA_VALIDA = "Correcta123!";

async function llenarYEnviarFormulario() {
  await userEvent.type(screen.getByLabelText(/nueva contraseña/i), CONTRASENA_VALIDA);
  await userEvent.type(screen.getByLabelText(/confirmar contraseña/i), CONTRASENA_VALIDA);
  await userEvent.click(screen.getByRole("button", { name: /guardar contraseña/i }));
}

describe("RestablecerContrasenaPage", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.updateUser).mockReset();
    vi.mocked(supabase.auth.mfa.getAuthenticatorAssuranceLevel).mockResolvedValue({
      data: { currentLevel: "aal1", nextLevel: "aal1" },
    } as never);
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [] },
    } as never);
  });

  afterEach(() => {
    window.location.hash = "";
  });

  it("muestra el enlace vencido en vez del formulario cuando Supabase lo marca en el hash, sin tocar Supabase", () => {
    window.location.hash =
      "#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired";

    render(<RestablecerContrasenaPage />);

    expect(screen.getByText(/este enlace venció/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /solicitar un enlace nuevo/i })).toHaveAttribute(
      "href",
      "/olvide-contrasena"
    );
    expect(screen.queryByLabelText(/nueva contraseña/i)).not.toBeInTheDocument();
    expect(supabase.auth.getSession).not.toHaveBeenCalled();
  });

  it("con aal1 y sin factor TOTP muestra el formulario directo", async () => {
    render(<RestablecerContrasenaPage />);
    await waitFor(() => expect(screen.getByLabelText(/nueva contraseña/i)).toBeInTheDocument());
  });

  it("con aal1 y un factor TOTP verificado muestra el casillero, no el formulario", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [{ id: "factor-1", status: "verified" }] },
    } as never);
    vi.mocked(supabase.auth.mfa.getAuthenticatorAssuranceLevel).mockResolvedValue({
      data: { currentLevel: "aal1", nextLevel: "aal2" },
    } as never);

    render(<RestablecerContrasenaPage />);

    await waitFor(() => expect(screen.getByLabelText("Dígito 1 de 6")).toBeInTheDocument());
    expect(screen.queryByLabelText(/nueva contraseña/i)).not.toBeInTheDocument();
  });

  it("insufficient_aal en el submit cambia al paso TOTP (red de seguridad aunque el montaje no lo haya detectado)", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [{ id: "factor-9", status: "verified" }] },
    } as never);
    vi.mocked(supabase.auth.updateUser).mockResolvedValue({
      data: { user: null },
      error: {
        message: "insufficient aal",
        name: "AuthApiError",
        status: 401,
        code: "insufficient_aal",
      },
    } as never);

    render(<RestablecerContrasenaPage />);
    await waitFor(() => expect(screen.getByLabelText(/nueva contraseña/i)).toBeInTheDocument());

    await llenarYEnviarFormulario();

    await waitFor(() => expect(screen.getByLabelText("Dígito 1 de 6")).toBeInTheDocument());
    expect(screen.getByText(/falta confirmar el segundo paso/i)).toBeInTheDocument();
  });

  it("same_password muestra el mensaje específico en vez del genérico", async () => {
    vi.mocked(supabase.auth.updateUser).mockResolvedValue({
      data: { user: null },
      error: { message: "same password", name: "AuthApiError", status: 422, code: "same_password" },
    } as never);

    render(<RestablecerContrasenaPage />);
    await waitFor(() => expect(screen.getByLabelText(/nueva contraseña/i)).toBeInTheDocument());

    await llenarYEnviarFormulario();

    await waitFor(() =>
      expect(screen.getByText(/distinta de la actual/i)).toBeInTheDocument()
    );
    expect(supabase.auth.signOut).not.toHaveBeenCalled();
  });

  it("al guardar con éxito cierra las otras sesiones y muestra la confirmación", async () => {
    vi.mocked(supabase.auth.updateUser).mockResolvedValue({
      data: { user: { id: "u1" } },
      error: null,
    } as never);

    render(<RestablecerContrasenaPage />);
    await waitFor(() => expect(screen.getByLabelText(/nueva contraseña/i)).toBeInTheDocument());

    await llenarYEnviarFormulario();

    await waitFor(() =>
      expect(screen.getByRole("link", { name: /ir a iniciar sesión/i })).toBeInTheDocument()
    );
    expect(supabase.auth.signOut).toHaveBeenCalledWith({ scope: "others" });
  });
});
