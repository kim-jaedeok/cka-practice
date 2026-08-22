# Generic disposable question cells

Operator, Gateway API, and CSI labs use a standard one-control-plane,
one-worker KIND base. `lib/cell.sh` records the dedicated network and every
container by immutable full ID before a profile installs anything.

The shared `kind-cka` cluster is never a fallback. If creation, ownership
verification, profile setup, or cleanup fails, the question is invalid and the
cell is preserved for explicit inspection.
