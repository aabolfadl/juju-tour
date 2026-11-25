#!/usr/bin/env bash
# juju-tour: drive Juju like an operator, on two substrates.
#
#   ./tour.sh <section>     run one section (0-8), e.g. ./tour.sh 2
#   ./tour.sh list          list the sections
#
# Sections are meant to be run one at a time, in order, reading the output
# between them. Every command is echoed with a "$ " prefix before it runs.
#
#   0  preflight      check the tools and the two clouds (installs nothing)
#   1  bootstrap      one controller on LXD, one on Canonical Kubernetes
#   2  k8s model      postgresql-k8s + data-integrator, credentials, scale up/down
#   3  machine model  the same pattern with the machine postgresql charm
#   4  cross-model    offer the machine database, consume it from Kubernetes
#   5  secrets/config user secrets, grants, revisions, charm config
#   6  look inside    show-unit, status log, debug-log, jhack, kubectl
#   7  export         juju export-bundle for each model into bundles/
#   8  teardown       destroy both controllers and everything in them
#
# Names can be overridden from the environment:
K8S_CLOUD=${K8S_CLOUD:-ck8s}         # the Kubernetes cloud known to the Juju client
LXD_CTRL=${LXD_CTRL:-tour-lxd}
K8S_CTRL=${K8S_CTRL:-tour-k8s}
VM_MODEL=${VM_MODEL:-machines}       # model on the LXD controller
POD_MODEL=${POD_MODEL:-pods}         # model on the Kubernetes controller
PG_CHANNEL=${PG_CHANNEL:-16/stable}
WAIT_SECS=${WAIT_SECS:-1800}

set -uo pipefail
cd "$(dirname "$0")"

VM="$LXD_CTRL:admin/$VM_MODEL"
POD="$K8S_CTRL:admin/$POD_MODEL"

hr()  { printf '\n\033[1;35m## %s\033[0m\n' "$*"; }
run() { printf '\033[1;36m$ %s\033[0m\n' "$*"; "$@"; local rc=$?; [ $rc -ne 0 ] && printf '\033[31m(exit %d)\033[0m\n' $rc; return 0; }
die() { printf '\033[31m%s\033[0m\n' "$*"; exit 1; }

# Wait until <app> has exactly <n> units, all workload=active and agent=idle.
# (juju wait-for application ... --query='status=="active"' is not enough: the
# application status stays "active" while a new unit is still allocating.)
wait_units() {  # <model> <app> <n>
  printf '\033[2m(waiting: %s with %s unit(s), all active/idle)\033[0m\n' "$2" "$3"
  local t=0 total ok
  while :; do
    read -r total ok < <(juju status -m "$1" --format json 2>/dev/null | jq -r --arg a "$2" '
      (.applications[$a].units // {}) as $u
      | [($u|length), ([$u[] | select(."workload-status".current=="active" and ."juju-status".current=="idle")]|length)] | @tsv')
    [ "${total:-}" = "$3" ] && [ "${ok:-}" = "$3" ] && break
    sleep 10; t=$((t+10))
    [ $t -ge "$WAIT_SECS" ] && { echo "timed out after ${t}s"; return 0; }
  done
  printf '\033[2m(ready after %ss)\033[0m\n' "$t"
}
wait_active() { wait_units "$1" "$2" 1; }  # <model> <app>

s0() {
  hr "0. Preflight: tools and clouds"
  run snap list juju lxd k8s jhack
  run lxc version
  run kubectl get nodes -o wide
  run juju clouds --client
  printf '\033[1;36m$ juju show-cloud %s --client   (CA certificate trimmed)\033[0m\n' "$K8S_CLOUD"
  juju show-cloud "$K8S_CLOUD" --client | sed '/ca-credentials/,$d'
  run cat /proc/sys/net/ipv4/ip_forward
  run free -h
  juju show-cloud "$K8S_CLOUD" --client >/dev/null 2>&1 ||
    die "No '$K8S_CLOUD' cloud on the client. Add it with: sudo k8s config | juju add-k8s $K8S_CLOUD --client"
}

s1() {
  hr "1. Bootstrap one controller per substrate"
  if juju show-controller "$LXD_CTRL" >/dev/null 2>&1; then echo "$LXD_CTRL exists, skipping"; else
    run juju bootstrap localhost "$LXD_CTRL"; fi
  if juju show-controller "$K8S_CTRL" >/dev/null 2>&1; then echo "$K8S_CTRL exists, skipping"; else
    run juju bootstrap "$K8S_CLOUD" "$K8S_CTRL"; fi
  run juju controllers
  run juju models -c "$LXD_CTRL"
  run juju models -c "$K8S_CTRL"
  hr "What each controller is made of"
  run lxc list -c ns4 juju-
  run kubectl get pods,svc -n "controller-$K8S_CTRL"
}

s2() {
  hr "2. Kubernetes model: postgresql-k8s + data-integrator"
  run juju add-model "$POD_MODEL" -c "$K8S_CTRL"
  run juju deploy postgresql-k8s -m "$POD" --channel "$PG_CHANNEL" --trust
  run juju deploy data-integrator -m "$POD" --config database-name=tour
  run juju integrate -m "$POD" data-integrator postgresql-k8s
  wait_active "$POD" postgresql-k8s
  wait_active "$POD" data-integrator
  run juju status -m "$POD" --relations
  hr "Ask the database for credentials, through the charm"
  run juju run -m "$POD" data-integrator/leader get-credentials
  hr "Scale up: one more PostgreSQL unit = one more pod in the StatefulSet"
  run kubectl get statefulset,pods -n "$POD_MODEL"
  run juju scale-application -m "$POD" postgresql-k8s 2
  sleep 20
  hr "Twenty seconds later, mid-scale"
  run kubectl get statefulset,pods -n "$POD_MODEL"
  run juju status -m "$POD" postgresql-k8s
  wait_units "$POD" postgresql-k8s 2
  hr "Both units settled"
  run kubectl get statefulset,pods -n "$POD_MODEL"
  run juju status -m "$POD" postgresql-k8s
  hr "Scale back down to save RAM on a laptop"
  run juju scale-application -m "$POD" postgresql-k8s 1
  wait_units "$POD" postgresql-k8s 1
  run kubectl get pods -n "$POD_MODEL"
  run juju status -m "$POD" postgresql-k8s
}

s3() {
  hr "3. Machine model: the same pattern on LXD"
  run juju add-model "$VM_MODEL" -c "$LXD_CTRL"
  run juju deploy postgresql -m "$VM" --channel "$PG_CHANNEL" --base ubuntu@24.04
  run juju deploy data-integrator -m "$VM" --config database-name=tour
  run juju integrate -m "$VM" data-integrator postgresql
  wait_active "$VM" postgresql
  wait_active "$VM" data-integrator
  run juju status -m "$VM" --relations
  run juju run -m "$VM" data-integrator/leader get-credentials
  hr "Compare the two status outputs"
  run juju status -m "$POD"
  run juju status -m "$VM"
  run juju machines -m "$VM"
  run lxc list -c ns4 juju-
}

s4() {
  hr "4. Cross-model: offer the machine database, consume it from Kubernetes"
  run juju offer -c "$LXD_CTRL" "$VM_MODEL.postgresql:database" pg
  run juju offers -m "$VM"
  run juju find-offers "$LXD_CTRL:"
  run juju consume -m "$POD" "$LXD_CTRL:admin/$VM_MODEL.pg"
  run juju deploy data-integrator remote-di -m "$POD" --config database-name=crossdb
  run juju integrate -m "$POD" remote-di pg
  wait_active "$POD" remote-di
  run juju status -m "$POD" --relations
  run juju offers -m "$VM" --format yaml
  hr "Credentials for a database living in an LXD container, handed to a pod"
  local out; out=$(juju run -m "$POD" remote-di/leader get-credentials --format yaml 2>&1)
  printf '\033[1;36m$ juju run -m %s remote-di/leader get-credentials\033[0m\n' "$POD"; echo "$out"
  local host user pass
  host=$(sed -n 's/^ *endpoints: *\(.*\):5432.*/\1/p' <<<"$out" | head -1)
  user=$(sed -n 's/^ *username: *\(.*\)/\1/p' <<<"$out" | head -1)
  pass=$(sed -n 's/^ *password: *\(.*\)/\1/p' <<<"$out" | head -1)
  hr "Prove it: connect from a throwaway pod in the Kubernetes model"
  printf '\033[1;36m$ kubectl run pgcheck -n %s --image=postgres:16-alpine ... psql -h %s -U %s -d crossdb\033[0m\n' "$POD_MODEL" "$host" "$user"
  kubectl run pgcheck -n "$POD_MODEL" --rm -i --restart=Never --quiet --pod-running-timeout=5m --image=postgres:16-alpine \
    --env "PGPASSWORD=$pass" -- \
    psql -h "$host" -U "$user" -d crossdb -c \
    "select session_user, current_user, inet_server_addr() as server, inet_client_addr() as seen_client;"
  hr "Why the database accepted a client it has never seen: the charm-managed pg_hba.conf"
  run juju exec -m "$VM" --unit postgresql/0 -- \
    'grep -E "^host" /var/snap/charmed-postgresql/common/var/lib/postgresql/16/main/pg_hba.conf'
}

s5() {
  hr "5. Secrets and config"
  run juju add-secret -m "$POD" tour-api-key token=first-value --info "MP1 demo secret"
  run juju secrets -m "$POD"
  run juju grant-secret -m "$POD" tour-api-key data-integrator
  run juju show-secret -m "$POD" tour-api-key
  run juju show-secret -m "$POD" tour-api-key --reveal
  run juju update-secret -m "$POD" tour-api-key token=rotated-value
  run juju show-secret -m "$POD" tour-api-key --revisions
  hr "Secrets the charms created themselves (owned by applications, not by you)"
  run juju secrets -m "$POD" --format yaml
  hr "Charm config"
  run juju config -m "$POD" data-integrator database-name
  run juju config -m "$POD" postgresql-k8s profile
  run juju config -m "$POD" postgresql-k8s logging-log-connections=true
  run juju config -m "$POD" postgresql-k8s logging-log-connections
  sleep 5; wait_active "$POD" postgresql-k8s
  run juju config -m "$POD" postgresql-k8s --reset logging-log-connections
}

s6() {
  hr "6. Look inside"
  run juju show-unit -m "$POD" data-integrator/0
  run juju show-status-log -m "$POD" postgresql-k8s/0 -n 15
  run juju debug-log -m "$POD" --include data-integrator --replay --no-tail --limit 15
  hr "jhack: the charm developer's view"
  printf '\033[1;36m$ jhack show-relation -m %s data-integrator:postgresql postgresql-k8s:database --hide-empty\033[0m\n' "$POD"
  COLUMNS=150 jhack show-relation -m "$POD" data-integrator:postgresql postgresql-k8s:database --hide-empty
  hr "jhack tail: every hook this unit has run, replayed from the logs"
  # Live use is 'jhack tail -m <model>' in a spare terminal (Ctrl-C to stop).
  # --replay --no-watch prints the history and exits, so the script never hangs.
  run jhack tail -m "$POD" data-integrator/0 --replay --no-watch --printer raw --length 25
  hr "What Juju created in Kubernetes"
  run kubectl get all -n "$POD_MODEL"
  run kubectl get pod postgresql-k8s-0 -n "$POD_MODEL" -o jsonpath='{range .spec.initContainers[*]}init: {.name}{"\n"}{end}{range .spec.containers[*]}container: {.name}  image: {.image}{"\n"}{end}'
  run kubectl get serviceaccount,role,rolebinding,secret,configmap,pvc -n "$POD_MODEL"
  run kubectl exec -n "$POD_MODEL" postgresql-k8s-0 -c postgresql -- /charm/bin/pebble services
}

s7() {
  hr "7. Export each model as a bundle"
  mkdir -p bundles
  run sh -c "juju export-bundle -m '$POD' > bundles/$POD_MODEL.yaml"
  run sh -c "juju export-bundle -m '$VM' > bundles/$VM_MODEL.yaml"
  run cat "bundles/$POD_MODEL.yaml"
  run cat "bundles/$VM_MODEL.yaml"
}

s8() {
  hr "8. Teardown: consumer first, then the offerer"
  run juju remove-relation -m "$POD" remote-di pg
  run juju remove-saas -m "$POD" pg
  run juju destroy-controller "$K8S_CTRL" --destroy-all-models --destroy-storage --no-prompt
  run juju destroy-controller "$LXD_CTRL" --destroy-all-models --destroy-storage --no-prompt
  run juju controllers
  run lxc list -c ns juju-
  run kubectl get ns
}

case "${1:-}" in
  [0-8]) "s$1" ;;
  list|"") sed -n '/^#   [0-8]/s/^#   //p' "$0" ;;
  *) die "usage: $0 <0-8|list>" ;;
esac
