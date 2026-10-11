CREATE TABLE IF NOT EXISTS `project-9ac387a6-66c9-4c04-81d.ms4_design.converted_readings` (
  ID STRING,
  time INT64,
  profile_name STRING,
  temperature FLOAT64 OPTIONS(description="Temperature in Fahrenheit"),
  humidity FLOAT64 OPTIONS(description="Relative humidity in percent"),
  pressure FLOAT64 OPTIONS(description="Pressure in psi")
);
