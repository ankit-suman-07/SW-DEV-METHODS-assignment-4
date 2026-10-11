"""Pure smart-meter preprocessing shared by both services."""
import math

MEASUREMENTS = ("temperature", "humidity", "pressure")

def filter_reading(record):
    if not isinstance(record, dict):
        raise ValueError("Reading must be a JSON object")
    if any(record.get(key) is None for key in MEASUREMENTS):
        return None
    if any(value is None for value in record.values()):
        return None
    for key in MEASUREMENTS:
        value = record[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError("Measurements must be finite numbers")
    return dict(record)

def convert_reading(record):
    cleaned = filter_reading(record)
    if cleaned is None:
        raise ValueError("Cannot convert a reading with missing measurements")
    cleaned["temperature"] = cleaned["temperature"] * 1.8 + 32
    cleaned["pressure"] = cleaned["pressure"] / 6.895
    return cleaned
