# Arranque del Pi de pruebas (`raspberrypi-serverpruebas`)

Todo lo necesario para reconstruir ese Pi desde git. Sin secretos: de los `.env` solo se nombran las claves y los valores
que no son secretos. Versionado el 16 de octubre de 2026 (antes vivía solo en el Pi, en ediciones manuales).

## 0. Reloj del host (antes de levantar contenedores)

El Pi no tiene RTC: al encender, el reloj arranca con la hora guardada al apagar (atrasado tanto como estuvo apagado) y
salta a la hora real cuando `systemd-timesyncd` sincroniza, unos 37 s después. Si Docker arranca antes, el scheduler,
`hoy_mexico()`, los registros y TLS ven una hora falsa durante esos segundos.

```
scripts/preparar_hora_host.sh verificar   # solo lee
scripts/preparar_hora_host.sh instalar    # sudo; aplica en el siguiente arranque
```

`instalar` habilita `systemd-time-wait-sync.service` y copia dos drop-ins de `despliegue/host/`: uno ordena
`docker.service` después de `time-sync.target` y otro pone un tope de 3 min a la espera, para que Docker arranque aunque
no haya internet. Habilitar solo `systemd-time-wait-sync` no basta: `docker.service` de fábrica solo espera
`time-set.target`. Así quedó el Pi del 17-sep al 27-oct; en el arranque del 26-oct Docker empezó ~15 s antes del salto
de ~58 min. Si el host tiene RTC, el script no instala nada. Si el host usa chrony, necesita `rtcsync` (el script avisa).

Esto **no** resuelve el `PGRST303` («JWT issued at future») del 17-sep: con la llave `sb_secret_` el JWT lo acuña
Supabase con su propio reloj, y la causa probable es un desfase dentro de Supabase. Ver
`bitacora/2026-10-27_reloj_pi_docker_espera_sincronia.md`.

## 1. Contenedores

Una sola vez por clon (archivo local, no versionado):

```
echo pi > ~/RTB-CRM-APP/.perfil-despliegue
```

Despliegue:

```
cd ~/RTB-CRM-APP
./scripts/desplegar.sh prod levantar backend    # sólo el backend; el frontend sigue arriba
./scripts/desplegar.sh prod levantar frontend   # sólo el frontend (exporta las VITE_* de frontend/.env para el build)
./scripts/desplegar.sh prod levantar            # los dos (corte de ambos)
```

`docker-compose.pi.yml` (versionado) aporta lo específico del Pi: el backend escucha solo en `127.0.0.1:8000`, la red
`rtb-crm-app_default` tiene la subred fija `172.19.0.0/16` y los logs rotan (10 MB × 3). El script lo suma solo cuando el perfil
es `pi`, que lee de `.perfil-despliegue` (la variable `DESPLEGAR_PERFIL`, si trae valor, gana sobre el archivo; vacía no cuenta;
`DESPLEGAR_PERFIL=ninguno` lo apaga a propósito). Antes de cada `levantar`/`reconstruir` imprime el perfil y los archivos compose.

Protecciones (desde el 30-oct-2026, tras dos incidentes):

- **Perfil olvidado.** El 29-oct un despliegue sin el perfil dejó el backend en `0.0.0.0:8000` (API en http plano por la LAN).
  Ahora, si `tailscale serve` publica `127.0.0.1:8000` y el perfil no es `pi`, el script corta con error. En una máquina sin
  `tailscale` no se aplica.
- **Red recreada en un despliegue parcial.** El 30-oct, `up -d --no-deps backend` a mano con el IPAM recién agregado falló:
  compose quiso recrear la red con el frontend conectado y dejó el backend caído ~1 min. Antes de un `levantar <servicio>` el
  script simula con `docker compose --dry-run`; si compose planea borrar una red, no hace el parcial y pide confirmación para
  un down + up completo (sin terminal interactiva, cancela).
- Sin `uv` en el host (el Pi), el script avisa y omite la verificación de esquema y el bootstrap del usuario base, en vez de
  terminar con `uv: orden no encontrada`. La verificación de migraciones hay que hacerla desde una máquina con `uv`.

No uses `docker compose … up -d --no-deps` a mano: se salta las dos protecciones.

## 2. `tailscale serve` (no vive en el compose)

```
sudo tailscale serve --bg --https=443  http://127.0.0.1:8000    # API; el puente llega por aquí (/api/terminal/*)
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8080    # SPA con HTTPS (enlaces de invitación)
```

Backend y frontend escuchan solo en `127.0.0.1` (8000 y 8080, por `docker-compose.pi.yml`): desde el 30-oct-2026 la SPA ya
no se alcanza por `http://<ip>:8080`, solo por el 8443 de `tailscale serve`.

## 3. `.env` del Pi (permisos 600; la copia del frontend, 664, solo lleva `VITE_*`)

- `FRONTEND_URL="https://raspberrypi-serverpruebas.tail3e5009.ts.net:8443"`: el PRIMER origen se usa como `redirect_to` de
  las invitaciones y debe ser un dominio con HTTPS (una IP literal con `http` dispara el WAF de Cloudflare: 403 HTML, la
  invitación falla). Los demás orígenes son para CORS. El segundo origen histórico, `http://100.115.160.115:8080`, quedó
  muerto con el bind a `127.0.0.1` del 30-oct-2026 (inofensivo; se puede quitar).
- `TERMINAL_PROXIES_CONFIANZA=172.19.0.1`: el gateway de la subred fija; es la IP que ve el backend para lo que entra por
  `127.0.0.1:8000` (por eso la subred no debe cambiar).
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` y el resto de `.env.example` (secretos: no se versionan).

## 4. Supabase (dashboard)

Authentication → URL Configuration: **Site URL** y **Redirect URLs** deben incluir
`https://raspberrypi-serverpruebas.tail3e5009.ts.net:8443/**` (y `http://localhost:5173/**` para desarrollo).

## 5. Verificación tras un despliegue

`/salud` 200 por `127.0.0.1:8000` y por el 443; bundle nuevo por `127.0.0.1:8080` y el 8443; `ss -tlnp` sin 8000 ni 8080 en
`0.0.0.0`; `docker inspect` con `LogConfig` json-file 10m/3;
latidos del puente 200 en el log del backend; líneas `app.latencia` sin ids ni correos.

## 6. Firewall del host

- **No habilitar `nftables.service` ni usar `/etc/nftables.conf`.** El de fábrica de Debian empieza con `flush ruleset`: al
  arrancar borraría las reglas de Docker (NAT de los puertos publicados) y las de Tailscale. Se deja enmascarado
  (`systemctl mask nftables.service`).
- `ufw` no está instalado y no se instala: no ve lo que Docker publica (DNAT antes de INPUT).
- Las reglas propias viven en tablas `inet rtb_filtro_*` (una por archivo en `/etc/rtb-filtro/*.nft`), cargadas en el arranque
  por `rtb-filtro-host.service`; Docker y Tailscale nunca tocan esas tablas. `systemctl stop rtb-filtro-host` las borra todas.
- Para lo publicado por Docker se filtra por el puerto ORIGINAL (`ct original proto-dst`), porque tras el DNAT el puerto ya es el
  del contenedor; las reglas se escriben en positivo (solo saltan al filtro los paquetes TCP del puerto en cuestión).
