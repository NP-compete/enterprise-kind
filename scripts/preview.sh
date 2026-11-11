#!/usr/bin/env bash
# Branch previews of the template-agent + template-ui stack.
#
# Each preview is a git worktree of both repos, built into its own image tag
# and deployed into its own namespace, sharing ONE data plane with the
# template-agent namespace. Postgres, redis and the sandbox runtime images
# are the expensive parts and they do not vary per branch; the agent and UI
# are the parts you are changing, so they are the only parts duplicated.
#
# Usage: preview.sh <add|build|deploy|up|list|rm|hosts> [name] [args]
#
#   add <name> [agent-ref] [ui-ref]   create the worktrees (refs default to <name>)
#   up <name>                         build + deploy
#   rm <name>                         delete the namespace and the worktrees
#
# Shared with template-agent: postgres, redis, the sandbox runtime images,
# the Keycloak client, the platform CA. Branches that change the database
# schema WILL collide -- give those a full stack instead.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREVIEW_DIR="${BUILD_DIR}/preview"
WORKTREE_DIR="${PREVIEW_WORKTREES}"
SRC_CLONES="${BUILD_DIR}/template-src"
DATA_NS=template-agent
REPOS=(template-agent template-ui)

_ns()   { echo "ta-${1}"; }
_tag()  { echo "preview-${1}"; }
# Only directories holding BOTH worktrees count. ${WORKTREE_DIR} is a normal
# directory in the user's home, not private to this repo -- whatever else
# lives there must not turn into a preview with a namespace and a DNS name.
_names() {
  [[ -d "${WORKTREE_DIR}" ]] || return 0
  local d
  for d in "${WORKTREE_DIR}"/*/; do
    [[ -e "${d}template-agent/.git" && -e "${d}template-ui/.git" ]] || continue
    basename "${d}"
  done
}

_require_name() {
  [[ -n "${1:-}" ]] || die "usage: preview.sh ${2} <name>"
  [[ "${1}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || die "'${1}' is not a usable name: lowercase letters, digits and dashes"
  # The namespace, two hostnames and an image tag are all derived from this.
  (( ${#1} <= 20 )) || die "'${1}' is too long; keep preview names under 20 characters"
}

# --- worktrees --------------------------------------------------------------

cmd_add() { # add <name> [agent-ref] [ui-ref]
  local name="${1:-}"; _require_name "${name}" add
  local agent_ref="${2:-${name}}" ui_ref="${3:-${2:-${name}}}"
  need git

  local i=0 ref
  for repo in "${REPOS[@]}"; do
    ref="$([[ ${i} -eq 0 ]] && echo "${agent_ref}" || echo "${ui_ref}")"; i=1
    local clone="${SRC_CLONES}/${repo}" wt="${WORKTREE_DIR}/${name}/${repo}"

    # `make agent-stack` leaves full clones here; reuse them so a preview
    # does not re-download two repos. A shallow one cannot serve worktrees
    # of arbitrary branches, so unshallow if that is what we inherited.
    if [[ ! -d "${clone}/.git" ]]; then
      step "cloning ${repo}"
      mkdir -p "${SRC_CLONES}"
      git clone -q "https://github.com/redhat-data-and-ai/${repo}.git" "${clone}" \
        || die "could not clone ${repo}"
    elif [[ -f "${clone}/.git/shallow" ]]; then
      step "unshallowing ${repo}"
      git -C "${clone}" fetch -q --unshallow 2>/dev/null || true
    fi
    git -C "${clone}" fetch -q origin || warn "could not fetch ${repo}; using what is on disk"

    [[ -d "${wt}" ]] && { ok "${repo} worktree for ${name} already exists"; continue; }
    mkdir -p "${WORKTREE_DIR}/${name}"
    step "worktree ${repo}@${ref} -> ${wt}"
    if git -C "${clone}" rev-parse --verify -q "refs/remotes/origin/${ref}" >/dev/null; then
      # A branch can only be checked out in one worktree, and the clone
      # itself holds the default branch -- so a preview tracking it gets a
      # detached HEAD rather than failing. Commit from here and you are
      # making an anonymous branch, which is the honest thing for a preview
      # of someone else's main.
      if git -C "${clone}" worktree list --porcelain | grep -qx "branch refs/heads/${ref}" \
         || [[ "$(git -C "${clone}" symbolic-ref -q --short HEAD)" == "${ref}" ]]; then
        warn "${repo}: '${ref}' is checked out already; using a detached worktree"
        git -C "${clone}" worktree add -q --detach "${wt}" "origin/${ref}" \
          || die "could not create the ${repo} worktree at ${ref}"
      else
        git -C "${clone}" worktree add -q -B "${ref}" "${wt}" "origin/${ref}" \
          || die "could not create the ${repo} worktree at ${ref}"
      fi
    elif git -C "${clone}" rev-parse --verify -q "${ref}" >/dev/null; then
      git -C "${clone}" worktree add -q --detach "${wt}" "${ref}" \
        || die "could not create the ${repo} worktree at ${ref}"
    else
      # A branch that does not exist yet is the normal case for new work.
      local base; base="$(git -C "${clone}" symbolic-ref -q --short refs/remotes/origin/HEAD \
        || echo origin/main)"
      warn "${repo} has no ref '${ref}'; branching it from ${base}"
      git -C "${clone}" worktree add -q -b "${ref}" "${wt}" "${base}" \
        || die "could not create the ${repo} worktree"
    fi
  done
  ok "preview '${name}' added -- edit ${WORKTREE_DIR}/${name}/, then: make preview-up NAME=${name}"
}

# --- build ------------------------------------------------------------------

cmd_build() { # build <name>
  local name="${1:-}"; _require_name "${name}" build
  local wt="${WORKTREE_DIR}/${name}"
  [[ -d "${wt}" ]] || die "no preview '${name}' -- run: make preview-add NAME=${name}"
  need rsync

  # Built from a copy, not the worktree itself: the build rewrites PROMPT.md
  # in place, and a build that dirties your checkout is a build that loses
  # your work to the next `git checkout`.
  local src="${PREVIEW_DIR}/${name}/src"
  step "staging ${name} sources"
  mkdir -p "${src}"
  for repo in "${REPOS[@]}"; do
    rsync -a --delete --exclude .git "${wt}/${repo}/" "${src}/${repo}/" \
      || die "could not stage ${repo}"
  done

  local tag; tag="$(_tag "${name}")"
  need "${CE}"

  step "building template-ui from ${name}"
  "${CE}" build -q -t "localhost/template-ui:${tag}" \
    -f "${src}/template-ui/Containerfile" "${src}/template-ui" >/dev/null \
    || die "template-ui build failed for '${name}'"

  # The model is declared in PROMPT.md front matter, which is baked into the
  # image, so it cannot be a deploy-time env var. It is deployment config
  # rather than branch content, so it is set here instead of committed --
  # which also keeps the three branches diffable against upstream.
  local prompt_md="${src}/template-agent/config/agent/PROMPT.md"
  if [[ -f "${prompt_md}" ]]; then
    step "setting the agent model to ${AGENT_MODEL}"
    sed -i.bak -E "s|^model: .*|model: ${AGENT_MODEL}|" "${prompt_md}"
    rm -f "${prompt_md}.bak"
    grep -q "^model: ${AGENT_MODEL}$" "${prompt_md}" \
      || die "could not set the model in ${name}'s PROMPT.md"
  else
    warn "${name} has no config/agent/PROMPT.md; the agent will not start"
  fi

  # From the branch's OWN Containerfile, not by layering onto the published
  # image the way `make agent-stack` does. A preview that cannot show a
  # change to deep_agent/ is not a preview of the branch; the cost is a full
  # uv install on the first build of each branch.
  step "building template-agent from ${name} source"
  "${CE}" build -q -t "localhost/template-agent-src:${tag}" \
    -f "${src}/template-agent/Containerfile" "${src}/template-agent" >/dev/null \
    || die "template-agent build failed for '${name}'"

  step "baking ${name}'s agent config"
  "${CE}" build -q -t "localhost/template-agent:${tag}" \
    --build-arg "PREVIEW_BASE_IMAGE=localhost/template-agent-src:${tag}" \
    -f "${ROOT_DIR}/apps/template-agent/patch/Containerfile.preview" \
    "${src}/template-agent" >/dev/null \
    || die "config layer failed for '${name}'"

  step "loading ${name} images into ${CLUSTER_NAME}"
  load_image "localhost/template-agent:${tag}"
  load_image "localhost/template-ui:${tag}"
  ok "preview '${name}' images built and loaded"
}

# --- overlay ----------------------------------------------------------------

_write_overlay() { # _write_overlay <name> <redis-db>
  local name="$1" db="$2" ns tag ui_host agent_host pgdb
  ns="$(_ns "${name}")"; tag="$(_tag "${name}")"; pgdb="$(_db_name "${name}")"
  ui_host="agent-ui-${name}.${BASE_DOMAIN}"
  agent_host="agent-${name}.${BASE_DOMAIN}"
  mkdir -p "${PREVIEW_DIR}/${name}"

  cat > "${PREVIEW_DIR}/${name}/kustomization.yaml" <<EOF
# Generated by scripts/preview.sh -- do not edit; re-run 'make preview-up'.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${ns}

resources:
  - ../../../apps/template-agent

images:
  - name: localhost/template-agent
    newTag: ${tag}
  - name: localhost/template-ui
    newTag: ${tag}

patches:
  # --- the shared data plane stays in ${DATA_NS} ---------------------------
  # Dropped here and pointed at by name below. Three copies of postgres is
  # 1.5Gi spent on three identical empty databases.
  - target: { kind: Deployment, name: pgvector }
    patch: |
      \$patch: delete
      apiVersion: apps/v1
      kind: Deployment
      metadata: { name: pgvector }
  - target: { kind: Deployment, name: redis }
    patch: |
      \$patch: delete
      apiVersion: apps/v1
      kind: Deployment
      metadata: { name: redis }
  - target: { kind: Service, name: postgres }
    patch: |
      \$patch: delete
      apiVersion: v1
      kind: Service
      metadata: { name: postgres }
  - target: { kind: Service, name: redis }
    patch: |
      \$patch: delete
      apiVersion: v1
      kind: Service
      metadata: { name: redis }
  - target: { kind: PersistentVolumeClaim, name: postgres-pvc }
    patch: |
      \$patch: delete
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata: { name: postgres-pvc }
  - target: { kind: PersistentVolumeClaim, name: redis-pvc }
    patch: |
      \$patch: delete
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata: { name: redis-pvc }
  - target: { kind: ConfigMap, name: postgres-init }
    patch: |
      \$patch: delete
      apiVersion: v1
      kind: ConfigMap
      metadata: { name: postgres-init }

  # --- sealed secrets are sealed TO a namespace ----------------------------
  # The ciphertext in apps/template-agent only decrypts in ${DATA_NS}; the
  # controller would reject it here. preview.sh creates the same Secret
  # imperatively from .secrets/ before applying this.
  - target: { kind: SealedSecret, name: ui-secrets }
    patch: |
      \$patch: delete
      apiVersion: bitnami.com/v1alpha1
      kind: SealedSecret
      metadata: { name: ui-secrets }
  - target: { kind: SealedSecret, name: agent-google-creds }
    patch: |
      \$patch: delete
      apiVersion: bitnami.com/v1alpha1
      kind: SealedSecret
      metadata: { name: agent-google-creds }

  # --- point at the shared data plane --------------------------------------
  # One postgres instance and one redis, but neither is shared at the
  # database level: each preview gets its own postgres database and its own
  # redis database index. The instances are what cost memory; a database
  # costs nothing and keeps a branch's schema and keys to itself.
  - target: { kind: ConfigMap, name: agent-config }
    patch: |
      apiVersion: v1
      kind: ConfigMap
      metadata: { name: agent-config }
      data:
        POSTGRES_HOST: postgres.${DATA_NS}.svc.cluster.local
        POSTGRES_DB: ${pgdb}
        REDIS_HOST: redis.${DATA_NS}.svc.cluster.local
        REDIS_PORT: "6379"
        REDIS_URL: redis://redis.${DATA_NS}.svc.cluster.local:6379/${db}

  # --- hostnames -----------------------------------------------------------
  - target: { kind: Ingress, name: template-agent-ingress }
    patch: |
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: template-agent-ingress
        annotations:
          cert-manager.io/cluster-issuer: platform-ca
      spec:
        ingressClassName: nginx
        tls:
          - secretName: template-agent-tls
            hosts: [${ui_host}, ${agent_host}]
        rules:
          - host: ${ui_host}
            http:
              paths:
                - path: /
                  pathType: Prefix
                  backend: { service: { name: ui, port: { number: 8080 } } }
          - host: ${agent_host}
            http:
              paths:
                - path: /
                  pathType: Prefix
                  backend: { service: { name: agent, port: { number: 5002 } } }

  # --- per-preview environment ---------------------------------------------
  # Anything in .secrets/preview-env-<name> reaches both containers. A
  # branch that integrates with an external service needs credentials the
  # other branches must not get, and they do not belong in a generated
  # overlay. optional: true so a preview without the file still deploys.
  - target: { kind: Deployment, name: agent }
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata: { name: agent }
      spec:
        template:
          spec:
            containers:
              - name: agent
                envFrom:
                  - secretRef: { name: preview-env, optional: true }
  - target: { kind: Deployment, name: ui }
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata: { name: ui }
      spec:
        template:
          spec:
            containers:
              - name: ui
                envFrom:
                  - secretRef: { name: preview-env, optional: true }

  # --- per-preview identity and traces -------------------------------------
  # One Keycloak client serves all previews; only the callback differs, and
  # preview.sh registers each one as an extra redirect URI.
  - target: { kind: Deployment, name: ui }
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata: { name: ui }
      spec:
        template:
          spec:
            containers:
              - name: ui
                env:
                  - name: SSO_CALLBACK_URL
                    value: https://${ui_host}${URL_SUFFIX}/auth/callback/oidc
  - target: { kind: Deployment, name: agent }
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata: { name: agent }
      spec:
        template:
          spec:
            containers:
              - name: agent
                env:
                  - name: OTEL_SERVICE_NAME
                    value: template-agent-${name}
EOF
}

# --- per-preview database ---------------------------------------------------

_db_name() { # _db_name <preview>
  # Dashes are legal in a preview name and in a postgres identifier, but an
  # unquoted one is a minus sign. Fold them rather than quote everywhere.
  echo "template_agent_$(tr '-' '_' <<<"$1")"
}

_psql() { # _psql <db> <sql...>
  local db="$1"; shift
  local pod
  pod="$(kc -n "${DATA_NS}" get pod -l component=database \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "${pod}" ]] || die "the shared postgres is not running in ${DATA_NS}"
  kc -n "${DATA_NS}" exec "${pod}" -- bash -c \
    "psql -U \"\${POSTGRES_USER:-postgres}\" -d $(printf %q "${db}") -tAc $(printf %q "$*")"
}

_ensure_database() { # _ensure_database <preview>
  # Previews share one postgres instance but not one database: the schema
  # is created by the langgraph checkpointer on first run, so two branches
  # with different migrations in the same database corrupt each other.
  # A database is cheap -- an instance is 500Mi.
  local db; db="$(_db_name "$1")"
  if [[ -n "$(_psql postgres "SELECT 1 FROM pg_database WHERE datname = '${db}'")" ]]; then
    ok "database ${db} already exists"
    return 0
  fi
  step "creating database ${db}"
  # CREATE DATABASE cannot run inside a transaction block, which is why
  # this is a bare -c rather than part of a script.
  _psql postgres "CREATE DATABASE ${db}" >/dev/null \
    || die "could not create ${db}"
  ok "database ${db} created"
}

# --- cross-namespace access to the data plane -------------------------------

_allow_data_plane() {
  # Scoped to component=database/cache -- the exact labels pgvector and redis
  # carry. It must NOT match agent or ui: a NetworkPolicy selecting a pod
  # that had none turns that pod default-deny, and selecting ui here would
  # cut ingress-nginx off from the main stack.
  #
  # The first rule restates what is true today (everything in ${DATA_NS} can
  # reach them) so adding this policy changes nothing for the main stack;
  # the second is what previews need.
  kc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-preview-clients
  namespace: ${DATA_NS}
spec:
  podSelector:
    matchExpressions:
      - { key: component, operator: In, values: [database, cache] }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
        - namespaceSelector:
            matchLabels: { kind.local/preview-of: template-agent }
      ports:
        - { protocol: TCP, port: 5432 }
        - { protocol: TCP, port: 6379 }
EOF
}

# --- deploy -----------------------------------------------------------------

cmd_deploy() { # deploy <name>
  local name="${1:-}"; _require_name "${name}" deploy
  local ns tag; ns="$(_ns "${name}")"; tag="$(_tag "${name}")"
  [[ -d "${WORKTREE_DIR}/${name}" ]] || die "no preview '${name}'"

  "${CE}" image inspect "localhost/template-agent:${tag}" >/dev/null 2>&1 \
    || die "no image for '${name}' -- run: make preview-build NAME=${name}"

  kc get namespace "${DATA_NS}" >/dev/null 2>&1 \
    || die "the shared data plane is not deployed -- run: make agent-stack"

  # Stable index so the redis database does not change under a preview on
  # re-deploy: derived from the name, not from the order previews were made.
  local db=$(( ( $(cksum <<<"${name}" | cut -d' ' -f1) % 14 ) + 1 ))

  step "namespace ${ns}"
  kc get namespace "${ns}" >/dev/null 2>&1 || kc create namespace "${ns}" >/dev/null
  # A tenant like template-agent: policed by Kyverno in full, plus the label
  # the data plane's NetworkPolicy selects on.
  kc label namespace "${ns}" \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/warn=restricted \
    kind.local/preview-of=template-agent --overwrite >/dev/null

  _allow_data_plane
  _ensure_database "${name}"

  # Same COOKIE_SIGN and client secret as the main stack: one Keycloak
  # client serves every preview, so the secret has to match.
  step "secrets"
  # Both deployments mount this to build their CA bundle, and it is created
  # per namespace by the installer -- a new namespace does not have it, and
  # the pods sit in Init with FailedMount until it does.
  local ca_file="${ROOT_DIR}/.secrets/platform-root-ca.crt"
  [[ -s "${ca_file}" ]] || die "missing ${ca_file} -- run: make trust-ca"
  kc -n "${ns}" create configmap platform-ca --from-file=ca.crt="${ca_file}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null

  local cookie_file="${ROOT_DIR}/.secrets/ui-cookie-sign"
  local oidc_file="${ROOT_DIR}/.secrets/oidc-secret-template-agent"
  [[ -s "${cookie_file}" ]] || die "missing ${cookie_file} -- run: make agent-stack"
  kc -n "${ns}" create secret generic ui-secrets \
    --from-literal=COOKIE_SIGN="$(cat "${cookie_file}")" \
    --from-literal=SSO_CLIENT_SECRET="$([[ -s "${oidc_file}" ]] && cat "${oidc_file}")" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  # Per-preview environment, if this preview has any. Rewritten on every
  # deploy so editing the file and re-running is the whole workflow.
  local env_file="${ROOT_DIR}/.secrets/preview-env-${name}"
  if [[ -s "${env_file}" ]]; then
    kc -n "${ns}" create secret generic preview-env \
      --from-env-file="${env_file}" \
      --dry-run=client -o yaml | kc apply -f - >/dev/null
    ok "preview-env applied from $(basename "${env_file}")"
  else
    kc -n "${ns}" delete secret preview-env --ignore-not-found >/dev/null 2>&1 || true
  fi

  # Vertex credentials, if the main stack has them. Optional: the agent
  # declares this key optional and only the default model needs it.
  if kc -n "${DATA_NS}" get secret agent-google-creds >/dev/null 2>&1; then
    kc -n "${DATA_NS}" get secret agent-google-creds -o json \
      | python3 -I -c 'import json,sys; d=json.load(sys.stdin); d["metadata"]={"name":"agent-google-creds"}; print(json.dumps(d))' \
      | kc -n "${ns}" apply -f - >/dev/null
  fi

  step "rendering the overlay"
  _write_overlay "${name}" "${db}"

  step "applying"
  kc apply -k "${PREVIEW_DIR}/${name}" >/dev/null || die "apply failed for '${name}'"

  # A preview's tag is mutable by design: every build replaces
  # localhost/*:preview-<name> in place. The pod spec therefore does not
  # change between builds, `kubectl apply` is a no-op, and the pods keep
  # running the previous image -- which looks exactly like a code change
  # having no effect. Restarting is the only thing that picks it up.
  step "restarting to pick up the rebuilt images"
  kc -n "${ns}" rollout restart deployment/agent deployment/ui >/dev/null 2>&1 || true

  cmd_sso >/dev/null 2>&1 || warn "could not register the preview callback URLs with Keycloak"
  cmd_portal >/dev/null 2>&1 || warn "could not add '${name}' to the homepage"

  for d in agent ui; do
    kc -n "${ns}" rollout status "deployment/${d}" --timeout=300s >/dev/null \
      || warn "${d} did not become ready in ${ns}"
  done
  ok "preview '${name}' at https://agent-ui-${name}.${BASE_DOMAIN}${URL_SUFFIX}"
  grep -qE "[[:space:]]agent-ui-${name}\.${BASE_DOMAIN//./\\.}([[:space:]]|\$)" /etc/hosts 2>/dev/null \
    || hint "the hostname is not in /etc/hosts yet" "make preview-hosts"
}

cmd_up() { cmd_build "$@"; cmd_deploy "$@"; }

# --- Keycloak ---------------------------------------------------------------

cmd_sso() {
  # Adds every preview's callback to the one template-agent client. Three
  # clients would mean three secrets and three sealed secrets; three
  # redirect URIs on one client is the same isolation for none of that.
  #
  # `make identity` rewrites this client, so re-run after it.
  local names; names="$(_names)"
  [[ -n "${names}" ]] || { ok "no previews to register"; return 0; }
  need jq
  local base="https://keycloak.${BASE_DOMAIN}${URL_SUFFIX}" extra=()
  local h
  for n in ${names}; do
    h="https://agent-ui-${n}.${BASE_DOMAIN}${URL_SUFFIX}"
    extra+=("${h}/auth/callback/oidc" "${h}/*")
  done

  local tok
  tok="$(curl -fsS --cacert "${ROOT_DIR}/.secrets/platform-root-ca.crt" \
    -d "client_id=admin-cli" -d "username=${KEYCLOAK_ADMIN_USERNAME}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" -d "grant_type=password" \
    "${base}/realms/master/protocol/openid-connect/token" | jq -r .access_token)" \
    || die "could not authenticate to Keycloak"
  [[ -n "${tok}" && "${tok}" != "null" ]] || die "could not authenticate to Keycloak"

  local api=("curl" "-fsS" "--cacert" "${ROOT_DIR}/.secrets/platform-root-ca.crt"
             "-H" "Authorization: Bearer ${tok}")
  local cid
  cid="$("${api[@]}" "${base}/admin/realms/platform/clients?clientId=template-agent" \
    | jq -r '.[0].id // empty')"
  [[ -n "${cid}" ]] || die "the template-agent Keycloak client does not exist -- run: make identity"

  local cur merged
  cur="$("${api[@]}" "${base}/admin/realms/platform/clients/${cid}")"
  merged="$(jq -n --argjson c "${cur}" --args '
      ($c.redirectUris + $ARGS.positional | unique) as $r
      | {redirectUris: $r,
         webOrigins: (($c.webOrigins + ($r | map(sub("/[^/]*$"; "")))) | unique)}' \
      "${extra[@]}")"
  "${api[@]}" -X PUT -H 'Content-Type: application/json' \
    "${base}/admin/realms/platform/clients/${cid}" -d "${merged}" >/dev/null \
    || die "could not update the template-agent client"
  ok "registered $(wc -w <<<"${names}" | tr -d ' ') preview callback URLs with Keycloak"
}

# --- host wiring ------------------------------------------------------------

cmd_hosts() {
  # macOS has no wildcard DNS, so each preview hostname needs a real entry.
  # Composed on top of the platform list rather than replacing it: the block
  # in /etc/hosts is rewritten whole every time.
  local extra_hosts=""
  for n in $(_names); do extra_hosts+=" agent-${n} agent-ui-${n}"; done
  [[ -n "${extra_hosts}" ]] || { ok "no previews"; return 0; }
  PLATFORM_HOSTS="${PLATFORM_HOSTS}${extra_hosts}" "${ROOT_DIR}/scripts/host-setup.sh" hosts add
}

# --- homepage ---------------------------------------------------------------

cmd_portal() {
  # Rewrites the "template-agent" subgroup of the portal's Apps group in the
  # live portal-config ConfigMap: one tile per worktree, next to `main`.
  #
  # The previews are not committed to platform/manifests/portal.yaml -- they
  # are created and destroyed, and tiles pointing at three dead hostnames are
  # worse than no tiles. Only `main` is committed there. The cost is that
  # `make install` re-renders the manifest and drops the rest -- re-run `make
  # preview-portal` after it.
  kc -n portal get configmap portal-config >/dev/null 2>&1 \
    || { warn "the portal is not installed; skipping the homepage"; return 0; }

  local names block="" br
  names="$(_names)"
  # No worktrees found is almost always a wrong PREVIEW_WORKTREES, not an
  # instruction to empty the group -- leave whatever the manifest rendered.
  [[ -n "${names}" ]] || { warn "no worktrees under ${WORKTREE_DIR}; leaving the homepage alone"; return 0; }
  # `main` is the baseline everyone compares against, so it reads first;
  # the rest stay in the alphabetical order _names gives.
  names="$({ printf '%s\n' ${names} | grep -x main; printf '%s\n' ${names} | grep -vx main; } || true)"
  for n in ${names}; do
    br="$(git -C "${WORKTREE_DIR}/${n}/template-agent" rev-parse --abbrev-ref HEAD 2>/dev/null \
      || echo unknown)"
    # A detached worktree reports "HEAD", which tells the reader nothing.
    [[ "${br}" == "HEAD" ]] && br="detached at $(git -C "${WORKTREE_DIR}/${n}/template-agent" \
      rev-parse --short HEAD 2>/dev/null)"
    block+="        - ${n}:"$'\n'
    block+="            href: https://agent-ui-${n}.${BASE_DOMAIN}${URL_SUFFIX}"$'\n'
    block+="            siteMonitor: https://agent-ui-${n}.${BASE_DOMAIN}${URL_SUFFIX}"$'\n'
    block+="            description: ${br} -- namespace $(_ns "${n}"), shared data plane"$'\n'
    block+="            icon: mdi-source-branch"$'\n'
  done

  local cur updated
  cur="$(kc -n portal get configmap portal-config -o jsonpath='{.data.services\.yaml}')"
  updated="$(PREVIEW_BLOCK="${block}" PREVIEW_CURRENT="${cur}" python3 -I - <<'PY'
import json, os, sys

# services.yaml is a list of single-key groups starting in column 0. Apps
# holds one nested group, template-agent, whose children are the worktrees:
#
#   - Apps:
#       - template-agent:
#           - main:
#               href: ...
#           - <worktree>: ...
#
# The children are replaced wholesale by what is on disk, so this is
# idempotent and a removed worktree actually disappears from the page.
#
# Passed in the environment, not on stdin: stdin is this script.
SUB = "    - template-agent:"
lines = os.environ["PREVIEW_CURRENT"].splitlines()

start = next((i for i, l in enumerate(lines) if l.rstrip() == SUB), None)
if start is None:
    sys.exit("the portal has no Apps > template-agent group; re-run `make install`")

# The subgroup runs until the next line indented at or above its own level.
end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i].strip() and len(lines[i]) - len(lines[i].lstrip()) <= 4:
        end = i
        break

block = [l for l in os.environ.get("PREVIEW_BLOCK", "").splitlines() if l.strip()]
body = "\n".join(lines[:start + 1] + block + lines[end:]).rstrip() + "\n"
print(json.dumps({"data": {"services.yaml": body}}))
PY
  )" || die "could not render the homepage group"

  kc -n portal patch configmap portal-config --type merge -p "${updated}" >/dev/null \
    || die "could not update portal-config"
  # homepage reads these files once at boot; a ConfigMap edit alone is invisible.
  kc -n portal rollout restart deployment/portal >/dev/null
  kc -n portal rollout status deployment/portal --timeout=120s >/dev/null \
    || warn "the portal did not restart cleanly"
  ok "homepage lists $(wc -w <<<"${names}" | tr -d ' ') preview(s)"
}

# --- list and teardown ------------------------------------------------------

cmd_list() {
  local names; names="$(_names)"
  [[ -n "${names}" ]] || { echo "  no previews -- make preview-add NAME=<name>"; return 0; }
  printf '  %-12s %-14s %-10s %s\n' NAME NAMESPACE PODS URL
  for n in ${names}; do
    local ns ready
    ns="$(_ns "${n}")"
    ready="$(kc -n "${ns}" get deploy agent ui \
      -o jsonpath='{range .items[*]}{.status.readyReplicas}/{.spec.replicas} {end}' 2>/dev/null)"
    printf '  %-12s %-14s %-10s %s\n' "${n}" "${ns}" "${ready:-none}" \
      "https://agent-ui-${n}.${BASE_DOMAIN}${URL_SUFFIX}"
  done
}

cmd_rm() { # rm <name>
  local name="${1:-}"; _require_name "${name}" rm
  local ns; ns="$(_ns "${name}")"
  step "deleting namespace ${ns}"
  kc delete namespace "${ns}" --ignore-not-found --wait=false >/dev/null

  # The preview's own database goes with it -- its contents are this
  # preview's checkpoints and nothing else. WITH (FORCE) because the
  # namespace delete above does not wait, so the agent may still hold a
  # connection; without it the drop fails on "database is being accessed".
  local db; db="$(_db_name "${name}")"
  if [[ -n "$(_psql postgres "SELECT 1 FROM pg_database WHERE datname = '${db}'" 2>/dev/null)" ]]; then
    step "dropping database ${db}"
    _psql postgres "DROP DATABASE IF EXISTS ${db} WITH (FORCE)" >/dev/null 2>&1 \
      || warn "could not drop ${db}; drop it by hand if you care about the space"
  fi
  for repo in "${REPOS[@]}"; do
    local wt="${WORKTREE_DIR}/${name}/${repo}"
    [[ -d "${wt}" ]] || continue
    # Uncommitted work in a preview worktree is still work. Refuse rather
    # than take it with the namespace.
    if [[ -n "$(git -C "${wt}" status --porcelain 2>/dev/null)" ]]; then
      warn "${wt} has uncommitted changes -- left in place"
      continue
    fi
    git -C "${SRC_CLONES}/${repo}" worktree remove --force "${wt}" 2>/dev/null \
      || warn "could not remove the ${repo} worktree"
  done
  rmdir "${WORKTREE_DIR}/${name}" 2>/dev/null || true
  rm -rf "${PREVIEW_DIR:?}/${name:?}"
  for t in template-agent template-agent-src template-ui; do
    "${CE}" rmi -f "localhost/${t}:$(_tag "${name}")" >/dev/null 2>&1 || true
  done
  cmd_portal >/dev/null 2>&1 || warn "could not remove '${name}' from the homepage"
  ok "preview '${name}' removed"
}

case "${1:-list}" in
  add)    shift; cmd_add    "$@" ;;
  build)  shift; cmd_build  "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  up)     shift; cmd_up     "$@" ;;
  sso)    shift; cmd_sso    "$@" ;;
  portal) shift; cmd_portal "$@" ;;
  hosts)  shift; cmd_hosts  "$@" ;;
  list)   shift; cmd_list   "$@" ;;
  rm)     shift; cmd_rm     "$@" ;;
  *) die "usage: preview.sh <add|build|deploy|up|sso|portal|hosts|list|rm> [name] [refs]" ;;
esac
