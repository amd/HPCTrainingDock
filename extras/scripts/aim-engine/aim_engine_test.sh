#!/bin/bash

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# End-to-end correctness harness for the AIM Engine scripts on a throwaway
# `kind` (Kubernetes IN Docker) cluster with REAL AMD GPU passthrough.
#
# The host's /dev/kfd + /dev/dri are bind-mounted into the kind node (same
# idea as `docker run --device`), and the ROCm k8s device plugin advertises
# amd.com/gpu -- so preflight, install, and inference all run for real. A
# GPU host is required; there is no no-GPU mode.
#
# Everything lives in a visible working dir that is removed on exit (when the
# interactive shell or the auto-run flow ends) so nothing is left in ~.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

AUTO_RUN=0
CLUSTER_NAME="aim-engine-test"
WORK_DIR="${HOME}/aim-engine-test"

: ${KIND_VERSION:=v0.27.0}       # ships a k8s 1.32 node image (AIM needs 1.32+)
: ${KUBECTL_VERSION:=v1.32.2}
: ${HELM_VERSION:=v3.16.2}
: ${AMDGPU_DP_URL:=https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml}
# Model image for the inference smoke test (this default is gated -> needs HF_TOKEN).
: ${AIM_TEST_MODEL_IMAGE:=amdenterpriseai/aim-meta-llama-llama-3-2-1b-instruct:0.11.1}
# AIM accelerator model used to label the kind node so profile resolution matches
# (the bare device plugin doesn't set the label a real AMD GPU Operator would).
# Auto-detected from rocminfo if empty; override with --gpu-model.
: ${AIM_GPU_MODEL:=}
# Hugging Face token for gated models (Llama/Gemma). If set, the harness creates
# the secret + a default AIMRuntimeConfig that injects HF_TOKEN into the pods.
: ${HF_TOKEN:=}

usage()
{
   echo "Usage:"
   echo "  --auto-run [ 0|1 ] 0: bring up kind+GPU and print manual commands (default);"
   echo "                     1: run preflight/install/idempotency + inference, then clean up"
   echo "  --cluster-name [ NAME ] kind cluster name, default $CLUSTER_NAME"
   echo "  --gpu-model [ MODEL ] AIM accelerator model to label the node with"
   echo "                        (e.g. MI355X, MI300X); auto-detected via rocminfo if unset"
   echo "  --help: print this usage information"
   echo ""
   echo "Env: HF_TOKEN (gated models), AIM_TEST_MODEL_IMAGE, AIM_GPU_MODEL."
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--auto-run")     shift; AUTO_RUN=${1}; reset-last ;;
      "--cluster-name") shift; CLUSTER_NAME=${1}; reset-last ;;
      "--gpu-model")    shift; AIM_GPU_MODEL=${1}; reset-last ;;
      "--help")         usage ;;
      *)                last ${1} ;;
   esac
   shift
done

command -v docker >/dev/null 2>&1 || send-error "docker not found; kind needs a container runtime."
[ -e /dev/kfd ] && [ -d /dev/dri ] || send-error "no AMD GPU on this host (/dev/kfd or /dev/dri missing)."
case "$(uname -m)" in
   x86_64|amd64) ARCH=amd64 ;;
   aarch64|arm64) ARCH=arm64 ;;
   *) send-error "unsupported architecture $(uname -m)." ;;
esac

BIN_DIR="${WORK_DIR}/bin"
mkdir -p "${BIN_DIR}"
export PATH="${BIN_DIR}:${PATH}"
export KUBECONFIG="${WORK_DIR}/kubeconfig"

fetch() { echo "[test] downloading ${1}"; curl -fsSL "${1}" -o "${2}" || send-error "download failed: ${1}"; }

if ! command -v kind >/dev/null 2>&1; then
   fetch "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" "${BIN_DIR}/kind"; chmod +x "${BIN_DIR}/kind"
fi
if ! command -v kubectl >/dev/null 2>&1; then
   fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" "${BIN_DIR}/kubectl"; chmod +x "${BIN_DIR}/kubectl"
fi
if ! command -v helm >/dev/null 2>&1; then
   fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "${BIN_DIR}/helm.tgz"
   tar -xzf "${BIN_DIR}/helm.tgz" -C "${BIN_DIR}" --strip-components=1 "linux-${ARCH}/helm"
   chmod +x "${BIN_DIR}/helm"; rm -f "${BIN_DIR}/helm.tgz"
fi

# kind node runs privileged, so bind-mounting the device nodes is enough.
# Also mount the aim-engine scripts and the kubectl/helm binaries (read-only)
# so they can be run from inside the node container as a throwaway sandbox.
cat > "${WORK_DIR}/kind-gpu.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /dev/kfd
    containerPath: /dev/kfd
  - hostPath: /dev/dri
    containerPath: /dev/dri
  - hostPath: ${HERE}
    containerPath: /aim-engine
    readOnly: true
  - hostPath: ${BIN_DIR}
    containerPath: /aim-bin
    readOnly: true
EOF

teardown() {
   echo "[test] cleaning up (kind cluster + ${WORK_DIR})"
   kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
   rm -rf "${WORK_DIR}"
}

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
   echo "[test] reusing existing kind cluster ${CLUSTER_NAME}"
   kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}" \
      || send-error "could not export kubeconfig for existing cluster ${CLUSTER_NAME}."
else
   echo "[test] creating kind cluster ${CLUSTER_NAME} (GPU passthrough)"
   kind create cluster --name "${CLUSTER_NAME}" --config "${WORK_DIR}/kind-gpu.yaml" \
      --kubeconfig "${KUBECONFIG}" || send-error "kind create cluster failed."
fi
# From here on any failure/exit tears the cluster (and work dir) down.
trap teardown EXIT

echo "[test] deploying the ROCm k8s device plugin"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "${WORK_DIR}/amd-gpu-dp.yaml" "${AMDGPU_DP_URL}" \
   || send-error "could not download the device plugin manifest from ${AMDGPU_DP_URL}"
kubectl apply -f "${WORK_DIR}/amd-gpu-dp.yaml" || send-error "device plugin apply failed."

echo "[test] waiting for a Kubernetes node to advertise amd.com/gpu"
for i in $(seq 1 30); do
   n=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.amd\.com/gpu}' 2>/dev/null)
   [ -n "${n}" ] && [ "${n}" != "0" ] && break
   sleep 5
done
[ -n "${n}" ] && [ "${n}" != "0" ] \
   || send-error "no amd.com/gpu became allocatable; check the device plugin pod and host GPU."
echo "[test] amd.com/gpu allocatable = ${n}"

# Label the node with the GPU model so AIM profile resolution matches. A real
# cluster gets this from the AMD GPU Operator's AcceleratorDetector; the bare
# device plugin used here does not, so we inject the equivalent label.
if [ -z "${AIM_GPU_MODEL}" ] && command -v rocminfo >/dev/null 2>&1; then
   AIM_GPU_MODEL=$(rocminfo 2>/dev/null | grep -m1 -oiE 'MI[0-9]{3}[A-Z]*' | tr 'a-z' 'A-Z')
fi
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
if [ -n "${AIM_GPU_MODEL}" ]; then
   echo "[test] labeling node ${NODE} as accelerator ${AIM_GPU_MODEL}"
   kubectl label node "${NODE}" "feature.node.kubernetes.io/aim-accelerator.${AIM_GPU_MODEL}=true" --overwrite
else
   echo "[test] WARNING GPU model unknown (pass --gpu-model); AIM profile matching will fail for inference."
fi

# Optional Hugging Face token for gated models: secret + default AIMRuntimeConfig.
if [ -n "${HF_TOKEN}" ]; then
   echo "[test] configuring Hugging Face token (secret + default AIMRuntimeConfig)"
   kubectl create secret generic hf-token -n default \
      --from-literal=hf-token="${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
   kubectl apply -f - <<EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMRuntimeConfig
metadata:
  name: default
  namespace: default
spec:
  env:
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-token
        key: hf-token
EOF
fi

if [ "${AUTO_RUN}" != "1" ]; then
   cat <<EOF

[test] kind cluster '${CLUSTER_NAME}' is UP with amd.com/gpu=${n}.
[test] Dropping you INTO the Kubernetes node container -- a throwaway sandbox.
[test]   scripts:    /aim-engine  (read-only)
[test]   kubectl/helm: /aim-bin   (on PATH)
[test]   KUBECONFIG:  /etc/kubernetes/admin.conf (this cluster)
[test] Node labeled accelerator: ${AIM_GPU_MODEL:-<none: pass --gpu-model>}
[test] HF token: ${HF_TOKEN:+configured}${HF_TOKEN:-not set (gated models will not download; export HF_TOKEN)}
[test] Mess it up freely; 'exit' tears the whole cluster down and the host is untouched.

  # 1) expect a preflight failure listing missing add-ons (exit 42):
  ./aim_engine_setup.sh

  # 2) install the add-ons, then AIM Engine (expect success):
  ./aim_engine_setup.sh --install-prereqs 1

  # 3) deploy a model and watch it serve:
  kubectl apply -f - <<'YAML'
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: aim-smoke
  namespace: default
  annotations:
    aim.eai.amd.com/reconciler-pipeline: profile
spec:
  model:
    image: ${AIM_TEST_MODEL_IMAGE}
YAML
  kubectl get aimservice,inferenceservice,pods -n default

EOF
   docker exec -it \
      -e PATH="/aim-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      -e KUBECONFIG=/etc/kubernetes/admin.conf \
      -w /aim-engine \
      "${CLUSTER_NAME}-control-plane" bash --norc -i
   exit 0
fi

# ------ auto-run: full flow with assertions, always cleaned up on exit ---------------
FAILED=0

echo ""; echo "[test] STEP 1: preflight with no prereqs (expect exit 42)"
"${HERE}/aim_engine_setup.sh"; rc=$?
if [ "${rc}" -eq 42 ]; then echo "[test] PASS: missing prerequisites reported."
else echo "[test] FAIL: expected exit 42, got ${rc}."; FAILED=1; fi

echo ""; echo "[test] STEP 2: install prereqs + AIM Engine (expect success)"
if "${HERE}/aim_engine_setup.sh" --install-prereqs 1; then echo "[test] PASS: installed."
else echo "[test] FAIL: install did not succeed."; FAILED=1; fi

echo ""; echo "[test] STEP 3: idempotency (re-run, expect success)"
if "${HERE}/aim_engine_setup.sh"; then echo "[test] PASS: idempotent."
else echo "[test] FAIL: second run did not succeed."; FAILED=1; fi

echo ""; echo "[test] STEP 4: inference smoke test (${AIM_TEST_MODEL_IMAGE})"
kubectl apply -f - <<EOF
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: aim-smoke
  namespace: default
  annotations:
    aim.eai.amd.com/reconciler-pipeline: profile
spec:
  model:
    image: ${AIM_TEST_MODEL_IMAGE}
EOF
echo "[test] waiting for the InferenceService to become Ready (model download can take a while)"
isvc=""
for i in $(seq 1 120); do
   isvc=$(kubectl get inferenceservice -n default -l aim.eai.amd.com/service.name=aim-smoke -o name 2>/dev/null | head -n1)
   [ -n "${isvc}" ] && kubectl wait --for=condition=Ready "${isvc}" -n default --timeout=10s >/dev/null 2>&1 && break
   sleep 10
done
if [ -n "${isvc}" ] && kubectl get "${isvc}" -n default >/dev/null 2>&1; then
   kubectl port-forward -n default "svc/$(basename ${isvc})-predictor" 8080:80 >/dev/null 2>&1 &
   pf=$!; sleep 5
   resp=$(curl -sS http://localhost:8080/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"aim-smoke","messages":[{"role":"user","content":"Hello!"}]}')
   kill ${pf} >/dev/null 2>&1 || true
   if echo "${resp}" | grep -q '"choices"'; then echo "[test] PASS: inference returned a completion."
   else echo "[test] FAIL: no valid completion. Response: ${resp}"; FAILED=1; fi
else
   echo "[test] FAIL: InferenceService for aim-smoke never became Ready."; FAILED=1
fi

echo ""
if [ "${FAILED}" -eq 0 ]; then echo "[test] RESULT: all AIM Engine harness checks passed."; exit 0
else echo "[test] RESULT: one or more AIM Engine harness checks FAILED."; exit 1; fi
