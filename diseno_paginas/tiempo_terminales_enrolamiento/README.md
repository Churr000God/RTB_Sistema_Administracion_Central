# Diseño previo — Enrolamiento de terminal (Paquete 2)

**Estado: APROBADO por el usuario el 2026-10-08 (incluye Configuración y reconsentimiento, 09-11). No implementar hasta que backend publique el contrato de `/api/terminales`.**
Fuente: `docs/07-procesos/SCJ-PRO-15_Proceso_Enrolamiento_de_Terminal_V1_2.md` §VI y `docs/03-decisiones/SCJ-DEC-12_*_V2_1.md` §4–§6. Importa el CSS real (`frontend/src/styles/tokens.css`); cada HTML tiene barra para cambiar de estado, `?estado=<clave>` abre uno directo y `?limpio=1` oculta las notas. Reutiliza `_mockup.css/js` (copia de los del Paquete 1, con el grupo «Terminales» en el sidebar). Sin móvil, igual que el resto de mockups.

| Archivo | Pantalla (SCJ-PRO-15 §VI) |
|---|---|
| `01-terminales-lista.html` | 1. Terminales (lista, sólo lectura) |
| `02-usuarios-de-la-terminal.html` | 2. Usuarios de la terminal: tabla de altas, filtros, acciones, `esperando_huella` con cuenta regresiva |
| `03-modales-asignar-y-baja.html` | 2 (acciones): modal Asignar (consentimiento obligatorio, auto-asignación) y modal Cancelar alta / Dar de baja, 13 estados |
| `04-historial-de-un-alta.html` | 3. Historial de un alta (panel lateral) |
| `05-tablero-de-anomalias.html` | 4. Tablero de anomalías (las 9 categorías) |
| `06-ficha-persona-seccion-terminal.html` | 5. Sección «Terminal» en la ficha de persona |
| `07-aviso-al-suspender-persona.html` | 6. Banner `baja_terminal_pendiente` al suspender / dar de baja |
| `08-navegacion.html` | 7. Entrada de sidebar: opción A (grupo propio, recomendada) vs B (dentro de Parámetros) |

## Invariantes del proceso que el diseño respeta
- **No hay botón «Capturar huella».** La huella se enrola en el menú del aparato (TI con RH presente); la UI sólo asigna, hace seguimiento y da de baja. `esperando_huella` dice «Esperando que TI enrole la huella en la terminal».
- 5 estados con **icono + texto + color** (nunca sólo color): `pendiente_alta` (reloj), `esperando_huella` (huella, con **tiempo restante hasta la caducidad de 24 h**, en tono urgente la última hora), `activo` (check), `pendiente_baja` (reloj), `baja` (neutro).
- «Cancelar alta» en `pendiente_alta`/`esperando_huella`; «Dar de baja» en `activo`; ninguna acción en `pendiente_baja`/`baja`.
- **Casilla de consentimiento** (LFPDPPP) obligatoria al asignar, sin marcar por defecto; si falta, error del campo (no un botón gris sin explicación).
- **Auto-asignación**: aviso informativo cuando la persona elegida es la del caller; la decisión (excepción del administrador genérico) es del backend (422 con `detail`). El frontend no sabe si el caller es administrador.
- Permisos `terminal_usuario_lectura` (heredable) / `terminal_usuario_edicion` (no heredable): sin edición, acciones ocultas y un aviso que explica por qué. Sin lectura, el módulo no aparece.
- Estados de interfaz en todas: cargando, vacío, error (con «Reintentar»), sin permiso.
- Nada biométrico viaja nunca al frontend: sólo el **conteo** de huellas.

## Datos y endpoints por pantalla (SCJ-DEC-12 §4–§6)
- **01** `GET /api/terminales`: `estado_contacto` (`en_linea|sin_contacto|nunca|inactiva`), `ultimo_contacto_en`, `segundos_sin_contacto`, `terminal_alcanzable`, `reloj_desfase_seg`, `version_pi`, `marcas_pendientes`, nombre, serie. Refresco cada 60 s.
- **02** `GET /api/terminales/{id}/usuarios` (filtros `estado`, `persona_id`, `desde`; orden `creado_en` desc): persona (nombre), `employee_no`, estado, huellas, fecha, `error_detalle`.
- **03** `POST /api/terminales/{id}/usuarios {persona_id}` → 201; `POST …/usuarios/{tu_id}/baja {motivo?}` → 201. Errores: `detail` fijos de §4 (409 duplicada / estado inválido / carrera; 422 persona no activa, terminal no válida, sin sincronizar; 403).
- **04** `GET …/usuarios/{tu_id}/movimientos`: tipo, fecha, `registrado_por_nombre` (o «Terminal»), detalle.
- **05** `GET /api/terminales/{id}/anomalias?desde=`.
- **06** `GET /api/terminales` + altas por persona. **07** `advertencias: ["baja_terminal_pendiente"]` en la respuesta de `POST /api/personas/{id}/movimientos`.

## Decisiones propias del diseño
1. **07 cambia el flujo de CambiarEstadoPage sólo si hay advertencia**: hoy redirige a la ficha en cuanto hay 201 y la advertencia se perdería. Con advertencia se queda en un resultado con el banner y «Continuar a la ficha»; sin ella, igual que hoy.
2. **Aviso de consentimiento en el modal, no en una página aparte**: es un paso del flujo de asignar y debe verse en el mismo momento.
3. **Botón principal de baja nombra la consecuencia** («Cancelar el alta» / «Dar de baja definitivamente»), con la advertencia de que borra la huella del aparato y de que reactivar no reenrola.
4. **Cuenta regresiva**: se calcula en el cliente a partir de la fecha de `usuario_creado` + 24 h (valor «inicial ajustable» según SCJ-PRO-15 §P2 → ver pedido 3).
5. Navegación opción A recomendada: es un módulo con permiso y público propios (RH/TI), distinto de la configuración de Parámetros; «Anomalías» necesita un lugar claro.

## Pedidos al contrato / backend (no inventados)
1. **P4 (ya abierta en SCJ-PRO-15):** `puede_ver_terminales` y `puede_editar_terminales` en `GET /api/sesion` para ocultar el grupo y las acciones sin llamar a un endpoint que dé 403.
2. **Consentimiento:** ¿el body de asignar lleva `consentimiento: true` para que el servidor lo exija y lo registre en `detalle`? SCJ-PRO-15 §IV.7 dice que se guarda en el `detalle` del movimiento `asignado`, pero SCJ-DEC-12 §4 sólo muestra `{persona_id}`. Recomiendo que el servidor lo exija (si no, sólo es un adorno de la UI).
3. **Caducidad:** el listado de altas debería devolver `caduca_en` (o `usuario_creado_en`) además del estado, para no hardcodear «24 h» en el cliente.
4. **Alta por persona:** `GET /api/personas/{id}/terminales` (o `persona_id` sin `terminal_id` en una ruta de altas) para la sección de la ficha; si no, son N llamadas.
5. **Anomalías:** forma exacta de cada bloque (cifra + hasta 3 ejemplos + «Ver todos»), si el backend manda un `nivel` por categoría, y qué devuelven las categorías 5 y 6 cuando aún no existen sus fuentes (`marca_rechazada`, llaves).
6. **`error_detalle` saneado** y su `codigo` corto para pintarlo en la fila (§IV.3: «se muestra a RH hasta que un movimiento válido lo limpia»).
7. **Lista de personas asignables:** ¿filtra el backend las que ya tienen alta vigente en esa terminal, o lo hace el cliente con las altas ya cargadas?
8. **Aviso de baja correcta:** ¿hay señal cuando la baja de terminal sí se emitió (para el banner informativo opcional de 07)? Hoy sólo se avisa del fallo.

## Preguntas abiertas para el usuario
1. **Navegación**: ¿opción A (grupo «Terminales») o B (dentro de Parámetros)? Recomiendo A.
2. **Un solo modal de asignar** compartido entre «Usuarios de la terminal» y la ficha de persona (con selector de terminal en este último caso): ¿de acuerdo? Recomiendo sí.
3. **Quién ve «Anomalías»**: SCJ-PRO-15 dice lectura o edición; ¿también RH, o sólo TI/Gerente General? (Hoy los tres puestos con permiso son RH, Gerente General y TI.)
4. **Copy de la leyenda de consentimiento**: el texto que aparece al lado de la casilla es una propuesta; el aviso de privacidad real lo provee RH/Legal (SCJ-PRO-15 P7), no se redacta aquí.
5. **Mínimo de huellas**: la UI muestra el conteo; no se exige mínimo mayor a 1 (P5 abierta).
6. **¿Se avisa a TI** (correo/notificación) cuando hay una alta en `esperando_huella`? Hoy sólo se ve en la lista; el diseño no inventa notificaciones.

---

# Adenda — Configuración de terminales (09, 10), reconsentimiento (11) y decisiones del usuario

**Decisiones del usuario que cierran preguntas anteriores:** grupo propio «Terminales» (opción A); modal de asignar compartido entre la pantalla de la terminal y la ficha; Anomalías visibles con `terminal_usuario_lectura/edición` (RH, Gerente General, TI); mínimo 1 huella; sin notificaciones por ahora.
**Configuración:** un solo permiso nuevo, `terminal_config_edicion` (Gerente o Encargado de TI y Gerente General). **No hay permiso de lectura aparte**: la pantalla se ve con la visibilidad del grupo Terminales y RH la ve en sólo lectura. Picos de tasa queda **fijo** (10/persona/hora). Texto de consentimiento: tope **4 000** caracteres, texto plano. La versión que confirmó cada alta se guarda en una **columna** de la bitácora (`consentimiento_id`), no en el `detalle`. Cambiar la caducidad aplica también a las altas en curso (la UI lo avisa y muestra el impacto). **No existe «sin texto publicado»**: la v1 se siembra como provisional. Una versión desactualizada al asignar se rechaza siempre (409). «Motivo del cambio» al publicar: opcional, 200 caracteres.

| Archivo | Contenido |
|---|---|
| `09-configuracion-consentimiento.html` | Versión vigente, editor (4 000), vista previa fiel al modal de asignar, historial (con motivo y marca de cambio material), panel de publicar con motivo opcional (200), y **«Cambio material (exige reconsentimiento)»** con el conteo de personas que quedarán pendientes. 16 estados |
| `10-configuracion-variables.html` | 5 variables: caducidad de altas 4–168 h, antigüedad máx. de llave 3–36 meses, ventana de anomalías 1–90 días, retención de rechazos 30–365 días, traslape de llaves 1–90 días (def. 7). Caducidad con **paso de impacto antes de confirmar**: variante que amplía el plazo y variante que lo acorta (nombra las altas que caducarían en la siguiente corrida) |
| `11-reconsentimiento.html` (**propuesta**) | Modal «Registrar reconsentimiento»: una persona, lote, todas las pendientes; casilla única de que existen los documentos firmados; éxito, éxito parcial por alta, 409, 403, 503 |
| `02-usuarios-de-la-terminal.html` (actualizado) | Estado nuevo «Con reconsentimiento pendiente (propuesta)»: insignia por fila con la versión que confirmó, métrica con contador, filtro, casillas de selección, barra de acciones en lote y «Registrar reconsentimiento» por fila |
| `03-modales-asignar-y-baja.html` (actualizado) | Casilla con el texto de la versión vigente y su número (+ «Provisional»); estado nuevo «texto desactualizado (409)» con «Releer el texto vigente». Se eliminó el estado «sin texto publicado» |
| `04-historial-de-un-alta.html`, `05-tablero-de-anomalias.html`, `08-navegacion.html` (actualizados) | 04: «Consentimiento vN» (columna) y entrada «Reconsentimiento registrado». 05: décima tarjeta **propuesta** «Reconsentimientos pendientes». 08: permisos simplificados |

## Propuestas pendientes de aprobación del usuario
Todo el **reconsentimiento** (11, y sus huellas en 02, 04, 05 y en el panel de publicar de 09) es un borrador que el usuario aún no aprueba; el resto de esta adenda refleja decisiones ya tomadas.

## Decisiones de diseño
1. **Versiones inmutables**; la nueva aplica a asignaciones nuevas, las altas hechas conservan su versión. **Deja de ser provisional publicando una versión nueva sin la marca** (el panel lo dice).
2. **Publicar en dos pasos** (revisar → panel con motivo, cambio material y confirmación explícita). Inerte mientras envía.
3. **Cambio material**: casilla propia, no deducida del texto. Si se marca, el panel muestra cuántas personas quedarán pendientes (cifra del servidor al abrir el panel).
4. **Reconsentimiento no toca nada del enrolamiento**: ni huella, ni estado, ni baja; sólo registra la existencia del documento firmado contra la versión vigente. Quien no reconsiente: se solicita su baja (pasa a captura manual).
5. **Impacto antes de confirmar** al cambiar la caducidad: cuenta de altas afectadas y, si acorta, nombra las que caducarían en la siguiente corrida; confirmar en rojo.
6. Lectura (RH): bloque de sólo lectura en lugar del editor, sin botones de edición, con aviso que nombra `terminal_config_edicion`. Sin acceso al grupo: estado vacío que nombra `terminal_usuario_lectura`.

## Pedidos de contrato a backend/db
1. **Permiso** `terminal_config_edicion` (sembrado a TI y Gerente General; ¿heredable? recomiendo no, como `terminal_usuario_edicion`) y banderas en `GET /api/sesion` (`puede_ver_terminales`, `puede_editar_terminales`, `puede_editar_config_terminales`).
2. **Consentimiento versionado:** `GET …/configuracion/consentimiento` → `{vigente (con texto), historial (sin texto)}` y `GET …/configuracion/consentimiento/{version}` (texto de una versión; 404 de mensaje fijo) (versión, texto, `provisional` —sólo la v1 sembrada—, `cambio_material`, `motivo_cambio`, `vigente_desde`, `publicado_por_nombre`). `POST` `{texto 1–4000, cambio_material, motivo_cambio≤200, base_version}` → 201; 409 si la vigente cambió; 422 inválido. Para el panel de publicar: el conteo de personas que quedarían pendientes si es material (p. ej. `GET …/consentimiento/impacto` o campo en la respuesta de `GET`).
3. **Asignar:** `POST …/usuarios {persona_id, consentimiento_id}`; 409 si ya no es el vigente (siempre). El historial del alta devuelve `consentimiento_id`/versión como campo propio.
4. **Variables:** `GET` (clave, descripción, unidad, `minimo`, `maximo`, valor, `vigente_desde`), `PATCH {valor}` (422 fuera de rango), historial, y `POST …/variables/caducidad_alta_horas/simular {valor}` → `{altas_que_ganan_plazo, altas_que_caducarian_ya:[nombres], altas_por_caducar_nuevas}` para el paso de impacto.
5. **Reconsentimiento (propuesta):** altas con `reconsentimiento_pendiente` (bool) y `consentimiento_vigente_id`/`consentimiento_confirmado_id`; filtro `reconsentimiento=pendiente` y contador; `POST …/usuarios/{tu_id}/reconsentimiento {consentimiento_id}` y lote `POST …/usuarios/reconsentimientos {tu_ids[], consentimiento_id}` (máx. 200, todo o nada; si alguna no es elegible, error con la lista de no elegibles y su razón); movimiento de bitácora propio sin cambio de estado; categoría 10 en `GET …/anomalias`.
6. `caduca_en` obligatorio en las altas (ya pedido): ahora la caducidad es configurable y cambia con altas en curso.
7. Compartir el modal entre la terminal y la ficha: sólo cambia que la ficha agrega el selector de terminal.

## Preguntas abiertas
1. **Reconsentimiento:** ¿una persona sin reconsentir tiene plazo y consecuencia (p. ej. baja automática) o sólo queda señalada? El diseño sólo señala.
2. **¿Quién registra el reconsentimiento?** Se propone `terminal_usuario_edicion` (RH, Gerente General, TI), el mismo que asigna.
4. Rangos de las variables (confirmar los propuestos) y si «traslape de llaves» debe validarse contra la antigüedad máxima de llave.

## Cierres posteriores del usuario (aplicados)
- **Texto máximo 4 000 caracteres.**
- **El reconsentimiento pendiente NO bloquea marcas:** sólo se muestra (insignia, filtro y contador en 02; sección en la ficha, 06; tarjeta 10 en 05 con persona, versión anterior y días pendiente).
- **Quién cuenta como pendiente:** `pendiente_alta`, `esperando_huella` y `activo`; `pendiente_baja` y `baja` no.
- **Primer texto definitivo que sustituye al provisional:** el reconsentimiento de todos es automático; en el panel de publicar de 09 (estado «Confirmar · reemplaza al provisional») la casilla «Cambio material» aparece marcada y **bloqueada** con la explicación. En versiones posteriores es opcional. El panel muestra cuántas altas quedarían pendientes.
- **09:** la versión 1 figura «Publicada por Sistema (texto provisional)»; no hay permiso de lectura aparte (`terminal_config_edicion` es el único).
- **Registro de reconsentimiento (11):** por fila y en lote, **máximo 200 por vez, todo o nada**; antes de la confirmación «tengo los documentos firmados» se muestran la versión y su texto completo; si alguna ya no es elegible se rechaza el lote y se listan las no elegibles con su razón. Si hay más de 200, el botón queda inerte con el motivo.

## Ajuste posterior
- **Sólo la v1 sembrada es provisional**; dejar de serlo es publicar una versión nueva. El RPC **nunca** publica `provisional=true`: el panel de publicar de 09 ya no tiene la casilla «Marcar como provisional».
- **Personas asignables** en el modal de asignar (03) muestran **nombre + puesto · área** para distinguir homónimos; en la ficha (06) la persona viene fija con ese mismo dato. Pedido: puesto vigente y área en el listado de personas asignables.

## Cambios menores posteriores
- **Baja manual:** el motivo es **obligatorio** (mínimo 10, máximo 500) en el modal de baja/cancelar de 03: campo requerido, contador «n / 500 · mínimo 10» y error de campo si falta (estado nuevo «Baja · falta el motivo»); no llama al servidor. Sustituye al motivo opcional anterior.
- **Reconsentimiento propio prohibido:** la alta de la propia persona del usuario no es elegible (razón fija «No puedes registrar tu propio reconsentimiento»; excepción: administrador genérico). En 02 la fila propia lleva la insignia «tú», su casilla está deshabilitada, no tiene botón y se muestra la razón; «Seleccionar las N elegibles» la excluye. En 11 figura entre las no elegibles si llegara al servidor.
- **Visibilidad:** el módulo Terminales se ve **sólo** con `terminal_usuario_lectura/edición`; `terminal_config_edicion` por sí solo no da acceso (08, 09 y 10 lo dicen).
- Pedidos de contrato: motivo de baja mínimo 10 validado en servidor (422); la elegibilidad del reconsentimiento incluye «no es la propia persona del caller (salvo administrador genérico)»; el listado de altas puede marcar `es_propia`/`reconsentimiento_elegible` con su razón.

## Ajuste de contrato: texto de versiones anteriores
El historial de versiones ya no trae el texto: sólo la vigente. En 09 cada versión anterior tiene «Ver texto» (botón con `aria-expanded`), que hace una segunda petición `GET …/consentimiento/{version}` y abre un panel de sólo lectura bajo el historial con cuatro estados: cargando, texto, error (con «Reintentar») y 404 de mensaje fijo («La versión de consentimiento solicitada no existe.»). La versión vigente muestra «Texto vigente (arriba)». De paso se quitó la marca «Provisional» de la v2 del historial (sólo la v1 sembrada lo es).

## Ajuste de contrato: edición de variables (10)
- `PATCH …/variables/{clave}` envía `valor` y `valor_base` (enteros; `valor_base` = el vigente que la pantalla mostró). **409** si cambió, con `valor_actual`: 10 tiene el estado «409 valor desactualizado» (la tabla recarga el vigente, 36 h en el ejemplo; el campo **conserva lo escrito**, 48 h; aviso que nombra ambos valores).
- **422 fuera de rango** con el mensaje del catálogo (estado «422 fuera de rango (catálogo)»; la validación local normalmente lo atrapa antes).
- **Regla cruzada de llaves** (`traslape_dias × 2 ≤ antigüedad_meses × 30`, 30 días por mes, contra el valor vigente de la otra clave y en ambos sentidos; db/ddl/89_): dos estados, uno por clave, con el texto fijo de cada una («El traslape de llaves no puede superar la mitad de la antigüedad máxima de la llave.» / «La antigüedad máxima de la llave debe ser al menos el doble del traslape de llaves.»). Las filas de ambas claves lo indican en su descripción.
- **Simulador de caducidad** (`…/terminal_caducidad_alta_horas/simular`): el panel de impacto usa `acorta`, `ya`, `ganan_plazo`, `por_caducar` (≤ 1 h) y `total` («3 de 5 altas…»), con nombres cortados a 50 caracteres y con tope («y N más»).
- Los ejemplos de los dos estados 422 de regla cruzada violan la regla de verdad: antigüedad vigente **3 meses (90 días)** con traslape propuesto **60** (60 × 2 = 120 > 90), y traslape vigente **60** con antigüedad propuesta **3 meses**. (12 meses con traslape 60 no la viola: 120 ≤ 360.)

## Ajuste (revisión de security): acortar la caducidad y valores ilegibles
- **Acortar la caducidad exige ver el impacto:** «Confirmar» queda deshabilitado hasta que el cálculo del simulador termine. Estados: «Acortar · calculando impacto» (spinner, Confirmar inerte), «Acortar · impacto calculado» (cifra **«N altas caerían en la próxima corrida»** con nombres cortados y el botón dice «Confirmar: N altas caerán en la próxima corrida») y «Acortar · falla el cálculo» (error con «Reintentar el cálculo»; sin impacto no se puede confirmar). Ampliar el plazo sigue siendo informativo (Confirmar habilitado).
- **Historial con valor ilegible:** estado «Historial · valor ilegible»: una vigencia cuyo valor no se pudo leer se muestra con la marca «Valor ilegible» y su explicación en vez de un número. Pedido de contrato: campo `valor_ilegible` (bool) por fila del historial; el cliente no intenta formatearlo.
