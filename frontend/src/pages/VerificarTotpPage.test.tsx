import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { supabase } from "../lib/supabaseClient";
import { VerificarTotpPage } from "./VerificarTotpPage";

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
