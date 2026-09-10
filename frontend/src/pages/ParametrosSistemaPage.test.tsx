import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ParametrosSistemaPage } from "./ParametrosSistemaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

type ParametroVigente = {
  clave: string;
  valor: string;
  vigente_desde: string;
  etiqueta: string;
  descripcion: string;
  tipo: "entero" | "hora";
  unidad: string | null;
  impacta_logica: boolean;
  nota: string | null;
};

type ParametroHistorialItem = {
  id: number;
  clave: string;
  etiqueta: string;
  valor: string;
  vigente_desde: string;
  vigente_hasta: string | null;
  registrado_por: string | null;
  nombre_registrado_por: string | null;
};

// Las 8 claves reales del catálogo -- las 8 con impacta_logica=true, 1 con nota, cero sin
// consumidor. hora_corte_dia/ventana_banco_meses ya lo tenían de cortes anteriores de esta misma
// sesión; umbral_aviso_pct/umbral_escalamiento_pct lo ganan ahora con la alerta de magnitud de
// deuda de Banco de Horas (nivel_alerta).
// "Ventana del banco de horas" no aparece en HISTORIAL_FIJO -- sirve de marca de carga sin
// ambigüedad entre las dos tablas de la página.
const VIGENTES_FIJOS: ParametroVigente[] = [
  {
    clave: "tolerancia_retardo_min",
    valor: "15",
    vigente_desde: "2026-01-01",
    etiqueta: "Tolerancia de retardo",
    descripcion: "Minutos antes de considerar retardo.",
    tipo: "entero",
    unidad: "min",
    impacta_logica: true,
    nota: null,
  },
  {
    clave: "hora_corte_dia",
    valor: "23:30",
    vigente_desde: "2026-01-01",
    etiqueta: "Hora de corte de día",
    descripcion: "A qué hora se considera cerrado un día.",
    tipo: "hora",
    unidad: null,
    impacta_logica: true,
    nota: null,
  },
  {
    clave: "ventana_banco_meses",
    valor: "3",
    vigente_desde: "2026-01-01",
    etiqueta: "Ventana del banco de horas",
    descripcion: "Duración de la ventana de resolución del banco de horas.",
    tipo: "entero",
    unidad: "meses",
    impacta_logica: true,
    nota: null,
  },
  {
    clave: "umbral_aviso_pct",
    valor: "80",
    vigente_desde: "2026-01-01",
    etiqueta: "Umbral de aviso",
    descripcion: "Porcentaje de la jornada semanal para avisar.",
    tipo: "entero",
    unidad: "%",
    impacta_logica: true,
    nota: null,
  },
  {
    clave: "umbral_escalamiento_pct",
    valor: "95",
    vigente_desde: "2026-01-01",
    etiqueta: "Umbral de escalamiento",
    descripcion: "Porcentaje de la jornada semanal para escalar.",
    tipo: "entero",
    unidad: "%",
    impacta_logica: true,
    nota: null,
  },
  {
    clave: "descuento_pausa_no_registrada_min",
    valor: "30",
    vigente_desde: "2026-01-01",
    etiqueta: "Descuento por pausa no registrada",
    descripcion: "Descuento fijo cuando la pausa no se marca.",
    tipo: "entero",
    unidad: "min",
    impacta_logica: true,
    nota: null,
  },
  {
    clave: "dias_habiles_correccion_marca",
    valor: "5",
    vigente_desde: "2026-01-01",
    etiqueta: "Días hábiles para corrección de marca",
    descripcion: "Ventana para corregir una marca, contada en días hábiles.",
    tipo: "entero",
    unidad: "días hábiles",
    impacta_logica: true,
    nota: null,
  },
  {
    clave: "hora_corrida_cierre_dia",
    valor: "00:15",
    vigente_desde: "2026-01-01",
    etiqueta: "Hora de corrida de cierre de día",
    descripcion: "Colchón tras la hora de corte de día antes de correr el batch de cierre.",
    tipo: "hora",
    unidad: null,
    impacta_logica: true,
    nota: "Requiere reiniciar el backend para tomar efecto -- el scheduler la lee una sola vez al arrancar.",
  },
];

// "Luis Gómez" aparece una sola vez -- sirve de marca de carga del historial.
const HISTORIAL_FIJO: ParametroHistorialItem[] = [
  {
    id: 5,
    clave: "tolerancia_retardo_min",
    etiqueta: "Tolerancia de retardo",
    valor: "15",
    vigente_desde: "2026-03-01",
    vigente_hasta: null,
    registrado_por: "auth-1",
    nombre_registrado_por: "Ana Pérez",
  },
  {
    id: 4,
    clave: "tolerancia_retardo_min",
    etiqueta: "Tolerancia de retardo",
    valor: "10",
    vigente_desde: "2026-01-15",
    vigente_hasta: "2026-03-01",
    registrado_por: "auth-2",
    nombre_registrado_por: "Luis Gómez",
  },
  {
    id: 3,
    clave: "hora_corte_dia",
    etiqueta: "Hora de corte de día",
    valor: "23:30",
    vigente_desde: "2026-02-01",
    vigente_hasta: null,
    registrado_por: null,
    nombre_registrado_por: null,
  },
  {
    id: 2,
    clave: "umbral_aviso_pct",
    etiqueta: "Umbral de aviso",
    valor: "80",
    vigente_desde: "2025-12-01",
    vigente_hasta: "2026-01-01",
    registrado_por: "auth-1",
    nombre_registrado_por: "Ana Pérez",
  },
  {
    id: 1,
    clave: "umbral_aviso_pct",
    etiqueta: "Umbral de aviso",
    valor: "70",
    vigente_desde: "2025-06-01",
    vigente_hasta: "2025-12-01",
    registrado_por: "auth-3",
    nombre_registrado_por: "María José",
  },
];

function mockApiFetch(opciones: {
  vigentes?: ParametroVigente[];
  vigentesResp?: Response;
  historial?: ParametroHistorialItem[];
  historialResp?: Response;
  put?: Response;
} = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null })),
      );
    }
    if (path === "/api/parametros" && (!init || init.method === undefined)) {
      return Promise.resolve(
        opciones.vigentesResp ?? new Response(JSON.stringify(opciones.vigentes ?? VIGENTES_FIJOS)),
      );
    }
    if (path === "/api/parametros/historial" && (!init || init.method === undefined)) {
      return Promise.resolve(
        opciones.historialResp ??
          new Response(JSON.stringify(opciones.historial ?? HISTORIAL_FIJO)),
      );
    }
    if (
      path.startsWith("/api/parametros/") &&
      path !== "/api/parametros/historial" &&
      init?.method === "PUT"
    ) {
      return Promise.resolve(
        opciones.put ?? new Response(JSON.stringify({ ...VIGENTES_FIJOS[0], valor: "20" })),
      );
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path} ${init?.method ?? "GET"}`));
  });
}

async function esperarCarga() {
  await screen.findByText("Ventana del banco de horas");
  await screen.findByText("Luis Gómez");
}

function tablaVigentes(): HTMLElement {
  return screen.getAllByRole("table").find((t) => within(t).queryByText("Aviso"))!;
}

function tablaHistorial(): HTMLElement {
  return screen.getAllByRole("table").find((t) => within(t).queryByText("Modificado por"))!;
}

async function clickEditar(etiqueta: string) {
  const fila = within(tablaVigentes()).getByText(etiqueta).closest("tr")!;
  await userEvent.click(within(fila).getByRole("button", { name: "Editar" }));
}

describe("ParametrosSistemaPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("carga ambas tarjetas con un solo GET cada una, sin query string", async () => {
    mockApiFetch();
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    const llamadasVigentes = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => path === "/api/parametros");
    const llamadasHistorial = vi
      .mocked(apiFetch)
      .mock.calls.filter(([path]) => path === "/api/parametros/historial");
    expect(llamadasVigentes).toHaveLength(1);
    expect(llamadasHistorial).toHaveLength(1);
  });

  it("editar, confirmar y guardar hace PUT con el body correcto y recarga ambas tarjetas", async () => {
    mockApiFetch();
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    await clickEditar("Tolerancia de retardo");
    const input = screen.getByLabelText("Nuevo valor para Tolerancia de retardo");
    await userEvent.clear(input);
    await userEvent.type(input, "20");
    await userEvent.click(screen.getByRole("button", { name: "Guardar" }));

    expect(screen.getByRole("alert")).toHaveTextContent(/cambiar.*tolerancia de retardo/i);

    await userEvent.click(screen.getByRole("button", { name: "Sí, guardar" }));

    await waitFor(() => {
      const llamadaPut = vi
        .mocked(apiFetch)
        .mock.calls.find(
          ([path, init]) => path === "/api/parametros/tolerancia_retardo_min" && init?.method === "PUT",
        );
      expect(llamadaPut).toBeDefined();
      expect(JSON.parse((llamadaPut![1] as RequestInit).body as string)).toEqual({ valor: "20" });
    });

    await waitFor(() => {
      const llamadasVigentes = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => path === "/api/parametros");
      const llamadasHistorial = vi
        .mocked(apiFetch)
        .mock.calls.filter(([path]) => path === "/api/parametros/historial");
      expect(llamadasVigentes.length).toBeGreaterThanOrEqual(2);
      expect(llamadasHistorial.length).toBeGreaterThanOrEqual(2);
    });
  });

  it("cancelar la confirmación no dispara PUT", async () => {
    mockApiFetch();
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    await clickEditar("Tolerancia de retardo");
    const input = screen.getByLabelText("Nuevo valor para Tolerancia de retardo");
    await userEvent.clear(input);
    await userEvent.type(input, "20");
    await userEvent.click(screen.getByRole("button", { name: "Guardar" }));

    expect(screen.getByRole("alert")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Cancelar" }));

    expect(vi.mocked(apiFetch).mock.calls.some(([, init]) => init?.method === "PUT")).toBe(false);
  });

  it("un 4xx en el PUT muestra el error sin cerrar la confirmación", async () => {
    mockApiFetch({
      put: new Response(JSON.stringify({ detail: "No se pudo guardar el nuevo valor." }), {
        status: 422,
      }),
    });
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    await clickEditar("Tolerancia de retardo");
    const input = screen.getByLabelText("Nuevo valor para Tolerancia de retardo");
    await userEvent.clear(input);
    await userEvent.type(input, "20");
    await userEvent.click(screen.getByRole("button", { name: "Guardar" }));
    await userEvent.click(screen.getByRole("button", { name: "Sí, guardar" }));

    await waitFor(() =>
      expect(screen.getByText("No se pudo guardar el nuevo valor.")).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: "Sí, guardar" })).toBeInTheDocument();
  });

  it("la búsqueda con y sin acentos da el mismo resultado", async () => {
    mockApiFetch();
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    const campoBusqueda = screen.getByLabelText("Buscar por parámetro");

    await userEvent.type(campoBusqueda, "dia");
    await waitFor(() => {
      expect(within(tablaHistorial()).getAllByRole("row")).toHaveLength(2); // encabezado + 1
    });

    await userEvent.clear(campoBusqueda);
    await userEvent.type(campoBusqueda, "día");
    await waitFor(() => {
      expect(within(tablaHistorial()).getAllByRole("row")).toHaveLength(2); // encabezado + 1
    });
  });

  it("rango de fechas y orden combinados con AND filtran correctamente", async () => {
    mockApiFetch();
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    expect(within(tablaHistorial()).getAllByRole("row")).toHaveLength(6); // encabezado + 5

    await userEvent.type(screen.getByLabelText("Vigente desde"), "2026-01-01");
    await userEvent.type(screen.getByLabelText("Vigente hasta"), "2026-03-01");
    await waitFor(() => {
      expect(within(tablaHistorial()).getAllByRole("row")).toHaveLength(4); // encabezado + 3
    });

    await userEvent.selectOptions(screen.getByLabelText("Ordenar por"), "parametro_asc");
    const filas = within(tablaHistorial()).getAllByRole("row");
    expect(filas).toHaveLength(4);
    expect(within(filas[1]).getByText("Hora de corte de día")).toBeInTheDocument();
  });

  it("botón Limpiar filtros y los dos estados vacíos distintos", async () => {
    mockApiFetch({ historial: [] });
    const { unmount } = render(<ParametrosSistemaPage />);
    await screen.findByText("Ventana del banco de horas");
    await waitFor(() =>
      expect(screen.getByText("No hay cambios registrados todavía.")).toBeInTheDocument(),
    );
    unmount();

    mockApiFetch();
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    await userEvent.type(screen.getByLabelText("Buscar por parámetro"), "zzz-no-existe");
    await waitFor(() =>
      expect(screen.getByText("Ningún cambio coincide con los filtros.")).toBeInTheDocument(),
    );
    await userEvent.click(screen.getByRole("button", { name: "Limpiar filtros" }));
    await waitFor(() => {
      expect(within(tablaHistorial()).getAllByRole("row")).toHaveLength(6);
    });
  });

  it("el badge de 'sin efecto' ya no aparece en ninguna clave -- las 8 tienen consumidor real", async () => {
    mockApiFetch();
    render(<ParametrosSistemaPage />);
    await esperarCarga();

    const tabla = tablaVigentes();
    const insigniasSinEfecto = within(tabla).queryAllByText("Sin efecto en la lógica actual");
    expect(insigniasSinEfecto).toHaveLength(0);

    const filaCierreDia = within(tabla)
      .getByText("Hora de corrida de cierre de día")
      .closest("tr")!;
    const filaTolerancia = within(tabla).getByText("Tolerancia de retardo").closest("tr")!;
    expect(within(filaCierreDia).getByText(/requiere reiniciar el backend/i)).toBeInTheDocument();
    expect(within(filaTolerancia).queryByText(/requiere reiniciar el backend/i)).toBeNull();
  });
});
