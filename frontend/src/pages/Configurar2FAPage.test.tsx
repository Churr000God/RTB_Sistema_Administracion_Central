import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { supabase } from "../lib/supabaseClient";
import { Configurar2FAPage } from "./Configurar2FAPage";

vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getSession: vi.fn().mockResolvedValue({ data: { session: { user: { email: null } } } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
      mfa: {
        listFactors: vi.fn(),
        enroll: vi.fn(),
        challenge: vi.fn(),
        verify: vi.fn(),
      },
    },
  },
}));

describe("Configurar2FAPage", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.mfa.listFactors).mockReset();
    vi.mocked(supabase.auth.mfa.enroll).mockReset();
  });

  it("sin 2FA previo, matricula un factor nuevo y muestra el QR con los pasos y la clave manual", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [], phone: [], all: [] },
      error: null,
    } as never);
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue({
      data: {
        id: "factor-1",
        type: "totp",
        totp: { qr_code: "data:image/svg+xml;base64,abc", secret: "K4RS2M9X7QTDBF13", uri: "otpauth://" },
      },
      error: null,
    } as never);

    render(<Configurar2FAPage />);

    await waitFor(() =>
      expect(screen.getByAltText("Código QR para configurar 2FA")).toBeInTheDocument()
    );
    expect(screen.getByText("Descarga una app autenticadora")).toBeInTheDocument();
    expect(screen.getByText("Escanea el código QR")).toBeInTheDocument();
    expect(screen.getByText("Ingresa el código de 6 dígitos")).toBeInTheDocument();
    expect(screen.getByText("K4RS2M9X7QTDBF13")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /ya la agregué, continuar/i })).toBeInTheDocument();
  });

  it("al confirmar que agregó la app, pasa a la pantalla de verificación del código", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [], phone: [], all: [] },
      error: null,
    } as never);
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue({
      data: {
        id: "factor-1",
        type: "totp",
        totp: { qr_code: "data:image/svg+xml;base64,abc", secret: "K4RS2M9X7QTDBF13", uri: "otpauth://" },
      },
      error: null,
    } as never);

    render(<Configurar2FAPage />);

    await waitFor(() => expect(screen.getByAltText("Código QR para configurar 2FA")).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /ya la agregué, continuar/i }));

    expect(await screen.findByLabelText("Dígito 1 de 6")).toBeInTheDocument();
  });

  it("si ya tiene un factor TOTP verificado, no vuelve a matricular y ofrece ir a Personas", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [{ id: "factor-existente", status: "verified" }], phone: [], all: [] },
      error: null,
    } as never);

    render(<Configurar2FAPage />);

    await waitFor(() =>
      expect(screen.getByText(/ya tiene la verificación en dos pasos activa/i)).toBeInTheDocument()
    );
    expect(supabase.auth.mfa.enroll).not.toHaveBeenCalled();
    expect(screen.getByRole("link", { name: /ir a personas/i })).toHaveAttribute("href", "/personas");
  });

  it("si listFactors falla, muestra el error y no intenta matricular", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: null,
      error: { message: "network down", name: "AuthApiError", status: 500 },
    } as never);

    render(<Configurar2FAPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no se pudo comprobar el estado de tu verificación en dos pasos/i)
      ).toBeInTheDocument()
    );
    expect(supabase.auth.mfa.enroll).not.toHaveBeenCalled();
  });

  it("si enroll falla, muestra el error genérico", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [], phone: [], all: [] },
      error: null,
    } as never);
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue({
      data: null,
      error: { message: "boom", name: "AuthApiError", status: 500 },
    } as never);

    render(<Configurar2FAPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo generar el código/i)).toBeInTheDocument()
    );
  });
});
