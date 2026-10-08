"""Variables de configuración del módulo Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md §5, 89_): las 5 claves
`terminal_*` de tiempo.parametro. Lectura de `tiempo.parametro` con service_role (deny-all para el caller; sólo
claves de la lista blanca del catálogo, nunca nada del listado genérico); ESCRITURA con el RPC
`fn_terminal_config_actualizar` y el cliente del CALLER (el gate de persona activa + terminal_config_edicion está
DENTRO del RPC)."""

import logging
from datetime import date, datetime, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app.altas_terminal import resolver_nombres_persona
from app.catalogo_terminal import CATALOGO_TERMINAL, CLAVE_CADUCIDAD, VariableTerminal, valor_vigente
from app.deps import get_caller_client, get_service_client
from app.errores import MENSAJE_VARIABLE_NO_EXISTE, manejar_error_terminal_web
from app.fecha_local import a_datetime
from app.permisos import requiere_permiso
from app.respuestas_error import ErrorConCampos
from app.schemas.terminales import (
    SimulacionCaducidadOut,
    SimularCaducidad,
    VariableActualizadaOut,
    VariableEditar,
    VariableOut,
    VigenciaVariableOut,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/terminales/configuracion/variables", tags=["terminales"])

_PERMISO_VER = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion")
_PERMISO_EDITAR = requiere_permiso("terminal_config_edicion")
# La simulación lista altas con nombres: se leen con la RLS del caller, así que además de configurar hay que poder verlas.
_PERMISO_VER_ALTAS = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion")

MENSAJE_CAMBIO_CONCURRENTE = "La variable cambió mientras la editabas; vuelve a leerla."
MENSAJE_SIMULACION_FALLIDA = "No se pudo calcular el impacto; intenta de nuevo."
MENSAJE_RESPUESTA_INESPERADA = "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."
MENSAJE_TRASLAPE_LLAVE = (
    "El traslape de llaves no puede superar la mitad de la antigüedad máxima de la llave (en días)."
)
MENSAJE_ANTIGUEDAD_LLAVE = "La antigüedad máxima de la llave no puede ser menor al doble del traslape máximo."
TOPE_BAJAS_POR_CORRIDA = 50  # fijo en fn_terminal_baja_por_caducidad
TOPE_HISTORIAL = 200
CLAVES = tuple(CATALOGO_TERMINAL)

Clave = Annotated[str, Path(max_length=64)]


def _entrada(clave: str) -> VariableTerminal:
    entrada = CATALOGO_TERMINAL.get(clave)
    if entrada is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_VARIABLE_NO_EXISTE)
    return entrada


def _mensaje_rango(entrada: VariableTerminal) -> str:
    return f"El valor debe ser un entero entre {entrada.minimo} y {entrada.maximo}."


def _validar_rango(valor: int, entrada: VariableTerminal) -> None:
    if valor < entrada.minimo or valor > entrada.maximo:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, _mensaje_rango(entrada))


def _filas_vigentes(db_servicio: Client) -> dict[str, dict]:
    filas = (
        db_servicio.postgrest.schema("tiempo")
        .table("parametro")
        .select("clave, valor, vigente_desde, registrado_por")
        .in_("clave", list(CLAVES))
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    return {f["clave"]: f for f in filas}


def _entero(valor, entrada: VariableTerminal) -> int | None:
    try:
        n = int(str(valor).strip())
    except (TypeError, ValueError):
        return None
    return n if entrada.minimo <= n <= entrada.maximo else None


def _nombres_de_autores(db: Client, auth_user_ids: list[str]) -> dict[str, str]:
    ids = sorted({i for i in auth_user_ids if i})
    if not ids:
        return {}
    filas = (
        db.postgrest.schema("personas")
        .table("usuario")
        .select("auth_user_id, nombre_usuario")
        .in_("auth_user_id", ids)
        .execute()
        .data
    )
    return {f["auth_user_id"]: f["nombre_usuario"] for f in filas}


@router.get("", response_model=list[VariableOut])
def listar_variables(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_VER),
    db_servicio: Client = Depends(get_service_client),
) -> list[dict]:
    """Las 5 variables con su valor vigente. Si una clave falta o está corrupta se muestra el valor por defecto con
    `vigente_desde: null` (mismo criterio que fn_terminal_config_valor): no tumba la pantalla."""
    filas = _filas_vigentes(db_servicio)
    nombres = _nombres_de_autores(db, [f.get("registrado_por") for f in filas.values()])
    salida = []
    for clave, entrada in CATALOGO_TERMINAL.items():
        fila = filas.get(clave)
        valor = _entero(fila["valor"], entrada) if fila else None
        ok = valor is not None
        salida.append(
            {
                "clave": clave,
                "etiqueta": entrada.etiqueta,
                "descripcion": entrada.descripcion,
                "unidad": entrada.unidad,
                "minimo": entrada.minimo,
                "maximo": entrada.maximo,
                "valor_defecto": entrada.defecto,
                "valor": valor if ok else entrada.defecto,
                "vigente_desde": str(fila["vigente_desde"]) if ok else None,
                "modificado_por_nombre": nombres.get(fila.get("registrado_por")) if ok else None,
                "valor_ilegible": fila is not None and not ok,
            }
        )
    return salida


@router.get("/historial", response_model=list[VigenciaVariableOut])
def historial_de_variables(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_VER),
    db_servicio: Client = Depends(get_service_client),
    clave: str | None = Query(None, max_length=64),
    desde: date | None = Query(None, description="Vigencias con vigente_desde a partir de esta fecha."),
) -> list[dict]:
    """Vigencias de las claves `terminal_*` (nunca de otras: lista blanca), más recientes primero, tope 200."""
    if clave is not None:
        _entrada(clave)
    consulta = (
        db_servicio.postgrest.schema("tiempo")
        .table("parametro")
        .select("clave, valor, vigente_desde, vigente_hasta, registrado_por")
        .in_("clave", [clave] if clave else list(CLAVES))
    )
    if desde is not None:
        consulta = consulta.gte("vigente_desde", desde.isoformat())
    filas = consulta.order("vigente_desde", desc=True).order("id", desc=True).limit(TOPE_HISTORIAL).execute().data
    nombres = _nombres_de_autores(db, [f.get("registrado_por") for f in filas])
    return [
        {
            "clave": f["clave"],
            "valor": str(f["valor"]),
            "vigente_desde": str(f["vigente_desde"]),
            "vigente_hasta": str(f["vigente_hasta"]) if f.get("vigente_hasta") else None,
            "modificado_por_nombre": nombres.get(f.get("registrado_por")),
            "estado": "vigente" if not f.get("vigente_hasta") else "reemplazada",
            "valor_ilegible": _entero(f["valor"], CATALOGO_TERMINAL[f["clave"]]) is None,
        }
        for f in filas
    ]


def _error_de_regla_cruzada(error: APIError, clave: str) -> HTTPException | None:
    """Tras validar el rango aquí, un 22023/valor_invalido del RPC sólo puede ser la regla cruzada entre las dos
    claves de llave (traslape*2 <= antigüedad_meses*30): se explica con texto fijo."""
    if error.code == "22023" and (error.hint or "") == "valor_invalido":
        if clave == "terminal_traslape_llave_max_dias":
            return HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TRASLAPE_LLAVE)
        if clave == "terminal_llave_max_meses":
            return HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ANTIGUEDAD_LLAVE)
    return None


@router.patch("/{clave}", response_model=VariableActualizadaOut)
def editar_variable(
    clave: Clave,
    datos: VariableEditar,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_EDITAR),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    entrada = _entrada(clave)
    _validar_rango(datos.valor, entrada)

    # Chequeo previo contra el valor vigente (el RPC no compara): evita pisar el cambio de otra persona.
    fila = _filas_vigentes(db_servicio).get(clave)
    actual = _entero(fila["valor"], entrada) if fila else None
    actual = actual if actual is not None else entrada.defecto
    if datos.valor_base != actual:
        raise ErrorConCampos(
            status.HTTP_409_CONFLICT, MENSAJE_CAMBIO_CONCURRENTE, {"valor_actual": actual}, codigo="valor_desactualizado"
        )

    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc("fn_terminal_config_actualizar", {"p_clave": clave, "p_valor": str(datos.valor)})
            .execute()
            .data
        )
    except APIError as error:
        cruzada = _error_de_regla_cruzada(error, clave)
        if cruzada is not None:
            raise cruzada from None
        manejar_error_terminal_web(error, (entrada.minimo, entrada.maximo))
    if (
        not isinstance(resultado, dict)
        or resultado.get("resultado") not in ("actualizada", "sin_cambio")
        or resultado.get("clave") != clave
    ):
        logger.error("fn_terminal_config_actualizar devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    try:
        valor = int(str(resultado["valor"]).strip())
    except (KeyError, TypeError, ValueError):
        logger.error("fn_terminal_config_actualizar devolvió un valor no entero")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA) from None
    vigente_desde = resultado.get("vigente_desde")
    return {
        "resultado": resultado["resultado"],
        "clave": clave,
        "valor": valor,
        "vigente_desde": str(vigente_desde) if vigente_desde else None,
    }


@router.post("/{clave}/simular", response_model=SimulacionCaducidadOut)
def simular_caducidad(
    clave: Clave,
    datos: SimularCaducidad,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_EDITAR),
    _permiso_ver: None = Depends(_PERMISO_VER_ALTAS),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Sin escribir nada: qué pasaría con las altas en `esperando_huella` si la caducidad fuera `valor`. Sólo para
    terminal_caducidad_alta_horas."""
    if clave != CLAVE_CADUCIDAD:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_VARIABLE_NO_EXISTE)
    entrada = CATALOGO_TERMINAL[clave]
    _validar_rango(datos.valor, entrada)

    propuesto = datos.valor
    try:
        actual = valor_vigente(db_servicio, clave)
        filas = (
            db.postgrest.schema("tiempo")
            .table("terminal_usuario")
            .select("id, persona_id, usuario_creado_en")
            .eq("estado", "esperando_huella")
            .order("usuario_creado_en")
            .execute()
            .data
        )
    except Exception as error:  # APIError, red, timeout: la UI deshabilita «Confirmar» si no hubo cálculo
        logger.error("simular caducidad: no se pudo calcular (%s)", getattr(error, "code", None) or type(error).__name__)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_SIMULACION_FALLIDA) from None
    ahora = datetime.now(timezone.utc)
    horas_de = {}
    for f in filas:
        if f.get("usuario_creado_en"):
            horas_de[f["id"]] = (ahora - a_datetime(f["usuario_creado_en"])) / timedelta(hours=1)

    ya = [f for f in filas if f["id"] in horas_de and propuesto <= horas_de[f["id"]] < actual]
    gana = [f for f in filas if f["id"] in horas_de and actual <= horas_de[f["id"]] < propuesto]
    por_caducar = [
        f for f in filas if f["id"] in horas_de and horas_de[f["id"]] < propuesto <= horas_de[f["id"]] + 1
    ]
    visibles = ya[:TOPE_BAJAS_POR_CORRIDA]
    nombres = resolver_nombres_persona(db, [f["persona_id"] for f in visibles])
    return {
        "valor_actual": actual,
        "valor_propuesto": propuesto,
        "acorta": propuesto < actual,
        "altas_en_espera": len(filas),
        "altas_que_ganan_plazo": len(gana),
        "altas_que_caducarian_ya": [
            {
                "tu_id": f["id"],
                "persona_nombre": nombres.get(f["persona_id"]),
                "esperando_desde": a_datetime(f["usuario_creado_en"]),
            }
            for f in visibles
        ],
        "altas_que_caducarian_ya_total": len(ya),
        "altas_por_caducar_nuevas": len(por_caducar),
        "tope_por_corrida": TOPE_BAJAS_POR_CORRIDA,
    }
