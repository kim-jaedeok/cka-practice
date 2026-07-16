Solve this question on: `kubectl config use-context kind-cka`

Namespace `secure-apps` contains:

- Pod `db` (labels `role=db`) serving HTTP on port `80` via Service `db-svc`
- Pod `backend` (labels `role=backend`)
- Pod `other` (labels `role=other`)

Currently every Pod can reach `db`. Lock this down:

1. Create a NetworkPolicy `default-deny-ingress` in namespace `secure-apps`
   that denies all ingress traffic to **all Pods** in the namespace.

2. Create a NetworkPolicy `allow-backend-to-db` in namespace `secure-apps` that
   allows ingress to Pods labeled `role=db` **only** from Pods labeled
   `role=backend` in the same namespace, and **only** on TCP port `80`.

Result: `backend` can reach `db` on port 80, `other` cannot.
