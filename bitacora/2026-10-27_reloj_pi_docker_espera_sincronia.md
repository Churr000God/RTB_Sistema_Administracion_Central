# 2026-10-27 · Reloj del Pi sin RTC: Docker no esperaba la sincronía (P-056)

**Participantes:** usuario (Diego), `sistemas-ce`, `orchestrator`, `devops`, `security`, `backend`.
**Modo:** solo lectura en el Pi de pruebas; cambios solo en el repo, sin commit.

---

## Qué se hizo

P-056 pedía llevar al repo el arreglo del 17-sep (`systemd-time-wait-sync` habilitado en el Pi de pruebas). Al
revisarlo en el Pi se vio que el arreglo nunca funcionó, y al revisar el incidente original se vio que su causa tampoco
fue el reloj.

## Hallazgos (verificados por `devops`, `security` y `backend`, solo lectura)

- **Pi de pruebas:** Debian 13, systemd 257.9, sin RTC (`RTC time: n/a`, sin `/dev/rtc*` ni fake-hwclock),
  `systemd-timesyncd` activo, chrony inactivo.
- **El arreglo del 17-sep no es efectivo.** `docker.service` es la unidad de fábrica (sin drop-ins) y solo tiene
  `After=time-set.target`. `systemd-time-wait-sync` está habilitado pero solo retrasa `time-sync.target`, que Docker no
  espera. `TimeoutStartUSec=infinity` de fábrica.
- **Arranque del 26-oct (reloj monotónico):** time-wait-sync a los 4.4 s; Docker empieza a los 21.65 s con la hora
  vieja (09:00:56); timesyncd sincroniza a los 37.0 s (salto a 09:58:48); Docker termina de iniciar a los 43.45 s.
  Docker corrió **~15 s** con el reloj atrasado **~58 min**. El atraso es lo que estuvo apagado el Pi (la hora inicial
  sale del mtime de `/var/lib/systemd/timesync/clock`). La sincronía tardó 31 s desde el primer cambio de red: normal.
  - Primera lectura de `sistemas-ce` («Docker corrió 58 min con la hora vieja», «NTP tardó 58 min»): **errónea**,
    comparó horas de antes y después del salto.
- **PGRST303 del 17-sep (`backend`):**
  - El job fallido fue `cierre_dia`, no el corte quincenal (ver la corrección en la bitácora del 17-sep).
  - El batch usa `service_role` con la llave opaca `sb_secret_` (41 caracteres; solo se leyó prefijo y largo). El backend
    no firma JWT. Con esa llave el gateway de Supabase acuña el JWT con su reloj: un desfase entre gateway y PostgREST
    da «JWT issued at future» aunque el Pi esté bien (offset ~1 ms ese día).
  - Confianza alta en que no fue el Pi; media-alta en lo de Supabase (logs del 17-sep perdidos, no se confirmó que en
    septiembre ya se usara `sb_secret_`).
- **`puente.service` (checador):** `devops` y `security` coinciden en no hacerlo esperar a Tailscale ni a `time-sync`.
  Con la sincronía caída o desfase > 60 s la marca sale `sin_sincronizar` (`reloj.py`, `ingesta.py`), el servidor solo
  empeora el estado y abre la excepción `reloj_no_sincronizado`, y el cursor `min(Pi, terminal)` evita perder marcas.

## Qué se cambió en el repo (sin commit)

- `despliegue/host/docker.service.d/10-esperar-hora.conf`: `Wants=` + `After=time-sync.target`.
- `despliegue/host/systemd-time-wait-sync.service.d/10-tope-espera.conf`: `TimeoutStartSec=3min` (la sincronía normal
  tarda ~37 s; con tope, sin internet Docker arranca igual a los 3 min).
- `scripts/preparar_hora_host.sh` (`verificar` / `instalar`): detecta RTC por `timedatectl` o `/dev/rtc*`, detecta el
  demonio de hora y avisa si chrony no tiene `rtcsync`, avisa si time-wait-sync venció el tope en este arranque, y
  reporta sin cortarse si la verificación final encuentra algo.
- `docs/07-procesos/ARRANQUE_PI_DE_PRUEBAS.md` §0 nueva.
- `bitacora/2026-09-17_…`: nota de corrección al inicio.

## Qué quedó pendiente

- **Aplicar en el Pi de pruebas:** Diego corre `scripts/preparar_hora_host.sh instalar` tras `git pull`; aplica en el
  siguiente reinicio. Después, `verificar`.
- **Lecturas en el Pi del checador** (sesión del Checador, solo lectura): `PUENTE_VERIFICAR_SINCRONIA_PI`, `operador
  estado`, `timedatectl`, chrony (`makestep`, `local`, `rtcsync`, NTS) y si el firmware V1.3.0 respeta `LI=unsync`.
- **Para después (decisión de Diego):** reintentar una vez ante PGRST303 en el backend; caso con soporte de Supabase si
  se repite; comparar la hora del host contra `now()` de la base antes de cada batch (sugerencia de `security`).
