import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DirectorioPersonasPage } from "./DirectorioPersonasPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));
vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
      signOut: vi.fn().mockResolvedValue({ error: null }),
    },
  },
}));

const PERSONAS = [
  {
    id: "1",
    primer_nombre: "Mariana",
    apellido_paterno: "Alcántara",
    estado: "activo",
    fecha_ingreso: "2022-03-14",
    fecha_baja: null,
  },
  {
    id: "2",
    primer_nombre: "Jorge",
    apellido_paterno: "Peña",
    estado: "suspension",
    fecha_ingreso: "2021-09-17",
    fecha_baja: null,
  },
  {
    id: "3",
    primer_nombre: "Karla",
    apellido_paterno: "Mendieta",
    estado: "baja_definitiva",
    fecha_ingreso: "2019-07-04",
    fecha_baja: new Date().toISOString().slice(0, 10),
  },
];

const ASIGNACIONES = [
  {
    persona_id: "1",
    puesto_id: "puesto-1",
    nombre_puesto: "Analista de Nómina",
    nombre_departamento: "Recursos Humanos",
    nombre_area: "Administración",
    vigente_hasta: null,
  },
  {
    persona_id: "1",
    puesto_id: "puesto-2",
    nombre_puesto: "Encargado de Capacitación",
    nombre_departamento: "Recursos Humanos",
    nombre_area: "Administración",
    vigente_hasta: null,
  },
  {
    persona_id: "2",
    puesto_id: "puesto-3",
    nombre_puesto: "Chofer",
    nombre_departamento: "Logística",
    nombre_area: "Operaciones",
    vigente_hasta: null,
  },
];

// AppShell hace su propio GET /api/sesion al montar — cada consumidor necesita su propio
// Response (el body sólo se puede leer una vez), y una respuesta sin acceso_permitido:true
// dispararía el guard de sesión y redirigiría, rompiendo el resto del test. /api/personas y
// /api/asignaciones son fetches independientes de la página (gates de permisos distintos) —
// cada uno necesita su propio Response también, o el segundo .json() revienta con "body
// already used".
function mockApiFetch(opciones: { personas?: Response; asignaciones?: Response } = {}) {
  vi.mocked(apiFetch).mockImplementation((path: string) => {
    if (path === "/api/sesion") {
      return Promise.resolve(
        new Response(JSON.stringify({ acceso_permitido: true, motivo_bloqueo: null }))
      );
    }
    if (path === "/api/personas") {
      return Promise.resolve(opciones.personas ?? new Response(JSON.stringify([])));
    }
    if (path === "/api/asignaciones") {
      return Promise.resolve(opciones.asignaciones ?? new Response(JSON.stringify(ASIGNACIONES)));
    }
    return Promise.reject(new Error(`ruta no mockeada: ${path}`));
  });
}

describe("DirectorioPersonasPage", () => {
  beforeEach(() => {
    vi.mocked(apiFetch).mockReset();
  });

  it("lista las personas devueltas por el backend, con exactamente 2 peticiones propias", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);

    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());
    // 3 llamadas totales: el guard de AppShell (/api/sesion) + las 2 propias de la página
    // (/api/personas y /api/asignaciones, independientes por tener gates de permisos
    // distintos) — ninguna hace una tercera petición encadenada.
    expect(apiFetch).toHaveBeenCalledTimes(3);
  });

  it("tolera personas sin fecha_ingreso/fecha_baja (undefined)", async () => {
    mockApiFetch({
      personas: new Response(
        JSON.stringify([{ id: "1", primer_nombre: "Mariana", apellido_paterno: "Alcántara", estado: "activo" }])
      ),
    });

    render(<DirectorioPersonasPage />);

    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());
  });

  it("calcula las métricas correctas (total, activos, suspensión, bajas del mes)", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);

    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());
    expect(screen.getByText("3")).toBeInTheDocument(); // total
    expect(screen.getByText("Activos").closest(".metrica")).toHaveTextContent("1");
    expect(screen.getByText(/suspensión temporal/i).closest(".metrica")).toHaveTextContent("1");
    expect(screen.getByText(/bajas del mes/i).closest(".metrica")).toHaveTextContent("1");
  });

  it("filtra por texto de búsqueda (nombre)", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    await userEvent.type(screen.getByLabelText(/buscar por nombre/i), "jorge");

    expect(screen.queryByText(/mariana alcántara/i)).not.toBeInTheDocument();
    expect(screen.getByText(/jorge peña/i)).toBeInTheDocument();
  });

  it("filtra por estado", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por estado/i), "suspension");

    expect(screen.queryByText(/mariana alcántara/i)).not.toBeInTheDocument();
    expect(screen.getByText(/jorge peña/i)).toBeInTheDocument();
  });

  it("muestra puesto, departamento y área en la fila, agrupando varias asignaciones vigentes sin duplicar depto/área", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    const filaMariana = screen.getByText(/mariana alcántara/i).closest("tr");
    expect(filaMariana).toHaveTextContent("Analista de Nómina, Encargado de Capacitación");
    expect(filaMariana).toHaveTextContent("Recursos Humanos");
    expect(filaMariana).toHaveTextContent("Administración");
  });

  it("personas sin asignación vigente muestran 'Sin asignar' en vez de desaparecer del listado", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/karla mendieta/i)).toBeInTheDocument());

    const filaKarla = screen.getByText(/karla mendieta/i).closest("tr");
    expect(filaKarla).toHaveTextContent("Sin asignar");
  });

  it("filtra por puesto: coincide si alguno de los puestos vigentes de la persona coincide", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por puesto/i), "puesto-1");

    expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument();
    expect(screen.queryByText(/jorge peña/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/karla mendieta/i)).not.toBeInTheDocument();
  });

  it("filtra por departamento", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por departamento/i), "Logística");

    expect(screen.queryByText(/mariana alcántara/i)).not.toBeInTheDocument();
    expect(screen.getByText(/jorge peña/i)).toBeInTheDocument();
  });

  it("filtra por área", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify(PERSONAS)) });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    await userEvent.selectOptions(screen.getByLabelText(/filtrar por área/i), "Operaciones");

    expect(screen.queryByText(/mariana alcántara/i)).not.toBeInTheDocument();
    expect(screen.getByText(/jorge peña/i)).toBeInTheDocument();
  });

  it("sin permiso para ver asignaciones (403): el padrón sigue completo, las columnas de puesto/departamento/área degradan sin romper la página", async () => {
    mockApiFetch({
      personas: new Response(JSON.stringify(PERSONAS)),
      asignaciones: new Response(null, { status: 403 }),
    });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    expect(
      screen.getByText(/no tienes permiso para ver el puesto\/departamento\/área asignados/i)
    ).toBeInTheDocument();
    const filaMariana = screen.getByText(/mariana alcántara/i).closest("tr");
    expect(filaMariana?.textContent).toContain("—");
  });

  it("error al cargar asignaciones (500): muestra aviso propio sin romper el padrón", async () => {
    mockApiFetch({
      personas: new Response(JSON.stringify(PERSONAS)),
      asignaciones: new Response(null, { status: 500 }),
    });

    render(<DirectorioPersonasPage />);
    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());

    expect(screen.getByText(/no se pudo cargar la asignación de puestos/i)).toBeInTheDocument();
  });

  it("muestra el estado vacío con copy propio cuando no hay personas", async () => {
    mockApiFetch({ personas: new Response(JSON.stringify([])) });

    render(<DirectorioPersonasPage />);

    await waitFor(() =>
      expect(
        screen.getByText(/no hay personas registradas o tu cuenta no tiene acceso al padrón/i)
      ).toBeInTheDocument()
    );
  });

  it("muestra el estado de error con opción de reintentar", async () => {
    mockApiFetch({ personas: new Response(null, { status: 500 }) });

    render(<DirectorioPersonasPage />);

    await waitFor(() =>
      expect(screen.getByText(/no se pudo cargar el directorio/i)).toBeInTheDocument()
    );
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument();
  });
});
