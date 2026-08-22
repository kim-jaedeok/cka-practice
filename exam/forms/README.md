# Mock exam form metadata

`question-catalog.tsv` is the P0 compatibility contract used by
`exam/planner.sh`. It keeps the existing per-question `meta.yaml` files
unchanged while the mock runner moves away from an unconstrained `shuf`.

Columns are pipe-delimited:

1. question id
2. domain
3. setup priority (higher values are set up later)
4. comma-separated mutex keys
5. comma-separated infrastructure capabilities broken by the scenario
6. comma-separated infrastructure capabilities required by the scenario
7. whether the question is eligible for the shared-cluster mock

Two questions are incompatible when they share a mutex key, or when one
breaks a capability required by the other. The planner validates the catalog
against the question directories before emitting a form.

The P0 catalog also treats node drain as incompatible with controller-less
Pods whose survival depends on solve order. This is intentionally
conservative until disruptive tasks receive dedicated cluster cells.

The generated form is reproducible from the seed saved in
`.state/exam/seed`. Display order and setup order are separate: disruptive
setups can run last without making the displayed order predictable.

`ts-05` and `ts-12` are deliberately ineligible in P0. Stopping a worker
kubelet or the scheduler can affect unrelated tasks in the same cluster.
Re-enable them only after the runner supports a dedicated cluster cell for
each disruptive task.
