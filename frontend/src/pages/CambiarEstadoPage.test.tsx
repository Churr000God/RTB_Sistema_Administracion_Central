import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { irA } from "../lib/navegacion";
import { CambiarEstadoPage } from "./CambiarEstadoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/navegacion", () => ({ irA: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

describe("CambiarEstadoPage", () => {
  it("exige motivo y envía el movimiento elegido", async () => {
    // Tres consumidores de apiFetch en esta pantalla: AppShell (GET /api/sesion), la propia
    // página (GET /api/personas/:id) y el submit (POST /movimientos) — cada uno necesita su
    // propio Response, no uno compartido (el body sólo se lee una vez).
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(JSON.stringify({ id: "m1" }), { status: 201 }));
    });

    render(
      <MemoryRouter initialEntries={["/personas/1/movimiento"]}>
        <Routes>
          <Route path="/personas/:id/movimiento" element={<CambiarEstadoPage />} />
        </Routes>
      </MemoryRouter>
    );

    await userEvent.click(await screen.findByLabelText(/suspensión/i));
    await userEvent.type(screen.getByLabelText(/motivo/i), "Licencia sin goce de sueldo");
    await userEvent.click(screen.getByRole("button", { name: /confirmar/i }));

    expect(apiFetch).toHaveBeenCalledWith(
      "/api/personas/1/movimientos",
      expect.objectContaining({ method: "POST" })
    );
  });

  describe("resultado del movimiento y baja en terminal (F7)", () => {
    beforeEach(() => {
      vi.mocked(irA).mockReset();
      vi.mocked(apiFetch).mockReset();
    });

    function mockPost(cuerpo: unknown, status = 201) {
      vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
        if (path === "/api/sesion") return Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true })));
        if (path === "/api/personas/1/movimientos" && init?.method === "POST") {
          return Promise.resolve(new Response(typeof cuerpo === "string" ? cuerpo : JSON.stringify(cuerpo), { status }));
        }
        return Promise.resolve(new Response(JSON.stringify({ id: "1", primer_nombre: "Ana", apellido_paterno: "Torres", estado: "activo" })));
      });
    }

    async function confirmar(tipo = /suspensión/i) {
      render(
        <MemoryRouter initialEntries={["/personas/1/movimiento"]}>
          <Routes>
            <Route path="/personas/:id/movimiento" element={<CambiarEstadoPage />} />
          </Routes>
        </MemoryRouter>,
      );
      await userEvent.click(await screen.findByLabelText(tipo));
      await userEvent.type(screen.getByLabelText(/motivo/i), "Licencia sin goce de sueldo");
      await userEvent.click(screen.getByRole("button", { name: /confirmar/i }));
    }

    it("sin advertencias ni bajas en terminal: redirige a la ficha como siempre", async () => {
      mockPost({ id: "m1", advertencias: [], bajas_terminal_emitidas: 0 });
      await confirmar();
      await waitFor(() => expect(irA).toHaveBeenCalledWith("/personas/1"));
    });

    it("un backend anterior (sin los campos nuevos) también redirige", async () => {
      mockPost({ id: "m1" });
      await confirmar();
      await waitFor(() => expect(irA).toHaveBeenCalledWith("/personas/1"));
    });

    it("advertencia baja_terminal_pendiente: NO redirige y avisa que la baja quedó pendiente", async () => {
      mockPost({ id: "m1", advertencias: ["baja_terminal_pendiente"], bajas_terminal_emitidas: 0 });
      await confirmar();
      const alerta = await screen.findByRole("alert");
      expect(alerta).toHaveTextContent(/la baja en la terminal quedó pendiente/i);
      expect(alerta).toHaveTextContent(/se reintentará sola/i);
      expect(alerta).toHaveTextContent(/persona inactiva/i);
      expect(screen.getByText(/suspensión registrada/i)).toBeInTheDocument();
      expect(irA).not.toHaveBeenCalled();
      expect(screen.getByRole("link", { name: /continuar a la ficha/i })).toHaveAttribute("href", "/personas/1");
      expect(screen.getByRole("link", { name: /anomalías/i })).toHaveAttribute("href", "/tiempo/terminales/anomalias");
    });

    it("el resultado nombra el movimiento: baja definitiva", async () => {
      mockPost({ id: "m1", advertencias: ["baja_terminal_pendiente"] });
      await confirmar(/baja definitiva/i);
      expect(await screen.findByText(/baja definitiva registrada/i)).toBeInTheDocument();
    });

    it("bajas_terminal_emitidas > 0 sin advertencia: aviso informativo (no alerta) y Continuar", async () => {
      mockPost({ id: "m1", advertencias: [], bajas_terminal_emitidas: 2 });
      await confirmar();
      expect(await screen.findByText(/se solicitó también la baja de 2 altas en la terminal/i)).toBeInTheDocument();
      expect(screen.queryByRole("alert")).not.toBeInTheDocument();
      expect(irA).not.toHaveBeenCalled();
      expect(screen.getByRole("link", { name: /continuar a la ficha/i })).toBeInTheDocument();
    });

    it("una advertencia desconocida se avisa de forma genérica, sin mostrar su texto", async () => {
      mockPost({ id: "m1", advertencias: ["<img src=x onerror=alert(1)>"] });
      await confirmar();
      const alerta = await screen.findByRole("alert");
      expect(alerta).toHaveTextContent(/avisa a sistemas/i);
      expect(alerta).not.toHaveTextContent(/img/);
      expect(document.querySelector("img[src=\"x\"]")).toBeNull();
    });

    it("si el cuerpo del 201 no es JSON legible, igual redirige (el movimiento ya se guardó)", async () => {
      mockPost("ok");
      await confirmar();
      await waitFor(() => expect(irA).toHaveBeenCalledWith("/personas/1"));
    });

    it("un error del servidor se muestra en la página y no navega", async () => {
      mockPost({ detail: "La persona ya está suspendida." }, 409);
      await confirmar();
      expect(await screen.findByRole("alert")).toHaveTextContent("La persona ya está suspendida.");
      expect(irA).not.toHaveBeenCalled();
    });
  });
});
