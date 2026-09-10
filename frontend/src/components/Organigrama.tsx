import type { KeyboardEvent } from "react";

export type PuestoOrganigrama = {
  id: string;
  nombre_puesto: string;
  reporta_a_id: string | null;
  activo: boolean;
  plazas_totales: number;
};

type NodoArbol = {
  puesto: PuestoOrganigrama;
  hijos: NodoArbol[];
};

function mapaHijosPorPuesto(puestos: PuestoOrganigrama[]): Map<string, string[]> {
  const hijos = new Map<string, string[]>();
  for (const puesto of puestos) {
    if (puesto.reporta_a_id === null) continue;
    const lista = hijos.get(puesto.reporta_a_id) ?? [];
    lista.push(puesto.id);
    hijos.set(puesto.reporta_a_id, lista);
  }
  return hijos;
}

// Mismo algoritmo que `mapa_hijos_por_puesto`/`descendientes_incluido_si_mismo` de
// backend/app/permisos.py, pero en TS para pintar el árbol — el conjunto de puestos es chico
// (~15-20 filas, ver comentario de esa función), arma el bosque completo en memoria en vez de
// pedir un endpoint nuevo.
export function descendientesIncluidoSiMismo(
  puestos: PuestoOrganigrama[],
  puestoId: string,
): Set<string> {
  const hijos = mapaHijosPorPuesto(puestos);
  const vistos = new Set([puestoId]);
  const pendientes = [puestoId];
  while (pendientes.length > 0) {
    const actual = pendientes.pop()!;
    for (const hijo of hijos.get(actual) ?? []) {
      if (!vistos.has(hijo)) {
        vistos.add(hijo);
        pendientes.push(hijo);
      }
    }
  }
  return vistos;
}

// Puede haber más de un "puesto tope" (reporta_a_id nulo) — cada uno arranca su propio árbol,
// no se fuerza una raíz sintética común.
export function construirBosque(puestos: PuestoOrganigrama[]): NodoArbol[] {
  const porId = new Map(puestos.map((p) => [p.id, p]));
  const hijos = mapaHijosPorPuesto(puestos);

  function construirNodo(puesto: PuestoOrganigrama): NodoArbol {
    return {
      puesto,
      hijos: (hijos.get(puesto.id) ?? [])
        .map((id) => porId.get(id))
        .filter((p): p is PuestoOrganigrama => p !== undefined)
        .sort((a, b) => a.nombre_puesto.localeCompare(b.nombre_puesto))
        .map(construirNodo),
    };
  }

  return puestos
    .filter((p) => p.reporta_a_id === null || !porId.has(p.reporta_a_id))
    .sort((a, b) => a.nombre_puesto.localeCompare(b.nombre_puesto))
    .map(construirNodo);
}

// Filtra el bosque por nombre de puesto, conservando el camino hacia cualquier descendiente
// que coincida (si no, un match profundo desaparecería junto con sus ancestros).
export function filtrarBosque(bosque: NodoArbol[], consulta: string): NodoArbol[] {
  if (!consulta) return bosque;

  function filtrarNodo(nodo: NodoArbol): NodoArbol | null {
    const hijosFiltrados = nodo.hijos.map(filtrarNodo).filter((n): n is NodoArbol => n !== null);
    const coincide = nodo.puesto.nombre_puesto.toLowerCase().includes(consulta);
    if (!coincide && hijosFiltrados.length === 0) return null;
    return { puesto: nodo.puesto, hijos: hijosFiltrados };
  }

  return bosque.map(filtrarNodo).filter((n): n is NodoArbol => n !== null);
}

type PropsNodo = {
  nodo: NodoArbol;
  esRaiz: boolean;
  ocupadasPorPuesto?: Record<string, number>;
  onSeleccionarPuesto: (puesto: PuestoOrganigrama) => void;
};

function NodoDelArbol({ nodo, esRaiz, ocupadasPorPuesto, onSeleccionarPuesto }: PropsNodo) {
  const ocupadas = ocupadasPorPuesto?.[nodo.puesto.id];

  function activar() {
    onSeleccionarPuesto(nodo.puesto);
  }

  function alTecla(evento: KeyboardEvent<HTMLDivElement>) {
    if (evento.key === "Enter" || evento.key === " ") {
      evento.preventDefault();
      activar();
    }
  }

  return (
    <li>
      <div
        className={`nodo-organigrama${esRaiz ? " nodo-organigrama--raiz" : ""}${!nodo.puesto.activo ? " nodo-organigrama--inactivo" : ""}`}
        role="button"
        tabIndex={0}
        onClick={activar}
        onKeyDown={alTecla}
      >
        <strong>{nodo.puesto.nombre_puesto}</strong>
        <span className="nodo-organigrama-conteo">
          {ocupadas !== undefined ? `${ocupadas}/${nodo.puesto.plazas_totales} ocupadas` : `${nodo.puesto.plazas_totales} plazas`}
        </span>
        {!nodo.puesto.activo && <span className="nodo-organigrama-conteo">Inactivo</span>}
      </div>
      {nodo.hijos.length > 0 && (
        <ul>
          {nodo.hijos.map((hijo) => (
            <NodoDelArbol
              key={hijo.puesto.id}
              nodo={hijo}
              esRaiz={false}
              ocupadasPorPuesto={ocupadasPorPuesto}
              onSeleccionarPuesto={onSeleccionarPuesto}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

type Props = {
  bosque: NodoArbol[];
  ocupadasPorPuesto?: Record<string, number>;
  onSeleccionarPuesto: (puesto: PuestoOrganigrama) => void;
};

// Recipe CSS clásico de organigrama (líneas conectoras vía pseudo-elementos en tokens.css,
// sección §organigrama) — sin librería de diagramas nueva, ver bitácora de la decisión.
export function Organigrama({ bosque, ocupadasPorPuesto, onSeleccionarPuesto }: Props) {
  return (
    <div className="bosque-organigrama">
      {bosque.map((raiz) => (
        <div className="arbol-organigrama" key={raiz.puesto.id}>
          <ul>
            <NodoDelArbol
              nodo={raiz}
              esRaiz
              ocupadasPorPuesto={ocupadasPorPuesto}
              onSeleccionarPuesto={onSeleccionarPuesto}
            />
          </ul>
        </div>
      ))}
    </div>
  );
}
