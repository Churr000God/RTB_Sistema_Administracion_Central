## Incidente DNS Docker (28-sep-2026)

Los contenedores de la Raspi de producción (`raspberrypi-serverpruebas`, Tailscale
`100.115.160.115`) quedaron sin resolver DNS (`Temporary failure in name resolution`)
porque Docker escribe el `resolv.conf` de un contenedor solo al crearlo, copiando el
resolver del host en ese momento. Al cambiar la Raspi de red (de `192.168.68.x` a la
actual `192.168.10.x`), los contenedores ya creados quedaron reenviando DNS a un
router que ya no existe.

Fix aplicado: recrear los contenedores en la Raspi para que regeneren el resolv.conf
con el DNS actual (`100.100.100.100`, Tailscale MagicDNS).

**Ojo con este repo especifico:** produccion se despliega con dos archivos
combinados (`docker-compose.yml` dev + `docker-compose.prod.yml` override, ver
comentario en `docker-compose.prod.yml`). Cualquier `docker compose ... up` /
`--force-recreate` en la Raspi debe llevar SIEMPRE:

```
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --force-recreate
```

Correrlo sin el `-f docker-compose.prod.yml` recrea el servicio `frontend` con la
config de **dev** (puerto 5173, healthcheck a 5173) mientras la imagen ya construida
sigue siendo la de **prod** (nginx sirviendo el bundle en el puerto 80) — nginx nunca
escucha en 5173 y el contenedor queda marcado `unhealthy` en bucle, aunque la app
funcione bien puertas adentro. Ya paso una vez (28-sep-2026), se corrigio recreando
con ambos archivos.

Fix de raiz del DNS pendiente (no aplicado a proposito, decision explicita): fijar
DNS explicito en `/etc/docker/daemon.json` de la Raspi o en `dns:` de cada
`docker-compose.yml`, para no depender de un snapshot del host.

Detalle completo: RTB-TIN-17 en Nextcloud Sistemas (01-TI/RTB-TIN).
