import glob                             # for searching for json file 
import os                               # for setting and reading environment variables
from google.cloud import pubsub_v1      # pip install google-cloud-pubsub  ##to install
import time                             # for sleep function
import json;                            # to deal with json objects
import random                           # to generate random values
import threading                        # for creating threads
import uuid                             # to generate a unique identifier

# MS4: use Application Default Credentials (no embedded key files).
# GKE uses Workload Identity; Cloud Shell uses locally authorized ADC.

#To do: Set the project ID, topic name and the subscription_id 
project_id = os.environ.get("GCP_PROJECT", "project-9ac387a6-66c9-4c04-81d")
topic_name = "election"

# let the user enter the election and machine IDs
electionID = int(input("Please enter the election ID (integer): "))
machineID = int(input("Please enter the machine ID (integer): "))

debug=False;  # change to True for debugging
if debug:
    print("Authentication: Application Default Credentials")
    print(electionID);
    print(machineID);
    print(project_id);
    print(topic_name);

messageReceived=False;     # A flag to block the machine from sending a new votr unless the current vote is processed.
last_uuid='';              # A universally unique identifier for the current vote
# The callback function for handling received messages
def callback(message: pubsub_v1.subscriber.message.Message) -> None:
    # Make sure that the global variables are accessed from within the function.
    global last_uuid, messageReceived
    
    # get the message content
    message_data = json.loads(message.data);
    print(f"Received {message_data}.")
    
    # Check if the UUID matches the current vote
    if last_uuid==message_data['UUID'] :
        messageReceived=True; # unblock the main thread
    message_data = json.loads(message.data);
    message.ack()

# Assign a different subscription ID for each voting machine.
subscription_id = "election-result-"+str(machineID)+"-sub";

# create a subscriber to the subscriber for the project using the subscription_id
subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(project_id, subscription_id)
print(f"Listening for messages on {subscription_path}..\n")

# create a publisher and get the topic path for the publisher
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(project_id, topic_name)

# the condition used for filtering the messages to be recieved
sub_filter = "attributes.function=\"result\" AND attributes.machineID=\""+str(machineID)+"\"";

if debug:
    print(sub_filter)
    print(subscription_id);

# The subscriber thread function
def thread_function():
    global subscriber, subscription_path, topic_path, sub_filter;
    with subscriber:
        try:
            subscription = subscriber.create_subscription(
                    request={"name": subscription_path, "topic": topic_path, "filter": sub_filter}
                )
        except:
            pass
        streaming_pull_future = subscriber.subscribe(subscription_path, callback=callback)
        try:
            streaming_pull_future.result()
        except KeyboardInterrupt:
            streaming_pull_future.cancel()
            return
    
# Create and start the subscriber thread
x = threading.Thread(target=thread_function)
x.start()

# the main thread
while True:
    # randomally generate a new vote ( to mimic a real voting machine)
    last_uuid=str(uuid.uuid1())
    value={'machine_ID': machineID, 'voter_ID': int(random.random()*100), 
           'voting': int(random.random()*5), 'election_ID': electionID, 'UUID': last_uuid,
           'timestamp':int(1000*time.time())}
           
    messageReceived=False; # A flag to block the main thread until result is recieved
    
    # Publish the voting message
    future = publisher.publish(topic_path, json.dumps(value).encode('utf-8'),function="submit vote");
    print("The message "+str(value)+" is sent")
    
    # Wait for a result, Time out will be signaled if no answer is received after 10 seconds
    c=1;
    while( messageReceived==False):
        time.sleep(0.01);
        c=c+1;
        if(c==1000):
            print('Time out')
            break;

    # Send a new message after 1 second
    time.sleep(1);
