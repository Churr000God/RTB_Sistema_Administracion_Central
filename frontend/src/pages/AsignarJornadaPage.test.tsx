import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AsignarJornadaPage } from "./AsignarJornadaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONAS_ACTIVAS = [
  {
    id: "persona-ficticia-1",
    primer_nombre: "Persona",
    apellido_paterno: "Ficticia Uno",
    estado: "activo",
    tiene_jornada_vigente: false,
  },
];

function mockApiFetch(opciones: {
  sesion?: Response;
  post?: Response | Response[];
  cadena?: Response;
  escritura?: Response | Response[];
  personas?: typeof PERSONAS_ACTIVAS;
}) {
  let llamadaPost = 0;
  let llamadaEscritura = 0;
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        opciones.sesion ??
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/personas") {
      return Promise.resolve(new Response(JSON.stringify(opciones.personas ?? PERSONAS_ACTIVAS)));
    }
    if (path.startsWith("/api/personas/") && path.endsWith("/jornadas")) {
      return Promise.resolve(opciones.cadena ?? new Response(JSON.stringify([])));
    }
    if (path === "/api/jornadas-asignadas" && init?.method === "POST") {
      if (Array.isArray(opciones.post)) {
        const respuesta = opciones.post[Math.min(llamadaPost, opciones.post.length - 1)];
        llamadaPost += 1;
        return Promise.resolve(respuesta);
      }
      return Promise.resolve(opciones.post ?? new Response(JSON.stringify({ id: 1 }), { status: 201 }));
    }
    if (
      path.startsWith("/api/jornadas-asignadas/") &&
      (init?.method === "PATCH" || init?.method === "DELETE")
    ) {
      if (Array.isArray(opciones.escritura)) {
        const respuesta = opciones.escritura[Math.min(llamadaEscritura, opciones.escritura.length - 1)];
        llamadaEscritura += 1;
        return Promise.resolve(respuesta);
      }
      return Promise.resolve(opciones.escritura ?? new Response(JSON.stringify({}), { status: 200 }));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

// Cadena de 3 jornadas para una sola persona: pasada, en curso (con sucesora) y futura terminal.
const PERSONA_CON_CADENA = [
  { id: "persona-1", primer_nombre: "Ana", apellido_paterno: "Con Jornada", estado: "activo", tiene_jornada_vigente: true },
];

const CADENA_TRES_JORNADAS = [
  {
    id: 3,
    tipo_jornada: "flexible",
    vigente_desde: "2026-10-01",
    vigente_hasta: null,
    horas_semanales_calculadas: 40,
    patron_semanal: [
      { dia_semana: "lunes", hora_entrada: "09:00:00", hora_salida: "17:00:00", minutos_comida: 30 },
    ],
    estado_vigencia: "futura",
    es_ultima_de_cadena: true,
    puede_editarse: true,
    puede_eliminarse: true,
    puede_mover_limite: false,
  },
  {
    id: 2,
    tipo_jornada: "normal",
    vigente_desde: "2026-08-01",
    vigente_hasta: "2026-09-30",
    horas_semanales_calculadas: 45,
    patron_semanal: [
      { dia_semana: "lunes", hora_entrada: "09:00:00", hora_salida: "18:00:00", minutos_comida: 60 },
    ],
    estado_vigencia: "en_curso",
    es_ultima_de_cadena: false,
    puede_editarse: false,
    puede_eliminarse: false,
    puede_mover_limite: true,
  },
  {
    id: 1,
    tipo_jornada: "normal",
    vigente_desde: "2026-01-01",
    vigente_hasta: "2026-07-31",
    horas_semanales_calculadas: 45,
    patron_semanal: [
      { dia_semana: "lunes", hora_entrada: "09:00:00", hora_salida: "18:00:00", minutos_comida: 60 },
    ],
    estado_vigencia: "pasada",
    es_ultima_de_cadena: false,
    puede_editarse: false,
    puede_eliminarse: false,
    puede_mover_limite: false,
  },
];

async function expandirFilaDeAna() {
  const tabla = await screen.findByRole("table");
  const fila = within(tabla).getByText("Ana Con Jornada").closest("tr")!;
  await userEvent.click(fila);
  await waitFor(() => expect(screen.getByText("Futura")).toBeInTheDocument());
}

async function abrirFormulario() {
  // El formulario ya no tiene un botón genérico para abrirlo -- se abre desde el "Asignar"/
  // "Renovar" de una fila de la tabla de cobertura. PERSONAS_ACTIVAS tiene una sola persona, sin
  // jornada vigente, así que hay un único botón "Asignar" en toda la página.
  await userEvent.click(await screen.findByRole("button", { name: /^asignar$/i }));
}

async function llenarFormularioBasico() {
  await abrirFormulario();
  await userEvent.selectOptions(screen.getByLabelText(/^persona$/i), "persona-ficticia-1");
  await userEvent.type(screen.getByLabelText(/vigente desde/i), "2026-01-01");
  await userEvent.click(screen.getByRole("checkbox", { name: /lunes/i }));
  await userEvent.type(screen.getByLabelText(/hora de entrada/i), "09:00");
  await userEvent.type(screen.getByLabelText(/hora de salida/i), "18:00");
}

describe("AsignarJornadaPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("envía persona, jornada y patrón semanal a POST /api/jornadas-asignadas", async () => {
    mockApiFetch({});

    render(<AsignarJornadaPage />);
    await llenarFormularioBasico();
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/jornadas-asignadas",
        expect.objectContaining({ method: "POST" }),
      ),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/jornadas-asignadas" && (init as RequestInit)?.method === "POST")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.persona_id).toBe("persona-ficticia-1");
    expect(cuerpo.tipo_jornada).toBe("normal");
    expect(cuerpo.vigente_desde).toBe("2026-01-01");
    expect(cuerpo.patron_semanal).toEqual([
      { dia_semana: "lunes", hora_entrada: "09:00", hora_salida: "18:00", minutos_comida: 0 },
    ]);
    expect(cuerpo.confirma_cierre_vigente).toBeUndefined();
  });

  it("se queda en la pestaña tras guardar pero cierra el formulario", async () => {
    mockApiFetch({});

    const { container } = render(<AsignarJornadaPage />);
    await llenarFormularioBasico();
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(container.querySelector(".tarjeta-info")).toHaveTextContent(
        /jornada asignada a\s*persona ficticia uno/i,
      ),
    );
    // Sigue en la misma pestaña, pero el formulario se cierra -- hay que reabrirlo desde una fila.
    expect(screen.queryByLabelText(/^persona$/i)).not.toBeInTheDocument();
  });

  it("tras un POST exitoso, invalida la cadena cacheada de esa persona (refetch de /jornadas)", async () => {
    mockApiFetch({});

    render(<AsignarJornadaPage />);
    await llenarFormularioBasico();
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith("/api/personas/persona-ficticia-1/jornadas"),
    );
  });

  it("muestra el diálogo de confirmación en 409 (SCJ01) y reintenta con confirma_cierre_vigente:true", async () => {
    mockApiFetch({
      post: [
        new Response(null, { status: 409 }),
        new Response(JSON.stringify({ id: 1 }), { status: 201 }),
      ],
    });

    render(<AsignarJornadaPage />);
    await llenarFormularioBasico();
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/ya tiene una jornada vigente/i),
    );

    await userEvent.click(screen.getByRole("button", { name: /sí, cerrar la anterior y asignar/i }));

    await waitFor(() => {
      const llamadas = vi
        .mocked(apiFetch)
        .mock.calls.filter(
          ([path, init]) => path === "/api/jornadas-asignadas" && (init as RequestInit)?.method === "POST",
        );
      expect(llamadas).toHaveLength(2);
      const segundoCuerpo = JSON.parse(llamadas[1][1]!.body as string);
      expect(segundoCuerpo.confirma_cierre_vigente).toBe(true);
    });
  });

  it("muestra un error legible cuando el backend rechaza el horario (422)", async () => {
    mockApiFetch({
      post: new Response(
        JSON.stringify({
          detail: [{ loc: ["body", "patron_semanal", 0], msg: "hora_salida debe ser posterior a hora_entrada" }],
        }),
        { status: 422 },
      ),
    });

    render(<AsignarJornadaPage />);
    await llenarFormularioBasico();
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() =>
      expect(screen.getByText(/no se pudo registrar la asignación de jornada/i)).toBeInTheDocument(),
    );
  });

  it("oculta el grupo Jornadas del sidebar cuando puede_ver_modulo_3 es false", async () => {
    mockApiFetch({
      sesion: new Response(
        JSON.stringify({
          acceso_permitido: true,
          motivo_bloqueo: null,
          puede_ver_modulo_1: true,
          puede_ver_modulo_2: true,
          puede_ver_modulo_3: false,
        }),
      ),
    });

    render(<AsignarJornadaPage />);

    await waitFor(() =>
      expect(screen.getByRole("button", { name: /^asignar$/i })).toBeInTheDocument(),
    );
    expect(screen.queryByText(/^jornadas$/i)).not.toBeInTheDocument();
  });

  it("muestra la cobertura de jornadas (con/sin jornada) y permite preseleccionar desde ahí", async () => {
    const personas = [
      { id: "persona-1", primer_nombre: "Ana", apellido_paterno: "Con Jornada", estado: "activo", tiene_jornada_vigente: true },
      { id: "persona-2", primer_nombre: "Beto", apellido_paterno: "Sin Jornada", estado: "activo", tiene_jornada_vigente: false },
    ];
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
        );
      }
      if (path === "/api/personas") {
        return Promise.resolve(new Response(JSON.stringify(personas)));
      }
      return Promise.reject(new Error(`ruta no mockeada: ${path}`));
    });

    render(<AsignarJornadaPage />);

    const tabla = await screen.findByRole("table");
    expect(within(tabla).getByText("Con jornada")).toBeInTheDocument();
    expect(within(tabla).getByText("Sin jornada")).toBeInTheDocument();
    expect(screen.getByText("Personas activas").nextElementSibling).toHaveTextContent("2");

    await userEvent.click(
      within(tabla).getByRole("button", { name: /asignar/i }),
    );
    expect(screen.getByLabelText(/^persona$/i)).toHaveValue("persona-2");
  });

  it("refresca la cobertura de jornadas después de registrar una nueva", async () => {
    mockApiFetch({});

    render(<AsignarJornadaPage />);
    await llenarFormularioBasico();
    await userEvent.click(screen.getByRole("button", { name: /registrar/i }));

    await waitFor(() => {
      const llamadasPersonas = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => path === "/api/personas");
      expect(llamadasPersonas.length).toBeGreaterThanOrEqual(2);
    });
  });

  it("el formulario arranca cerrado y el botón de la fila lo abre", async () => {
    mockApiFetch({});

    render(<AsignarJornadaPage />);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /^asignar$/i })).toBeInTheDocument(),
    );
    expect(screen.queryByLabelText(/^persona$/i)).not.toBeInTheDocument();

    await abrirFormulario();
    expect(screen.getByLabelText(/^persona$/i)).toBeInTheDocument();
  });

  it("click en Asignar/Renovar de una fila abre el formulario si estaba cerrado", async () => {
    const personas = [
      { id: "persona-1", primer_nombre: "Ana", apellido_paterno: "Con Jornada", estado: "activo", tiene_jornada_vigente: true },
    ];
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
        );
      }
      if (path === "/api/personas") {
        return Promise.resolve(new Response(JSON.stringify(personas)));
      }
      return Promise.reject(new Error(`ruta no mockeada: ${path}`));
    });

    render(<AsignarJornadaPage />);
    const tabla = await screen.findByRole("table");
    expect(screen.queryByLabelText(/^persona$/i)).not.toBeInTheDocument();

    await userEvent.click(within(tabla).getByRole("button", { name: /renovar/i }));

    expect(screen.getByLabelText(/^persona$/i)).toHaveValue("persona-1");
  });

  it("expandir una fila muestra el detalle del patrón semanal, colapsar lo oculta", async () => {
    const personas = [
      { id: "persona-1", primer_nombre: "Ana", apellido_paterno: "Con Jornada", estado: "activo", tiene_jornada_vigente: true },
    ];
    const jornada = {
      id: 1,
      tipo_jornada: "normal",
      vigente_desde: "2026-01-01",
      vigente_hasta: null,
      horas_semanales_calculadas: null, // siempre NULL en la DB real -- se calcula del patrón
      patron_semanal: [
        { dia_semana: "lunes", hora_entrada: "09:00:00", hora_salida: "18:00:00", minutos_comida: 60 },
      ],
      estado_vigencia: "en_curso",
      es_ultima_de_cadena: true,
      puede_editarse: false,
      puede_eliminarse: false,
      puede_mover_limite: false,
    };
    let llamadasJornada = 0;
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
        );
      }
      if (path === "/api/personas") {
        return Promise.resolve(new Response(JSON.stringify(personas)));
      }
      if (path === "/api/personas/persona-1/jornadas") {
        llamadasJornada += 1;
        return Promise.resolve(new Response(JSON.stringify([jornada])));
      }
      return Promise.reject(new Error(`ruta no mockeada: ${path}`));
    });

    render(<AsignarJornadaPage />);
    const tabla = await screen.findByRole("table");
    const fila = within(tabla).getByText("Ana Con Jornada").closest("tr")!;

    await userEvent.click(fila);
    await waitFor(() => expect(screen.getByText(/vigente desde/i)).toBeInTheDocument());
    // lunes 09:00-18:00 con 60min de comida -- 9h - 1h = 8h, calculado del patrón, no del
    // campo horas_semanales_calculadas (siempre NULL en la DB real).
    expect(screen.getByText(/8\.0 h\/semana esperadas/)).toBeInTheDocument();

    // colapsar la oculta
    await userEvent.click(fila);
    expect(screen.queryByText(/vigente desde/i)).not.toBeInTheDocument();

    // reabrir no refetchea (cacheada)
    await userEvent.click(fila);
    await waitFor(() => expect(screen.getByText(/vigente desde/i)).toBeInTheDocument());
    expect(llamadasJornada).toBe(1);
  });

  it("expandir una fila sin jornada muestra el mensaje de sin jornada asignada", async () => {
    mockApiFetch({});

    render(<AsignarJornadaPage />);
    const tabla = await screen.findByRole("table");
    const fila = within(tabla).getByText("Persona Ficticia Uno").closest("tr")!;

    await userEvent.click(fila);

    await waitFor(() =>
      expect(screen.getByText(/sin jornada vigente asignada/i)).toBeInTheDocument(),
    );
  });

  it("cadena de 3 jornadas renderiza los 3 badges (Pasada/En curso/Futura)", async () => {
    mockApiFetch({
      personas: PERSONA_CON_CADENA,
      cadena: new Response(JSON.stringify(CADENA_TRES_JORNADAS)),
    });

    render(<AsignarJornadaPage />);
    await expandirFilaDeAna();

    expect(screen.getByText("Pasada")).toBeInTheDocument();
    expect(screen.getByText("En curso")).toBeInTheDocument();
    expect(screen.getByText("Futura")).toBeInTheDocument();
  });

  it("Editar/Eliminar quedan deshabilitados en pasada y en curso, con title explicando el motivo", async () => {
    mockApiFetch({
      personas: PERSONA_CON_CADENA,
      cadena: new Response(JSON.stringify(CADENA_TRES_JORNADAS)),
    });

    render(<AsignarJornadaPage />);
    await expandirFilaDeAna();

    // El botón deshabilitado cambia su nombre accesible (aria-label) al motivo -- se ubican por
    // el texto visible, no por el rol/nombre, para cubrir ambos estados con la misma query.
    const botonesEditar = screen.getAllByText("Editar").map((el) => el.closest("button")!);
    const botonesEliminar = screen.getAllByText("Eliminar").map((el) => el.closest("button")!);
    expect(botonesEditar).toHaveLength(3);
    expect(botonesEliminar).toHaveLength(3);

    // Orden desc: [futura, en_curso, pasada]
    expect(botonesEditar[0]).toBeEnabled();
    expect(botonesEditar[1]).toBeDisabled();
    expect(botonesEditar[1]).toHaveAttribute(
      "title",
      "Sólo se puede editar la última jornada planeada, y sólo si todavía no empezó.",
    );
    expect(botonesEditar[2]).toBeDisabled();

    expect(botonesEliminar[0]).toBeEnabled();
    expect(botonesEliminar[1]).toBeDisabled();
    expect(botonesEliminar[1]).toHaveAttribute(
      "title",
      "Sólo se puede eliminar la última jornada planeada, y sólo si todavía no empezó.",
    );
    expect(botonesEliminar[2]).toBeDisabled();
  });

  it('"Mover fecha de término" sólo se renderiza para la jornada en curso con sucesora', async () => {
    mockApiFetch({
      personas: PERSONA_CON_CADENA,
      cadena: new Response(JSON.stringify(CADENA_TRES_JORNADAS)),
    });

    render(<AsignarJornadaPage />);
    await expandirFilaDeAna();

    expect(screen.getAllByRole("button", { name: /mover fecha de término/i })).toHaveLength(1);
  });

  it("confirmación inline de borrado -- Cancelar la cierra sin llamar al backend", async () => {
    mockApiFetch({
      personas: PERSONA_CON_CADENA,
      cadena: new Response(JSON.stringify(CADENA_TRES_JORNADAS)),
    });

    render(<AsignarJornadaPage />);
    await expandirFilaDeAna();

    await userEvent.click(screen.getByRole("button", { name: /^eliminar$/i }));
    expect(screen.getByRole("alert")).toHaveTextContent(/¿eliminar esta jornada/i);
    expect(screen.getByRole("alert")).toHaveTextContent(
      /la jornada anterior volverá a quedar sin fecha de término/i,
    );

    await userEvent.click(screen.getByRole("button", { name: /^cancelar$/i }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(
      vi.mocked(apiFetch).mock.calls.some(([, init]) => (init as RequestInit)?.method === "DELETE"),
    ).toBe(false);
  });

  it("422 al eliminar muestra el error y mantiene la confirmación abierta", async () => {
    mockApiFetch({
      personas: PERSONA_CON_CADENA,
      cadena: new Response(JSON.stringify(CADENA_TRES_JORNADAS)),
      escritura: new Response(JSON.stringify({ detail: "La cadena cambió, ya no es la última." }), {
        status: 422,
      }),
    });

    render(<AsignarJornadaPage />);
    await expandirFilaDeAna();

    await userEvent.click(screen.getByRole("button", { name: /^eliminar$/i }));
    await userEvent.click(screen.getByRole("button", { name: /sí, eliminar/i }));

    await waitFor(() =>
      expect(screen.getByText(/la cadena cambió, ya no es la última/i)).toBeInTheDocument(),
    );
    // La confirmación sigue abierta -- el botón "Sí, eliminar" sigue presente.
    expect(screen.getByRole("button", { name: /sí, eliminar/i })).toBeInTheDocument();
  });

  it("editar la última jornada futura manda PATCH sin persona_id", async () => {
    mockApiFetch({
      personas: PERSONA_CON_CADENA,
      cadena: new Response(JSON.stringify(CADENA_TRES_JORNADAS)),
    });

    render(<AsignarJornadaPage />);
    await expandirFilaDeAna();

    await userEvent.click(screen.getByRole("button", { name: /^editar$/i }));
    expect(screen.getByRole("button", { name: /guardar cambios/i })).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: /guardar cambios/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/jornadas-asignadas/3",
        expect.objectContaining({ method: "PATCH" }),
      ),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/jornadas-asignadas/3" && (init as RequestInit)?.method === "PATCH")!;
    const cuerpo = JSON.parse(llamada[1]!.body as string);
    expect(cuerpo.persona_id).toBeUndefined();
    expect(cuerpo.tipo_jornada).toBe("flexible");
    expect(cuerpo.vigente_desde).toBe("2026-10-01");
  });

  it("mover el límite de la en curso avisa la cascada con la fecha correcta antes de guardar", async () => {
    mockApiFetch({
      personas: PERSONA_CON_CADENA,
      cadena: new Response(JSON.stringify(CADENA_TRES_JORNADAS)),
    });

    render(<AsignarJornadaPage />);
    await expandirFilaDeAna();

    await userEvent.click(screen.getByRole("button", { name: /mover fecha de término/i }));
    const campoFecha = screen.getByLabelText(/nueva fecha de término/i);
    await userEvent.type(campoFecha, "2026-10-15");

    await waitFor(() =>
      expect(screen.getByText(/el siguiente tramo \(flexible\) pasará a comenzar el 16 oct 2026/i)).toBeInTheDocument(),
    );

    await userEvent.click(screen.getByRole("button", { name: /^guardar$/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/jornadas-asignadas/2/limite",
        expect.objectContaining({ method: "PATCH" }),
      ),
    );
    const llamada = vi
      .mocked(apiFetch)
      .mock.calls.find(([path, init]) => path === "/api/jornadas-asignadas/2/limite" && (init as RequestInit)?.method === "PATCH")!;
    expect(JSON.parse(llamada[1]!.body as string)).toEqual({ vigente_hasta: "2026-10-15" });
  });

  it("muestra el grupo Jornadas del sidebar cuando puede_ver_modulo_3 es true", async () => {
    mockApiFetch({
      sesion: new Response(
        JSON.stringify({
          acceso_permitido: true,
          motivo_bloqueo: null,
          puede_ver_modulo_1: true,
          puede_ver_modulo_2: true,
          puede_ver_modulo_3: true,
        }),
      ),
    });

    render(<AsignarJornadaPage />);

    await waitFor(() => expect(screen.getByText(/^jornadas$/i)).toBeInTheDocument());
  });
});
