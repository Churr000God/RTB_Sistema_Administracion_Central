import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { UsuariosTerminalPage } from "./UsuariosTerminalPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const TERMINAL = {
  id: 1,
  serie: "DS-K1T-0001",
  nombre: "Entrada principal",
  modelo: null,
  activa: true,
  estado_contacto: "en_linea",
  ultimo_contacto_en: "2026-10-08T15:00:00Z",
  segundos_sin_contacto: 40,
  terminal_alcanzable: true,
  reloj_desfase_seg: 2,
  version_pi: "1.4.0",
  marcas_pendientes: 0,
};

function alta(id: number, extra: Record<string, unknown> = {}) {
  return {
    id,
    terminal_id: 1,
    employee_no: 1000 + id,
    persona_id: `00000000-0000-4000-8000-${String(id).padStart(12, "0")}`,
    persona_nombre: `Persona ${id}`,
    estado: "activo",
    huellas_capturadas: 2,
    huella_evidencia: "conteo",
    creado_en: "2026-10-01T15:00:00Z",
    actualizado_en: "2026-10-01T15:00:00Z",
    usuario_creado_en: "2026-10-01T15:05:00Z",
    caduca_en: null,
    error_codigo: null,
    error_detalle: null,
    consentimiento: { id: 3, version: 3, provisional: false },
    consentimiento_vigente_id: 3,
    reconsentimiento_pendiente: false,
    es_propia: false,
    reconsentimiento_elegible: false,
    reconsentimiento_razon: null,
    accion_disponible: "dar_de_baja",
    ...extra,
  };
}

const RESUMEN = {
  por_estado: { pendiente_alta: 1, esperando_huella: 2, activo: 12, pendiente_baja: 1, baja: 1 },
  reconsentimiento_pendiente: 0,
};

function respuestaAltas(altas: unknown[], total = altas.length) {
  return new Response(JSON.stringify({ total, resumen: RESUMEN, altas }));
}

type Opciones = {
  altas?: () => Response;
  terminal?: Response;
  sesion?: Record<string, unknown> | Response;
  extra?: (path: string, init?: RequestInit) => Response | undefined;
};

function mockApi(opciones: Opciones = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    const extra = opciones.extra?.(path, init);
    if (extra) return Promise.resolve(extra);
    if (path === "/api/sesion") {
      const sesion = opciones.sesion;
      if (sesion instanceof Response) return Promise.resolve(sesion);
      return Promise.resolve(
        new Response(
          JSON.stringify({ acceso_permitido: true, puede_ver_terminales: true, puede_editar_terminales: true, ...sesion }),
        ),
      );
    }
    if (path === "/api/terminales/1") {
      return Promise.resolve(opciones.terminal ?? new Response(JSON.stringify(TERMINAL)));
    }
    if (path.startsWith("/api/terminales/1/usuarios?")) {
      return Promise.resolve(opciones.altas ? opciones.altas() : respuestaAltas([alta(1)]));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function llamadasAltas() {
  return vi
    .mocked(apiFetch)
    .mock.calls.map(([path]) => path as string)
    .filter((path) => path.startsWith("/api/terminales/1/usuarios?"));
}

function renderPagina() {
  return render(
    <MemoryRouter initialEntries={["/tiempo/terminales/1/usuarios"]}>
      <Routes>
        <Route path="/tiempo/terminales/:id/usuarios" element={<UsuariosTerminalPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

describe("UsuariosTerminalPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("muestra la terminal y pide las altas con límite 200", async () => {
    mockApi();
    renderPagina();
    expect(await screen.findByRole("heading", { name: /usuarios de la terminal/i })).toBeInTheDocument();
    expect(await screen.findByText(/Entrada principal · DS-K1T-0001/)).toBeInTheDocument();
    await screen.findByText("Persona 1");
    expect(new URLSearchParams(llamadasAltas()[0].split("?")[1]).get("limite")).toBe("200");
  });

  it("cada alta muestra persona, nº en la terminal, estado, huellas y fecha de asignación", async () => {
    mockApi();
    renderPagina();
    const fila = (await screen.findByText("Persona 1")).closest("tr")!;
    expect(within(fila).getByText("1001")).toBeInTheDocument();
    expect(within(fila).getByText("Activo")).toBeInTheDocument();
    expect(within(fila).getByText("2 huellas")).toBeInTheDocument();
    expect(within(fila).getByText(/01 oct 2026/i)).toBeInTheDocument();
  });

  it("esperando_huella: texto claro y cuenta regresiva que usa caduca_en del servidor", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-10-08T12:00:00Z"));
    mockApi({
      altas: () =>
        respuestaAltas([alta(2, { estado: "esperando_huella", huellas_capturadas: 0, caduca_en: "2026-10-09T07:40:00Z", accion_disponible: "cancelar_alta" })]),
    });
    renderPagina();
    const fila = (await screen.findByText("Persona 2")).closest("tr")!;
    expect(within(fila).getByText("Esperando huella")).toBeInTheDocument();
    expect(within(fila).getByText(/esperando que ti enrole la huella en la terminal/i)).toBeInTheDocument();
    expect(within(fila).getByText("Caduca en 19 h 40 min")).toBeInTheDocument();
    expect(within(fila).queryByText(/capturar/i)).not.toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000);
    });
    expect(within(fila).getByText("Caduca en 19 h 39 min")).toBeInTheDocument();
  });

  it("la última hora se marca urgente y avisa que se dará de baja sola", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-10-08T12:00:00Z"));
    mockApi({ altas: () => respuestaAltas([alta(3, { estado: "esperando_huella", caduca_en: "2026-10-08T12:58:00Z" })]) });
    renderPagina();
    const fila = (await screen.findByText("Persona 3")).closest("tr")!;
    expect(within(fila).getByText(/caduca en 58 min · se dará de baja sola/i).closest(".cuenta-regresiva")).toHaveClass(
      "cuenta-regresiva--urgente",
    );
  });

  it.each([
    ["pendiente_alta", "Pendiente de alta", /el puente aún no la crea en el aparato/i],
    ["pendiente_baja", "Pendiente de baja", /el puente borrará el usuario y sus huellas del aparato/i],
    ["baja", "Baja", /dato biométrico dado de baja/i],
  ])("estado %s: etiqueta y ayuda propias", async (estado, etiqueta, ayuda) => {
    mockApi({ altas: () => respuestaAltas([alta(4, { estado, accion_disponible: null })]) });
    renderPagina();
    const fila = (await screen.findByText("Persona 4")).closest("tr")!;
    expect(within(fila).getByText(etiqueta)).toBeInTheDocument();
    expect(within(fila).getByText(ayuda)).toBeInTheDocument();
  });

  it("muestra el último error del puente como texto plano (nunca HTML)", async () => {
    mockApi({
      altas: () =>
        respuestaAltas([alta(5, { estado: "pendiente_alta", error_codigo: "usuario_ya_existe", error_detalle: "<img src=x onerror=alert(1)>" })]),
    });
    const { container } = renderPagina();
    const fila = (await screen.findByText("Persona 5")).closest("tr")!;
    expect(within(fila).getByText(/usuario_ya_existe/)).toBeInTheDocument();
    expect(within(fila).getByText(/<img src=x onerror=alert\(1\)>/)).toBeInTheDocument();
    expect(container.querySelector("img[src='x']")).toBeNull();
  });

  it("las métricas salen del resumen del servidor, no de la página", async () => {
    mockApi({ altas: () => respuestaAltas([alta(1)], 17) });
    renderPagina();
    await screen.findByText("Persona 1");
    expect(within(screen.getByText("Activos").closest(".metrica") as HTMLElement).getByText("12")).toBeInTheDocument();
    expect(within(screen.getByText("Esperando huella", { selector: ".etiqueta-metrica" }).closest(".metrica") as HTMLElement).getByText("2")).toBeInTheDocument();
    expect(within(screen.getByText(/pendientes de alta \/ baja/i).closest(".metrica") as HTMLElement).getByText("1 / 1")).toBeInTheDocument();
  });

  it("filtrar por estado y por fecha vuelve a pedir al servidor con esos parámetros", async () => {
    mockApi();
    renderPagina();
    await screen.findByText("Persona 1");
    await userEvent.selectOptions(screen.getByLabelText(/filtrar por estado/i), "esperando_huella");
    await waitFor(() => {
      const ultima = llamadasAltas().at(-1)!;
      expect(new URLSearchParams(ultima.split("?")[1]).get("estado")).toBe("esperando_huella");
    });
    await userEvent.type(screen.getByLabelText(/asignada desde/i), "2026-10-01");
    await waitFor(() => {
      const ultima = llamadasAltas().at(-1)!;
      expect(new URLSearchParams(ultima.split("?")[1]).get("desde")).toBe("2026-10-01");
    });
  });

  it("buscar por persona filtra las altas cargadas (sin acentos ni mayúsculas)", async () => {
    mockApi({ altas: () => respuestaAltas([alta(1, { persona_nombre: "Ana Torres" }), alta(2, { persona_nombre: "Luis Ramírez" })]) });
    renderPagina();
    await screen.findByText("Ana Torres");
    await userEvent.type(screen.getByLabelText(/buscar por persona/i), "RAMIREZ");
    expect(screen.queryByText("Ana Torres")).not.toBeInTheDocument();
    expect(screen.getByText("Luis Ramírez")).toBeInTheDocument();
    await userEvent.clear(screen.getByLabelText(/buscar por persona/i));
    await userEvent.type(screen.getByLabelText(/buscar por persona/i), "zzz");
    expect(screen.getByText(/ninguna alta coincide/i)).toBeInTheDocument();
  });

  it("pagina de 20 en 20 sobre lo cargado", async () => {
    mockApi({ altas: () => respuestaAltas(Array.from({ length: 25 }, (_, i) => alta(i + 1))) });
    renderPagina();
    await screen.findByText("Persona 1");
    expect(screen.getByText(/mostrando 1–20 de 25/i)).toBeInTheDocument();
    expect(screen.queryByText("Persona 25")).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /siguiente/i }));
    expect(screen.getByText("Persona 25")).toBeInTheDocument();
    expect(screen.getByText(/mostrando 21–25 de 25/i)).toBeInTheDocument();
  });

  it("si el servidor tiene más de 200, avisa que se muestran las 200 más recientes", async () => {
    mockApi({ altas: () => respuestaAltas([alta(1)], 340) });
    renderPagina();
    expect(await screen.findByText(/mostrando las 200 más recientes de 340/i)).toBeInTheDocument();
  });

  it("sin altas: estado vacío; con error: Reintentar; 404: la terminal no existe", async () => {
    mockApi({ altas: () => respuestaAltas([]) });
    const a = renderPagina();
    expect(await screen.findByText(/todavía no tiene personas asignadas/i)).toBeInTheDocument();
    a.unmount();

    mockApi({ altas: () => new Response(null, { status: 500 }) });
    const b = renderPagina();
    expect(await screen.findByText(/no se pudo cargar los usuarios de la terminal/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
    b.unmount();

    mockApi({ terminal: new Response(JSON.stringify({ detail: "no" }), { status: 404 }), altas: () => new Response(null, { status: 404 }) });
    renderPagina();
    expect(await screen.findByText(/la terminal no existe/i)).toBeInTheDocument();
  });

  it("una respuesta de altas con forma inesperada se trata como error", async () => {
    mockApi({ altas: () => new Response(JSON.stringify({ total: 1 })) });
    renderPagina();
    expect(await screen.findByText(/no se pudo cargar los usuarios de la terminal/i)).toBeInTheDocument();
  });

  it("sin puede_ver_terminales (o 403) muestra sin acceso y no pide altas", async () => {
    mockApi({ sesion: { puede_ver_terminales: false } });
    const a = renderPagina();
    expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
    expect(llamadasAltas()).toHaveLength(0);
    a.unmount();

    mockApi({ altas: () => new Response(JSON.stringify({ detail: "No tienes permiso para esta acción." }), { status: 403 }) });
    renderPagina();
    expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
  });

  it("sin puede_editar_terminales explica que sólo se puede consultar", async () => {
    mockApi({ sesion: { puede_editar_terminales: false } });
    renderPagina();
    expect(await screen.findByText(/puedes consultar estas altas, no modificarlas/i)).toBeInTheDocument();
  });

  it("con permiso de edición no muestra ese aviso", async () => {
    mockApi();
    renderPagina();
    await screen.findByText("Persona 1");
    expect(screen.queryByText(/puedes consultar estas altas/i)).not.toBeInTheDocument();
  });

  describe("acciones (F3)", () => {
    const ANA = "11111111-1111-4111-8111-111111111111";
    const rutasModales = (path: string, init?: RequestInit): Response | undefined => {
      if (path === "/api/terminales/configuracion/consentimiento")
        return new Response(JSON.stringify({ vigente: { id: 3, version: 3, texto: "Texto v3", provisional: false, cambio_material: false, vigente_desde: "2026-10-02T00:00:00Z" }, historial: [] }));
      if (path.startsWith("/api/terminales/1/personas-asignables"))
        return new Response(JSON.stringify([{ persona_id: ANA, nombre: "Ana Torres", puesto: "Auxiliar", area: "Bodega" }]));
      if (path === "/api/terminales/1/usuarios" && init?.method === "POST") return new Response(JSON.stringify({ id: 99, employee_no: 1099 }), { status: 201 });
      if (path === "/api/terminales/1/usuarios/10/baja" && init?.method === "POST") return new Response(JSON.stringify({ id: 10 }), { status: 201 });
      if (path === "/api/terminales/1/usuarios/10/movimientos")
        return new Response(JSON.stringify([{ id: 1, tipo_movimiento: "asignado", creado_en: "2026-10-01T15:00:00Z", origen: "web", registrado_por_nombre: "Carlos Ruiz", detalle: null, huellas_capturadas: null, consentimiento: { id: 3, version: 3 } }]));
      return undefined;
    };

    it("con permiso de edición ofrece Asignar persona y, tras asignar, recarga las altas", async () => {
      mockApi({ extra: rutasModales });
      renderPagina();
      await screen.findByText("Persona 1");
      const antes = llamadasAltas().length;
      await userEvent.click(screen.getByRole("button", { name: /asignar persona/i }));
      expect(await screen.findByRole("dialog", { name: /asignar persona a la terminal/i })).toBeInTheDocument();
      await userEvent.selectOptions(await screen.findByLabelText(/^persona/i), ANA);
      await userEvent.click(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i));
      await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
      await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));
      await waitFor(() => expect(llamadasAltas().length).toBeGreaterThan(antes));
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    });

    it("sin permiso de edición no hay Asignar persona ni acciones de baja", async () => {
      mockApi({ sesion: { puede_editar_terminales: false }, extra: rutasModales });
      renderPagina();
      await screen.findByText("Persona 1");
      expect(screen.queryByRole("button", { name: /asignar persona/i })).not.toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /dar de baja|cancelar alta/i })).not.toBeInTheDocument();
    });

    it.each([
      ["dar_de_baja", "Dar de baja"],
      ["cancelar_alta", "Cancelar alta"],
    ])("accion_disponible %s muestra el botón «%s»; null no muestra ninguno", async (accion, etiqueta) => {
      mockApi({
        extra: rutasModales,
        altas: () => respuestaAltas([alta(10, { accion_disponible: accion, estado: accion === "dar_de_baja" ? "activo" : "esperando_huella", caduca_en: "2030-01-01T00:00:00Z" }), alta(11, { estado: "baja", accion_disponible: null })]),
      });
      renderPagina();
      const fila = (await screen.findByText("Persona 10")).closest("tr")!;
      expect(within(fila).getByRole("button", { name: etiqueta })).toBeInTheDocument();
      const sinAccion = screen.getByText("Persona 11").closest("tr")!;
      expect(within(sinAccion).queryByRole("button", { name: /dar de baja|cancelar alta/i })).not.toBeInTheDocument();
    });

    it("dar de baja abre el modal con motivo obligatorio y recarga al terminar", async () => {
      mockApi({ extra: rutasModales, altas: () => respuestaAltas([alta(10, { accion_disponible: "dar_de_baja" })]) });
      renderPagina();
      const fila = (await screen.findByText("Persona 10")).closest("tr")!;
      const antes = llamadasAltas().length;
      await userEvent.click(within(fila).getByRole("button", { name: "Dar de baja" }));
      await userEvent.type(screen.getByLabelText(/motivo/i), "La persona revocó su consentimiento.");
      await userEvent.click(screen.getByRole("button", { name: /dar de baja definitivamente/i }));
      await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));
      await waitFor(() => expect(llamadasAltas().length).toBeGreaterThan(antes));
    });

    it("Historial abre la bitácora del alta (también con sólo lectura)", async () => {
      mockApi({ sesion: { puede_editar_terminales: false }, extra: rutasModales, altas: () => respuestaAltas([alta(10)]) });
      renderPagina();
      const fila = (await screen.findByText("Persona 10")).closest("tr")!;
      await userEvent.click(within(fila).getByRole("button", { name: /historial/i }));
      const dialogo = await screen.findByRole("dialog", { name: /historial del alta/i });
      expect(await within(dialogo).findByText("Asignada")).toBeInTheDocument();
      expect(within(dialogo).getByText(/Consentimiento v3/)).toBeInTheDocument();
    });
  });

  describe("reconsentimiento (F6)", () => {
    const pendiente = (id: number, extra: Record<string, unknown> = {}) =>
      alta(id, { reconsentimiento_pendiente: true, reconsentimiento_elegible: true, consentimiento: { id: 2, version: 2, provisional: false }, consentimiento_vigente_id: 4, ...extra });
    const RESUMEN_PEND = { ...RESUMEN, reconsentimiento_pendiente: 14 };
    const respuesta = (altas: unknown[]) => new Response(JSON.stringify({ total: altas.length, resumen: RESUMEN_PEND, altas }));
    const rutas = (path: string, init?: RequestInit): Response | undefined => {
      if (path === "/api/terminales/configuracion/consentimiento")
        return new Response(JSON.stringify({ vigente: { id: 4, version: 4, texto: "Texto vigente v4", provisional: false, cambio_material: true, vigente_desde: "2026-10-08T12:00:00Z" }, historial: [] }));
      if (path === "/api/terminales/1/reconsentimientos-pendientes") return new Response(JSON.stringify({ total: 2, ids: [10, 11], hay_mas: false }));
      if (init?.method === "POST") return new Response(JSON.stringify({ registradas: 2, pendientes_restantes: 12, omitidas: [] }), { status: 201 });
      return undefined;
    };

    it("señala el reconsentimiento pendiente: métrica, aviso (sin bloquear marcas) e insignia por fila", async () => {
      mockApi({ extra: rutas, altas: () => respuesta([pendiente(10), alta(11)]) });
      renderPagina();
      const fila = (await screen.findByText("Persona 10")).closest("tr")!;
      expect(within(fila).getByText("Reconsentimiento pendiente")).toBeInTheDocument();
      expect(within(fila).getByText(/confirmó el texto v2/i)).toBeInTheDocument();
      expect(within(screen.getByText("Reconsentimiento pendiente", { selector: ".etiqueta-metrica" }).closest(".metrica") as HTMLElement).getByText("14")).toBeInTheDocument();
      expect(screen.getByText(/14 personas deben reconsentir/i)).toBeInTheDocument();
      expect(screen.getByText(/no se bloquea ninguna marca/i)).toBeInTheDocument();
      const otra = screen.getByText("Persona 11").closest("tr")!;
      expect(within(otra).queryByText("Reconsentimiento pendiente")).not.toBeInTheDocument();
    });

    it("sin pendientes no hay métrica ni aviso", async () => {
      mockApi({ extra: rutas });
      renderPagina();
      await screen.findByText("Persona 1");
      expect(screen.queryByText(/deben reconsentir/i)).not.toBeInTheDocument();
      expect(screen.queryByText("Reconsentimiento pendiente", { selector: ".etiqueta-metrica" })).not.toBeInTheDocument();
    });

    it("el filtro de reconsentimiento vuelve a pedir al servidor con pendiente / al_corriente", async () => {
      mockApi({ extra: rutas });
      renderPagina();
      await screen.findByText("Persona 1");
      await userEvent.selectOptions(screen.getByLabelText(/filtrar por reconsentimiento/i), "pendiente");
      await waitFor(() => expect(new URLSearchParams(llamadasAltas().at(-1)!.split("?")[1]).get("reconsentimiento")).toBe("pendiente"));
      await userEvent.selectOptions(screen.getByLabelText(/filtrar por reconsentimiento/i), "al_corriente");
      await waitFor(() => expect(new URLSearchParams(llamadasAltas().at(-1)!.split("?")[1]).get("reconsentimiento")).toBe("al_corriente"));
    });

    it("una alta no elegible (la propia) no se puede seleccionar y muestra la razón fija", async () => {
      mockApi({ extra: rutas, altas: () => respuesta([pendiente(10, { es_propia: true, reconsentimiento_elegible: false, reconsentimiento_razon: "es_propia" }), pendiente(11)]) });
      renderPagina();
      const propia = (await screen.findByText("Persona 10")).closest("tr")!;
      expect(within(propia).getByRole("checkbox")).toBeDisabled();
      expect(within(propia).getByText(/no puedes registrar tu propio reconsentimiento/i)).toBeInTheDocument();
      expect(within(propia).queryByRole("button", { name: /registrar reconsentimiento/i })).not.toBeInTheDocument();
      const elegible = screen.getByText("Persona 11").closest("tr")!;
      expect(within(elegible).getByRole("checkbox")).toBeEnabled();
    });

    it("Registrar reconsentimiento por fila abre el modal con esa alta y recarga al terminar", async () => {
      mockApi({ extra: rutas, altas: () => respuesta([pendiente(10)]) });
      renderPagina();
      const fila = (await screen.findByText("Persona 10")).closest("tr")!;
      const antes = llamadasAltas().length;
      await userEvent.click(within(fila).getByRole("button", { name: /registrar reconsentimiento/i }));
      const dialogo = await screen.findByRole("dialog", { name: /registrar reconsentimiento/i });
      expect(await within(dialogo).findByText("Texto vigente v4")).toBeInTheDocument();
      await userEvent.click(within(dialogo).getByLabelText(/confirmo que los documentos firmados existen/i));
      await userEvent.click(within(dialogo).getByRole("button", { name: /registrar reconsentimiento/i }));
      await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));
      await waitFor(() => expect(llamadasAltas().length).toBeGreaterThan(antes));
    });

    it("selección en lote: casillas, contador y botón; manda sólo las seleccionadas", async () => {
      mockApi({ extra: rutas, altas: () => respuesta([pendiente(10), pendiente(11), pendiente(12)]) });
      renderPagina();
      await screen.findByText("Persona 10");
      expect(screen.queryByRole("button", { name: /de las seleccionadas/i })).not.toBeInTheDocument();
      await userEvent.click(within(screen.getByText("Persona 10").closest("tr")!).getByRole("checkbox"));
      await userEvent.click(within(screen.getByText("Persona 12").closest("tr")!).getByRole("checkbox"));
      expect(screen.getByText("2 seleccionadas")).toBeInTheDocument();
      await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento de las seleccionadas/i }));
      const dialogo = await screen.findByRole("dialog", { name: /registrar reconsentimiento/i });
      await within(dialogo).findByText("Texto vigente v4");
      await userEvent.click(within(dialogo).getByLabelText(/confirmo que los documentos firmados existen/i));
      await userEvent.click(within(dialogo).getByRole("button", { name: /registrar reconsentimiento/i }));
      await screen.findByText(/reconsentimiento registrado/i);
      const post = vi.mocked(apiFetch).mock.calls.find(([, init]) => init?.method === "POST")!;
      expect(post[0]).toBe("/api/terminales/1/usuarios/reconsentimientos");
      expect(JSON.parse(post[1]!.body as string).tu_ids).toEqual([10, 12]);
    });

    it("«Seleccionar todas las elegibles» pide los ids de TODAS las pendientes (no sólo las de la página)", async () => {
      mockApi({ extra: rutas, altas: () => respuesta([pendiente(10)]) });
      renderPagina();
      await screen.findByText("Persona 10");
      await userEvent.click(screen.getByRole("button", { name: /seleccionar todas las elegibles/i }));
      expect(await screen.findByText("2 seleccionadas")).toBeInTheDocument();
      expect(vi.mocked(apiFetch)).toHaveBeenCalledWith("/api/terminales/1/reconsentimientos-pendientes", undefined);
    });

    it("el lote tiene tope de 200: si hay más pendientes lo dice", async () => {
      mockApi({
        extra: (path, init) => (path === "/api/terminales/1/reconsentimientos-pendientes" ? new Response(JSON.stringify({ total: 340, ids: Array.from({ length: 200 }, (_, i) => i + 1), hay_mas: true })) : rutas(path, init)),
        altas: () => respuesta([pendiente(10)]),
      });
      renderPagina();
      await screen.findByText("Persona 10");
      await userEvent.click(screen.getByRole("button", { name: /seleccionar todas las elegibles/i }));
      expect(await screen.findByText("200 seleccionadas")).toBeInTheDocument();
      expect(screen.getByText(/máximo 200 por vez; quedan 140 pendientes/i)).toBeInTheDocument();
    });

    it("sin permiso de edición ve la señal pero no hay casillas ni acciones de registro", async () => {
      mockApi({ sesion: { puede_editar_terminales: false }, extra: rutas, altas: () => respuesta([pendiente(10)]) });
      renderPagina();
      const fila = (await screen.findByText("Persona 10")).closest("tr")!;
      expect(within(fila).getByText("Reconsentimiento pendiente")).toBeInTheDocument();
      expect(within(fila).queryByRole("checkbox")).not.toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /registrar reconsentimiento/i })).not.toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /seleccionar todas las/i })).not.toBeInTheDocument();
    });

    it("si no se pueden pedir los ids pendientes, avisa sin romper la selección manual", async () => {
      mockApi({ extra: (path, init) => (path === "/api/terminales/1/reconsentimientos-pendientes" ? new Response(null, { status: 500 }) : rutas(path, init)), altas: () => respuesta([pendiente(10)]) });
      renderPagina();
      await screen.findByText("Persona 10");
      await userEvent.click(screen.getByRole("button", { name: /seleccionar todas las elegibles/i }));
      expect(await screen.findByText(/no se pudo obtener la lista de pendientes/i)).toBeInTheDocument();
    });
  });

  describe("selección (testing)", () => {
    const pendiente = (id: number) =>
      alta(id, { reconsentimiento_pendiente: true, reconsentimiento_elegible: true, consentimiento: { id: 2, version: 2, provisional: false }, consentimiento_vigente_id: 4 });
    const conPendientes = (altas: unknown[]) => new Response(JSON.stringify({ total: altas.length, resumen: { ...RESUMEN, reconsentimiento_pendiente: 3 }, altas }));
    const rutas = (path: string, init?: RequestInit): Response | undefined => {
      if (path === "/api/terminales/configuracion/consentimiento")
        return new Response(JSON.stringify({ vigente: { id: 4, version: 4, texto: "Texto v4", provisional: false, cambio_material: true, vigente_desde: "2026-10-08T12:00:00Z" }, historial: [] }));
      if (init?.method === "POST") return new Response(JSON.stringify({ registradas: 1, pendientes_restantes: 2 }), { status: 201 });
      return undefined;
    };

    it("marcar y desmarcar la misma casilla deja la selección vacía", async () => {
      mockApi({ extra: rutas, altas: () => conPendientes([pendiente(10), pendiente(11)]) });
      renderPagina();
      const casilla = within((await screen.findByText("Persona 10")).closest("tr")!).getByRole("checkbox");
      await userEvent.click(casilla);
      expect(screen.getByText("1 seleccionada")).toBeInTheDocument();
      await userEvent.click(casilla);
      expect(screen.queryByText(/seleccionadas?$/)).not.toBeInTheDocument();
      expect(casilla).not.toBeChecked();
    });

    it("cerrar el modal con refresco limpia la selección", async () => {
      mockApi({ extra: rutas, altas: () => conPendientes([pendiente(10), pendiente(11)]) });
      renderPagina();
      await screen.findByText("Persona 10");
      await userEvent.click(within(screen.getByText("Persona 10").closest("tr")!).getByRole("checkbox"));
      await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento de las seleccionadas/i }));
      const dialogo = await screen.findByRole("dialog", { name: /registrar reconsentimiento/i });
      await within(dialogo).findByText("Texto v4");
      await userEvent.click(within(dialogo).getByLabelText(/confirmo que los documentos firmados existen/i));
      await userEvent.click(within(dialogo).getByRole("button", { name: /registrar reconsentimiento/i }));
      await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));
      await waitFor(() => expect(screen.queryByText(/seleccionadas?$/)).not.toBeInTheDocument());
      expect(within(screen.getByText("Persona 10").closest("tr")!).getByRole("checkbox")).not.toBeChecked();
    });

    it("cancelar el modal (sin refresco) conserva la selección", async () => {
      mockApi({ extra: rutas, altas: () => conPendientes([pendiente(10)]) });
      renderPagina();
      await screen.findByText("Persona 10");
      await userEvent.click(within(screen.getByText("Persona 10").closest("tr")!).getByRole("checkbox"));
      await userEvent.click(screen.getByRole("button", { name: /registrar reconsentimiento de las seleccionadas/i }));
      const dialogo = await screen.findByRole("dialog", { name: /registrar reconsentimiento/i });
      await userEvent.click(within(dialogo).getByRole("button", { name: /cancelar/i }));
      expect(screen.getByText("1 seleccionada")).toBeInTheDocument();
    });
  });
});

describe("UsuariosTerminalPage · evidencia de huella y Confirmar huella", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it.each([
    ["inferida", /Huella verificada en el aparato/],
    ["manual", /Huella confirmada por una persona \(sin conteo\)/],
  ])("columna Huellas con evidencia %s: etiqueta, sin número", async (evidencia, etiqueta) => {
    mockApi({ altas: () => respuestaAltas([alta(1, { huella_evidencia: evidencia, huellas_capturadas: 0 })]) });
    renderPagina();
    const fila = (await screen.findByText("Persona 1")).closest("tr")!;
    expect(within(fila).getByText(etiqueta)).toBeInTheDocument();
    expect(within(fila).queryByText(/0 huellas/)).not.toBeInTheDocument();
  });

  it("regresión: activa con huellas_capturadas = 0 y sin evidencia muestra «—», nunca «0»", async () => {
    mockApi({ altas: () => respuestaAltas([alta(1, { huella_evidencia: null, huellas_capturadas: 0 })]) });
    renderPagina();
    const fila = (await screen.findByText("Persona 1")).closest("tr")!;
    const celdas = within(fila).getAllByRole("cell");
    expect(celdas.some((c) => c.textContent === "0")).toBe(false);
    expect(within(fila).queryByText(/huella/i, { selector: "td" })).not.toBeInTheDocument();
    expect(celdas.filter((c) => c.textContent === "—").length).toBeGreaterThanOrEqual(2);
  });

  it("esperando huella con edición: botón Confirmar huella que abre el modal; recarga al terminar", async () => {
    let llamadas = 0;
    mockApi({
      altas: () => {
        llamadas += 1;
        return respuestaAltas([
          llamadas === 1
            ? alta(2, { estado: "esperando_huella", huellas_capturadas: 0, huella_evidencia: null, accion_disponible: "cancelar_alta" })
            : alta(2, { estado: "activo", huellas_capturadas: 0, huella_evidencia: "manual" }),
        ]);
      },
      extra: (path, init) => (path === "/api/terminales/1/usuarios/2/huella-confirmada" && init?.method === "POST" ? new Response("{}", { status: 201 }) : undefined),
    });
    renderPagina();
    await userEvent.click(await screen.findByRole("button", { name: /confirmar huella/i }));
    await userEvent.type(screen.getByLabelText(/nota/i), "TI enroló el índice derecho en el aparato");
    await userEvent.click(screen.getByRole("button", { name: /confirmar que vi la huella/i }));
    await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));
    const fila = (await screen.findByText("Persona 2")).closest("tr")!;
    expect(await within(fila).findByText(/Huella confirmada por una persona \(sin conteo\)/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /confirmar huella/i })).not.toBeInTheDocument();
  });

  it("sin edición no hay Confirmar huella; fuera de Esperando huella tampoco", async () => {
    mockApi({
      sesion: { puede_editar_terminales: false },
      altas: () => respuestaAltas([alta(2, { estado: "esperando_huella", huellas_capturadas: 0, huella_evidencia: null })]),
    });
    renderPagina();
    await screen.findByText("Persona 2");
    expect(screen.queryByRole("button", { name: /confirmar huella/i })).not.toBeInTheDocument();
  });

  it("alta activa con edición: no ofrece Confirmar huella", async () => {
    mockApi();
    renderPagina();
    await screen.findByText("Persona 1");
    expect(screen.queryByRole("button", { name: /confirmar huella/i })).not.toBeInTheDocument();
  });
});
