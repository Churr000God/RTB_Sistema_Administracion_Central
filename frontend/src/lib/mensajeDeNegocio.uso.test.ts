import { describe, expect, it } from "vitest";

// `mensajeDeNegocio` muestra el `detail` del servidor en 403/409/422. Eso sólo es seguro con las rutas
// del módulo de terminales, cuyos mensajes son FIJOS. Las rutas de otros módulos (ausencias, días, ...)
// pueden devolver texto crudo en sus 422 hasta que backend confirme lo contrario: no deben usar este
// helper. Esta prueba documenta y vigila esa frontera; para sumar un archivo a la lista hace falta que
// backend confirme que ese módulo ya cerró sus 422 con mensajes fijos.
const PERMITIDOS = [
  "../components/AsignarPersonaTerminalModal.tsx",
  "../components/BajaAltaModal.tsx",
  "../components/ConfirmarHuellaModal.tsx",
  "../components/PublicarConsentimientoPanel.tsx",
  "../components/ReconsentimientoModal.tsx",
  "../pages/VariablesTerminalesPage.tsx",
  "./errorApi.ts",
];

const fuentes = import.meta.glob(["../**/*.ts", "../**/*.tsx", "!../**/*.test.ts", "!../**/*.test.tsx"], {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

describe("uso de mensajeDeNegocio", () => {
  it("sólo lo usan archivos del módulo de terminales", () => {
    const usuarios = Object.entries(fuentes)
      .filter(([, contenido]) => contenido.includes("mensajeDeNegocio"))
      .map(([ruta]) => ruta)
      .sort();
    expect(usuarios).toEqual([...PERMITIDOS].sort());
  });

  it("ningún archivo permitido lo usa contra rutas de otros módulos", () => {
    const ajenas = [/\/api\/ausencias/, /\/api\/dias/, /\/api\/marcas/, /\/api\/excepciones/, /\/api\/personas\/\$\{[^}]*\}\/movimientos/];
    for (const ruta of PERMITIDOS) {
      const contenido = fuentes[ruta] ?? "";
      for (const patron of ajenas) {
        expect(contenido, `${ruta} toca ${patron}`).not.toMatch(patron);
      }
    }
  });
});
