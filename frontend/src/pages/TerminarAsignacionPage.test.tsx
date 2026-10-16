import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { TerminarAsignacionPage } from "./TerminarAsignacionPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const ASIGNACION_ID = "asignacion-ficticia-1";

const ASIGNACION = {
  id: ASIGNACION_ID,
  persona_id: "persona-ficticia-1",
  persona_nombre: "Persona Ficticia Uno",
  nombre_puesto: "Puesto Ficticio Uno",
  nombre_departamento: "Departamento Ficticio Uno",
};

function mockApiFetch(overrides: { get?: Response; patch?: (init: RequestInit) => Response }) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === `/api/asignaciones/${ASIGNACION_ID}/terminar` && init?.method === "PATCH") {
      return Promise.resolve(
        overrides.patch ? overrides.patch(init) : new Response(JSON.stringify(ASIGNACION))
      );
    }
    if (path === `/api/asignaciones/${ASIGNACION_ID}`) {
      return Promise.resolve(overrides.get ?? new Response(JSON.stringify(ASIGNACION)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/estructura/asignaciones/${ASIGNACION_ID}/terminar`]}>
      <Routes>
        <Route path="/estructura/asignaciones/:id/terminar" element={<TerminarAsignacionPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("TerminarAsignacionPage", () => {
  it("muestra la persona y el puesto de la asignación a terminar", async () => {
    mockApiFetch({});
    renderPagina();

    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    expect(screen.getByText(/puesto ficticio uno/i)).toBeInTheDocument();
  });

  it("envía vigente_hasta a PATCH /api/asignaciones/:id/terminar", async () => {
    mockApiFetch({});
    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/vigente hasta/i), "2026-07-01");
    await userEvent.click(screen.getByRole("button", { name: /confirmar término/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        `/api/asignaciones/${ASIGNACION_ID}/terminar`,
        expect.objectContaining({ method: "PATCH" })
      )
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(
        ([path, init]) =>
          path === `/api/asignaciones/${ASIGNACION_ID}/terminar` &&
          (init as RequestInit)?.method === "PATCH"
      )!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.vigente_hasta).toBe("2026-07-01");
  });

  it("muestra el detail real del backend cuando la asignación ya está cerrada (422)", async () => {
    mockApiFetch({
      patch: () =>
        new Response(JSON.stringify({ detail: "Esta asignación ya está cerrada." }), {
          status: 422,
        }),
    });
    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/vigente hasta/i), "2026-07-01");
    await userEvent.click(screen.getByRole("button", { name: /confirmar término/i }));

    await waitFor(() =>
      expect(screen.getByText("Esta asignación ya está cerrada.")).toBeInTheDocument()
    );
  });
});

describe("TerminarAsignacionPage · fecha de término no anterior al inicio", () => {
  const CON_INICIO = { ...ASIGNACION, vigente_desde: "2026-03-10" };
  const patches = () => vi.mocked(apiFetch).mock.calls.filter(([, i]) => (i as RequestInit | undefined)?.method === "PATCH");

  it("si el servidor manda el inicio, el campo lo usa como mínimo", async () => {
    mockApiFetch({ get: new Response(JSON.stringify(CON_INICIO)) });
    renderPagina();
    await waitFor(() => expect(screen.getByLabelText(/vigente hasta/i)).toHaveAttribute("min", "2026-03-10"));
  });

  it("una fecha anterior al inicio se rechaza antes de enviar, con el mensaje del backend", async () => {
    vi.mocked(apiFetch).mockReset();
    mockApiFetch({ get: new Response(JSON.stringify(CON_INICIO)) });
    renderPagina();
    await waitFor(() => expect(screen.getByLabelText(/vigente hasta/i)).toHaveAttribute("min", "2026-03-10"));
    fireEvent.change(screen.getByLabelText(/vigente hasta/i), { target: { value: "2026-03-09" } });
    fireEvent.submit(document.querySelector("form")!);
    expect(await screen.findByText("La fecha de término no puede ser anterior al inicio de la asignación.")).toBeInTheDocument();
    expect(patches()).toHaveLength(0);
  });

  it("el mismo día del inicio sí se envía", async () => {
    vi.mocked(apiFetch).mockReset();
    mockApiFetch({ get: new Response(JSON.stringify(CON_INICIO)) });
    renderPagina();
    await waitFor(() => expect(screen.getByLabelText(/vigente hasta/i)).toHaveAttribute("min", "2026-03-10"));
    fireEvent.change(screen.getByLabelText(/vigente hasta/i), { target: { value: "2026-03-10" } });
    fireEvent.submit(document.querySelector("form")!);
    await waitFor(() => expect(patches()).toHaveLength(1));
  });

  it("sin el inicio conocido, el 422 del backend se muestra tal cual", async () => {
    vi.mocked(apiFetch).mockReset();
    const detail = "La fecha de término no puede ser anterior al inicio de la asignación.";
    mockApiFetch({ patch: () => new Response(JSON.stringify({ detail }), { status: 422 }) });
    renderPagina();
    await waitFor(() => expect(screen.getByText("Persona Ficticia Uno")).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/vigente hasta/i), { target: { value: "2026-01-01" } });
    fireEvent.submit(document.querySelector("form")!);
    expect(await screen.findByRole("alert")).toHaveTextContent(detail);
  });
});
