# 2026-09-08 · Movimiento de saldo manual — renovar/descontar/condonar deuda vieja

**Participantes:** Diego (usuario), `orchestrator` + `db` + `backend` + `frontend` vía
`team-orchestrator`.
**Duración:** un corte, con investigación previa a fondo antes de plan mode (a pedido explícito
del usuario: "revisa primero la lógica antes de planear, las dudas dímelas"), una ronda de
`AskUserQuestion` (4 preguntas), delegación secuencial `db` → `backend` (con un fix de seguridad
en el camino) → `frontend`.

---

## Qué se hizo

Cierra el pendiente más viejo del proyecto: "Movimiento de saldo" se mencionó como cuarta pantalla
faltante desde el 7 de septiembre (`bitacora/2026-09-07_parametros_del_sistema.md`), nunca
construida. El usuario mandó el diagrama ER de `tiempo.movimiento_de_saldo` (ya implementado desde
`02_tiempo.sql`) pidiendo un formulario para decidir qué hacer con la deuda de 6+ meses de
antigüedad (el desglose que armamos temprano en el día, `banco_antiguedad.py`), con una
descripción explícitamente incierta de dos de los cuatro tipos ("cubrir tendría que... creo que
arrastrar es lo mismo").

**Investigación previa (sin la cual el diseño habría sido incorrecto):** un agente `Explore`
confirmó que hoy **no existe ninguna vía de escritura humana** sobre `tiempo.movimiento_de_saldo`
— sólo policy de SELECT (`56_*.sql`), el único escritor real es el batch de corte quincenal con
`service_role`. El permiso `movimiento_de_saldo_edicion` ya existe y ya está mapeado a RH/Gerente
General/TI desde hace semanas, esperando exactamente este formulario. También confirmó que **nada
en la base valida hoy que el saldo no baje de cero** (la regla "nunca rebasa la deuda" es sólo
autolimitación de Python en el batch), y que `arrastrar` hoy es un no-op total en el FIFO de
antigüedad (`calcular_lotes` ignora `monto == 0`).

**4 preguntas confirmadas con el usuario:**
1. "Cubrir" sobre la porción 6+ meses = **renovación**, no reduce el saldo — la deuda vieja
   desaparece del tramo 6+ y se recrea fechada hoy, mismo monto total.
2. "Arrastrar" y "Cubrir" son **exactamente el mismo mecanismo** — un solo botón.
3. El monto que RH puede mover se **topa a la porción de 6+ meses** de esa persona, no al saldo
   total.
4. **Motivo obligatorio** en las 3 acciones.

**Decisión de diseño propia, comunicada en el plan:** como "cubrir" ya tiene un significado real y
distinto (repago real en el batch automático), la UI llama a la acción unificada **"Renovar
antigüedad"** y persiste `tipo='arrastrar'` en la base — nunca `'cubrir'` desde este formulario,
para no crear un significado ambiguo del mismo `tipo` en dos contextos.

**Mecanismo de renovación, sin tocar `banco_antiguedad.py`:** el RPC inserta un par de filas en la
misma transacción — `(tipo='arrastrar', monto=-X)` seguido de `(tipo='arrastrar', monto=+X)`,
mismo `motivo`. `now()` es estable dentro de una transacción Postgres, así que las 2 filas quedan
con el mismo `creado_en` sin fijarlo a mano. El FIFO que ya existe en `calcular_lotes` procesa esto
correctamente tal cual está escrito hoy: la fila negativa consume el lote más viejo, la positiva
abre uno nuevo fechado hoy — la deuda sale del tramo 6+ sin ningún cambio de código en ese módulo.
"Descontar"/"Condonar" son una sola fila (`monto=-X`), reducción real.

**DDL (`db/ddl/68_*.sql`):** policy de INSERT nueva sobre `movimiento_de_saldo` (`tipo IN
('arrastrar','descontar','condonar')` — excluye `cubrir`/`generado_quincena`, reservados al batch
— más `autor_id = caller`, anti-suplantación) y RPC `fn_movimiento_de_saldo_manual_registrar`
(`SECURITY INVOKER`, la RLS de arriba es la autorización real). `db` corrigió 2 detalles de estilo
antes de aplicar: las funciones `personas.fn_caller_activo()`/`fn_caller_tiene_permiso()` sin
prefijo de esquema habrían fallado (`search_path` del rol `authenticated` no incluye `personas`),
y sobraba un `SECURITY INVOKER` explícito que ninguna otra función del proyecto escribe literal
(es el default). Ambas correcciones confirmadas contra el patrón real del proyecto antes de
aplicar.

**Hallazgo de seguridad real, encontrado por `backend` durante la implementación:** el endpoint
necesita leer `tiempo.banco_de_horas` (RLS exige `banco_de_horas_lectura` específico, sin `OR` con
`movimiento_de_saldo_edicion`) antes de poder escribir en `movimiento_de_saldo`. Con un solo
cliente `get_caller_client`, alguien con sólo el permiso de edición del ledger habría recibido un
404 falso en vez de la validación real. Hoy no pasa (los 3 puestos con `movimiento_de_saldo_edicion`
también tienen `banco_de_horas_lectura`), pero el código no debía depender de esa coincidencia.
Corregido con 2 clientes Supabase en el mismo endpoint: `service_role` para toda lectura de insumo
(incluida la reconstrucción del ledger de la respuesta final, extensión que `backend` hizo por
iniciativa propia al notar la misma fragilidad ahí), `caller` sólo para el INSERT real vía RPC.

**Backend**: validación en 2 capas — Python recalcula el desglose de antigüedad al momento del
submit (nunca confía en algo cacheado del frontend) y topa el monto contra `horas_fuera_ventana`;
el RPC sólo puede topar contra el saldo total como backstop grueso (no tiene el FIFO reconstruido,
duplicar esa lógica en SQL habría sido una tercera copia).

**Frontend**: formulario dentro de la fila expandible del ledger que ya tenía Banco de Horas (sin
pantalla ni ruta nueva) — select de acción, monto con `max` ligado a `horas_fuera_ventana`, motivo
obligatorio, éxito reemplaza el ledger cacheado y refresca la tabla principal. `frontend` encontró
un bug real en su propio mock de test (no en producción): un `Response` reusado entre la carga
inicial y el refetch posterior revienta porque el body sólo se lee una vez — arreglado con
`.clone()` en el mock.

## Qué se decidió

- "Renovar" persiste `tipo='arrastrar'`, nunca `'cubrir'` — evita un significado ambiguo del mismo
  valor en dos contextos del sistema.
- El tope de monto se valida en Python (fino, contra la porción 6+ meses) con el RPC como backstop
  grueso (contra el total) — no se reimplementa el FIFO en SQL.
- Dos clientes Supabase distintos en el mismo endpoint cuando lectura de insumo y escritura real
  tienen gates de permiso distintos, sin asumir que van a seguir acoplados para siempre.
- Sin pantalla ni ruta nueva — el formulario vive dentro del ledger expandible que ya existía.

## Qué quedó pendiente

- El futuro módulo de nómina que consumiría los movimientos `tipo='descontar'` no se construye acá
  — sólo se deja el dato bien registrado para cuando exista.
- `arrastrar`/`descontar`/`condonar` manuales no tienen tests de integración contra la BD real
  (todo mockeado) — primera vía de escritura real sobre esta tabla, vale la pena una prueba manual
  en vivo antes de dar por cerrado el flujo completo.

## Preguntas nuevas

-

## Nota para la retrospectiva

Tercera vez en el día que "explorar a fondo antes de plantear preguntas" evita un diseño
equivocado — acá el usuario mismo pidió el orden explícito ("revisa primero la lógica... las dudas
dímelas... luego planeas e implementas"), y la exploración encontró 2 hechos que habrían invalidado
cualquier plan hecho a ciegas: que hoy no hay ninguna vía de escritura, y que nada valida el saldo
mínimo en la base. Vale la pena seguir aplicando este orden (investigar → preguntar → planear)
como default para pedidos de negocio con lenguaje ambiguo, no sólo cuando el usuario lo pide
explícito.
