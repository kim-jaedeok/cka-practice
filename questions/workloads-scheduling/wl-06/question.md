Solve this question on: `kubectl config use-context kind-cka`

In namespace `dept-z` configure an application with its configuration data:

1. Create a ConfigMap `app-config` with the data:
   - `DB_HOST=db.example.com`
   - `LOG_LEVEL=warn`

2. Create a Secret `app-secret` (type Opaque) with the data:
   - `DB_PASS=S3cretPass!`

3. Create a PriorityClass `high-priority` with value `100000`
   (not a global default).

4. Create a Deployment `config-app` in namespace `dept-z`:
   - 1 replica, container name `app`, image `busybox:1.36`,
     command `sleep infinity`
   - All keys of ConfigMap `app-config` must be exposed as environment
     variables (use `envFrom`)
   - The Secret key `DB_PASS` must be exposed as the environment variable
     `DB_PASS`
   - The Pod must use the PriorityClass `high-priority`
