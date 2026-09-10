import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { FichaPuestoPage } from "./FichaPuestoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const DEPARTAMENTO = { id: "dep-1", nombre_departamento: "Ventas" };
const SUPERIOR = { id: "puesto-superior", nombre_puesto: "Director Comercial" };

const PUESTO = {
  id: "77777777-7777-7777-7777-777777777777",
  departamento_id: DEPARTAMENTO.id,
  nombre_puesto: "Ejecutivo de Ventas",
  nivel: "operativo",
  plazas_totales: 5,
  reporta_a_id: SUPERIOR.id,
  activo: true,
  creado_en: "2026-08-31T00:00:00+00:00",
  actualizado_en: "2026-08-31T00:00:00+00:00",
};

function mockApiFetch(overrides: {
  puesto?: Record<string, unknown>;
  departamento?: Record<string, unknown> | null;
  superior?: Record<string, unknown> | null;
  permisosVigentes?: Response;
  asignaciones?: Response;
  patch?: (path: string, init: RequestInit) => Response | undefined;
} = {}) {
  const puesto = overrides.puesto ?? PUESTO;
  const departamento = overrides.departamento === undefined ? DEPARTAMENTO : overrides.departamento;
  const superior = overrides.superior === undefined ? SUPERIOR : overrides.superior;

  vi.mocked(apiFetch).mockImplementation((path: string, init?: RequestInit) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (overrides.patch && init?.method === "PATCH") {
      const respuesta = overrides.patch(path, init);
      if (respuesta) return Promise.resolve(respuesta);
    }
    if (path === `/api/departamentos/${(puesto as typeof PUESTO).departamento_id}`) {
      return Promise.resolve(
        departamento ? new Response(JSON.stringify(departamento)) : new Response(null, { status: 404 })
      );
    }
    if (path === "/api/permisos/vigentes") {
      return Promise.resolve(overrides.permisosVigentes ?? new Response(JSON.stringify([])));
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(overrides.asignaciones ?? new Response(JSON.stringify([])));
    }
    if (path === `/api/puestos/${(puesto as typeof PUESTO).reporta_a_id}`) {
      return Promise.resolve(
        superior ? new Response(JSON.stringify(superior)) : new Response(null, { status: 404 })
      );
    }
    return Promise.resolve(new Response(JSON.stringify(puesto)));
  });
}

function renderPagina() {
  render(
    <MemoryRouter initialEntries={[`/estructura/puestos/${PUESTO.id}`]}>
      <Routes>
        <Route path="/estructura/puestos/:id" element={<FichaPuestoPage />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("FichaPuestoPage", () => {
  it("muestra nombre, estado, nivel, plazas, departamento y puesto superior", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));
    expect(screen.getByText("Activo")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByText("Ventas")).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText("Director Comercial")).toBeInTheDocument());
  });

  it("muestra '— (puesto tope)' cuando no hay reporta_a_id", async () => {
    mockApiFetch({ puesto: { ...PUESTO, reporta_a_id: null } });
    renderPagina();

    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));
    expect(screen.getByText("— (puesto tope)")).toBeInTheDocument();
  });

  it("renombra/cambia nivel y plazas vía PATCH /api/puestos/:id", async () => {
    let cuerpoEnviado: Record<string, unknown> | null = null;
    mockApiFetch({
      patch: (path, init) => {
        if (path !== `/api/puestos/${PUESTO.id}`) return undefined;
        cuerpoEnviado = JSON.parse(init.body as string);
        return new Response(
          JSON.stringify({ ...PUESTO, nombre_puesto: "Gerente de Ventas", nivel: "gerencia", plazas_totales: 1 })
        );
      },
    });
    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));

    const campoNombre = screen.getByLabelText(/^nombre$/i);
    await userEvent.clear(campoNombre);
    await userEvent.type(campoNombre, "Gerente de Ventas");
    await userEvent.selectOptions(screen.getByLabelText(/^nivel$/i), "gerencia");
    const plazas = screen.getByLabelText(/plazas totales/i);
    await userEvent.clear(plazas);
    await userEvent.type(plazas, "1");
    await userEvent.click(screen.getByRole("button", { name: /guardar/i }));

    await waitFor(() => expect(cuerpoEnviado).not.toBeNull());
    expect(cuerpoEnviado).toMatchObject({
      nombre_puesto: "Gerente de Ventas",
      nivel: "gerencia",
      plazas_totales: 1,
    });
    await waitFor(() => expect(screen.getAllByText("Gerente de Ventas").length).toBeGreaterThan(0));
  });

  it("bloquea la desactivación por subordinados activos y muestra el detail real del backend", async () => {
    mockApiFetch({
      patch: (path) => {
        if (path !== `/api/puestos/${PUESTO.id}/estado`) return undefined;
        return new Response(
          JSON.stringify({ detail: "No se puede desactivar: tiene puestos subordinados activos." }),
          { status: 422 }
        );
      },
    });
    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));

    await userEvent.click(screen.getByRole("button", { name: /desactivar puesto/i }));

    await waitFor(() =>
      expect(
        screen.getByText("No se puede desactivar: tiene puestos subordinados activos.")
      ).toBeInTheDocument()
    );
    // sigue activo: el estado no debe haber cambiado
    expect(screen.getByText("Activo")).toBeInTheDocument();
  });

  it("desactiva el puesto cuando no hay subordinados activos", async () => {
    mockApiFetch({
      patch: (path) => {
        if (path !== `/api/puestos/${PUESTO.id}/estado`) return undefined;
        return new Response(JSON.stringify({ ...PUESTO, activo: false }));
      },
    });
    renderPagina();
    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));

    await userEvent.click(screen.getByRole("button", { name: /desactivar puesto/i }));

    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: /reactivar puesto/i })).toBeInTheDocument();
  });

  it("bloquea la reactivación cuando el departamento o el superior están inactivos, con el detail real", async () => {
    mockApiFetch({
      puesto: { ...PUESTO, activo: false },
      patch: (path) => {
        if (path !== `/api/puestos/${PUESTO.id}/estado`) return undefined;
        return new Response(
          JSON.stringify({
            detail: "No se puede reactivar: el departamento o el puesto superior no están activos.",
          }),
          { status: 422 }
        );
      },
    });
    renderPagina();
    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /reactivar puesto/i }));

    await waitFor(() =>
      expect(
        screen.getByText(
          "No se puede reactivar: el departamento o el puesto superior no están activos."
        )
      ).toBeInTheDocument()
    );
    expect(screen.getByText("Inactivo")).toBeInTheDocument();
  });

  it("reactiva el puesto cuando el departamento y el superior están activos", async () => {
    mockApiFetch({
      puesto: { ...PUESTO, activo: false },
      patch: (path) => {
        if (path !== `/api/puestos/${PUESTO.id}/estado`) return undefined;
        return new Response(JSON.stringify({ ...PUESTO, activo: true }));
      },
    });
    renderPagina();
    await waitFor(() => expect(screen.getByText("Inactivo")).toBeInTheDocument());

    await userEvent.click(screen.getByRole("button", { name: /reactivar puesto/i }));

    await waitFor(() => expect(screen.getByText("Activo")).toBeInTheDocument());
  });

  it("si GET /api/puestos/:id falla, muestra error con reintentar", async () => {
    vi.mocked(apiFetch).mockImplementation((path: string) => {
      if (path === "/api/sesion") {
        return Promise.resolve(
          new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
        );
      }
      return Promise.resolve(new Response(null, { status: 500 }));
    });

    renderPagina();

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar este puesto/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });

  it("tiene un link 'Otorgar permiso' con deep-link a este puesto", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));
    expect(screen.getByRole("link", { name: /otorgar permiso/i })).toHaveAttribute(
      "href",
      `/estructura/permisos/otorgar?puesto_id=${PUESTO.id}`
    );
  });

  it("lista los permisos vigentes de este puesto (filtrado por puesto_id+activo) con link a revocar", async () => {
    mockApiFetch({
      permisosVigentes: new Response(
        JSON.stringify([
          { id: "puesto-permiso-ficticio-1", puesto_id: PUESTO.id, codigo: "permiso_ficticio_uno", activo: true },
          // de otro puesto — debe excluirse
          { id: "puesto-permiso-ficticio-2", puesto_id: "otro-puesto-ficticio", codigo: "permiso_ficticio_dos", activo: true },
          // de este puesto pero inactivo (ya revocado) — debe excluirse
          { id: "puesto-permiso-ficticio-3", puesto_id: PUESTO.id, codigo: "permiso_ficticio_tres", activo: false },
        ])
      ),
    });
    renderPagina();

    await waitFor(() => expect(screen.getByText("permiso_ficticio_uno")).toBeInTheDocument());
    expect(screen.queryByText("permiso_ficticio_dos")).not.toBeInTheDocument();
    expect(screen.queryByText("permiso_ficticio_tres")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: /revocar/i })).toHaveAttribute(
      "href",
      `/estructura/permisos/puesto-permiso-ficticio-1/revocar?puesto_id=${PUESTO.id}`
    );
  });

  it("muestra 'sin permisos otorgados' cuando /vigentes no trae nada para este puesto", async () => {
    mockApiFetch();
    renderPagina();

    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));
    expect(
      screen.getByText(/este puesto no tiene permisos otorgados actualmente/i)
    ).toBeInTheDocument();
  });

  it("degrada a un mensaje propio si /api/permisos/vigentes falla, sin romper el resto de la ficha", async () => {
    mockApiFetch({ permisosVigentes: new Response(null, { status: 500 }) });
    renderPagina();

    await waitFor(() => expect(screen.getAllByText("Ejecutivo de Ventas").length).toBeGreaterThan(0));
    await waitFor(() =>
      expect(
        screen.getByText(/no se pudieron cargar los permisos de este puesto/i)
      ).toBeInTheDocument()
    );
  });

  describe("personas asignadas a este puesto (opción B: dos columnas)", () => {
    const ASIGNACION_SOFIA = {
      persona_id: "persona-sofia",
      persona_nombre: "Sofía Ramírez",
      puesto_id: PUESTO.id,
      vigente_desde: "2025-02-03",
      vigente_hasta: null,
    };
    const ASIGNACION_DIEGO = {
      persona_id: "persona-diego",
      persona_nombre: "Diego Morales",
      puesto_id: PUESTO.id,
      vigente_desde: "2024-06-18",
      vigente_hasta: null,
    };
    const ASIGNACION_OTRO_PUESTO = {
      persona_id: "persona-otro-puesto",
      persona_nombre: "No Debería Aparecer",
      puesto_id: "otro-puesto-ficticio",
      vigente_desde: "2024-01-01",
      vigente_hasta: null,
    };
    const ASIGNACION_TERMINADA = {
      persona_id: "persona-vieja",
      persona_nombre: "Persona Ya No Vigente",
      puesto_id: PUESTO.id,
      vigente_desde: "2020-01-01",
      vigente_hasta: "2023-01-01",
    };

    it("lista en tabla las personas vigentes de este puesto, con link a su expediente, y filtra por búsqueda", async () => {
      mockApiFetch({
        asignaciones: new Response(
          JSON.stringify([ASIGNACION_SOFIA, ASIGNACION_DIEGO, ASIGNACION_OTRO_PUESTO, ASIGNACION_TERMINADA])
        ),
      });
      renderPagina();

      await waitFor(() => expect(screen.getByText("Sofía Ramírez")).toBeInTheDocument());
      expect(screen.getByText("Diego Morales")).toBeInTheDocument();
      expect(screen.queryByText("No Debería Aparecer")).not.toBeInTheDocument();
      expect(screen.queryByText("Persona Ya No Vigente")).not.toBeInTheDocument();

      expect(screen.getByRole("link", { name: /sofía ramírez/i })).toHaveAttribute(
        "href",
        "/personas/persona-sofia"
      );

      const resumen = screen.getByText("Resumen").closest(".tarjeta-resumen") as HTMLElement;
      expect(within(resumen).getByText("2/5")).toBeInTheDocument();

      await userEvent.type(screen.getByLabelText(/buscar por nombre/i), "sofía");
      expect(screen.getByText("Sofía Ramírez")).toBeInTheDocument();
      expect(screen.queryByText("Diego Morales")).not.toBeInTheDocument();
    });

    it("muestra un estado vacío si el puesto no tiene personas asignadas", async () => {
      mockApiFetch();
      renderPagina();

      await waitFor(() =>
        expect(
          screen.getByText("Este puesto no tiene personas asignadas actualmente.")
        ).toBeInTheDocument()
      );
    });

    it("si GET /api/asignaciones da 403, avisa sin romper el resto de la ficha (permisos y datos del puesto siguen)", async () => {
      mockApiFetch({ asignaciones: new Response(null, { status: 403 }) });
      renderPagina();

      await waitFor(() =>
        expect(
          screen.getByText("No tienes permiso para ver las personas asignadas a este puesto.")
        ).toBeInTheDocument()
      );
      expect(screen.getByRole("button", { name: /desactivar puesto/i })).toBeInTheDocument();
      const resumen = screen.getByText("Resumen").closest(".tarjeta-resumen") as HTMLElement;
      expect(within(resumen).getByText("—/5")).toBeInTheDocument();
    });

    it("si GET /api/asignaciones falla con otro error, muestra un aviso genérico", async () => {
      mockApiFetch({ asignaciones: new Response(null, { status: 500 }) });
      renderPagina();

      await waitFor(() =>
        expect(
          screen.getByText("No se pudieron cargar las personas asignadas a este puesto.")
        ).toBeInTheDocument()
      );
    });
  });

  describe("búsqueda y scroll en Permisos de este puesto", () => {
    const PERMISOS_VARIOS = [
      { id: "pp-1", puesto_id: PUESTO.id, codigo: "equipo_ti_gestion", activo: true },
      { id: "pp-2", puesto_id: PUESTO.id, codigo: "ticket_soporte_atencion", activo: true },
    ];

    it("filtra los permisos por nombre con el buscador", async () => {
      mockApiFetch({ permisosVigentes: new Response(JSON.stringify(PERMISOS_VARIOS)) });
      renderPagina();

      await waitFor(() => expect(screen.getByText("equipo_ti_gestion")).toBeInTheDocument());
      expect(screen.getByText("ticket_soporte_atencion")).toBeInTheDocument();

      await userEvent.type(screen.getByLabelText(/buscar por nombre de permiso/i), "ticket");

      expect(screen.getByText("ticket_soporte_atencion")).toBeInTheDocument();
      expect(screen.queryByText("equipo_ti_gestion")).not.toBeInTheDocument();
    });

    it("muestra un aviso cuando ningún permiso coincide con la búsqueda", async () => {
      mockApiFetch({ permisosVigentes: new Response(JSON.stringify(PERMISOS_VARIOS)) });
      renderPagina();

      await waitFor(() => expect(screen.getByText("equipo_ti_gestion")).toBeInTheDocument());
      await userEvent.type(screen.getByLabelText(/buscar por nombre de permiso/i), "no existe");

      expect(screen.getByText("Ningún permiso coincide con la búsqueda.")).toBeInTheDocument();
      expect(screen.queryByText("equipo_ti_gestion")).not.toBeInTheDocument();
    });

    it("la lista de permisos tiene la clase de scroll interno (no crece sin límite)", async () => {
      mockApiFetch({ permisosVigentes: new Response(JSON.stringify(PERMISOS_VARIOS)) });
      renderPagina();

      await waitFor(() => expect(screen.getByText("equipo_ti_gestion")).toBeInTheDocument());
      expect(screen.getByText("equipo_ti_gestion").closest("ul")).toHaveClass("lista-desplazable");
    });
  });
});
