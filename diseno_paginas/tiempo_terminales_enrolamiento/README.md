# Diseño previo — Enrolamiento de terminal (Paquete 2)

**Estado: BORRADOR sujeto a contrato. No implementar hasta que el usuario lo apruebe y backend publique `/api/terminales`.**
Fuente: `docs/07-procesos/SCJ-PRO-15_Proceso_Enrolamiento_de_Terminal_V1_1.md` §VI y `docs/03-decisiones/SCJ-DEC-12_*_V2_0.md` §4–§6. Importa el CSS real (`frontend/src/styles/tokens.css`); cada HTML tiene barra para cambiar de estado, `?estado=<clave>` abre uno directo y `?limpio=1` oculta las notas. Reutiliza `_mockup.css/js` (copia de los del Paquete 1, con el grupo «Terminales» en el sidebar). Sin móvil, igual que el resto de mockups.

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
