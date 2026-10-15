import { useCallback, useEffect, useState } from "react";

import { consultarSesionConReintento, ErrorSesion, type SesionOut } from "./sesion";

// «Reintentar» en una instancia (p. ej. el de AppShell) debe refrescar a TODAS las demás (la página que
// llama useSesion por encima del AppShell): si no, la página seguiría con su propio error aunque el marco
// ya se hubiera recuperado. Las instancias se avisan por este conjunto y la consulta se deduplica.
const oyentes = new Set<() => void>();

export type EstadoSesion = {
  sesion: SesionOut | null;
  // true mientras NO hay una sesión utilizable: durante la consulta (reintentos automáticos incluidos) Y
  // tras una falla definitiva. Así ninguna pantalla pide sus datos con una sesión que no se pudo verificar;
  // quien quiera distinguir «sigue cargando» de «falló» mira `error`.
  cargando: boolean;
  // La falla definitiva de GET /api/sesion (tras los reintentos); null si cargó o aún carga.
  error: ErrorSesion | null;
  reintentar: () => void;
};

// Sesión del caller para decidir qué mostrar (banderas de permisos). Tres estados: cargando, error
// (con reintento automático previo y uno manual) y cargada. consultarSesionConReintento() deduplica la
// petición en vuelo, así que usarlo junto con AppShell no duplica GET /api/sesion. Una falla ya NO se
// traduce en «todo permitido»: cada pantalla decide, y AppShell no monta las pantallas de módulo.
export function useSesion(): EstadoSesion {
  const [sesion, setSesion] = useState<SesionOut | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<ErrorSesion | null>(null);
  const [intento, setIntento] = useState(0);

  useEffect(() => {
    let vivo = true;
    setCargando(true);
    setError(null);
    consultarSesionConReintento()
      .then((datos) => {
        if (vivo) setSesion(datos);
      })
      .catch((falla) => {
        if (vivo) {
          setSesion(null);
          setError(falla instanceof ErrorSesion ? falla : new ErrorSesion(null));
        }
      })
      .finally(() => {
        if (vivo) setCargando(false);
      });
    return () => {
      vivo = false;
    };
  }, [intento]);

  useEffect(() => {
    const oyente = () => setIntento((n) => n + 1);
    oyentes.add(oyente);
    return () => {
      oyentes.delete(oyente);
    };
  }, []);

  const reintentar = useCallback(() => {
    for (const oyente of [...oyentes]) oyente();
  }, []);

  return { sesion, cargando: cargando || error !== null, error, reintentar };
}
