# Diseño v4 — interruptor de la activación por huella (`terminal_inferir_huella_activa`)

**Estado:** diseño final consolidado (v4), aprobado por `security` en lo técnico; la decisión de producto «activo hasta» la confirma el usuario (mientras tanto se asume SÍ). **No hay SQL escrito, no hay ensayos corridos, no hay nada aplicado.** Este documento es la única fuente para escribir `97_` y `98_`.
**Fecha:** 10 de octubre de 2026. **Autor:** sesión `db`. **Revisión:** `security` (v1 a v3, ajustes A1-A3, P1-P5, D1-D4), `orchestrator`.
**Documentos relacionados:** `db/ddl/94_`, `95_`, `96_` (huella sin conteo y logs sin identidad, aplicados), `db/ddl/89_` (configuración de terminales), `db/ddl/88_` (consentimiento y permiso `terminal_config_edicion`), `CLAUDE.md` (gotchas de `CREATE OR REPLACE`, RLS, bitácoras inmutables).

---

## 1. Qué problema resuelve y qué no

Desde `95_`, `fn_marca_terminal_registrar` activa una alta que sigue en `esperando_huella` cuando llega la **primera marca verificada por huella** de ese empleado (movimiento `huella_inferida`). Esa evidencia descansa en la honestidad del puente: el campo `modo_verificacion = 'huella'` lo manda el puente, y el servidor no puede comprobarlo. Un puente comprometido (o un backend con un defecto) podría activar altas, y con ello evitar su caducidad, sin que haya huella enrolada.

El interruptor deja esa decisión **en el servidor, apagada por omisión**, y exige que encenderla sea un acto humano deliberado, con nota, con vencimiento, con consentimiento vigente y con rastro inmutable.

**Lo que protege:** contra el puente (Pi), contra un defecto o un filtro mal puesto del backend, y contra un encendido accidental o olvidado.
**Lo que NO protege (riesgos residuales aceptados, D3 y D4):** quien tenga la llave de `service_role` puede escribir directamente en `tiempo.parametro` (60_ solo revocó UPDATE/DELETE a `anon` y `authenticated`); quien sea dueño o superusuario puede desactivar triggers o fijar variables de transacción. El diseño no lo impide: lo **registra y lo hace visible** (anomalía «cambio sin nota», lector que apaga el interruptor ante cualquier anomalía) y el verificador comprueba que los triggers existan y estén habilitados.

---

## 2. Decisiones tomadas (resumen)

| Id | Decisión | Estado |
|---|---|---|
| Orden | `97_` completo en un archivo y una transacción; luego `98_`; luego, solo con la primera alta real **supervisada**, el usuario pone el interruptor en 1 | Aprobado |
| D1 | Las dos claves van **fuera** del catálogo `fn_terminal_config_catalogo()`; tienen su **propio lector de estado efectivo** de solo lectura | Aprobado |
| D2 | «Activo hasta»: SÍ, dentro de `97_` y `98_`, con tope de 30 días aplicado también al LEER | Aprobado técnicamente; confirma el usuario |
| D3 | La nota viaja por variable de transacción; refuerzo: segunda variable con `txid_current()` que el trigger compara; ambas se limpian al terminar | Aceptado |
| D4 | Quien tenga `service_role` puede escribir la fila: queda registrado y visible; incluye el `DELETE` de la fila (lo registra el trigger; el lector lo lee como apagado) | Aceptado |
| P1 | «Vigente» = `vigente_desde <= hoy_utc` y (`vigente_hasta` nulo o `>= hoy_utc`); **cero o más de una** fila vigente por clave ⇒ apagado | Aprobado |
| P2 | **Una sola** definición del estado efectivo, para el RPC de marcas, el backend y el tablero; nadie la reimplementa | Aprobado |
| P3 | El backend consulta ese estado efectivo (no la fila cruda), falla cerrado; descartar `modo_verificacion` pasa a ser optimización | Aprobado |
| P4 | La función dedicada rechaza ENCENDER si no hay consentimiento biométrico vigente publicado o si ninguna terminal está activa | Aprobado |
| P5 | Ensayos extra (sección 9) | Aprobado |
| Trigger | Auditoría **estrecha**: solo las dos claves del interruptor; auditar las otras cinco `terminal_*` queda como mejora opcional posterior | Aprobado |

---

## 3. Piezas de `97_` (un archivo, una transacción)

`97_` no puede aplicarse a medias: sin la función dedicada, la bitácora y el trigger, alguien con `terminal_config_edicion` podría encender el parámetro por la ruta genérica sin nota ni rastro, y el backend lo leería. Por eso todo va junto y el interruptor nace en `'0'`.

### 3.1 Siembra (idempotente, molde de `89_`)
- `terminal_inferir_huella_activa` = `'0'`, vigencia desde `2026-01-01`, sin cierre, `registrado_por` nulo.
- `terminal_inferir_huella_hasta` = una fecha centinela **ya vencida** (`1970-01-01T00:00:00Z`), misma vigencia. Se siembra para que ambas claves tengan siempre una vigencia que versionar y para que la invariante «una sola vigencia activa por clave» valga para las dos. Con el valor `'0'` el centinela es inerte; con el centinela, aun un `'1'` escrito a mano queda apagado por vencido.

### 3.2 Restricciones de formato en `tiempo.parametro`
- `ck_parametro_inferir_huella_activa`: si la clave es la del interruptor, el valor es exactamente `'0'` o `'1'`.
- `ck_parametro_inferir_huella_hasta`: si la clave es la de vencimiento, el valor es un **timestamp ISO estricto con zona**: fecha `AAAA-MM-DD`, la letra `T`, hora `HH:MM:SS` (fracción opcional de 1 a 6 dígitos) y zona `Z` o `±HH:MM`, con rangos válidos de mes, día, hora, minuto y segundo expresados en el propio patrón. Rechaza fechas sin zona, sin hora, con espacio en vez de `T`, texto libre, vacío y nulo. No usa conversiones dependientes de la sesión (el patrón es puro texto); la lectura convierte dentro de un bloque con excepciones.
- Ambas restricciones se validan contra las filas existentes (solo las recién sembradas).
- En los ensayos las restricciones se **sueltan dentro de la transacción** para simular filas inválidas; en producción es imposible guardar esos valores.

### 3.3 Bitácora de configuración `tiempo.bitacora_config_terminal` (append-only)
Columnas: identificador, clave, operación (`INSERT`, `UPDATE` o `DELETE`), valor anterior, valor nuevo, nota (nula si no vino de la función), `registrado_por` (uuid, **sin clave foránea**: una bitácora inmutable con FK impediría borrar cuentas), rol del JWT (`authenticated`, `service_role` o nulo), usuario de sesión (`session_user`), indicador `via_funcion` (calculado por el trigger, no recibido), identificador de transacción (`txid`) y `creado_en` con hora exacta.
- Inmutable por trigger: `UPDATE`, `DELETE` y `TRUNCATE` rechazados, incluso para el dueño.
- RLS habilitada. `REVOKE ALL` a `anon`, `authenticated` y `service_role` y después `SELECT` a `authenticated` (policy: persona activa con `terminal_config_edicion` o `terminal_usuario_lectura`) y a `service_role`. **Nadie tiene `INSERT`**: solo el trigger (como dueño). `REVOKE UPDATE, DELETE, TRUNCATE` explícitos desde el principio (gotcha de `CLAUDE.md`: el `ALTER DEFAULT PRIVILEGES` de 38_ da `GRANT ALL` a tablas nuevas y el `GRANT` es aditivo).
- Inventario de RLS en la cabecera del archivo (regla de `CLAUDE.md`).

### 3.4 Trigger de auditoría sobre `tiempo.parametro` (A2)
- `AFTER INSERT OR UPDATE OR DELETE`, por fila, función `SECURITY DEFINER`, `search_path = tiempo, pg_temp`, `EXECUTE` para nadie.
- **Filtro estrecho:** solo actúa si la fila es de `terminal_inferir_huella_activa` o `terminal_inferir_huella_hasta`.
- Registra: `INSERT` (valor nuevo; valor anterior = el de la vigencia previa), `UPDATE` **solo si cambia el valor** (el `UPDATE` que únicamente cierra `vigente_hasta` no genera ruido) y `DELETE` (valor anterior).
- Por eso un `UPDATE`, `INSERT` o `DELETE` directo hecho con `service_role`, con `psql` o por el dueño **deja fila**, con su rol, su usuario de sesión y su hora.
- La nota llega por una variable de transacción que **solo fija la función dedicada** y limpia al terminar. Refuerzo (D3): la función fija una segunda variable con `txid_current()`; el trigger solo acepta la nota si ese valor coincide con su propia `txid_current()` (una variable fijada en otra transacción no sirve). Una escritura directa queda con nota nula y `via_funcion = falso`.
- La anomalía del tablero **no depende de una bandera falsificable**: «una fila con valor nuevo `'1'` y nota nula o de menos de 10 caracteres es una activación hecha fuera de la función» (la función exige la nota, así que esa fila solo puede venir de una escritura directa).

### 3.5 Función dedicada `fn_terminal_inferir_huella_cambiar(p_activa, p_nota, p_hasta)`
- `SECURITY DEFINER`, `search_path = tiempo, personas, pg_temp`. `EXECUTE` solo `authenticated` (el backend la llama con el cliente del caller); `REVOKE` a `PUBLIC`, `anon` y `service_role`.
- **Gate dentro:** persona activa y permiso `terminal_config_edicion` (no heredable; solo «Gerente o Encargado de TI» y «Gerente General»). Sin ello: `42501 / sin_permiso`.
- **Encender** (`p_activa` verdadero) exige, en este orden:
  1. Nota de **al menos 10 caracteres ya saneados** (se quitan los mismos invisibles y separadores que limpia `92_`; `22023 / nota_requerida`).
  2. `p_hasta` obligatorio, mayor que ahora y **a lo más 30 días** hacia adelante (`22023 / hasta_invalido`).
  3. **P4:** existe un texto de consentimiento biométrico **vigente y publicado** (no provisional) en `tiempo.terminal_consentimiento` (`SCJ16 / sin_consentimiento_vigente`) y **al menos una terminal activa** (`22023 / terminal_no_activa`).
- **Apagar** no exige nota; deja el valor en `'0'` y devuelve la fecha de vencimiento al centinela vencido en la misma transacción.
- **Renovar** (encender cuando ya está encendido y vigente): permitido con nota nueva y `p_hasta` nuevo (deja su fila de auditoría); si el valor y el vencimiento no cambian, devuelve `sin_cambio` sin escribir ni auditar.
- **Ambas claves se escriben en la misma transacción de la función**, en orden fijo, con `FOR UPDATE` sobre sus vigencias activas y un lock de transacción para serializar cambios simultáneos; versionado igual que `89_` (borde inclusivo; el mismo día corrige en sitio), pero con «hoy» = `(now() AT TIME ZONE 'UTC')::date` explícito (ver 4.3).
- Devuelve el **estado efectivo** (llamando al lector único de la sección 4), no una copia.

### 3.6 `fn_terminal_config_actualizar` (CREATE OR REPLACE desde la definición VIGENTE de `89_`)
Tras el gate de permiso y antes de consultar el catálogo: rechaza las dos claves del interruptor con `22023 / clave_no_editable`, incluso para quien tiene permiso. Repite `SECURITY DEFINER`, `search_path = tiempo, personas, pg_temp`, `REVOKE` a `PUBLIC`, `anon`, `authenticated`, `service_role` y `GRANT` solo a `authenticated`. Diff literal contra `89_` (un hunk). Como las claves están fuera del catálogo ya serían rechazadas por construcción; el guard explícito evita que un alta futura del catálogo por descuido reabra la ruta.

### 3.7 `fn_parametro_actualizar_valor`
Sin cambios: `89_` ya rechaza cualquier clave `terminal_%` con `SCJ17 / clave_reservada`. El backend mantiene el grupo `terminal` fuera del listado y del catálogo del router genérico.

---

## 4. El estado efectivo: una sola definición (P2)

### 4.1 Lector `fn_terminal_inferir_huella_estado()` (parte de `97_`)
Función de **solo lectura**, `STABLE`, `SECURITY DEFINER`, `search_path = tiempo, pg_temp`, `EXECUTE` solo `service_role` (la usa el backend y la usa internamente `fn_marca_terminal_registrar`, que corre como dueño). Devuelve un objeto con: `activo` (booleano efectivo), valor crudo del interruptor, `hasta`, `vencido`, el motivo por el que está apagado (cuando lo está) y, de la bitácora, quién y cuándo lo encendió por última vez.

**Es la única implementación.** El RPC de marcas, el backend y el tablero la llaman; ninguno repite la regla.

### 4.2 Regla de «efectivamente encendido» (todas deben cumplirse; cualquier otra cosa es APAGADO)
1. Para **cada una de las dos claves** hay **exactamente una** fila vigente (P1). Cero filas (por ejemplo, tras un `DELETE`) o más de una (vigencias solapadas) ⇒ apagado.
2. El valor del interruptor es **exactamente la cadena `'1'`** (lectura cruda; nada de acotar ni normalizar; no se usa `fn_terminal_config_valor`, que acota con `LEAST`/`GREATEST` y leería `'7'` como 1).
3. El valor de `hasta` pasa el patrón estricto, se convierte a timestamp **dentro de un bloque con excepción**, y se cumple `hasta > now()` **y** `hasta <= now() + 30 días`. El tope se aplica **también al leer**, de modo que un `UPDATE` directo con una fecha lejana no crea un interruptor de vida larga.
4. Cualquier error al leer o convertir ⇒ apagado, con `SQLSTATE` (nunca texto del error ni identidad) en el warning.

Casos de presentación: valor `'1'` con `hasta` vencido o ausente ⇒ apagado efectivo y se **muestra como «vencido»**; valor `'0'` ⇒ apagado normal; vigencias solapadas o ausentes ⇒ «inconsistente».

### 4.3 Fecha de las vigencias
Las vigencias son diarias y `CURRENT_DATE` depende de la zona de la sesión. En el código nuevo (lector y función dedicada) «hoy» es `(now() AT TIME ZONE 'UTC')::date` explícito, para que ambos lados coincidan aunque cambie `TimeZone`. Consecuencia ya existente: un cambio hecho a las 18:00 de México cae en la fecha UTC siguiente; el RPC lee el último valor vigente en esa fecha y la bitácora guarda la hora exacta. El vencimiento `hasta` se compara con `now()` (instante), no con la fecha.

---

## 5. `98_` — `fn_marca_terminal_registrar` lee el interruptor

- `CREATE OR REPLACE` de `tiempo.fn_marca_terminal_registrar` **partiendo de la definición VIGENTE aplicada** (la de `95_`; antes de escribir se guarda `db/ensayos/vigente_98_marca_95.sql`), repitiendo `SECURITY DEFINER`, `SET search_path = tiempo, personas, pg_temp`, `REVOKE EXECUTE` a `PUBLIC`, `anon`, `authenticated` y `GRANT` solo a `service_role`. Diff literal contra `95_`; fuera de los hunks el cuerpo debe ser idéntico.
- **Una vez por lote**, tras el advisory lock y antes del bucle, en un sub-bloque con `EXCEPTION`: llama al lector único y toma el campo `activo`. Si la llamada falla, `activo` falta o no es verdadero ⇒ **apagado**; el `RAISE WARNING` lleva solo `SQLSTATE` y `terminal_id`.
- La condición de activación de `95_` suma «y el interruptor está efectivamente encendido». Apagado ⇒ la marca se registra y se responde **exactamente igual** (`confirmado` o `duplicado`); solo la activación no ocurre; **el lote nunca se rechaza** ni cambia de resultado.
- El interruptor se lee al inicio del lote; un cambio concurrente se aplica desde el lote siguiente (documentado).
- Verificación estática: el cuerpo no nombra `fn_terminal_config_valor`, no usa `SKIP LOCKED` ni `SQLERRM`, y la sección 59 de `verificar_ddl.sql` sigue en 0.

### Backend y frontend (no son SQL, pero deben coincidir) — P3
- `/api/terminal/marcas` consulta el **estado efectivo** mediante el lector (con caché de pocos segundos) y, si no es verdadero o la consulta falla, descarta `modo_verificacion` (falla cerrado). Descartarlo es ahora una **optimización**: la base es la barrera que no depende del backend.
- El backend **no usa** `fn_terminal_config_valor` ni lee la fila cruda para decidir.
- La pantalla de configuración muestra el estado efectivo (encendido hasta, vencido, apagado, inconsistente), pide la nota y la fecha de vencimiento al encender (con confirmación explícita escrita en la interfaz, que es barrera de usabilidad, no de seguridad) y llama a la función dedicada.
- Tablero de anomalías (consultas del backend, sin reemplazar `fn_terminal_anomalias`): tarjeta **mientras esté encendido** («encendido por X el día Y hasta Z»), tarjeta «**cambio del interruptor sin nota**» (filas con valor nuevo `'1'` y nota nula o menor de 10 caracteres, filas de `service_role`, y cualquier `DELETE` de la fila) y la categoría `huellas_inferidas_exceso` (94_), que ya cubre el uso excesivo. El primer día de puesta en marcha el exceso de inferidas es esperado.

---

## 6. Procedimiento operativo

1. Aplicar `97_` (interruptor apagado desde su primer instante; no cambia ningún comportamiento).
2. Aplicar `98_` (la base respeta el interruptor; con valor `'0'` todo sigue igual).
3. Backend y frontend desplegados con el estado efectivo y la pantalla.
4. **Primera alta real supervisada:** solo entonces el usuario enciende el interruptor con la función dedicada (nota, vencimiento corto) y se observa el resultado; después se apaga o se deja que venza.
5. En producción el estado por omisión es siempre «apagado».

Cada aplicación sigue el procedimiento ya usado en `93_` a `96_`: archivo idéntico al ensayado (md5), comprobaciones previas (puente apagado, sin sesiones abiertas, sin altas en curso), `psql --single-transaction -v ON_ERROR_STOP=1` por el pooler de sesión (puerto 5432), y verificación posterior con `verificar_ddl.sql` completo y conteos de las tablas antes y después.

---

## 7. Reversa

- **Operativa (inmediata):** poner el interruptor en `'0'` con la función dedicada; deja su fila. Sin DDL.
- **`98_`:** `CREATE OR REPLACE` con el cuerpo de `95_` (copia en `db/ensayos/vigente_98_marca_95.sql`), repitiendo `SECURITY DEFINER`, `search_path` y `REVOKE`/`GRANT`.
- **`97_` antes del primer uso real:** quitar el trigger de auditoría, las funciones nuevas, restaurar `fn_terminal_config_actualizar` de `89_`, soltar las restricciones y borrar las dos filas sembradas (solo si nunca se editaron).
- **`97_` con filas en la bitácora:** la tabla es inmutable por diseño; se deja inerte y se documenta. No se desactivan sus triggers. `DROP TABLE` solo con superusuario y autorización explícita del usuario. Si las claves ya fueron editadas, se dejan con `'0'` y el centinela (el lector las lee como apagado).

---

## 8. Cambios en `verificar_ddl.sql`

- **Sección 51** (claves de configuración de terminales): tolerar **exactamente** las dos claves nuevas fuera del catálogo; el resto igual (cinco claves, una vigencia activa cada una, valor dentro de rango, ninguna clave `terminal_%` desconocida).
- **Sección 60 (`97_`):**
  - ambas filas sembradas con una sola vigencia activa; valor del interruptor `'0'` o `'1'`; formato de `hasta` correcto;
  - restricciones con la definición esperada;
  - bitácora de configuración: RLS, triggers de inmutabilidad habilitados (`tgenabled = 'O'`, `tgtype` esperado), ACL exacta por rol (nadie con `INSERT`, `UPDATE`, `DELETE` ni `TRUNCATE`; `SELECT` para `authenticated` y `service_role`), policy `SELECT` exacta;
  - trigger de auditoría sobre `tiempo.parametro`: existe, habilitado, `tgtype` esperado; su función `SECURITY DEFINER`, `search_path` exacto, `EXECUTE` para nadie;
  - función dedicada: `SECURITY DEFINER`, `search_path = tiempo, personas, pg_temp`, `EXECUTE` solo `authenticated`, cuerpo con la nota mínima, el tope de 30 días y las condiciones de consentimiento y terminal;
  - lector de estado: `STABLE`, `SECURITY DEFINER`, `EXECUTE` solo `service_role`, no nombra `fn_terminal_config_valor`;
  - `fn_terminal_config_actualizar` con el guard de `clave_no_editable`;
  - ambas claves fuera del catálogo y el lector tolerante devolviendo nulo para ellas.
- **Sección 61 (`98_`):** `fn_marca_terminal_registrar` sigue `SECURITY DEFINER` con `search_path` exacto y `EXECUTE` solo `service_role`; su cuerpo llama al lector único; no nombra `fn_terminal_config_valor`; sin `SKIP LOCKED` ni `SQLERRM`; y la sección 59 sigue en 0.
- Una consulta **informativa** (no de violación) con el estado efectivo actual y quién/cuándo lo cambió por última vez. No hay condición «el valor es 0» (cambiará legítimamente al encenderlo).
- **Conteos documentados:** parámetros 13 → 15 (las dos claves nuevas), policies 76 → 77 (policy `SELECT` de la bitácora), archivos de DDL 97 → 99 (`00` a `98`), `SCJ-DIC-01` a V1.6. El texto propuesto para `CLAUDE.md` se entrega aparte (no se edita desde `db`).

---

## 9. Plan de ensayo (BEGIN … ROLLBACK real por psql, pooler de sesión puerto 5432, `lock_timeout` de 3 s, puente apagado, sin concurrencia; salida sin `employee_no`, `persona_id` ni nombres)

### `ensayo_97`
- **Sembrado:** ambas claves con una sola vigencia activa, valor `'0'` y centinela; claves fuera del catálogo; el lector tolerante devuelve nulo; las cinco claves de `89_` intactas.
- **Restricciones:** valores inválidos del interruptor (`'7'`, `'2'`, `'1 '`, vacío, `'true'`, nulo) rechazados; `hasta` sin zona, sin hora, con espacio, mes 13, texto libre, vacío y nulo rechazados; formatos válidos aceptados.
- **Función dedicada:**
  - encender con nota válida, `hasta` válido, consentimiento vigente y terminal activa ⇒ ambas claves cambian en la misma transacción y quedan **dos** filas de bitácora (anterior/nuevo, nota, autor `auth.uid()`, rol `authenticated`, `via_funcion` verdadero, mismo `txid`, hora);
  - nota corta, nula, solo espacios o invisibles, o nueve letras más invisibles ⇒ `nota_requerida` sin cambio de valor ni fila;
  - `hasta` en el pasado, nulo o a más de 30 días ⇒ `hasta_invalido`;
  - sin consentimiento vigente publicado (solo el provisional) o sin terminal activa ⇒ rechazo (P4);
  - apagar sin nota ⇒ ok, con su fila y `hasta` devuelto al centinela; mismo valor y mismo vencimiento ⇒ `sin_cambio` sin fila; renovar con nota nueva ⇒ ok;
  - **encender y apagar el mismo día UTC** ⇒ filas de bitácora para ambas transiciones aunque la vigencia se corrija en sitio;
  - sin permiso (RH con `parametro_edicion` pero sin `terminal_config_edicion`, usuario sin permisos, persona inactiva, `anon`) ⇒ `42501` sin escritura ni fila.
- **Rutas genéricas:** `fn_terminal_config_actualizar` con cualquiera de las dos claves ⇒ `22023 clave_no_editable` (con y sin permiso); `fn_parametro_actualizar_valor` ⇒ `SCJ17`.
- **Auditoría (A2):**
  - `UPDATE` directo como `service_role` (de `'0'` a `'1'`) ⇒ una fila con nota nula, `via_funcion` falso, rol `service_role`; la consulta de la anomalía «cambio sin nota» la devuelve;
  - `INSERT` directo y **`DELETE` directo por `service_role`** ⇒ fila de bitácora y, tras el `DELETE`, el lector responde apagado;
  - el `UPDATE` que solo cierra `vigente_hasta` no deja fila;
  - ambas variables de transacción se limpian al terminar (un `UPDATE` directo posterior en la misma transacción sale sin nota); una variable de nota fijada a mano en otra transacción (otro `txid`) no se acepta;
  - `UPDATE`, `DELETE` y `TRUNCATE` sobre la bitácora rechazados incluso para el dueño; `has_table_privilege` por rol (nadie con `INSERT`; `authenticated` y `service_role` solo `SELECT`); policy exacta.
- **Lector de estado:** encendido válido ⇒ activo; `hasta` vencido, `hasta` a más de 30 días (escrito saltando el CHECK dentro de la transacción), formato inválido o sin zona, valor corrupto `'7'`, fila ausente tras `DELETE`, **dos filas vigentes** (vigencias solapadas) ⇒ apagado con el motivo correcto y mostrado como vencido/inconsistente según el caso.
- **Regresión:** las otras cinco `terminal_*` siguen editables solo dentro de su rango, con la regla cruzada de llaves; `verificar_ddl.sql` completo dentro de la transacción (51 ajustada, 57 a 60 en 0 filas).

### `ensayo_98`
- Interruptor `'0'` ⇒ una marca por huella en una alta `esperando_huella` se confirma y **no activa**; encendido válido ⇒ activa (`huella_inferida` con `marca_id`).
- **No activa** (y la marca se registra, el lote sigue, el warning lleva solo `SQLSTATE` y `terminal_id`): parámetro ausente; `hasta` vencido; `hasta` a más de 30 días; formato inválido; valor `'7'` o `'1 '` (CHECK saltado dentro de la transacción); dos filas vigentes; vigencia con fecha de mañana; `DELETE` de la fila; **lectura fallida** (`ALTER TABLE tiempo.parametro RENAME` dentro de la transacción ⇒ la lectura lanza `undefined_table` dentro del sub-bloque ⇒ apagado).
- **Encender y apagar el mismo día** ⇒ el RPC lee el último valor. **Medianoche UTC:** interruptor encendido a las 17:59 de México (fecha UTC aún igual) y cambio posterior a las 18:00 de México (fecha UTC siguiente), simulados con filas fechadas ayer/hoy/mañana (el reloj de la transacción no se puede mover) y un caso que cambia `SET LOCAL timezone` entre `UTC` y `America/Mexico_City` para demostrar que la lectura usa la fecha UTC explícita, no la de la sesión.
- **Regresión de los 44 casos de `ensayo_95`:** con el interruptor encendido y vigente pasan los 44; con el interruptor apagado pasan todos salvo los que exigen activación; **y un caso con el interruptor en `'1'` pero `hasta` vencido** ⇒ no activa.
- Atributos y ACL de `fn_marca_terminal_registrar` intactos; el cuerpo no nombra `fn_terminal_config_valor`; sección 59 en 0.

---

## 10. Riesgos residuales, para que nadie los descubra después

- `service_role` puede escribir en `tiempo.parametro` (incluido encender el interruptor con un `hasta` legal): el trigger lo registra y el tablero lo marca («cambio sin nota»), y el lector exige `hasta` dentro de 30 días al leer, pero la escritura no se impide.
- El dueño o un superusuario pueden desactivar triggers o fijar variables de transacción; se mitiga con la comprobación de existencia y `tgenabled = 'O'` en `verificar_ddl.sql` y con el refuerzo del `txid`.
- «Hoy» en las vigencias es fecha UTC; los instantes (`hasta`, hora de la bitácora) son exactos.
- La llave de `service_role` no se rota (decisión del usuario): el diseño asume ese riesgo y lo hace visible.
- Reemplazar `fn_marca_terminal_registrar` otra vez es el punto de mayor riesgo de regresión: por eso `98_` va aparte, con diff literal contra `95_` y la regresión completa.

---

## 11. Lo que falta para escribir

1. Confirmación del usuario de la decisión de producto «activo hasta» (se asume SÍ, tope de 30 días).
2. Autorización del usuario para escribir `97_` y `98_` y sus ensayos.
3. Autorización posterior y separada para **correr cada ensayo** y para **aplicar** cada archivo contra la base real.
4. Trabajo de backend/frontend/documentación en paralelo (sección 5), fuera del alcance de `db`.
