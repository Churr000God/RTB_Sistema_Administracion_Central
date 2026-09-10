# 2026-09-05 · Pulido de UI (Estructura Organizacional/Permisos) + protección del puesto administrador

**Participantes:** `orchestrator` (coordinación) · `frontend` (todo el pulido de UI, iterativo con
capturas del usuario) · `backend`/`db`/`security` (protección del puesto administrador y fix de
datos) · equipo de 6 especialistas de `team-orchestrator`.

**Duración:** 5 de septiembre de 2026, sesión larga de QA manual del usuario probando la app en
vivo, con fixes puntuales pedidos sobre la marcha.

---

## Contexto

Con el pase de mejora cross-stack del día anterior cerrado, el usuario empezó a probar la
aplicación real en el navegador y fue pidiendo ajustes puntuales a medida que encontraba cosas —
la mayoría de UI/UX en Estructura Organizacional y Permisos, más dos hallazgos de datos/seguridad
reales que se resolvieron en el camino. Todo el trabajo de `frontend` fue iterativo: capturas de
pantalla del usuario → diagnóstico → fix → captura de verificación → siguiente ajuste.

## UI de Estructura Organizacional (Áreas/Departamentos/Puestos)

- **Ficha de Área**: tarjeta nueva "Departamentos de esta área" (activos/inactivos, con 403
  independiente si falta el permiso de departamentos).
- **Ficha de Departamento**: tres iteraciones de diseño con el usuario (opciones A/B/C vía
  `/design`) hasta llegar a la lista buscable de personas del departamento + resumen + desglose
  por puesto, con varios ajustes de layout después (contenedor ancho unificado, breakpoint para
  monitores grandes a 96rem, agrupar Área/Nombre/Fechas en una grilla, avatar+nombre en las filas
  de personas, scroll interno, separación buscador/lista).
- **Ficha de Puesto**: mismo patrón — tabla de personas asignadas con link a su ficha, resumen de
  plazas, "Permisos de este puesto" con su propio buscador y scroll interno.
- **Organigrama interactivo** (pedido nuevo, evaluado por factibilidad antes de construir): árbol
  de puestos por `reporta_a_id`, sin librería de diagramas nueva (CSS/SVG puro, ~15-20 nodos no
  lo justifican). Componente compartido `Organigrama.tsx`, usado en AsignacionesPage y
  DirectorioPuestosPage con el mismo híbrido elegido por el usuario entre 3 mockups: árbol grande
  en su propia pestaña (Opción A) + click en un nodo filtra la tabla por esa rama con chip
  removible (Opción B). Bug real encontrado y corregido después: `justify-content:center` sobre
  un contenedor con `overflow-x` cortaba el lado izquierdo sin que el scroll pudiera alcanzarlo
  (bug clásico de flexbox) — fix estándar (`margin:0 auto` en el hijo).
- **Directorio de Personas**: columnas y filtros nuevos por puesto/departamento/área, cruzando con
  `/api/asignaciones` (que ya trae los tres nombres denormalizados).

## UI de Permisos

Iteración larga con el usuario, en varios pasos:
1. Nota agregada explicando dónde revocar un permiso (no hay acción inline en el historial, es
   deliberado — ver test que lo confirma).
2. 3 mockups del catálogo de permisos (estaba ahí pero con un bug de acoplamiento a
   `filtrados.length` del historial, y poco visible) → Opción B elegida (sección propia, ancho
   completo, en grilla).
3. Varias vueltas de reubicación: catálogo con su propio buscador + filtro heredable/no
   heredable; filtros de fecha/orden del historial reubicados dos veces hasta terminar dentro de
   la tarjeta "Resumen" (apilados); catálogo con tarjeta por ítem en vez de texto suelto en
   grilla (rompía alineación); scroll interno tanto en catálogo como en historial.
4. Fix de navegación: revocar un permiso desde la ficha de un puesto ahora vuelve a esa ficha en
   vez de mandar siempre a la pantalla general de Permisos.

## Patrón de carga real (bloquea doble submit)

El usuario notó que las acciones tardaban en dar feedback y temía que el sistema mandara
peticiones duplicadas. Se extendió el `Button` compartido con `cargando`/`textoCargando`
(deshabilita de verdad, no sólo visual) y se aplicó a las 14 pantallas con acciones mutantes que
no tenían protección real, más homologación posterior en Login/VerificarTotp/
RestablecerContraseña (que ya prevenían doble submit pero sin el spinner visual).

## Hallazgo de datos: dos puestos de TI duplicados

El usuario encontró que "Encargado de TI" (el puesto real del organigrama, `16_*.sql`) y "Gerente
o Encargado de TI" (fixture de bootstrap, `26_*.sql`) eran dos conceptos deliberadamente
separados que terminaron pareciendo un duplicado en la UI. No se pudo borrar la fila vieja
(bitácora inmutable con FK activas) — el usuario la desactivó a mano vía el flujo real de la app.
`db` corrigió el DDL de seed (`15_`/`16_`/`27_`) para que un despliegue nuevo desde cero no vuelva
a crear el duplicado, documentando en comentarios por qué se sacó cada INSERT. Sin menciones en
docs versionados, sin bump de versión necesario ahí.

## Protección del puesto administrador (`es_administrador_generico`)

Pedido de seguridad: que el puesto "Gerente o Encargado de TI" (16 permisos, usuario base de
bootstrap) no pueda quedar sin acceso por acción de nadie. Diseñado en conjunto por `db` y
`security` (convergieron de forma independiente a la misma solución):

- Columna nueva `personas.puesto.es_administrador_generico`, inmutable tras el backfill (trigger
  BEFORE UPDATE) — sin esto, cualquiera con `puesto_edicion` podría apagar el flag y esquivar
  todo lo demás.
- Bloqueo total en 4 vectores, alcance ampliado por el usuario durante la sesión: revocar
  permisos (pedido original), terminar/cambiar la asignación de quien lo ocupa, y desactivar el
  puesto (los dos últimos, aprobados después de que `db`/`security` los señalaran como vectores
  de lockout más directos que el original).
- 2 capas: RLS (`32_puesto_administrador_generico_proteccion.sql`, la que realmente importa
  porque estos routers usan `get_caller_client`) + chequeo espejo en `backend` (4 endpoints, 422
  legible en vez de error crudo de RLS).
- `fn_asignacion_cambiar_puesto` no necesitó cambio propio — es `SECURITY INVOKER` y pasa por el
  mismo `UPDATE` que ya cubre la policy.
- Aplicado y verificado contra Supabase remoto: 1 puesto marcado (el correcto), índice único
  parcial y trigger de inmutabilidad probados con rollback. Revisado por `security` línea por
  línea, sin hallazgos.
- Documentado con bump menor en `SCJ-PRO-04`/`05`/`06` (las 3 reglas de negocio que la columna
  hace cumplir).
- Pendiente, decisión del usuario: validación en vivo contra Supabase con un JWT real (los 4
  chequeos de backend son de sólo lectura, sin riesgo de escritura) — no se hizo en esta sesión,
  falta que alguien pase un `access_token` a `backend` si se quiere confirmar 422 vs 500 en un
  entorno real.

## Nota sobre trabajo paralelo no relacionado

Durante toda la sesión hubo cambios sin commitear de otra conversación (probablemente el usuario
trabajando el módulo Tiempo directo con `db`, sin pasar por `orchestrator`): `README.md`,
`db/ddl/02_tiempo.sql`, `db/ddl/33_`-`37_*.sql`, `diagramas/fuente/logico.mmd`, y varios `SCJ-CDT-
01`/`ESP-01`/`PRA-01`/`TRZ-01`/`DIC-01`/`MOD-02`/`MOD-03`/`GLO-01`/`PRO-07` a `PRO-11`. No se tocó
ni se commiteó nada de eso desde esta sesión — se verificó explícitamente después de cada commit
que seguía intacto. Sigue pendiente de quien lo esté trabajando.

## Conteos de tests al cierre

- Backend: 122 → **126** casos.
- Frontend: 221 → **285** casos (41 → 42 archivos).

## Qué quedó pendiente

- Validación en vivo (JWT real) de los 4 endpoints de protección del puesto administrador —
  decisión del usuario, no bloqueante (RLS + tests unitarios ya lo cubren).
- `VerificarTotpRoute.tsx` sigue con cobertura casi nula (señalado en el pase anterior, no se
  tocó en este).
- Todo lo del módulo Tiempo que se ve en el working tree, ajeno a esta sesión.
