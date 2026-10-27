# 2026-09-17 · Falla del corte quincenal automático por reloj del Pi + fix de boot NTP

> **Corrección del 27-oct-2026 (P-056).** Tres afirmaciones de esta bitácora resultaron falsas o no demostradas.
> Se dejan abajo como se escribieron; lo vigente es esto. Detalle en `2026-10-27_reloj_pi_docker_espera_sincronia.md`.
>
> 1. **El job que falló fue `cierre_dia` (procesaba el 16-sep), no el corte quincenal.** El traceback
>    `scheduler.py:68` corresponde a la lambda de `cierre_dia` en `e5408ba`, y el corte solo corre los días 1 y 16. El
>    `intentos=2` del corte con fecha 16 es el cron del 16 más el disparo manual del 17: probablemente el corte nunca falló.
> 2. **La causa no fue el reloj del Pi** (no demostrada). El Pi tenía ~1 ms de offset. El backend usa la llave
>    `sb_secret_`, con la que Supabase acuña el JWT con su propio reloj; lo más probable es un desfase dentro de Supabase.
>    Los logs ya no existen (contenedor recreado el 21-oct).
> 3. **El «fix» no bloqueaba el arranque de Docker.** Habilitar `systemd-time-wait-sync` solo retrasa
>    `time-sync.target`, y `docker.service` solo espera `time-set.target`. El arreglo efectivo está en
>    `despliegue/host/` + `scripts/preparar_hora_host.sh` (pendiente de aplicar en el Pi).

**Participantes:** usuario, `orchestrator`, `devops`.
**Duración:** corta (una consulta del usuario sobre la pantalla de Banco de Horas terminó en un
hallazgo de infraestructura real).

---

## Qué se hizo

El usuario reportó que Diego Guillén (usuario base de bootstrap) aparecía con "corte pendiente" en
Banco de Horas aunque su saldo estaba en 0.00h sin deuda. Se explicó primero que `corte_pendiente`
es una alerta preventiva (`app/prevision_corte_quincenal.py`) sobre si el batch de corte quincenal
ya corrió para el último periodo vencido — no mide deuda.

El usuario disparó manualmente el corte quincenal dos veces desde el panel (fecha 2026-09-15 →
periodo 16-31 agosto; fecha 2026-09-16 → periodo 1-15 septiembre), ambos con `200 OK`, y pidió
investigar por qué el primero había fallado antes.

Con lectura autorizada (`SELECT` de sólo lectura sobre `tiempo.corrida_batch` vía REST +
`service_role`, aprobación explícita del usuario) se confirmó:

```
fecha=2026-09-16  intentos=2  estado=exitosa
fecha=2026-09-15  intentos=1  estado=exitosa
```

`intentos=2` en la fila del 16 apuntaba a un intento previo fallido. Con acceso SSH autorizado por
el usuario al Pi de pruebas (`raspberrypi-serverpruebas`, ver memoria `reference-ssh-pi-deploy`),
se encontró en los logs del backend el error real, de la corrida automática del scheduler
(`app/scheduler.py`, job de madrugada) a las **2026-09-17T03:00:01 UTC**:

```
File ".../app/scheduler.py", line 68
File ".../app/batches/_orquestacion.py", line 54, in upsert_corrida_en_progreso
postgrest.exceptions.APIError: {'message': 'JWT issued at future', 'code': 'PGRST303', ...}
```

Se delegó a `devops` (vía `team-orchestrator`) investigar la sincronización horaria del Pi.

## Qué se decidió

- **Causa raíz confirmada por `devops`**: no fue el reloj en el momento del incidente (NTP activo,
  offset ~1ms, sin errores en esa ventana) sino un hueco estructural — el Pi no tiene RTC
  (`RTC time: n/a`), y `docker.service` sólo esperaba `time-set.target` (hora aproximada, no
  confirmación real de sync NTP). `systemd-time-wait-sync.service` estaba **disabled**. En
  cualquier reboot (corte de luz, mantenimiento) los contenedores pueden arrancar con el reloj
  todavía sin resincronizar de verdad, reproduciendo el mismo `PGRST303` (el JWT `service_role`
  parece "emitido en el futuro" si el reloj del host está atrasado en ese instante).
- **Fix aplicado en el host** (fuera del repo, sólo config de systemd):
  `systemctl enable --now systemd-time-wait-sync.service` — el boot ahora bloquea hasta
  confirmar sync NTP real antes de que arranque `docker.service`. Verificado enabled + activo.
  Sin tocar `app/scheduler.py`, `db/ddl/` ni `docker-compose.prod.yml`; sin commits.
- No es bug de lógica de negocio del corte quincenal — el algoritmo de `corte_quincenal.py` es
  correcto, sólo la infraestructura del Pi permitía una ventana de arranque con reloj no confiable.

## Qué quedó pendiente

- **Persistencia de journald** (`Storage=persistent` en `/etc/systemd/journald.conf`, para tener
  evidencia si este tipo de incidente vuelve a pasar): el `sed` de `devops` aplicó el cambio
  correctamente (confirmado con `grep`), pero el journal sigue escribiendo sólo en volátil
  (`/run/log/journal`) tras el restart — no crea `/var/log/journal/<machine-id>`. Diagnóstico de
  permisos/ACL/espacio en disco salió limpio, causa no encontrada. El siguiente paso obvio
  (`mkdir`/`chown` manual del subdirectorio) lo bloqueó el permission classifier de la sesión de
  `devops` sobre un directorio de sistema en host de producción — no se insistió, correctamente.
  **Decisión del usuario (esta sesión): dejarlo así por ahora, pendiente de activarse cuando el
  proyecto salga a producción real** (no es la causa del incidente, es hardening secundario de
  observabilidad).
- Este es el **Pi de pruebas** (`raspberrypi-serverpruebas`), no el servidor de producción real de
  RTB. Al preparar el servidor de producción definitivo, replicar ahí también:
  1. `systemctl enable --now systemd-time-wait-sync.service` (o el equivalente si ese host sí
     tiene RTC — verificar con `timedatectl show -p RTCTimeUSec`).
  2. `Storage=persistent` en `journald.conf` + crear `/var/log/journal/` a mano si el auto-create
     no dispara igual que acá.

## Preguntas nuevas

- ¿Por qué `mkdir`/`chown` en `/var/log/journal/` no lo crea automáticamente `systemd-journald`
  pese a que la config y los permisos del filesystem están correctos? No se investigó a fondo, sólo
  se dejó documentado como bloqueado por permisos de sesión, no como misterio técnico resuelto.

## Nota para la retrospectiva

Mismo patrón que el gotcha de zona horaria del 11 de septiembre (`_desfase_local_en` resolviendo
UTC del contenedor): otra vez un supuesto "problema de lógica" resultó ser un problema de reloj de
infraestructura, encontrado siguiendo evidencia real (logs) en vez de adivinar. Vale la pena, antes
de asumir "bug de código" en cualquier fallo puntual y no reproducible de un batch/scheduler,
revisar primero si hay desfase de reloj en el host — ya son dos incidentes de esta familia.
