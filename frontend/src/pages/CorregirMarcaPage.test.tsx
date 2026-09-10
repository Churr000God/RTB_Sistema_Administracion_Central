import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { CorregirMarcaPage } from "./CorregirMarcaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const EXCEPCION = {
  id: 1,
  marca_id: 10,
  estado: "pendiente",
  creado_en: "2026-09-06T12:00:00Z",
  persona_nombre: "Persona Ficticia",
  motivo_revision: "fuera_de_horario",
  momento_dispositivo: "2026-09-06T12:00:00Z",
};

function mockApiFetch(opciones: { excepcion?: Response; post?: Response }) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/excepciones/1") {
      return Promise.resolve(opciones.excepcion ?? new Response(JSON.stringify(EXCEPCION)));
    }
    if (path === "/api/correcciones" && init?.method === "POST") {
      return Promise.resolve(
        opciones.post ??
          new Response(
            JSON.stringify({
              id: 1,
              marca_id: 10,
              valor_corregido: "2026-09-06T12:05:00Z",
              motivo: "ajuste",
              autor_id: "persona-1",
              creado_en: "2026-09-06T12:10:00Z",
            }),
            { status: 201 },
          ),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function renderPagina() {
  return render(
    <MemoryRouter initialEntries={["/tiempo/excepciones/1/corregir"]}>
      <Routes>
        <Route path="/tiempo/excepciones/:id/corregir" element={<CorregirMarcaPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

describe("CorregirMarcaPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("precarga la excepción y envía la corrección a POST /api/correcciones", async () => {
    mockApiFetch({});

    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    expect(screen.getByText(/motivo de revisión: fuera_de_horario/i)).toBeInTheDocument();

    await userEvent.type(screen.getByLabelText(/motivo/i), "Ajuste por olvido de checar");
    await userEvent.click(screen.getByRole("button", { name: /guardar corrección/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/correcciones",
        expect.objectContaining({ method: "POST" }),
      ),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => path === "/api/correcciones")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.marca_id).toBe(10);
    expect(cuerpo.motivo).toBe("Ajuste por olvido de checar");
  });

  it("muestra el mensaje real del backend cuando rechaza por ventana vencida", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({
          detail: "La ventana de corrección de 30 día(s) hábil(es) ya venció para esta marca.",
        }),
        { status: 422 },
      ),
    });

    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    await userEvent.type(screen.getByLabelText(/motivo/i), "Ajuste");
    await userEvent.click(screen.getByRole("button", { name: /guardar corrección/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/la ventana de corrección de 30 día\(s\) hábil\(es\) ya venció/i),
      ).toBeInTheDocument(),
    );
  });

  it("muestra el mensaje real del backend cuando rechaza por falta de excepcion_reapertura", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({
          detail:
            "Esta excepción ya está resuelta -- reabrirla exige el permiso excepcion_reapertura (exclusivo de TI).",
        }),
        { status: 403 },
      ),
    });

    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    await userEvent.type(screen.getByLabelText(/motivo/i), "Ajuste");
    await userEvent.click(screen.getByRole("button", { name: /guardar corrección/i }));

    await waitFor(() =>
      expect(screen.getByText(/exige el permiso excepcion_reapertura/i)).toBeInTheDocument(),
    );
  });
});
