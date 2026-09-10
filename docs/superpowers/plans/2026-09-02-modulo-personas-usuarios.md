# Módulo Personas y Usuarios — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar de punta a punta (base de datos, backend, frontend, tests) los dos procesos
ya cerrados del módulo Personas y Usuarios: `SCJ-PRO-01` (alta de usuario) y `SCJ-PRO-02`
(movimiento de persona), sobre el proyecto de Supabase real del usuario.

**Architecture:** Supabase (Postgres + Auth + Storage) como única fuente de datos y de identidad.
Un backend FastAPI delgado que centraliza las operaciones que necesitan la `service_role` key
(invitar usuarios, orquestar alta persona+expediente+usuario+bitácora en una transacción) y expone
JSON al frontend. El frontend (Vite + React + TypeScript) habla con Supabase Auth directo para
login/2FA/recuperación de contraseña (flujos nativos), y con el backend para todo lo que es lógica
de negocio de Personas. El candado de acceso (`persona.estado = 'activo'`) vive en una RLS policy
de Postgres, no en el backend ni en el frontend — decisión ya cerrada en `SCJ-PRO-02`.

**Tech Stack:** Python 3.11 + FastAPI + `supabase-py` v2 (backend) · React 18 + TypeScript + Vite +
`@supabase/supabase-js` (frontend) · Postgres/Auth/Storage de Supabase (sin ORM propio, el esquema
ya lo define el DDL de este repo) · `pytest` + `httpx` (tests backend) · `vitest` +
`@testing-library/react` (tests frontend) · `uv` para todo lo que es Python, nunca `python3` directo.

**Spec:**
- `docs/07-procesos/SCJ-PRO-01_Proceso_Alta_de_Usuario_V1_0.md`
- `docs/07-procesos/SCJ-PRO-02_Proceso_Movimiento_de_Persona_V1_0.md`
- `diseno_paginas/personas/` (mockups de referencia visual — nombre ficticio "Kairos") y su
  `NOTAS_campos_extra_mockups.md`
- Modelo de datos: Lucid `RTB-APP_DIAGRAMA_V2` (`9015128f-275f-4c42-bf86-85eb41a329f6`), subsistema
  Personas — entidades `persona` (ya tiene DDL, `db/ddl/04_personas.sql`), `expediente`, `usuario`,
  `bitacora_movimiento_persona`.

## Global Constraints

- Español en nombres de esquema/tabla/columna, comentarios SQL y mensajes al usuario final
  (`CONVENCIONES.md §II`, `AGENTS.md`). Identificadores de código Python/TypeScript en inglés
  (idiomático), pero comentarios de código en español.
- `uv run python`, nunca `python3` directo (hook del entorno lo bloquea).
- Ningún archivo con folio `RTB-` ni dato real entra al repositorio (`SCJ-ANO-01`) — todo dato de
  prueba en este plan es sintético.
- `DATABASE_URL` puerto `5432` (directo) solo para DDL/migraciones vía `psql`; puerto `6543`
  (pooler) es el que usa el backend en tiempo de ejecución (`.env.example`).
- La `service_role` key de Supabase **nunca** se expone al frontend — solo vive en el backend.
- El candado de acceso (`persona.estado = 'activo'`) es una RLS policy de Postgres, ya decidido en
  `SCJ-PRO-02` — ningún task de este plan debe reimplementarlo como chequeo de aplicación.
- **Fuera de alcance, a propósito:** `puesto`, `area`, `departamento`, `permiso`, `puesto_permiso`,
  `asignacion` — el usuario ya marcó que eso es un módulo aparte ("asignaciones, áreas, puestos y
  permisos"), todavía sin diseñar. Este plan no crea esas tablas ni endpoints que dependan de ellas.
  Donde un mockup las mostraba (ficha de persona), la implementación se recorta a lo que sí existe
  — ver Task 12.
- El MCP de Supabase conectado en esta sesión **no apunta a la base de datos real del proyecto** —
  ningún task de este plan usa esas herramientas. La aplicación de DDL y la configuración de Auth
  se hacen con `psql`/`supabase` CLI o el dashboard, igual que ya documenta `README.md`.
- No existe todavía un `SCJ-DEC-*` formal para las tablas `expediente`/`usuario`/
  `bitacora_movimiento_persona` (los 9 `SCJ-DEC` existentes son todos del subsistema Tiempo).
  Siguiendo el mismo precedente que se usó para `personas.persona` (decisión de sesión documentada
  en `bitacora/`, no un `SCJ-DEC` nuevo), el Task 1 de este plan escribe esa nota de bitácora antes
  de tocar DDL, para cumplir la regla de `AGENTS.md` ("un cambio de esquema... necesita su propio
  documento de decisión"). Si el usuario prefiere un `SCJ-DEC-10` formal en vez de bitácora, es un
  cambio de una línea en el Task 1, avísenle antes de continuar si no está seguro.

---

## Task 1: Documentar la decisión de esquema antes del DDL

**Files:**
- Create: `bitacora/2026-09-03_estructura_personas_usuario_bitacora.md`

**Interfaces:** Ninguna (documento, no código).

- [ ] **Step 1: Escribir la nota de bitácora**

```markdown
# 2026-09-03 — Estructura de expediente, usuario y bitacora_movimiento_persona

Se implementan en DDL las tres tablas que faltaban del subsistema Personas para poder construir
`SCJ-PRO-01` y `SCJ-PRO-02` de punta a punta: `personas.expediente`, `personas.usuario`,
`personas.bitacora_movimiento_persona`. El diseño ya estaba cerrado en el modelo de Lucid
`RTB-APP_DIAGRAMA_V2` (subsistema Personas, sesión 2026-09-02) — este documento solo formaliza la
decisión de pasarlo a DDL, mismo patrón que se usó para `personas.persona` (sesión 2026-08-31, ver
`bitacora/2026-08-31_campos_persona.md`).

Fuera de alcance a propósito: `puesto`, `area`, `departamento`, `permiso`, `puesto_permiso`,
`asignacion` — módulo aparte, todavía sin proceso de negocio diseñado.

Una desviación del texto literal del diagrama: `bitacora_movimiento_persona.registrado_por` está
anotado en Lucid como `fk usuario.persona_id`, pero `persona_id` no es clave única en
`personas.usuario` (la PK es `auth_user_id`) — Postgres no permite una FK contra una columna sin
restricción de unicidad. Se corrige a `registrado_por uuid REFERENCES personas.usuario(auth_user_id)`,
que es semánticamente lo mismo que pedía el diagrama (qué usuario hizo el movimiento), solo que
apuntando a la clave real de la tabla.
```

- [ ] **Step 2: Commit**

```bash
git add bitacora/2026-09-03_estructura_personas_usuario_bitacora.md
git commit -m "acta: documenta decisión de esquema para expediente, usuario y bitácora"
```

---

## Task 2: DDL de `expediente`, `usuario` y `bitacora_movimiento_persona`

**Files:**
- Create: `db/ddl/05_personas_estructura.sql`

**Interfaces:**
- Consumes: `personas.persona(id)` (ya existe, `db/ddl/04_personas.sql`), `auth.users(id)`
  (gestionada por Supabase).
- Produces: `personas.expediente`, `personas.usuario`, `personas.bitacora_movimiento_persona` —
  usadas por el backend desde Task 6 en adelante.

- [ ] **Step 1: Escribir el DDL**

```sql
-- 05_personas_estructura.sql
-- Completa el subsistema Personas para SCJ-PRO-01/02: expediente, usuario, bitácora de movimiento.
-- Depende de: 00_esquemas.sql, 04_personas.sql
-- Justificación: RTB-APP_DIAGRAMA_V2 (Lucid, subsistema Personas) ·
--   bitacora/2026-09-03_estructura_personas_usuario_bitacora.md

CREATE TABLE personas.expediente (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  persona_id       uuid NOT NULL REFERENCES personas.persona(id),
  tipo_contrato    varchar(30) NOT NULL,
  fecha_firma      timestamptz,
  documento_ref    varchar(50) NOT NULL,
  CONSTRAINT uq_expediente_persona UNIQUE (persona_id),
  CONSTRAINT uq_expediente_documento_ref UNIQUE (documento_ref),
  CONSTRAINT ck_expediente_tipo_contrato
    CHECK (tipo_contrato IN ('indefinido', 'prestacion_servicios', 'por_proyecto')),
  CONSTRAINT ck_expediente_documento_ref_formato
    CHECK (documento_ref ~ '^RTB-[A-Za-z0-9]+-[A-Za-z0-9]+$')
);

COMMENT ON TABLE personas.expediente IS
  'Referencia al expediente físico/digital de la persona. documento_ref es la única referencia '
  '(folio) — el archivo real vive en el bucket de Storage "expedientes", no en esta tabla.';
COMMENT ON COLUMN personas.expediente.documento_ref IS
  'Folio formato RTB-__-__. Único por persona (uq_expediente_persona: una persona, un expediente).';

CREATE TABLE personas.usuario (
  auth_user_id     uuid PRIMARY KEY REFERENCES auth.users(id),
  persona_id       uuid REFERENCES personas.persona(id),
  nombre_usuario   varchar(100) NOT NULL,
  estado           varchar(20) NOT NULL DEFAULT 'activo',
  creado_en        timestamptz NOT NULL DEFAULT now(),
  actualizado_en   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_usuario_persona UNIQUE (persona_id),
  CONSTRAINT ck_usuario_estado CHECK (estado IN ('activo', 'inactivo'))
);

COMMENT ON TABLE personas.usuario IS
  'Cuenta de acceso, ligada 1:1 a auth.users (Supabase Auth) y a lo más 1:1 a personas.persona. '
  'usuario.estado es un interruptor de la cuenta en sí (activo/inactivo), distinto de '
  'persona.estado (el candado real de acceso, ver SCJ-PRO-02) — no se usa para autorización.';

CREATE TABLE personas.bitacora_movimiento_persona (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  persona_id       uuid NOT NULL REFERENCES personas.persona(id),
  tipo_movimiento  varchar(20) NOT NULL,
  fecha_efectiva   timestamptz NOT NULL DEFAULT now(),
  motivo           text,
  documento_ref    varchar(50),
  registrado_por   uuid REFERENCES personas.usuario(auth_user_id),
  creado_en        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_bitacora_tipo_movimiento
    CHECK (tipo_movimiento IN ('alta', 'suspension', 'reactivacion', 'baja_definitiva'))
);

COMMENT ON TABLE personas.bitacora_movimiento_persona IS
  'Fuente de verdad de persona.estado y fecha_baja (ver SCJ-PRO-02) y también registra el alta '
  '(tipo_movimiento = alta, disparado por trg_usuario_bitacora_alta). No registra cambios de '
  'puesto/área — eso es un módulo aparte (asignacion), todavía sin diseñar.';
COMMENT ON COLUMN personas.bitacora_movimiento_persona.registrado_por IS
  'FK a personas.usuario(auth_user_id), no a persona_id: el diagrama de Lucid lo anotaba contra '
  'persona_id, pero esa columna no es única en usuario — ver bitacora/2026-09-03_*.md.';

-- A3 de SCJ-PRO-01: registrar el alta en la bitácora automáticamente al crear el usuario.
CREATE FUNCTION personas.fn_usuario_bitacora_alta()
RETURNS trigger AS $$
BEGIN
  INSERT INTO personas.bitacora_movimiento_persona
    (persona_id, tipo_movimiento, fecha_efectiva, registrado_por)
  VALUES (NEW.persona_id, 'alta', now(), NEW.auth_user_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_usuario_bitacora_alta
  AFTER INSERT ON personas.usuario
  FOR EACH ROW
  WHEN (NEW.persona_id IS NOT NULL)
  EXECUTE FUNCTION personas.fn_usuario_bitacora_alta();

COMMENT ON FUNCTION personas.fn_usuario_bitacora_alta() IS
  'Implementa SCJ-PRO-01 paso A3. registrado_por = el propio usuario recién creado, porque en el '
  'alta todavía no hay "quién más" lo hizo — es un alta administrada por RH vía backend.';

-- A1 de SCJ-PRO-02: sincronizar persona.estado y fecha_baja desde el último movimiento.
CREATE FUNCTION personas.fn_bitacora_sincroniza_persona()
RETURNS trigger AS $$
BEGIN
  IF NEW.tipo_movimiento = 'alta' THEN
    RETURN NEW;
  END IF;

  UPDATE personas.persona
  SET estado = CASE NEW.tipo_movimiento
                 WHEN 'suspension' THEN 'suspension'
                 WHEN 'reactivacion' THEN 'activo'
                 WHEN 'baja_definitiva' THEN 'baja_definitiva'
               END,
      fecha_baja = CASE WHEN NEW.tipo_movimiento = 'baja_definitiva'
                         THEN NEW.fecha_efectiva::date
                         ELSE NULL
                    END
  WHERE id = NEW.persona_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bitacora_sincroniza_persona
  AFTER INSERT ON personas.bitacora_movimiento_persona
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_bitacora_sincroniza_persona();

COMMENT ON FUNCTION personas.fn_bitacora_sincroniza_persona() IS
  'Implementa SCJ-PRO-02: la bitácora es la fuente de verdad, persona.estado/fecha_baja son '
  '[CALCULADO] — nunca se actualizan con UPDATE directo a personas.persona.';
```

- [ ] **Step 2: Aplicar el DDL contra el proyecto de Supabase real**

```bash
source .env
psql "$DATABASE_URL" -f db/ddl/05_personas_estructura.sql
```

Expected: sin errores. Si `personas.persona` no existe todavía en ese proyecto, correr antes
`00_esquemas.sql` y `04_personas.sql` en ese orden (ver `README.md §Cómo levantar el proyecto`).

- [ ] **Step 3: Verificar con una consulta de validación**

Crear `db/consultas/validacion/05_trigger_bitacora_sincroniza_estado.sql`:

```sql
-- Verifica que un movimiento de suspensión sincroniza persona.estado y que el alta no lo toca dos veces.
BEGIN;

INSERT INTO personas.persona
  (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES
  ('XEXX010101HNEXXXA4', 'XEXX010101AB1', '12345678901', 'Prueba', 'Validación', '1990-01-01', '2026-01-01')
RETURNING id \gset persona_

INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento)
VALUES (:'persona_id', 'suspension');

SELECT estado FROM personas.persona WHERE id = :'persona_id';
-- Esperado: suspension

ROLLBACK;
```

```bash
psql "$DATABASE_URL" -f db/consultas/validacion/05_trigger_bitacora_sincroniza_estado.sql
```

Expected: la última fila impresa dice `suspension`.

- [ ] **Step 4: Commit**

```bash
git add db/ddl/05_personas_estructura.sql db/consultas/validacion/05_trigger_bitacora_sincroniza_estado.sql
git commit -m "ddl: agrega expediente, usuario y bitacora_movimiento_persona"
```

---

## Task 3: RLS del candado de acceso (`SCJ-PRO-02`)

**Files:**
- Create: `db/ddl/06_personas_rls.sql`

**Interfaces:**
- Consumes: `personas.persona`, `personas.usuario`, `personas.expediente`,
  `personas.bitacora_movimiento_persona` (Task 2), `auth.uid()` (función nativa de Supabase).
- Produces: función `personas.fn_caller_activo()` — cualquier RLS futura de este esquema la puede
  reusar en vez de reescribir el `EXISTS`.

- [ ] **Step 1: Escribir el DDL de RLS**

```sql
-- 06_personas_rls.sql
-- Candado de acceso de SCJ-PRO-02: bloquea cualquier operación si persona.estado != 'activo',
-- sin importar la vía de entrada (app, script, API) — vive en Postgres, no en el backend.
-- Depende de: 05_personas_estructura.sql
-- Justificación: SCJ-PRO-02 §III/§V

CREATE FUNCTION personas.fn_caller_activo()
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1
    FROM personas.usuario u
    JOIN personas.persona p ON p.id = u.persona_id
    WHERE u.auth_user_id = auth.uid()
      AND p.estado = 'activo'
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = personas, pg_temp;

COMMENT ON FUNCTION personas.fn_caller_activo() IS
  'true si el usuario autenticado (auth.uid()) tiene una persona activa detrás. SECURITY DEFINER '
  'porque el propio caller normalmente no tendría permiso de leer personas.usuario/persona hasta '
  'pasar este chequeo — es la única función que corre con privilegio elevado en este esquema.';

ALTER TABLE personas.persona ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.expediente ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.usuario ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.bitacora_movimiento_persona ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.persona
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

CREATE POLICY solo_caller_activo ON personas.expediente
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

CREATE POLICY solo_caller_activo ON personas.usuario
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

CREATE POLICY solo_caller_activo ON personas.bitacora_movimiento_persona
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());
```

Nota de alcance (dejarla tal cual, no "mejorarla" en este task): esta policy es deliberadamente
gruesa — cualquier usuario activo puede leer/escribir cualquier persona. El control fino por
permiso de puesto (solo RH) llega con el módulo de permisos/asignaciones, todavía sin diseñar. Está
igual de documentado en `Global Constraints` arriba.

- [ ] **Step 2: Aplicar contra Supabase**

```bash
psql "$DATABASE_URL" -f db/ddl/06_personas_rls.sql
```

- [ ] **Step 3: Verificar que una persona suspendida queda bloqueada**

Crear `db/consultas/validacion/06_rls_bloquea_suspendido.sql`:

```sql
-- Verifica que fn_caller_activo() devuelve false para una persona suspendida.
-- No podemos simular auth.uid() con SET ROLE simple porque es una función de Supabase Auth
-- (lee el JWT de la sesión PostgREST); esta consulta valida la lógica de negocio equivalente
-- directamente sobre la tabla, que es lo que la función encapsula.
BEGIN;

INSERT INTO personas.persona
  (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso, estado)
VALUES
  ('XEXX020202HNEXXXA5', 'XEXX020202AB2', '10987654321', 'Prueba', 'Suspendida', '1990-01-01', '2026-01-01', 'suspension')
RETURNING id \gset persona_

SELECT EXISTS (
  SELECT 1 FROM personas.persona WHERE id = :'persona_id' AND estado = 'activo'
) AS deberia_ser_false;

ROLLBACK;
```

```bash
psql "$DATABASE_URL" -f db/consultas/validacion/06_rls_bloquea_suspendido.sql
```

Expected: `deberia_ser_false` = `f`. La prueba end-to-end real de RLS (con un JWT de verdad,
distinguiendo activo vs. suspendido a través de PostgREST) se cubre en el Task 5 con `supabase-py`.

- [ ] **Step 4: Commit**

```bash
git add db/ddl/06_personas_rls.sql db/consultas/validacion/06_rls_bloquea_suspendido.sql
git commit -m "ddl: activa RLS del candado de acceso en el esquema personas"
```

---

## Task 4: Bucket de Storage para expedientes

**Files:**
- Create: `db/ddl/07_personas_storage.sql`

**Interfaces:**
- Consumes: `personas.fn_caller_activo()` (Task 3).
- Produces: bucket `expedientes` — el backend sube/descarga ahí en el Task 6.

- [ ] **Step 1: Escribir el DDL del bucket y sus policies**

```sql
-- 07_personas_storage.sql
-- Bucket privado para el archivo del expediente (documento_ref). Solo el backend (service_role)
-- sube/descarga; no hay acceso directo del frontend al bucket.
-- Depende de: 06_personas_rls.sql
-- Justificación: NOTAS_campos_extra_mockups.md (diseno_paginas/personas/) · SCJ-PRO-01

INSERT INTO storage.buckets (id, name, public)
VALUES ('expedientes', 'expedientes', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY solo_service_role_expedientes ON storage.objects
  FOR ALL
  USING (bucket_id = 'expedientes' AND auth.role() = 'service_role')
  WITH CHECK (bucket_id = 'expedientes' AND auth.role() = 'service_role');
```

- [ ] **Step 2: Aplicar contra Supabase**

```bash
psql "$DATABASE_URL" -f db/ddl/07_personas_storage.sql
```

- [ ] **Step 3: Verificar en el dashboard**

Dashboard → Storage → confirmar que existe el bucket `expedientes`, marcado como privado (no
público). No hay verificación por SQL de esto porque el estado del bucket también se refleja en
`storage.buckets`, ya cubierto por el `INSERT` — si el `INSERT` no falló, el bucket existe.

- [ ] **Step 4: Commit**

```bash
git add db/ddl/07_personas_storage.sql
git commit -m "ddl: agrega bucket privado de storage para expedientes"
```

---

## Task 5: Configurar Supabase Auth (TTL de token, sesión única)

**Files:** Ninguno de código — configuración en el dashboard de Supabase. Documentar el resultado en:
- Create: `bitacora/2026-09-03_config_auth_supabase.md`

**Interfaces:** Ninguna.

- [ ] **Step 1: Bajar el TTL del access token a 15 minutos**

Dashboard del proyecto → **Authentication → Settings → Sessions** (o **Auth → Rate Limits** según
la versión del dashboard) → buscar **"Access token (JWT) expiry"** → cambiar de `3600` a `900`
segundos → Guardar.

- [ ] **Step 2: Activar "Enforce single session per user"**

Mismo panel (**Authentication → Sessions**) → activar el toggle **"Enforce single session per
user"** → Guardar.

- [ ] **Step 3: Configurar la plantilla de invitación (A4 de `SCJ-PRO-01`)**

Dashboard → **Authentication → Email Templates → Invite user** → confirmar que el link apunta al
frontend (`{{ .SiteURL }}/completar-invitacion` en vez del default) — el `SiteURL` se configura en
**Authentication → URL Configuration** con la URL del frontend desplegado (en desarrollo,
`http://localhost:5173`).

- [ ] **Step 4: Documentar lo hecho**

```markdown
# 2026-09-03 — Configuración de Supabase Auth para SCJ-PRO-01/02

- TTL del access token: 3600s → 900s (15 min). Acota la ventana de un JWT ya emitido tras una
  suspensión (SCJ-PRO-02, JWT es stateless).
- "Enforce single session per user": activado.
- Site URL: http://localhost:5173 (desarrollo). Actualizar a la URL real al desplegar.
- Plantilla de invitación: redirige a /completar-invitacion en vez del default de Supabase.

Verificado a mano: login desde dos navegadores distintos con la misma cuenta invalida la sesión
más vieja al iniciar la segunda.
```

- [ ] **Step 5: Commit**

```bash
git add bitacora/2026-09-03_config_auth_supabase.md
git commit -m "acta: configura TTL de token y sesión única en Supabase Auth"
```

---

## Task 6: Scaffold del backend FastAPI

**Files:**
- Create: `backend/pyproject.toml`
- Create: `backend/app/__init__.py`
- Create: `backend/app/config.py`
- Create: `backend/app/main.py`
- Create: `backend/app/deps.py`
- Test: `backend/tests/test_health.py`

**Interfaces:**
- Produces: `Settings` (en `config.py`, campos `supabase_url: str`, `supabase_anon_key: str`,
  `supabase_service_role_key: str`), `get_settings() -> Settings`, `app: FastAPI` (en `main.py`).

- [ ] **Step 1: `pyproject.toml`**

```toml
[project]
name = "scj-backend"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
  "fastapi>=0.115",
  "uvicorn[standard]>=0.30",
  "supabase>=2.9",
  "pydantic-settings>=2.5",
]

[dependency-groups]
dev = [
  "pytest>=8.3",
  "pytest-asyncio>=0.24",
  "httpx>=0.27",
]
```

- [ ] **Step 2: `app/config.py`**

```python
"""Configuración leída de variables de entorno (.env en la raíz del repo)."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file="../.env", extra="ignore")

    supabase_url: str
    supabase_anon_key: str
    supabase_service_role_key: str


@lru_cache
def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 3: `app/deps.py` — clientes de Supabase por request**

```python
"""Dependencias de FastAPI: cliente de Supabase con el JWT del caller (respeta RLS) y cliente
con service_role (para operaciones administrativas: invitar usuarios, subir al bucket)."""
from fastapi import Depends, Header, HTTPException, status
from supabase import Client, create_client

from app.config import Settings, get_settings


def get_service_client(settings: Settings = Depends(get_settings)) -> Client:
    return create_client(settings.supabase_url, settings.supabase_service_role_key)


def get_caller_client(
    authorization: str = Header(...),
    settings: Settings = Depends(get_settings),
) -> Client:
    """Cliente con el token del usuario que llama — cualquier consulta con este cliente respeta
    la RLS de personas.fn_caller_activo() (SCJ-PRO-02), no hay chequeo de estado aparte aquí."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Falta el token de acceso")
    token = authorization.removeprefix("Bearer ")
    client = create_client(settings.supabase_url, settings.supabase_anon_key)
    client.postgrest.auth(token)
    return client
```

Nota para quien implemente: todos los routers de este plan (Tasks 7-10) llaman
`db.postgrest.schema("personas").table(...)`. Si la versión instalada de `supabase-py` expone el
atajo `db.schema("personas").table(...)` directo en vez de bajo `.postgrest`, son equivalentes —
usar el que exista en la librería instalada, reportarlo como concern en el reporte de este task si
difiere de lo escrito aquí, para ajustar consistentemente en los tasks siguientes.

- [ ] **Step 4: `app/main.py`**

```python
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="SCJ — Personas y Usuarios")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/salud")
def salud() -> dict:
    return {"estado": "ok"}
```

- [ ] **Step 5: Test de salud**

```python
# backend/tests/test_health.py
from fastapi.testclient import TestClient

from app.main import app


def test_salud_responde_ok():
    client = TestClient(app)
    response = client.get("/salud")
    assert response.status_code == 200
    assert response.json() == {"estado": "ok"}
```

- [ ] **Step 6: Correr el test**

```bash
cd backend
uv run pytest tests/test_health.py -v
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/
git commit -m "feat: scaffold del backend FastAPI con endpoint de salud"
```

---

## Task 7: `POST /api/personas` — alta de persona + expediente (`SCJ-PRO-01` A1)

**Files:**
- Create: `backend/app/schemas/personas.py`
- Create: `backend/app/routers/personas.py`
- Modify: `backend/app/main.py` (montar el router)
- Test: `backend/tests/test_personas.py`

**Interfaces:**
- Consumes: `get_caller_client` (Task 6).
- Produces: `PersonaCreate`, `PersonaOut` (Pydantic, en `schemas/personas.py`) — reusados por
  Task 9 (listar/ficha).

- [ ] **Step 1: Esquemas Pydantic**

```python
# backend/app/schemas/personas.py
from datetime import date

from pydantic import BaseModel


class PersonaCreate(BaseModel):
    primer_nombre: str
    segundo_nombre: str | None = None
    apellido_paterno: str
    apellido_materno: str | None = None
    curp: str
    rfc: str
    nss: str
    fecha_nacimiento: date
    fecha_ingreso: date
    tipo_contrato: str  # indefinido | prestacion_servicios | por_proyecto
    documento_ref: str  # formato RTB-__-__


class PersonaOut(BaseModel):
    id: str
    primer_nombre: str
    segundo_nombre: str | None
    apellido_paterno: str
    apellido_materno: str | None
    curp: str
    rfc: str
    nss: str
    fecha_nacimiento: date
    fecha_ingreso: date
    estado: str
```

- [ ] **Step 2: Test que falla primero**

```python
# backend/tests/test_personas.py
from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import get_caller_client
from app.main import app


def test_alta_persona_inserta_persona_y_expediente():
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    tabla_mock.return_value.insert.return_value.execute.return_value.data = [
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "primer_nombre": "Mariana",
            "segundo_nombre": None,
            "apellido_paterno": "Alcántara",
            "apellido_materno": None,
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "estado": "activo",
        }
    ]
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.post(
        "/api/personas",
        json={
            "primer_nombre": "Mariana",
            "apellido_paterno": "Alcántara",
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "tipo_contrato": "indefinido",
            "documento_ref": "RTB-2026-001",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["curp"] == "AARM910427MDFLVR03"
    assert tabla_mock.call_args_list[0].args[0] == "persona"
    assert tabla_mock.call_args_list[1].args[0] == "expediente"
```

- [ ] **Step 3: Correr el test y verificar que falla**

```bash
cd backend && uv run pytest tests/test_personas.py -v
```

Expected: FAIL (no existe `/api/personas` todavía).

- [ ] **Step 4: Router**

```python
# backend/app/routers/personas.py
from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import get_caller_client
from app.schemas.personas import PersonaCreate, PersonaOut

router = APIRouter(prefix="/api/personas", tags=["personas"])


@router.post("", status_code=201, response_model=PersonaOut)
def alta_persona(datos: PersonaCreate, db: Client = Depends(get_caller_client)) -> dict:
    """SCJ-PRO-01 paso A1: persona + expediente en una misma operación, en ese orden por la FK."""
    persona = (
        db.postgrest.schema("personas")
        .table("persona")
        .insert(
            {
                "primer_nombre": datos.primer_nombre,
                "segundo_nombre": datos.segundo_nombre,
                "apellido_paterno": datos.apellido_paterno,
                "apellido_materno": datos.apellido_materno,
                "curp": datos.curp,
                "rfc": datos.rfc,
                "nss": datos.nss,
                "fecha_nacimiento": datos.fecha_nacimiento.isoformat(),
                "fecha_ingreso": datos.fecha_ingreso.isoformat(),
            }
        )
        .execute()
        .data[0]
    )

    db.postgrest.schema("personas").table("expediente").insert(
        {
            "persona_id": persona["id"],
            "tipo_contrato": datos.tipo_contrato,
            "documento_ref": datos.documento_ref,
        }
    ).execute()

    return persona
```

- [ ] **Step 5: Montar el router**

```python
# backend/app/main.py — agregar tras crear `app`
from app.routers import personas  # noqa: E402

app.include_router(personas.router)
```

Nota: `supabase-py` apunta por default al esquema `public` de PostgREST. Este proyecto usa el
esquema `personas` — hay que exponerlo en PostgREST vía Dashboard → **Settings → API → Exposed
schemas**, agregando `personas` a la lista (junto a `public`), antes de que esto funcione contra
Supabase real. El código ya usa `db.postgrest.schema("personas").table(...)` en vez de
`db.table(...)` directo — no hace falta ajustar nada más aquí, solo la configuración del dashboard.

- [ ] **Step 6: Correr el test y verificar que pasa**

```bash
cd backend && uv run pytest tests/test_personas.py -v
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/
git commit -m "feat: agrega POST /api/personas (alta persona + expediente)"
```

---

## Task 8: `POST /api/usuarios` — alta de usuario + invitación (`SCJ-PRO-01` A2-A4)

**Files:**
- Create: `backend/app/schemas/usuarios.py`
- Create: `backend/app/routers/usuarios.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_usuarios.py`

**Interfaces:**
- Consumes: `get_service_client` (Task 6) — este endpoint necesita `service_role` porque invita
  usuarios vía Supabase Auth admin API, algo que el token de un caller normal no puede hacer.
- Produces: `UsuarioCreate`, `UsuarioOut`.

- [ ] **Step 1: Esquemas**

```python
# backend/app/schemas/usuarios.py
from pydantic import BaseModel, EmailStr


class UsuarioCreate(BaseModel):
    persona_id: str
    correo: EmailStr
    nombre_usuario: str


class UsuarioOut(BaseModel):
    auth_user_id: str
    persona_id: str
    nombre_usuario: str
    estado: str
```

- [ ] **Step 2: Test que falla primero**

```python
# backend/tests/test_usuarios.py
from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import get_service_client
from app.main import app


def test_alta_usuario_invita_y_crea_fila_usuario():
    fake_client = MagicMock()
    fake_invite = MagicMock()
    fake_invite.user.id = "22222222-2222-2222-2222-222222222222"
    fake_client.auth.admin.invite_user_by_email.return_value = fake_invite
    fake_client.postgrest.schema.return_value.table.return_value.insert.return_value.execute.return_value.data = [
        {
            "auth_user_id": "22222222-2222-2222-2222-222222222222",
            "persona_id": "11111111-1111-1111-1111-111111111111",
            "nombre_usuario": "mariana.alcantara",
            "estado": "activo",
        }
    ]
    app.dependency_overrides[get_service_client] = lambda: fake_client

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": "11111111-1111-1111-1111-111111111111",
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    fake_client.auth.admin.invite_user_by_email.assert_called_once_with(
        "mariana.alcantara@example.com"
    )
    assert response.json()["auth_user_id"] == "22222222-2222-2222-2222-222222222222"
```

- [ ] **Step 3: Correr el test y verificar que falla**

```bash
cd backend && uv run pytest tests/test_usuarios.py -v
```

Expected: FAIL.

- [ ] **Step 4: Router**

```python
# backend/app/routers/usuarios.py
from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import get_service_client
from app.schemas.usuarios import UsuarioCreate, UsuarioOut

router = APIRouter(prefix="/api/usuarios", tags=["usuarios"])


@router.post("", status_code=201, response_model=UsuarioOut)
def alta_usuario(datos: UsuarioCreate, db: Client = Depends(get_service_client)) -> dict:
    """SCJ-PRO-01: A2 (crear usuario) + A4 (invitación). A3 (bitácora) lo dispara
    trg_usuario_bitacora_alta en la base de datos, no hay nada que hacer aquí para eso."""
    invite = db.auth.admin.invite_user_by_email(datos.correo)

    usuario = (
        db.postgrest.schema("personas")
        .table("usuario")
        .insert(
            {
                "auth_user_id": invite.user.id,
                "persona_id": datos.persona_id,
                "nombre_usuario": datos.nombre_usuario,
            }
        )
        .execute()
        .data[0]
    )
    return usuario
```

- [ ] **Step 5: Montar el router**

```python
# backend/app/main.py — agregar
from app.routers import usuarios  # noqa: E402

app.include_router(usuarios.router)
```

- [ ] **Step 6: Correr el test y verificar que pasa**

```bash
cd backend && uv run pytest tests/test_usuarios.py -v
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/
git commit -m "feat: agrega POST /api/usuarios (alta usuario + invitación de Supabase)"
```

---

## Task 9: `GET /api/personas` y `GET /api/personas/{id}` — directorio y ficha (recortada)

**Files:**
- Modify: `backend/app/routers/personas.py`
- Modify: `backend/app/schemas/personas.py`
- Test: `backend/tests/test_personas.py`

**Interfaces:**
- Consumes: `PersonaOut` (Task 7).
- Produces: `PersonaConExpediente` (`PersonaOut` + `documento_ref`, `tipo_contrato`) — usado por el
  frontend en el Task 17 (ficha de persona).

Nota de alcance (Task 12 del frontend depende de esto): la ficha **no** incluye puesto/área ni el
panel de asistencia/banco de horas de los mockups — esos dependen de módulos todavía sin diseñar
(asignaciones) o sin implementar (Tiempo). Solo trae identidad + expediente + histórico de estado.

- [ ] **Step 1: Agregar el esquema de salida con expediente**

```python
# backend/app/schemas/personas.py — agregar al final del archivo
class PersonaConExpediente(PersonaOut):
    tipo_contrato: str
    documento_ref: str
```

- [ ] **Step 2: Tests que fallan primero**

```python
# backend/tests/test_personas.py — agregar al final del archivo
def test_listar_personas():
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.select.return_value.execute.return_value.data = [
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "primer_nombre": "Mariana",
            "segundo_nombre": None,
            "apellido_paterno": "Alcántara",
            "apellido_materno": None,
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "estado": "activo",
        }
    ]
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get("/api/personas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert len(response.json()) == 1


def test_ficha_persona_incluye_expediente():
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.select.return_value.eq.return_value.single.return_value.execute.return_value.data = {
        "id": "11111111-1111-1111-1111-111111111111",
        "primer_nombre": "Mariana",
        "segundo_nombre": None,
        "apellido_paterno": "Alcántara",
        "apellido_materno": None,
        "curp": "AARM910427MDFLVR03",
        "rfc": "AARM910427H8A",
        "nss": "62119145338",
        "fecha_nacimiento": "1991-04-27",
        "fecha_ingreso": "2026-01-01",
        "estado": "activo",
        "expediente": {"tipo_contrato": "indefinido", "documento_ref": "RTB-2026-001"},
    }
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        "/api/personas/11111111-1111-1111-1111-111111111111",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["documento_ref"] == "RTB-2026-001"
```

(Esto añade imports nuevos al principio del archivo: `from app.deps import get_caller_client` y
`from app.main import app` ya están en el archivo desde el Step 2 del Task 7 — no hace falta
repetirlos.)

- [ ] **Step 3: Correr los tests y verificar que fallan**

```bash
cd backend && uv run pytest tests/test_personas.py -v
```

Expected: FAIL (2 nuevos, los del Task 7 siguen en PASS).

- [ ] **Step 4: Agregar los endpoints al router**

```python
# backend/app/routers/personas.py — agregar al final del archivo
from app.schemas.personas import PersonaConExpediente


@router.get("", response_model=list[PersonaOut])
def listar_personas(db: Client = Depends(get_caller_client)) -> list[dict]:
    return db.postgrest.schema("personas").table("persona").select("*").execute().data


@router.get("/{persona_id}", response_model=PersonaConExpediente)
def ficha_persona(persona_id: str, db: Client = Depends(get_caller_client)) -> dict:
    fila = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("*, expediente(tipo_contrato, documento_ref)")
        .eq("id", persona_id)
        .single()
        .execute()
        .data
    )
    expediente = fila.pop("expediente")
    return {**fila, **expediente}
```

- [ ] **Step 5: Correr los tests y verificar que pasan**

```bash
cd backend && uv run pytest tests/test_personas.py -v
```

Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/
git commit -m "feat: agrega GET /api/personas y GET /api/personas/{id}"
```

---

## Task 10: Movimientos de persona (`SCJ-PRO-02`)

**Files:**
- Create: `backend/app/schemas/movimientos.py`
- Create: `backend/app/routers/movimientos.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_movimientos.py`

**Interfaces:**
- Consumes: `get_caller_client` (Task 6).
- Produces: `MovimientoCreate`, `MovimientoOut`.

- [ ] **Step 1: Esquemas**

```python
# backend/app/schemas/movimientos.py
from datetime import datetime

from pydantic import BaseModel


class MovimientoCreate(BaseModel):
    tipo_movimiento: str  # suspension | reactivacion | baja_definitiva (alta la crea el trigger)
    motivo: str


class MovimientoOut(BaseModel):
    id: str
    persona_id: str
    tipo_movimiento: str
    fecha_efectiva: datetime
    motivo: str | None
    registrado_por: str | None
```

- [ ] **Step 2: Test que falla primero**

```python
# backend/tests/test_movimientos.py
from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import get_caller_client
from app.main import app


def test_crear_movimiento_de_suspension():
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.insert.return_value.execute.return_value.data = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": "11111111-1111-1111-1111-111111111111",
            "tipo_movimiento": "suspension",
            "fecha_efectiva": "2026-09-03T10:00:00+00:00",
            "motivo": "Licencia sin goce de sueldo",
            "registrado_por": None,
        }
    ]
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.post(
        "/api/personas/11111111-1111-1111-1111-111111111111/movimientos",
        json={"tipo_movimiento": "suspension", "motivo": "Licencia sin goce de sueldo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["tipo_movimiento"] == "suspension"


def test_listar_movimientos_de_una_persona():
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.select.return_value.eq.return_value.order.return_value.execute.return_value.data = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": "11111111-1111-1111-1111-111111111111",
            "tipo_movimiento": "alta",
            "fecha_efectiva": "2026-01-01T09:00:00+00:00",
            "motivo": None,
            "registrado_por": "22222222-2222-2222-2222-222222222222",
        }
    ]
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        "/api/personas/11111111-1111-1111-1111-111111111111/movimientos",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()[0]["tipo_movimiento"] == "alta"
```

- [ ] **Step 3: Correr los tests y verificar que fallan**

```bash
cd backend && uv run pytest tests/test_movimientos.py -v
```

Expected: FAIL.

- [ ] **Step 4: Router**

```python
# backend/app/routers/movimientos.py
from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import get_caller_client
from app.schemas.movimientos import MovimientoCreate, MovimientoOut

router = APIRouter(prefix="/api/personas/{persona_id}/movimientos", tags=["movimientos"])


@router.post("", status_code=201, response_model=MovimientoOut)
def crear_movimiento(
    persona_id: str, datos: MovimientoCreate, db: Client = Depends(get_caller_client)
) -> dict:
    """SCJ-PRO-02: el trigger trg_bitacora_sincroniza_persona actualiza persona.estado solo —
    este endpoint nunca hace UPDATE directo a personas.persona."""
    return (
        db.postgrest.schema("personas")
        .table("bitacora_movimiento_persona")
        .insert(
            {
                "persona_id": persona_id,
                "tipo_movimiento": datos.tipo_movimiento,
                "motivo": datos.motivo,
            }
        )
        .execute()
        .data[0]
    )


@router.get("", response_model=list[MovimientoOut])
def listar_movimientos(persona_id: str, db: Client = Depends(get_caller_client)) -> list[dict]:
    return (
        db.postgrest.schema("personas")
        .table("bitacora_movimiento_persona")
        .select("*")
        .eq("persona_id", persona_id)
        .order("fecha_efectiva", desc=True)
        .execute()
        .data
    )
```

- [ ] **Step 5: Montar el router**

```python
# backend/app/main.py — agregar
from app.routers import movimientos  # noqa: E402

app.include_router(movimientos.router)
```

- [ ] **Step 6: Correr los tests y verificar que pasan**

```bash
cd backend && uv run pytest tests/test_movimientos.py -v
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/
git commit -m "feat: agrega alta y listado de movimientos de persona"
```

---

## Task 11: Scaffold del frontend Vite + React + TypeScript

**Files:**
- Create: `frontend/package.json`
- Create: `frontend/vite.config.ts`
- Create: `frontend/tsconfig.json`
- Create: `frontend/index.html`
- Create: `frontend/src/main.tsx`
- Create: `frontend/src/App.tsx`
- Create: `frontend/src/styles/tokens.css`
- Create: `frontend/src/lib/supabaseClient.ts`
- Test: `frontend/src/App.test.tsx`

**Interfaces:**
- Produces: `supabase` (cliente exportado de `lib/supabaseClient.ts`), variable CSS `--teal`,
  `--navy`, etc. (`styles/tokens.css`) — usadas por todas las páginas de los tasks siguientes.

- [ ] **Step 1: `package.json`**

```json
{
  "name": "scj-frontend",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "test": "vitest run"
  },
  "dependencies": {
    "@supabase/supabase-js": "^2.45.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0",
    "react-router-dom": "^6.26.0"
  },
  "devDependencies": {
    "@testing-library/jest-dom": "^6.5.0",
    "@testing-library/react": "^16.0.0",
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.0",
    "jsdom": "^25.0.0",
    "typescript": "^5.6.0",
    "vite": "^5.4.0",
    "vitest": "^2.1.0"
  }
}
```

- [ ] **Step 2: `vite.config.ts`**

```ts
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    globals: true,
  },
});
```

- [ ] **Step 3: `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "skipLibCheck": true,
    "types": ["vitest/globals", "@testing-library/jest-dom"]
  },
  "include": ["src"]
}
```

- [ ] **Step 4: `index.html`**

```html
<!doctype html>
<html lang="es">
  <head>
    <meta charset="UTF-8" />
    <title>Kairos — Control de jornada</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link
      href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Playfair+Display:wght@600;700&display=swap"
      rel="stylesheet"
    />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 5: `src/styles/tokens.css`** (mismos valores que
  `07-Identidad/RTB-IDE/rtb-design-system/rtb-design-tokens.css`, ver `[[diseno-bd-scj-control-jornada]]`)

```css
:root {
  --teal: #159895;
  --teal-claro: #57c5b6;
  --blanco: #ffffff;
  --superficie: #eef8f7;
  --navy-medio: #1a5f7a;
  --navy: #002b5b;
  --oro: #ad9551;
  --font-titulo: "Playfair Display", serif;
  --font-cuerpo: "Inter", system-ui, sans-serif;
  --radio-tarjeta: 14px;
  --sombra-tarjeta: 0 2px 10px rgba(0, 43, 91, 0.05);
}

body {
  margin: 0;
  font-family: var(--font-cuerpo);
  color: var(--navy);
  background: var(--superficie);
}
```

- [ ] **Step 6: Cliente de Supabase**

```ts
// frontend/src/lib/supabaseClient.ts
import { createClient } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

export const supabase = createClient(supabaseUrl, supabaseAnonKey);
```

Agregar a `frontend/.env.example`:

```
VITE_SUPABASE_URL=https://TU-PROYECTO.supabase.co
VITE_SUPABASE_ANON_KEY=
VITE_API_URL=http://localhost:8000
```

- [ ] **Step 7: `App.tsx` mínimo + test**

```tsx
// frontend/src/App.tsx
export function App() {
  return <main>Kairos</main>;
}
```

```tsx
// frontend/src/App.test.tsx
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { App } from "./App";

describe("App", () => {
  it("renderiza el nombre de la app", () => {
    render(<App />);
    expect(screen.getByText("Kairos")).toBeInTheDocument();
  });
});
```

```tsx
// frontend/src/main.tsx
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./App";
import "./styles/tokens.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
```

- [ ] **Step 8: Instalar y correr el test**

```bash
cd frontend
npm install
npm test
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add frontend/
git commit -m "feat: scaffold del frontend Vite + React + TypeScript"
```

---

## Task 12: Router y layout de autenticación (páginas 01, 07, 08)

**Files:**
- Create: `frontend/src/router.tsx`
- Create: `frontend/src/layouts/AuthLayout.tsx`
- Create: `frontend/src/pages/LoginPage.tsx`
- Create: `frontend/src/pages/CuentaSuspendidaPage.tsx`
- Modify: `frontend/src/App.tsx`
- Test: `frontend/src/pages/LoginPage.test.tsx`

**Interfaces:**
- Consumes: `supabase` (Task 11).
- Produces: `AuthLayout` (componente, prop `titulo: string`, `bajada: string`, `children`) —
  reusado por Task 13 y 14 para las demás pantallas de autenticación.

- [ ] **Step 1: `AuthLayout` — el panel dividido con degradado (versión final aprobada)**

```tsx
// frontend/src/layouts/AuthLayout.tsx
import type { ReactNode } from "react";

type Props = {
  titulo: string;
  bajada: string;
  children: ReactNode;
};

export function AuthLayout({ titulo, bajada, children }: Props) {
  return (
    <div style={{ display: "flex", minHeight: "100vh" }}>
      <aside
        style={{
          flex: "0 0 42%",
          background:
            "linear-gradient(160deg, var(--navy) 0%, var(--teal) 60%, var(--teal-claro) 100%)",
          color: "white",
          padding: "3rem",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
        }}
      >
        <strong style={{ fontFamily: "var(--font-titulo)", fontSize: "1.5rem" }}>Kairos</strong>
        <div>
          <h1 style={{ fontFamily: "var(--font-titulo)", fontSize: "2.5rem" }}>{titulo}</h1>
          <p>{bajada}</p>
        </div>
        <small>Distribuidora Central, S.A. de C.V. · v1.0</small>
      </aside>
      <main style={{ flex: 1, display: "grid", placeItems: "center", background: "white" }}>
        <div
          style={{
            background: "var(--superficie)",
            borderRadius: "var(--radio-tarjeta)",
            boxShadow: "var(--sombra-tarjeta)",
            padding: "2.5rem",
            width: "min(420px, 90%)",
          }}
        >
          {children}
        </div>
      </main>
    </div>
  );
}
```

- [ ] **Step 2: Test de `LoginPage` que falla primero**

```tsx
// frontend/src/pages/LoginPage.test.tsx
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { supabase } from "../lib/supabaseClient";
import { LoginPage } from "./LoginPage";

vi.mock("../lib/supabaseClient", () => ({
  supabase: { auth: { signInWithPassword: vi.fn() } },
}));

describe("LoginPage", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.signInWithPassword).mockReset();
  });

  it("muestra error de credenciales inválidas sin salir de la pantalla", async () => {
    vi.mocked(supabase.auth.signInWithPassword).mockResolvedValue({
      data: { user: null, session: null },
      error: { message: "Invalid login credentials", name: "AuthApiError", status: 400 },
    } as never);

    render(<LoginPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.type(screen.getByLabelText(/contraseña/i), "malacontrasena");
    await userEvent.click(screen.getByRole("button", { name: /iniciar sesión/i }));

    await waitFor(() =>
      expect(screen.getByText(/correo o contraseña incorrectos/i)).toBeInTheDocument()
    );
  });
});
```

- [ ] **Step 3: Instalar `@testing-library/user-event` y correr el test**

```bash
cd frontend
npm install -D @testing-library/user-event
npm test -- LoginPage
```

Expected: FAIL (no existe `LoginPage.tsx`).

- [ ] **Step 4: `LoginPage.tsx` (07-error-credenciales integrado, no una pantalla aparte)**

```tsx
// frontend/src/pages/LoginPage.tsx
import { type FormEvent, useState } from "react";

import { supabase } from "../lib/supabaseClient";
import { AuthLayout } from "../layouts/AuthLayout";

export function LoginPage() {
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    const formulario = new FormData(evento.currentTarget);
    const { error: errorLogin } = await supabase.auth.signInWithPassword({
      email: String(formulario.get("correo")),
      password: String(formulario.get("contrasena")),
    });
    if (errorLogin) {
      setError("Correo o contraseña incorrectos.");
    }
  }

  return (
    <AuthLayout
      titulo="El tiempo de tu gente, en orden."
      bajada="Control de jornada, marcas, banco de horas y gestión de personas en una sola plataforma."
    >
      <h2>Iniciar sesión</h2>
      <p>Accede con tu correo corporativo.</p>
      <form onSubmit={handleSubmit}>
        <label htmlFor="correo">Correo electrónico</label>
        <input id="correo" name="correo" type="email" required />
        <label htmlFor="contrasena">Contraseña</label>
        <input id="contrasena" name="contrasena" type="password" required />
        {error && <p role="alert">{error}</p>}
        <button type="submit">Iniciar sesión</button>
      </form>
    </AuthLayout>
  );
}
```

- [ ] **Step 5: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- LoginPage
```

Expected: PASS.

- [ ] **Step 6: `CuentaSuspendidaPage.tsx` (08 — sin formulario de reintento)**

```tsx
// frontend/src/pages/CuentaSuspendidaPage.tsx
import { AuthLayout } from "../layouts/AuthLayout";

export function CuentaSuspendidaPage() {
  return (
    <AuthLayout titulo="Acceso no disponible" bajada="Tu cuenta no está activa en este momento.">
      <h2>Cuenta suspendida</h2>
      <p>Contacta a Recursos Humanos para reactivar tu acceso.</p>
    </AuthLayout>
  );
}
```

- [ ] **Step 7: Router**

```tsx
// frontend/src/router.tsx
import { createBrowserRouter } from "react-router-dom";

import { CuentaSuspendidaPage } from "./pages/CuentaSuspendidaPage";
import { LoginPage } from "./pages/LoginPage";

export const router = createBrowserRouter([
  { path: "/", element: <LoginPage /> },
  { path: "/cuenta-suspendida", element: <CuentaSuspendidaPage /> },
]);
```

```tsx
// frontend/src/App.tsx
import { RouterProvider } from "react-router-dom";

import { router } from "./router";

export function App() {
  return <RouterProvider router={router} />;
}
```

Actualizar `App.test.tsx` (Task 11) para envolver en el router real o borrarlo — ya no aplica un
`render(<App />)` a secas sin ruta. Reemplazar su contenido por:

```tsx
// frontend/src/App.test.tsx
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { App } from "./App";

describe("App", () => {
  it("muestra el login en la ruta raíz", () => {
    render(<App />);
    expect(screen.getByText("Iniciar sesión")).toBeInTheDocument();
  });
});
```

- [ ] **Step 8: Correr toda la suite de frontend**

```bash
cd frontend && npm test
```

Expected: todos los tests en PASS.

- [ ] **Step 9: Commit**

```bash
git add frontend/
git commit -m "feat: agrega layout de autenticación, login y cuenta suspendida"
```

---

## Task 13: 2FA — configurar y verificar TOTP (páginas 02, 03)

**Files:**
- Create: `frontend/src/pages/Configurar2FAPage.tsx`
- Create: `frontend/src/pages/VerificarTotpPage.tsx`
- Modify: `frontend/src/router.tsx`
- Test: `frontend/src/pages/VerificarTotpPage.test.tsx`

**Interfaces:**
- Consumes: `supabase.auth.mfa.enroll()`, `supabase.auth.mfa.challenge()`,
  `supabase.auth.mfa.verify()` (API nativa de Supabase Auth MFA).

- [ ] **Step 1: Test de `VerificarTotpPage` que falla primero**

```tsx
// frontend/src/pages/VerificarTotpPage.test.tsx
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { supabase } from "../lib/supabaseClient";
import { VerificarTotpPage } from "./VerificarTotpPage";

vi.mock("../lib/supabaseClient", () => ({
  supabase: {
    auth: {
      mfa: {
        challenge: vi.fn().mockResolvedValue({ data: { id: "challenge-1" }, error: null }),
        verify: vi.fn(),
      },
    },
  },
}));

describe("VerificarTotpPage", () => {
  beforeEach(() => {
    vi.mocked(supabase.auth.mfa.verify).mockReset();
  });

  it("navega tras un código correcto", async () => {
    vi.mocked(supabase.auth.mfa.verify).mockResolvedValue({
      data: { access_token: "tok" },
      error: null,
    } as never);

    render(<VerificarTotpPage factorId="factor-1" />);
    await userEvent.type(screen.getByLabelText(/código/i), "123456");
    await userEvent.click(screen.getByRole("button", { name: /verificar/i }));

    await waitFor(() =>
      expect(supabase.auth.mfa.verify).toHaveBeenCalledWith({
        factorId: "factor-1",
        challengeId: "challenge-1",
        code: "123456",
      })
    );
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

```bash
cd frontend && npm test -- VerificarTotpPage
```

Expected: FAIL.

- [ ] **Step 3: `VerificarTotpPage.tsx`**

```tsx
// frontend/src/pages/VerificarTotpPage.tsx
import { type FormEvent, useState } from "react";

import { AuthLayout } from "../layouts/AuthLayout";
import { supabase } from "../lib/supabaseClient";

type Props = { factorId: string };

export function VerificarTotpPage({ factorId }: Props) {
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    const codigo = String(new FormData(evento.currentTarget).get("codigo"));
    const { data: challenge, error: errorChallenge } = await supabase.auth.mfa.challenge({
      factorId,
    });
    if (errorChallenge || !challenge) {
      setError("No se pudo iniciar la verificación.");
      return;
    }
    const { error: errorVerify } = await supabase.auth.mfa.verify({
      factorId,
      challengeId: challenge.id,
      code: codigo,
    });
    if (errorVerify) {
      setError("Código incorrecto.");
    }
  }

  return (
    <AuthLayout titulo="Verifica tu identidad" bajada="Ingresa el código de tu app autenticadora.">
      <form onSubmit={handleSubmit}>
        <label htmlFor="codigo">Código de verificación</label>
        <input id="codigo" name="codigo" inputMode="numeric" maxLength={6} required />
        {error && <p role="alert">{error}</p>}
        <button type="submit">Verificar</button>
      </form>
    </AuthLayout>
  );
}
```

- [ ] **Step 4: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- VerificarTotpPage
```

Expected: PASS.

- [ ] **Step 5: `Configurar2FAPage.tsx` (sin test — es el flujo de enrolamiento, cubierto
  manualmente porque `enroll()` requiere una sesión real de Supabase para generar el QR; ver
  Task 19 para la verificación manual completa del flujo)**

```tsx
// frontend/src/pages/Configurar2FAPage.tsx
import { useEffect, useState } from "react";

import { AuthLayout } from "../layouts/AuthLayout";
import { supabase } from "../lib/supabaseClient";
import { VerificarTotpPage } from "./VerificarTotpPage";

export function Configurar2FAPage() {
  const [qr, setQr] = useState<string | null>(null);
  const [factorId, setFactorId] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.mfa.enroll({ factorType: "totp" }).then(({ data, error }) => {
      if (!error && data) {
        setQr(data.totp.qr_code);
        setFactorId(data.id);
      }
    });
  }, []);

  if (factorId) {
    return <VerificarTotpPage factorId={factorId} />;
  }

  return (
    <AuthLayout titulo="Protege tu cuenta" bajada="Escanea el código con tu app autenticadora.">
      {qr ? <img src={qr} alt="Código QR para configurar 2FA" /> : <p>Generando código…</p>}
    </AuthLayout>
  );
}
```

- [ ] **Step 6: Registrar rutas**

```tsx
// frontend/src/router.tsx — agregar imports y rutas
import { Configurar2FAPage } from "./pages/Configurar2FAPage";

// dentro del arreglo de createBrowserRouter:
{ path: "/configurar-2fa", element: <Configurar2FAPage /> },
```

- [ ] **Step 7: Commit**

```bash
git add frontend/
git commit -m "feat: agrega configuración y verificación de 2FA (TOTP)"
```

---

## Task 14: Recuperación de contraseña e invitación (páginas 04, 05, 06)

**Files:**
- Create: `frontend/src/pages/OlvideContrasenaPage.tsx`
- Create: `frontend/src/pages/RestablecerContrasenaPage.tsx`
- Create: `frontend/src/pages/CompletarInvitacionPage.tsx`
- Modify: `frontend/src/router.tsx`
- Test: `frontend/src/pages/OlvideContrasenaPage.test.tsx`

**Interfaces:**
- Consumes: `supabase.auth.resetPasswordForEmail()`, `supabase.auth.updateUser()`.

- [ ] **Step 1: Test que falla primero**

```tsx
// frontend/src/pages/OlvideContrasenaPage.test.tsx
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { supabase } from "../lib/supabaseClient";
import { OlvideContrasenaPage } from "./OlvideContrasenaPage";

vi.mock("../lib/supabaseClient", () => ({
  supabase: { auth: { resetPasswordForEmail: vi.fn().mockResolvedValue({ error: null }) } },
}));

describe("OlvideContrasenaPage", () => {
  it("confirma el envío del enlace", async () => {
    render(<OlvideContrasenaPage />);
    await userEvent.type(screen.getByLabelText(/correo/i), "mariana@example.com");
    await userEvent.click(screen.getByRole("button", { name: /enviar enlace/i }));

    await waitFor(() => expect(screen.getByText(/revisa tu correo/i)).toBeInTheDocument());
    expect(supabase.auth.resetPasswordForEmail).toHaveBeenCalledWith("mariana@example.com", {
      redirectTo: expect.stringContaining("/restablecer-contrasena"),
    });
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

```bash
cd frontend && npm test -- OlvideContrasenaPage
```

Expected: FAIL.

- [ ] **Step 3: Las tres páginas**

```tsx
// frontend/src/pages/OlvideContrasenaPage.tsx
import { type FormEvent, useState } from "react";

import { AuthLayout } from "../layouts/AuthLayout";
import { supabase } from "../lib/supabaseClient";

export function OlvideContrasenaPage() {
  const [enviado, setEnviado] = useState(false);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    const correo = String(new FormData(evento.currentTarget).get("correo"));
    await supabase.auth.resetPasswordForEmail(correo, {
      redirectTo: `${window.location.origin}/restablecer-contrasena`,
    });
    setEnviado(true);
  }

  return (
    <AuthLayout titulo="Recupera tu acceso" bajada="Te enviamos un enlace a tu correo.">
      {enviado ? (
        <p>Revisa tu correo para continuar.</p>
      ) : (
        <form onSubmit={handleSubmit}>
          <label htmlFor="correo">Correo electrónico</label>
          <input id="correo" name="correo" type="email" required />
          <button type="submit">Enviar enlace</button>
        </form>
      )}
    </AuthLayout>
  );
}
```

```tsx
// frontend/src/pages/RestablecerContrasenaPage.tsx
import { type FormEvent, useState } from "react";

import { AuthLayout } from "../layouts/AuthLayout";
import { supabase } from "../lib/supabaseClient";

export function RestablecerContrasenaPage() {
  const [error, setError] = useState<string | null>(null);
  const [listo, setListo] = useState(false);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    const formulario = new FormData(evento.currentTarget);
    const nueva = String(formulario.get("nueva"));
    const confirmar = String(formulario.get("confirmar"));
    if (nueva !== confirmar) {
      setError("Las contraseñas no coinciden.");
      return;
    }
    const { error: errorUpdate } = await supabase.auth.updateUser({ password: nueva });
    if (errorUpdate) {
      setError("No se pudo actualizar la contraseña.");
      return;
    }
    setListo(true);
  }

  if (listo) {
    return (
      <AuthLayout titulo="Contraseña actualizada" bajada="Ya puedes iniciar sesión.">
        <a href="/">Ir a iniciar sesión</a>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout titulo="Define tu nueva contraseña" bajada="">
      <form onSubmit={handleSubmit}>
        <label htmlFor="nueva">Nueva contraseña</label>
        <input id="nueva" name="nueva" type="password" required minLength={8} />
        <label htmlFor="confirmar">Confirmar contraseña</label>
        <input id="confirmar" name="confirmar" type="password" required minLength={8} />
        {error && <p role="alert">{error}</p>}
        <button type="submit">Guardar</button>
      </form>
    </AuthLayout>
  );
}
```

```tsx
// frontend/src/pages/CompletarInvitacionPage.tsx
import { RestablecerContrasenaPage } from "./RestablecerContrasenaPage";

export function CompletarInvitacionPage() {
  // Mismo formulario que restablecer contraseña — Supabase ya autenticó a la persona vía el link
  // de invitación antes de llegar aquí (mismo mecanismo, distinto punto de entrada).
  return <RestablecerContrasenaPage />;
}
```

- [ ] **Step 4: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- OlvideContrasenaPage
```

Expected: PASS.

- [ ] **Step 5: Rutas**

```tsx
// frontend/src/router.tsx — agregar
import { CompletarInvitacionPage } from "./pages/CompletarInvitacionPage";
import { OlvideContrasenaPage } from "./pages/OlvideContrasenaPage";
import { RestablecerContrasenaPage } from "./pages/RestablecerContrasenaPage";

// dentro del arreglo:
{ path: "/olvide-contrasena", element: <OlvideContrasenaPage /> },
{ path: "/restablecer-contrasena", element: <RestablecerContrasenaPage /> },
{ path: "/completar-invitacion", element: <CompletarInvitacionPage /> },
```

- [ ] **Step 6: Commit**

```bash
git add frontend/
git commit -m "feat: agrega recuperación de contraseña y completar invitación"
```

---

## Task 15: Cliente de API autenticado hacia el backend

**Files:**
- Create: `frontend/src/lib/apiClient.ts`
- Test: `frontend/src/lib/apiClient.test.ts`

**Interfaces:**
- Consumes: `supabase.auth.getSession()`.
- Produces: `apiFetch(path: string, init?: RequestInit): Promise<Response>` — usado por todas las
  páginas de los Tasks 16-18.

- [ ] **Step 1: Test que falla primero**

```ts
// frontend/src/lib/apiClient.test.ts
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "./apiClient";
import { supabase } from "./supabaseClient";

vi.mock("./supabaseClient", () => ({
  supabase: {
    auth: {
      getSession: vi.fn().mockResolvedValue({
        data: { session: { access_token: "el-token" } },
      }),
    },
  },
}));

describe("apiFetch", () => {
  it("agrega el Authorization con el token de la sesión", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(new Response("{}"));

    await apiFetch("/api/personas");

    expect(fetch).toHaveBeenCalledWith(
      expect.stringContaining("/api/personas"),
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer el-token" }),
      })
    );
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

```bash
cd frontend && npm test -- apiClient
```

Expected: FAIL.

- [ ] **Step 3: Implementación**

```ts
// frontend/src/lib/apiClient.ts
import { supabase } from "./supabaseClient";

const apiUrl = import.meta.env.VITE_API_URL as string;

export async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  return fetch(`${apiUrl}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(session ? { Authorization: `Bearer ${session.access_token}` } : {}),
      ...init.headers,
    },
  });
}
```

- [ ] **Step 4: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- apiClient
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/
git commit -m "feat: agrega cliente de API autenticado hacia el backend"
```

---

## Task 16: Directorio de personas (página 09)

**Files:**
- Create: `frontend/src/pages/DirectorioPersonasPage.tsx`
- Modify: `frontend/src/router.tsx`
- Test: `frontend/src/pages/DirectorioPersonasPage.test.tsx`

**Interfaces:**
- Consumes: `apiFetch` (Task 15), `GET /api/personas` (Task 9).

- [ ] **Step 1: Test que falla primero**

```tsx
// frontend/src/pages/DirectorioPersonasPage.test.tsx
import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { DirectorioPersonasPage } from "./DirectorioPersonasPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

describe("DirectorioPersonasPage", () => {
  it("lista las personas devueltas por el backend", async () => {
    vi.mocked(apiFetch).mockResolvedValue(
      new Response(
        JSON.stringify([
          { id: "1", primer_nombre: "Mariana", apellido_paterno: "Alcántara", estado: "activo" },
        ])
      )
    );

    render(<DirectorioPersonasPage />);

    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

```bash
cd frontend && npm test -- DirectorioPersonasPage
```

Expected: FAIL.

- [ ] **Step 3: Implementación**

```tsx
// frontend/src/pages/DirectorioPersonasPage.tsx
import { useEffect, useState } from "react";

import { apiFetch } from "../lib/apiClient";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  estado: string;
};

export function DirectorioPersonasPage() {
  const [personas, setPersonas] = useState<Persona[]>([]);

  useEffect(() => {
    apiFetch("/api/personas")
      .then((respuesta) => respuesta.json())
      .then(setPersonas);
  }, []);

  return (
    <div>
      <h1>Personas</h1>
      <table>
        <thead>
          <tr>
            <th>Nombre</th>
            <th>Estado</th>
          </tr>
        </thead>
        <tbody>
          {personas.map((persona) => (
            <tr key={persona.id}>
              <td>
                <a href={`/personas/${persona.id}`}>
                  {persona.primer_nombre} {persona.apellido_paterno}
                </a>
              </td>
              <td>{persona.estado}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <a href="/personas/nueva">Agregar persona</a>
    </div>
  );
}
```

- [ ] **Step 4: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- DirectorioPersonasPage
```

Expected: PASS.

- [ ] **Step 5: Ruta**

```tsx
// frontend/src/router.tsx — agregar
import { DirectorioPersonasPage } from "./pages/DirectorioPersonasPage";

{ path: "/personas", element: <DirectorioPersonasPage /> },
```

- [ ] **Step 6: Commit**

```bash
git add frontend/
git commit -m "feat: agrega directorio de personas"
```

---

## Task 17: Alta de persona y alta de usuario (páginas 11, 12)

**Files:**
- Create: `frontend/src/pages/AltaPersonaPage.tsx`
- Create: `frontend/src/pages/AltaUsuarioPage.tsx`
- Modify: `frontend/src/router.tsx`
- Test: `frontend/src/pages/AltaPersonaPage.test.tsx`

**Interfaces:**
- Consumes: `apiFetch`, `POST /api/personas` (Task 7), `POST /api/usuarios` (Task 8).

- [ ] **Step 1: Test que falla primero**

```tsx
// frontend/src/pages/AltaPersonaPage.test.tsx
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { AltaPersonaPage } from "./AltaPersonaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

describe("AltaPersonaPage", () => {
  it("envía los datos del formulario a POST /api/personas", async () => {
    vi.mocked(apiFetch).mockResolvedValue(new Response(JSON.stringify({ id: "1" }), { status: 201 }));

    render(<AltaPersonaPage />);
    await userEvent.type(screen.getByLabelText(/primer nombre/i), "Mariana");
    await userEvent.type(screen.getByLabelText(/apellido paterno/i), "Alcántara");
    await userEvent.type(screen.getByLabelText(/curp/i), "AARM910427MDFLVR03");
    await userEvent.type(screen.getByLabelText(/rfc/i), "AARM910427H8A");
    await userEvent.type(screen.getByLabelText(/nss/i), "62119145338");
    await userEvent.type(screen.getByLabelText(/fecha de nacimiento/i), "1991-04-27");
    await userEvent.type(screen.getByLabelText(/fecha de ingreso/i), "2026-01-01");
    await userEvent.type(screen.getByLabelText(/documento_ref/i), "RTB-2026-001");
    await userEvent.click(screen.getByRole("button", { name: /registrar alta/i }));

    await waitFor(() =>
      expect(apiFetch).toHaveBeenCalledWith(
        "/api/personas",
        expect.objectContaining({ method: "POST" })
      )
    );
    const cuerpo = JSON.parse(vi.mocked(apiFetch).mock.calls[0][1]!.body as string);
    expect(cuerpo.curp).toBe("AARM910427MDFLVR03");
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

```bash
cd frontend && npm test -- AltaPersonaPage
```

Expected: FAIL.

- [ ] **Step 3: `AltaPersonaPage.tsx`** (campos = exactamente los de `personas.persona` +
  `tipo_contrato`/`documento_ref` de `expediente`, sin sexo/estado civil/puesto/correo — ver
  `NOTAS_campos_extra_mockups.md`)

```tsx
// frontend/src/pages/AltaPersonaPage.tsx
import { type FormEvent, useState } from "react";

import { apiFetch } from "../lib/apiClient";

export function AltaPersonaPage() {
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/personas", {
      method: "POST",
      body: JSON.stringify({
        primer_nombre: f.get("primer_nombre"),
        segundo_nombre: f.get("segundo_nombre") || null,
        apellido_paterno: f.get("apellido_paterno"),
        apellido_materno: f.get("apellido_materno") || null,
        curp: f.get("curp"),
        rfc: f.get("rfc"),
        nss: f.get("nss"),
        fecha_nacimiento: f.get("fecha_nacimiento"),
        fecha_ingreso: f.get("fecha_ingreso"),
        tipo_contrato: f.get("tipo_contrato"),
        documento_ref: f.get("documento_ref"),
      }),
    });
    if (!respuesta.ok) {
      setError("No se pudo registrar el alta.");
      return;
    }
    const persona = await respuesta.json();
    window.location.href = `/personas/${persona.id}`;
  }

  return (
    <form onSubmit={handleSubmit}>
      <h1>Alta de persona</h1>
      <label htmlFor="primer_nombre">Primer nombre</label>
      <input id="primer_nombre" name="primer_nombre" required />
      <label htmlFor="segundo_nombre">Segundo nombre</label>
      <input id="segundo_nombre" name="segundo_nombre" />
      <label htmlFor="apellido_paterno">Apellido paterno</label>
      <input id="apellido_paterno" name="apellido_paterno" required />
      <label htmlFor="apellido_materno">Apellido materno</label>
      <input id="apellido_materno" name="apellido_materno" />
      <label htmlFor="curp">CURP</label>
      <input id="curp" name="curp" required maxLength={18} />
      <label htmlFor="rfc">RFC</label>
      <input id="rfc" name="rfc" required maxLength={13} />
      <label htmlFor="nss">NSS</label>
      <input id="nss" name="nss" required maxLength={11} />
      <label htmlFor="fecha_nacimiento">Fecha de nacimiento</label>
      <input id="fecha_nacimiento" name="fecha_nacimiento" type="date" required />
      <label htmlFor="fecha_ingreso">Fecha de ingreso</label>
      <input id="fecha_ingreso" name="fecha_ingreso" type="date" required />
      <fieldset>
        <legend>Tipo de contrato</legend>
        <label>
          <input type="radio" name="tipo_contrato" value="indefinido" defaultChecked /> Indefinido
        </label>
        <label>
          <input type="radio" name="tipo_contrato" value="prestacion_servicios" /> Prestación de
          servicios
        </label>
        <label>
          <input type="radio" name="tipo_contrato" value="por_proyecto" /> Por proyecto
        </label>
      </fieldset>
      <label htmlFor="documento_ref">documento_ref</label>
      <input id="documento_ref" name="documento_ref" placeholder="RTB-__-__" required />
      {error && <p role="alert">{error}</p>}
      <button type="submit">Registrar alta</button>
    </form>
  );
}
```

- [ ] **Step 4: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- AltaPersonaPage
```

Expected: PASS.

- [ ] **Step 5: `AltaUsuarioPage.tsx`** (selecciona una persona ya existente — reusa
  `GET /api/personas` del Task 9 para la lista del `<select>`)

```tsx
// frontend/src/pages/AltaUsuarioPage.tsx
import { type FormEvent, useEffect, useState } from "react";

import { apiFetch } from "../lib/apiClient";

type PersonaOpcion = { id: string; primer_nombre: string; apellido_paterno: string };

export function AltaUsuarioPage() {
  const [personas, setPersonas] = useState<PersonaOpcion[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [enviado, setEnviado] = useState(false);

  useEffect(() => {
    apiFetch("/api/personas")
      .then((r) => r.json())
      .then(setPersonas);
  }, []);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch("/api/usuarios", {
      method: "POST",
      body: JSON.stringify({
        persona_id: f.get("persona_id"),
        correo: f.get("correo"),
        nombre_usuario: f.get("nombre_usuario"),
      }),
    });
    if (!respuesta.ok) {
      setError("No se pudo enviar la invitación.");
      return;
    }
    setEnviado(true);
  }

  if (enviado) {
    return <p>Invitación enviada.</p>;
  }

  return (
    <form onSubmit={handleSubmit}>
      <h1>Alta de usuario</h1>
      <label htmlFor="persona_id">Persona</label>
      <select id="persona_id" name="persona_id" required>
        <option value="">Selecciona una persona</option>
        {personas.map((p) => (
          <option key={p.id} value={p.id}>
            {p.primer_nombre} {p.apellido_paterno}
          </option>
        ))}
      </select>
      <label htmlFor="correo">Correo</label>
      <input id="correo" name="correo" type="email" required />
      <label htmlFor="nombre_usuario">Nombre de usuario</label>
      <input id="nombre_usuario" name="nombre_usuario" required />
      {error && <p role="alert">{error}</p>}
      <button type="submit">Enviar invitación</button>
    </form>
  );
}
```

- [ ] **Step 6: Rutas**

```tsx
// frontend/src/router.tsx — agregar
import { AltaPersonaPage } from "./pages/AltaPersonaPage";
import { AltaUsuarioPage } from "./pages/AltaUsuarioPage";

{ path: "/personas/nueva", element: <AltaPersonaPage /> },
{ path: "/usuarios/nuevo", element: <AltaUsuarioPage /> },
```

- [ ] **Step 7: Commit**

```bash
git add frontend/
git commit -m "feat: agrega formularios de alta de persona y alta de usuario"
```

---

## Task 18: Ficha de persona y cambio de estado (páginas 10 recortada, 13, 14)

**Files:**
- Create: `frontend/src/pages/FichaPersonaPage.tsx`
- Create: `frontend/src/pages/CambiarEstadoPage.tsx`
- Modify: `frontend/src/router.tsx`
- Test: `frontend/src/pages/FichaPersonaPage.test.tsx`
- Test: `frontend/src/pages/CambiarEstadoPage.test.tsx`

**Interfaces:**
- Consumes: `apiFetch`, `GET /api/personas/{id}` (Task 9),
  `POST /api/personas/{id}/movimientos` + `GET /api/personas/{id}/movimientos` (Task 10).

- [ ] **Step 1: Test de `FichaPersonaPage` que falla primero**

```tsx
// frontend/src/pages/FichaPersonaPage.test.tsx
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { FichaPersonaPage } from "./FichaPersonaPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

describe("FichaPersonaPage", () => {
  it("muestra identidad, expediente e historial de estado", async () => {
    vi.mocked(apiFetch).mockImplementation((path) => {
      if (path.endsWith("/movimientos")) {
        return Promise.resolve(
          new Response(
            JSON.stringify([
              { id: "m1", tipo_movimiento: "alta", fecha_efectiva: "2026-01-01T09:00:00Z", motivo: null },
            ])
          )
        );
      }
      return Promise.resolve(
        new Response(
          JSON.stringify({
            id: "1",
            primer_nombre: "Mariana",
            apellido_paterno: "Alcántara",
            curp: "AARM910427MDFLVR03",
            estado: "activo",
            tipo_contrato: "indefinido",
            documento_ref: "RTB-2026-001",
          })
        )
      );
    });

    render(
      <MemoryRouter initialEntries={["/personas/1"]}>
        <Routes>
          <Route path="/personas/:id" element={<FichaPersonaPage />} />
        </Routes>
      </MemoryRouter>
    );

    await waitFor(() => expect(screen.getByText(/mariana alcántara/i)).toBeInTheDocument());
    expect(screen.getByText(/rtb-2026-001/i)).toBeInTheDocument();
    expect(screen.getByText(/alta/i)).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Correr el test y verificar que falla**

```bash
cd frontend && npm test -- FichaPersonaPage
```

Expected: FAIL.

- [ ] **Step 3: `FichaPersonaPage.tsx`** (sin puesto/área ni panel de asistencia — fuera de
  alcance, ver `Global Constraints`)

```tsx
// frontend/src/pages/FichaPersonaPage.tsx
import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";

import { apiFetch } from "../lib/apiClient";

type Persona = {
  id: string;
  primer_nombre: string;
  apellido_paterno: string;
  curp: string;
  estado: string;
  tipo_contrato: string;
  documento_ref: string;
};

type Movimiento = {
  id: string;
  tipo_movimiento: string;
  fecha_efectiva: string;
  motivo: string | null;
};

export function FichaPersonaPage() {
  const { id } = useParams<{ id: string }>();
  const [persona, setPersona] = useState<Persona | null>(null);
  const [movimientos, setMovimientos] = useState<Movimiento[]>([]);

  useEffect(() => {
    apiFetch(`/api/personas/${id}`)
      .then((r) => r.json())
      .then(setPersona);
    apiFetch(`/api/personas/${id}/movimientos`)
      .then((r) => r.json())
      .then(setMovimientos);
  }, [id]);

  if (!persona) return <p>Cargando…</p>;

  return (
    <div>
      <h1>
        {persona.primer_nombre} {persona.apellido_paterno}
      </h1>
      <p>Estado: {persona.estado}</p>
      <section>
        <h2>Datos personales</h2>
        <p>CURP: {persona.curp}</p>
      </section>
      <section>
        <h2>Expediente</h2>
        <p>documento_ref: {persona.documento_ref}</p>
        <p>Tipo de contrato: {persona.tipo_contrato}</p>
      </section>
      <section>
        <h2>Historial de estado</h2>
        <ul>
          {movimientos.map((m) => (
            <li key={m.id}>
              {m.fecha_efectiva} — {m.tipo_movimiento} {m.motivo ? `(${m.motivo})` : ""}
            </li>
          ))}
        </ul>
      </section>
      <a href={`/personas/${persona.id}/movimiento`}>Nuevo movimiento</a>
    </div>
  );
}
```

- [ ] **Step 4: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- FichaPersonaPage
```

Expected: PASS.

- [ ] **Step 5: Test de `CambiarEstadoPage` que falla primero**

```tsx
// frontend/src/pages/CambiarEstadoPage.test.tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { apiFetch } from "../lib/apiClient";
import { CambiarEstadoPage } from "./CambiarEstadoPage";

vi.mock("../lib/apiClient", () => ({ apiFetch: vi.fn() }));

describe("CambiarEstadoPage", () => {
  it("exige motivo y envía el movimiento elegido", async () => {
    vi.mocked(apiFetch).mockResolvedValue(new Response(JSON.stringify({ id: "m1" }), { status: 201 }));

    render(
      <MemoryRouter initialEntries={["/personas/1/movimiento"]}>
        <Routes>
          <Route path="/personas/:id/movimiento" element={<CambiarEstadoPage />} />
        </Routes>
      </MemoryRouter>
    );

    await userEvent.click(screen.getByLabelText(/suspensión/i));
    await userEvent.type(screen.getByLabelText(/motivo/i), "Licencia sin goce de sueldo");
    await userEvent.click(screen.getByRole("button", { name: /confirmar/i }));

    expect(apiFetch).toHaveBeenCalledWith(
      "/api/personas/1/movimientos",
      expect.objectContaining({ method: "POST" })
    );
  });
});
```

- [ ] **Step 6: Correr el test y verificar que falla**

```bash
cd frontend && npm test -- CambiarEstadoPage
```

Expected: FAIL.

- [ ] **Step 7: `CambiarEstadoPage.tsx`**

```tsx
// frontend/src/pages/CambiarEstadoPage.tsx
import { type FormEvent, useState } from "react";
import { useParams } from "react-router-dom";

import { apiFetch } from "../lib/apiClient";

export function CambiarEstadoPage() {
  const { id } = useParams<{ id: string }>();
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault();
    setError(null);
    const f = new FormData(evento.currentTarget);
    const respuesta = await apiFetch(`/api/personas/${id}/movimientos`, {
      method: "POST",
      body: JSON.stringify({
        tipo_movimiento: f.get("tipo_movimiento"),
        motivo: f.get("motivo"),
      }),
    });
    if (!respuesta.ok) {
      setError("No se pudo registrar el movimiento.");
      return;
    }
    window.location.href = `/personas/${id}`;
  }

  return (
    <form onSubmit={handleSubmit}>
      <h1>Cambio de estado</h1>
      <fieldset>
        <legend>Nuevo estado</legend>
        <label>
          <input type="radio" name="tipo_movimiento" value="suspension" required /> Suspensión
        </label>
        <label>
          <input type="radio" name="tipo_movimiento" value="reactivacion" /> Reactivación
        </label>
        <label>
          <input type="radio" name="tipo_movimiento" value="baja_definitiva" /> Baja definitiva
        </label>
      </fieldset>
      <label htmlFor="motivo">Motivo</label>
      <textarea id="motivo" name="motivo" required />
      {error && <p role="alert">{error}</p>}
      <button type="submit">Confirmar</button>
    </form>
  );
}
```

- [ ] **Step 8: Correr el test y verificar que pasa**

```bash
cd frontend && npm test -- CambiarEstadoPage
```

Expected: PASS.

- [ ] **Step 9: Rutas**

```tsx
// frontend/src/router.tsx — agregar
import { CambiarEstadoPage } from "./pages/CambiarEstadoPage";
import { FichaPersonaPage } from "./pages/FichaPersonaPage";

{ path: "/personas/:id", element: <FichaPersonaPage /> },
{ path: "/personas/:id/movimiento", element: <CambiarEstadoPage /> },
```

- [ ] **Step 10: Commit**

```bash
git add frontend/
git commit -m "feat: agrega ficha de persona (recortada) y cambio de estado"
```

---

## Task 19: Verificación manual de punta a punta

**Files:** Ninguno de código — checklist de verificación manual contra el proyecto de Supabase real.
- Modify: `bitacora/2026-09-03_config_auth_supabase.md` (agregar el resultado al final)

**Interfaces:** Ninguna.

- [ ] **Step 1: Levantar backend y frontend**

```bash
cd backend && uv run uvicorn app.main:app --reload &
cd frontend && npm run dev
```

- [ ] **Step 2: Correr el flujo completo de `SCJ-PRO-01`**

1. Ir a `/personas/nueva`, dar de alta una persona sintética (ver `SCJ-ANO-01` — sin datos reales).
2. Ir a `/usuarios/nuevo`, invitar a esa persona con un correo de prueba propio.
3. Revisar el correo de invitación, seguir el link a `/completar-invitacion`, definir contraseña.
4. Verificar en el SQL Editor de Supabase que `bitacora_movimiento_persona` tiene una fila
   `tipo_movimiento = 'alta'` para esa persona (confirma `trg_usuario_bitacora_alta`).
5. Ir a `/`, iniciar sesión con ese correo/contraseña → debe pedir configurar 2FA (`/configurar-2fa`)
   la primera vez.
6. Cerrar sesión, volver a entrar → debe pedir el código TOTP (`/verificar-totp` vía
   `Configurar2FAPage`, que ya redirige a `VerificarTotpPage` cuando el factor existe).

- [ ] **Step 3: Correr el flujo completo de `SCJ-PRO-02`**

1. Ir a `/personas/{id}/movimiento` de esa misma persona, registrar una `suspension` con motivo.
2. Verificar en el SQL Editor que `personas.persona.estado` cambió a `suspension` (confirma
   `trg_bitacora_sincroniza_persona`).
3. Con la sesión de esa persona ya abierta en otra pestaña, refrescar cualquier página que llame al
   backend → debe fallar (403/401) porque `fn_caller_activo()` ahora devuelve `false`. Esto prueba
   el candado de RLS con un JWT real, cerrando la verificación que el Task 3 dejó pendiente con
   `supabase-py`.
4. Registrar una `reactivacion` → confirmar que `estado` vuelve a `activo` y que el acceso se
   restablece.

- [ ] **Step 4: Documentar el resultado**

Agregar al final de `bitacora/2026-09-03_config_auth_supabase.md`:

```markdown
## Verificación end-to-end — 2026-09-0X

SCJ-PRO-01 y SCJ-PRO-02 corridos de punta a punta contra el proyecto de Supabase real, con datos
sintéticos. [Anotar aquí cualquier desviación encontrada frente al plan.]
```

- [ ] **Step 5: Commit**

```bash
git add bitacora/
git commit -m "acta: verificación end-to-end de SCJ-PRO-01 y SCJ-PRO-02"
```
