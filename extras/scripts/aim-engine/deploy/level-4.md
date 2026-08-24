# Level 4: install prerequisites and the operator, then serve

Level 4 is the turnkey path for a cluster we own: it installs the seven add-ons,
installs AIM Engine, and serves, assuming only that the GPU nodes run the AMD GPU
Operator. It needs cluster-admin, since it creates cluster-scoped resources for
both.

First point `KUBECONFIG` at the cluster's kubeconfig, substituting our own path
for the placeholder (skip if we are already pointed at the cluster), and confirm
it resolves to a real file:

```bash
export KUBECONFIG=/path/to/your/kubeconfig
echo "${KUBECONFIG}"; test -s "${KUBECONFIG}" && echo "kubeconfig found" || echo "set KUBECONFIG to a real file"
```

Then run the level, passing `--namespace` for the project the `AIMService`
should land in (see [Choosing a namespace](README.md#choosing-a-namespace));
where `default` is writable we omit it:

```bash
./aim_deploy.sh --level 4 --namespace <your-namespace>
# serve a specific image (gated images also need HF_TOKEN exported):
./aim_deploy.sh --level 4 --namespace <your-namespace> --model-image amdenterpriseai/aim-qwen-qwen3-32b:0.13.0
```

This runs `aim_engine_setup.sh --install-prereqs 1` (which runs
`aim_prereqs_setup.sh` for the add-ons, then installs the CRDs and operator) and
applies the same `AIMService` as level 2. The serve, verify, inference,
example-app, and cleanup steps are identical to [level 2](level-2.md).

The [test harness](../test/README.md) runs this exact flow on a throwaway `kind`
cluster, so a run there is the closest rehearsal of a real level-4 deploy.
