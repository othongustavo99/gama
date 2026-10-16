"""Integração enxuta com Open-Meteo: geocodificação, condições atuais e previsão."""
from __future__ import annotations

import logging
from typing import Any

import httpx

logger = logging.getLogger(__name__)
GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

WMO_PT = {
    0: "céu limpo", 1: "predominantemente limpo", 2: "parcialmente nublado", 3: "nublado",
    45: "nevoeiro", 48: "nevoeiro com geada", 51: "garoa fraca", 53: "garoa moderada",
    55: "garoa intensa", 56: "garoa congelante fraca", 57: "garoa congelante intensa",
    61: "chuva fraca", 63: "chuva moderada", 65: "chuva forte", 66: "chuva congelante fraca",
    67: "chuva congelante forte", 71: "neve fraca", 73: "neve moderada", 75: "neve forte",
    77: "grãos de neve", 80: "pancadas de chuva fracas", 81: "pancadas de chuva moderadas",
    82: "pancadas de chuva fortes", 85: "pancadas de neve fracas", 86: "pancadas de neve fortes",
    95: "trovoadas", 96: "trovoadas com granizo fraco", 99: "trovoadas com granizo forte",
}


def _weather_label(code: Any) -> str:
    try:
        return WMO_PT.get(int(code), "condição meteorológica não identificada")
    except (TypeError, ValueError):
        return "condição meteorológica não identificada"


async def get_weather_report(location: str, days: int = 3) -> dict[str, Any]:
    """Consulta Open-Meteo; não depende de chave de API para uso não comercial."""
    location = " ".join((location or "").split()).strip()[:120]
    vague_locations = {
        "aqui", "aí", "ai", "here", "perto de mim", "near me",
        "minha localização", "minha localizacao", "current location",
        "onde estou", "where am i", "na minha cidade", "minha região",
        "minha regiao", "na minha região", "local atual",
    }
    if len(location) < 2 or location.casefold() in vague_locations:
        return {"ok": False, "error": "Não recebi uma cidade/localidade específica. Pergunte ao usuário qual cidade e estado/país quer consultar; não adivinhe nem use uma localização não fornecida."}
    days = max(1, min(int(days or 3), 7))
    timeout = httpx.Timeout(12.0, connect=5.0)
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            geo_response = await client.get(GEOCODING_URL, params={"name": location, "count": 5, "language": "pt", "format": "json"})
            geo_response.raise_for_status()
            geo_data = geo_response.json()
            matches = geo_data.get("results") or []
            if not matches:
                return {"ok": False, "error": f"Não encontrei a localidade '{location}'. Peça ao usuário que confira o nome ou informe estado/país."}
            # Primeira correspondência da API; mantém a identificação geográfica para transparência.
            place = matches[0]
            lat, lon = place.get("latitude"), place.get("longitude")
            if lat is None or lon is None:
                return {"ok": False, "error": "A geocodificação não retornou coordenadas para a localidade."}
            label_parts = [str(place.get("name") or location)]
            if place.get("admin1"):
                label_parts.append(str(place["admin1"]))
            if place.get("country"):
                label_parts.append(str(place["country"]))
            label = ", ".join(dict.fromkeys(label_parts))

            forecast_response = await client.get(FORECAST_URL, params={
                "latitude": lat,
                "longitude": lon,
                "timezone": "auto",
                "forecast_days": days,
                "temperature_unit": "celsius",
                "wind_speed_unit": "kmh",
                "precipitation_unit": "mm",
                "current": "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,rain,showers,weather_code,cloud_cover,wind_speed_10m,wind_direction_10m",
                "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset",
            })
            forecast_response.raise_for_status()
            data = forecast_response.json()
            current = data.get("current") or {}
            daily = data.get("daily") or {}
            unit = data.get("current_units") or {}
            daily_unit = data.get("daily_units") or {}
            days_out = []
            times = daily.get("time") or []
            for i, day in enumerate(times[:days]):
                def item(key: str, default: Any = None) -> Any:
                    values = daily.get(key) or []
                    return values[i] if i < len(values) else default
                days_out.append({
                    "date": day,
                    "condition": _weather_label(item("weather_code")),
                    "min_c": item("temperature_2m_min"),
                    "max_c": item("temperature_2m_max"),
                    "rain_probability_percent": item("precipitation_probability_max"),
                    "precipitation_mm": item("precipitation_sum"),
                    "sunrise": item("sunrise"),
                    "sunset": item("sunset"),
                })
            current_out = {
                "time": current.get("time"),
                "condition": _weather_label(current.get("weather_code")),
                "temperature_c": current.get("temperature_2m"),
                "feels_like_c": current.get("apparent_temperature"),
                "humidity_percent": current.get("relative_humidity_2m"),
                "precipitation_mm": current.get("precipitation"),
                "rain_mm": current.get("rain"),
                "cloud_cover_percent": current.get("cloud_cover"),
                "wind_kmh": current.get("wind_speed_10m"),
                "wind_direction_degrees": current.get("wind_direction_10m"),
            }
            return {
                "ok": True,
                "location": label,
                "timezone": data.get("timezone"),
                "current": current_out,
                "daily": days_out,
                "units": {"temperature": unit.get("temperature_2m", "°C"), "wind": unit.get("wind_speed_10m", "km/h"), "precipitation": daily_unit.get("precipitation_sum", "mm")},
                "provider": "Open-Meteo",
            }
    except httpx.TimeoutException:
        return {"ok": False, "error": "A consulta meteorológica demorou demais. Tente novamente."}
    except httpx.HTTPError as exc:
        logger.warning("Open-Meteo HTTP error: %s", type(exc).__name__)
        return {"ok": False, "error": "O serviço Open-Meteo não respondeu corretamente. Tente novamente mais tarde."}
    except (ValueError, TypeError, KeyError):
        logger.exception("Unexpected Open-Meteo response")
        return {"ok": False, "error": "A resposta meteorológica veio em formato inesperado."}


def format_weather_for_model(report: dict[str, Any]) -> str:
    if not report.get("ok"):
        return str(report.get("error") or "Não foi possível consultar o clima.")
    cur = report.get("current") or {}
    lines = [
        "DADOS METEOROLÓGICOS ATUAIS (Open-Meteo; responda com base neles, sem inventar):",
        f"Local: {report.get('location')}",
        f"Horário local reportado pela API: {cur.get('time')} ({report.get('timezone')})",
        f"Agora: {cur.get('condition')}; {cur.get('temperature_c')} °C; sensação térmica {cur.get('feels_like_c')} °C; umidade {cur.get('humidity_percent')}%; vento {cur.get('wind_kmh')} km/h; precipitação {cur.get('precipitation_mm')} mm.",
        "Previsão diária:",
    ]
    for day in report.get("daily") or []:
        lines.append(
            f"- {day.get('date')}: {day.get('condition')}; mínima {day.get('min_c')} °C; máxima {day.get('max_c')} °C; probabilidade máxima de precipitação {day.get('rain_probability_percent')}%; acumulado {day.get('precipitation_mm')} mm; nascer do sol {day.get('sunrise')}; pôr do sol {day.get('sunset')}."
        )
    lines.append("Se a localidade ou o período não corresponder ao pedido, esclareça. Diga que são dados de previsão e evite garantir o tempo com certeza absoluta.")
    return "\n".join(lines)
