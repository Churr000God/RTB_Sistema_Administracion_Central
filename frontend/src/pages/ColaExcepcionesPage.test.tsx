import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ColaExcepcionesPage } from "./ColaExcepcionesPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const EXCEPCIONES = [
  {
    id: 1,
    marca_id: 10,
    dia_id: null,
    motivo_revision: "fuera_de_horario",
    estado: "pendiente",
    creado_en: "2026-09-06T12:00:00Z",
    persona_nombre: "Persona Ficticia",
    momento_dispositivo: "2026-09-06T12:00:00Z",
  },
  {
    id: 2,
    marca_id: null,
    dia_id: 5,
    motivo_revision: "dia_sin_marca",
    estado: "pendiente",
    creado_en: "2026-09-05T08:00:00Z",
    persona_nombre: null,
    momento_dispositivo: null,
  },
];

function mockApiFetch(listado?: Response) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/excepciones") {
      return Promise.resolve(listado ?? new Response(JSON.stringify(EXCEPCIONES)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("ColaExcepcionesPage", () => {
  it("lista sólo las excepciones con marca_id (las de dia_id las resuelve la bandeja de ausencias)", async () => {
    mockApiFetch();

    render(<ColaExcepcionesPage />);

    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    expect(within(screen.getByRole("table")).getByText("Fuera de horario")).toBeInTheDocument();
    expect(screen.queryByText("dia_sin_marca")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: /corregir/i })).toHaveAttribute(
      "href",
      "/tiempo/excepciones/1/corregir",
    );
  });

  it("filtra por persona y ordena por motivo", async () => {
    mockApiFetch(
      new Response(
        JSON.stringify([
          ...EXCEPCIONES,
          {
            id: 3,
            marca_id: 30,
            dia_id: null,
            motivo_revision: "persona_inactiva",
            estado: "pendiente",
            creado_en: "2026-09-07T09:00:00Z",
            persona_nombre: "Otra Persona",
            momento_dispositivo: "2026-09-07T09:00:00Z",
          },
        ]),
      ),
    );

    render(<ColaExcepcionesPage />);
    const tabla = await screen.findByRole("table");
    expect(within(tabla).getAllByRole("row")).toHaveLength(3); // encabezado + 2 filas

    await userEvent.type(screen.getByLabelText(/buscar por persona/i), "otra");
    await waitFor(() => expect(within(tabla).getAllByRole("row")).toHaveLength(2));
    expect(within(tabla).getByText("Otra Persona")).toBeInTheDocument();
  });

  it("muestra estado vacío cuando no hay excepciones pendientes", async () => {
    mockApiFetch(new Response(JSON.stringify([])));

    render(<ColaExcepcionesPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay excepciones de marca pendientes/i)).toBeInTheDocument(),
    );
  });

  it("muestra el estado de error cuando falla la carga", async () => {
    mockApiFetch(new Response(null, { status: 500 }));

    render(<ColaExcepcionesPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar la cola de excepciones/i)).toBeInTheDocument(),
    );
  });

  it("motivo con sufijo concatenado (fn_ausencia_resuelve_excepcion) traduce sólo la parte anterior al separador", async () => {
    mockApiFetch(
      new Response(
        JSON.stringify([
          {
            id: 4,
            marca_id: 40,
            dia_id: null,
            motivo_revision: "dia_cerrado — resuelto por ausencia autorizada, carga tardía",
            estado: "resuelto",
            creado_en: "2026-09-07T09:00:00Z",
            persona_nombre: "Persona Resuelta",
            momento_dispositivo: "2026-09-07T09:00:00Z",
          },
        ]),
      ),
    );

    render(<ColaExcepcionesPage />);

    await waitFor(() => expect(screen.getByText("Persona Resuelta")).toBeInTheDocument());
    expect(
      within(screen.getByRole("table")).getByText(
        "Día ya cerrado — resuelto por ausencia autorizada, carga tardía",
      ),
    ).toBeInTheDocument();
  });
});
