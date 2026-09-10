import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { RegistroMarcasPage } from "./RegistroMarcasPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONAS = [
  { id: "persona-1", primer_nombre: "Persona", apellido_paterno: "Ficticia Uno" },
  { id: "persona-2", primer_nombre: "Otra", apellido_paterno: "Persona" },
];

const MARCA_1 = {
  id: 1,
  evento_id: "evento-1",
  persona_id: "persona-1",
  persona_nombre: "Persona Ficticia Uno",
  terminal_id: "rh-captura-01",
  secuencia_local: null,
  momento_dispositivo: "2026-09-07T12:00:00Z",
  momento_efectivo: "2026-09-07T12:00:00Z",
  desfase_local: "-06:00",
  momento_recepcion: "2026-09-07T12:00:00Z",
  estado_reloj: "sincronizado",
  origen: "captura_manual",
  version_software: "1.0.0",
  requiere_revision: false,
  estado_revision: "sin_revision",
  motivos_revision: [],
  excepcion_pendiente_id: null,
};

function mockApiFetch(opciones: { marcas?: Response } = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/personas") {
      return Promise.resolve(new Response(JSON.stringify(PERSONAS)));
    }
    if (path.startsWith("/api/marcas?")) {
      return Promise.resolve(
        opciones.marcas ?? new Response(JSON.stringify({ total: 1, marcas: [MARCA_1] })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("RegistroMarcasPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("carga el feed inicial con límite fijo y sin filtros", async () => {
    mockApiFetch();

    render(<RegistroMarcasPage />);

    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Persona Ficticia Uno")).toBeInTheDocument(),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path]) => (path as string).startsWith("/api/marcas?"))!;
    expect(llamada[0]).toBe("/api/marcas?limite=100");
    expect(screen.getByText(/mostrando 1 de 1 marcas/i)).toBeInTheDocument();
  });

  it("agrega persona_id a la query al filtrar por persona", async () => {
    mockApiFetch();

    render(<RegistroMarcasPage />);
    await waitFor(() =>
      expect(within(screen.getByRole("table")).getByText("Persona Ficticia Uno")).toBeInTheDocument(),
    );

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por persona/i), "persona-2");

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => (path as string).startsWith("/api/marcas?"));
      expect(llamadas.at(-1)![0]).toBe("/api/marcas?persona_id=persona-2&limite=100");
    });
  });

  it("muestra estado vacío cuando no hay marcas", async () => {
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 0, marcas: [] })) });

    render(<RegistroMarcasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay marcas que coincidan/i)).toBeInTheDocument(),
    );
  });

  it("muestra el estado de error cuando falla la carga", async () => {
    mockApiFetch({ marcas: new Response(null, { status: 500 }) });

    render(<RegistroMarcasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el registro de marcas/i)).toBeInTheDocument(),
    );
  });

  it("refresca sola cada 20 segundos (polling)", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    mockApiFetch();

    render(<RegistroMarcasPage />);
    await vi.waitFor(() =>
      expect(
        vi.mocked(apiFetch).mock.calls.filter(([path]) => (path as string).startsWith("/api/marcas?")),
      ).toHaveLength(1),
    );

    await act(async () => {
      await vi.advanceTimersByTimeAsync(20_000);
    });

    const llamadas = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => (path as string).startsWith("/api/marcas?"));
    expect(llamadas.length).toBeGreaterThanOrEqual(2);
  });

  it("columna Ocurrió muestra momento_efectivo + desfase_local, distinto de Recibida", async () => {
    const marca = {
      ...MARCA_1,
      momento_dispositivo: "2026-09-07T08:00:00Z",
      momento_efectivo: "2026-09-07T08:00:00Z",
      desfase_local: "-06:00",
      momento_recepcion: "2026-09-07T14:00:00Z",
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });

    render(<RegistroMarcasPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    const celdas = within(fila).getAllByRole("cell");
    const celdaOcurrio = celdas[4];
    const celdaRecibida = celdas[5];
    expect(celdaOcurrio).toHaveTextContent("-06:00");
    expect(celdaOcurrio.textContent).not.toBe(celdaRecibida.textContent);
  });

  it("momento_efectivo distinto de momento_dispositivo muestra el valor corregido y el original", async () => {
    const marca = {
      ...MARCA_1,
      momento_dispositivo: "2026-09-07T08:00:00Z",
      momento_efectivo: "2026-09-07T09:00:00Z",
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });

    render(<RegistroMarcasPage />);

    const fila = await waitFor(() => screen.getByRole("row", { name: /persona ficticia uno/i }));
    const celdaOcurrio = within(fila).getAllByRole("cell")[4];
    expect(celdaOcurrio).toHaveTextContent("03:00:00");
    expect(celdaOcurrio).toHaveTextContent(/original/i);
    expect(celdaOcurrio).toHaveTextContent("02:00:00");
  });

  it("motivos_revision etiquetados aparecen bajo el badge de revisión pendiente", async () => {
    const marca = {
      ...MARCA_1,
      requiere_revision: true,
      estado_revision: "pendiente",
      motivos_revision: ["persona_inactiva", "dia_cerrado"],
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });

    render(<RegistroMarcasPage />);

    await waitFor(() => expect(screen.getByText(/requiere revisión/i)).toBeInTheDocument());
    expect(screen.getByText(/persona inactiva, día ya cerrado/i)).toBeInTheDocument();
  });

  it("estado_revision resuelta muestra el badge de resuelta, no el de pendiente", async () => {
    const marca = {
      ...MARCA_1,
      requiere_revision: true,
      estado_revision: "resuelta",
      motivos_revision: ["persona_inactiva"],
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });

    render(<RegistroMarcasPage />);

    await waitFor(() => expect(screen.getByText(/revisión resuelta/i)).toBeInTheDocument());
    expect(screen.queryByText(/^requiere revisión$/i)).not.toBeInTheDocument();
    expect(screen.getByText(/persona inactiva/i)).toBeInTheDocument();
  });

  it("excepcion_pendiente_id no nulo muestra el link Corregir con el href correcto", async () => {
    const marca = {
      ...MARCA_1,
      requiere_revision: true,
      estado_revision: "pendiente",
      excepcion_pendiente_id: 42,
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });

    render(<RegistroMarcasPage />);

    const enlace = await waitFor(() => screen.getByRole("link", { name: /corregir/i }));
    expect(enlace).toHaveAttribute("href", "/tiempo/excepciones/42/corregir");
  });

  it("requiere_revision true con excepcion_pendiente_id null no muestra el botón Corregir", async () => {
    const marca = {
      ...MARCA_1,
      requiere_revision: true,
      estado_revision: "pendiente",
      excepcion_pendiente_id: null,
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });

    render(<RegistroMarcasPage />);

    await waitFor(() => expect(screen.getByText(/requiere revisión/i)).toBeInTheDocument());
    expect(screen.queryByRole("link", { name: /corregir/i })).not.toBeInTheDocument();
  });
});
