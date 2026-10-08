import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { respuestaSesion } from "../testing/sesion";
import { VariablesTerminalesPage } from "./VariablesTerminalesPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

function variable(clave: string, etiqueta: string, valor: number, minimo: number, maximo: number, unidad: string, extra: Record<string, unknown> = {}) {
  return {
    clave,
    etiqueta,
    descripcion: `Descripción de ${etiqueta}`,
    unidad,
    minimo,
    maximo,
    valor_defecto: valor,
    valor,
    vigente_desde: "2026-09-20",
    modificado_por_nombre: "Carlos Ruiz",
    valor_ilegible: false,
    ...extra,
  };
}

const VARIABLES = [
  variable("terminal_caducidad_alta_horas", "Caducidad de altas sin huella", 24, 4, 168, "horas"),
  variable("terminal_llave_max_meses", "Antigüedad máxima de la llave del puente", 12, 3, 36, "meses"),
  variable("terminal_anomalias_ventana_dias", "Ventana de anomalías", 7, 1, 90, "días"),
  variable("terminal_retencion_rechazos_dias", "Retención de rechazos", 90, 30, 365, "días"),
  variable("terminal_traslape_llave_max_dias", "Traslape de llaves", 7, 1, 90, "días"),
];

const HISTORIAL = [
  { clave: "terminal_caducidad_alta_horas", valor: "24", vigente_desde: "2026-09-20", vigente_hasta: null, modificado_por_nombre: "Carlos Ruiz", estado: "vigente", valor_ilegible: false },
  { clave: "terminal_retencion_rechazos_dias", valor: "basura", vigente_desde: "2026-10-01", vigente_hasta: "2026-10-07", modificado_por_nombre: null, estado: "reemplazada", valor_ilegible: true },
];

const SIMULACION_ACORTA = {
  valor_actual: 24,
  valor_propuesto: 12,
  acorta: true,
  altas_en_espera: 5,
  altas_que_ganan_plazo: 0,
  altas_que_caducarian_ya: [
    { tu_id: 1, persona_nombre: "Luis Ramírez", esperando_desde: "2026-10-07T01:00:00Z" },
    { tu_id: 2, persona_nombre: "Marta Núñez", esperando_desde: "2026-10-07T02:00:00Z" },
  ],
  altas_que_caducarian_ya_total: 2,
  altas_por_caducar_nuevas: 1,
  tope_por_corrida: 50,
};
const SIMULACION_ALARGA = {
  valor_actual: 24,
  valor_propuesto: 48,
  acorta: false,
  altas_en_espera: 5,
  altas_que_ganan_plazo: 3,
  altas_que_caducarian_ya: [],
  altas_que_caducarian_ya_total: 0,
  altas_por_caducar_nuevas: 0,
  tope_por_corrida: 50,
};

type Config = {
  sesion?: Record<string, unknown>;
  variables?: () => Response;
  historial?: () => Response;
  simular?: (cuerpo: { valor: number }) => Response;
  patch?: (clave: string, cuerpo: { valor: number; valor_base: number }) => Response;
};

function mockApi(config: Config = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") return Promise.resolve(respuestaSesion({ puede_editar_config_terminales: true, ...config.sesion }));
    if (path === "/api/terminales/configuracion/variables") return Promise.resolve(config.variables?.() ?? new Response(JSON.stringify(VARIABLES)));
    if (path.startsWith("/api/terminales/configuracion/variables/historial")) return Promise.resolve(config.historial?.() ?? new Response(JSON.stringify(HISTORIAL)));
    if (path === "/api/terminales/configuracion/variables/terminal_caducidad_alta_horas/simular" && init?.method === "POST") {
      const cuerpo = JSON.parse(init.body as string);
      return Promise.resolve(config.simular?.(cuerpo) ?? new Response(JSON.stringify(cuerpo.valor < 24 ? SIMULACION_ACORTA : SIMULACION_ALARGA)));
    }
    const m = /^\/api\/terminales\/configuracion\/variables\/(terminal_[a-z_]+)$/.exec(path);
    if (m && init?.method === "PATCH") {
      const cuerpo = JSON.parse(init.body as string);
      return Promise.resolve(config.patch?.(m[1], cuerpo) ?? new Response(JSON.stringify({ resultado: "actualizada", clave: m[1], valor: cuerpo.valor, vigente_desde: "2026-10-08" })));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

// Las etiquetas también aparecen en el historial: las filas de «valores vigentes» están en la 1.ª tabla.
function filaDe(etiqueta: string) {
  return within(screen.getAllByRole("table")[0]).getByText(etiqueta).closest("tr")!;
}

async function esperarTabla() {
  await screen.findByText("Valores vigentes");
  await screen.findAllByRole("table");
}

function patches() {
  return vi.mocked(apiFetch).mock.calls.filter(([, init]) => init?.method === "PATCH");
}

async function editarFila(etiqueta: string, valor: string) {
  const fila = filaDe(etiqueta);
  await userEvent.click(within(fila).getByRole("button", { name: /^editar/i }));
  const campo = within(filaDe(etiqueta)).getByRole("spinbutton");
  fireEvent.change(campo, { target: { value: valor } });
  return campo;
}

describe("VariablesTerminalesPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("lista las 5 variables con valor, unidad, rango, descripción y vigente desde", async () => {
    mockApi();
    render(<VariablesTerminalesPage />);
    await esperarTabla();
    const fila = filaDe("Caducidad de altas sin huella");
    expect(within(fila).getByText("Descripción de Caducidad de altas sin huella")).toBeInTheDocument();
    expect(within(fila).getByText("24")).toBeInTheDocument();
    expect(within(fila).getByText("horas")).toBeInTheDocument();
    expect(within(fila).getByText("4 – 168")).toBeInTheDocument();
    expect(within(fila).getByText(/20 sep 2026/)).toBeInTheDocument();
    for (const e of ["Antigüedad máxima de la llave del puente", "Ventana de anomalías", "Retención de rechazos", "Traslape de llaves"]) {
      expect(within(screen.getAllByRole("table")[0]).getByText(e)).toBeInTheDocument();
    }
  });

  it("no existe el umbral de picos de tasa (es fijo, no editable)", async () => {
    mockApi();
    render(<VariablesTerminalesPage />);
    await esperarTabla();
    expect(screen.queryByText(/picos/i)).not.toBeInTheDocument();
  });

  it("valor_ilegible en el listado: avisa que se muestra el valor por defecto", async () => {
    mockApi({ variables: () => new Response(JSON.stringify([variable("terminal_caducidad_alta_horas", "Caducidad de altas sin huella", 24, 4, 168, "horas", { valor_ilegible: true, vigente_desde: null })])) });
    render(<VariablesTerminalesPage />);
    await esperarTabla();
    const fila = filaDe("Caducidad de altas sin huella");
    expect(within(fila).getByText("Valor ilegible")).toBeInTheDocument();
    expect(within(fila).getByText(/se muestra el valor por defecto/i)).toBeInTheDocument();
  });

  it("el historial marca «Valor ilegible» sin formatear el texto crudo, y resuelve la etiqueta por clave", async () => {
    mockApi();
    render(<VariablesTerminalesPage />);
    await esperarTabla();
    const tabla = screen.getAllByRole("table")[1];
    const ilegible = within(tabla).getByText("Valor ilegible").closest("tr")!;
    expect(within(ilegible).getByText("Retención de rechazos")).toBeInTheDocument();
    expect(within(ilegible).queryByText(/basura/)).not.toBeInTheDocument();
    const vigente = within(tabla).getByText("24 horas").closest("tr")!;
    expect(within(vigente).getByText("Vigente")).toBeInTheDocument();
  });

  it("buscar en el historial filtra por variable o por persona", async () => {
    mockApi();
    render(<VariablesTerminalesPage />);
    await esperarTabla();
    const tabla = screen.getAllByRole("table")[1];
    expect(within(tabla).getAllByRole("row")).toHaveLength(3);
    await userEvent.type(screen.getByLabelText(/buscar por variable o persona/i), "retención");
    expect(within(tabla).getAllByRole("row")).toHaveLength(2);
  });

  describe("edición", () => {
    it("validación local: fuera de rango o no entero no llama al servidor", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "0");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      expect(within(filaDe("Ventana de anomalías")).getByText("Debe ser un entero entre 1 y 90.")).toBeInTheDocument();
      fireEvent.change(within(filaDe("Ventana de anomalías")).getByRole("spinbutton"), { target: { value: "7.5" } });
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      expect(within(filaDe("Ventana de anomalías")).getByText("Debe ser un entero entre 1 y 90.")).toBeInTheDocument();
      expect(patches()).toHaveLength(0);
    });

    it("guarda con valor y valor_base ENTEROS, avisa y recarga", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "14");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      expect(await screen.findByText(/ventana de anomalías actualizada a 14 días/i)).toBeInTheDocument();
      expect(patches()).toHaveLength(1);
      expect(patches()[0][0]).toBe("/api/terminales/configuracion/variables/terminal_anomalias_ventana_dias");
      expect(JSON.parse(patches()[0][1]!.body as string)).toEqual({ valor: 14, valor_base: 7 });
    });

    it("sin_cambio: dice que el valor ya era ese", async () => {
      mockApi({ patch: (clave, c) => new Response(JSON.stringify({ resultado: "sin_cambio", clave, valor: c.valor, vigente_desde: "2026-09-20" })) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "7");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      expect(await screen.findByText(/ya tenía ese valor/i)).toBeInTheDocument();
    });

    it("mientras guarda bloquea el campo y evita el doble envío", async () => {
      mockApi();
      let resolver!: (r: Response) => void;
      const anterior = vi.mocked(apiFetch).getMockImplementation()!;
      vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) =>
        init?.method === "PATCH" ? new Promise<Response>((r) => (resolver = r)) : anterior(path, init),
      );
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "14");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      expect(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardando/i })).toBeDisabled();
      expect(within(filaDe("Ventana de anomalías")).getByRole("spinbutton")).toBeDisabled();
      expect(patches()).toHaveLength(1);
      resolver(new Response(JSON.stringify({ resultado: "actualizada", clave: "terminal_anomalias_ventana_dias", valor: 14, vigente_desde: "2026-10-08" })));
      await screen.findByText(/actualizada a 14/i);
    });

    it("409: recarga el vigente (valor_actual), AVISA con ambos valores y conserva lo que escribió", async () => {
      mockApi({
        patch: () => new Response(JSON.stringify({ detail: "La variable cambió mientras la editabas; vuelve a leerla.", valor_actual: 10 }), { status: 409 }),
      });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "14");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      const alerta = await screen.findByRole("alert");
      expect(alerta).toHaveTextContent(/ahora es 10/i);
      expect(alerta).toHaveTextContent(/viste 7/i);
      const fila = filaDe("Ventana de anomalías");
      expect(within(fila).getByRole("spinbutton")).toHaveValue(14);
      expect(within(fila).getByText(/vigente actual: 10/i)).toBeInTheDocument();
      // al volver a guardar usa el valor_actual como base
      vi.mocked(apiFetch).mockClear();
      mockApi();
      await userEvent.click(within(fila).getByRole("button", { name: /guardar/i }));
      await waitFor(() => expect(patches()).toHaveLength(1));
      expect(JSON.parse(patches()[0][1]!.body as string)).toEqual({ valor: 14, valor_base: 10 });
    });

    it("código valor_desactualizado sin valor_actual: recarga las variables y avisa sin perder lo escrito", async () => {
      let cargas = 0;
      mockApi({
        variables: () => {
          cargas++;
          return new Response(JSON.stringify(cargas > 1 ? VARIABLES.map((v) => (v.clave === "terminal_anomalias_ventana_dias" ? { ...v, valor: 10 } : v)) : VARIABLES));
        },
        patch: () => new Response(JSON.stringify({ detail: "La variable cambió mientras la editabas; vuelve a leerla.", codigo: "valor_desactualizado" }), { status: 409 }),
      });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "14");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      expect(await screen.findByRole("alert")).toHaveTextContent(/cambió mientras la editabas/i);
      await waitFor(() => expect(cargas).toBe(2));
      expect(within(filaDe("Ventana de anomalías")).getByRole("spinbutton")).toHaveValue(14);
    });

    it.each([
      [422, "El valor debe ser un entero entre 1 y 90."],
      [403, "No tienes permiso para esta acción."],
    ])("error %i: muestra el mensaje fijo del backend y conserva el campo", async (status, detail) => {
      mockApi({ patch: () => new Response(JSON.stringify({ detail }), { status }) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "14");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      expect(await screen.findByRole("alert")).toHaveTextContent(detail);
      expect(within(filaDe("Ventana de anomalías")).getByRole("spinbutton")).toHaveValue(14);
    });

    it("regla cruzada de llaves (422 con texto fijo por clave)", async () => {
      const detail = "El traslape de llaves no puede superar la mitad de la antigüedad máxima de la llave (en días).";
      mockApi({ patch: () => new Response(JSON.stringify({ detail }), { status: 422 }) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Traslape de llaves", "60");
      await userEvent.click(within(filaDe("Traslape de llaves")).getByRole("button", { name: /guardar/i }));
      expect(await screen.findByRole("alert")).toHaveTextContent(detail);
    });

    it("500 con detail interno nunca se muestra", async () => {
      mockApi({ patch: () => new Response(JSON.stringify({ detail: "tabla tiempo.parametro" }), { status: 500 }) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "14");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      const alerta = await screen.findByRole("alert");
      expect(alerta).not.toHaveTextContent(/tiempo\.parametro/);
      expect(alerta).toHaveTextContent(/no se pudo guardar/i);
    });

    it("Cancelar descarta lo escrito", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", "14");
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /cancelar/i }));
      expect(within(filaDe("Ventana de anomalías")).queryByRole("spinbutton")).not.toBeInTheDocument();
      expect(within(filaDe("Ventana de anomalías")).getByText("7")).toBeInTheDocument();
    });
  });

  describe("caducidad de altas: impacto previo", () => {
    async function pedirImpacto(valor: string) {
      await editarFila("Caducidad de altas sin huella", valor);
      await userEvent.click(within(filaDe("Caducidad de altas sin huella")).getByRole("button", { name: /revisar impacto/i }));
    }

    it("la caducidad no tiene «Guardar» directo: pasa por «Revisar impacto…»", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Caducidad de altas sin huella", "12");
      expect(within(filaDe("Caducidad de altas sin huella")).queryByRole("button", { name: /^guardar$/i })).not.toBeInTheDocument();
    });

    it("acortar: calcula el impacto, muestra la cifra y sólo entonces habilita Confirmar", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("12");
      const panel = await screen.findByRole("alertdialog");
      expect(await within(panel).findByText(/2 altas caerían en la próxima corrida/i)).toBeInTheDocument();
      expect(within(panel).getByText(/de 5 en «esperando huella»/i)).toBeInTheDocument();
      expect(within(panel).getByText(/Luis Ramírez, Marta Núñez/)).toBeInTheDocument();
      expect(within(panel).getByText(/1 alta más quedará «por caducar»/i)).toBeInTheDocument();
      expect(within(panel).getByText(/también a las altas que ya están esperando huella/i)).toBeInTheDocument();
      const confirmar = within(panel).getByRole("button", { name: /confirmar/i });
      expect(confirmar).toBeEnabled();
      expect(JSON.parse(vi.mocked(apiFetch).mock.calls.find(([p]) => String(p).endsWith("/simular"))![1]!.body as string)).toEqual({ valor: 12 });
      await userEvent.click(confirmar);
      expect(await screen.findByText(/caducidad de altas sin huella actualizada a 12 horas/i)).toBeInTheDocument();
      expect(JSON.parse(patches()[0][1]!.body as string)).toEqual({ valor: 12, valor_base: 24 });
    });

    it("mientras calcula, Confirmar está deshabilitado", async () => {
      mockApi();
      const anterior = vi.mocked(apiFetch).getMockImplementation()!;
      vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) =>
        String(path).endsWith("/simular") ? new Promise<Response>(() => {}) : anterior(path, init),
      );
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("12");
      const panel = await screen.findByRole("alertdialog");
      expect(within(panel).getByText(/calculando cuántas altas/i)).toBeInTheDocument();
      expect(within(panel).getByRole("button", { name: /confirmar/i })).toBeDisabled();
    });

    it("si el cálculo falla al ACORTAR no se puede confirmar y se ofrece reintentar", async () => {
      let falla = true;
      mockApi({ simular: (c) => (falla ? new Response(JSON.stringify({ detail: "x" }), { status: 503 }) : new Response(JSON.stringify(SIMULACION_ACORTA))) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("12");
      const panel = await screen.findByRole("alertdialog");
      expect(await within(panel).findByText(/no se pudo calcular el impacto/i)).toBeInTheDocument();
      expect(within(panel).getByRole("button", { name: /confirmar/i })).toBeDisabled();
      falla = false;
      await userEvent.click(within(panel).getByRole("button", { name: /reintentar el cálculo/i }));
      await waitFor(() => expect(within(panel).getByRole("button", { name: /confirmar/i })).toBeEnabled());
    });

    it("ampliar: informa cuántas altas ganan plazo y no exige el cálculo para confirmar", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("48");
      const panel = await screen.findByRole("alertdialog");
      expect(await within(panel).findByText(/3 de 5 altas/i)).toBeInTheDocument();
      expect(within(panel).getByText(/ganan plazo/i)).toBeInTheDocument();
      expect(within(panel).getByRole("button", { name: /confirmar/i })).toBeEnabled();
    });

    it("si hay más altas que el tope por corrida, lo dice; los nombres se cortan con «y N más»", async () => {
      const muchas = Array.from({ length: 7 }, (_, i) => ({ tu_id: i, persona_nombre: `Persona ${i}`, esperando_desde: "2026-10-07T01:00:00Z" }));
      mockApi({ simular: () => new Response(JSON.stringify({ ...SIMULACION_ACORTA, altas_que_caducarian_ya: muchas, altas_que_caducarian_ya_total: 120, tope_por_corrida: 50 })) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("12");
      const panel = await screen.findByRole("alertdialog");
      expect(await within(panel).findByText(/120 altas caerían en la próxima corrida/i)).toBeInTheDocument();
      expect(within(panel).getByText(/50 por corrida/i)).toBeInTheDocument();
      expect(within(panel).getByText(/y 115 más/i)).toBeInTheDocument();
    });

    it("los nombres del servidor en el impacto son texto plano", async () => {
      mockApi({ simular: () => new Response(JSON.stringify({ ...SIMULACION_ACORTA, altas_que_caducarian_ya: [{ tu_id: 1, persona_nombre: "<b>Hack</b>", esperando_desde: "2026-10-07T01:00:00Z" }], altas_que_caducarian_ya_total: 1 })) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("12");
      expect(await screen.findByText(/<b>Hack<\/b>/)).toBeInTheDocument();
      expect(document.querySelector("b")).toBeNull();
    });

    it("Volver cierra el panel sin guardar", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("12");
      const panel = await screen.findByRole("alertdialog");
      await userEvent.click(within(panel).getByRole("button", { name: /^volver$/i }));
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(patches()).toHaveLength(0);
    });

    it("409 al confirmar: avisa con ambos valores y el panel de impacto se cierra para repetirlo", async () => {
      mockApi({ patch: () => new Response(JSON.stringify({ detail: "x", valor_actual: 36 }), { status: 409 }) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await pedirImpacto("12");
      const panel = await screen.findByRole("alertdialog");
      await within(panel).findByText(/2 altas caerían/i);
      await userEvent.click(within(panel).getByRole("button", { name: /confirmar/i }));
      const alerta = await screen.findByRole("alert");
      expect(alerta).toHaveTextContent(/ahora es 36/i);
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(within(filaDe("Caducidad de altas sin huella")).getByRole("spinbutton")).toHaveValue(12);
    });
  });

  describe("permisos y estados", () => {
    it("sin puede_editar_config_terminales (RH): sin botones de editar y nombra el permiso", async () => {
      mockApi({ sesion: { puede_editar_config_terminales: false } });
      render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/puedes consultar las variables, no modificarlas/i)).toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /^editar/i })).not.toBeInTheDocument();
      expect(screen.getByText(/puedes consultar las variables/i).closest(".banner-aviso")).toHaveTextContent(/terminal_config_edicion/);
    });

    it("sin puede_ver_terminales o 403: estado sin acceso", async () => {
      mockApi({ sesion: { puede_ver_terminales: false } });
      const a = render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
      a.unmount();
      mockApi({ variables: () => new Response(JSON.stringify({ detail: "no" }), { status: 403 }) });
      render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/no tienes acceso a las terminales/i)).toBeInTheDocument();
    });

    it("error de carga con Reintentar y forma inesperada", async () => {
      let falla = true;
      mockApi({ variables: () => (falla ? new Response(null, { status: 500 }) : new Response(JSON.stringify(VARIABLES))) });
      const a = render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/no se pudieron cargar las variables/i)).toBeInTheDocument();
      falla = false;
      await userEvent.click(screen.getByRole("button", { name: /reintentar/i }));
      await esperarTabla();
      expect(filaDe("Ventana de anomalías")).toBeInTheDocument();
      a.unmount();
      mockApi({ variables: () => new Response(JSON.stringify({ x: 1 })) });
      render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/no se pudieron cargar las variables/i)).toBeInTheDocument();
    });

    it("historial vacío y cargando", async () => {
      mockApi({ historial: () => new Response("[]") });
      const a = render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/todavía no hay cambios registrados/i)).toBeInTheDocument();
      a.unmount();
      vi.mocked(apiFetch).mockImplementation((path: string) =>
        path === "/api/sesion" ? Promise.resolve(respuestaSesion()) : new Promise<Response>(() => {}),
      );
      render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/cargando variables/i)).toBeInTheDocument();
    });

    it("las pestañas enlazan y marcan Variables como actual", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      expect(screen.getByRole("link", { name: /^variables$/i })).toHaveAttribute("aria-current", "page");
      expect(screen.getByRole("link", { name: /texto de consentimiento/i })).toHaveAttribute("href", "/tiempo/terminales/configuracion");
    });
  });

  describe("cobertura adicional (testing)", () => {
    it.each([
      ["1", true],
      ["90", true],
      ["0", false],
      ["91", false],
    ])("Ventana de anomalías (1–90): %s ⇒ %s", async (valor, valido) => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Ventana de anomalías", valor);
      await userEvent.click(within(filaDe("Ventana de anomalías")).getByRole("button", { name: /guardar/i }));
      if (valido) await waitFor(() => expect(patches()).toHaveLength(1));
      else {
        expect(within(filaDe("Ventana de anomalías")).getByText("Debe ser un entero entre 1 y 90.")).toBeInTheDocument();
        expect(patches()).toHaveLength(0);
      }
    });

    it("igualar el valor actual de la caducidad NO es acortar: confirmar queda habilitado aunque falle el cálculo", async () => {
      mockApi({ simular: () => new Response(JSON.stringify({ detail: "x" }), { status: 503 }) });
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Caducidad de altas sin huella", "24");
      await userEvent.click(within(filaDe("Caducidad de altas sin huella")).getByRole("button", { name: /revisar impacto/i }));
      const panel = await screen.findByRole("alertdialog");
      await within(panel).findByText(/no se pudo calcular el impacto/i);
      expect(within(panel).getByRole("button", { name: /confirmar/i })).toBeEnabled();
    });

    it("cambiar el campo descarta la simulación previa (no se puede confirmar con un cálculo viejo)", async () => {
      mockApi();
      render(<VariablesTerminalesPage />);
      await esperarTabla();
      await editarFila("Caducidad de altas sin huella", "12");
      await userEvent.click(within(filaDe("Caducidad de altas sin huella")).getByRole("button", { name: /revisar impacto/i }));
      await screen.findByRole("alertdialog");
      fireEvent.change(within(filaDe("Caducidad de altas sin huella")).getByRole("spinbutton"), { target: { value: "6" } });
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    it("una variable con valor que no es número (forma inválida) es un error de carga", async () => {
      mockApi({ variables: () => new Response(JSON.stringify([{ ...VARIABLES[0], valor: "24" }])) });
      render(<VariablesTerminalesPage />);
      expect(await screen.findByText(/no se pudieron cargar las variables/i)).toBeInTheDocument();
    });
  });
});
