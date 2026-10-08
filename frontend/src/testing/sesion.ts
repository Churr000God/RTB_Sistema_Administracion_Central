// Utilidades de prueba para páginas que leen GET /api/sesion (AppShell y useSesion).
//
// CUIDADO: lib/sesion.ts::consultarSesion() deduplica la petición en vuelo a nivel de MÓDULO. Si una
// prueba deja /api/sesion sin responder (p. ej. `mockImplementation(() => new Promise(() => {}))`
// para probar «cargando»), esa promesa colgada queda compartida y las pruebas siguientes del mismo
// archivo nunca salen de «Verificando acceso…». Para probar un estado de carga responde SIEMPRE
// /api/sesion y deja colgada sólo la petición que quieres observar (ver `respuestaSesion`).
export function respuestaSesion(extra: Record<string, unknown> = {}): Response {
  return new Response(
    JSON.stringify({
      acceso_permitido: true,
      puede_ver_terminales: true,
      puede_editar_terminales: true,
      puede_editar_config_terminales: false,
      ...extra,
    }),
  );
}
