# 2026-10-22 · SCJ-PRO-12 / ERD — diagrama vigente V3.0 y primer cierre en hora de México

**Participantes:** Diego; `orchestrator` con `db`, `Asistente` y `raspi-pruebas` (team-orchestrator).
**Duración:** 21 y 22 de octubre de 2026.

---

## Qué se hizo

### 1. ERD contra la base real y diagrama vigente «Diagrama RTB-CRM V3.0»
- **Catálogo real** (lectura aprobada por Diego):
  - 37 tablas: 11 en `personas` y 26 en `tiempo`;
  - 285 columnas y 53 FK;
  - coincide exacto con el diccionario V1.6.
- **Tres ERD generados en Lucid** a partir del catálogo: personas, tiempo y terminales. Los vínculos entre diagramas se dibujaron como cuadros sustitutos.
- **Diagrama único:** Diego los juntó en «Diagrama RTB-CRM V3.0» (Lucid `7ce7bbf7-f91c-404d-addd-3bfe87796669`).
- **Verificación del V3.0 en tres rondas,** contra el catálogo:
  - sobraba el cuadro sustituto de `personas.usuario`;
  - 5 líneas salían o llegaban a una columna equivocada (`terminal.ultimo_contacto_en`, `dia.estado`, `banco_de_horas.vivo_desde`, `terminal_usuario.huellas_capturadas`, `corrida_batch.id`);
  - faltaban 5 relaciones;
  - una línea estaba pegada a otra línea en vez de al cuadro, y con los extremos invertidos.
- **Estado final:** 38 cuadros (las 37 tablas más `auth.users`) y 53 relaciones, todas uno a muchos salvo `auth.users` → `personas.usuario`, que es uno a uno.
- **P-100 cerrada** (Asistente):
  - el vigente es el V3.0;
  - RTB-ESP-01 pasa a V1.4 y SCJ-MOD-01 a V1.2, en la bóveda;
  - «RTB-APP_DIAGRAMA» y «RTB-APP_DIAGRAMA_V2» quedan obsoletos, pero Diego decidió no borrarlos;
  - los ERD separados del 15 y del 21-oct los borra Diego a mano, porque el MCP de Lucid no elimina documentos.

### 2. Aclaración del modelo: `auth.users`, `personas.usuario` y `tiempo.persona`
- **El alta de persona** (`fn_persona_crear`) crea `personas.persona`, y el trigger de `43_` crea `tiempo.persona` con el mismo uuid. Entre las dos no hay FK física, a propósito, por la frontera SCJ-FRO-01.
- **«Crear acceso a Kairos»** es opcional. Invita el correo, Supabase crea `auth.users` y después se inserta `personas.usuario(auth_user_id, persona_id)`.
- **En consecuencia,** toda persona tiene su `tiempo.persona`, pero no toda persona tiene usuario.
- **Columnas de autor:**
  - `registrado_por` apunta a `personas.usuario`;
  - `autor_id`, `aprobador_id`, `revisado_por` y `creado_por` apuntan a `tiempo.persona`.

### 3. P-180: primer cierre automático en hora de México (verificado)
- **Registros del Pi** (`raspi-pruebas`, solo lectura):
  - la imagen del backend es posterior a `7a97c81` y `e4c8c8d`;
  - el scheduler tiene `ZONA_MEXICO`;
  - no hay errores SCJ27, SCJ15 ni 42501.
  - Pero los batches solo escriben en el registro cuando fallan, así que el registro no prueba que corrieron.
- **Consulta de solo lectura,** corrida por Diego con su propio `psql` dentro de una transacción `READ ONLY` con `ROLLBACK`:
  - la corrida 77 de `cierre_dia` arrancó el 22-oct a las 03:00:00 (México), procesó el 21-oct y salió exitosa: 3 días cerrados y 0 bloqueados;
  - la corrida 78 de `de_confianza` arrancó a las 03:00:02, procesó el 22-oct y salió exitosa;
  - las corridas 68, 75 y 76 arrancaron a las 21:00 de México del día anterior: así se ve el error de zona horaria ya corregido;
  - `dias_cierre_incompleto.sql` dio 0 en las 4 secciones;
  - 0 marcas del 21-oct de las 18:00 en adelante quedaron con excepción `dia_cerrado`;
  - queda 1 alerta `fuera_de_horario` pendiente en un día cerrado, que se atiende con «Descartar alerta» (`125_`).
- **P-180 cerrada** en Notion y en la bóveda.

## Qué se decidió

- El ERD vigente es «Diagrama RTB-CRM V3.0» en Lucid, verificado contra el catálogo real con DDL `00`–`125`.
- «RTB-APP_DIAGRAMA» y «RTB-APP_DIAGRAMA_V2» se conservan como obsoletos; no se borran.
- El `KeyError: 5` de `/api/sesion` queda como nota para el futuro (P-193), no se investiga ahora.

## Qué quedó pendiente

- **P-193:** `KeyError: 5` sin capturar en `GET /api/sesion` (21-oct, 11:31 de México), junto con errores transitorios de la base (`RemoteProtocolError`/`LocalProtocolError`) que se repitieron el 22-oct a las 09:03. Prioridad baja, vence 30-nov.
- **Otras anomalías vistas en el registro, sin tarea propia:**
  - `GET /api/terminal/mapa` devolvió 500 con sqlstate 504 el 21-oct a las 14:46;
  - `GET /api/dias/pendientes-corte-quincenal` tardó 5.2 s.
- **ERD separados viejos en Lucid:** Diego los borra a mano.
- **Contenido de RTB-ESP-01 §IV.3:** no se cotejó contra el V3.0; solo se cambió la referencia.
- **Sigue abierto lo del 21-oct:**
  - corte de septiembre, bloqueado por la ausencia #35;
  - P-181, capturas de la guía de huella;
  - P-187, firmas del acta;
  - P-055 y P-182, `CURRENT_DATE` en UTC.

## Preguntas nuevas

- ¿Conviene que los batches registren una línea INFO al terminar? Hoy el registro del contenedor no basta para saber si corrieron.

## Nota para la retrospectiva

- **Una sesión con un bloqueo de permisos no se rodea.** El clasificador de `db` negó la lectura a la base aunque Diego la había aprobado. La solución fue darle a Diego un archivo `.sql` de solo lectura para que lo corriera él con `!`, no pasarle la consulta a otra sesión.
- **«Sin errores en el registro» no es lo mismo que «corrió bien»** cuando el código solo registra fallos. La evidencia real está en `tiempo.corrida_batch`.
- **Al revisar un ERD juntado a mano,** comparar las relaciones como «columna FK → columna PK» contra el catálogo. Visualmente, una línea pegada a otra línea o con la cardinalidad invertida se ve conectada.
