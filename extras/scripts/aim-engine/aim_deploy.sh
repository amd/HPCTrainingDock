#!/bin/bash

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Incremental AIM deployment into an EXISTING Kubernetes cluster. Pick a level:
# higher levels assume less is already installed and do more, and each level
# preflights its preconditions before acting. This is a thin dispatcher over the
# sibling scripts (aim_base_check.sh, aim_engine_setup.sh, aim_prereqs_setup.sh);
# it holds no install logic of its own beyond applying the AIMService.
#
#   L1 base-image serve : deploy the model as a plain Deployment (no operator).
#                         Assumes present: cluster + amd.com/gpu.
#   L2 operator serve   : deploy an AIMService.
#                         Assumes present: AIM Engine operator + the 7 prereqs.
#   L3 operator install : install AIM Engine, then serve (L2).
#                         Assumes present: the 7 prereqs.
#   L4 prereqs install  : install the 7 add-ons + AIM Engine, then serve (L2).
#                         Assumes present: the AMD GPU Operator (amd.com/gpu).
#
# Level 1 runs an AIM container directly (the microservice); levels 2-4 use AIM
# Engine (the operator). For how the two relate, see the reference stacks
# overview: https://enterprise-ai.docs.amd.com/en/latest/reference-stacks.html
#
# Cluster creation ("from zero") is intentionally out of scope: use
# aim_engine_test.sh for a throwaway kind cluster, or AMD's Cluster Bloom/Forge
# for a real bare-metal install.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

: ${LEVEL:=}
# Ungated model-specific image for the operator levels (2-4), so no token is needed.
: ${AIM_MODEL_IMAGE:=amdenterpriseai/aim-qwen-qwen3-32b:0.13.0}
: ${NAMESPACE:=default}
# Predictor resource floor. AIM Engine merges spec.resources on top of the
# profile's computed resources (service values win). Auto-generated profiles can
# omit memory, leaving KServe's 2Gi default, which OOM-kills weight loading for
# large models. These defaults suit the 32B image above; lower them for smaller
# models or raise them for bigger ones.
: ${AIM_CPU_REQUEST:=8}
: ${AIM_MEM_REQUEST:=64Gi}
: ${AIM_CPU_LIMIT:=16}
: ${AIM_MEM_LIMIT:=128Gi}
# GPU count the resolved profile should use (tensor-parallel size). 1 keeps the
# smoke test on a single GPU, the predictor configuration we verified end to end;
# raise it (2, 4, 8) for multi-GPU profiles. If resolution reports ProfileNotFound
# the model may not ship a profile at this count, so try another value.
: ${AIM_ACCELERATOR_COUNT:=1}
# One-shot auto-nudge that clears an AIM Engine reconcile gap (see below). 0 off.
: ${AIM_AUTO_NUDGE:=1}
: ${HF_TOKEN:=}
BASE_ARGS=()    # forwarded to aim_base_check.sh on level 1 only
SETUP_ARGS=()   # forwarded to aim_engine_setup.sh on levels 3 and 4

usage()
{
   echo "Usage:"
   echo "  --level [ 1|2|3|4 ] deployment level (required):"
   echo "     1: base-image serve (plain Deployment; assumes cluster + amd.com/gpu)"
   echo "     2: operator serve (AIMService; assumes operator + prereqs installed)"
   echo "     3: install AIM Engine, then serve (assumes the 7 prereqs installed)"
   echo "     4: install prereqs + AIM Engine, then serve (assumes GPU Operator)"
   echo "  --model-image [ IMAGE ] AIM model image for levels 2-4, default ${AIM_MODEL_IMAGE}"
   echo "                          (level 1 uses aim_base_check.sh's own ungated default)"
   echo "  --namespace [ NS ] namespace for the AIMService, default ${NAMESPACE}"
   echo "  --keep [ 0|1 ] (level 1 only) leave the Deployment/Service running"
   echo "  --verbose [ 0|1 ] (level 1 only) tail recent pod logs while waiting"
   echo "  --replace [ 0|1 ] (levels 3-4) uninstall an existing AIM Engine release first"
   echo "  --aim-version [ VER ] (levels 3-4) AIM Engine chart version, default latest"
   echo "  --crds-chart [ REF ] (levels 3-4) AIM CRDs chart override"
   echo "  --chart [ REF ] (levels 3-4) AIM Engine chart override"
   echo "  --help: print this usage information"
   echo ""
   echo "Env: HF_TOKEN (gated models), AIM_MODEL_IMAGE, AIM_CPU_REQUEST,"
   echo "  AIM_MEM_REQUEST, AIM_CPU_LIMIT, AIM_MEM_LIMIT (predictor resources),"
   echo "  AIM_ACCELERATOR_COUNT (GPU/tensor-parallel size, default 1),"
   echo "  AIM_AUTO_NUDGE (0 disables the reconcile-stall auto-nudge)."
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }
# State/environment failures: print the reason plainly, no usage block.
fatal() { echo -e "\n[deploy] ERROR: ${@}" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--level")       shift; LEVEL=${1}; reset-last ;;
      "--model-image") shift; AIM_MODEL_IMAGE=${1}; reset-last ;;
      "--namespace")   shift; NAMESPACE=${1}; reset-last ;;
      "--keep")        shift; BASE_ARGS+=(--keep "${1}"); reset-last ;;
      "--verbose")     shift; BASE_ARGS+=(--verbose "${1}"); reset-last ;;
      "--replace")     shift; SETUP_ARGS+=(--replace "${1}"); reset-last ;;
      "--aim-version") shift; SETUP_ARGS+=(--aim-version "${1}"); reset-last ;;
      "--crds-chart")  shift; SETUP_ARGS+=(--crds-chart "${1}"); reset-last ;;
      "--chart")       shift; SETUP_ARGS+=(--chart "${1}"); reset-last ;;
      "--help")        usage ;;
      *)               last ${1} ;;
   esac
   shift
done

[ -n "${LEVEL}" ] || send-error "select a level with --level [1|2|3|4]."
command -v kubectl >/dev/null 2>&1 || send-error "kubectl not found on PATH."
kubectl get nodes >/dev/null 2>&1 || send-error "cannot reach a Kubernetes cluster (check KUBECONFIG)."

operator_present() { kubectl get crd aimservices.aim.eai.amd.com >/dev/null 2>&1; }

# L2 action: wire an optional HF token, apply an AIMService, report how to check it.
serve_operator()
{
   operator_present || fatal "AIM Engine operator not installed in this cluster (CRD aimservices.aim.eai.amd.com missing).
Level 2 assumes the operator and its prerequisites are already present. To install:
  --level 3   install AIM Engine, then serve (assumes the 7 prerequisites)
  --level 4   install the 7 prerequisites + AIM Engine, then serve (assumes the GPU Operator)"
   if [ -n "${HF_TOKEN}" ]; then
      echo "[deploy] configuring Hugging Face token (secret + default AIMRuntimeConfig)"
      kubectl create secret generic hf-token -n "${NAMESPACE}" \
         --from-literal=hf-token="${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f - <<EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMRuntimeConfig
metadata:
  name: default
  namespace: ${NAMESPACE}
spec:
  env:
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-token
        key: hf-token
EOF
   fi
   echo "[deploy] applying AIMService for ${AIM_MODEL_IMAGE}"
   kubectl apply -f - <<EOF || fatal "AIMService apply failed."
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: aim-smoke
  namespace: ${NAMESPACE}
  annotations:
    aim.eai.amd.com/reconciler-pipeline: profile
spec:
  model:
    image: ${AIM_MODEL_IMAGE}
  resources:
    requests:
      cpu: "${AIM_CPU_REQUEST}"
      memory: ${AIM_MEM_REQUEST}
    limits:
      cpu: "${AIM_CPU_LIMIT}"
      memory: ${AIM_MEM_LIMIT}
  profile:
    selector:
      acceleratorCount: ${AIM_ACCELERATOR_COUNT}
      minimumType: any
EOF
   # AIM Engine sometimes fails to re-queue the AIMService when its AIMProfileCache
   # object reaches Ready, leaving it parked in Starting with no InferenceService.
   # A detached one-shot watcher forces a reconcile (annotation bump) once the cache
   # is Ready, so users need not nudge by hand. Disable with AIM_AUTO_NUDGE=0.
   if [ "${AIM_AUTO_NUDGE}" = "1" ]; then
      (
         for _ in $(seq 1 240); do
            sleep 15
            kubectl get inferenceservice -n "${NAMESPACE}" \
               -l aim.eai.amd.com/service.name=aim-smoke -o name 2>/dev/null | grep -q . && exit 0
            kubectl get aimprofilecache -n "${NAMESPACE}" \
               -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
               | grep -q '^True$' \
               && kubectl annotate aimservice aim-smoke -n "${NAMESPACE}" \
                    kick="$(date +%s)" --overwrite >/dev/null 2>&1
         done
      ) >/tmp/aim-nudge.log 2>&1 &
      disown 2>/dev/null || true
      echo "[deploy] auto-nudge watcher running (pid $!): forces one reconcile when the profile cache is Ready. Disable with AIM_AUTO_NUDGE=0."
   fi
   cat <<EOF
[deploy] AIMService applied. How to verify level ${LEVEL} succeeded:
  # 1) check that it is Ready with this command (READY True/False plus the reason;
  #    may take a while on first pull):
  kubectl get aimservice aim-smoke -n ${NAMESPACE} -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason'
  # while it is not Ready yet, this one line says why (latest status message):
  kubectl describe aimservice aim-smoke -n ${NAMESPACE} | grep -iE 'reason:|message:' | tail -n2
  # 2) wait until Ready (the InferenceService exists only after the weight
  #    download finishes and the auto-nudge above clears the reconcile stall; a
  #    bare cluster with no default StorageClass stays Starting forever), then
  #    run a small inference:
  kubectl wait --for=condition=Ready aimservice/aim-smoke -n ${NAMESPACE} --timeout=1800s
  isvc=\$(kubectl get inferenceservice -n ${NAMESPACE} -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
  kubectl port-forward -n ${NAMESPACE} svc/\$(basename \$isvc)-predictor 8080:80 >/tmp/pf.log 2>&1 &
  sleep 3   # let the port-forward come up, else curl gets connection refused
  curl -sS localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"aim-smoke","messages":[{"role":"user","content":"What is ROCm?"}],"max_tokens":200}'
  # 3) confirm the GPU is in use inside the serving pod:
  pod=\$(kubectl get pods -n ${NAMESPACE} -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
  kubectl exec -n ${NAMESPACE} \$pod -- rocm-smi
EOF
}

case "${LEVEL}" in
   1) HF_TOKEN="${HF_TOKEN}" exec "${HERE}/aim_base_check.sh" --namespace "${NAMESPACE}" "${BASE_ARGS[@]}" ;;
   2) serve_operator ;;
   3) "${HERE}/aim_engine_setup.sh" "${SETUP_ARGS[@]}" || exit $?; serve_operator ;;
   4) "${HERE}/aim_engine_setup.sh" --install-prereqs 1 "${SETUP_ARGS[@]}" || exit $?; serve_operator ;;
   *) send-error "invalid level '${LEVEL}'; choose 1, 2, 3, or 4." ;;
esac
