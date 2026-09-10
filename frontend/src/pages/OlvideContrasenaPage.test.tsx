import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { supabase } from "../lib/supabaseClient";
import { OlvideContrasenaPage } from "./OlvideContrasenaPage";

vi.mock("../lib/supabaseClient", () => ({
  supabase: { auth: { resetPasswordForEmail: vi.fn() } },
}));

describe("OlvideContrasenaPage", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.resetPasswordForEmail).mockReset();
  });

  it("confirma el envío del enlace", async () => {
    vi.mocked(supabase.auth.resetPasswordForEmail).mockResolvedValue({ error: null } as never);

    render(<OlvideContrasenaPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.click(screen.getByRole("button", { name: /enviar enlace/i }));

    await waitFor(() => expect(screen.getByText(/revisa tu correo/i)).toBeInTheDocument());
    expect(supabase.auth.resetPasswordForEmail).toHaveBeenCalledWith("mariana@example.com", {
      redirectTo: expect.stringContaining("/restablecer-contrasena"),
    });
  });

  it("con rate limit (429) muestra el mensaje específico, no la pantalla de enviado", async () => {
    vi.mocked(supabase.auth.resetPasswordForEmail).mockResolvedValue({
      error: {
        message: "For security purposes, you can only request this after 12 seconds.",
        name: "AuthApiError",
        status: 429,
        code: "over_email_send_rate_limit",
      },
    } as never);

    render(<OlvideContrasenaPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.click(screen.getByRole("button", { name: /enviar enlace/i }));

    await waitFor(() =>
      expect(screen.getByText(/esperá unos segundos antes de pedir otro/i)).toBeInTheDocument()
    );
    expect(screen.queryByText(/revisa tu correo/i)).not.toBeInTheDocument();
  });

  it("el enlace a Recursos Humanos es un mailto: real", () => {
    render(<OlvideContrasenaPage />);

    expect(screen.getByRole("link", { name: /recursos humanos/i })).toHaveAttribute(
      "href",
      expect.stringMatching(/^mailto:.+@/)
    );
  });
});
