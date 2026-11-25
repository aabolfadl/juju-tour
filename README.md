# juju-tour

Driving [Juju](https://juju.is) the way an operator does, on two substrates at once:
one controller on **LXD** (machines) and one on **Canonical Kubernetes** (pods), with a
PostgreSQL database offered from one to the other.

Everything lives in one script, [`tour.sh`](tour.sh), split into numbered sections that
you run one at a time and read between:

```
./tour.sh list
./tour.sh 0      # preflight: tools and clouds (installs nothing)
./tour.sh 1      # bootstrap tour-lxd (localhost) and tour-k8s (Kubernetes)
./tour.sh 2      # Kubernetes model: postgresql-k8s + data-integrator, credentials, scale 1 -> 2 -> 1
./tour.sh 3      # machine model: the same pattern with the machine postgresql charm
./tour.sh 4      # cross-model: offer the LXD database, consume it from the Kubernetes model, connect with psql
./tour.sh 5      # secrets (add, grant, reveal, rotate) and charm config
./tour.sh 6      # look inside: show-unit, show-status-log, debug-log, jhack, kubectl
./tour.sh 7      # export both models to bundles/
./tour.sh 8      # teardown: consumer first, then the offerer
```

Every command is echoed with a `$ ` prefix before it runs, so the output reads as a
transcript.

## What you need

| | Version used |
|---|---|
| Juju | 3.6 (`snap install juju --channel 3.6/stable`) |
| LXD | 5.21 (`snap install lxd --channel 5.21/stable && lxd init --auto`) |
| Canonical Kubernetes | 1.32 (`snap install k8s --classic --channel 1.32-classic/stable`) |
| jhack | `snap install jhack --channel latest/edge` |
| jq, kubectl | any recent |

The Kubernetes cluster must be registered with the Juju client as a cloud. The script
expects it to be called `ck8s` (override with `K8S_CLOUD=...`):

```
sudo k8s config | juju add-k8s ck8s --client
```

On a clean CI-style machine, [`concierge`](https://github.com/canonical/concierge) can do
all of this in one step. **Don't use it on a laptop that also runs Docker**: its
Kubernetes step stops `containerd.service` and its LXD step flushes the `FORWARD` firewall
chain, which breaks Docker. Install by hand there, and turn on IPv4 forwarding before
Docker starts so LXD containers keep their network.

About 6 GB of free RAM is enough for both controllers and both databases.

## What's in the repo

- `tour.sh`: the tour.
- `bundles/pods.yaml`, `bundles/machines.yaml`: `juju export-bundle` of each model
  after section 6, committed exactly as Juju wrote them. The consumer side (`pods.yaml`)
  records the cross-model link as `saas: pg: url: tour-lxd:admin/machines.pg`. The
  offering side (`machines.yaml`) puts the offer in an overlay document, but also lists
  the *consumer* as an empty `saas: remote-<uuid>: {}` entry with a relation to it. That
  entry has no URL, so delete it (and its relation) before deploying `machines.yaml`
  somewhere else.

## Overriding names

`K8S_CLOUD`, `LXD_CTRL` (default `tour-lxd`), `K8S_CTRL` (`tour-k8s`), `VM_MODEL`
(`machines`), `POD_MODEL` (`pods`), `PG_CHANNEL` (`16/stable`), `WAIT_SECS` (`1800`).
