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
: ${HF_TOKEN:=}

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
   echo "  --help: print this usage information"
   echo ""
   echo "Env: HF_TOKEN (gated models), AIM_MODEL_IMAGE."
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--level")       shift; LEVEL=${1}; reset-last ;;
      "--model-image") shift; AIM_MODEL_IMAGE=${1}; reset-last ;;
      "--namespace")   shift; NAMESPACE=${1}; reset-last ;;
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
   operator_present || send-error "AIM Engine operator not installed; use --level 3 or 4."
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
   kubectl apply -f - <<EOF || send-error "AIMService apply failed."
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
EOF
   cat <<EOF
[deploy] AIMService applied. How to verify level ${LEVEL} succeeded:
  # 1) AIMService + InferenceService report Ready (may take a while on first pull):
  kubectl get aimservice,inferenceservice,pods -n ${NAMESPACE}
  kubectl describe aimservice aim-smoke -n ${NAMESPACE}
  # 2) small inference (find the predictor service, port-forward, then curl):
  isvc=\$(kubectl get inferenceservice -n ${NAMESPACE} -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
  kubectl port-forward -n ${NAMESPACE} svc/\$(basename \$isvc)-predictor 8080:80 &
  curl -sS localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"aim-smoke","messages":[{"role":"user","content":"Hello!"}]}'
  # 3) confirm the GPU is in use inside the serving pod:
  pod=\$(kubectl get pods -n ${NAMESPACE} -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
  kubectl exec -n ${NAMESPACE} \$pod -- rocm-smi
EOF
}

case "${LEVEL}" in
   1) HF_TOKEN="${HF_TOKEN}" exec "${HERE}/aim_base_check.sh" --namespace "${NAMESPACE}" ;;
   2) serve_operator ;;
   3) "${HERE}/aim_engine_setup.sh" || exit $?; serve_operator ;;
   4) "${HERE}/aim_engine_setup.sh" --install-prereqs 1 || exit $?; serve_operator ;;
   *) send-error "invalid level '${LEVEL}'; choose 1, 2, 3, or 4." ;;
esac
