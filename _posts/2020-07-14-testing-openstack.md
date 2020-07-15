---
layout: post
title:  "Testing OpenStack"
date:   2020-07-14
categories: openstack testing
---
This is not official but is something that worked for me.

# Setup

Before we can start testing we need a few things. To make it easier to launch jobs on many nodes in parallel we will leverage of a kubernetes cluster. We will create machines first, install docker and configure the nodes to be a kubernetes cluster.

Once the kubernetes cluster is configured we will install rabbitmq, which will be used to distribute the work to each node, as well as collect statistics.

Finally we will load 3 deployments in the kubernetes cluster. Each of these deployments is configured to start with 0 replicas.

- creator, which will add jobs to rabbitmq. This pod will not stop automatically. It is controlled by a deployment that can be scaled up (to 1 is fine) and back to 0 once enough jobs are creates.
- parser, this will be run at the end and collect the statistics of each job. This will just read the results from a queue and print them to the screen. This pod will not stop automatically. It is controlled by a deployment that can be scaled up (should be 1 only) and back to 0 once all results are parsed.
- worker, which will do the actual work. There are different types of tests inside this container. What test is done is based on the job that is in the queue. Again this is controlled by a deployment. You can scale this up to have more parallel jobs done. The assumption is that kubernetes will try and place them uniformly on all nodes.

## Installing Kubernetes

Create a kubernetes cluster, in my case 200 worker nodes and 3 master nodes.

```bash
#!/bin/bash

openstack server create \
            --config-drive true \
            --flavor m1.medium \
            --key-name radiant \
            --network ext-net \
            --network kooper-net \
            --security-group "rancher" \
            --image CentOS-7-GenericCloud-Latest \
            --user-data kube-master.sh \
            --min 3 \
            --max 3 \
            rob-test-master

openstack server create \
            --config-drive true \
            --flavor m1.large \
            --key-name radiant \
            --network kooper-net \
            --security-group "rancher" \
            --image CentOS-7-GenericCloud-Latest \
            --user-data kube-worker.sh \
            --min 200 \
            --max 200 \
            rob-test-worker
```

Script to initialize kubernetes master node(s), this is executed as part of the cloud-init. I leverage of my rancher setup to get kubernetes setup.

```bash
#!/bin/bash

echo "Installing docker"
curl https://raw.githubusercontent.com/rancher/install-docker/master/19.03.11.sh | sudo sh
systemctl enable docker

echo "Installing kubernetes"
sudo docker run -d --privileged --restart=unless-stopped --net=host \
	-v /etc/kubernetes:/etc/kubernetes \
	-v /var/run:/var/run \
	rancher/rancher-agent:v2.4.5 \
		--server https://gonzo-rancher.ncsa.illinois.edu \
		--token secret \
		--etcd --controlplane
```

Same for the worker nodes, slightly different script

```bash
#!/bin/bash

echo "Installing iscsi driver"
yum -y install iscsi-initiator-utils

echo "Installing docker"
curl https://raw.githubusercontent.com/rancher/install-docker/master/19.03.11.sh | sudo sh
systemctl enable docker

echo "Installing kubernetes"
sudo docker run -d --privileged --restart=unless-stopped --net=host \
	-v /etc/kubernetes:/etc/kubernetes \
	-v /var/run:/var/run \
	rancher/rancher-agent:v2.4.5 \
		--server https://gonzo-rancher.ncsa.illinois.edu \
		--token secret \
		--worker
```

Wait for the cluster to be up and running, use `kubectl get nodes` to make sure all nodes are up and running.

At this point there is a cluster with 3 master nodes that have a public ip address and 200 nodes that have a private ip address.

## Installing RabbitMQ

We use helm to deploy rabbitmq:

```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install rabbitmq bitnami/rabbitmq \
	--set rabbitmq.auth.password=guest \
	--set rabbitmq.auth.username=guest
```

## Running the server

The download tests leverages of a small server that will need to run somewhere with a lot of bandwith. The goal is for this server to be able to handle all the requests coming in from all the worker pods. You can find the code for the [server](#appendix-b-server) at the end of this document. 

Once the docker image is created you can either run it using docker, or copy the binary out from the docker image and just run it on any machine. The code is written in GO and should not require any libraries.

```bash
docker create --name radiantserver radiant/server
docker cp radiantserver:/server .
docker rm radiantserver
```

The server runs on port 5201, that will need to be opened in the firewall. The binary does not take any command line arguments.

## Installing deployments

As stated before we use 3 deployments, you can see the code for the docker image that is used in [Appendix A: Testing Code](#appendix-a-testing-code). 

The creator deployment can be modified to control the job that will be executed. You can choose from:

- sleep, this will spin the CPU for 1 second.
- image, this will create a 2048x2048 image using imagemagick and write it to /
- random, this will create a 1GB file using /dev/urandom and write it to / using `dd`
- pi, will create pi with 50,000 decimals, using 2000 iterations
- download, will download a 1GB file from the [server](#appendix-b-server).

The deployment to push commands to rabbitmq.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: creator
spec:
  replicas: 0
  selector:
    matchLabels:
      app: creator
  template:
    metadata:
      labels:
        app: creator
    spec:
      containers:
      - name: creator
        image: hub.ncsa.illinois.edu/kooper/radiant
        command: ["python", "creator.py", "download"]
```

The deployment to start the workers.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
spec:
  replicas: 0
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      containers:
      - name: worker
        image: hub.ncsa.illinois.edu/kooper/radiant
        command: ["python", "worker.py"]
```

The deployment to start the parser.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: parser
spec:
  replicas: 0
  selector:
    matchLabels:
      app: parser
  template:
    metadata:
      labels:
        app: parser
    spec:
      containers:
      - name: parser
        image: hub.ncsa.illinois.edu/kooper/radiant
        command: ["python", "parser.py"]
```

# Testing Open Stack

Testing consists of 3 steps. Create jobs, process jobs and parse results.

## Create Jobs

To start testing you will need to pick your test, and run the creator deployment to put jobs in rabbitmq, the number of jobs in the queue depends on how many parallel jobs you plan to do. Running for a few seconds should generate about 500,000 jobs which should be enough.

```
kubectl scale --replicas=1 deployment/creator
sleep 10
kubectl scale --replicas=0 deployment/creator
```

## Process Jobs

Once you have the jobs created we want to start processing them. This is where we go parallel across the kubernetes cluster. The ask performed is based on the job put in the queue by the creator. For example the following sequence will create 100 workers that process jobs in parallel, write their results in a new rabbitmq queue, and start the next job. After 300 seconds (5 minutes) the workers are scaled down to 0.

```
kubectl scale --replicas=100 deployment/creator
sleep 300
kubectl scale --replicas=0 deployment/creator
```

Couple of caveats:

- pulling the same image on many nodes from docker hub will result in a 429 error and you will be throttled. This will impact the measurements. I pushed the image to a private registry to avoid this.
- if you want to do a different test you will need to empty the worker queue in rabbitmq first. I used the webinterface to do this.

## Parsing the results

Once all workers have stopped we can get the results. To do this we will use the parser deployment. This will get the results from rabbitmq, print them to stdout so they can be parsed. For example the following code will compute the average time:

```
kubectl scale --replicas=1 deployment/parser
sleep 30
POD=$(kubectl get po -l app=parser --no-headers | awk '{print $1}')
kubectl logs ${POD} | sed 's/=/ /g' | awk "/Got message/ { total += \$7; count++ } END { print count, total/count }"
```

## Single script to run them all

The following script will asume the queue is filled with work, and run 1, 10, 50, 100, 200, 400 and 800 worker pods, compute the results and write them to stdout.

```bash
#!/bin/bash

run_test() {
  workers=$1
  sleep=$2

  kubectl scale --replicas=0 deployment/worker
  kubectl scale --replicas=0 deployment/parser

  while [ "$(kubectl get po -l app=parser --no-headers 2>/dev/null)" != "" ]; do
    sleep 1
  done
  echo "no more parsers"

  while [ "$(kubectl get po -l app=worker --no-headers 2>/dev/null)" != "" ]; do
    sleep 1
  done
  echo "no more workers"

  kubectl scale --replicas=$workers deployment/worker
  sleep $sleep
  kubectl scale --replicas=0 deployment/worker

  while [ "$(kubectl get po -l app=worker --no-headers 2>/dev/null)" != "" ]; do
    sleep 1
  done
  echo "no more workers"

  kubectl scale --replicas=1 deployment/parser
  while [ "$(kubectl get po -l app=parser --no-headers | grep Running 2>/dev/null)" == "" ]; do
    sleep 1
  done
  sleep 30
  kubectl logs $(kubectl get po -l app=parser --no-headers | awk '{print $1}') | sed 's/=/ /g' | awk "/Got message/ { total += \$7; count++ } END { print $workers, count, total/count }"
  kubectl scale --replicas=0 deployment/parser
}

run_test   "1" "300"
run_test  "10" "300"
run_test  "50" "300"
run_test "100" "300"
run_test "200" "300"
run_test "400" "300"
run_test "800" "300"
```

# Appendix A: Testing Code

These 3 files make up the docker image that is used for testing. The deployments assume the image to be called `kooper/radiant` but you can push it to any registry and any name, just update and apply the yaml files.

## creator.py

```python
import pika
import sys

if sys.argv[1]:
  job=sys.argv[1]
else:
  job='pi'

parameters = pika.URLParameters('amqp://guest:guest@rabbitmq:5672/%2F')
print(str(parameters))
connection = pika.BlockingConnection(parameters)
channel = connection.channel()
channel.queue_declare(queue='worker')

while True:
  channel.basic_publish(exchange='', routing_key='worker', body=job)

print(" [x] Sent jobs")
```

## worker.py

```
import pika
import json
import sys
import time
import subprocess
import decimal
import urllib.request
import shutil

count = 0

# image to be created
size = 2048

# for pi calc
decimal.getcontext().prec = 50000
loop = 2000

# for download a file (1GB)
url = "http://someserver:5201/" + str(1 * 1024 * 1024 * 1024)
chunk_size = 16 * 1024


def callback(ch, method, properties, body):
  global count

  cms = lambda: int(round(time.time() * 1000))
  start = cms()

  if body == b"sleep":
    ms = cms()
    while cms() - ms < 1000:
      pass

  elif body == b"image":
    cms = lambda: int(round(time.time() * 1000))
    print(subprocess.check_output(["/usr/bin/convert", "-size", "%dx%d" % (size, size), "plasma:", "image_%d.jpg" % count]))
    print(subprocess.check_output(["ls", "-l", "image_%d.jpg" % count]))

  elif body == b"random":
    subprocess.check_output(["dd", "if=/dev/urandom", "of=foo", "bs=1M", "count=1000"])

  elif body == b"pi":
    pi = sum(1/decimal.Decimal(16)**k *
             (decimal.Decimal(4)/(8*k+1) -
              decimal.Decimal(2)/(8*k+4) -
              decimal.Decimal(1)/(8*k+5) -
              decimal.Decimal(1)/(8*k+6)) for k in range(loop))

  elif body == b"download":
    #with urllib.request.urlopen(url) as response, open("/dev/null", 'wb') as out_file:
    #  shutil.copyfileobj(response, out_file)
    with urllib.request.urlopen(url) as response:
      while True:
        chunk = response.read(chunk_size)
        if not chunk:
          break

  end = cms()

  count = count + 1
  print(' [*] Got message count=%d body=%s wait=%d' % (count, body, end - start), flush=True)
  ch.basic_publish(exchange='', routing_key='results', body=json.dumps({"msg": body.decode('utf-8'), "time": end - start}))
  ch.basic_ack(method.delivery_tag)


parameters = pika.URLParameters('amqp://guest:guest@rabbitmq:5672/%2F')
connection = pika.BlockingConnection(parameters)
channel = connection.channel()
channel.queue_declare(queue='results')
channel.basic_qos(prefetch_count=1)

channel.basic_consume(queue='worker', on_message_callback=callback, auto_ack=False)
print(' [*] Waiting for messages. To exit press CTRL+C', flush=True)
channel.start_consuming()
```

## parser.py

```python
import pika
import json

from decimal import Decimal, getcontext
getcontext().prec=500

def callback(ch, method, properties, body):
  jbody = json.loads(body)
  print(' [*] Got message body=%s wait=%d' % (jbody['msg'], jbody['time']), flush=True)


parameters = pika.URLParameters('amqp://guest:guest@rabbitmq:5672/%2F')
connection = pika.BlockingConnection(parameters)
channel = connection.channel()
channel.queue_declare(queue='results')

channel.basic_consume(queue='results', on_message_callback=callback, auto_ack=True)
print(' [*] Waiting for messages. To exit press CTRL+C', flush=True)
channel.start_consuming()
```

## Dockerfile

```Dockerfile
FROM python:alpine

RUN pip install pika && \
    apk add imagemagick

COPY *.py /
CMD python /worker.py
```

# Appendix B: Server

This creates a simple server that can handle a GET and POST request. The GET request will return the number of bytes requested, for example `GET /500` will return 500 bytes.

The POST request will allow to upload a file that is written to /dev/null.

## server.go

```go
package main

import (
  "io"
  "fmt"
  "log"
  "math/rand"
  "net/http"
  "os"
  "strconv"
)

var bufferSize = 1024*1024
var buffer = make([]byte, bufferSize)

func handler(w http.ResponseWriter, r *http.Request) {
  switch r.Method {
  case "GET":
    strAsked := r.URL.Path[1:]
    bytesAsked, err := strconv.Atoi(strAsked)
    if err != nil {
      log.Printf("Invalid size requested : %v", err)
      return
    }
    log.Printf("Received GET for %d bytes", bytesAsked)
    w.Header().Set("Content-Length", strAsked)
    w.Header().Set("Content-Type", "application/octet-stream")
    for bytesAsked > 0 {
      if bytesAsked < bufferSize {
        written, err := w.Write(buffer[0:bytesAsked])
        if err != nil {
          log.Print(err)
          return
        }
        bytesAsked -= written
      } else {
        written, err := w.Write(buffer)
        if err != nil {
          log.Print(err)
          return
        }
        bytesAsked -= written
      }
    }

  case "POST":
    // no parse of the data, just write it to /dev/null
    f, err := os.OpenFile("/dev/null", os.O_WRONLY| os.O_CREATE | os.O_TRUNC, 0644)
    if err != nil {
      log.Print(err)
      return
    }
    written, err := io.Copy(f, r.Body)
    if err != nil {
      log.Print(err)
    }
    err = r.Body.Close()
    if err != nil {
      log.Print(err)
    }
    err = f.Close()
    if err != nil {
      log.Print(err)
    }
    log.Printf("Received POST on %s with %d bytes", r.URL.Path, written)
    fmt.Fprintf(w, "Received %d bytes\n", written)

  default:
    fmt.Fprintf(w, "Sorry, only GET and POST methods are supported.")
  }
}

func main() {
  // initialize random data
  rand.Read(buffer)

  // register handler for /
  http.HandleFunc("/", handler)

  // start the server
  fmt.Printf("Starting HTTP server...\n")
  if err := http.ListenAndServe(":5201", nil); err != nil {
    log.Fatal(err)
  }
}
```

## Dockerfile

```dockerfile
FROM golang as builder

ENV CGO_ENABLED=0  \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /build
COPY server.go .

RUN go get -d -v
RUN go build -ldflags="-w -s" -o /server

# create user
RUN echo "server:x:1000:1000:App User:/tmp:/sbin/nologin" > /tmp/passwd && \
    echo "server:x:1000:" > /tmp/group

# final server image
FROM scratch
EXPOSE 5201
COPY --from=builder /server /
COPY --from=builder /tmp/passwd /tmp/group /etc/
USER server:server
ENTRYPOINT ["/server"]
```
