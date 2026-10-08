# Diseño previo — Excepciones de día cerrado y corrección de marcas (Paquete 1)

**Estado: borrador para aprobación del usuario. Nada de esto está implementado en `frontend/src`.**
HTML estático que importa el CSS **real** (`frontend/src/styles/tokens.css`), así que colores, tipografía, tablas, badges y botones son los de producción. Ábrelos con el navegador (necesitan la carpeta `frontend/` al lado para el CSS). Cada página trae una barra superior para **cambiar de estado** (con datos, carga, vacío, error, etc.); `?estado=<clave>` abre uno directo y `?limpio=1` oculta las notas de diseño.

| Archivo | Pantalla |
|---|---|
| `01-registro-marcas-bloqueo.html` | `/tiempo/marcas` — Corregir bloqueado por motivo |
| `02-excepciones-dia-cerrado.html` | `/tiempo/excepciones` — tipo "Día cerrado": tabla, tarjetas, sin permiso |
| `03-modal-descartar.html` | Modal "Descartar marca tardía" — 11 estados |
| `04-dias-excepciones-dia-cerrado.html` | `/tiempo/dias` — resumen de marcas tardías |
| `_mockup.css` / `_mockup.js` | Andamiaje + los 3 componentes nuevos (ver abajo). No es código de la app. |

Sin versión móvil: los mockups de `diseno_paginas/personas/` son sólo escritorio y la app no tiene layout responsive del sidebar; las tablas ya usan `.tabla-desplazable` y 02 ofrece una variante en tarjetas.

## Qué dato/endpoint usa cada pantalla
**01 Registro de marcas** — `GET /api/marcas`: `motivo_bloqueo_correccion` (`dia_cerrado_pendiente` | `en_tramo_cerrado` | `en_tramo` | null) decide la celda; `excepcion_pendiente_id` sigue decidiendo si hay algo que corregir (sin él, "—" como hoy); `excepcion_dia_cerrado_pendiente_id` enlaza a la excepción; `momento_efectivo` + `desfase_local` dan la fecha local para el enlace a Días. Los 2 booleanos `correccion_bloqueada_*` son redundantes con el motivo: no se usan.
**02 Excepciones** — `GET /api/excepciones?tipo=dia_cerrado`: `es_dia_cerrado`, `dia_de_la_marca_estado` (badge), `camino_resolucion` (acción), `persona_nombre`, `momento_dispositivo` (columna "Marca", ver pregunta 4), `creado_en`. `GET /api/sesion`: `puede_descartar_excepciones` (mostrar/ocultar "Descartar").
**03 Modal** — `POST /api/excepciones/{id}/descartar` `{motivo}` → `{resultado: descartada|ya_descartada, excepcion_id, dia_id}`. Textos de error = `detail` reales de `backend/app/errores.py`.
**04 Días** — `GET /api/excepciones?tipo=dia_cerrado` agrupado por `dia_de_la_marca_id` cruzado con `GET /api/dias` (`dia.id`). Sin endpoint nuevo.

## Componentes nuevos propuestos (a agregar a `tokens.css`/`components/` al implementar)
1. **`.aviso-bloqueo` + `.boton-corregir-bloqueado`** — "Corregir" visible pero inactivo: `button aria-disabled="true"` (sigue en el orden de tab y se anuncia como no disponible), candado + borde punteado + etiqueta de texto por motivo (no depende del color), mensaje fijo detrás de "¿Por qué?" (divulgación con `aria-expanded`, funciona en teclado y táctil; no tooltip de hover).
2. **`.banner-aviso`** (+ `--info`) — banner de página; extiende la idea de `.tarjeta-info`.
3. **`.modal`** — primer modal del proyecto; propuesta `<dialog>` nativo (`showModal()`: foco atrapado, Esc, restaura foco). Además `.boton-peligro` (rojo, sólo para la confirmación irreversible).

## Decisiones de copy
- Tú ("Revisa", "Usa") en el copy nuevo, porque los mensajes fijos del backend vienen en tú; el frontend actual mezcla tú y voseo ("Corrígelas" / "afiná" / "usá") — ver pregunta 6.
- Honestidad sobre el alcance de Corregir: banner permanente en 01 ("después del cierre de día casi ninguna marca se puede corregir por esta pantalla: usa captura manual o revisa el día"). No promete la opción B.
- Etiquetas cortas por motivo: *Ya está en un tramo* / *Día / tramo cerrado* / *Marca tardía · día cerrado*; el mensaje largo del backend va tal cual en "¿Por qué?".
- "Revisar día" = enlace (navegación); "Descartar marca tardía" = botón de borde rojo; la confirmación del modal es el único relleno rojo ("Descartar definitivamente"). Éxito distingue `descartada` ("quedó descartada y registrada") de `ya_descartada` ("no se hizo ningún cambio").
- Sin permiso: se muestra el estado y el porqué en la fila (no se esconde la fila ni se deja un botón que dará 403).

## Pedidos a backend (el diseño no los inventa; con ellos queda completo)
1. **`dia_de_la_marca_fecha`** en `ExcepcionOut` — columna "Día de la marca" y enlace exacto a Días. Hoy sólo hay `dia_de_la_marca_id`. (Alternativa sin backend: derivar de `momento_dispositivo` + zona México; frágil cerca de medianoche — preferible el campo.)
2. **Filtro `persona_id` y/o `dia_id` en `GET /api/dias`** (hoy: `busqueda_persona` por texto, `desde`, `hasta`, `estado`). Para que "Ir a revisar el día" caiga exactamente en la fila sin homónimos. Mientras tanto el enlace usaría `persona` (texto) + `desde=hasta=fecha`, y `DiasPage` tendría que leer esos query params (trabajo de frontend; hoy no lee ninguno).
3. (Opcional) **`persona_id`/`dia_id`/fecha local en `MarcaListaItem`** para no calcular la fecha en cliente.

## Preguntas abiertas para el usuario
1. **Tabla o tarjetas** en Excepciones de día cerrado (02): recomiendo tabla (coherente con el resto de Tiempo); las tarjetas quedan como alternativa.
2. **¿Selector "Tipo" (Todas / Día cerrado) en la cola de excepciones**, o una sola lista con la acción adaptada por fila? Recomiendo el selector (usa el `?tipo=` del backend).
3. **Resuelto:** `fn_dia_revisar` resuelve las excepciones de las marcas que quedan dentro de un tramo; si una quedara sin pareja bloquea todo (SCJ09) y no resuelve nada. El aviso de 04 lo dice así.
4. **"Marca (hora efectiva)"**: `ExcepcionOut` trae `momento_dispositivo`, no `momento_efectivo`. Para marcas de día cerrado coinciden (no se pueden corregir), así que alcanza; si backend prefiere exponer `momento_efectivo`, se cambia sin rediseño.
5. **¿Puede `motivo_bloqueo_correccion` venir no-nulo con `excepcion_pendiente_id = null`?** El diseño muestra el bloqueo sólo cuando hay excepción pendiente (si no, "—", como hoy: nada que corregir). Confirmar.
6. **Tuteo vs. voseo** en el copy nuevo: propuse tú (como los mensajes del backend); la app mezcla ambos hoy.
7. **Descartar** pide sólo motivo. ¿Debe mostrarse también quién/cuándo en el historial de la excepción? (Ahora no hay pantalla de excepciones resueltas; no se diseñó.)

## Decisiones del usuario (revisión en tablet)
Paquete 1 aprobado. Respuestas: 1 tabla; 2 selector Tipo; 4 `momento_dispositivo` alcanza; 5 asunción correcta; 6 tuteo; 7 sin pantalla de resueltas. Ajuste: en 04 la lupa del buscador flotaba y los filtros quedaban pegados al banner. Causa: el icono estaba envuelto en un `<span>`, y el CSS real ancla `svg.icono-campo` (absoluto) sólo si el svg es hijo directo de `.campo-con-icono`. Corregido en 01, 02 y 04, más aire entre bloques apilados y menos padding bajo 1100px.
