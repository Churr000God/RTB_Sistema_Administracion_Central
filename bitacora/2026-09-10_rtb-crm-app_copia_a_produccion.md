# 2026-09-10 · — RTB-CRM-APP: copia a producción real, identidad de marca y Supabase productivo

**Participantes:** usuario, `orchestrator` + equipo de 4 especialistas (`frontend`, `db`,
`devops`, `security`) vía `team-orchestrator`
**Duración:** una sesión larga

---

## Qué se hizo

Este repositorio (académico, anonimizado) llegó a estar funcionalmente completo. El usuario pidió
ejecutar lo que `RTB-ACA-01 §VIII` (documento externo, Nextcloud) ya preveía: copiarlo a un
repositorio real de la empresa, con su identidad de marca, base de datos propia y auditado.

Se creó `/home/diego/Proyectos/RTB-CRM-APP` (copia limpia, sin el `.git` de este repo), pusheado a
`https://github.com/Churr000God/RTB_Sistema_Administracion_Central`. **Este repositorio no se
tocó** — sigue congelado tal como estaba.

Hallazgo que redujo el trabajo de rebranding a la mitad: la paleta/tipografía de
`frontend/src/styles/tokens.css` ya coincidía hex por hex con el brandbook real de RTB, y el
organigrama sembrado en `db/ddl/11,13,15,16_*.sql` ya era la estructura real de la empresa (la
"anonimización" nunca tocó nombres de puesto porque ya eran genéricos de función) — sólo hicieron
falta correcciones de comentario, no de datos.

Trabajo delegado al equipo: `frontend` hizo el rebranding completo (logo, hero, correos,
sustitución de "Kairos"/"Distribuidora Central"); `db`+`devops` prepararon la aplicación del DDL
(script + verificación) y el checklist de configuración de Supabase; `security` corrió una
auditoría estática (inyección SQL, RLS, GRANTs, secretos) sin hallazgos críticos ni altos.

Después de eso, una ronda larga de QA en vivo del usuario contra la app real encontró y corrigió
varios bugs reales: formato incorrecto del folio de expediente (`RTB-XX-XX` genérico en vez del
real `RTB-RH-EIT-<año>-<número>`, causaba un 500 que el navegador mostraba como error de CORS),
UI de Asignar Jornada con controles redundantes, el logo de los correos transaccionales que no
tomaba el círculo de fondo porque viven con su propia copia base64 independiente del PNG del
sitio, y un `ARG` faltante en `frontend/Dockerfile` para las variables de correo de contacto.

Desplegado en modo producción en el servidor de pruebas de la red de RTB (Raspberry Pi por
Tailscale, decisión explícita de no usar el VPS ni exponer a internet). Verificado end-to-end:
login + MFA reales, RLS deny-by-default confirmado con `curl` directo a PostgREST.

## Qué se decidió

- La anonimización se levanta **sólo** para `RTB-CRM-APP` — este repositorio sigue siendo el
  ejercicio académico anónimo.
- Nombre de producto en la UI: "RTB — Sistema de Administración Central" (no "Kairos", no sólo
  "Control de jornada" — el sistema ya cubre más que jornada).
- Producción real corre en un servidor local vía Tailscale, no en un VPS ni expuesta a internet.
- Sólo se dio de alta una persona real por ahora (el admin) — el resto de la plantilla de RTB
  queda para después, no bloquea.

## Qué quedó pendiente

- Dar de alta al resto de la plantilla de RTB (~13 puestos del organigrama real).
- Verificación de bypass de RLS con una cuenta de permisos limitados (hace falta una segunda
  cuenta real).
- Documentos de Notion — pendiente de que el usuario confirme qué páginas actualizar.
- SVG vectorial real del logo (favicon hoy es el logo completo reescalado, no el monograma).

## Preguntas nuevas

-

## Nota para la retrospectiva

Vale la pena registrar como patrón general: cuando un proyecto académico anonimiza cambiando sólo
identidad (nombres de persona, empresa) mientras deja committed a un diseño con nombres genéricos
de dominio (puestos, colores de marca ya elegidos con la empresa real en mente), la "copia a
producción" termina siendo mucho más rebranding superficial que trabajo estructural — el diseño ya
estaba bien encaminado desde el principio. No asumir que hay que rehacer nada sin verificar primero
qué tan genérica era realmente la anonimización original.
