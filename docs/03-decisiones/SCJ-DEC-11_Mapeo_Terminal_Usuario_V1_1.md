# SCJ-DEC-11 · ¿Dónde vive el mapeo `employeeNo` ↔ persona de la terminal biométrica, y cómo se audita?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-10-05
**Última revisión:** 2026-10-06 (V1.1)

> **Cambio de versión (V1.0 → V1.1, menor):** se **refuerza y se precisa**, sin contradecir lo
> escrito, el principio de la captura biométrica: la huella se enrola **en el menú de la propia
> terminal** (decisión del usuario, 2026-10-06, opción B) y **ninguna plantilla biométrica sale del
> aparato**, ni hacia el Pi ni hacia el servidor. Se registran además la **custodia de la
> contraseña de administrador del aparato** (TI) y el **riesgo residual** del tramo Pi ↔ terminal
> (HTTP + Digest, sin TLS), con la condición que lo hace aceptable. Ver el punto 3 de la Decisión,
> los puntos 6 y 7 de "Riesgos aceptados" y "Cómo se verifica".

---

## Contexto

La terminal biométrica Hikvision DS-K1A8503EF-B reemplaza al lector R503Pro como aparato de
registro (`SCJ-PRO-11`). A diferencia del R503Pro, la terminal guarda sus propios usuarios y
huellas: cada usuario del aparato se identifica por un `employeeNo` (entero de hasta 8 dígitos) y
cada evento de acceso que reporta (`AcsEvent`) trae ese `employeeNo`, no un `persona_id`. Alguien
tiene que decidir **dónde se guarda la correspondencia `employeeNo` ↔ `persona_id`** y cómo queda
rastro de cada alta y baja de usuarios en el aparato.

El Raspberry Pi queda como **puente** entre la terminal y el servidor: no tiene pantalla propia, no
decide identidades y no es la fuente de verdad de nada. La terminal se alcanza por red local con la
interfaz ISAPI; el servidor es la única parte que conoce a las personas.

No hay respuesta obvia porque el mapeo toca tres cosas a la vez: la frontera entre subsistemas
(`SCJ-FRO-01`: sólo `persona_id` cruza a `tiempo`, ningún dato de identidad), la biometría (las
huellas nunca salen del aparato, pero su alta y baja sí hay que controlarlas) y la auditoría (una
baja que no queda registrada es una persona que sigue marcando sin que nadie lo sepa).

**Esquema congelado:** el esquema se congeló el 2026-09-25 (`SCJ-ACT-03`). Esta decisión agrega
tablas y permisos después de esa fecha, así que **RTB-App debe enterarse** antes de copiar el DDL
a su base: las tres tablas nuevas, dos permisos nuevos y un código de error nuevo (`SCJ11`/`SCJ12`)
son cambios que su backend tiene que conocer.

---

## Opciones consideradas

### Opción A — Mapeo sólo en el SQLite local del Pi
**A favor:** nada nuevo en el servidor; el Pi ya tiene una base local; cero cambios de esquema.
**En contra:** el servidor no sabe qué personas están enroladas ni en qué estado. Si el Pi se
reinstala o se roba, el mapeo se pierde y los `employeeNo` guardados en la terminal quedan
huérfanos. No hay bitácora central de altas y bajas. Recursos Humanos no tiene dónde ver ni
iniciar un enrolamiento.

### Opción B — Mapeo en el servidor, con el Pi como caché *(elegida)*
**A favor:** una sola fuente de verdad, auditable, que sobrevive a la pérdida del Pi. Recursos
Humanos opera el enrolamiento desde la aplicación. El Pi puede reconstruir su caché en cualquier
momento.
**En contra:** tablas, permisos y endpoints nuevos; el Pi depende de que el servidor responda para
procesar altas y bajas pendientes (el registro de marcas ya funciona igual, no cambia).

### Opción C — Mapeo en el servidor, pero el Pi escribe directo por RLS
**A favor:** menos código de backend; el Pi usaría el rol de Postgres `terminal_checador`
ampliado.
**En contra:** ampliar los privilegios de un aparato que está físicamente expuesto (`SCJ-PRO-11
§III`) para que lea y escriba tablas de enrolamiento. Un Pi comprometido pasaría de poder insertar
marcas a poder alterar el mapeo de identidades. RLS por fila no puede validar una transición de
estado completa.

### Opción D — Reutilizar permisos existentes (`persona_edicion`, `alta_personas_usuarios`)
**A favor:** no se crea ningún permiso nuevo.
**En contra:** `persona_edicion` y `alta_personas_usuarios` gobiernan datos de identidad y accesos
a la aplicación. Enrolar a alguien en el aparato es una acción biométrica distinta: quien puede
corregir un RFC no necesariamente debe poder dar de alta a una persona en la terminal. Además esos
dos permisos son heredables por jerarquía y éste no debe serlo (ver más abajo).

---

## Decisión

**Opción B**, con las siguientes piezas:

1. **El mapeo vive en `tiempo.terminal_usuario`** (una fila por alta de una persona en una
   terminal), y su **fuente de verdad es una bitácora inmutable**,
   `tiempo.bitacora_movimiento_terminal_usuario`. La tabla viva es `[CALCULADO]`: nadie la escribe
   directo; un trigger `SECURITY DEFINER` valida la transición y la sincroniza al insertar en la
   bitácora (mismo patrón que `puesto_permiso` ← `bitacora_movimiento_puesto_permiso`,
   `SCJ-PRO-05`).
2. **El `employeeNo` sale de una secuencia global** (`tiempo.seq_terminal_employee_no`), sin ciclo
   y sin reutilización: un `employeeNo` dado de baja nunca vuelve a asignarse, así ningún evento
   histórico del aparato apunta a otra persona.
3. **Ninguna plantilla biométrica sale del aparato, ni hacia el Pi ni hacia el servidor. La
   captura se hace en el aparato con intervención de la persona** *(V1.1: la persona se enrola en el
   **menú de la propia terminal**, frente a TI con RH presente, `SCJ-PRO-15`)*. **El Pi y el
   backend sólo manejan `employeeNo`, estado y conteo de huellas.** Ningún flujo remoto registra
   huellas, y **ninguna tabla, columna, log, cola, caché ni respaldo** de este repositorio, de la
   base, del Pi o del backend guarda `fingerData` ni plantillas: sólo el conteo
   (`huellas_capturadas`, 0–10). Es verificable por búsqueda de texto en el repositorio y por CI
   (ver "Cómo se verifica").
4. **El Pi accede al servidor por endpoints del backend, con una credencial propia de terminal**
   —no con el secreto JWT de Supabase—, y **las marcas también suben por el backend**. El Pi no
   toca la base de datos directamente. (Esto reemplaza el mecanismo de `SCJ-PRO-11 §III` original,
   que firmaba un JWT de Supabase con `role=terminal_checador`; ver `SCJ-PRO-11 V2.0`.)
5. **Una sola terminal por ahora**, pero el diseño admite varias: `tiempo.terminal` es una tabla,
   `terminal_usuario` referencia la terminal por clave, y el `employeeNo` es único por terminal.
   `tiempo.marca.terminal_id` **no** es FK a `tiempo.terminal`: esa columna también guarda puntos de
   captura manual (`SCJ-PRO-07`).
6. **Permisos nuevos, de acción:**
   - `terminal_usuario_lectura` — **heredable**: ver el mapeo y el estado de enrolamiento.
   - `terminal_usuario_edicion` — **NO heredable**: asignar una persona a una terminal y
     solicitar su baja. No es heredable porque es un permiso biométrico: que un jefe herede lo de
     su subordinado tiene sentido para ver, no para enrolar.

   Se otorgan por bitácora a "Responsable de Recursos Humanos", "Gerente General" y "Gerente o
   Encargado de TI" (este último es el puesto administrador y se incluye explícito, porque no
   recibe permisos nuevos solo).

### Transiciones

El trigger de la bitácora es el único que valida el estado. Cada fila de la bitácora es un
movimiento; el estado de `terminal_usuario` se deriva de ellos.

| Movimiento | Quién lo origina | Estado previo | Estado nuevo |
|---|---|---|---|
| `asignado` | Recursos Humanos (web) | ninguna alta no-`baja` de esa persona en esa terminal; terminal activa; persona `activo` | `pendiente_alta` (crea la fila viva y asigna el `employeeNo`) |
| `usuario_creado` | Pi, vía backend | `pendiente_alta` | `esperando_huella` |
| `huella_capturada` | Pi, vía backend | `esperando_huella` o `activo` | `activo`, fija `huellas_capturadas` (1–10) |
| `baja_solicitada` | Recursos Humanos (web) | cualquiera salvo `pendiente_baja` o `baja` | `pendiente_baja` |
| `baja_confirmada` | Pi, vía backend | `pendiente_baja` | `baja` |
| `error` | Pi, vía backend | cualquiera salvo `baja` | sin cambio; llena `error_detalle` |

`baja_solicitada` se acepta también desde `pendiente_alta` (alguien se asignó por error y nunca
llegó a crearse en el aparato). La terminal activa sólo se exige en `asignado`: una terminal
dada de baja aún debe poder recibir bajas y reportes. Un movimiento válido distinto de `error`
limpia `error_detalle`.

### Códigos de error

Dos `ERRCODE` propios, cada uno con un `HINT` estable para que el backend distinga el caso sin leer
el texto:

| `ERRCODE` | `HINT` | Significa |
|---|---|---|
| `SCJ11` | `transicion_invalida` | Transición inválida, o la fila viva no coincide con el movimiento |
| `SCJ12` | `alta_duplicada` | La persona ya tiene un alta vigente en esa terminal |
| `SCJ12` | `persona_no_activa` | La persona no existe o no está `activo` |
| `SCJ12` | `terminal_no_valida` | La terminal no existe o no está activa |

---

## Por qué

Un solo argumento inclinó la balanza: **el enrolamiento es un acto de autorización sobre una
persona, y el servidor es el único que conoce a las personas.** Dejar el mapeo en el Pi (opción A)
pierde la auditoría y la recuperación; darle al Pi escritura directa (opción C) amplía justo el
privilegio que `SCJ-PRO-11 §III` quería mantener mínimo. Con la bitácora inmutable como fuente de
verdad, una baja nunca desaparece sin dejar rastro de quién la pidió.

---

## Consecuencias

**Se vuelve fácil:** saber qué personas están enroladas y en qué estado; reconstruir la caché del
Pi; auditar quién dio de alta o baja a quién, y cuándo.

**Se vuelve difícil:** corregir un movimiento mal registrado. La bitácora es inmutable por
`UPDATE`/`DELETE`/`TRUNCATE` incluso para `service_role` (grants, RLS y triggers en 3 capas); un
`baja_solicitada` por error no se borra, se compensa con movimientos posteriores. Queda además un
residual aceptado: el dueño de la base puede `DROP`/`DISABLE TRIGGER`, como en toda bitácora del
proyecto.

**Queda cerrado para siempre:** un `employeeNo` asignado no se reutiliza. Si la secuencia se agota
(99 999 999), falla en vez de reciclar números.

### Riesgos aceptados y notas para backend

1. **Persona dada de baja en la empresa.** Cuando una persona pasa a `inactivo` en `personas`, el
   backend debe emitir `baja_solicitada` para su alta en la terminal; el esquema no lo hace solo
   (cruzar de `personas` a `tiempo` por trigger violaría `SCJ-FRO-01`). Mientras no ocurra, esa
   persona puede seguir marcando en el aparato. El ingestor de marcas debe **señalar** (no
   rechazar) las marcas de una persona inactiva, con el mecanismo que ya existe
   (`motivo_revision = 'persona_inactiva'`).
2. **Sin doble autorización.** Quien tiene `terminal_usuario_edicion` puede enrolar a **cualquier**
   persona activa, sin que un segundo usuario lo apruebe. Se acepta porque el permiso se limita a
   tres puestos y porque la bitácora deja constancia de quién lo hizo (`registrado_por`, atado por
   RLS a `auth.uid()`: nadie puede atribuir un movimiento a otra persona).
3. **Mapeo de errores.** El backend debe traducir `23503` (la persona no tiene fila en
   `tiempo.persona`: la frontera no se sincronizó), `23505` (carrera entre dos altas
   simultáneas de la misma persona), `SCJ11` y `SCJ12` a `409`/`422`, **sin retransmitir el texto
   del error al Pi**.
4. **Texto libre acotado.** `detalle` y `error_detalle` tienen un `CHECK` de 500 caracteres. El
   backend debe sanear y truncar antes de insertar, y **nunca** meter cuerpos crudos de respuestas
   ISAPI ni encabezados HTTP (pueden traer credenciales, series o datos de otros usuarios).
5. **Residual del dueño.** `TRUNCATE`, `DROP TABLE`, `DROP TRIGGER` y `DISABLE TRIGGER` por un
   superusuario siguen siendo posibles (ver arriba).
6. **Custodia de la contraseña de administrador del aparato *(V1.1, decisión del usuario,
   2026-10-06)*.** **TI** la guarda y es quien hace el enrolamiento frente a la persona, **con RH
   presente**; **RH no la conoce**. Es distinta de la credencial que usa el Pi
   (`SCJ-DEC-12 §1`), que vive **sólo en el `.env` del Pi**. Quien tiene la contraseña de
   administrador puede crear usuarios, **leer y escribir huellas** directamente en el aparato
   (incluida la lectura de `fingerData` por ISAPI): por eso la custodia es de TI y el
   procedimiento (cambio de la contraseña por defecto, bloqueo por intentos fallidos, no
   reutilizarla en el Pi) está en `SCJ-PRO-15 §IV.5`.
7. **Riesgo residual del tramo Pi ↔ terminal: HTTP + Digest, sin TLS *(V1.1)*.** La terminal habla
   ISAPI por HTTP con autenticación Digest; quien tenga acceso a ese tramo puede observar el tráfico
   y atacar la contraseña por fuerza bruta. **Se acepta con una condición:** el tramo debe estar
   **aislado física o lógicamente — punto a punto entre el Pi y la terminal, sin acceso desde la LAN
   ni desde Internet, con los servicios de la terminal que no se usan apagados**
   (`SCJ-PRO-15 §IV.6`). Sin ese aislamiento, el riesgo **no** está aceptado. Es independiente de
   `SCJ-DEC-12 §7` (HTTPS obligatorio entre el Pi y el backend).

---

## Cómo se verifica

- `db/verificar_ddl.sql`, secciones de la fase "Terminal Hikvision": consultas de violaciones,
  todas con resultado esperado de 0 filas (RLS habilitada; privilegios de tabla y columna contra
  una lista blanca; secuencias sin privilegios; funciones de trigger sin `EXECUTE` para nadie;
  `SECURITY DEFINER` y `search_path` fijos; triggers presentes y habilitados; policies
  comparadas por comando y rol; heredabilidad de los permisos; otorgamiento a los puestos
  acordados).
- Ensayo del 2026-10-05 contra la base real dentro de `BEGIN … ROLLBACK`: 61 casos, 61 aprobados
  (cadena completa de movimientos, transiciones inválidas, persona/terminal no válidas,
  inmutabilidad como `service_role` y como dueño, RLS de lectura y escritura, `CHECK` de largo y de
  conteo de huellas), sin dejar objetos nuevos al terminar.
- *(V1.1)* **Ninguna plantilla biométrica en el repositorio, el backend ni el Pi:** una búsqueda de
  texto de `fingerData` (sin distinguir mayúsculas) y de las rutas ISAPI que la devuelven
  (`CaptureFingerPrint`, `FingerPrintCfg`) que **falle en CI** si aparece en el código del
  backend, del puente o de sus pruebas — salvo en la lista blanca de documentos que **prohíben**
  su uso (esta decisión, `SCJ-DEC-12`, `SCJ-PRO-15`). Complemento: inspección de las columnas de la
  base (`db/verificar_ddl.sql`: ninguna columna de tipo `bytea` ni con nombre de plantilla/huella
  en `tiempo`/`personas`).
- *(V1.1)* **Lista de servicios habilitados de la terminal**, revisada y firmada por TI
  (`SCJ-PRO-15 §IV.6`): sólo los necesarios para el Pi; el resto apagado.

---

## Revisión posterior a la implementación

*(se llena al construir los endpoints del backend y el puente del Pi, no antes)*
