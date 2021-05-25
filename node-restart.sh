#!/bin/bash

image='alpine:3.9'
nodesleep=20        #Time delay between node restarts - give pods time to start up
force=false
dryrun=false
blue='\033[0;34m'
nocolor='\033[0m'
rebootcommand='touch /node-restart-flag && reboot'

function print_usage() {
  echo "Usage: kubectl node-restart [<options>]"
  echo ""
  echo "all                                 Restarts all nodes within the cluster"
  echo ""
  echo "-l|--selector key=value             Selector (label query) to target specific nodes"
  echo ""
  echo "-f|--force                          Restart node(s) without first draining"
  echo ""
  echo "-d|--dry-run                        Just print what to do; don't actually do it"
  echo ""
  echo "-s|--sleep                          Sleep delay between restarting Nodes (default 20s)"
  echo ""
  echo "-r|--registry                       Pull Alpine image from an alternate registry"
  echo ""
  echo "-c|--command                        Pre-restart command to be executed"
  echo ""
  echo "-h|--help                           Print usage and exit"
}

while [[ $# -gt 0 ]]
do
  key="$1"

  case $key in
    all)
    allnodes=true
    shift
    ;;
    -l|--selector)
    selector="$2"
    shift
    shift
    ;;
    -f|--force)
    force=true
    shift
    ;;
    -d|--dry-run)
    dryrun=true
    shift
    ;;
    -s|--sleep)
    nodesleep="$2"
    shift
    shift
    ;;
    -r|--registry)
    image="$2"
    shift
    shift
    ;;
    -c|--command)
    rebootcommand="$2 && touch /node-restart-flag && reboot"
    shift
    shift
    ;;
    -h|--help)
    print_usage
    exit 0
    ;;
    *)
    print_usage
    exit 1
    ;;
  esac
done

function wait_for_job_completion() {
  pod=$1
  i=0
  while [[ $i -lt 30 ]]; do
    status=$(kubectl get job $pod -n kube-system -o "jsonpath={.status.succeeded}" 2>/dev/null)
    if [[ $status -gt 0 ]]; then
      echo "Restart complete after $((i*10)) seconds"
      break;
    else
      i=$(($i+1))
      sleep 10s
      echo "$node - $((i*10)) seconds"
    fi
  done
  if [[ $i == 30 ]]; then
    echo "Error: Restart job did not complete within 5 minutes"
    exit 1
  fi
}

function wait_for_status() {
  node=$1
  i=0
  while [[ $i -lt 30 ]]; do
    status=$(kubectl get node $node -o "jsonpath={.status.conditions[?(.reason==\"KubeletReady\")].type}" 2>/dev/null)
    if [[ "$status" == "Ready" ]]; then
      echo "KubeletReady after $((i*10)) seconds"
      break;
    else
      i=$(($i+1))
      sleep 10s
      echo "$node NotReady - waited $((i*10)) seconds"
    fi
  done
  if [[ $i == 30 ]]; then
    echo "Error: Did not reach KubeletReady state within 5 minute"
    exit 1
  fi
}

if [ "$allnodes" == "true" ]; then
  nodes=$(kubectl get nodes -o jsonpath={.items[*].metadata.name})
  echo -e "${blue}Targeting nodes:${nocolor}"
  for node in $nodes; do
    echo " $node"
  done
elif [ ! -z "$selector" ]; then
  nodes=$(kubectl get nodes --selector=$selector -o jsonpath={.items[*].metadata.name})
  echo -e "${blue}Targeting selective nodes:${nocolor}"
  for node in $nodes; do
    echo " $node"
  done
else
  print_usage
fi

for node in $nodes; do
  if $force; then
    echo -e "\nWARNING: --force specified, restarting node $node without draining first"
    if $dryrun; then
      echo "kubectl cordon $node"
    else
      kubectl cordon "$node"
    fi
  else
    echo -e "\n${blue}Draining node $node...${nocolor}"
    if $dryrun; then
      echo "kubectl drain $node --ignore-daemonsets --delete-local-data"
    else
      kubectl drain "$node" --ignore-daemonsets --delete-local-data
    fi
  fi
  
  echo -e "${blue}Initiating node restart job on $node...${nocolor}"
  pod="node-restart-$(env LC_CTYPE=C LC_ALL=C tr -dc a-z0-9 < /dev/urandom | head -c 5)"
  if $dryrun; then
    echo "kubectl create job $pod"
  else
cat << EOT | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $pod
  namespace: kube-system
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 30
  template:
    spec:
      nodeName: $node
      hostPID: true
      tolerations:
      - effect: NoSchedule
        operator: Exists
      containers:
      - name: $pod
        image: $image
        command: [ "nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--pid", "--", "bash", "-c" ]
        args: [ "if [ -f /node-restart-flag ]; then rm /node-restart-flag && exit 0; else $rebootcommand && exit 1; fi" ]
        securityContext:
          privileged: true
      restartPolicy: Never
EOT
  fi

  if ! $dryrun; then
    echo -e "${blue}Waiting for restart job to complete on node $node...${nocolor}"
    wait_for_job_completion $pod
    wait_for_status $node KubeletReady
  fi

  echo -e "${blue}Uncordoning node $node${nocolor}"

  if $dryrun; then
    echo "kubectl uncordon $node"
  else
    kubectl uncordon "$node"
    kubectl delete job $pod -n kube-system
    sleep $nodesleep
  fi
done