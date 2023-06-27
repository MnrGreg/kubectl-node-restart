#!/usr/bin/env bash

image='alpine:3.15'
nodesleep=20 #Time delay between node restarts - give pods time to start up
restartdeadline=300
kubeletdeadline=300
uncordondelay=0
force=false
dryrun=false
blue='\033[0;34m'
nocolor='\033[0m'
rebootcommand='touch /node-restart-flag && reboot'

function print_usage() {
  echo "Usage: kubectl node-restart [<options>]"
  echo ""
  echo "  all                                 Restarts all nodes within the cluster"
  echo ""
  echo "  --context context                   Specify the context (or use kubectx)"
  echo "  -l|--selector key=value             Selector (label query) to target specific nodes"
  echo "  -f|--force                          Restart node(s) without first draining"
  echo "  -d|--dry-run                        Just print what to do; don't actually do it"
  echo "  -s|--sleep                          Sleep delay between restarting Nodes (default 20s)"
  echo "  -r|--registry                       Pull Alpine image from an alternate registry"
  echo "  -c|--command                        Pre-restart command to be executed"
  echo "  -ud|--uncordon-delay                 Sleep delay before uncordoning a node (default 0s)"
  echo "  -rd|--restart-deadline                  Deadline for the restart job to complete (default 300s)"
  echo "  -kd|--kubelet-deadline                  Deadling for kubelet to start up (default 300s)"
  echo "  -h|--help                           Print usage and exit"
}

while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
    all)
      allnodes=true
      shift
      ;;
    --context)
      cluster="$2"
      echo -e "${blue}Targeting cluster $cluster${nocolor}"
      context="--context $cluster"
      shift
      shift
      ;;
    -l | --selector)
      selector="$2"
      shift
      shift
      ;;
    -f | --force)
      force=true
      shift
      ;;
    -d | --dry-run)
      dryrun=true
      shift
      ;;
    -s | --sleep)
      nodesleep="$2"
      shift
      shift
      ;;
    -r | --registry)
      image="$2"
      shift
      shift
      ;;
    -c | --command)
      rebootcommand="$2 && touch /node-restart-flag && reboot"
      shift
      shift
      ;;
    -ud | --uncordon-delay)
      uncordondelay="$2"
      shift
      shift
      ;;
    -rd | --restart-deadline)
      restartdeadline="$2"
      shift
      shift
      ;;
    -kd | --kubelet-deadline)
      kubeletdeadline="$2"
      shift
      shift
      ;;
    -h | --help)
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
  while [[ $i -lt $restartdeadline ]]; do
    status=$(kubectl get job $pod -n kube-system -o "jsonpath={.status.succeeded}" $context 2> /dev/null)
    if [[ $status -gt 0 ]]; then
      echo "Restart complete after $i seconds"
      break
    else
      i=$(($i + 10))
      sleep 10
      echo "$node - $i seconds"
    fi
  done
  if [[ $i == $restartdeadline ]]; then
    echo "Error: Restart job did not complete within $restartdeadline seconds"
    exit 1
  fi
}

function wait_for_status() {
  node=$1
  i=0
  while [[ $i -lt $kubeletdeadline ]]; do
    status=$(kubectl get node $node -o "jsonpath={.status.conditions[?(.reason==\"KubeletReady\")].type}" $context 2> /dev/null)
    if [[ "$status" == "Ready" ]]; then
      echo "KubeletReady after $i seconds"
      break
    else
      i=$(($i + 10))
      sleep 10
      echo "$node NotReady - waited $i seconds"
    fi
  done
  if [[ $i == $kubeletdeadline ]]; then
    echo "Error: Did not reach KubeletReady state within $kubeletdeadline seconds"
    exit 1
  fi
}

if [ "$allnodes" == "true" ]; then
  nodes=$(kubectl get nodes -o jsonpath={.items[*].metadata.name} $context)
  echo -e "${blue}Targeting nodes:${nocolor}"
  for node in $nodes; do
    echo " $node"
  done
elif [ ! -z "$selector" ]; then
  nodes=$(kubectl get nodes --selector=$selector -o jsonpath={.items[*].metadata.name} $context)
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
      echo "kubectl cordon $node $context"
    else
      kubectl $context cordon "$node"
    fi
  else
    echo -e "\n${blue}Draining node $node...${nocolor}"
    if $dryrun; then
      echo "kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force $context"
    else
      kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force $context
    fi
  fi

  echo -e "${blue}Initiating node restart job on $node...${nocolor}"
  pod="node-restart-$(env LC_CTYPE=C LC_ALL=C tr -dc a-z0-9 < /dev/urandom | head -c 5)"
  if $dryrun; then
    echo "kubectl create job $pod $context"
  else
    kubectl apply $context -f- << EOT
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
  else
    echo "Waiting $restartdeadline seconds for restart job completion."
    echo "Waiting $kubeletdeadline seconds for kubelet initialization."
  fi

  if [[ $uncordondelay -gt 0 ]]; then
    echo "Waiting $uncordondelay seconds before uncordoning."
  fi

  echo -e "${blue}Uncordoning node $node${nocolor}"

  if $dryrun; then
    echo "kubectl uncordon $node $context"
  else
    sleep $uncordondelay
    kubectl uncordon "$node" $context
    kubectl delete job $pod -n kube-system $context
    sleep $nodesleep
  fi
done
