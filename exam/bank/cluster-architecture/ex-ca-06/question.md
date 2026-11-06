Solve this question on: `cka-use-context ex-ca-06`

The Helm release `board` in namespace `ops-dash` runs the chart
`status-board`. A moment ago someone upgraded it with a wrong image tag, and
the new Pod cannot start.

The directory `~/cka/ex-ca-06` contains the next chart version and the
production values:

```text
~/cka/ex-ca-06
├── status-board-0.2.0/   (chart status-board, version 0.2.0)
└── prod-values.yaml
```

1. With Helm, roll the release `board` back to the last revision that worked.
   Do not uninstall the release.
2. Then upgrade `board` to the chart in `~/cka/ex-ca-06/status-board-0.2.0`,
   using the values file `prod-values.yaml` and the image tag `1.29`
   (value `image.tag`).
3. The result must be:
   - release `board` is `deployed` with chart version `0.2.0`
   - Deployment `board` has `2` Ready replicas running `nginx:1.29`
   - ConfigMap `board-banner` contains the banner text from `prod-values.yaml`

There is no chart repository. Use the local chart directory.
