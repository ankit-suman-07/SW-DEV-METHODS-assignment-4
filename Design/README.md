# Smart-meter preprocessing with Pub/Sub microservices

One topic, `smartMeterDesign`, carries all three stages, selected by the
`function` message attribute:

| Consumer | Subscription | Filter | Output |
| --- | --- | --- | --- |
| FilterReading | ms4-reading-filter-sub | function=raw | function=filtered |
| ConvertReading | ms4-reading-convert-sub | function=filtered | function=converted |
| BigQuery export | ms4-reading-bigquery-sub | function=converted | BigQuery rows |

FilterReading drops readings with missing measurements. ConvertReading uses
temperature F = temperature C * 1.8 + 32 and pressure psi = pressure kPa / 6.895.
Humidity and identification fields remain unchanged. Invalid numeric inputs
are also discarded. Input values are synthetic measurements, not real city data.

The BigQuery table will contain ID (STRING), time (INTEGER), profile_name
(STRING), temperature (FLOAT), humidity (FLOAT), and pressure (FLOAT).
Stored temperature is Fahrenheit; stored pressure is psi. A native BigQuery
subscription will export JSON using the table schema; workers do not write to
BigQuery directly. There are no additional worker databases.

Build each container from the Design context, for example:
`docker build -f Design/filter_reading/Dockerfile -t IMAGE Design`

Run pure transformation tests:
`python -m unittest discover -s Design/tests -v`

Run the producer after deployment with GCP_PROJECT set:
`python Design/producer.py --count 20`

Workers use Workload Identity; the producer uses Cloud Shell ADC.
The pipeline acknowledges only after downstream publication succeeds, and
requests redelivery on publication failure. Delivery is at least once: retries
can produce duplicates, so ID is a correlation field, not an exactly-once guarantee.

Preparation creates source files only. Deployment and live tests are separate
checkpoints. Original voting source credit remains with the upstream repository.
