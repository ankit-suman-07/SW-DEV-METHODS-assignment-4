import glob                             # for searching for json file 
import os                               # for setting and reading environment variables
from google.cloud import pubsub_v1      # pip install google-cloud-pubsub  ##to install
import redis                            # pip install redis   ##to install
import time                             # for sleep function
import json;                            # to deal with json objects
import sys;                             # fot exit function

# MS4: use Application Default Credentials (no embedded key files).
# GKE uses Workload Identity; Cloud Shell uses locally authorized ADC.

# Get the environment variables to set the crossponding variables
redis_host = os.environ["REDIS_HOST"];
project_id = os.environ["GCP_PROJECT"];
subscription_id = os.environ["ELECTION_SUB_ID"];
topic_name = os.environ["TOPIC_NAME"];

debug=False;  # change to True for debugging
if "Debug" in os.environ:  # or define it as an environment variable
    debug=True;
if debug:
    print("Authentication: Application Default Credentials")
    print(redis_host)
    print(project_id)
    print(subscription_id)
    print(topic_name)

# Try to connect to the Redis server. If the connection is not established, the service will end.
for i in range(60):
    try:
        Redis = redis.Redis(host=redis_host, port=6379, db=0,password='election')
        time.sleep(1);              # Wait for 1 second
        Redis.ping()                # Check the connection
        print('Connected to Redis');
        failed=False; 
        break;
    except:
        print('Failed to connect to Redis');
        failed=True; 
if failed:
    print("Failed to connect to Redis. Terminating the service");
    sys.exit(0);                    # Terminate the program
  
# create a publisher and get the topic path for the publisher
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(project_id, topic_name)

# The callback function for handling received messages
def callback(message: pubsub_v1.subscriber.message.Message) -> None:
    # Make sure that the global variables are accessed from within the function.
    global Redis, publisher, topic_path
    # get the message content
    message_data = json.loads(message.data);
   
    if debug:
        print(f"Received {message_data}.")
    
    # check for a voter in Redis
    redis_key=str(message_data["voter_ID"])+","+str(message_data['election_ID']);
    if(Redis.exists(redis_key)):
        # if found an "Already Voted!!!" message is produced associated with attributes (function="result", machineID)
        value={'result': 'Already Voted!!!','UUID': message_data['UUID']}
        future = publisher.publish(topic_path, json.dumps(value).encode('utf-8'),function="result",machineID=str(message_data['machine_ID']));
    else:
        # if not found, set a Redis key/value to prevent the voter from voting again
        Redis.set(redis_key,message_data["timestamp"])
        #Exclude the voter ID and  produce the message to future process with attribute (function="record vote")
        value={'machine_ID': message_data['machine_ID'], 'voting': message_data['voting'], 'election_ID': message_data['election_ID'], 'UUID': message_data['UUID']}        
        
        if debug:
            print(f"Sending {str(value)}.")
            
        future = publisher.publish(topic_path, json.dumps(value).encode('utf-8'),function="record vote");
    # Report To Google Pub/Sub the successful processed of the received messages
    message.ack()
    
# create a subscriber to the subscriber for the project using the subscription_id
subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(project_id, subscription_id)
sub_filter = "attributes.function=\"submit vote\""  # the condition used for filtering the messages to be recieved 

print(f"Listening for messages on {subscription_path}..\n")

with subscriber:
    # Create a subscription with the given ID and filter for the first time, if already not existed
    try:
        subscription = subscriber.create_subscription(
            request={"name": subscription_path, "topic": topic_path, "filter": sub_filter}
        )
    except:
        pass;
    
    # Now, the subscription is already existing or has been created. 
    # The call back function will be called for each message match the filter from the topic.
    streaming_pull_future = subscriber.subscribe(subscription_path, callback=callback)
    try:
        streaming_pull_future.result()
    except KeyboardInterrupt:
        streaming_pull_future.cancel()
