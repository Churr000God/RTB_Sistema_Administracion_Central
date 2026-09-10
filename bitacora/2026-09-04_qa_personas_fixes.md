# Segundo bloque del 4 de septiembre: fixes puntuales, normalizadores, security y calidad visual

**Participantes:** `orchestrator` (coordinación) · `frontend` (login/normalizadores/calidad
visual/botón de alta) · `backend` (normalizadores/fix de usuario huérfano/campo `tiene_usuario`) ·
`security` (auditoría de inyección SQL) · `testing` (verificación e2e final) · cuatro tareas
decididas por el usuario, sin dependencias entre sí salvo la última con backend.

**Duración:** 4 de septiembre de 2026, tras el cierre del QA de mockups
(`2026-09-04_qa_personas_mockups.md`).

---

## Contexto

Con el QA de las 14 pantallas cerrado, el usuario pidió un segundo bloque de trabajo más chico:
un fix visual, una pasada de calidad, dos normalizadores de datos y un bug funcional real. Se
trabajó en paralelo (frontend/backend/security), sin push hasta coordinar, reportando tarea por
tarea.

## Los cinco frentes

1. **Login centrado verticalmente en pantallas grandes** (`226d4c4`, frontend) — `.zona-formulario`
   sólo tenía `place-items: start center` heredado de un breakpoint menor; en `≥64rem` el panel
   quedaba pegado arriba en vez de centrado. Fix de una línea (`place-items: center` en el media
   query de `64rem`).

2. **Normalización de CURP/RFC a mayúsculas** (`33ef25c` frontend, `4f177a0` backend) — defensa en
   profundidad. Frontend: `AltaPersonaPage.tsx` normaliza en `onChange` (mutación directa de
   `currentTarget.value`, sin pasar por estado de React) más `textTransform: uppercase` para evitar
   un frame en minúsculas. Backend: `field_validator` en `PersonaCreate` normaliza igual del lado
   del servidor, para que la garantía no dependa sólo del cliente.

3. **Bug de usuario huérfano en Supabase Auth** (`ed7ef24`, backend) — la restricción `UNIQUE` de
   `personas.usuario` (`persona_id`) ya existía en el DDL y nunca permitió duplicados reales en la
   tabla. El bug era de secuencia: `POST /api/usuarios` invitaba por correo (creaba el usuario en
   Supabase Auth) *antes* de insertar la fila en `personas.usuario`; si el insert fallaba después
   (por ejemplo, por el mismo `UNIQUE` en un doble-submit), quedaba un usuario de Auth sin fila
   correspondiente — huérfano, sin acceso a la app pero ocupando el correo/alias. Fix: rollback
   explícito (borra el usuario de Auth) si el insert posterior falla.

4. **Auditoría de inyección SQL** (security, sin commit — sin hallazgos) — revisión del acceso a
   datos del módulo Personas y Usuarios. Conclusión: sin superficie real de ataque. El diseño ya lo
   cubre por construcción — `supabase-py` parametriza todas las consultas (nunca concatena SQL a
   mano) y Pydantic valida/tipa cada payload antes de que llegue a la capa de datos. Sin cambios de
   código, documentado como auditoría cerrada.

5. **Bug real: "Alta de usuario" inalcanzable desde la UI** (`0aef661` backend, `842d797`
   frontend) — la ruta `/usuarios/nuevo` existía y funcionaba, pero ningún lugar de la app
   enlazaba a ella; sólo se llegaba tipeando la URL a mano. El usuario, consultado explícitamente
   (`AskUserQuestion`), eligió condicionar el punto de entrada a si la persona ya tiene usuario
   vinculado, en vez de mostrarlo siempre. Backend agregó `tiene_usuario: bool` a
   `GET /api/personas/{id}` (`PersonaConExpediente`). Frontend agregó el botón "Crear acceso a
   Kairos" en la cabecera de `FichaPersonaPage`, oculto cuando `tiene_usuario` es `true`, con
   deep-link a `/usuarios/nuevo?persona_id={id}`; `AltaUsuarioPage` pasó a controlar su `<select>`
   de persona y preselecciona ese `persona_id` desde el query param.

## Calidad visual, sin tocar la restricción de "cero datos nuevos"

**Pasada de calidad visual en 09/10/11/12/13/14** (`d4e05a4`, frontend) — típica ronda de pulido
(tipografía, espaciado, jerarquía, sombras, microinteracciones), explícitamente sin agregar ningún
campo que no exista en la base real (restricción dura documentada en
`NOTAS_campos_extra_mockups.md`: puesto, área, número de empleado, banco de horas, asistencia,
etc. siguen fuera de alcance). Cambios: hover en filas de tabla, spinners consistentes (`Loader2`
en vez de texto plano "Cargando…"), feedback de click en botones (`scale(0.98)`), fuente
monoespaciada para identificadores (CURP/RFC/NSS/`documento_ref`, token `--font-mono` nuevo),
`tabular-nums` en métricas, estado vacío con ícono en vez de `<p>` pelado, y un bug real de CSS
corregido de paso: `.boton-con-icono` sólo aplicaba `display:inline-flex` a `button`/`a` — un
`<p className="boton-con-icono">` ya usado en `Configurar2FAPage` nunca había tenido el layout
correcto. Documentado en detalle en `qa/REPORTE_QA_personas.md`. Explícitamente se descartó
aplicar la parte del checklist de la skill de rediseño orientada a landing pages (glassmorphism,
parallax, gradientes) — contradiría la fidelidad ya validada a los mockups "Kairos".

## Verificación final

**Testing** (`262e370`) verificó en vivo con sesión real, sin regresiones sobre lo anterior.

## Conteos de tests al cierre de este bloque

- Backend: 16 → **19** casos (`uv run pytest`).
- Frontend: 87 → **91** casos (`npm test`).
- `npx tsc -b` limpio.

## Qué quedó pendiente

- Nada nuevo de este bloque quedó abierto — los cinco frentes cerraron con commit y verificación.
- Sigue pendiente lo ya conocido de la tanda anterior (responsive completo, roles/autorización real
  en `POST /api/usuarios`, puesto/área/departamento fuera de alcance a propósito).
