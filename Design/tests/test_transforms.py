import math
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "common"))
from transforms import filter_reading, convert_reading

class TransformTests(unittest.TestCase):
    def setUp(self):
        self.record = {"ID": "test-1", "time": 123, "profile_name": "test",
                       "temperature": 20, "humidity": 50, "pressure": 6.895}

    def test_each_missing_measurement_is_discarded(self):
        for field in ("temperature", "humidity", "pressure"):
            with self.subTest(field=field):
                self.assertIsNone(filter_reading(dict(self.record, **{field: None})))

    def test_absent_measurement_is_discarded(self):
        record = dict(self.record)
        del record["pressure"]
        self.assertIsNone(filter_reading(record))

    def test_zero_measurements_are_valid(self):
        record = dict(self.record, temperature=0, humidity=0, pressure=0)
        converted = convert_reading(record)
        self.assertEqual(converted["temperature"], 32)
        self.assertEqual(converted["pressure"], 0)
        self.assertEqual(converted["humidity"], 0)

    def test_known_conversion_and_unchanged_metadata(self):
        converted = convert_reading(self.record)
        self.assertAlmostEqual(converted["temperature"], 68)
        self.assertAlmostEqual(converted["pressure"], 1)
        for field in ("ID", "time", "profile_name", "humidity"):
            self.assertEqual(converted[field], self.record[field])
        self.assertEqual(self.record["temperature"], 20)

    def test_negative_celsius(self):
        self.assertAlmostEqual(convert_reading(dict(self.record, temperature=-40))["temperature"], -40)

    def test_invalid_numeric_values(self):
        for value in ("20", True, math.nan, math.inf):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    filter_reading(dict(self.record, temperature=value))

if __name__ == "__main__":
    unittest.main()
