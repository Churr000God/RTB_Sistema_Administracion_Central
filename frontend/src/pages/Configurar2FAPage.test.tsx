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

describe("Configurar2FAPage · nombre propio y limpieza de factores sin verificar", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.mfa.listFactors).mockReset();
    vi.mocked(supabase.auth.mfa.enroll).mockReset();
    (supabase.auth.mfa as unknown as { unenroll: ReturnType<typeof vi.fn> }).unenroll = vi.fn().mockResolvedValue({ data: {}, error: null });
    vi.mocked(supabase.auth.getSession).mockResolvedValue({ data: { session: { user: { email: "mariana@example.com" } } } } as never);
  });

  const unenroll = () => (supabase.auth.mfa as unknown as { unenroll: ReturnType<typeof vi.fn> }).unenroll;
  const ENROLADO = {
    data: { id: "factor-1", type: "totp", totp: { qr_code: "data:image/svg+xml;base64,abc", secret: "K4RS2M9X7QTDBF13", uri: "otpauth://" } },
    error: null,
  } as never;

  it("enroll recibe el emisor «RTB Administración Central» (sin dos puntos) y el correo como friendlyName", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({ data: { totp: [], phone: [], all: [] }, error: null } as never);
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue(ENROLADO);
    render(<Configurar2FAPage />);
    await waitFor(() => expect(screen.getByAltText("Código QR para configurar 2FA")).toBeInTheDocument());
    expect(supabase.auth.mfa.enroll).toHaveBeenCalledWith({
      factorType: "totp",
      issuer: "RTB Administración Central",
      friendlyName: "mariana@example.com",
    });
    const { issuer } = vi.mocked(supabase.auth.mfa.enroll).mock.calls[0][0] as { issuer: string };
    expect(issuer).not.toMatch(/[:—–]/);
  });

  it("el friendlyName no se imprime en pantalla", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({ data: { totp: [], phone: [], all: [] }, error: null } as never);
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue(ENROLADO);
    render(<Configurar2FAPage />);
    await waitFor(() => expect(screen.getByAltText("Código QR para configurar 2FA")).toBeInTheDocument());
    expect(screen.queryByText(/mariana@example\.com/)).not.toBeInTheDocument();
  });

  it("sin correo en la sesión usa un nombre estable «Cuenta RTB»", async () => {
    vi.mocked(supabase.auth.getSession).mockResolvedValue({ data: { session: { user: { email: null } } } } as never);
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({ data: { totp: [], phone: [], all: [] }, error: null } as never);
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue(ENROLADO);
    render(<Configurar2FAPage />);
    await waitFor(() => expect(supabase.auth.mfa.enroll).toHaveBeenCalled());
    expect(supabase.auth.mfa.enroll).toHaveBeenCalledWith(expect.objectContaining({ friendlyName: "Cuenta RTB" }));
  });

  it("si getSession falla igual enrola, con «Cuenta RTB»", async () => {
    vi.mocked(supabase.auth.getSession).mockRejectedValue(new Error("sin sesión"));
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({ data: { totp: [], phone: [], all: [] }, error: null } as never);
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue(ENROLADO);
    render(<Configurar2FAPage />);
    await waitFor(() => expect(supabase.auth.mfa.enroll).toHaveBeenCalled());
    expect(supabase.auth.mfa.enroll).toHaveBeenCalledWith(expect.objectContaining({ friendlyName: "Cuenta RTB" }));
  });

  it("un TOTP sin verificar de un intento previo se desmatricula ANTES de enrolar (el friendlyName es único)", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: {
        totp: [],
        phone: [],
        all: [
          { id: "viejo-1", factor_type: "totp", status: "unverified" },
          { id: "viejo-2", factor_type: "totp", status: "unverified" },
          { id: "telefono", factor_type: "phone", status: "unverified" },
        ],
      },
      error: null,
    } as never);
    const orden: string[] = [];
    unenroll().mockImplementation(async ({ factorId }: { factorId: string }) => {
      orden.push(`unenroll:${factorId}`);
      return { data: {}, error: null };
    });
    vi.mocked(supabase.auth.mfa.enroll).mockImplementation((async () => {
      orden.push("enroll");
      return ENROLADO;
    }) as never);
    render(<Configurar2FAPage />);
    await waitFor(() => expect(screen.getByAltText("Código QR para configurar 2FA")).toBeInTheDocument());
    expect(orden).toEqual(["unenroll:viejo-1", "unenroll:viejo-2", "enroll"]);
  });

  it("un factor verificado NO se desmatricula (ya configurado: ni enroll ni unenroll)", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [{ id: "ok", status: "verified" }], phone: [], all: [{ id: "ok", factor_type: "totp", status: "verified" }] },
      error: null,
    } as never);
    render(<Configurar2FAPage />);
    await waitFor(() => expect(screen.getByText(/ya tiene la verificación en dos pasos activa/i)).toBeInTheDocument());
    expect(unenroll()).not.toHaveBeenCalled();
    expect(supabase.auth.mfa.enroll).not.toHaveBeenCalled();
  });

  it("si la limpieza falla igual intenta enrolar", async () => {
    vi.mocked(supabase.auth.mfa.listFactors).mockResolvedValue({
      data: { totp: [], phone: [], all: [{ id: "viejo", factor_type: "totp", status: "unverified" }] },
      error: null,
    } as never);
    unenroll().mockResolvedValue({ data: null, error: { message: "x", name: "AuthApiError", status: 500 } });
    vi.mocked(supabase.auth.mfa.enroll).mockResolvedValue(ENROLADO);
    render(<Configurar2FAPage />);
    await waitFor(() => expect(screen.getByAltText("Código QR para configurar 2FA")).toBeInTheDocument());
  });
});
