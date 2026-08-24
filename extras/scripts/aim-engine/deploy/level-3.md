# Level 3: install the operator, then serve

Level 3 installs AIM Engine and then serves, assuming the seven prerequisites
(cert-manager, Gateway API, kgateway, KServe, KEDA, keda-otel-add-on, and the
OpenTelemetry Operator) are present. It suits a cluster where those are curated
separately (for example by a platform team via GitOps) but installing the
operator is our job. It needs cluster-admin, since it creates cluster-scoped
CRDs.

First export the two values every later command reuses: `KUBECONFIG` (substitute
our own path for the placeholder; skip if we are already pointed at the cluster)
and `NAMESPACE`, the project the `AIMService` should land in (see
[Choosing a namespace](README.md#choosing-a-namespace); use `default` where it is
writable). We then confirm the kubeconfig resolves to a real file:

```bash
export KUBECONFIG=/path/to/your/kubeconfig
export NAMESPACE=<your-namespace>
echo "${KUBECONFIG}"; test -s "${KUBECONFIG}" && echo "kubeconfig found" || echo "set KUBECONFIG to a real file"
```

Then run the level:

```bash
./aim_deploy.sh --level 3 --namespace "$NAMESPACE"
# add --replace 1 to reinstall cleanly over an existing release
```

This runs `aim_engine_setup.sh`, which preflights the prerequisites and, if they
pass, Helm-installs the CRDs and operator (it stops and lists any gap; use
[level 4](level-4.md) to install the add-ons too), then applies the same
`AIMService` as level 2.

The serve, verify, inference, example-app, and cleanup steps are identical to
[level 2](level-2.md).
