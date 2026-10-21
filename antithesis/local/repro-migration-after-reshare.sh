#!/usr/bin/env bash
#=============================================================================
# Reproduces the boot brick after a key migration of a reshared key
# (scratchbook/workload-ledger.md, Status, 2026-10-21) on k3s, without faults:
# reshare key K into epoch E2, migrate K (keygen with --existing-keyset-id K
# --copy-compressed-key-to-original, all four cores up), then restart cores.
# The copy rewrites K's CompressedXofKeySet and K's FheKeyInfo in the default
# epoch only; E2's FheKeyInfo keeps the old digest.
#
#   antithesis/local/repro-migration-after-reshare.sh [label]
#
# Steps: first key K; reshare K into E2; restart core 3 (control: the reshare
# alone must not stop a core from booting); decrypt; migrate K; decrypt;
# restart core 4, then core 2; decrypt without them; reshare K from E2 into E3.
#
# Writes antithesis/local/out/<label>/ (label defaults to
# migration-after-reshare): steps.log, each CLI run's output, and each core's
# log. Needs make build and make k3s, like run-local.sh; deletes and redeploys
# the kapp app kms.
#=============================================================================
set -uo pipefail

NS=kms-threshold-staging
POD=kms-core-client-0
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
OUT="${HERE}/out/${1:-migration-after-reshare}"
rm -rf "${OUT}" && mkdir -p "${OUT}"
n=0
CTX="07$(printf '0%.0s' {1..61})1"
E1="08$(printf '0%.0s' {1..61})1"
E2="08$(printf '0%.0s' {1..61})2"
E3="08$(printf '0%.0s' {1..61})3"

log() { echo "[$(date -u +%T)] $*" | tee -a "${OUT}/steps.log"; }
kx() { kubectl exec -n "${NS}" "${POD}" -- "$@"; }

# cli NAME CONFIG ARGS...: one kms-core-client run in /tmp/repro, output in OUT/NN-NAME.log.
cli() {
    local name=$1 cfg=$2
    shift 2
    n=$((n + 1))
    local f
    f="${OUT}/$(printf %02d ${n})-${name}.log"
    log "${name}: kms-core-client -l -f ${cfg} $*"
    kx sh -c "cd /tmp/repro && timeout 900 kms-core-client -l -f ${cfg} $*" >"${f}" 2>&1
    local rc=$?
    log "  -> exit ${rc} $(grep -oE 'Error: .{0,200}' "${f}" | tail -1)"
    return ${rc}
}

request_id() { grep -oE '"request_id": "[0-9a-fA-F]+"' "$1" | tail -1 | grep -oE '[0-9a-fA-F]{64}'; }

# restart C: delete core C's pod and report whether it is Ready again within 5 min.
restart() {
    log "restart kms-core-$1-core-$1"
    kubectl delete pod -n "${NS}" "kms-core-$1-core-$1" --wait=true >/dev/null
    sleep 10
    if kubectl wait -n "${NS}" --for=condition=Ready "pod/kms-core-$1-core-$1" --timeout=5m >/dev/null 2>&1; then
        log "  -> Ready"
    else
        log "  -> not Ready after 5 min, restarts: $(kubectl get pod -n "${NS}" "kms-core-$1-core-$1" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="kms-core")].restartCount}')"
    fi
    kubectl logs -n "${NS}" "kms-core-$1-core-$1" -c kms-core --tail=40 >"${OUT}/restart-core-$1.log" 2>&1
    kubectl logs -n "${NS}" "kms-core-$1-core-$1" -c kms-core --previous --tail=40 >>"${OUT}/restart-core-$1.log" 2>&1
    log "  -> last boot error: $(grep -oE 'Error: .{0,160}' "${OUT}/restart-core-$1.log" | tail -1)"
    sleep 10
}

# decrypt NAME CONFIG [EPOCH]: -a (every response, each checked) only with all four cores.
decrypt() {
    local all=() epoch=()
    [[ "$2" == all.toml ]] && all=(-a)
    [[ -n "${3:-}" ]] && epoch=(--context-id "${CTX}" --epoch-id "$3")
    cli "$1" "$2" --max-iter 120 "${all[@]}" public-decrypt from-args --to-encrypt 0x2a --data-type euint8 \
        --key-id "${KEY}" --batch-size 1 "${epoch[@]}"
}

# reshare NAME SOURCE_EPOCH NEW_EPOCH PREPROC: new-epoch with the workload's --previous-epoch-params.
reshare() {
    local params
    params=$(kx sh -c "cd /opt/antithesis/test/v1/main && python3 -c \"from helper_reshare import \
previous_epoch_params as p; print(p([('${KEY}', '$4')], '$2'))\"" | tail -1) # the SDK prints a line first
    cli "$1" all.toml --max-iter 1200 new-epoch --new-epoch-id "$3" --new-context-id "${CTX}" \
        --previous-epoch-params "'${params}'"
}

log "deploy"
"${ROOT}/config/render.sh" >/dev/null
kapp delete -a kms --yes >/dev/null 2>&1 || true
kapp deploy -a kms -f "${ROOT}/build/config/manifests" --yes >"${OUT}/deploy.log" 2>&1 ||
    { tail -20 "${OUT}/deploy.log"; exit 1; }
kubectl wait -n "${NS}" --for=condition=Ready "pod/${POD}" --timeout=5m >/dev/null
kubectl wait -n "${NS}" --for=condition=complete job/kms-core-init-threshold-init --timeout=10m >/dev/null

log "first key"
kx /opt/antithesis/test/v1/main/first_generate_key.py >"${OUT}/first-key.log" 2>&1 || { log "first key failed"; exit 1; }
KEY=$(kx ls /tmp/kms-workload-state/first-key)
PREPROC0=$(kx cat "/tmp/kms-workload-state/keys/${KEY}")
log "key ${KEY} (preprocessing ${PREPROC0})"

# Client configs: all four cores, and each three-core subset (as helper_common.write_client_config).
kx sh -c 'mkdir -p /tmp/repro && cd /tmp/repro && cp /app/kms-core-client/config.toml all.toml && python3 -c "
import re
text = open(\"all.toml\").read()
head, *blocks = text.split(\"[[cores]]\")
for left in (1, 2, 3, 4):
    kept = [b for b in blocks if not re.search(rf\"(?m)^party_id *= *{left} *$\", b)]
    open(f\"no{left}.toml\", \"w\").write(head + \"num_parties = 4\n\" + \"\".join(\"[[cores]]\" + b for b in kept))
"'

log "== reshare into E2, then a control restart"
reshare reshare-e2 "${E1}" "${E2}" "${PREPROC0}"
decrypt e2-all all.toml "${E2}"
restart 3
decrypt control-all all.toml

log "== migration (all four cores)"
cli preproc all.toml --max-iter 1200 insecure-preproc-key-gen
PREPROC1=$(request_id "${OUT}/$(printf %02d ${n})-preproc.log")
log "preproc ${PREPROC1}"
cli migrate all.toml --max-iter 1200 insecure-key-gen --preproc-id "${PREPROC1}" \
    --existing-keyset-id "${KEY}" --copy-compressed-key-to-original
decrypt after-migrate-all all.toml

log "== restarts after the migration"
restart 4
decrypt after-restart4-no4 no4.toml
restart 2
decrypt after-restart2-no4 no4.toml

log "== reshare from E2 (cores 2 and 4 as they are)"
reshare reshare-e3 "${E2}" "${E3}" "${PREPROC0}"

log "== server logs"
for c in 1 2 3 4; do
    kubectl logs -n "${NS}" "kms-core-${c}-core-${c}" -c kms-core >"${OUT}/core-${c}.log" 2>&1 || true
    log "core ${c}: $(grep -c 'Copied compressed key' "${OUT}/core-${c}.log") copies," \
        "$(grep -c 'digest mismatch' "${OUT}/core-${c}.log") digest-mismatch lines," \
        "restarts $(kubectl get pod -n "${NS}" "kms-core-${c}-core-${c}" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="kms-core")].restartCount}')"
done
kapp delete -a kms --yes >/dev/null 2>&1 || true
log "done: ${OUT}"
