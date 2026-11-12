# template-examples

Example Coder workspace templates. Each template lives in its own directory
with its own README (e.g. [`openshift-gpu-mig`](openshift-gpu-mig)) and is
pushed independently.

## Pushing a template to a Coder instance

```bash
brew install go-task coder shellcheck
cp .env.example .env   # fill in CODER_URL / CODER_SESSION_TOKEN
task up TEMPLATE=openshift-gpu-mig   # validate, then push
```

Tasks are thin wrappers around `scripts/*.sh`.

| Task | Description |
|---|---|
| `task up TEMPLATE=<dir>` | Validate, then push |
| `task push TEMPLATE=<dir> [VARS_FILE=path]` | Push/update one template |
| `task validate [TEMPLATE=<dir>]` | `terraform fmt`/`validate` for all templates (or just one), plus `shellcheck` on `scripts/` |
