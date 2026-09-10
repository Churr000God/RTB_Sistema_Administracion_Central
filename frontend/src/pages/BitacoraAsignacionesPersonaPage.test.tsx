import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { BitacoraAsignacionesPersonaPage } from "./BitacoraAsignacionesPersonaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONA_ID = "persona-ficticia-1";

const PERSONA = {
  id: PERSONA_ID,
  primer_nombre: "Persona",
  apellido_paterno: "Ficticia Uno",
  estado: "activo",
};

const ASIGNACIONES = [
  {
    id: "asignacion-ficticia-1",
    persona_id: PERSONA_ID,
    puesto_id: "puesto-ficticio-1",
    nombre_puesto: "Puesto Ficticio Uno",
    nombre_departamento: "Departamento Ficticio Uno",
    nombre_area: "Área Ficticia Uno",
    vigente_desde: "2024-01-01",
    vigente_hasta: "2025-01-01",
  },
  {
    id: "asignacion-ficticia-2",
    persona_id: PERSONA_ID,
    puesto_id: "puesto-ficticio-2",
    nombre_puesto: "Puesto Ficticio Dos",
    nombre_departamento: "Departamento Ficticio Dos",
    nombre_area: "Área Ficticia Dos",
    vigente_desde: "2025-01-02",
    vigente_hasta: null,
  },
  {
    id: "asignacion-ajena",
    persona_id: "otra-persona-ficticia",
    puesto_id: "puesto-ficticio-3",
    nombre_puesto: "Puesto Ficticio Ajeno",
    nombre_departamento: "Departamento Ficticio Tres",
    nombre_area: "Área Ficticia Tres",
    vigente_desde: "2025-06-01",
    vigente_hasta: null,
  },
];

function mockApiFetch(overrides: { persona?: Response; asignaciones?: Response }) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(overrides.asignaciones ?? new Response(JSON.stringify(ASIGNACIONES)));
    }
    if (path === `/api/personas/${PERSONA_ID}`) {
      return Promise.resolve(overrides.persona ?? new Response(JSON.stringify(PERSONA)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/personas/${PERSONA_ID}/bitacora-asignaciones`]}>
      <Routes>
        <Route
          path="/personas/:id/bitacora-asignaciones"
          element={<BitacoraAsignacionesPersonaPage />}
        />
      </Routes>
    </MemoryRouter>
  );
}

describe("BitacoraAsignacionesPersonaPage", () => {
  it("muestra el historial completo de la persona, filtrado por persona_id (excluye asignaciones ajenas)", async () => {
    mockApiFetch({});
    renderPagina();

    await waitFor(() => expect(screen.getByText("Puesto Ficticio Dos")).toBeInTheDocument());
    expect(screen.getByText("Puesto Ficticio Uno")).toBeInTheDocument();
    expect(screen.queryByText("Puesto Ficticio Ajeno")).not.toBeInTheDocument();
  });

  it("muestra el conteo total de asignaciones de la persona en la cabecera", async () => {
    mockApiFetch({});
    renderPagina();

    await waitFor(() => expect(screen.getByText("Puesto Ficticio Dos")).toBeInTheDocument());
    expect(screen.getByText("Asignaciones").closest("div")).toHaveTextContent("2");
  });

  it("distingue vigente de terminada por insignia", async () => {
    mockApiFetch({});
    renderPagina();

    await waitFor(() => expect(screen.getByText("Puesto Ficticio Dos")).toBeInTheDocument());
    expect(screen.getByText("Vigente", { selector: "span.insignia" })).toBeInTheDocument();
    expect(screen.getByText("Terminada", { selector: "span.insignia" })).toBeInTheDocument();
  });

  it("muestra un mensaje propio cuando la persona no tiene asignaciones", async () => {
    mockApiFetch({ asignaciones: new Response(JSON.stringify([])) });
    renderPagina();

    await waitFor(() =>
      expect(
        screen.getByText(/esta persona no tiene asignaciones registradas todavía/i)
      ).toBeInTheDocument()
    );
  });

  it("muestra un error si falla la carga (sin botón reintentar, a diferencia de otras páginas)", async () => {
    mockApiFetch({ persona: new Response(null, { status: 500 }) });
    renderPagina();

    await waitFor(() =>
      expect(
        screen.getByText(/no se pudo cargar la bitácora de puestos/i)
      ).toBeInTheDocument()
    );
  });
});
