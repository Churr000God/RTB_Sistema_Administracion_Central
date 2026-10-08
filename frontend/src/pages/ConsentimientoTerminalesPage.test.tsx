import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { respuestaSesion } from "../testing/sesion";
import { ConsentimientoTerminalesPage } from "./ConsentimientoTerminalesPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const TEXTO_V3 = "La persona recibió el aviso de privacidad y otorgó por escrito su consentimiento.";

function version(n: number, extra: Record<string, unknown> = {}) {
  return {
    id: n,
    version: n,
    texto: null,
    texto_sha256: "a".repeat(64),
    provisional: false,
    cambio_material: false,
    motivo_cambio: null,
    vigente_desde: `2026-10-0${n}T12:00:00Z`,
    vigente_hasta: null,
    publicado_por_nombre: "Carlos Ruiz",
    es_semilla: false,
    ...extra,
  };
}

const VIGENTE = { ...version(3), texto: TEXTO_V3 };
const HISTORIAL = [
  { ...version(3) },
  { ...version(2, { vigente_hasta: "2026-10-03T12:00:00Z", motivo_cambio: "Se agregó la revocación" }) },
  { ...version(1, { vigente_hasta: "2026-10-02T12:00:00Z", provisional: true, publicado_por_nombre: null, es_semilla: true, motivo_cambio: "Texto inicial" }) },
];

type Config = {
  sesion?: Record<string, unknown>;
  consentimiento?: () => Response;
  version?: (n: string) => Response;
  impacto?: (material: string) => Response;
  post?: (cuerpo: Record<string, unknown>) => Response;
};

const IMPACTO_NORMAL = { cambio_material_efectivo: false, forzado: false, altas_que_quedarian_pendientes: 0, en_proceso: 0, activas: 0, pendientes_actuales: 0 };
const IMPACTO_MATERIAL = { cambio_material_efectivo: true, forzado: false, altas_que_quedarian_pendientes: 14, en_proceso: 3, activas: 11, pendientes_actuales: 0 };
const IMPACTO_FORZADO = { ...IMPACTO_MATERIAL, forzado: true };

function mockApi(config: Config = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") return Promise.resolve(respuestaSesion({ puede_editar_config_terminales: true, ...config.sesion }));
    if (path === "/api/terminales/configuracion/consentimiento") {
      return Promise.resolve(config.consentimiento?.() ?? new Response(JSON.stringify({ vigente: VIGENTE, historial: HISTORIAL })));
    }
    if (path.startsWith("/api/terminales/configuracion/consentimiento/impacto")) {
      const material = new URLSearchParams(path.split("?")[1]).get("cambio_material") ?? "false";
      return Promise.resolve(
        config.impacto?.(material) ?? new Response(JSON.stringify(material === "true" ? IMPACTO_MATERIAL : IMPACTO_NORMAL)),
      );
    }
    const m = /^\/api\/terminales\/configuracion\/consentimiento\/(\d+)$/.exec(path);
    if (m) return Promise.resolve(config.version?.(m[1]) ?? new Response(JSON.stringify({ ...version(+m[1]), texto: `Texto de la versión ${m[1]}` })));
    if (path === "/api/terminales/configuracion/consentimiento" && init?.method === "POST") return Promise.reject(new Error("unreachable"));
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

// El POST comparte ruta con el GET: se distingue por método.
function mockApiConPost(config: Config = {}) {
  const base = vi.mocked(apiFetch);
  mockApi(config);
  const anterior = base.getMockImplementation()!;
  base.mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/terminales/configuracion/consentimiento" && init?.method === "POST") {
      const cuerpo = JSON.parse(init.body as string);
      return Promise.resolve(
        config.post?.(cuerpo) ?? new Response(JSON.stringify({ resultado: "publicada", id: 4, version: 4, cambio_material: false, cambio_material_forzado: false, pendientes: 0 }), { status: 201 }),
      );
    }
    return anterior(path, init);
  });
}

function posts() {
  return vi.mocked(apiFetch).mock.calls.filter(([, init]) => init?.method === "POST");
}

async function editar(texto = "Texto nuevo del consentimiento.") {
  const campo = await screen.findByLabelText(/texto de consentimiento \(texto plano/i);
  await userEvent.clear(campo);
  await userEvent.type(campo, texto);
  return campo;
}

async function abrirPanel() {
  await userEvent.click(screen.getByRole("button", { name: /revisar y publicar/i }));
  return screen.findByRole("alertdialog");
}

describe("ConsentimientoTerminalesPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("muestra la versión vigente (número, desde, quién) y el texto en el editor", async () => {
    mockApiConPost();
    render(<ConsentimientoTerminalesPage />);
    expect(await screen.findByRole("heading", { name: /configuración de terminales/i })).toBeInTheDocument();
    expect(await screen.findByDisplayValue(TEXTO_V3)).toBeInTheDocument();
    expect(screen.getByText("Versión 3")).toBeInTheDocument();
    expect(screen.getByText(/Carlos Ruiz/, { selector: ".version-vigente *" })).toBeInTheDocument();
  });

  it("la semilla se muestra «Sistema (texto provisional)» y avisa que el texto es provisional", async () => {
    mockApiConPost({
      consentimiento: () =>
        new Response(JSON.stringify({ vigente: { ...version(1, { provisional: true, publicado_por_nombre: null, es_semilla: true }), texto: TEXTO_V3 }, historial: [version(1, { provisional: true, publicado_por_nombre: null, es_semilla: true })] })),
    });
    render(<ConsentimientoTerminalesPage />);
    expect(await screen.findByText(/el texto vigente es provisional/i)).toBeInTheDocument();
    expect(screen.getAllByText(/Sistema \(texto provisional\)/).length).toBeGreaterThan(0);
  });

  it("el contador y la vista previa siguen lo que se escribe, con la versión siguiente como borrador", async () => {
    mockApiConPost();
    render(<ConsentimientoTerminalesPage />);
    await editar("Nuevo texto");
    expect(screen.getByText("11 / 4000")).toBeInTheDocument();
    const vista = screen.getByLabelText(/vista previa del modal de asignar/i);
    expect(within(vista).getByText("Nuevo texto")).toBeInTheDocument();
    expect(within(vista).getByText(/versión 4 \(borrador, sin publicar\)/i)).toBeInTheDocument();
  });

  it("Revisar y publicar está inerte sin cambios o con el texto vacío", async () => {
    mockApiConPost();
    render(<ConsentimientoTerminalesPage />);
    const campo = await screen.findByLabelText(/texto de consentimiento \(texto plano/i);
    expect(screen.getByRole("button", { name: /revisar y publicar/i })).toBeDisabled();
    await userEvent.clear(campo);
    expect(screen.getByRole("button", { name: /revisar y publicar/i })).toBeDisabled();
    await userEvent.type(campo, "Otro");
    expect(screen.getByRole("button", { name: /revisar y publicar/i })).toBeEnabled();
  });

  it("el texto del servidor y el que se escribe se pintan como texto plano, nunca HTML", async () => {
    mockApiConPost({ consentimiento: () => new Response(JSON.stringify({ vigente: { ...VIGENTE, texto: "<img src=x onerror=alert(1)>" }, historial: HISTORIAL })) });
    const { baseElement } = render(<ConsentimientoTerminalesPage />);
    await screen.findByDisplayValue("<img src=x onerror=alert(1)>");
    const vista = screen.getByLabelText(/vista previa del modal de asignar/i);
    expect(within(vista).getByText("<img src=x onerror=alert(1)>")).toBeInTheDocument();
    expect(baseElement.querySelector("img[src='x']")).toBeNull();
  });

  describe("publicar", () => {
    it("abre el panel, pide el impacto sin cambio material y exige confirmar antes de publicar", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      expect(within(panel).getByText(/publicar la versión 4/i)).toBeInTheDocument();
      expect(vi.mocked(apiFetch)).toHaveBeenCalledWith("/api/terminales/configuracion/consentimiento/impacto?cambio_material=false", undefined);
      const publicar = within(panel).getByRole("button", { name: /^publicar versión 4$/i });
      expect(publicar).toBeDisabled();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      expect(publicar).toBeEnabled();
    });

    it("marcar «Cambio material» vuelve a pedir el impacto y muestra cuántas altas quedarían pendientes", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/cambio material/i));
      expect(await within(panel).findByText(/14 altas quedarían con «reconsentimiento pendiente»/i)).toBeInTheDocument();
      expect(within(panel).getByText(/3 en proceso de alta/i)).toBeInTheDocument();
      expect(within(panel).getByText(/11 activas/i)).toBeInTheDocument();
      expect(within(panel).getByText(/no se bloquea ninguna marca/i)).toBeInTheDocument();
    });

    it("publica con texto, cambio_material, motivo y base_version; no manda provisional ni motivo vacío", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar("Texto final.");
      const panel = await abrirPanel();
      await userEvent.type(within(panel).getByLabelText(/motivo del cambio/i), "Se aclara la revocación");
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      expect(await screen.findByText(/versión 4 publicada/i)).toBeInTheDocument();
      expect(JSON.parse(posts()[0][1]!.body as string)).toEqual({
        texto: "Texto final.",
        cambio_material: false,
        motivo_cambio: "Se aclara la revocación",
        base_version: 3,
      });
    });

    it("sin motivo no envía la clave motivo_cambio (el backend prohíbe campos extra)", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      await screen.findByText(/versión 4 publicada/i);
      const cuerpo = JSON.parse(posts()[0][1]!.body as string);
      expect(cuerpo).not.toHaveProperty("motivo_cambio");
      expect(cuerpo).not.toHaveProperty("provisional");
    });

    it("el motivo de más de 200 caracteres no se envía y marca el campo", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      fireEvent.change(within(panel).getByLabelText(/motivo del cambio/i), { target: { value: "a".repeat(201) } });
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      expect(posts()).toHaveLength(0);
      expect(within(panel).getByText(/hasta 200 caracteres/i, { selector: ".mensaje-campo" })).toBeInTheDocument();
    });

    it("cuando la vigente es provisional el cambio material es obligatorio: marcado y bloqueado", async () => {
      mockApiConPost({
        consentimiento: () =>
          new Response(JSON.stringify({ vigente: { ...version(1, { provisional: true, publicado_por_nombre: null, es_semilla: true }), texto: TEXTO_V3 }, historial: [] })),
        impacto: () => new Response(JSON.stringify(IMPACTO_FORZADO)),
        post: () => new Response(JSON.stringify({ resultado: "publicada", id: 2, version: 2, cambio_material: true, cambio_material_forzado: true, pendientes: 14 }), { status: 201 }),
      });
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      expect(within(panel).getByText(/publicar la versión 2 — la primera definitiva/i)).toBeInTheDocument();
      const casilla = within(panel).getByLabelText(/cambio material/i);
      expect(casilla).toBeChecked();
      expect(casilla).toBeDisabled();
      expect(await within(panel).findByText(/14 altas quedarían/i)).toBeInTheDocument();
      expect(within(panel).getByText(/reemplaza al texto provisional/i)).toBeInTheDocument();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 2$/i }));
      await screen.findByText(/versión 2 publicada/i);
      expect(JSON.parse(posts()[0][1]!.body as string)).toMatchObject({ cambio_material: true, base_version: 1 });
    });

    it("si el servidor marca forzado aunque la pantalla creyera que no (versión vigente desactualizada), obedece al servidor", async () => {
      mockApiConPost({ impacto: () => new Response(JSON.stringify(IMPACTO_FORZADO)) });
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await waitFor(() => expect(within(panel).getByLabelText(/cambio material/i)).toBeChecked());
      expect(within(panel).getByLabelText(/cambio material/i)).toBeDisabled();
      expect(within(panel).getByText(/publicar la versión 4 — la primera definitiva/i)).toBeInTheDocument();
    });

    it("si el impacto no se puede calcular, avisa, ofrece reintentar y no deja publicar", async () => {
      let falla = true;
      mockApiConPost({ impacto: () => (falla ? new Response(null, { status: 403 }) : new Response(JSON.stringify(IMPACTO_NORMAL))) });
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      expect(await within(panel).findByText(/no se pudo calcular cuántas altas quedarían pendientes/i)).toBeInTheDocument();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      expect(within(panel).getByRole("button", { name: /^publicar versión 4$/i })).toBeDisabled();
      falla = false;
      await userEvent.click(within(panel).getByRole("button", { name: /reintentar/i }));
      await waitFor(() => expect(within(panel).getByRole("button", { name: /^publicar versión 4$/i })).toBeEnabled());
    });

    it("publicada como cambio material: avisa cuántas quedaron pendientes y enlaza a Usuarios", async () => {
      mockApiConPost({ post: () => new Response(JSON.stringify({ resultado: "publicada", id: 4, version: 4, cambio_material: true, cambio_material_forzado: false, pendientes: 14 }), { status: 201 }) });
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/cambio material/i));
      await within(panel).findByText(/14 altas quedarían/i);
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      const aviso = (await screen.findByText(/altas quedaron con/i)).closest(".banner-aviso")!;
      expect(aviso).toHaveTextContent(/14 altas quedaron con reconsentimiento pendiente/i);
      expect(within(aviso as HTMLElement).getByRole("link")).toHaveAttribute("href", "/tiempo/terminales");
    });

    it("tras publicar recarga la versión vigente y cierra el panel", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      const cargasAntes = vi.mocked(apiFetch).mock.calls.filter(([p, i]) => p === "/api/terminales/configuracion/consentimiento" && !i?.method).length;
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      await screen.findByText(/versión 4 publicada/i);
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      const cargasDespues = vi.mocked(apiFetch).mock.calls.filter(([p, i]) => p === "/api/terminales/configuracion/consentimiento" && !i?.method).length;
      expect(cargasDespues).toBeGreaterThan(cargasAntes);
    });

    it("sin_cambio (200): dice que el texto es igual al vigente y no hay versión nueva", async () => {
      mockApiConPost({ post: () => new Response(JSON.stringify({ resultado: "sin_cambio", version: 3 }), { status: 200 }) });
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      expect(await screen.findByText(/el texto es igual al vigente/i)).toBeInTheDocument();
    });

    it("mientras publica bloquea el panel y evita el doble envío", async () => {
      mockApiConPost();
      let resolver!: (r: Response) => void;
      const anterior = vi.mocked(apiFetch).getMockImplementation()!;
      vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) =>
        init?.method === "POST" ? new Promise<Response>((r) => (resolver = r)) : anterior(path, init),
      );
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      expect(within(panel).getByRole("button", { name: /publicando/i })).toBeDisabled();
      expect(within(panel).getByRole("button", { name: /volver al editor/i })).toBeDisabled();
      expect(posts()).toHaveLength(1);
      resolver(new Response(JSON.stringify({ resultado: "publicada", id: 4, version: 4, cambio_material: false, cambio_material_forzado: false, pendientes: 0 }), { status: 201 }));
      await screen.findByText(/versión 4 publicada/i);
    });

    it("409 (otra persona publicó): alerta, conserva lo escrito y Recargar toma la versión nueva sin perder el borrador", async () => {
      const nueva = { id: 4, version: 4, texto: "Texto que publicó otra persona", provisional: false, cambio_material: false, vigente_desde: "2026-10-08T12:00:00Z" };
      mockApiConPost({ post: () => new Response(JSON.stringify({ detail: "Otra persona publicó una versión nueva del texto; vuelve a leerlo antes de publicar.", consentimiento_vigente: nueva }), { status: 409 }) });
      render(<ConsentimientoTerminalesPage />);
      const campo = await editar("Mi borrador");
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      expect(await screen.findByRole("alert")).toHaveTextContent("Otra persona publicó una versión nueva del texto; vuelve a leerlo antes de publicar.");
      expect(campo).toHaveValue("Mi borrador");
      await userEvent.click(screen.getByRole("button", { name: /recargar versión vigente/i }));
      expect(await screen.findByText("Versión 4")).toBeInTheDocument();
      expect(screen.getByLabelText(/texto de consentimiento \(texto plano/i)).toHaveValue("Mi borrador");
      expect(screen.getByText(/versión 5 \(borrador, sin publicar\)/i)).toBeInTheDocument();
    });

    it("409 con consentimiento_vigente incompleto: no reemplaza el estado con un objeto a medias, vuelve a leer", async () => {
      let lecturas = 0;
      mockApiConPost({
        consentimiento: () => {
          lecturas++;
          return new Response(JSON.stringify({ vigente: lecturas > 1 ? { ...VIGENTE, version: 5, id: 5, texto: "Texto releído v5" } : VIGENTE, historial: HISTORIAL }));
        },
        post: () => new Response(JSON.stringify({ detail: "Otra persona publicó una versión nueva del texto; vuelve a leerlo antes de publicar.", codigo: "version_base_desactualizada", consentimiento_vigente: { id: 9 } }), { status: 409 }),
      });
      render(<ConsentimientoTerminalesPage />);
      await editar("Mi borrador");
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      await screen.findByRole("alert");
      await userEvent.click(screen.getByRole("button", { name: /recargar versión vigente/i }));
      expect(await screen.findByText("Versión 5")).toBeInTheDocument();
      expect(screen.getByLabelText(/texto de consentimiento \(texto plano/i)).toHaveValue("Mi borrador");
      expect(lecturas).toBe(2);
    });

    it.each([
      [403, "No tienes permiso para esta acción."],
      [422, "El texto debe tener entre 1 y 4 000 caracteres."],
    ])("error %i: muestra el detail fijo del backend", async (status, detail) => {
      mockApiConPost({ post: () => new Response(JSON.stringify({ detail }), { status }) });
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      expect(await screen.findByRole("alert")).toHaveTextContent(detail);
    });

    it("503 o un error interno usa el mensaje propio, nunca el texto del servidor", async () => {
      mockApiConPost({ post: () => new Response(JSON.stringify({ detail: "tabla tiempo.terminal_consentimiento" }), { status: 500 }) });
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      const alerta = await screen.findByRole("alert");
      expect(alerta).not.toHaveTextContent(/tiempo\.terminal_consentimiento/);
      expect(alerta).toHaveTextContent(/no se pudo publicar/i);
    });

    it("Descartar cambios restaura el texto vigente", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      const campo = await editar("otra cosa");
      await userEvent.click(screen.getByRole("button", { name: /descartar cambios/i }));
      expect(campo).toHaveValue(TEXTO_V3);
    });
  });

  describe("historial de versiones", () => {
    it("lista versiones con motivo, publicador, estado y marca de cambio material", async () => {
      mockApiConPost({
        consentimiento: () =>
          new Response(JSON.stringify({ vigente: VIGENTE, historial: [version(3, { cambio_material: true }), HISTORIAL[1], HISTORIAL[2]] })),
      });
      render(<ConsentimientoTerminalesPage />);
      const tabla = await screen.findByRole("table");
      const v3 = within(tabla).getByText("3").closest("tr")!;
      expect(within(v3).getByText("Vigente")).toBeInTheDocument();
      expect(within(v3).getByText("Cambio material")).toBeInTheDocument();
      expect(within(v3).getByText(/texto vigente \(arriba\)/i)).toBeInTheDocument();
      const v2 = within(tabla).getByText("2").closest("tr")!;
      expect(within(v2).getByText("Reemplazada")).toBeInTheDocument();
      expect(within(v2).getByText("Se agregó la revocación")).toBeInTheDocument();
      const v1 = within(tabla).getByText("1").closest("tr")!;
      expect(within(v1).getByText("Sistema (texto provisional)")).toBeInTheDocument();
      expect(within(v1).getByText("Provisional")).toBeInTheDocument();
    });

    it("Ver texto de una versión anterior hace una segunda petición y lo muestra como texto plano", async () => {
      mockApiConPost({ version: (n) => new Response(JSON.stringify({ ...version(+n), texto: "<b>Texto</b> v" + n })) });
      render(<ConsentimientoTerminalesPage />);
      const v2 = (await screen.findByText("2", { selector: "td" })).closest("tr")!;
      await userEvent.click(within(v2).getByRole("button", { name: /ver texto de la versión 2/i }));
      expect(await screen.findByText("<b>Texto</b> v2")).toBeInTheDocument();
      expect(vi.mocked(apiFetch)).toHaveBeenCalledWith("/api/terminales/configuracion/consentimiento/2", undefined);
      expect(within(v2).getByRole("button", { name: /ver texto de la versión 2/i })).toHaveAttribute("aria-expanded", "true");
      expect(document.querySelector("b")).toBeNull();
    });

    it("mientras carga muestra el estado, y si falla ofrece Reintentar", async () => {
      let falla = true;
      mockApiConPost({ version: (n) => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify({ ...version(+n), texto: "Texto de v" + n }))) });
      render(<ConsentimientoTerminalesPage />);
      const v2 = (await screen.findByText("2", { selector: "td" })).closest("tr")!;
      await userEvent.click(within(v2).getByRole("button", { name: /ver texto de la versión 2/i }));
      expect(await screen.findByText(/no se pudo cargar el texto de esta versión/i)).toBeInTheDocument();
      falla = false;
      await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
      expect(await screen.findByText("Texto de v2")).toBeInTheDocument();
    });

    it("404: mensaje fijo «La versión de consentimiento solicitada no existe.»", async () => {
      mockApiConPost({ version: () => new Response(JSON.stringify({ detail: "x" }), { status: 404 }) });
      render(<ConsentimientoTerminalesPage />);
      const v2 = (await screen.findByText("2", { selector: "td" })).closest("tr")!;
      await userEvent.click(within(v2).getByRole("button", { name: /ver texto de la versión 2/i }));
      expect(await screen.findByText("La versión de consentimiento solicitada no existe.")).toBeInTheDocument();
    });
  });

  describe("permisos y estados", () => {
    it("sin puede_editar_config_terminales (RH): sólo lectura, sin editor ni publicar, y nombra el permiso", async () => {
      mockApiConPost({ sesion: { puede_editar_config_terminales: false } });
      render(<ConsentimientoTerminalesPage />);
      expect(await screen.findByText(/puedes consultar el texto, no modificarlo/i)).toBeInTheDocument();
      expect(screen.getByText(/puedes consultar el texto, no modificarlo/i).closest(".banner-aviso")).toHaveTextContent(/terminal_config_edicion/);
      expect(screen.queryByLabelText(/texto de consentimiento \(texto plano/i)).not.toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /revisar y publicar/i })).not.toBeInTheDocument();
      expect(screen.getAllByText(TEXTO_V3).length).toBeGreaterThan(0);
    });

    it("sin puede_ver_terminales o con 403: estado sin acceso", async () => {
      mockApiConPost({ sesion: { puede_ver_terminales: false } });
      const a = render(<ConsentimientoTerminalesPage />);
      expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
      a.unmount();
      mockApiConPost({ consentimiento: () => new Response(JSON.stringify({ detail: "No tienes permiso para esta acción." }), { status: 403 }) });
      render(<ConsentimientoTerminalesPage />);
      expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
    });

    it("error de carga con Reintentar; forma inesperada también es error", async () => {
      let falla = true;
      mockApiConPost({ consentimiento: () => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify({ vigente: VIGENTE, historial: HISTORIAL }))) });
      render(<ConsentimientoTerminalesPage />);
      expect(await screen.findByText(/no se pudo cargar la configuración/i)).toBeInTheDocument();
      falla = false;
      await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
      expect(await screen.findByDisplayValue(TEXTO_V3)).toBeInTheDocument();
    });

    it("una respuesta con forma inesperada se trata como error", async () => {
      mockApiConPost({ consentimiento: () => new Response(JSON.stringify({ algo: 1 })) });
      render(<ConsentimientoTerminalesPage />);
      expect(await screen.findByText(/no se pudo cargar la configuración/i)).toBeInTheDocument();
    });

    it("muestra «Cargando…» mientras responde", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string) =>
        path === "/api/sesion" ? Promise.resolve(respuestaSesion()) : new Promise<Response>(() => {}),
      );
      render(<ConsentimientoTerminalesPage />);
      expect(await screen.findByText(/cargando el texto de consentimiento/i)).toBeInTheDocument();
    });

    it("las pestañas enlazan a Texto de consentimiento y a Variables", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await screen.findByDisplayValue(TEXTO_V3);
      expect(screen.getByRole("link", { name: /texto de consentimiento/i })).toHaveAttribute("aria-current", "page");
      expect(screen.getByRole("link", { name: /^variables$/i })).toHaveAttribute("href", "/tiempo/terminales/configuracion/variables");
    });
  });

  describe("cobertura adicional (testing)", () => {
    it("el motivo del cambio con espacios se envía recortado", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.type(within(panel).getByLabelText(/motivo del cambio/i), "   se aclara la revocación   ");
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      await screen.findByText(/versión 4 publicada/i);
      expect(JSON.parse(posts()[0][1]!.body as string).motivo_cambio).toBe("se aclara la revocación");
    });

    it("un motivo de sólo espacios se trata como vacío y no viaja", async () => {
      mockApiConPost();
      render(<ConsentimientoTerminalesPage />);
      await editar();
      const panel = await abrirPanel();
      await userEvent.type(within(panel).getByLabelText(/motivo del cambio/i), "     ");
      await userEvent.click(within(panel).getByLabelText(/confirmo que revisé la vista previa/i));
      await userEvent.click(within(panel).getByRole("button", { name: /^publicar versión 4$/i }));
      await screen.findByText(/versión 4 publicada/i);
      expect(JSON.parse(posts()[0][1]!.body as string)).not.toHaveProperty("motivo_cambio");
    });
  });
});
