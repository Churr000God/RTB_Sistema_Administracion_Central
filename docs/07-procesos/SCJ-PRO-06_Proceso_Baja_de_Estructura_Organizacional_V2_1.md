# Proceso — Baja/desactivación de estructura organizacional (área / departamento / puesto)

**Sistema de Control de Jornada**
Folio SCJ-PRO-06 · Versión 2.1 · 5 de septiembre de 2026

Sexto documento de la serie `SCJ-PRO`, subsistema **Personas y Usuarios** — módulo
Asignaciones/áreas/puestos/permisos. Cierra el módulo: cubre desactivar (`activo = false`) y
reactivar (`activo = true`) área, departamento y puesto, precisando la regla ya anunciada en
`SCJ-PRO-03 §V` ("no se desactiva si tiene información asociada activa río abajo").

> **Cambió en V2.1 (no contradice V2.0, se agrega sin quitar nada — bump menor):** el puesto
> marcado `personas.puesto.es_administrador_generico = true` (el fixture de bootstrap de
> `26_puesto_permiso_bootstrap_admin_generico.sql`) no puede desactivarse, sin excepción — ver
> DPA en §III/§IV y la regla nueva de §V. Hoy ya queda bloqueado de rebote por DP1/DP3 (siempre
> tiene asignación vigente y `puesto_permiso` activo), pero eso es un efecto colateral, no una
> garantía — la protección nueva es explícita y no depende de que DP1/DP3 seguro se cumplan.
> Ver también `SCJ-PRO-04 §V` (misma protección, para no poder cortarle la asignación) y
> `SCJ-PRO-05 §V` (misma protección, para no poder revocarle un permiso) — las tres cierran el
> mismo puesto por sus tres vectores distintos.
>
> **Cambió en V2.0:** el §VI decía "nada de este proceso está construido". Los endpoints
> `PATCH /api/{areas,departamentos,puestos}/{id}/estado` y el frontend ya existían desde el corte
> de `area`, pero con las validaciones DA1/DD1/RD1/DP1/DP3 marcadas `TODO` porque las tablas que
> necesitaban consultar (`departamento`, `puesto`, `asignacion`, `puesto_permiso`) no existían
> todavía en ese momento. El 4 de septiembre de 2026, con esas tablas ya construidas, `backend`
> cerró las 5 validaciones pendientes; `testing` sumó los casos de rechazo (incluido el mensaje de
> error exacto de cada uno) y confirmó 100% de cobertura en los 3 routers; `security` revisó que
> ninguna abre un gap de permisos. Contradice contenido ya escrito (mayor, no menor), de ahí el
> bump a V2.0.

---

## I. Alcance

**Cubre:** desactivación y reactivación de `area`, `departamento`, `puesto`.

**No cubre:**

- **Alta** de estos tres catálogos — `SCJ-PRO-03`.
- **Asignación de persona a puesto** — `SCJ-PRO-04`.
- **Otorgar/revocar permiso a puesto** — `SCJ-PRO-05`.
- **Desactivación de `permiso`** — no es proceso de usuario. Igual que su alta (`SCJ-PRO-03 §I`),
  se toca por migración al momento de deprecar un módulo, no desde una UI.
- **Ningún `DELETE`.** Este proceso, como el resto del módulo, nunca borra filas — sólo cambia
  `activo`.

---

## II. Precondiciones

1. Usuario con el permiso de edición correspondiente (`area_edicion`, `departamento_edicion` o
   `puesto_edicion`).
2. La entidad existe. Para desactivar, `activo = true`; para reactivar, `activo = false`.

---

## III. Diagrama de flujo

```mermaid
flowchart TD
    subgraph DESACTIVAR["Desactivar"]
        DA0["Desactivar area"] --> DA1{"¿tiene algún\ndepartamento\ncon activo = true?"}
        DA1 -->|sí| DA2["Rechaza"]
        DA1 -->|no| DA3["area.activo = false"]

        DD0["Desactivar departamento"] --> DD1{"¿tiene algún\npuesto con\nactivo = true?"}
        DD1 -->|sí| DD2["Rechaza"]
        DD1 -->|no| DD3["departamento.activo = false"]

        DP0["Desactivar puesto"] --> DPA{"¿es_administrador_generico?"}
        DPA -->|sí| DPA2["Rechaza: puesto administrador,\nnunca se desactiva"]
        DPA -->|no| DP1{"¿tiene asignacion\nvigente (vigente_hasta\nIS NULL)?"}
        DP1 -->|sí| DP2["Rechaza"]
        DP1 -->|no| DP3{"¿tiene puesto_permiso\ncon activo = true?"}
        DP3 -->|sí| DP2
        DP3 -->|no| DP4{"¿otro puesto activo\ntiene reporta_a_id\napuntando a éste?"}
        DP4 -->|sí| DP5["Rechaza: reasigna primero\na los subordinados\n(SCJ-PRO-03)"]
        DP4 -->|no| DP6["Puesto_activo = false"]
    end

    subgraph REACTIVAR["Reactivar"]
        RA0["Reactivar area"] --> RA1["area.activo = true\n(sin condición, es el tope)"]

        RD0["Reactivar departamento"] --> RD1{"area.activo = true?"}
        RD1 -->|no| RD2["Rechaza"]
        RD1 -->|sí| RD3["departamento.activo = true"]

        RP0["Reactivar puesto"] --> RP1{"departamento.activo = true\nY (reporta_a_id es el tope\nO el puesto al que reporta\nestá activo)?"}
        RP1 -->|no| RP2["Rechaza"]
        RP1 -->|sí| RP3["Puesto_activo = true"]
    end
```

---

## IV. Descripción paso a paso

| Paso | Actor | Acción | Toca |
|---|---|---|---|
| DA1 | Sistema | Rechaza desactivar `area` si algún `departamento` hijo sigue `activo = true` | `personas.departamento` |
| DD1 | Sistema | Rechaza desactivar `departamento` si algún `puesto` hijo sigue `Puesto_activo = true` | `personas.puesto` |
| DPA | Sistema | Rechaza desactivar `puesto` si `es_administrador_generico = true`, sin excepción — primer chequeo, antes que cualquier otro (V2.1) | `personas.puesto` |
| DP1 | Sistema | Rechaza desactivar `puesto` si tiene una `asignacion` vigente (persona ocupándolo) | `personas.asignacion` |
| DP3 | Sistema | Rechaza si tiene algún `puesto_permiso.activo = true` (permisos otorgados) | `personas.puesto_permiso` |
| DP4 | Sistema | Rechaza si algún puesto activo le reporta (`reporta_a_id` apunta a éste) | `personas.puesto` |
| RA1 | Sistema | `area` se reactiva sin condición — es el tope de la jerarquía | `personas.area` |
| RD1 | Sistema | `departamento` sólo se reactiva si su `area` está activa | `personas.area` |
| RP1 | Sistema | `puesto` sólo se reactiva si su `departamento` está activo **y** el puesto al que reporta está activo (o es el puesto tope) | `personas.departamento`, `personas.puesto` |

---

## V. Reglas de negocio confirmadas

- **"Información asociada activa río abajo" (`SCJ-PRO-03 §V`) significa hijos DIRECTOS, no toda la
  cadena transitiva.** `area` sólo revisa `departamento`; `departamento` sólo revisa `puesto`. La
  protección de tres niveles se logra sola: no puedes desactivar `area` mientras tenga un
  `departamento` activo, y no puedes desactivar ese `departamento` mientras tenga un `puesto`
  activo — así que `area` nunca queda desactivada con un `puesto` vivo debajo, sin que `area` tenga
  que revisar `puesto` directamente.
- **`puesto` es el único con tres fuentes de bloqueo distintas**, porque es el único nivel con tres
  tipos de "hijo": personas asignadas (`asignacion`), permisos otorgados (`puesto_permiso`), y
  puestos subordinados (`reporta_a_id` de otros apuntando a éste). Los otros dos catálogos sólo
  tienen un tipo de hijo cada uno.
- **Reactivar depende de la cadena hacia arriba, no hacia abajo.** Un `puesto` no puede reactivarse
  colgado de un `departamento` inactivo, ni un `departamento` de un `area` inactiva. `puesto`
  también valida su propio `reporta_a_id`: no puede reactivarse reportando a un puesto que sigue
  inactivo.
- **Nunca hay `DELETE`.** Consistente con el resto del proyecto (`asignacion`, `puesto_permiso`) —
  desactivar es la única forma de "retirar" algo del catálogo, preservando el historial completo.
- **`permiso` queda fuera de este proceso a propósito** — su ciclo de vida es de migración/deploy,
  no de operación diaria (`SCJ-PRO-03 §I`).
- **El puesto administrador nunca se desactiva, sin excepción (V2.1).** El puesto marcado
  `es_administrador_generico = true` (a lo sumo uno, `SCJ-PRO-05 §V`) se rechaza en `DPA`, antes
  de llegar siquiera a evaluar `DP1`/`DP3`/`DP4`. Es un chequeo explícito, no un efecto colateral
  de las otras reglas — aunque hoy el puesto administrador siempre tiene asignación vigente y
  `puesto_permiso` activo (así que `DP1`/`DP3` ya lo bloquearían de rebote), esa coincidencia no es
  una garantía si algún día ese puesto queda temporalmente sin asignación o sin permisos activos.
  Implementado en las dos capas de siempre: `backend/app/routers/puestos.py::
  cambiar_estado_puesto()` (chequeo explícito, antes de DP1/DP3) y RLS
  (`db/ddl/32_puesto_administrador_generico_proteccion.sql` — la policy de `personas.puesto`
  rechaza la transición a `activo = false` para ese puesto, deja pasar `activo = true`).

---

## VI. Estado actual — implementado

Construido de punta a punta:

- **Backend:** `PATCH /api/areas/{id}/estado`, `PATCH /api/departamentos/{id}/estado`,
  `PATCH /api/puestos/{id}/estado` en `backend/app/routers/{areas,departamentos,puestos}.py` —
  DA1/RA1, DD1/RD1, DP1/DP3/DP4/RP1 implementados exactamente como se describen en §III/§IV
  (4 de septiembre de 2026).
- **Frontend:** botones "Desactivar"/"Reactivar" en `FichaAreaPage`, `FichaDepartamentoPage`,
  `FichaPuestoPage`, ya conectados a estos endpoints.
- **DB:** ninguna tabla ni columna nueva — usa `area`/`departamento`/`puesto`/`asignacion`/
  `puesto_permiso` ya existentes. Índices de las columnas FK que consultan estas validaciones
  (`departamento.area_id`, `puesto.departamento_id`, `asignacion.puesto_id`) en
  `30_indices_fk.sql`.
- **RLS:** las escrituras de `.../estado` exigen `area_edicion`/`departamento_edicion`/
  `puesto_edicion` real (`31_personas_rls_permiso_especifico.sql`), no sólo estar activo. Desde el
  5 de septiembre de 2026, además: desactivar el puesto administrador
  (`es_administrador_generico`) nunca procede
  (`32_puesto_administrador_generico_proteccion.sql` — ver §V, DPA).

Tests: 5 casos nuevos de rechazo (uno por regla) más los ya existentes de camino feliz, 100% de
cobertura de líneas en los 3 routers.

---

## VII. Siguiente paso

Con `SCJ-PRO-03` a `06` cerrados e implementados, el módulo **Asignaciones/áreas/puestos/permisos**
tiene su diseño de procesos completo — alta, asignación, permisos y baja de los tres catálogos —
y todo construido en código. Sigue: actualizar el Sprint Backlog de Notion
(`[[notion-sprint-backlog-scj]]`) reflejando este avance, y decidir con el usuario si falta algún
otro proceso del módulo.

---

*Proceso · Folio SCJ-PRO-06 · V2.1*
