import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { BitacoraMovimientosPage } from "./BitacoraMovimientosPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONA = {
  id: "p1",
  primer_nombre: "Ana",
  apellido_paterno: "Miranda",
  estado: "activo",
};

const MOVIMIENTOS = [
  {
    id: "m1",
    persona_id: "p1",
    tipo_movimiento: "alta",
    fecha_efectiva: "2024-11-04T11:35:00Z",
    motivo: null,
    documento_ref: null,
    registrado_por: null,
    registrado_por_nombre: null,
  },
  {
    id: "m2",
    persona_id: "p1",
    tipo_movimiento: "suspension",
    fecha_efectiva: "2026-04-06T10:22:00Z",
    motivo: "Suspensión precautoria mientras se desahoga la investigación interna.",
    documento_ref: "RTB-2026-014",
    registrado_por: "u1",
    registrado_por_nombre: "jorge.alcantara",
  },
  {
    id: "m3",
    persona_id: "p1",
    tipo_movimiento: "reactivacion",
    fecha_efectiva: "2026-04-18T17:40:00Z",
    motivo: "Cierre de la investigación interna sin sanción.",
    documento_ref: null,
    registrado_por: "u2",
    registrado_por_nombre: "mariana.renteria",
  },
];

function mockApiFetch(movimientos: typeof MOVIMIENTOS) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path.endsWith("/movimientos")) {
      return Promise.resolve(new Response(JSON.stringify(movimientos)));
    }
    return Promise.resolve(new Response(JSON.stringify(PERSONA)));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={["/personas/p1/bitacora"]}>
      <Routes>
        <Route path="/personas/:id/bitacora" element={<BitacoraMovimientosPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("BitacoraMovimientosPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("muestra la píldora de transición: sin flecha en el primer movimiento, con flecha en los siguientes", async () => {
    mockApiFetch(MOVIMIENTOS);
    renderPagina();

    await waitFor(() => expect(screen.getByText("Ana Miranda", { selector: "strong" })).toBeInTheDocument());

    // alta: sólo el estado nuevo (Activo), sin "Suspendido" antes de él
    const grupo2024 = screen.getByText("2024").closest(".grupo-anio")!;
    expect(grupo2024).toHaveTextContent("Activo");
    expect(grupo2024).not.toHaveTextContent("Suspendido");

    // suspension: Activo → Suspendido
    const grupo2026 = screen.getByText("2026").closest(".grupo-anio")!;
    expect(grupo2026).toHaveTextContent("Activo");
    expect(grupo2026).toHaveTextContent("Suspendido");
  });

  it("muestra el autor resuelto o 'Sistema' cuando no hay registrado_por_nombre", async () => {
    mockApiFetch(MOVIMIENTOS);
    renderPagina();

    await waitFor(() => expect(screen.getByText("Ana Miranda", { selector: "strong" })).toBeInTheDocument());

    expect(screen.getByText("jorge.alcantara", { selector: "strong" })).toBeInTheDocument();
    expect(screen.getByText("mariana.renteria", { selector: "strong" })).toBeInTheDocument();
    expect(screen.getByText("Sistema", { selector: "strong" })).toBeInTheDocument();
  });

  it("filtra por tipo de movimiento", async () => {
    mockApiFetch(MOVIMIENTOS);
    renderPagina();

    await waitFor(() => expect(screen.getByText("Ana Miranda", { selector: "strong" })).toBeInTheDocument());

    await userEvent.selectOptions(
      screen.getByLabelText(/filtrar por tipo de movimiento/i),
      "reactivacion"
    );

    expect(screen.queryByText(/investigación interna sin sanción/i)).toBeInTheDocument();
    expect(screen.queryByText(/investigación interna\./i)).not.toBeInTheDocument();
  });

  it("agrupa los movimientos por año", async () => {
    mockApiFetch(MOVIMIENTOS);
    renderPagina();

    await waitFor(() => expect(screen.getByText("Ana Miranda", { selector: "strong" })).toBeInTheDocument());

    expect(screen.getByText("2026")).toBeInTheDocument();
    expect(screen.getByText("2024")).toBeInTheDocument();
  });

  it("muestra la tarjeta de registro inmutable (DB1 ya aplicado)", async () => {
    mockApiFetch(MOVIMIENTOS);
    renderPagina();

    await waitFor(() => expect(screen.getByText("Ana Miranda", { selector: "strong" })).toBeInTheDocument());

    expect(screen.getByText("Registro inmutable")).toBeInTheDocument();
    expect(
      screen.getByText(/no se editan ni se borran/i)
    ).toBeInTheDocument();
  });
});
