---
layout: post
title:  "Almost VPN"
date:   2020-07-14
categories: vpn
---
Instead of starting my vpn software I use the following. This works well for accessing sites. It uses a SSH tunnel instead. This works on my Mac

Script to setup tunnel and proxy
```
#!/bin/bash

# some config variables
SSHSERVER="the-remote-machine"
PROXYPORT=9050
WEBPORT=5678

# trap specific signals
trap cleanup INT
trap checkup CHLD

# check all child processes
function checkup() {
  if [ "$SSHPID" != "" ]; then
    if ! kill -0 ${SSHPID} &> /dev/null ; then
      echo "ssh is dead [${SSHPID}]"
      cleanup
    fi
  else
    echo "SSH is dead"
  fi
  if [ "$WEBPID" != "" ]; then
    if ! kill -0 ${WEBPID} &> /dev/null ; then
      echo "webserver is dead [${WEBPID}]"
      cleanup
    fi
  else
    echo "WEB is dead"
  fi
}

# cleanup function at the end
function cleanup() {
  trap - INT
  trap - CHLD

  # turn off proxy
  networksetup -setautoproxystate "Wi-Fi" off

  # kill webserver
  if [ "$WEBPID" != "" ]; then
    if kill -0 ${WEBPID} &> /dev/null ; then
      echo "Killing webserver [${WEBPID}]"
      kill ${WEBPID}
    fi
  fi

  # kill tunnel
  if [ "$SSHPID" != "" ]; then
    if kill -0 ${SSHPID} &> /dev/null ; then
      echo "Killing ssh [${SSHPID}]"
      kill ${SSHPID}
    fi
  fi

  exit 0
}

# kill existing tunnel and start a new one, otherwise we can't trap CHLD
OLDSSHPID=$(pgrep -f 'ssh -D ${PROXYPORT}')
if [ "$OLDSSHPID" != "" ]; then
  kill ${OLDSSHPID}
fi
ssh -D ${PROXYPORT} -f -q -C -N ${SSHSERVER}
SSHPID=$(pgrep -f "ssh -D ${PROXYPORT}")

# kill existing server and start a new one, otherwise we can't trap CHLD
OLDWEBPID=$(pgrep -f 'SimpleHTTPServer ${WEBPORT}')
if [ "$OLDWEBPID" != "" ]; then
  kill ${OLDWEBPID}
fi
python -m SimpleHTTPServer ${WEBPORT} 2> /dev/null &
WEBPID=$(pgrep -f "SimpleHTTPServer ${WEBPORT}")

# fix proxy
networksetup -setautoproxyurl "Wi-Fi" "http://localhost:${WEBPORT}/proxy.pac"

# show proxy setup
echo "export http_proxy=socks5://127.0.0.1:${PROXYPORT}"
echo "export https_proxy=socks5://127.0.0.1:${PROXYPORT}"

# now just wait
while [ 1 == 1 ]; do
  sleep 1
  checkup
done
```

and the proxy pac file
```
function FindProxyForURL(url, host) {
  if (shExpMatch(host, "host1") ||
      shExpMatch(host, "host2")) {
    return "SOCKS localhost:9050";
  }

  return "DIRECT";
}
```
