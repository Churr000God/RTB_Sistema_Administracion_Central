import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { respuestaSesion } from "../testing/sesion";
import {
  ALARMA_FUERA_DE_LA_FUNCION,
  ALARMA_REVISAR,
  ALARMA_SIN_RESPALDO,
  ESTADO_APAGADO,
  ESTADO_ENCENDIDO,
  estadoApi,
} from "../testing/interruptorHuella";
import { ActivacionHuellaPage } from "./ActivacionHuellaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const RUTA = "/api/terminales/configuracion/activacion-por-huella";
const HISTORIAL = [
  { id: 1, creado_en: "2026-10-10T15:30:00Z", clave: "terminal_inferir_huella_activa", operacion: "UPDATE", valor_anterior: "0", valor_nuevo: "1", nota: "Alta supervisada de almacén.", autor_nombre: "Carlos Ruiz", via_funcion: true },
];

type Opciones = {
  estado?: Record<string, unknown> | Response;
  sesion?: Record<string, unknown>;
  historial?: Response;
  extra?: (path: string, init?: RequestInit) => Response | undefined;
};

function mockApi(opciones: Opciones = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    const extra = opciones.extra?.(path, init);
    if (extra) return Promise.resolve(extra);
    if (path === "/api/sesion") return Promise.resolve(respuestaSesion(opciones.sesion));
    if (path === RUTA) {
      const e = opciones.estado ?? ESTADO_ENCENDIDO;
      return Promise.resolve(e instanceof Response ? e : new Response(JSON.stringify(e)));
    }
    if (path.startsWith(`${RUTA}/historial`)) {
      return Promise.resolve(opciones.historial ?? new Response(JSON.stringify({ items: HISTORIAL })));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

const CONFIG = { puede_editar_config_terminales: true };
const SOLO_LECTURA = { puede_editar_config_terminales: false, puede_editar_terminales: false };
const LECTURA_CON_DETALLE = { puede_editar_config_terminales: false, puede_editar_terminales: true };

describe("ActivacionHuellaPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("encendido: insignia con fecha Y hora de México, quién, conteo e historial", async () => {
    mockApi({ sesion: CONFIG });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/encendido hasta el 24 oct 2026, 23:59 \(hora de méxico\)/i)).toBeInTheDocument();
    expect(screen.getByText(/carlos ruiz · /i)).toBeInTheDocument();
    expect(screen.getByText(/3 desde que se encendió/i)).toBeInTheDocument();
    expect(screen.getByText(/apagar y volver a encender reinicia el conteo; renovar no/i)).toBeInTheDocument();
    expect(await screen.findByText("Alta supervisada de almacén.")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Activación por huella" })).toHaveAttribute("aria-current", "page");
  });

  it("el conteo sólo se destaca sobre el umbral de la anomalía 11 y nunca como alarma", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ altas_activadas_desde_encendido: 12 }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/12 desde que se encendió/i)).toBeInTheDocument();
    expect(screen.getByText(/más de 5 en total: es normal en un alta supervisada/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "tablero" })).toHaveAttribute("href", "/tiempo/terminales/anomalias");
    expect(screen.queryByText(/^atender/i)).not.toBeInTheDocument();
  });

  it("conteo null: la fila no se muestra", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ altas_activadas_desde_encendido: null }) });
    render(<ActivacionHuellaPage />);
    await screen.findByText(/encendido hasta el/i);
    expect(screen.queryByText(/altas activadas por esta vía/i)).not.toBeInTheDocument();
  });

  it("apagado: Encender habilitado, explica el apagado y no hay conteo", async () => {
    mockApi({ sesion: CONFIG, estado: ESTADO_APAGADO });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText("Apagado")).toBeInTheDocument();
    expect(screen.getByText(/las altas nuevas se activan con «confirmar huella»/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /encender…/i })).toBeEnabled();
    expect(screen.queryByRole("button", { name: /renovar/i })).not.toBeInTheDocument();
    expect(screen.queryByText(/altas activadas por esta vía/i)).not.toBeInTheDocument();
  });

  it("apagado sin consentimiento definitivo: Encender deshabilitado con la explicación y el enlace", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ activo: false, estado: "apagado", motivo: "apagado", hasta: null, hasta_fecha: null, encendido_por_nombre: null, altas_activadas_desde_encendido: null, requisitos: { consentimiento_publicado: false, terminal_activa: true } }) });
    render(<ActivacionHuellaPage />);
    const encender = await screen.findByRole("button", { name: /encender…/i });
    expect(encender).toBeDisabled();
    expect(screen.getByText(/falta publicar el texto de consentimiento biométrico definitivo/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /ir a texto de consentimiento/i })).toHaveAttribute("href", "/tiempo/terminales/configuracion");
  });

  it("apagado sin terminal activa: Encender deshabilitado con la explicación", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ activo: false, estado: "apagado", motivo: "apagado", hasta: null, hasta_fecha: null, requisitos: { consentimiento_publicado: true, terminal_activa: false } }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByRole("button", { name: /encender…/i })).toBeDisabled();
    expect(screen.getByText(/no hay ninguna terminal activa/i)).toBeInTheDocument();
  });

  it("requisitos null: el botón queda habilitado (el dato es informativo, decide la base)", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ activo: false, estado: "apagado", motivo: "apagado", hasta: null, hasta_fecha: null, requisitos: null }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByRole("button", { name: /encender…/i })).toBeEnabled();
  });

  it("vencido: dice cuándo venció y ofrece Encender de nuevo", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ activo: false, estado: "vencido", vencido: true, motivo: "vencido", mensaje: "El vencimiento ya pasó; el interruptor está apagado.", hasta: "2026-10-06T05:59:59Z", hasta_fecha: "2026-10-05" }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/vencido · venció el 05 oct 2026, 23:59/i)).toBeInTheDocument();
    expect(screen.getByText(/ya no activa altas/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /encender de nuevo/i })).toBeInTheDocument();
  });

  it("alarma «atender» sin respaldo: banner rojo, Apagado por seguridad y sólo Encender", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ activo: false, estado: "inconsistente", motivo: "sin_respaldo_de_la_funcion", hasta: null, hasta_fecha: null, alarma: ALARMA_SIN_RESPALDO }) });
    render(<ActivacionHuellaPage />);
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(/atender/i);
    expect(alerta).toHaveTextContent(ALARMA_SIN_RESPALDO.mensaje);
    expect(screen.getByText("Apagado por seguridad")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /encender…/i })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /renovar/i })).not.toBeInTheDocument();
  });

  it("alarma «atender» con el interruptor encendido sin registro válido: Apagar es la acción principal y Renovar con registro", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ alarma: ALARMA_FUERA_DE_LA_FUNCION }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/recomendado: apágalo/i)).toBeInTheDocument();
    expect(screen.getByText(/sin registro válido/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^apagar…$/i })).toHaveClass("boton-peligro");
    expect(screen.getByRole("button", { name: /renovar con registro/i })).toBeInTheDocument();
  });

  it("alarma «revisar»: banner ámbar con el mensaje fijo del servidor", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ activo: false, estado: "inconsistente", motivo: "vigencias_inconsistentes", hasta: null, hasta_fecha: null, alarma: ALARMA_REVISAR }) });
    render(<ActivacionHuellaPage />);
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(/revisar/i);
    expect(alerta).toHaveTextContent(ALARMA_REVISAR.mensaje);
    expect(screen.getByText(/apagado · ajuste inconsistente/i)).toBeInTheDocument();
  });

  it("los textos del servidor se pintan como texto plano", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ encendido_por_nombre: "<img src=x onerror=alert(1)>", alarma: { ...ALARMA_FUERA_DE_LA_FUNCION, codigo: "codigo_nuevo", mensaje: "<b>aviso</b>" } }) });
    const { container } = render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/<img src=x onerror=alert\(1\)>/)).toBeInTheDocument();
    expect(screen.getByText(/<b>aviso<\/b>/)).toBeInTheDocument();
    expect(container.querySelector("img[src='x']")).toBeNull();
    expect(container.querySelector("b")).toBeNull();
  });

  describe("niveles de visibilidad", () => {
    it("terminal_usuario_edicion: ve nombre, nota e historial pero ningún botón", async () => {
      mockApi({ sesion: LECTURA_CON_DETALLE });
      render(<ActivacionHuellaPage />);
      expect(await screen.findByText(/puedes consultar este ajuste y su historial, no modificarlo/i)).toBeInTheDocument();
      expect(screen.getByText(/carlos ruiz · /i)).toBeInTheDocument();
      expect(await screen.findByText("Alta supervisada de almacén.")).toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /encender|renovar|apagar/i })).not.toBeInTheDocument();
    });

    it("sólo terminal_usuario_lectura: estado y alarma, sin nombre ni nota ni historial (ni lo pide)", async () => {
      mockApi({ sesion: SOLO_LECTURA, estado: estadoApi({ encendido_por_nombre: null }) });
      render(<ActivacionHuellaPage />);
      expect(await screen.findByText(/ves el estado del ajuste, no quién lo encendió ni el historial/i)).toBeInTheDocument();
      expect(screen.getByText(/encendido hasta el 24 oct 2026, 23:59/i)).toBeInTheDocument();
      expect(screen.queryByText(/encendido por/i)).not.toBeInTheDocument();
      expect(screen.getByText(/el historial no está disponible con tu permiso/i)).toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /encender|renovar|apagar/i })).not.toBeInTheDocument();
      expect(vi.mocked(apiFetch).mock.calls.some(([p]) => String(p).includes("/historial"))).toBe(false);
    });

    it("la alarma la ve también quien sólo tiene lectura", async () => {
      mockApi({ sesion: SOLO_LECTURA, estado: estadoApi({ alarma: ALARMA_FUERA_DE_LA_FUNCION }) });
      render(<ActivacionHuellaPage />);
      expect(await screen.findByRole("alert")).toHaveTextContent(ALARMA_FUERA_DE_LA_FUNCION.mensaje);
    });
  });

  describe("estados de carga y error", () => {
    it("cargando", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string) =>
        path === "/api/sesion" ? Promise.resolve(respuestaSesion(CONFIG)) : new Promise<Response>(() => {}),
      );
      render(<ActivacionHuellaPage />);
      expect(await screen.findByText(/cargando el estado/i)).toBeInTheDocument();
    });

    it("un 503 es pantalla de error con Reintentar, nunca «apagado»", async () => {
      let falla = true;
      mockApi({
        sesion: CONFIG,
        extra: (path) => (path === RUTA && falla ? new Response(JSON.stringify({ detail: "x" }), { status: 503 }) : undefined),
      });
      render(<ActivacionHuellaPage />);
      expect(await screen.findByText(/no se pudo cargar el estado de la activación por huella/i)).toBeInTheDocument();
      expect(screen.queryByText("Apagado")).not.toBeInTheDocument();
      falla = false;
      await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
      expect(await screen.findByText(/encendido hasta el/i)).toBeInTheDocument();
    });

    it("forma ilegible también es error (no se rellena con apagado)", async () => {
      mockApi({ sesion: CONFIG, estado: new Response(JSON.stringify({ activo: true })) });
      render(<ActivacionHuellaPage />);
      expect(await screen.findByText(/no se pudo cargar el estado/i)).toBeInTheDocument();
      expect(screen.queryByText("Apagado")).not.toBeInTheDocument();
    });

    it("403 del servidor o sin puede_ver_terminales: sin acceso", async () => {
      mockApi({ sesion: { puede_ver_terminales: false } });
      render(<ActivacionHuellaPage />);
      expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
      expect(vi.mocked(apiFetch).mock.calls.some(([p]) => p === RUTA)).toBe(false);
    });

    it("el historial puede fallar sin tumbar el estado", async () => {
      mockApi({ sesion: CONFIG, historial: new Response(null, { status: 500 }) });
      render(<ActivacionHuellaPage />);
      expect(await screen.findByText(/encendido hasta el/i)).toBeInTheDocument();
      expect(await screen.findByText(/no se pudo cargar el historial/i)).toBeInTheDocument();
    });
  });

  describe("acciones", () => {
    it("Encender: abre el modal, aplica el cambio, muestra el aviso y vuelve a pedir el historial", async () => {
      let historialPedido = 0;
      mockApi({
        sesion: CONFIG,
        estado: ESTADO_APAGADO,
        extra: (path, init) => {
          if (path.startsWith(`${RUTA}/historial`)) {
            historialPedido += 1;
            return new Response(JSON.stringify({ items: historialPedido > 1 ? HISTORIAL : [] }));
          }
          if (path === `${RUTA}/encender` && init?.method === "POST") {
            return new Response(JSON.stringify({ resultado: "actualizada", estado: ESTADO_ENCENDIDO }));
          }
          return undefined;
        },
      });
      render(<ActivacionHuellaPage />);
      await userEvent.click(await screen.findByRole("button", { name: /encender…/i }));
      await userEvent.type(screen.getByLabelText(/motivo/i), "Alta supervisada del turno de reparto.");
      await userEvent.click(screen.getByRole("button", { name: /encender la activación/i }));
      expect(await screen.findByText(/activación por huella encendida hasta el 24 oct 2026/i)).toBeInTheDocument();
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
      expect(await screen.findByText(/encendido hasta el 24 oct 2026, 23:59/i)).toBeInTheDocument();
      await waitFor(() => expect(historialPedido).toBe(2));
      expect(screen.getByRole("button", { name: /renovar…/i })).toBeInTheDocument();
    });

    it("Renovar con el estado cambiado: se cierra el modal y la pantalla se refresca con el estado devuelto", async () => {
      const actual = estadoApi({ hasta: "2026-10-29T05:59:59Z", hasta_fecha: "2026-10-28" });
      mockApi({
        sesion: CONFIG,
        extra: (path, init) =>
          path === `${RUTA}/renovar` && init?.method === "POST"
            ? new Response(JSON.stringify({ codigo: "estado_desactualizado", detail: "x", estado: actual }), { status: 409 })
            : undefined,
      });
      render(<ActivacionHuellaPage />);
      await userEvent.click(await screen.findByRole("button", { name: /renovar…/i }));
      await userEvent.type(screen.getByLabelText(/motivo/i), "Se extiende hasta el cierre del inventario.");
      await userEvent.click(screen.getByRole("button", { name: /renovar la activación/i }));
      expect(await screen.findByText(/no se renovó: el estado cambió mientras tenías la ventana abierta/i)).toBeInTheDocument();
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
      expect(screen.getByText(/encendido hasta el 28 oct 2026, 23:59/i)).toBeInTheDocument();
    });

    it("Apagar: pide confirmación, apaga y muestra el aviso", async () => {
      mockApi({
        sesion: CONFIG,
        extra: (path, init) =>
          path === `${RUTA}/apagar` && init?.method === "POST"
            ? new Response(JSON.stringify({ resultado: "actualizada", estado: ESTADO_APAGADO }))
            : undefined,
      });
      render(<ActivacionHuellaPage />);
      await userEvent.click(await screen.findByRole("button", { name: /^apagar…$/i }));
      const modal = screen.getByRole("dialog", { name: /apagar la activación por huella/i });
      await userEvent.click(within(modal).getByRole("button", { name: /apagar la activación/i }));
      expect(await screen.findByText(/activación por huella apagada\./i)).toBeInTheDocument();
      expect(screen.getByText("Apagado")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /encender…/i })).toBeInTheDocument();
    });

    it("Apagar cuando ya estaba apagado (sin_cambio): aviso de que no hubo cambios", async () => {
      mockApi({
        sesion: CONFIG,
        extra: (path, init) =>
          path === `${RUTA}/apagar` && init?.method === "POST"
            ? new Response(JSON.stringify({ resultado: "sin_cambio", estado: ESTADO_APAGADO }))
            : undefined,
      });
      render(<ActivacionHuellaPage />);
      await userEvent.click(await screen.findByRole("button", { name: /^apagar…$/i }));
      await userEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: /apagar la activación/i }));
      expect(await screen.findByText(/ya estaba apagado: no hubo cambios/i)).toBeInTheDocument();
    });
  });
});

describe("ActivacionHuellaPage · textos locales por código (security F3)", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("la alarma conocida se pinta con el texto local aunque el servidor mande otro", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ alarma: { ...ALARMA_FUERA_DE_LA_FUNCION, mensaje: "Texto del servidor distinto <b>x</b>" } }) });
    const { container } = render(<ActivacionHuellaPage />);
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(ALARMA_FUERA_DE_LA_FUNCION.mensaje);
    expect(alerta).not.toHaveTextContent(/distinto/);
    expect(container.querySelector("b")).toBeNull();
  });

  it("un código de alarma que la pantalla no conoce usa el mensaje del servidor como respaldo", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ alarma: { activa: true, nivel: "revisar", codigo: "codigo_nuevo", mensaje: "Mensaje de respaldo del servidor." } }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByRole("alert")).toHaveTextContent("Mensaje de respaldo del servidor.");
  });

  it("vencido: el texto del motivo es el local", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ activo: false, estado: "vencido", vencido: true, motivo: "vencido", mensaje: "otro texto", hasta: "2026-10-06T05:59:59Z", hasta_fecha: "2026-10-05" }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/el vencimiento ya pasó; el interruptor está apagado/i)).toBeInTheDocument();
    expect(screen.queryByText(/otro texto/)).not.toBeInTheDocument();
  });
});

describe("ActivacionHuellaPage · huecos de mutación", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  const APAGADO_EXTRA = { activo: false, estado: "apagado", motivo: "apagado", hasta: null, hasta_fecha: null, encendido_por_nombre: null, altas_activadas_desde_encendido: null };

  it("fail-closed: con una sesión incompleta (banderas ausentes) no hay botones ni se pide el historial", async () => {
    mockApi({ sesion: { puede_editar_config_terminales: undefined, puede_editar_terminales: undefined } });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/encendido hasta el/i)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /encender|renovar|apagar/i })).not.toBeInTheDocument();
    expect(screen.queryByText(/encendido por/i)).not.toBeInTheDocument();
    expect(vi.mocked(apiFetch).mock.calls.some(([p]) => String(p).includes("/historial"))).toBe(false);
  });

  it("puede_ver_terminales ausente no bloquea la lectura (la autoridad es el 403 del servidor) pero tampoco da botones", async () => {
    mockApi({ sesion: { puede_ver_terminales: undefined, puede_editar_config_terminales: undefined, puede_editar_terminales: undefined } });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/encendido hasta el/i)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /encender|renovar|apagar/i })).not.toBeInTheDocument();
  });

  it("sin cargar la sesión (falla) no aparece el banner de permisos, aunque el estado ya cargó", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") return Promise.resolve(new Response(null, { status: 500 }));
      if (path === RUTA) return Promise.resolve(new Response(JSON.stringify(ESTADO_ENCENDIDO)));
      return Promise.resolve(new Response(JSON.stringify({ items: [] })));
    });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/encendido hasta el/i)).toBeInTheDocument();
    expect(screen.queryByText(/puedes consultar este ajuste|ves el estado del ajuste/i)).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /encender|renovar|apagar/i })).not.toBeInTheDocument();
  });

  it("GET 403 de la pantalla => sin acceso, no «error»", async () => {
    mockApi({ sesion: CONFIG, estado: new Response(JSON.stringify({ detail: "No tienes permiso para esta acción." }), { status: 403 }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
    expect(screen.queryByText(/no se pudo cargar el estado/i)).not.toBeInTheDocument();
  });

  it("con la activación encendida no existe el botón «Encender…»", async () => {
    mockApi({ sesion: CONFIG });
    render(<ActivacionHuellaPage />);
    await screen.findByRole("button", { name: /renovar…/i });
    expect(screen.queryByRole("button", { name: /encender/i })).not.toBeInTheDocument();
  });

  it("«Recomendado: apágalo» sólo aparece con el interruptor encendido y alarma atender (no con sin_respaldo apagado)", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ ...APAGADO_EXTRA, estado: "inconsistente", motivo: "sin_respaldo_de_la_funcion", alarma: ALARMA_SIN_RESPALDO }) });
    render(<ActivacionHuellaPage />);
    await screen.findByRole("alert");
    expect(screen.queryByText(/recomendado: apágalo/i)).not.toBeInTheDocument();
  });

  it("alarma con activa=false no pinta banner aunque traiga nivel y mensaje", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ alarma: { activa: false, nivel: "atender", codigo: "sin_registro", mensaje: "Mensaje que no debe verse." } }) });
    render(<ActivacionHuellaPage />);
    await screen.findByText(/encendido hasta el/i);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.queryByText(/mensaje que no debe verse/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/sin registro válido/i)).not.toBeInTheDocument();
  });

  it("nombre null con detalle => «Sin registro»", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ encendido_por_nombre: null, encendido_en: null }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText("Sin registro")).toBeInTheDocument();
  });

  it.each([
    ["vencido", estadoApi({ ...APAGADO_EXTRA, estado: "vencido", vencido: true, motivo: "vencido", hasta: "2026-10-06T05:59:59Z", hasta_fecha: "2026-10-05" })],
    ["inconsistente", estadoApi({ ...APAGADO_EXTRA, estado: "inconsistente", motivo: "vigencias_inconsistentes", alarma: ALARMA_REVISAR })],
  ])("%s no muestra el texto del apagado normal ni «Encendido por»", async (_nombre, estado) => {
    mockApi({ sesion: CONFIG, estado });
    render(<ActivacionHuellaPage />);
    await screen.findByRole("button", { name: /encender/i });
    expect(screen.queryByText(/las altas nuevas se activan con «confirmar huella»/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/encendido por/i)).not.toBeInTheDocument();
  });

  it("umbral de la anomalía 11: exactamente 5 NO sugiere revisar el tablero; 6 sí", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ altas_activadas_desde_encendido: 5 }) });
    const { unmount } = render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/5 desde que se encendió/i)).toBeInTheDocument();
    expect(screen.queryByText(/más de 5 en total/i)).not.toBeInTheDocument();
    unmount();
    mockApi({ sesion: CONFIG, estado: estadoApi({ altas_activadas_desde_encendido: 6 }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/6 desde que se encendió/i)).toBeInTheDocument();
    expect(screen.getByText(/más de 5 en total/i)).toBeInTheDocument();
  });

  it("conteo 0 es un número válido y se muestra", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ altas_activadas_desde_encendido: 0 }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/0 desde que se encendió/i)).toBeInTheDocument();
  });

  it("precedencia cuando faltan ambos requisitos: explica primero el consentimiento", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ ...APAGADO_EXTRA, requisitos: { consentimiento_publicado: false, terminal_activa: false } }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/falta publicar el texto de consentimiento biométrico definitivo/i)).toBeInTheDocument();
    expect(screen.queryByText(/no hay ninguna terminal activa/i)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /encender…/i })).toBeDisabled();
  });

  it("Encender habilitado con ambos requisitos cumplidos y sin mensaje de requisito", async () => {
    mockApi({ sesion: CONFIG, estado: estadoApi({ ...APAGADO_EXTRA }) });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByRole("button", { name: /encender…/i })).toBeEnabled();
    expect(screen.queryByText(/no se puede encender todavía/i)).not.toBeInTheDocument();
  });

  it("no_esta_encendido al renovar: «Actualizar estado» vuelve a pedir el estado y cierra el modal", async () => {
    let pedidos = 0;
    mockApi({
      sesion: CONFIG,
      extra: (path, init) => {
        if (path === RUTA) pedidos += 1;
        return path === `${RUTA}/renovar` && init?.method === "POST"
          ? new Response(JSON.stringify({ codigo: "no_esta_encendido", detail: "x" }), { status: 409 })
          : undefined;
      },
    });
    render(<ActivacionHuellaPage />);
    await userEvent.click(await screen.findByRole("button", { name: /renovar…/i }));
    await userEvent.type(screen.getByLabelText(/motivo/i), "Se extiende hasta el cierre del inventario.");
    await userEvent.click(screen.getByRole("button", { name: /renovar la activación/i }));
    await screen.findByText(/ya no está encendido/i);
    expect(pedidos).toBe(1);
    await userEvent.click(screen.getByRole("button", { name: /actualizar estado/i }));
    await waitFor(() => expect(pedidos).toBe(2));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });
});

describe("ActivacionHuellaPage · la insignia respeta alarma.activa", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("inconsistente con alarma inactiva (aunque traiga nivel atender) no dice «Apagado por seguridad»", async () => {
    mockApi({
      sesion: CONFIG,
      estado: estadoApi({ activo: false, estado: "inconsistente", motivo: "vigencias_inconsistentes", hasta: null, hasta_fecha: null, alarma: { activa: false, nivel: "atender", codigo: null, mensaje: null } }),
    });
    render(<ActivacionHuellaPage />);
    expect(await screen.findByText(/apagado · ajuste inconsistente/i)).toBeInTheDocument();
    expect(screen.queryByText("Apagado por seguridad")).not.toBeInTheDocument();
  });
});
