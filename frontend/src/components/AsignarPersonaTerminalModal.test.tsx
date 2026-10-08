import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AsignarPersonaTerminalModal } from "./AsignarPersonaTerminalModal";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

const TEXTO_V3 = "La persona recibió el aviso de privacidad y otorgó por escrito su consentimiento.";
const VIGENTE = (extra: Record<string, unknown> = {}) => ({
  id: 3,
  version: 3,
  texto: TEXTO_V3,
  provisional: false,
  cambio_material: false,
  vigente_desde: "2026-10-02T00:00:00Z",
  ...extra,
});
const ANAS = [
  { persona_id: "11111111-1111-4111-8111-111111111111", nombre: "Ana Torres", puesto: "Auxiliar de almacén", area: "Bodega" },
  { persona_id: "22222222-2222-4222-8222-222222222222", nombre: "Ana Torres", puesto: "Analista de nómina", area: "Administración" },
  { persona_id: "33333333-3333-4333-8333-333333333333", nombre: "Luis Ramírez", puesto: null, area: null },
];
const TERMINAL = { id: 1, nombre: "Entrada principal" };

type Config = {
  vigente?: Record<string, unknown>;
  consentimiento?: () => Response;
  asignables?: Response;
  post?: (init: RequestInit) => Response;
};

function mockApi(config: Config = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/terminales/configuracion/consentimiento") {
      return Promise.resolve(
        config.consentimiento?.() ?? new Response(JSON.stringify({ vigente: VIGENTE(config.vigente), historial: [] })),
      );
    }
    if (path.startsWith("/api/terminales/1/personas-asignables")) {
      return Promise.resolve(config.asignables ?? new Response(JSON.stringify(ANAS)));
    }
    if (path === "/api/terminales/1/usuarios" && init?.method === "POST") {
      return Promise.resolve(
        config.post?.(init) ?? new Response(JSON.stringify({ id: 77, employee_no: 1042, estado: "pendiente_alta" }), { status: 201 }),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function cuerpoPost(): Record<string, unknown> {
  const llamada = vi.mocked(apiFetch).mock.calls.filter(([, init]) => init?.method === "POST").at(-1)!;
  return JSON.parse(llamada[1]!.body as string);
}

async function elegirYConfirmar(persona = "11111111-1111-4111-8111-111111111111") {
  await userEvent.selectOptions(await screen.findByLabelText(/^persona/i), persona);
  await userEvent.click(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i));
}

describe("AsignarPersonaTerminalModal", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("muestra el texto vigente con su versión en la casilla de consentimiento", async () => {
    mockApi();
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    expect(await screen.findByText(TEXTO_V3)).toBeInTheDocument();
    expect(screen.getByText(/texto versión 3/i)).toBeInTheDocument();
    expect(screen.queryByText("Provisional")).not.toBeInTheDocument();
  });

  it("un texto provisional se marca como tal", async () => {
    mockApi({ vigente: { provisional: true, version: 1, id: 1 } });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    expect(await screen.findByText(/provisional/i, { selector: ".insignia" })).toBeInTheDocument();
  });

  it("el texto del consentimiento se pinta como texto plano, nunca como HTML", async () => {
    mockApi({ vigente: { texto: "<img src=x onerror=alert(1)> acepto" } });
    const { baseElement } = render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    expect(await screen.findByText(/<img src=x onerror=alert\(1\)> acepto/)).toBeInTheDocument();
    expect(baseElement.querySelector("img[src='x']")).toBeNull();
  });

  it("lista personas asignables con puesto y área para distinguir homónimos", async () => {
    mockApi();
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    const selector = await screen.findByLabelText(/^persona/i);
    await waitFor(() => expect(within(selector).getAllByRole("option").length).toBeGreaterThan(1));
    expect(within(selector).getByRole("option", { name: "Ana Torres — Auxiliar de almacén · Bodega" })).toBeInTheDocument();
    expect(within(selector).getByRole("option", { name: "Ana Torres — Analista de nómina · Administración" })).toBeInTheDocument();
    expect(within(selector).getByRole("option", { name: "Luis Ramírez" })).toBeInTheDocument();
  });

  it("buscar (2 o más caracteres) vuelve a pedir las personas asignables con ese texto", async () => {
    mockApi();
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await screen.findByLabelText(/^persona/i);
    await userEvent.type(screen.getByLabelText(/buscar persona/i), "ram");
    await waitFor(() => {
      const rutas = vi.mocked(apiFetch).mock.calls.map(([p]) => p as string).filter((p) => p.includes("personas-asignables"));
      expect(rutas.some((p) => new URLSearchParams(p.split("?")[1]).get("busqueda") === "ram")).toBe(true);
    });
  });

  it("no envía sin persona ni sin confirmar el consentimiento y marca el campo", async () => {
    mockApi();
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await screen.findByText(TEXTO_V3);
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(screen.getByText(/elige a la persona/i)).toBeInTheDocument();
    expect(screen.getByText(/confirma que el consentimiento está recabado para poder asignar/i)).toBeInTheDocument();
    expect(vi.mocked(apiFetch).mock.calls.some(([, init]) => init?.method === "POST")).toBe(false);
  });

  it("asigna con persona_id, consentimiento_id vigente y consentimiento_recabado=true", async () => {
    mockApi();
    const onCerrar = vi.fn();
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={onCerrar} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));

    expect(await screen.findByText(/persona asignada/i)).toBeInTheDocument();
    expect(cuerpoPost()).toEqual({
      persona_id: "11111111-1111-4111-8111-111111111111",
      consentimiento_id: 3,
      consentimiento_recabado: true,
    });
    expect(screen.getByText(/pendiente de alta/i)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /cerrar/i }));
    expect(onCerrar).toHaveBeenCalledWith(true);
  });

  it("mientras envía deshabilita todo y evita el doble envío", async () => {
    mockApi();
    let resolver!: (r: Response) => void;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (init?.method === "POST") return new Promise<Response>((r) => (resolver = r));
      if (path.includes("consentimiento")) return Promise.resolve(new Response(JSON.stringify({ vigente: VIGENTE(), historial: [] })));
      return Promise.resolve(new Response(JSON.stringify(ANAS)));
    });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(screen.getByRole("button", { name: /asignando/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /cancelar/i })).toBeDisabled();
    expect(screen.getByLabelText(/^persona/i)).toBeDisabled();
    resolver(new Response(JSON.stringify({ id: 1 }), { status: 201 }));
    await screen.findByText(/persona asignada/i);
  });

  it("409 de consentimiento desactualizado: toma el texto nuevo del cuerpo, desmarca y pide releer", async () => {
    const nuevo = VIGENTE({ id: 4, version: 4, texto: "Texto nuevo v4", cambio_material: true });
    mockApi({
      post: () =>
        new Response(JSON.stringify({ detail: "El texto de consentimiento cambió; vuelve a leerlo.", consentimiento_vigente: nuevo }), { status: 409 }),
    });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent("El texto de consentimiento cambió; vuelve a leerlo.");
    expect(screen.getByText("Texto nuevo v4")).toBeInTheDocument();
    expect(screen.getByText(/texto versión 4/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i)).not.toBeChecked();

    // Reintento: con el texto nuevo y confirmando de nuevo, manda consentimiento_id 4
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) =>
      Promise.resolve(init?.method === "POST" ? new Response(JSON.stringify({ id: 9 }), { status: 201 }) : new Response("[]")),
    );
    await userEvent.click(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i));
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    await screen.findByText(/persona asignada/i);
    expect(cuerpoPost()).toMatchObject({ consentimiento_id: 4 });
  });

  it("tras el 409 el consentimiento queda DESMARCADO y Asignar no envía hasta marcarlo de nuevo", async () => {
    const nuevo = VIGENTE({ id: 4, version: 4, texto: "Texto nuevo v4" });
    mockApi({
      post: () => new Response(JSON.stringify({ detail: "El texto de consentimiento cambió; vuelve a leerlo.", consentimiento_vigente: nuevo }), { status: 409 }),
    });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    await screen.findByText("Texto nuevo v4");
    const postsAntes = vi.mocked(apiFetch).mock.calls.filter(([, init]) => init?.method === "POST").length;

    expect(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i)).not.toBeChecked();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(vi.mocked(apiFetch).mock.calls.filter(([, init]) => init?.method === "POST")).toHaveLength(postsAntes);
    expect(screen.getByText(/confirma que el consentimiento está recabado para poder asignar/i)).toBeInTheDocument();
  });

  it("un consentimiento_vigente INCOMPLETO en el 409 no reemplaza el estado: vuelve a leer el texto", async () => {
    let lecturas = 0;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/terminales/configuracion/consentimiento") {
        lecturas++;
        return Promise.resolve(new Response(JSON.stringify({ vigente: VIGENTE(lecturas > 1 ? { id: 6, version: 6, texto: "Texto releído v6" } : {}), historial: [] })));
      }
      if (init?.method === "POST")
        return Promise.resolve(new Response(JSON.stringify({ detail: "El texto de consentimiento cambió; vuelve a leerlo.", consentimiento_vigente: { id: 9, version: 9 } }), { status: 409 }));
      return Promise.resolve(new Response(JSON.stringify(ANAS)));
    });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(await screen.findByText("Texto releído v6")).toBeInTheDocument();
    expect(screen.queryByText(/versión 9/i)).not.toBeInTheDocument();
    expect(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i)).not.toBeChecked();
  });

  it("el código estable consentimiento_desactualizado basta, aunque el detail no mencione el consentimiento", async () => {
    let lecturas = 0;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/terminales/configuracion/consentimiento") {
        lecturas++;
        return Promise.resolve(new Response(JSON.stringify({ vigente: VIGENTE(lecturas > 1 ? { texto: "Texto releído" } : {}), historial: [] })));
      }
      if (init?.method === "POST") return Promise.resolve(new Response(JSON.stringify({ detail: "Vuelve a leerlo.", codigo: "consentimiento_desactualizado" }), { status: 409 }));
      return Promise.resolve(new Response(JSON.stringify(ANAS)));
    });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(await screen.findByText("Texto releído")).toBeInTheDocument();
    expect(lecturas).toBe(2);
  });

  it("un código de otro conflicto no dispara la relectura aunque el detail hable del consentimiento", async () => {
    let lecturas = 0;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/terminales/configuracion/consentimiento") {
        lecturas++;
        return Promise.resolve(new Response(JSON.stringify({ vigente: VIGENTE(), historial: [] })));
      }
      if (init?.method === "POST") return Promise.resolve(new Response(JSON.stringify({ detail: "Ese consentimiento ya tiene un alta.", codigo: "alta_duplicada" }), { status: 409 }));
      return Promise.resolve(new Response(JSON.stringify(ANAS)));
    });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/ya tiene un alta/i);
    expect(lecturas).toBe(1);
    expect(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i)).toBeChecked();
  });

  it("409 sin consentimiento_vigente en el cuerpo: vuelve a pedir el texto vigente", async () => {
    let llamadasTexto = 0;
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/terminales/configuracion/consentimiento") {
        llamadasTexto++;
        return Promise.resolve(new Response(JSON.stringify({ vigente: VIGENTE(llamadasTexto > 1 ? { id: 5, version: 5, texto: "Texto v5" } : {}), historial: [] })));
      }
      if (init?.method === "POST") return Promise.resolve(new Response(JSON.stringify({ detail: "El texto de consentimiento cambió; vuelve a leerlo." }), { status: 409 }));
      return Promise.resolve(new Response(JSON.stringify(ANAS)));
    });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(await screen.findByText("Texto v5")).toBeInTheDocument();
    expect(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i)).not.toBeChecked();
    const posts = () => vi.mocked(apiFetch).mock.calls.filter(([, init]) => init?.method === "POST").length;
    const antes = posts();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(posts()).toBe(antes);
  });

  it.each([
    [409, "La persona ya tiene un alta vigente en esta terminal."],
    [422, "La persona no está sincronizada en el esquema de tiempo; avisa a Sistemas."],
    [403, "No tienes permiso para esta acción."],
  ])("error %i: muestra el detail fijo del backend dentro del modal y conserva lo elegido", async (status, detail) => {
    mockApi({ post: () => new Response(JSON.stringify({ detail }), { status }) });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(detail);
    expect(screen.getByLabelText(/^persona/i)).toHaveValue("11111111-1111-4111-8111-111111111111");
    expect(screen.getByRole("button", { name: /^asignar$/i })).toBeEnabled();
  });

  it.each([
    [503, /servicio no disponible; reintenta/i],
    [500, /no se pudo asignar\. inténtalo de nuevo/i],
  ])("%i con cuerpo ilegible usa el mensaje de respaldo, nunca texto interno", async (status, esperado) => {
    mockApi({ post: () => new Response("<html>stack trace SELECT *</html>", { status }) });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent(esperado);
    expect(alerta).not.toHaveTextContent(/SELECT/);
  });

  it("un 500 con detail interno tampoco se muestra (sólo 403/409/422 traen mensajes fijos)", async () => {
    mockApi({ post: () => new Response(JSON.stringify({ detail: "psycopg2 tabla tiempo.terminal_usuario" }), { status: 500 }) });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    await elegirYConfirmar();
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    expect(await screen.findByRole("alert")).not.toHaveTextContent(/psycopg2/);
  });

  it("si es la propia persona del llamador avisa que sólo el administrador puede (decide el backend)", async () => {
    mockApi();
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} personaDelCaller={ANAS[0].persona_id} onCerrar={vi.fn()} />);
    await userEvent.selectOptions(await screen.findByLabelText(/^persona/i), ANAS[0].persona_id);
    expect(screen.getByText(/te estás asignando a ti/i)).toBeInTheDocument();
  });

  it("no se pudo cargar el texto: error con Reintentar y Asignar inerte", async () => {
    let falla = true;
    mockApi({ consentimiento: () => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify({ vigente: VIGENTE(), historial: [] }))) });
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
    expect(await screen.findByText(/no se pudo cargar el texto de consentimiento/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^asignar$/i })).toBeDisabled();
    falla = false;
    await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
    expect(await screen.findByText(TEXTO_V3)).toBeInTheDocument();
  });

  it("con persona fija (desde la ficha) no pide asignables y deja elegir la terminal", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
      if (path === "/api/terminales/configuracion/consentimiento") return Promise.resolve(new Response(JSON.stringify({ vigente: VIGENTE(), historial: [] })));
      if (path === "/api/terminales/2/usuarios" && init?.method === "POST") return Promise.resolve(new Response(JSON.stringify({ id: 1 }), { status: 201 }));
      return Promise.reject(new Error(`ruta no mockeada: ${path}`));
    });
    render(
      <AsignarPersonaTerminalModal
        terminales={[{ id: 1, nombre: "Entrada principal" }, { id: 2, nombre: "Bodega" }]}
        personaFija={{ persona_id: ANAS[0].persona_id, nombre: "Ana Torres", puesto: "Auxiliar de almacén", area: "Bodega" }}
        onCerrar={vi.fn()}
      />,
    );
    expect(await screen.findByText("Ana Torres — Auxiliar de almacén · Bodega")).toBeInTheDocument();
    expect(vi.mocked(apiFetch).mock.calls.some(([p]) => String(p).includes("personas-asignables"))).toBe(false);
    await userEvent.selectOptions(screen.getByLabelText("Terminal"), "2");
    await userEvent.click(await screen.findByLabelText(/consentimiento y aviso de privacidad recabados/i));
    await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
    await screen.findByText(/persona asignada/i);
    expect(vi.mocked(apiFetch).mock.calls.some(([p, init]) => p === "/api/terminales/2/usuarios" && init?.method === "POST")).toBe(true);
  });

  it("Cancelar y Escape cierran sin refrescar", async () => {
    mockApi();
    const onCerrar = vi.fn();
    render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={onCerrar} />);
    await screen.findByText(TEXTO_V3);
    fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
    expect(onCerrar).toHaveBeenCalledWith(false);
  });

  describe("cobertura adicional (testing)", () => {
    it("sin persona elegida (con la confirmación marcada) no envía y pide elegirla", async () => {
      mockApi();
      render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
      await screen.findByText(TEXTO_V3);
      await userEvent.click(screen.getByLabelText(/consentimiento y aviso de privacidad recabados/i));
      await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
      expect(screen.getByText("Elige a la persona.")).toBeInTheDocument();
      expect(vi.mocked(apiFetch).mock.calls.some(([, init]) => init?.method === "POST")).toBe(false);
    });

    it("Escape tras el éxito cierra pidiendo refrescar la lista", async () => {
      mockApi();
      const onCerrar = vi.fn();
      render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={onCerrar} />);
      await elegirYConfirmar();
      await userEvent.click(screen.getByRole("button", { name: /^asignar$/i }));
      await screen.findByText(/persona asignada/i);
      fireEvent(screen.getByRole("dialog"), new Event("cancel", { cancelable: true }));
      expect(onCerrar).toHaveBeenCalledWith(true);
    });

    describe("búsqueda de personas asignables", () => {
      function rutasAsignables() {
        return vi.mocked(apiFetch).mock.calls.map(([p]) => String(p)).filter((p) => p.includes("personas-asignables"));
      }

      it("inicial: sin busqueda y con limite=50; 1 carácter no filtra; «  an  » busca «an»", async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        mockApi();
        const usuario = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
        render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
        await screen.findByLabelText(/^persona/i);
        const inicial = new URLSearchParams(rutasAsignables()[0].split("?")[1]);
        expect(inicial.has("busqueda")).toBe(false);
        expect(inicial.get("limite")).toBe("50");

        await usuario.type(screen.getByLabelText(/buscar persona/i), "a");
        await act(async () => {
          await vi.advanceTimersByTimeAsync(400);
        });
        expect(rutasAsignables().every((r) => !new URLSearchParams(r.split("?")[1]).has("busqueda"))).toBe(true);

        await usuario.clear(screen.getByLabelText(/buscar persona/i));
        await usuario.type(screen.getByLabelText(/buscar persona/i), "  an  ");
        await act(async () => {
          await vi.advanceTimersByTimeAsync(400);
        });
        await vi.waitFor(() => expect(new URLSearchParams(rutasAsignables().at(-1)!.split("?")[1]).get("busqueda")).toBe("an"));
        vi.useRealTimers();
      });

      it("escribir rápido produce UNA sola petición tras los 300 ms (debounce)", async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        mockApi();
        const usuario = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
        render(<AsignarPersonaTerminalModal terminal={TERMINAL} onCerrar={vi.fn()} />);
        await screen.findByLabelText(/^persona/i);
        const antes = rutasAsignables().length;
        await usuario.type(screen.getByLabelText(/buscar persona/i), "rami");
        await act(async () => {
          await vi.advanceTimersByTimeAsync(400);
        });
        const nuevas = rutasAsignables().slice(antes);
        expect(nuevas).toHaveLength(1);
        expect(new URLSearchParams(nuevas[0].split("?")[1]).get("busqueda")).toBe("rami");
        vi.useRealTimers();
      });
    });
  });
});
