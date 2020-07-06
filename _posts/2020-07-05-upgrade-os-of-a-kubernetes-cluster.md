---
layout: post
title:  "Kubernetes and system upgrades"
date:   2020-07-05
categories: jekyll update
---
How do I update a kubernetes cluster cleanly? How can I make sure the OS is patched, and rebooted, with zero downtime?

Enter [system upgrade controller](). This will run a container that interacts with the OS, using privileged access, and will upgrade the OS. To do this you will need to deploy the system upgrade controller, plans for OS that you want to upgrade. And in my case I added a cronjob to trigger this every Sunday. These jobs will do a rolling upgrade of the OS. It will first drain the node, upgrade the node, reboot the node if needed and move to the next ndoe.

The following script will install everything. First it will mark all master nodes as capabable of running the system-upgrade-controller pod. Next it will install the actual deployment. Once the pod is running it will have loaded the Plan type CRD. Once that is available we load the plan for bionic and for centos 7, as well as the cronjob that will force a OS upgrade every Monday morning at 2am. Finally it will mark all `Ubuntu 18.04` so that the bionic plan will run on them and the `Centos 7` such that the centos7 plan will run on them.

```bash
#!/bin/bash

kubectl label node --overwrite --selector='node-role.kubernetes.io/master' node-role.kubernetes.io/master=true

# mark master nodes
kubectl label node --overwrite --selector='node-role.kubernetes.io/master' upgrade.cattle.io/controller=system-upgrade-controller
kubectl label node --overwrite --selector='node-role.kubernetes.io/controlplane' upgrade.cattle.io/controller=system-upgrade-controller

# load system-upgrade
#kubectl apply -f https://raw.githubusercontent.com/rancher/system-upgrade-controller/master/manifests/system-upgrade-controller.yaml
kubectl apply -f system-upgrade-controller.yaml

# wait for pod to run (and plan type to exist)
while [ "$(kubectl -n system-upgrade get pods | awk '/^system-upgrade/ { print $3 }')" != "Running" ]; do
  sleep 1
done

# load plans
kubectl apply -f bionic.yaml -f centos7.yaml

# load cronjob
kubectl apply -f cronjob.yaml

# label all nodes for centos 7, will also force an upgrade
kubectl get nodes --selector='!plan.upgrade.cattle.io/centos7' -o=custom-columns=NAME:.metadata.name,NODE:.status.nodeInfo.osImage | awk '/CentOS Linux 7/ { print $1 }' | xargs -t -I % -n 1 kubectl label node % --overwrite plan.upgrade.cattle.io/centos7=true

# label all nodes for ubuntu 18.04, will also force an upgrade
kubectl get nodes --selector='!plan.upgrade.cattle.io/bionic' -o=custom-columns=NAME:.metadata.name,NODE:.status.nodeInfo.osImage | awk '/Ubuntu 18.04/ { print $1 }' | xargs -t -I % -n 1 kubectl label node % --overwrite plan.upgrade.cattle.io/bionic=true
```

Following the system-upgrade-controller (version 0.6.1). This has a few changes to make it work wit [rancher](https://rancher.com).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: system-upgrade
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: system-upgrade
  namespace: system-upgrade
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name:  system-upgrade
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: system-upgrade
  namespace: system-upgrade
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: default-controller-env
  namespace: system-upgrade
data:
  SYSTEM_UPGRADE_CONTROLLER_DEBUG: "false"
  SYSTEM_UPGRADE_CONTROLLER_THREADS: "2"
  SYSTEM_UPGRADE_JOB_ACTIVE_DEADLINE_SECONDS: "900"
  SYSTEM_UPGRADE_JOB_BACKOFF_LIMIT: "99"
  SYSTEM_UPGRADE_JOB_IMAGE_PULL_POLICY: "Always"
  SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE: "rancher/kubectl:v1.18.3"
  SYSTEM_UPGRADE_JOB_PRIVILEGED: "true"
  SYSTEM_UPGRADE_JOB_TTL_SECONDS_AFTER_FINISH: "900"
  SYSTEM_UPGRADE_PLAN_POLLING_INTERVAL: "15m"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: system-upgrade-controller
  namespace: system-upgrade
spec:
  selector:
    matchLabels:
      upgrade.cattle.io/controller: system-upgrade-controller
  template:
    metadata:
      labels:
        upgrade.cattle.io/controller: system-upgrade-controller # necessary to avoid drain
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - {key: "node-role.kubernetes.io/master", operator: In, values: ["true"]}
              - matchExpressions:
                  - {key: "node-role.kubernetes.io/controlplane", operator: In, values: ["true"]}
      serviceAccountName: system-upgrade
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
        - key: "node-role.kubernetes.io/master"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/controlplane"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/etcd"
          operator: "Exists"
          effect: "NoExecute"
      containers:
        - name: system-upgrade-controller
          image: rancher/system-upgrade-controller:v0.5.0
          imagePullPolicy: IfNotPresent
          envFrom:
            - configMapRef:
                name: default-controller-env
          env:
            - name: SYSTEM_UPGRADE_CONTROLLER_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['upgrade.cattle.io/controller']
            - name: SYSTEM_UPGRADE_CONTROLLER_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          volumeMounts:
            - name: etc-ssl
              mountPath: /etc/ssl
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: etc-ssl
          hostPath:
            path: /etc/ssl
            type: Directory
        - name: tmp
          emptyDir: {}
```

The plan for `Ubuntu 18.04`. This will not upgrade kubernetes, and will only update docker on a reboot. The part in the secret is the actual script that is executed on each node, the plan is what controls the system-upgrade-controller and tells it how many nodes in parallel to upgrade (1 in my case) and if the node should be drained first (yes).

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: bionic
  namespace: system-upgrade
type: Opaque
stringData:
  upgrade.sh: |
    #!/bin/sh
    set -e
    # mark containerd.io to hold, otherwise it will kill this container BAD!
    apt-mark hold containerd.io kubeadm kubectl kubelet
    # do actual upgrade
    apt-get --assume-yes update
    apt-get --assume-yes dist-upgrade
    # unmark
    apt-mark unhold containerd.io kubeadm kubectl kubelet
    # reboot
    if [ -f /run/reboot-required ]; then
      cat /run/reboot-required
      # magic to install docker after the reboot
      if [ -e /etc/rc.local ]; then
        mv /etc/rc.local /etc/rc.local.orig
      fi
      cp /run/system-upgrade/secrets/bionic/rc.local /etc/rc.local
      chmod 755 /etc/rc.local
      reboot
    fi
  rc.local: |
    #!/bin/bash
    apt-get upgrade -y containerd.io
    if [ -e /etc/rc.local.orig ]; then
      /etc/rc.local.orig
      mv /etc/rc.local.orig /etc/rc.local
    else
      rm /etc/rc.local
    fi
---
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: bionic
  namespace: system-upgrade
spec:
  concurrency: 1
  nodeSelector:
    matchExpressions:
      - {key: plan.upgrade.cattle.io/bionic, operator: Exists}
  tolerations:
    - key: "node-role.kubernetes.io/master"
      operator: "Exists"
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/controlplane"
      operator: "Exists"
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/etcd"
      operator: "Exists"
      effect: "NoExecute"
  serviceAccountName: system-upgrade
  secrets:
    - name: bionic
      path: /host/run/system-upgrade/secrets/bionic
  drain:
    force: true
  version: bionic
  upgrade:
    image: ubuntu
    command: ["chroot", "/host"]
    args: ["sh", "/run/system-upgrade/secrets/bionic/upgrade.sh"]
```

The same for `Centos 7`

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: centos7
  namespace: system-upgrade
type: Opaque
stringData:
  upgrade.sh: |
    #!/bin/sh
    set -e
    # do actual upgrade
    setenforce 0
    yum upgrade -y --exclude docker-ce,kubeadm,kubectl,kubelet
    setenforce 1
    # needs-restarting returns 1 if reboot is needed
    if ! needs-restarting -r &> /dev/null; then
      needs-restarting -r || /bin/true  # otherwise script ends due to -e
      # magic to install docker after the reboot
      if [ -e /etc/rc.d/rc.local ]; then
        mv /etc/rc.d/rc.local /etc/rc.d/rc.local.orig
      fi
      cp /run/system-upgrade/secrets/centos7/rc.local /etc/rc.d/rc.local
      chmod 755 /etc/rc.d/rc.local
      reboot
    fi
  rc.local: |
    #!/bin/bash
    yum upgrade -y docker-ce
    if [ -e /etc/rc.d/rc.local.orig ]; then
      /etc/rc.d/rc.local.orig
      mv /etc/rc.d/rc.local.orig /etc/rc.d/rc.local
    else
      rm /etc/rc.d/rc.local
    fi
---
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: centos7
  namespace: system-upgrade
spec:
  concurrency: 1
  nodeSelector:
    matchExpressions:
      - {key: plan.upgrade.cattle.io/centos7, operator: Exists}
  tolerations:
    - key: "node-role.kubernetes.io/controlplane"
      operator: "Exists"
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/etcd"
      operator: "Exists"
      effect: "NoExecute"
  serviceAccountName: system-upgrade
  secrets:
    - name: centos7
      path: /host/run/system-upgrade/secrets/centos7
  drain:
    force: true
  version: centos7
  upgrade:
    image: centos
    command: ["chroot", "/host"]
    args: ["sh", "/run/system-upgrade/secrets/centos7/upgrade.sh"]
```

The following cronjob will set all plans back to the initial value, resulting in all nodes being upgraded.

```yaml
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: os-upgrade
  namespace: system-upgrade
spec:
  schedule: "0 2 * * 1"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          serviceAccountName: system-upgrade
          containers:
          - name: os-upgrade
            image: lachlanevenson/k8s-kubectl
            command:
            - /bin/sh
            - "-ec"
            - |
              # label all nodes for centos 7, will also force an upgrade
              kubectl get nodes -o=custom-columns=NAME:.metadata.name,NODE:.status.nodeInfo.osImage | awk '/CentOS Linux 7/ { print $1 }' | xargs -t -I % -n 1 kubectl label node % --overwrite plan.upgrade.cattle.io/centos7=true

              # label all nodes for ubuntu 18.04, will also force an upgrade
              kubectl get nodes -o=custom-columns=NAME:.metadata.name,NODE:.status.nodeInfo.osImage | awk '/Ubuntu 18.04/ { print $1 }' | xargs -t -I % -n 1 kubectl label node % --overwrite plan.upgrade.cattle.io/bionic=true
          restartPolicy: Never
```

Finally the following job will allow you to do a forced upgrade of all nodes in the cluster.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: os-upgrade-force
  namespace: system-upgrade
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: system-upgrade
      containers:
        - name: os-upgrade
          image: lachlanevenson/k8s-kubectl
          command:
            - /bin/sh
            - '-ec'
            - |
              # label all nodes for centos 7, will also force an upgrade
              kubectl get nodes -o=custom-columns=NAME:.metadata.name,NODE:.status.nodeInfo.osImage | awk '/CentOS Linux 7/ { print $1 }' | xargs -t -I % -n 1 kubectl label node % --overwrite plan.upgrade.cattle.io/centos7=true

              # label all nodes for ubuntu 18.04, will also force an upgrade
              kubectl get nodes -o=custom-columns=NAME:.metadata.name,NODE:.status.nodeInfo.osImage | awk '/Ubuntu 18.04/ { print $1 }' | xargs -t -I % -n 1 kubectl label node % --overwrite plan.upgrade.cattle.io/bionic=true
```