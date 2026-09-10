# Campos de más en los mockups — revisar en la versión final para la empresa

Los mockups del módulo Personas se generaron con IA de diseño y se embellecieron con campos
plausibles de RH que **no existen todavía en el modelo de datos real** (`RTB-APP_DIAGRAMA_V2`,
`personas.persona` y `personas.expediente`). Se recortaron del mockup para que solo muestre lo que
ya hay en base de datos, pero quedan aquí anotados por si conviene agregarlos de verdad cuando se
mire el sistema real de la empresa.

## `11-alta-persona` (formulario de alta)

**Datos personales** — de más: `sexo`, `estado civil`. `persona` real solo tiene:
`primer_nombre`, `segundo_nombre`, `apellido_paterno`, `apellido_materno`, `curp`, `rfc`, `nss`,
`fecha_nacimiento`.

**Alta laboral** — de más, no existen en `persona` ni `expediente`: `número de empleado`,
`tipo de movimiento` (ese concepto es de `bitacora_movimiento_persona`, no de esta pantalla),
`centro de trabajo`, `correo institucional` (el correo se maneja en Auth al dar de alta el
*usuario*, `SCJ-PRO-01` paso A2 — no es campo de la persona/expediente). `tipo_contrato` sí existe
en `expediente` (enum real: `indefinido` / `prestacion_servicios` / `por_proyecto` — no
"Indeterminado").

**Puesto/área en esta misma pantalla** — de más: asignar puesto en el alta de persona no está
diseñado todavía, es el proceso aparte de "asignaciones, puestos, áreas y permisos" que el usuario
dejó pendiente (candidato a `SCJ-PRO-03`).

**Referencia de expediente** — de más: `tipo de resguardo`, `ubicación física`, y el checklist de
documentos individuales (acta de nacimiento, CURP, comprobante de domicilio, constancia de
situación fiscal, contrato individual) cada uno con estatus propio cargado/pendiente.
`expediente` real solo tiene **una** columna `documento_ref` (`varchar(50)`, formato
`RTB-__-__`) — una sola referencia, no una tabla de documentos. El archivo en sí se resuelve con
un bucket de Supabase Storage (confirmado con el usuario), pero eso es implementación detrás de
ese único campo, no una tabla nueva.

## `10-ficha-persona` (ficha de detalle)

**Contacto de emergencia** — de más por completo. No existe ninguna tabla ni campo para esto en el
modelo. Si se quiere en la versión real, es una tabla nueva a diseñar (contacto, teléfono, tipo de
sangre, domicilio, parentesco).

**Expediente** — mismo caso que en `11`: el checklist de documentos con fechas y estatus
individuales no tiene respaldo real, solo existe `documento_ref`.

**Puesto y área actuales** — de más **por completo**, incluido `jefe inmediato`: puesto, área,
departamento y asignación quedaron **fuera de alcance del proyecto a propósito** (ver `CLAUDE.md`),
no es un módulo "pendiente de diseñar". Las tablas `asignacion`/`puesto`/`departamento` **no
existen** en `db/ddl/` — una versión anterior de esta nota decía lo contrario, era un error.

**Histórico de movimientos** — mismo caso por consistencia: el bloque separado "Historial de puesto
y área" del mockup tampoco se implementa, misma razón (puesto/área fuera de alcance a propósito).
`bitacora_movimiento_persona` **solo** registra los 3 valores de `estado`
(alta/suspensión/reactivación/baja) — no hay ninguna tabla `asignacion` con la que "mezclar".

**Estado actual / Asistencia** (banco de horas, puntualidad, incidencias) — matiz: el subsistema
Tiempo (`saldo`, `ausencia`, `excepcion`, `marca`) sí tiene **respaldo de datos** real en el DDL, ya
cerrado — pero **cero superficie de API**: `backend/app/main.py` sólo registra los routers de
personas/usuarios/movimientos. No es un campo inexistente en el modelo, es un módulo entero sin
endpoints todavía — por eso queda fuera de esta tanda de frontend, no por falta de diseño de datos.

## `12-alta-usuario` (alta de usuario)

**Card de persona seleccionada** — de más: `número de empleado` (`No. 10428`), `puesto`
(`Analista de Nómina`), `área` (`Administración`). Mismo caso que en `11`/`10`: no existen en
`persona` ni en ninguna tabla del modelo actual.

**Tabla "Invitaciones pendientes"** — de más por completo: no hay endpoint que liste
invitaciones (`POST /api/usuarios` sólo crea). Listarlas, reenviarlas o mostrar su estado
(`Pendiente`/`Por expirar`) requeriría un endpoint nuevo sobre `auth.users`/GoTrue que no existe
hoy.

**Layout de navegación superior** (barra horizontal con "Jornada / Personas / Reportes /
Configuración" en vez del sidebar) — el mockup usa un layout distinto al `AppShell` real del
proyecto (sidebar fijo). Se descarta: cambiar el layout global es su propia tanda, no de esta
pantalla puntual.

## `13-cambio-estado` (cambio de estado)

**Card de persona** — mismo caso que `12`: `No. 10428 · Analista de Nómina · Administración` de
más (número de empleado/puesto/área no existen).

**Campos "Fecha de efecto" y "Reincorporación estimada"** — de más:
`personas.bitacora_movimiento_persona` (`db/ddl/05_personas_estructura.sql`) sólo tiene
`fecha_efectiva timestamptz NOT NULL DEFAULT now()`, fijada por el servidor al insertar — no hay
columna para capturar una fecha de efecto distinta a "ahora", ni una fecha de reincorporación
estimada. Si se quiere de verdad, es un cambio de esquema (agregar columnas), no sólo de UI.

**"Registra" (`María Rentería · RH`)** — el nombre propio con rol/departamento no existe; lo que
sí devuelve el backend (`B3` de `SCJ-PRO-02`) es `registrado_por_nombre` = `nombre_usuario`
(ej. `mariana.alcantara`), sin rol — mismo caso ya documentado para la bitácora de movimientos.

**Panel lateral "Resumen del cambio" / "Al confirmar" / "Historial de estados"** — panel lateral
nuevo completo, no es un ajuste cosmético de la pantalla existente. El "Historial de estados"
además depende de la pantalla de bitácora (`14-bitacora-movimientos`, todavía no implementada).
Layout de navegación superior — mismo caso que `12`, descartado.

## `14-bitacora-movimientos` (bitácora de movimientos)

**Folio** (`MOV-0007` en el mockup) — de más: `bitacora_movimiento_persona` no tiene columna
secuencial/de negocio, sólo `id uuid`. No hay folio legible para mostrar.

**Origen** (`Panel de personas` / `Importación`) — de más: esa columna no existe en
`bitacora_movimiento_persona`. Sí existe un concepto de origen en `tiempo.marca` (terminal/app),
pero es de un esquema distinto y no aplica acá.

**Estado `Prealta` y pseudo-estado "Sin registro"** — de más: el `CHECK` real de
`personas.persona.estado` sólo admite `activo` / `baja_definitiva` / `suspension`. No existe
"prealta" como estado, y "Sin registro" no es un estado sino la ausencia de movimiento previo — se
representa sin flecha en el primer registro (`alta`), no como un pseudo-valor.

**Columnas `estado_anterior`/`estado_nuevo`** — de más como *columnas*: no existen en la tabla, se
derivan en el cliente (`frontend/src/lib/movimientos.ts`) recorriendo los movimientos en orden
ascendente. El mapeo espeja exactamente `personas.fn_bitacora_sincroniza_persona`
(`db/ddl/05_personas_estructura.sql`): `alta`→`activo`, `suspension`→`suspension`,
`reactivacion`→`activo`, `baja_definitiva`→`baja_definitiva`.

**"Exportar bitácora"** — de más: no hay endpoint ni mecanismo de exportación (CSV/PDF) en ningún
punto del backend.

**Rol del autor** (`· Recursos Humanos` junto al nombre) — de más: no existe tabla de rol/puesto.
Lo que sí devuelve el backend (`B3`) es `registrado_por_nombre` = `nombre_usuario`
(ej. `mariana.alcantara`), sin rol — mismo caso ya documentado para `13-cambio-estado`.

**"Registro inmutable"** — **esta sí es cierta**, a partir de `db/ddl/09_personas_bitacora_inmutable.sql`
(aplicado 2026-09-04): revoca `UPDATE`/`DELETE` a `anon`/`authenticated`, reemplaza la policy `FOR
ALL` por `SELECT`+`INSERT` explícitas, y agrega un trigger `BEFORE UPDATE OR DELETE` que aborta
incluso para `service_role`. Antes de este DDL la tarjeta mentía (la policy `FOR ALL` de
`06_personas_rls.sql` y el `GRANT ALL` de `08_personas_permisos.sql` no bloqueaban nada).

## `09-directorio-personas` (directorio)

**Correo** y **número de empleado** — de más: no existen en `personas.persona`. El correo vive en
`auth.users`/`personas.usuario`, no en la persona.

**Filtros de Área/Puesto** — de más: puesto/área fuera de alcance a propósito (mismo caso que en
`10`/`11`/`12`/`13`).

**Paginación de servidor** (`"Mostrando 8 de 248"`) — de más: el filtrado/búsqueda/métricas de esta
tanda es 100% client-side (volumen de proyecto académico); no hay paginación real de servidor.

**"Exportar"** — de más, mismo caso que en `14`: no hay endpoint de exportación.

**Menú `⋮`** (acciones masivas por fila) — de más: no hay acciones de ese tipo implementadas ni
endpoints que las respalden.

## `08-error-cuenta-suspendida` (cuenta suspendida)

**Datos de contacto de RH/Sistemas/Administración/Dirección** — no son datos "de más" del mockup
(la empresa ficticia sí los necesita mostrar), pero **no vienen de una tabla ni de un endpoint de
configuración**: son variables de entorno de build del frontend (`VITE_CONTACTO_RH_CORREO`,
`VITE_CONTACTO_SISTEMAS_CORREO`, `VITE_CONTACTO_ADMINISTRACION_CORREO`,
`VITE_CONTACTO_DIRECCION_CORREO`, ver `frontend/.env.example` y `CLAUDE.md`) — no hardcodeadas en
el código de la página como se planteó originalmente, pero tampoco dinámicas: cambiar un correo en
producción exige rebuild del frontend (`--build`, no basta reiniciar el contenedor), mismo gotcha
que el resto de las `VITE_*` del proyecto.
