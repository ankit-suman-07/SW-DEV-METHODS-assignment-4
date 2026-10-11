"""Consume one filtered stage, publish the next, then acknowledge."""
import json
import logging
import os
from google.cloud import pubsub_v1
from transforms import filter_reading, convert_reading

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
PROJECT = os.environ["GCP_PROJECT"]
TOPIC = os.environ["TOPIC_NAME"]
SUBSCRIPTION = os.environ["SUBSCRIPTION_ID"]
STAGE = "filter"
publisher = pubsub_v1.PublisherClient()
subscriber = pubsub_v1.SubscriberClient()
topic_path = publisher.topic_path(PROJECT, TOPIC)
subscription_path = subscriber.subscription_path(PROJECT, SUBSCRIPTION)

def callback(message):
    try:
        record = json.loads(message.data)
        result = filter_reading(record) if STAGE == "filter" else convert_reading(record)
    except (ValueError, TypeError, KeyError) as error:
        logging.warning("Discarding invalid reading: %s", error)
        message.ack()
        return
    if result is None:
        logging.info("Discarded missing-measurement reading ID=%s", record.get("ID"))
        message.ack()
        return
    try:
        output = "filtered" if STAGE == "filter" else "converted"
        publisher.publish(topic_path, json.dumps(result, allow_nan=False).encode("utf-8"),
                          function=output).result(timeout=30)
        message.ack()
        logging.info("Published %s ID=%s", output, result.get("ID"))
    except Exception:
        logging.exception("Publish failed; requesting redelivery")
        message.nack()

if __name__ == "__main__":
    logging.info("Listening on %s; stage=%s", subscription_path, STAGE)
    future = subscriber.subscribe(subscription_path, callback=callback,
                                  flow_control=pubsub_v1.types.FlowControl(max_messages=10))
    try:
        future.result()
    except KeyboardInterrupt:
        future.cancel()
        future.result()
    finally:
        subscriber.close()
        publisher.stop()
