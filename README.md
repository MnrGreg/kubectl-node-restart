# kubectl-node-restart

`kubectl-node-restart` is a [kubectl plugin](https://kubernetes.io/docs/tasks/extend-kubectl/kubectl-plugins/) that sequentially and gracefully performs a rolling restart of Nodes within a Kubernetes cluster

![using kubectl-node-restart plugin](demo/usage.gif)

# Installing
- install `krew` using instructions [here](https://github.com/kubernetes-sigs/krew#installation)
- run `kubectl krew update`
- run `kubectl krew install node-restart`

![installing kubectl-node-restart plugin](demo/installation.gif)


# Usage

- perform rolling restart of all nodes in a cluster

```bash
    kubectl node-restart all
```

- restart only specific nodes selected through labels

```bash
    kubectl node-restart --selector node-role.kubernetes.io/master
```

- perform a dry-run

```bash
    kubectl node-restart all --dry-run
```

- restart node(s) without first draining

```bash
    kubectl node-restart all --force
```

- add a delay of 120seconds between node restarts

```bash
    kubectl node-restart all --sleep 120
```