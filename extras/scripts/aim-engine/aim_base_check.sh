#!/bin/bash

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Minimal, operator-less AIM serving check. Deploys the aim-base image as a plain
# Deployment + Service, requests one GPU, and confirms the model answers a single
# request. This is the simplest way to prove a cluster's GPU can serve a model
# BEFORE committing to the full AIM Engine operator stack (aim_engine_setup.sh).
#
# It needs only its own small prerequisites: a reachable cluster and a node that
# advertises amd.com/gpu (from the AMD GPU device plugin or GPU Operator). It uses
# NO CRDs, NO operator, and NO accelerator node labels; the base image detects the
# GPU in-container. Gated models still require HF_TOKEN, injected as a pod env var.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

: ${AIM_BASE_IMAGE:=amdenterpriseai/aim-base:0.11}
: ${AIM_ID:=meta-llama/Llama-3.2-1B-Instruct}
: ${HF_TOKEN:=}
: ${NAMESPACE:=default}
: ${NAME:=aim-base-check}
: ${GPU_COUNT:=1}
: ${MEM_REQUEST:=16Gi}
: ${CPU_REQUEST:=4}
: ${READY_TIMEOUT:=1800}   # seconds; first-run weight download can be slow
KEEP=0

usage()
{
   echo "Usage:"
   echo "  --aim-id [ ORG/MODEL ] model id to serve, default ${AIM_ID}"
   echo "  --namespace [ NS ] namespace to deploy into, default ${NAMESPACE}"
   echo "  --name [ NAME ] deployment/service name, default ${NAME}"
   echo "  --keep [ 0|1 ] 1: leave the Deployment/Service running, default 0 (clean up)"
   echo "  --help: print this usage information"
   echo ""
   echo "Env: HF_TOKEN (gated models), AIM_BASE_IMAGE, AIM_ID, GPU_COUNT, READY_TIMEOUT."
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--aim-id")    shift; AIM_ID=${1}; reset-last ;;
      "--namespace") shift; NAMESPACE=${1}; reset-last ;;
      "--name")      shift; NAME=${1}; reset-last ;;
      "--keep")      shift; KEEP=${1}; reset-last ;;
      "--help")      usage ;;
      *)             last ${1} ;;
   esac
   shift
done

command -v kubectl >/dev/null 2>&1 || send-error "kubectl not found on PATH."
kubectl get nodes >/dev/null 2>&1 || send-error "cannot reach a Kubernetes cluster (check KUBECONFIG)."

# Prerequisite for this simple check: some node advertises amd.com/gpu.
gpu_ok=0
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
   q=$(kubectl get node "${node}" -o jsonpath='{.status.allocatable.amd\.com/gpu}' 2>/dev/null)
   [ -n "${q}" ] && [ "${q}" != "0" ] && { gpu_ok=1; break; }
done
[ "${gpu_ok}" = "1" ] \
   || send-error "no node advertises amd.com/gpu; install the AMD GPU device plugin (or GPU Operator) first."

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

hf_env=""
if [ -n "${HF_TOKEN}" ]; then
   echo "[base-check] configuring HF_TOKEN secret for gated model access"
   kubectl create secret generic "${NAME}-hf" -n "${NAMESPACE}" \
      --from-literal=hf-token="${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
   hf_env=$'\n        - name: HF_TOKEN\n          valueFrom:\n            secretKeyRef:\n              name: '"${NAME}"$'-hf\n              key: hf-token'
fi

cleanup() {
   [ "${KEEP}" = "1" ] && { echo "[base-check] --keep set; leaving ${NAME} running in ${NAMESPACE}"; return; }
   echo "[base-check] cleaning up ${NAME} in ${NAMESPACE}"
   kubectl delete deployment,service "${NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
   [ -n "${HF_TOKEN}" ] && kubectl delete secret "${NAME}-hf" -n "${NAMESPACE}" >/dev/null 2>&1 || true
   [ -n "${pf}" ] && kill "${pf}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[base-check] deploying ${AIM_BASE_IMAGE} (AIM_ID=${AIM_ID}, amd.com/gpu=${GPU_COUNT})"
kubectl apply -n "${NAMESPACE}" -f - <<EOF || send-error "deploy failed."
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  labels: { app: ${NAME} }
spec:
  progressDeadlineSeconds: ${READY_TIMEOUT}
  replicas: 1
  selector:
    matchLabels: { app: ${NAME} }
  template:
    metadata:
      labels: { app: ${NAME} }
    spec:
      containers:
      - name: ${NAME}
        image: "${AIM_BASE_IMAGE}"
        imagePullPolicy: Always
        env:
        - name: AIM_ID
          value: "${AIM_ID}"${hf_env}
        ports:
        - { name: http, containerPort: 8000 }
        resources:
          requests: { memory: "${MEM_REQUEST}", cpu: "${CPU_REQUEST}", amd.com/gpu: "${GPU_COUNT}" }
          limits:   { memory: "${MEM_REQUEST}", cpu: "${CPU_REQUEST}", amd.com/gpu: "${GPU_COUNT}" }
        startupProbe:
          httpGet: { path: /v1/models, port: http }
          periodSeconds: 10
          failureThreshold: $(( READY_TIMEOUT / 10 ))
        readinessProbe:
          httpGet: { path: /v1/models, port: http }
        livenessProbe:
          httpGet: { path: /health, port: http }
        volumeMounts:
        - { name: dshm, mountPath: /dev/shm }
      volumes:
      - name: dshm
        emptyDir: { medium: Memory, sizeLimit: 8Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  labels: { app: ${NAME} }
spec:
  type: ClusterIP
  ports:
  - { name: http, port: 80, targetPort: 8000 }
  selector: { app: ${NAME} }
EOF

echo "[base-check] waiting for the model to become Ready (weight download can take a while)"
if ! kubectl rollout status deployment/"${NAME}" -n "${NAMESPACE}" --timeout="${READY_TIMEOUT}s"; then
   echo "[base-check] pod did not become Ready; recent events and logs:"
   kubectl describe deployment/"${NAME}" -n "${NAMESPACE}" | sed -n '/Events:/,$p'
   kubectl logs -n "${NAMESPACE}" "deploy/${NAME}" --tail=50 2>/dev/null || true
   send-error "the aim-base deployment never became Ready."
fi

kubectl port-forward -n "${NAMESPACE}" "svc/${NAME}" 8000:80 >/dev/null 2>&1 &
pf=$!; sleep 5
resp=$(curl -sS http://localhost:8000/v1/completions \
   -H "Content-Type: application/json" \
   -d '{"model":"'"${AIM_ID}"'","prompt":"San Francisco is a","max_tokens":7,"temperature":0}')

if echo "${resp}" | grep -q '"choices"'; then
   echo "[base-check] PASS: model served a completion."
   echo "${resp}"
   exit 0
else
   echo "[base-check] FAIL: no valid completion. Response: ${resp}"
   exit 1
fi
