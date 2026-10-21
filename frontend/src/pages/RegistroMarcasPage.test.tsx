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

  it("muestra el banner que explica cuándo se puede corregir desde esta pantalla", async () => {
    mockApiFetch();
    render(<RegistroMarcasPage />);
    await waitFor(() => expect(screen.getByRole("table")).toBeInTheDocument());
    expect(screen.getByText(/casi ninguna marca se puede corregir/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /captura manual/i })).toHaveAttribute(
      "href",
      "/tiempo/captura-manual",
    );
  });

  it.each([
    ["en_tramo", /ya forma parte de un tramo/i],
    ["en_tramo_cerrado", /este día ya está cerrado/i],
    ["dia_cerrado_pendiente", /es de un día ya cerrado/i],
  ])("motivo_bloqueo_correccion %s: Corregir bloqueado con su mensaje y sin enlace a corregir", async (motivo, mensaje) => {
    const marca = {
      ...MARCA_1,
      requiere_revision: true,
      estado_revision: "pendiente",
      excepcion_pendiente_id: 42,
      motivo_bloqueo_correccion: motivo,
      dia_id: 21,
      fecha_local: "2026-09-07",
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });

    render(<RegistroMarcasPage />);

    const boton = await waitFor(() => screen.getByRole("button", { name: "Corregir" }));
    expect(boton).toHaveAttribute("aria-disabled", "true");
    expect(screen.queryByRole("link", { name: /^corregir$/i })).not.toBeInTheDocument();
    expect(boton).toHaveAccessibleDescription(mensaje);
    expect(screen.getByRole("link", { name: /ir a revisar el día/i })).toHaveAttribute(
      "href",
      "/tiempo/dias?dia_id=21",
    );
  });

  it("Ir a revisar el día sin fila de día todavía filtra por persona y fecha local", async () => {
    const marca = {
      ...MARCA_1,
      estado_revision: "pendiente",
      excepcion_pendiente_id: 42,
      motivo_bloqueo_correccion: "en_tramo",
      dia_id: null,
      fecha_local: "2026-09-07",
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });
    render(<RegistroMarcasPage />);
    expect(await screen.findByRole("link", { name: /ir a revisar el día/i })).toHaveAttribute(
      "href",
      "/tiempo/dias?persona_id=persona-1&desde=2026-09-07&hasta=2026-09-07",
    );
  });

  it("motivo_bloqueo_correccion null con excepción pendiente conserva el enlace Corregir", async () => {
    const marca = {
      ...MARCA_1,
      requiere_revision: true,
      estado_revision: "pendiente",
      excepcion_pendiente_id: 42,
      motivo_bloqueo_correccion: null,
    };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });
    render(<RegistroMarcasPage />);
    await waitFor(() => screen.getByRole("link", { name: /^corregir$/i }));
    expect(screen.queryByRole("button", { name: "Corregir" })).not.toBeInTheDocument();
  });

  it("un bloqueo sin excepción pendiente no muestra aviso (nada que corregir)", async () => {
    const marca = { ...MARCA_1, excepcion_pendiente_id: null, motivo_bloqueo_correccion: "en_tramo" };
    mockApiFetch({ marcas: new Response(JSON.stringify({ total: 1, marcas: [marca] })) });
    render(<RegistroMarcasPage />);
    await waitFor(() => expect(screen.getByRole("table")).toBeInTheDocument());
    expect(screen.queryByRole("button", { name: "Corregir" })).not.toBeInTheDocument();
  });
});

describe("RegistroMarcasPage · descartar alerta de horario", () => {
  const MARCA_CON_ALERTA = {
    ...MARCA_1,
    id: 10,
    persona_nombre: "Persona Con Alerta",
    excepcion_pendiente_id: 5, // otra excepción: NO es la que se descarta
    motivo_bloqueo_correccion: "en_tramo_cerrado",
    puede_descartar_alerta_horario: true,
    excepcion_horario_pendiente_id: 77,
  };

  function mockConMarcas(marcas: unknown[], post?: () => Promise<Response>) {
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/sesion") {
        return Promise.resolve(new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })));
      }
      if (path === "/api/personas") return Promise.resolve(new Response(JSON.stringify(PERSONAS)));
      if (path.startsWith("/api/marcas?")) {
        return Promise.resolve(new Response(JSON.stringify({ total: marcas.length, marcas })));
      }
      if (path.endsWith("/descartar-alerta-horario") && init?.method === "POST") {
        return post
          ? post()
          : Promise.resolve(new Response(JSON.stringify({ auditoria_id: 1, excepcion_id: 77 }), { status: 200 }));
      }
      return Promise.reject(new Error(`ruta no mockeada: ${path}`));
    });
  }

  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("el botón aparece solo con el flag en true (y con el id de la excepción de horario)", async () => {
    mockConMarcas([
      MARCA_CON_ALERTA,
      { ...MARCA_1, id: 11, persona_nombre: "Sin Flag" },
      { ...MARCA_1, id: 12, persona_nombre: "Flag Apagado", puede_descartar_alerta_horario: false, excepcion_horario_pendiente_id: 80 },
      { ...MARCA_1, id: 13, persona_nombre: "Flag Sin Id", puede_descartar_alerta_horario: true, excepcion_horario_pendiente_id: null },
    ]);
    render(<RegistroMarcasPage />);
    await screen.findByText("Persona Con Alerta");

    expect(screen.getAllByRole("button", { name: /^descartar alerta$/i })).toHaveLength(1);
    const fila = screen.getByText("Persona Con Alerta").closest("tr")!;
    expect(within(fila).getByRole("button", { name: /^descartar alerta$/i })).toBeInTheDocument();
  });

  it("el «¿Por qué?» menciona la salida solo cuando el flag es true", async () => {
    mockConMarcas([
      MARCA_CON_ALERTA,
      {
        ...MARCA_1, id: 14, persona_nombre: "Bloqueada Sin Flag", excepcion_pendiente_id: 6,
        motivo_bloqueo_correccion: "en_tramo_cerrado",
      },
    ]);
    render(<RegistroMarcasPage />);
    await screen.findByText("Persona Con Alerta");

    const conFlag = screen.getByText("Persona Con Alerta").closest("tr")!;
    const sinFlag = screen.getByText("Bloqueada Sin Flag").closest("tr")!;
    expect(conFlag).toHaveTextContent(/puedes descartarla con constancia/i);
    expect(sinFlag).not.toHaveTextContent(/puedes descartarla con constancia/i);
  });

  it("flujo: abre el modal, envía a la excepción de horario (77, no la 5) y refresca la lista", async () => {
    mockConMarcas([MARCA_CON_ALERTA]);
    render(<RegistroMarcasPage />);
    await screen.findByText("Persona Con Alerta");
    const cargasAntes = vi.mocked(apiFetch).mock.calls.filter(([p]) => (p as string).startsWith("/api/marcas?")).length;

    await userEvent.click(screen.getByRole("button", { name: /^descartar alerta$/i }));
    await userEvent.type(screen.getByLabelText(/motivo del descarte/i), "Salió tarde por una junta autorizada.");
    await userEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: /^descartar alerta$/i }));

    expect(await screen.findByText(/alerta descartada/i)).toBeInTheDocument();
    const post = vi
      .mocked(apiFetch)
      .mock.calls.filter(([p, init]) => (p as string).endsWith("/descartar-alerta-horario") && init?.method === "POST");
    expect(post).toHaveLength(1);
    expect(post[0][0]).toBe("/api/excepciones/77/descartar-alerta-horario");

    await userEvent.click(screen.getByRole("button", { name: /^cerrar$/i }));
    await waitFor(() => {
      const cargasDespues = vi.mocked(apiFetch).mock.calls.filter(([p]) => (p as string).startsWith("/api/marcas?")).length;
      expect(cargasDespues).toBeGreaterThan(cargasAntes);
    });
  });

  it("un error del backend se muestra tal cual dentro del modal", async () => {
    mockConMarcas([MARCA_CON_ALERTA], () =>
      Promise.resolve(new Response(JSON.stringify({ detail: "No puedes descartar tu propia alerta." }), { status: 403 })),
    );
    render(<RegistroMarcasPage />);
    await screen.findByText("Persona Con Alerta");

    await userEvent.click(screen.getByRole("button", { name: /^descartar alerta$/i }));
    await userEvent.type(screen.getByLabelText(/motivo del descarte/i), "Motivo suficientemente largo.");
    await userEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: /^descartar alerta$/i }));

    expect(await screen.findByText("No puedes descartar tu propia alerta.")).toBeInTheDocument();
  });
});
