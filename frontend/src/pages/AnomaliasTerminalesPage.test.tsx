import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { respuestaSesion } from "../testing/sesion";
import { AnomaliasTerminalesPage } from "./AnomaliasTerminalesPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const TERMINALES = [
  { id: 1, nombre: "Entrada principal", serie: "DS-1", activa: true },
  { id: 2, nombre: "Bodega", serie: "DS-2", activa: true },
];

const TITULOS: [string, number, string][] = [
  ["marcas_posteriores_a_baja", 1, "Marcas posteriores a la baja"],
  ["picos_de_tasa", 2, "Picos de tasa"],
  ["reloj_degradado", 3, "Reloj degradado"],
  ["huecos_de_secuencia", 4, "Huecos de secuencia"],
  ["rechazos_definitivos", 5, "Rechazos definitivos"],
  ["credenciales", 6, "Credenciales"],
  ["inconsistencias_de_baja", 7, "Inconsistencias de baja"],
  ["altas_atascadas", 8, "Altas atascadas"],
  ["altas_recientes", 9, "Altas recientes"],
  ["reconsentimientos_pendientes", 10, "Reconsentimientos pendientes"],
];

function tarjeta(clave: string, numero: number, titulo: string, extra: Record<string, unknown> = {}) {
  return { clave, numero, titulo, estado: "sin_hallazgos", nivel: null, total: 0, ejemplos: [], hay_mas: false, motivo: null, ...extra };
}

const LIMPIO = TITULOS.map(([c, n, t]) => tarjeta(c, n, t));

const CON_HALLAZGOS = TITULOS.map(([c, n, t]) => {
  switch (c) {
    case "marcas_posteriores_a_baja":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "atender", total: 12, hay_mas: true, ejemplos: [{ persona_nombre: "Julio Cano", marca_en: "2026-10-05T18:02:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" }] });
    case "picos_de_tasa":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "revisar", total: 1, ejemplos: [{ persona_nombre: "Marta Núñez", hora: "2026-10-06T14:00:00Z", marcas: 14, limite: 10 }] });
    case "reloj_degradado":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "revisar", total: 3, ejemplos: [{ conteo: 3, desfase_actual_seg: 95 }] });
    case "huecos_de_secuencia":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "revisar", total: 1, ejemplos: [{ desde: 5120, hasta: 5124, faltan: 3, fecha: "2026-10-06" }] });
    case "rechazos_definitivos":
      return tarjeta(c, n, t, { estado: "no_disponible", motivo: "falta_migracion", total: null });
    case "credenciales":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "revisar", total: 2, ejemplos: [{ tipo: "llave_antigua", antiguedad_meses: 13 }, { tipo: "traslape_abierto", dias_abierto: 9 }] });
    case "inconsistencias_de_baja":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "atender", total: 2, ejemplos: [{ persona_nombre: "Sofía Vega", estado_persona: "suspension", estado_alta: "activo" }, { persona_nombre: null, estado_persona: "inexistente", estado_alta: "activo" }] });
    case "altas_atascadas":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "revisar", total: 1, ejemplos: [{ persona_nombre: "Ana Torres", estado: "pendiente_alta", horas: 31 }] });
    case "altas_recientes":
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "informativo", total: 4, ejemplos: [{ persona_nombre: "Luis Ramírez", asignada_por: "María López", creado_en: "2026-10-08T15:00:00Z" }] });
    default:
      return tarjeta(c, n, t, { estado: "con_hallazgos", nivel: "revisar", total: 14, ejemplos: [{ persona_nombre: "Pedro Salas", version_confirmada: 2, version_vigente: 4, dias_pendiente: 3 }] });
  }
});

type Config = {
  sesion?: Record<string, unknown>;
  terminales?: () => Response;
  anomalias?: (terminal: string, params: URLSearchParams) => Response;
  detalle?: (terminal: string, clave: string, params: URLSearchParams) => Response;
};

function mockApi(config: Config = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") return Promise.resolve(respuestaSesion(config.sesion));
    if (path === "/api/terminales") return Promise.resolve(config.terminales?.() ?? new Response(JSON.stringify(TERMINALES)));
    const detalle = /^\/api\/terminales\/(\d+)\/anomalias\/([a-z_]+)(?:\?(.*))?$/.exec(path);
    if (detalle) {
      return Promise.resolve(
        config.detalle?.(detalle[1], detalle[2], new URLSearchParams(detalle[3])) ??
          new Response(JSON.stringify({ clave: detalle[2], total: 2, items: [{ persona_nombre: "Julio Cano", marca_en: "2026-10-05T18:02:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" }, { persona_nombre: "Otra Persona", marca_en: "2026-10-06T08:01:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" }] })),
      );
    }
    const lista = /^\/api\/terminales\/(\d+)\/anomalias(?:\?(.*))?$/.exec(path);
    if (lista) {
      return Promise.resolve(
        config.anomalias?.(lista[1], new URLSearchParams(lista[2])) ??
          new Response(JSON.stringify({ terminal_id: +lista[1], desde: "2026-10-01T06:00:00Z", hasta: "2026-10-08T20:00:00Z", generado_en: "2026-10-08T20:00:00Z", categorias: CON_HALLAZGOS })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

function pedidasAnomalias() {
  return vi
    .mocked(apiFetch)
    .mock.calls.map(([p]) => p as string)
    .filter((p) => /^\/api\/terminales\/\d+\/anomalias(\?|$)/.test(p));
}

function tarjetaDe(titulo: string) {
  return screen.getByRole("heading", { name: new RegExp(titulo, "i") }).closest(".anomalia") as HTMLElement;
}

describe("AnomaliasTerminalesPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
    window.history.replaceState(null, "", "/tiempo/terminales/anomalias");
  });

  it("pide las anomalías de la primera terminal y muestra las 10 tarjetas numeradas", async () => {
    mockApi();
    render(<AnomaliasTerminalesPage />);
    for (const [, n, t] of TITULOS) {
      expect(await screen.findByRole("heading", { name: new RegExp(`${n} · ${t}`, "i") })).toBeInTheDocument();
    }
    expect(pedidasAnomalias()[0]).toMatch(/^\/api\/terminales\/1\/anomalias/);
  });

  it("?terminal=2 elige esa terminal; cambiar el selector vuelve a pedir", async () => {
    window.history.replaceState(null, "", "/tiempo/terminales/anomalias?terminal=2");
    mockApi();
    render(<AnomaliasTerminalesPage />);
    await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
    expect(pedidasAnomalias()[0]).toMatch(/^\/api\/terminales\/2\/anomalias/);
    await userEvent.selectOptions(screen.getByLabelText("Terminal"), "1");
    await waitFor(() => expect(pedidasAnomalias().at(-1)).toMatch(/^\/api\/terminales\/1\/anomalias/));
  });

  it("el nivel va como texto + color: Atender / Revisar / Informativo", async () => {
    mockApi();
    render(<AnomaliasTerminalesPage />);
    await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
    expect(within(tarjetaDe("1 · marcas posteriores")).getByText("Atender")).toBeInTheDocument();
    expect(within(tarjetaDe("2 · picos")).getByText("Revisar")).toBeInTheDocument();
    expect(within(tarjetaDe("9 · altas recientes")).getByText("Informativo")).toBeInTheDocument();
    expect(within(tarjetaDe("1 · marcas posteriores")).getByText("12")).toBeInTheDocument();
  });

  it("cada categoría traduce sus ejemplos a texto legible", async () => {
    mockApi();
    render(<AnomaliasTerminalesPage />);
    await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
    expect(within(tarjetaDe("1 · marcas posteriores")).getByText(/Julio Cano/)).toBeInTheDocument();
    expect(within(tarjetaDe("2 · picos")).getByText(/14 marcas/)).toBeInTheDocument();
    expect(within(tarjetaDe("2 · picos")).getByText(/límite 10/i)).toBeInTheDocument();
    expect(within(tarjetaDe("3 · reloj")).getByText(/desfase actual: \+95 s/i)).toBeInTheDocument();
    expect(within(tarjetaDe("4 · huecos")).getByText(/faltan 3/i)).toBeInTheDocument();
    expect(within(tarjetaDe("6 · credenciales")).getByText(/13 meses de antigüedad/i)).toBeInTheDocument();
    expect(within(tarjetaDe("6 · credenciales")).getByText(/abierto hace 9 días/i)).toBeInTheDocument();
    expect(within(tarjetaDe("7 · inconsistencias")).getByText(/Sofía Vega/)).toBeInTheDocument();
    expect(within(tarjetaDe("7 · inconsistencias")).getByText(/la persona ya no existe/i)).toBeInTheDocument();
    expect(within(tarjetaDe("8 · altas atascadas")).getByText(/Ana Torres.*Pendiente de alta.*31 h/i)).toBeInTheDocument();
    expect(within(tarjetaDe("9 · altas recientes")).getByText(/asignó María López/i)).toBeInTheDocument();
    expect(within(tarjetaDe("10 · reconsentimientos")).getByText(/confirmó v2.*vigente v4.*3 días/i)).toBeInTheDocument();
  });

  it("los nombres y textos del servidor se pintan como texto plano", async () => {
    mockApi({
      anomalias: () =>
        new Response(JSON.stringify({ terminal_id: 1, desde: "2026-10-01T00:00:00Z", hasta: "2026-10-08T00:00:00Z", generado_en: "2026-10-08T00:00:00Z", categorias: [tarjeta("altas_recientes", 9, "Altas recientes", { estado: "con_hallazgos", nivel: "informativo", total: 1, ejemplos: [{ persona_nombre: "<img src=x onerror=alert(1)>", asignada_por: "<b>x</b>", creado_en: "2026-10-08T15:00:00Z" }] })] })),
    });
    const { container } = render(<AnomaliasTerminalesPage />);
    expect(await screen.findByText(/<img src=x onerror=alert\(1\)>/)).toBeInTheDocument();
    expect(container.querySelector("img[src='x']")).toBeNull();
    expect(container.querySelector("b")).toBeNull();
  });

  it("sin hallazgos: lo dice y cada tarjeta muestra «Sin hallazgos»", async () => {
    mockApi({ anomalias: () => new Response(JSON.stringify({ terminal_id: 1, desde: "2026-10-01T00:00:00Z", hasta: "2026-10-08T00:00:00Z", generado_en: "2026-10-08T00:00:00Z", categorias: LIMPIO })) });
    render(<AnomaliasTerminalesPage />);
    expect(await screen.findByText(/sin hallazgos en el periodo/i)).toBeInTheDocument();
    expect(within(tarjetaDe("1 · marcas posteriores")).getByText("Sin hallazgos")).toBeInTheDocument();
  });

  it("no_disponible por falta de migración y por falta de permiso se explican distinto", async () => {
    mockApi({
      anomalias: () =>
        new Response(JSON.stringify({ terminal_id: 1, desde: "2026-10-01T00:00:00Z", hasta: "2026-10-08T00:00:00Z", generado_en: "2026-10-08T00:00:00Z", categorias: [
          tarjeta("rechazos_definitivos", 5, "Rechazos definitivos", { estado: "no_disponible", motivo: "falta_migracion", total: null }),
          tarjeta("picos_de_tasa", 2, "Picos de tasa", { estado: "no_disponible", motivo: "sin_permiso", total: null }),
        ] })),
    });
    render(<AnomaliasTerminalesPage />);
    expect(await screen.findByText(/aún no está disponible en el servidor/i)).toBeInTheDocument();
    expect(screen.getByText(/requiere el permiso de lectura de marcas/i)).toBeInTheDocument();
  });

  it("una tarjeta con error no tira las demás", async () => {
    mockApi({
      anomalias: () =>
        new Response(JSON.stringify({ terminal_id: 1, desde: "2026-10-01T00:00:00Z", hasta: "2026-10-08T00:00:00Z", generado_en: "2026-10-08T00:00:00Z", categorias: [
          tarjeta("credenciales", 6, "Credenciales", { estado: "error", total: null }),
          tarjeta("altas_recientes", 9, "Altas recientes"),
        ] })),
    });
    render(<AnomaliasTerminalesPage />);
    expect(await screen.findByText(/no se pudo calcular esta revisión/i)).toBeInTheDocument();
    expect(within(tarjetaDe("9 · altas recientes")).getByText("Sin hallazgos")).toBeInTheDocument();
  });

  it("la tarjeta de reconsentimientos enlaza a Usuarios de la terminal", async () => {
    mockApi();
    render(<AnomaliasTerminalesPage />);
    await screen.findByRole("heading", { name: /10 · reconsentimientos/i });
    expect(within(tarjetaDe("10 · reconsentimientos")).getByRole("link", { name: /ver y registrar/i })).toHaveAttribute("href", "/tiempo/terminales/1/usuarios");
  });

  describe("periodo", () => {
    it("desde y hasta se mandan como fechas; hasta < desde no llama al servidor", async () => {
      mockApi();
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      fireEvent.change(screen.getByLabelText("Periodo desde"), { target: { value: "2026-09-30" } });
      await waitFor(() => expect(new URLSearchParams(pedidasAnomalias().at(-1)!.split("?")[1]).get("desde")).toBe("2026-09-30"));
      const antes = pedidasAnomalias().length;
      fireEvent.change(screen.getByLabelText("Periodo hasta"), { target: { value: "2026-09-01" } });
      expect(await screen.findByText(/la fecha final no puede ser anterior a la inicial/i)).toBeInTheDocument();
      expect(pedidasAnomalias()).toHaveLength(antes);
    });
  });

  describe("ver todos", () => {
    it("pide el detalle de la categoría con limite y desplazamiento y lo lista", async () => {
      mockApi();
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      await userEvent.click(within(tarjetaDe("1 · marcas posteriores")).getByRole("button", { name: /ver todos/i }));
      const dialogo = await screen.findByRole("dialog", { name: /marcas posteriores a la baja/i });
      expect(await within(dialogo).findByText(/Otra Persona/)).toBeInTheDocument();
      const llamada = vi.mocked(apiFetch).mock.calls.map(([p]) => p as string).find((p) => p.includes("/anomalias/marcas_posteriores_a_baja"))!;
      const params = new URLSearchParams(llamada.split("?")[1]);
      expect(params.get("limite")).toBe("50");
      expect(params.get("desplazamiento")).toBe("0");
    });

    it("«Cargar más» pide la siguiente página y agrega", async () => {
      const pagina = (d: string) =>
        new Response(JSON.stringify({ clave: "marcas_posteriores_a_baja", total: 3, items: d === "0" ? [{ persona_nombre: "Uno", marca_en: "2026-10-05T18:02:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" }, { persona_nombre: "Dos", marca_en: "2026-10-05T18:02:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" }] : [{ persona_nombre: "Tres", marca_en: "2026-10-05T18:02:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" }] }));
      mockApi({ detalle: (_t, _c, p) => pagina(p.get("desplazamiento") ?? "0") });
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      await userEvent.click(within(tarjetaDe("1 · marcas posteriores")).getByRole("button", { name: /ver todos/i }));
      const dialogo = await screen.findByRole("dialog");
      await within(dialogo).findByText(/Dos/);
      await userEvent.click(within(dialogo).getByRole("button", { name: /cargar más/i }));
      expect(await within(dialogo).findByText(/Tres/)).toBeInTheDocument();
      expect(within(dialogo).getByText(/Uno/)).toBeInTheDocument();
      expect(within(dialogo).queryByRole("button", { name: /cargar más/i })).not.toBeInTheDocument();
    });

    it("403 (sin marca_lectura) lo explica; 500 ofrece Reintentar", async () => {
      mockApi({ detalle: () => new Response(JSON.stringify({ detail: "No tienes permiso" }), { status: 403 }) });
      const a = render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      await userEvent.click(within(tarjetaDe("1 · marcas posteriores")).getByRole("button", { name: /ver todos/i }));
      expect(await screen.findByText(/requiere el permiso de lectura de marcas/i, { selector: "dialog *" })).toBeInTheDocument();
      a.unmount();
      let falla = true;
      mockApi({ detalle: () => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify({ clave: "marcas_posteriores_a_baja", total: 1, items: [{ persona_nombre: "Recuperada", marca_en: "2026-10-05T18:02:00Z", baja_confirmada_en: "2026-10-03T15:00:00Z" }] }))) });
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      await userEvent.click(within(tarjetaDe("1 · marcas posteriores")).getByRole("button", { name: /ver todos/i }));
      await screen.findByText(/no se pudo cargar el detalle/i);
      falla = false;
      await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
      expect(await screen.findByText(/Recuperada/)).toBeInTheDocument();
    });
  });

  describe("estados y permisos", () => {
    it("sin puede_ver_terminales o con 403: sin acceso", async () => {
      mockApi({ sesion: { puede_ver_terminales: false } });
      const a = render(<AnomaliasTerminalesPage />);
      expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
      a.unmount();
      mockApi({ terminales: () => new Response(JSON.stringify({ detail: "x" }), { status: 403 }) });
      render(<AnomaliasTerminalesPage />);
      expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
    });

    it("sin terminales: lo dice; error de carga con Reintentar; forma inesperada es error", async () => {
      mockApi({ terminales: () => new Response("[]") });
      const a = render(<AnomaliasTerminalesPage />);
      expect(await screen.findByText(/todavía no hay terminales/i)).toBeInTheDocument();
      a.unmount();
      let falla = true;
      mockApi({ anomalias: () => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify({ terminal_id: 1, desde: "2026-10-01T00:00:00Z", hasta: "2026-10-08T00:00:00Z", generado_en: "2026-10-08T00:00:00Z", categorias: LIMPIO }))) });
      const b = render(<AnomaliasTerminalesPage />);
      expect(await screen.findByText(/no se pudo calcular el tablero/i)).toBeInTheDocument();
      falla = false;
      await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
      expect(await screen.findByText(/sin hallazgos en el periodo/i)).toBeInTheDocument();
      b.unmount();
      mockApi({ anomalias: () => new Response(JSON.stringify({ categorias: "raro" })) });
      render(<AnomaliasTerminalesPage />);
      expect(await screen.findByText(/no se pudo calcular el tablero/i)).toBeInTheDocument();
    });

    it("muestra «Calculando anomalías…» mientras responde", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string) =>
        path === "/api/sesion" ? Promise.resolve(respuestaSesion()) : path === "/api/terminales" ? Promise.resolve(new Response(JSON.stringify(TERMINALES))) : new Promise<Response>(() => {}),
      );
      render(<AnomaliasTerminalesPage />);
      expect(await screen.findByText(/calculando anomalías/i)).toBeInTheDocument();
    });
  });

  describe("cobertura adicional (testing)", () => {
    const envolver = (categorias: unknown[]) =>
      new Response(JSON.stringify({ terminal_id: 1, desde: "2026-10-01T00:00:00Z", hasta: "2026-10-08T00:00:00Z", generado_en: "2026-10-08T00:00:00Z", categorias }));

    it("el banner de «sin hallazgos» NO sale si una de las 10 revisiones falló", async () => {
      const nueve = LIMPIO.slice(0, 9);
      mockApi({ anomalias: () => envolver([...nueve, tarjeta("reconsentimientos_pendientes", 10, "Reconsentimientos pendientes", { estado: "error", total: null })]) });
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /10 · reconsentimientos/i });
      expect(screen.queryByText(/sin hallazgos en el periodo/i)).not.toBeInTheDocument();
    });

    it("un tablero sin categorías tampoco declara «sin hallazgos»", async () => {
      mockApi({ anomalias: () => envolver([]) });
      render(<AnomaliasTerminalesPage />);
      await screen.findByText(/calculado a las/i);
      expect(screen.queryByText(/sin hallazgos en el periodo/i)).not.toBeInTheDocument();
    });

    it("no_disponible dice «No disponible» (no «Error»); error dice «Error» con rol de alerta (no «Sin hallazgos»)", async () => {
      mockApi({
        anomalias: () =>
          envolver([
            tarjeta("picos_de_tasa", 2, "Picos de tasa", { estado: "no_disponible", motivo: "sin_permiso", total: null }),
            tarjeta("credenciales", 6, "Credenciales", { estado: "error", total: null }),
          ]),
      });
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /2 · picos/i });
      const noDisp = tarjetaDe("2 · picos");
      expect(within(noDisp).getByText("No disponible")).toBeInTheDocument();
      expect(within(noDisp).queryByText("Error")).not.toBeInTheDocument();
      expect(within(noDisp).queryByRole("alert")).not.toBeInTheDocument();
      const conError = tarjetaDe("6 · credenciales");
      expect(within(conError).getByText("Error")).toBeInTheDocument();
      expect(within(conError).getByRole("alert")).toHaveTextContent(/no se pudo calcular esta revisión/i);
      expect(within(conError).queryByText("Sin hallazgos")).not.toBeInTheDocument();
    });

    it("hay_mas=false no ofrece «Ver todos»", async () => {
      mockApi();
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /2 · picos/i });
      expect(within(tarjetaDe("2 · picos")).queryByRole("button", { name: /ver todos/i })).not.toBeInTheDocument();
      expect(within(tarjetaDe("1 · marcas posteriores")).getByRole("button", { name: /ver todos/i })).toBeInTheDocument();
    });

    it("un detalle sin lista de items es un error, no una pantalla vacía", async () => {
      mockApi({ detalle: () => new Response(JSON.stringify({ clave: "marcas_posteriores_a_baja", total: 3 })) });
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      await userEvent.click(within(tarjetaDe("1 · marcas posteriores")).getByRole("button", { name: /ver todos/i }));
      expect(await screen.findByText(/no se pudo cargar el detalle/i)).toBeInTheDocument();
    });

    it("desde y hasta válidos viajan los dos al servidor y también al detalle", async () => {
      mockApi();
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      fireEvent.change(screen.getByLabelText("Periodo desde"), { target: { value: "2026-09-30" } });
      fireEvent.change(screen.getByLabelText("Periodo hasta"), { target: { value: "2026-10-05" } });
      await waitFor(() => {
        const params = new URLSearchParams(pedidasAnomalias().at(-1)!.split("?")[1]);
        expect(params.get("desde")).toBe("2026-09-30");
        expect(params.get("hasta")).toBe("2026-10-05");
      });
      await userEvent.click(within(tarjetaDe("1 · marcas posteriores")).getByRole("button", { name: /ver todos/i }));
      await screen.findByRole("dialog");
      const detalle = vi.mocked(apiFetch).mock.calls.map(([p]) => p as string).filter((p) => p.includes("/anomalias/marcas_posteriores_a_baja")).at(-1)!;
      const p = new URLSearchParams(detalle.split("?")[1]);
      expect(p.get("desde")).toBe("2026-09-30");
      expect(p.get("hasta")).toBe("2026-10-05");
    });

    it("una fecha imposible no se manda al servidor", async () => {
      mockApi();
      render(<AnomaliasTerminalesPage />);
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      fireEvent.change(screen.getByLabelText("Periodo desde"), { target: { value: "2026-02-30" } });
      await screen.findByRole("heading", { name: /1 · marcas posteriores/i });
      for (const ruta of pedidasAnomalias()) {
        expect(new URLSearchParams(ruta.split("?")[1]).get("desde")).not.toBe("2026-02-30");
      }
    });
  });
});
