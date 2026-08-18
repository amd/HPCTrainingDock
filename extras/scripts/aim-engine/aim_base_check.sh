#!/bin/bash

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Minimal, operator-less AIM serving check. Runs an AIM container as a plain
# Deployment + Service instead of an AIMService, to prove a cluster's GPU can
# serve a model BEFORE committing to the full AIM Engine operator stack
# (aim_engine_setup.sh). The default is deliberately ungated: the generic base
# image plus a small open model (Qwen2.5-1.5B-Instruct), so no Hugging Face token
# is ever required. Point --image at a model-specific image (dropping --model-id)
# to run the exact container the operator's by-image predictor would run.
#
# Scope: this matches the operator only on the RUNTIME (image, GPU detection,
# weight download, engine start). It does NOT exercise the operator's profile
# RESOLUTION, which keys off node labels (aim-accelerator.<MODEL> AND
# partitioning-scheme.default). A green check here is necessary but not
# sufficient: the label-driven resolution is validated only by the full operator
# flow (aim_engine_test.sh --auto-run 1).
#
# It needs only its own small prerequisites: a reachable cluster and a node that
# advertises amd.com/gpu. It uses NO CRDs, NO operator, and NO accelerator node
# labels; the image detects the GPU in-container. HF_TOKEN is used only if set,
# for the rare case of deliberately choosing a gated model.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Ungated by default: generic base image + a small open model, so no token is needed.
: ${IMAGE:=amdenterpriseai/aim-base:0.11}
# Model id for a base image (AIM_MODEL_ID). Leave empty when --image is a
# model-specific image, since those set AIM_ID themselves.
: ${MODEL_ID:=Qwen/Qwen2.5-1.5B-Instruct}
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
   echo "  --image [ IMAGE ] AIM image to serve, default ${IMAGE}"
   echo "  --model-id [ ORG/MODEL ] only for a bare aim-base image: HF model to serve"
   echo "  --namespace [ NS ] namespace to deploy into, default ${NAMESPACE}"
   echo "  --name [ NAME ] deployment/service name, default ${NAME}"
   echo "  --keep [ 0|1 ] 1: leave the Deployment/Service running, default 0 (clean up)"
   echo "  --help: print this usage information"
   echo ""
   echo "Env: HF_TOKEN (gated models), IMAGE, MODEL_ID, GPU_COUNT, READY_TIMEOUT."
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--image")     shift; IMAGE=${1}; reset-last ;;
      "--model-id")  shift; MODEL_ID=${1}; reset-last ;;
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

env_block=$'\n        env:'
[ -n "${MODEL_ID}" ] && env_block+=$'\n        - name: AIM_MODEL_ID\n          value: "'"${MODEL_ID}"'"'
if [ -n "${HF_TOKEN}" ]; then
   echo "[base-check] configuring HF_TOKEN secret for gated model access"
   kubectl create secret generic "${NAME}-hf" -n "${NAMESPACE}" \
      --from-literal=hf-token="${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
   env_block+=$'\n        - name: HF_TOKEN\n          valueFrom:\n            secretKeyRef:\n              name: '"${NAME}"$'-hf\n              key: hf-token'
fi
[ "${env_block}" = $'\n        env:' ] && env_block=""

cleanup() {
   [ "${KEEP}" = "1" ] && { echo "[base-check] --keep set; leaving ${NAME} running in ${NAMESPACE}"; return; }
   echo "[base-check] cleaning up ${NAME} in ${NAMESPACE}"
   kubectl delete deployment,service "${NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
   [ -n "${HF_TOKEN}" ] && kubectl delete secret "${NAME}-hf" -n "${NAMESPACE}" >/dev/null 2>&1 || true
   [ -n "${pf}" ] && kill "${pf}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[base-check] deploying ${IMAGE} (amd.com/gpu=${GPU_COUNT}${MODEL_ID:+, AIM_MODEL_ID=${MODEL_ID}})"
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
        image: "${IMAGE}"
        imagePullPolicy: Always${env_block}
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
   send-error "the deployment never became Ready."
fi

kubectl port-forward -n "${NAMESPACE}" "svc/${NAME}" 8000:80 >/dev/null 2>&1 &
pf=$!; sleep 5

# The served model name is whatever the image resolved; read it from /v1/models.
served=$(curl -sS http://localhost:8000/v1/models | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)
[ -z "${served}" ] && served="${MODEL_ID}"
echo "[base-check] served model id: ${served:-<unknown>}"

resp=$(curl -sS http://localhost:8000/v1/completions \
   -H "Content-Type: application/json" \
   -d '{"model":"'"${served}"'","prompt":"San Francisco is a","max_tokens":7,"temperature":0}')

if echo "${resp}" | grep -q '"choices"'; then
   echo "[base-check] PASS: model served a completion."
   echo "${resp}"
   exit 0
else
   echo "[base-check] FAIL: no valid completion. Response: ${resp}"
   exit 1
fi
