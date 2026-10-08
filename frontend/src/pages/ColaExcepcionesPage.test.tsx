import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { ColaExcepcionesPage } from "./ColaExcepcionesPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const EXCEPCIONES = [
  {
    id: 1,
    marca_id: 10,
    dia_id: null,
    motivo_revision: "fuera_de_horario",
    estado: "pendiente",
    creado_en: "2026-09-06T12:00:00Z",
    persona_nombre: "Persona Ficticia",
    momento_dispositivo: "2026-09-06T12:00:00Z",
  },
  {
    id: 2,
    marca_id: null,
    dia_id: 5,
    motivo_revision: "paridad_impar",
    estado: "pendiente",
    creado_en: "2026-09-05T08:00:00Z",
    persona_nombre: null,
    momento_dispositivo: null,
  },
];

function mockApiFetch(listado?: Response, sesion: Record<string, unknown> = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null, ...sesion })),
      );
    }
    if (path === "/api/excepciones") {
      return Promise.resolve(listado ?? new Response(JSON.stringify(EXCEPCIONES)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

const DIA_CERRADO_BASE = {
  marca_id: 70,
  dia_id: null,
  motivo_revision: "dia_cerrado",
  estado: "pendiente",
  es_dia_cerrado: true,
};
const A_REVISAR = {
  ...DIA_CERRADO_BASE,
  id: 11,
  creado_en: "2026-10-07T13:55:00Z",
  persona_nombre: "Pedro Salas",
  momento_dispositivo: "2026-10-06T01:20:00Z",
  dia_de_la_marca_id: 21,
  dia_de_la_marca_fecha: "2026-10-05",
  dia_de_la_marca_estado: "bloqueado",
  camino_resolucion: "revisar_dia",
};
const A_DESCARTAR = {
  ...DIA_CERRADO_BASE,
  id: 12,
  marca_id: 71,
  creado_en: "2026-10-05T15:02:00Z",
  persona_nombre: "Luis Ramírez",
  momento_dispositivo: "2026-10-04T02:41:00Z",
  dia_de_la_marca_id: 22,
  dia_de_la_marca_fecha: "2026-10-03",
  dia_de_la_marca_estado: "revisado",
  camino_resolucion: "descartar",
};
const MEZCLA = [EXCEPCIONES[0], A_REVISAR, A_DESCARTAR];

describe("ColaExcepcionesPage", () => {
  it("lista también las excepciones de día (dia_id, sin persona_nombre/momento_dispositivo)", async () => {
    mockApiFetch();

    render(<ColaExcepcionesPage />);

    await waitFor(() => expect(screen.getByText("Persona Ficticia")).toBeInTheDocument());
    const tabla = screen.getByRole("table");
    expect(within(tabla).getByText("Fuera de horario")).toBeInTheDocument();
    expect(within(tabla).getByText("Paridad impar de marcas")).toBeInTheDocument();
    expect(within(tabla).getByText("Excepción de día")).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: /corregir/i })[0]).toHaveAttribute(
      "href",
      "/tiempo/excepciones/1/corregir",
    );
  });

  it("filtra por persona y ordena por motivo", async () => {
    mockApiFetch(
      new Response(
        JSON.stringify([
          ...EXCEPCIONES,
          {
            id: 3,
            marca_id: 30,
            dia_id: null,
            motivo_revision: "persona_inactiva",
            estado: "pendiente",
            creado_en: "2026-09-07T09:00:00Z",
            persona_nombre: "Otra Persona",
            momento_dispositivo: "2026-09-07T09:00:00Z",
          },
        ]),
      ),
    );

    render(<ColaExcepcionesPage />);
    const tabla = await screen.findByRole("table");
    expect(within(tabla).getAllByRole("row")).toHaveLength(4); // encabezado + 3 filas

    await userEvent.type(screen.getByLabelText(/buscar por persona/i), "otra");
    await waitFor(() => expect(within(tabla).getAllByRole("row")).toHaveLength(2));
    expect(within(tabla).getByText("Otra Persona")).toBeInTheDocument();
  });

  it("muestra estado vacío cuando no hay excepciones pendientes", async () => {
    mockApiFetch(new Response(JSON.stringify([])));

    render(<ColaExcepcionesPage />);

    await waitFor(() =>
      expect(screen.getByText(/no hay excepciones de marca pendientes/i)).toBeInTheDocument(),
    );
  });

  it("muestra el estado de error cuando falla la carga", async () => {
    mockApiFetch(new Response(null, { status: 500 }));

    render(<ColaExcepcionesPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar la cola de excepciones/i)).toBeInTheDocument(),
    );
  });

  it("motivo con sufijo concatenado (fn_ausencia_resuelve_excepcion) traduce sólo la parte anterior al separador", async () => {
    mockApiFetch(
      new Response(
        JSON.stringify([
          {
            id: 4,
            marca_id: 40,
            dia_id: null,
            motivo_revision: "dia_cerrado — resuelto por ausencia autorizada, carga tardía",
            estado: "resuelto",
            creado_en: "2026-09-07T09:00:00Z",
            persona_nombre: "Persona Resuelta",
            momento_dispositivo: "2026-09-07T09:00:00Z",
          },
        ]),
      ),
    );

    render(<ColaExcepcionesPage />);

    await waitFor(() => expect(screen.getByText("Persona Resuelta")).toBeInTheDocument());
    expect(
      within(screen.getByRole("table")).getByText(
        "Día ya cerrado — resuelto por ausencia autorizada, carga tardía",
      ),
    ).toBeInTheDocument();
  });

  describe("excepciones de día cerrado", () => {
    it("ofrece las pestañas Todas y Día cerrado con sus conteos", async () => {
      mockApiFetch(new Response(JSON.stringify(MEZCLA)));
      render(<ColaExcepcionesPage />);
      expect(await screen.findByRole("tab", { name: "Todas (3)" })).toHaveAttribute("aria-selected", "true");
      expect(screen.getByRole("tab", { name: "Día cerrado (2)" })).toHaveAttribute("aria-selected", "false");
    });

    it("al cambiar a Día cerrado, Todas conserva el total", async () => {
      mockApiFetch(new Response(JSON.stringify(MEZCLA)));
      render(<ColaExcepcionesPage />);
      await userEvent.click(await screen.findByRole("tab", { name: /día cerrado/i }));
      expect(screen.getByRole("tab", { name: "Todas (3)" })).toBeInTheDocument();
      expect(screen.getByRole("tab", { name: "Día cerrado (2)" })).toBeInTheDocument();
    });

    it("la pestaña Día cerrado deja sólo esas excepciones, con fecha del día y estado del día", async () => {
      mockApiFetch(new Response(JSON.stringify(MEZCLA)));
      render(<ColaExcepcionesPage />);
      await userEvent.click(await screen.findByRole("tab", { name: /día cerrado/i }));

      const tabla = screen.getByRole("table");
      expect(within(tabla).queryByText("Persona Ficticia")).not.toBeInTheDocument();
      expect(within(tabla).getByText("Pedro Salas")).toBeInTheDocument();
      expect(within(tabla).getByText("05 oct 2026")).toBeInTheDocument();
      expect(within(tabla).getByText(/bloqueado — necesita revisión/i)).toBeInTheDocument();
      expect(within(tabla).getByText("Revisado")).toBeInTheDocument();
    });

    it("camino revisar_dia: enlace Revisar día y nunca Corregir", async () => {
      mockApiFetch(new Response(JSON.stringify([A_REVISAR])));
      render(<ColaExcepcionesPage />);
      const enlace = await screen.findByRole("link", { name: /revisar día/i });
      expect(enlace).toHaveAttribute("href", "/tiempo/dias?dia_id=21");
      expect(screen.queryByRole("link", { name: /corregir/i })).not.toBeInTheDocument();
    });

    it("Revisar día sin fila de día todavía filtra por persona y fecha", async () => {
      const sinFila = { ...A_REVISAR, persona_id: "p-9", dia_de_la_marca_id: null };
      mockApiFetch(new Response(JSON.stringify([sinFila])));
      render(<ColaExcepcionesPage />);
      expect(await screen.findByRole("link", { name: /revisar día/i })).toHaveAttribute(
        "href",
        "/tiempo/dias?persona_id=p-9&desde=2026-10-05&hasta=2026-10-05",
      );
    });

    it("camino descartar con permiso: botón que abre el modal y, al descartar, recarga la lista", async () => {
      let lista: unknown[] = [A_DESCARTAR];
      vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
        if (path === "/api/sesion")
          return Promise.resolve(
            new Response(JSON.stringify({ acceso_permitido: true, puede_descartar_excepciones: true })),
          );
        if (path === "/api/excepciones") return Promise.resolve(new Response(JSON.stringify(lista)));
        if (path === "/api/excepciones/12/descartar" && init?.method === "POST") {
          lista = [];
          return Promise.resolve(new Response(JSON.stringify({ resultado: "descartada", excepcion_id: 12 })));
        }
        return Promise.reject(new Error(`ruta no mockeada: ${path}`));
      });
      render(<ColaExcepcionesPage />);

      await userEvent.click(await screen.findByRole("button", { name: /descartar marca tardía/i }));
      expect(screen.getByRole("dialog", { name: /descartar marca tardía/i })).toBeInTheDocument();
      await userEvent.type(screen.getByLabelText(/motivo del descarte/i), "Registro accidental.");
      await userEvent.click(screen.getByRole("button", { name: /descartar definitivamente/i }));
      await userEvent.click(await screen.findByRole("button", { name: /^cerrar$/i }));

      await waitFor(() =>
        expect(screen.getByText(/no hay excepciones de marca pendientes/i)).toBeInTheDocument(),
      );
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    });

    it("camino descartar sin permiso: sin botón y con el porqué", async () => {
      mockApiFetch(new Response(JSON.stringify([A_DESCARTAR])), { puede_descartar_excepciones: false });
      render(<ColaExcepcionesPage />);
      expect(await screen.findByText(/sin permiso para descartar/i)).toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /descartar marca tardía/i })).not.toBeInTheDocument();
    });

    it("si /api/sesion falla, se trata como sin permiso (no ofrece descartar)", async () => {
      vi.mocked(apiFetch).mockImplementation((path: string) => {
        if (path === "/api/sesion") return Promise.resolve(new Response(null, { status: 500 }));
        return Promise.resolve(new Response(JSON.stringify([A_DESCARTAR])));
      });
      render(<ColaExcepcionesPage />);
      expect(await screen.findByText(/sin permiso para descartar/i)).toBeInTheDocument();
    });

    it("en la pestaña Todas una de día cerrado tampoco ofrece Corregir", async () => {
      mockApiFetch(new Response(JSON.stringify(MEZCLA)));
      render(<ColaExcepcionesPage />);
      await screen.findByText("Pedro Salas");
      expect(screen.getAllByRole("link", { name: /corregir/i })).toHaveLength(1);
    });

    it("pestaña Día cerrado sin pendientes muestra su estado vacío", async () => {
      mockApiFetch();
      render(<ColaExcepcionesPage />);
      await userEvent.click(await screen.findByRole("tab", { name: /día cerrado \(0\)/i }));
      expect(screen.getByText(/no hay excepciones de día cerrado pendientes/i)).toBeInTheDocument();
    });
  });
});
