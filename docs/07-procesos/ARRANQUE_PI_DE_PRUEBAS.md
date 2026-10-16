# Arranque del Pi de pruebas (`raspberrypi-serverpruebas`)

Todo lo necesario para reconstruir ese Pi desde git. Sin secretos: de los `.env` solo se nombran las claves y los valores
que no son secretos. Versionado el 16 de octubre de 2026 (antes vivía solo en el Pi, en ediciones manuales).

## 1. Contenedores

```
cd ~/RTB-CRM-APP
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.pi.yml up -d --no-deps backend
# frontend (las VITE_* son de build; se cargan de frontend/.env):
bash -c "set -a; source frontend/.env; set +a; docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.pi.yml build frontend"
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.pi.yml up -d --no-deps frontend
```

`docker-compose.pi.yml` (versionado) aporta lo específico del Pi: el backend escucha solo en `127.0.0.1:8000`, la red
`rtb-crm-app_default` tiene la subred fija `172.19.0.0/16` y los logs rotan (10 MB × 3). Con `./scripts/desplegar.sh` el perfil
se activa con `DESPLEGAR_PERFIL=pi` (ojo: ese script recrea backend y frontend a la vez y exige `uv` en el host, que el Pi no
tiene; por eso los despliegues se hacen con los comandos de arriba).

## 2. `tailscale serve` (no vive en el compose)

```
sudo tailscale serve --bg --https=443  http://127.0.0.1:8000    # API; el puente llega por aquí (/api/terminal/*)
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8080    # SPA con HTTPS (enlaces de invitación)
```

La SPA también se alcanza por `http://100.115.160.115:8080`.

## 3. `.env` del Pi (permisos 600; la copia del frontend, 664, solo lleva `VITE_*`)

- `FRONTEND_URL="https://raspberrypi-serverpruebas.tail3e5009.ts.net:8443,http://100.115.160.115:8080"`: el PRIMER origen se
  usa como `redirect_to` de las invitaciones y debe ser un dominio con HTTPS (una IP literal con `http` dispara el WAF de
  Cloudflare: 403 HTML, la invitación falla). Los demás orígenes son para CORS.
- `TERMINAL_PROXIES_CONFIANZA=172.19.0.1`: el gateway de la subred fija; es la IP que ve el backend para lo que entra por
  `127.0.0.1:8000` (por eso la subred no debe cambiar).
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` y el resto de `.env.example` (secretos: no se versionan).

## 4. Supabase (dashboard)

Authentication → URL Configuration: **Site URL** y **Redirect URLs** deben incluir
`https://raspberrypi-serverpruebas.tail3e5009.ts.net:8443/**` (y `http://localhost:5173/**` para desarrollo).

## 5. Verificación tras un despliegue

`/salud` 200 por el 8000 y por el 443; bundle nuevo por el 8080 y el 8443; `docker inspect` con `LogConfig` json-file 10m/3;
latidos del puente 200 en el log del backend; líneas `app.latencia` sin ids ni correos.
