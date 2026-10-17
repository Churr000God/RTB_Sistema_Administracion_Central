# Pendientes de UX en Asignar jornada (anotados, sin implementar)

Origen: `orchestrator`, al armar la guía de RH. Verificados en vivo en la app de pruebas el 17 de octubre de 2026.
Archivo: `frontend/src/pages/AsignarJornadaPage.tsx`. Estado: **solo anotados; sin código ni commit**.

## 1. Texto de confirmación de Renovar (~línea 889)
Hoy: «¿Cerrarla y dejar vigente la nueva a partir del día anterior a 2026-10-26?». Engañoso (la anterior termina el 25, la nueva empieza el 26) y la fecha sale en ISO.
Propuesta: «Esta persona ya tiene una jornada vigente. La actual terminará el {formatearFecha(sumarDiasISO(vigente_desde, -1))} y la nueva comenzará el {formatearFecha(vigente_desde)}. ¿Continuar?» Reusa `formatearFecha` y `sumarDiasISO`, que ya existen en la página (línea 820 usa el mismo cálculo).

## 2. Renovar no precarga el patrón semanal
Hay que capturar todos los días otra vez. Ya existe `valoresIniciales` (línea ~383, flujo de edición de una fila) que carga días y horas desde `fila.patron_semanal`. Propuesta: al abrir el formulario de asignar sobre una persona con jornada vigente, precargar `tipoJornada` y `patronPorDia` de esa jornada (con `vigenteDesde` vacío o mañana), con una nota «Precargado de la jornada vigente; ajusta lo que cambie». Sin backend nuevo (el listado de jornadas ya trae `patron_semanal`).

## 3. Persona con jornada solo FUTURA aparece «Sin jornada» (rojo)
Causa: `tiene_jornada_vigente` es booleano (`routers/personas.py::_resolver_personas_con_jornada_vigente`). Propuesta: estado intermedio ámbar «Jornada futura desde {fecha}». **Requiere backend**: exponer `jornada_futura_desde: date | None` junto a `tiene_jornada_vigente` (3 schemas en `schemas/personas.py` + el resolver). Frontend: tercer estado en el badge (línea ~542), conteo y orden («Sin jornada» sigue primero; «futura» después).

## 4. Voseo (el sistema es para México)
- Frontend: `setExito` línea ~222, «Podés asignar otra desde acá mismo.» → «Puedes asignar otra desde aquí mismo.» Conviene barrer toda la app con un grep de `és `/`á ` en cadenas de UI.
- Backend (solo anotado, lo pasa `orchestrator` a `backend`): `routers/jornada_asignada.py` `MENSAJE_VIGENCIA_ACTIVA_SIN_CONFIRMAR` «Confirmá para cerrarla…» y `ERRORES_MOVER_LIMITE` SCJ05 «eliminá…».
