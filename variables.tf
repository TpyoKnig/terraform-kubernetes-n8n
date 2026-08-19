# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Common ────────────────────────────────────────────────────────────────────
# Naming and tagging inputs threaded through every resource this module
# creates, ahead of the product-specific settings below. The analog of the
# friendly_name_prefix/common_tags block HVD modules lead with; ours is named
# and shaped for this module's own resource-naming and tagging needs rather
# than mirroring HVD's variable names, since renaming cluster_name/tags to
# match would be a breaking change with no functional benefit (see #81).

variable "k8s_namespace" {
  description = "Kubernetes namespace to deploy n8n into. Names the namespace the module creates when create_namespace = true (the default), or the existing namespace the module deploys into when create_namespace = false."
  type        = string
  default     = "n8n"

  validation {
    # DNS-1123 label, which is what Kubernetes requires of a namespace name and
    # what every resource this module creates in it inherits. Checked here
    # rather than left to the API server so the failure names the input that
    # caused it, at plan time, instead of surfacing mid-apply.
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.k8s_namespace)) && length(var.k8s_namespace) <= 63
    error_message = "namespace must be a DNS-1123 label, which is what Kubernetes requires of a namespace: 63 characters or fewer, lowercase alphanumerics and hyphens only, starting and ending with an alphanumeric (e.g. \"n8n\", \"n8n-prod\"). Underscores, dots and uppercase are rejected."
  }
}

# ── Core inputs ───────────────────────────────────────────────────────────────
# The hostname n8n is served on, and the namespace it lives in. Everything the
# module needs from outside itself (the cluster, its ingress controller, its
# issuer) reaches it through provider configuration rather than an input; see
# examples/homelab/providers.tf.

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). Becomes the Ingress host and the base of the webhook URLs n8n advertises, and must be covered by whatever certificate the named ClusterIssuer issues. The module creates no DNS record for it; see the examples for two worked strategies."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.n8n_domain))
    error_message = "Value must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }
}

variable "n8n_additional_domains" {
  description = "Extra fully-qualified hostnames n8n should answer on, beyond n8n_domain. Each becomes an additional host rule on both Ingresses the chart renders (the webhook Ingress derives its hosts from the main one, so the webhook prefixes are routed for every name too) and is added to the single TLS block, so cert-manager issues one Certificate covering all of them. The module creates no DNS records: every name has to resolve to this ingress controller by some means you arrange. It also does not inspect the issued certificate's SAN set, so an issuer that refuses one of the names fails at the Certificate rather than at plan time. n8n_domain stays canonical: it is what n8n advertises as WEBHOOK_URL and N8N_HOST unless n8n_webhook_url overrides the former. Names are normalized to lowercase, because Kubernetes rejects an uppercase Ingress host and DNS is case-insensitive."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for d in var.n8n_additional_domains : can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", d))])
    error_message = "Every entry must be a valid fully qualified domain name (e.g. hooks.example.com)."
  }

  validation {
    condition     = !contains(var.n8n_additional_domains, var.n8n_domain)
    error_message = "n8n_domain must not be repeated in n8n_additional_domains; it is always included on the certificate."
  }

  validation {
    condition     = length(distinct(var.n8n_additional_domains)) == length(var.n8n_additional_domains)
    error_message = "n8n_additional_domains must not contain duplicates."
  }

  # ACM's default quota is 10 names per certificate, the primary domain
  # included, so 9 is the most that can be added here.
  validation {
    condition     = length(var.n8n_additional_domains) <= 9
    error_message = "At most 9 additional domains are supported (ACM allows 10 names per certificate including n8n_domain)."
  }
}

variable "n8n_webhook_url" {
  description = "Public HTTPS base URL used for webhook callbacks (e.g. <https://webhooks.example.com>). Defaults to https://<n8n_domain> when not set. Override when webhooks are served from a different host than the n8n UI."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_webhook_url == null ? true : can(regex("^https://[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.n8n_webhook_url))
    error_message = "n8n_webhook_url must be an https:// base URL with a host and no whitespace (e.g. \"https://webhooks.example.com\"). n8n hands this value to callers as the address to POST to, so a bare hostname, an http:// URL, or a trailing newline produces webhook URLs that external systems cannot reach, with nothing failing on this side."
  }
}

variable "n8n_encryption_key" {
  description = "N8N_ENCRYPTION_KEY value. Leave null (the default) to let the module generate one with random_id (32 bytes, rendered as 64 hex characters). THIS IS NOT A ROTATION MECHANISM. n8n's own docs describe this as the instance's master key, set once at deployment time and never changed; the separate data encryption key stored in the database is what n8n's key-rotation feature actually rotates, unrelated to this input. Setting this to a NEW value against a database that already holds credentials encrypted under a DIFFERENT key does not migrate or re-encrypt anything: n8n reads the new key, the stored credentials were written under the old one, and every one of them becomes permanently unreadable with no recovery path on n8n's side. The only supported uses of a non-null value are (1) the first deployment against a brand-new, empty database, and (2) restoring the EXACT ORIGINAL key into a rebuilt deployment pointed at a database that already holds credentials encrypted under that same key: a rebuilt cluster, or any fresh terraform apply reattaching to existing data. Retrieve that original value beforehand with `terraform output -raw n8n_encryption_key`, or from wherever it was backed up; never invent a new one for an existing database. Must be exactly 64 hexadecimal characters (32 bytes), the shape n8n and the chart expect; anything else is rejected at plan time rather than failing less legibly inside n8n. Leave this null as well when n8n_encryption_key_secret_ref is set instead; setting both is rejected at plan time."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.n8n_encryption_key == null || can(regex("^[0-9a-fA-F]{64}$", var.n8n_encryption_key))
    error_message = "n8n_encryption_key must be exactly 64 hexadecimal characters (32 bytes), the shape random_id.n8n_encryption_key (byte_length = 32) has always produced, or null to let the module generate one."
  }
}

variable "n8n_encryption_key_secret_ref" {
  description = "Existing Kubernetes Secret carrying N8N_ENCRYPTION_KEY, instead of supplying the value through n8n_encryption_key. Different in shape from the other three secret-reference inputs below: the chart's secretRefs.existingSecret (n8n.tf) names a single Secret that n8n.coreSecretsEnv reads FOUR keys from, N8N_ENCRYPTION_KEY, N8N_HOST, N8N_PORT and N8N_PROTOCOL, so setting this input points the chart at your Secret for all four, not just the encryption key, and your Secret must carry every one of them: N8N_HOST is var.n8n_domain, N8N_PORT is \"5678\", N8N_PROTOCOL is \"http\". See README.md -> \"Where credentials live\" for a worked ExternalSecret example with a template block supplying those three literals alongside the fetched key. key defaults to \"N8N_ENCRYPTION_KEY\" and exists only for shape parity with the other three secret-reference inputs: the chart hardcodes the key name it reads on this path, so this module rejects any other value at plan time rather than silently ignoring it. Setting this input also gates kubernetes_secret.n8n to zero, since secretRefs.existingSecret replaces that whole Secret rather than one key inside it. The task runner auth token is unaffected, since it is never in a Secret at all: it reaches the chart as a literal Helm value regardless of this input. Setting this alongside n8n_encryption_key is rejected at plan time. The module does not verify that the referenced Secret exists or carries the required keys: a missing key surfaces only as a pod stuck in CreateContainerConfigError, not as a Terraform error."
  type = object({
    name = string
    key  = optional(string)
  })
  default = null

  validation {
    condition     = var.n8n_encryption_key_secret_ref == null || var.n8n_encryption_key == null
    error_message = "Both n8n_encryption_key and n8n_encryption_key_secret_ref are set. Only one may supply the encryption key: remove n8n_encryption_key to consume the referenced Secret, or remove n8n_encryption_key_secret_ref to keep passing the value directly."
  }

  # Written as a nested ternary rather than `== null ||`, per AGENTS.md's
  # consistency rule for guard-style conditions: the null guard gates the
  # `.key` access structurally rather than relying on short-circuit
  # evaluation.
  validation {
    condition     = var.n8n_encryption_key_secret_ref == null ? true : coalesce(var.n8n_encryption_key_secret_ref.key, "N8N_ENCRYPTION_KEY") == "N8N_ENCRYPTION_KEY"
    error_message = "n8n_encryption_key_secret_ref.key must be \"N8N_ENCRYPTION_KEY\" or unset. The chart's coreSecretsEnv helper reads this exact key name from secretRefs.existingSecret and takes no override, unlike the other three secret-reference inputs, whose key the chart does honor."
  }

}

# ── Cluster ───────────────────────────────────────────────────────────────────

variable "create_namespace" {
  description = "When true (the default), the module creates the Kubernetes namespace named by var.k8s_namespace. Set to false to deploy into a namespace that already exists, e.g. one a platform team created with its own resource quotas, labels, or network policies. The module does not validate that the namespace exists; the apply fails on the first resource that references it if it does not. Kept as a static boolean rather than checking for the namespace's existence because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
  nullable    = false
}

# ── Ingress ───────────────────────────────────────────────────────────────────

variable "create_ingress" {
  description = "Whether the module renders the Ingress for n8n. True (the default) renders one for n8n_domain plus every entry in n8n_additional_domains, using k8s_ingress_class_name and the cert-manager annotations built from k8s_ingress_cluster_issuer. Set false to own routing yourself: the module then creates no Ingress and you build your own from the namespace, n8n_service_name, n8n_webhook_service_name, n8n_service_port and n8n_webhook_path_prefixes outputs. Routing the webhook prefixes to the webhook processors is the part that is easy to get wrong on that path: production webhooks are disabled on the main pods, so a catch-all rule that swallows them returns 404 for every inbound webhook. See examples/homelab-split-ingress."
  type        = bool
  default     = true
}

variable "k8s_ingress_class_name" {
  description = "Ingress class name for the Ingress the chart renders when create_ingress = true. Defaults to \"nginx\" (ingress-nginx)."
  type        = string
  default     = "nginx"
  nullable    = false
}

variable "k8s_ingress_host" {
  description = "Hostname served by the Ingress. Empty string falls back to var.n8n_domain. Only used when create_ingress = true."
  type        = string
  default     = ""
  nullable    = false
}

variable "k8s_ingress_cluster_issuer" {
  description = "cert-manager ClusterIssuer that issues the TLS certificate for the Ingress. Empty string skips the cert-manager annotation (bring-your-own TLS Secret). Only used when create_ingress = true."
  type        = string
  default     = ""
  nullable    = false
}

variable "k8s_ingress_tls_secret_name" {
  description = "Explicit TLS Secret name for the Ingress. Empty string derives one from the ingress host by replacing dots with dashes and appending -tls. Only used when create_ingress = true."
  type        = string
  default     = ""
  nullable    = false
}

variable "k8s_ingress_extra_annotations" {
  description = "Extra annotations merged onto the Ingress on top of the module's ingress-nginx defaults (last write wins). Only used when create_ingress = true."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "n8n_extra_helm_values" {
  description = "Raw YAML merged on top of the module-rendered chart values. The escape hatch for chart knobs this module exposes no typed input for. Merging is Helm's, which coalesces maps but replaces lists outright, so an overlay that sets a list the module already renders substitutes its own rather than adding to it. config.extraEnv is the list where that matters most: overriding it there drops N8N_ENCRYPTION_KEY and every connection variable the module assembles, and the release still installs, so the failure surfaces as pods that come up misconfigured. Use n8n_extra_env for plain values and n8n_extra_env_from_secret for secretKeyRef entries; both append to that list instead of replacing it."
  type        = string
  default     = ""
  nullable    = false
}

# Cluster-wide operators (an ingress controller, cert-manager, CloudNativePG,
# KEDA, metrics-server) are the caller's to install; see AGENTS.md for why the
# module owns none of them. Where an input attests to one being present,
# Terraform cannot see whether it actually is at plan time, so the claim is the
# caller's alone and getting it wrong surfaces after the apply rather than
# during it. See each variable for what actually breaks and how.

# ── Chart repositories ────────────────────────────────────────────────────────
# Each helm_release's repository argument, exposed so any of the five charts
# can be pulled from a private mirror instead of its public upstream. Every
# default reproduces the module's own hardcoded value exactly, so leaving all
# five unset is a no-op for every existing deployment. This is the other half
# of air-gapped support: n8n_image_repository already lets the n8n container
# image itself be mirrored, but until these existed the five charts had no
# such input, so a cluster with no egress to their public repositories could
# not come up regardless of what the image pointed at.
#
# A mirror must carry the exact version each chart is pinned to in "Chart
# versions" below, since all five versions are now explicit. Mirroring a
# subset of upstream's versions is the common case, so expect to set the
# matching *_chart_version alongside the repository rather than only the
# repository.

variable "n8n_chart_repository" {
  description = "Helm chart repository for the n8n chart. Defaults to the public upstream (oci://ghcr.io/n8n-io/n8n-helm-chart). Point this at a private mirror, e.g. a Harbor or Zot OCI registry inside the network, for a cluster with no egress to ghcr.io. The mirror must serve the exact chart version named by n8n_chart_version; this module does not verify that a mirrored repository actually carries it."
  type        = string
  default     = "oci://ghcr.io/n8n-io/n8n-helm-chart"

  validation {
    condition     = can(regex("^(https://|oci://)[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.n8n_chart_repository))
    error_message = "n8n_chart_repository must be a URL starting with https:// or oci://, with a host and no whitespace."
  }
}

variable "valkey_chart_repository" {
  description = "Helm chart repository for the Valkey chart. Defaults to the public upstream (https://valkey-io.github.io/valkey-helm). Only used when redis_backend = \"valkey\"."
  type        = string
  default     = "https://valkey-io.github.io/valkey-helm"

  validation {
    condition     = can(regex("^(https://|oci://)[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.valkey_chart_repository))
    error_message = "valkey_chart_repository must be a URL starting with https:// or oci://, with a host and no whitespace."
  }
}

# ── Chart versions ────────────────────────────────────────────────────────────
# The four controller charts alongside n8n's own. n8n_chart_version has always
# been pinned; these four were not passed a `version` at all, which meant the
# installed version was whatever each repository's index happened to serve at
# the moment of the first apply. Two deployments of the same module commit
# could therefore be running different controller versions, and neither the
# plan nor the state made that visible until something broke.
#
# Every default is the version the public repository serves as latest as of
# 2026-08-05, so a fresh apply installs exactly what it would have installed
# unpinned. A deployment that first applied earlier and is still on an older
# chart plans an in-place Helm upgrade to the pinned version on its next apply.
# That is the intended cost: a deliberate, reviewable upgrade in a plan beats a
# version nobody chose. Override any of these to stay where you are.
#
# Bumping a default here is a module change worth its own CHANGELOG entry,
# because it upgrades a cluster-scoped controller for every consumer who has
# not pinned. See AGENTS.md → "When adding a new input".

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy. Must be an exact version, not a constraint: the Helm provider resolves this literally."
  type        = string
  default     = "1.10.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.n8n_chart_version))
    error_message = "n8n_chart_version must be an exact SemVer 2 version such as \"1.10.0\" or \"1.11.0-rc.1\". Helm resolves chart versions literally here, so a range (\">= 1.10\", \"~1.10.0\"), a leading \"v\", or a floating tag is not accepted."
  }
}

variable "n8n_image_tag" {
  description = "n8n application image tag to deploy (e.g. \"2.27.4\"). When it is null (the default), the Helm chart's own default applies, currently the floating `stable` tag, which resolves to whatever n8n version is latest at the time each pod starts. Pin this to a concrete version for reproducible, incremental upgrades and to avoid crossing major-version boundaries (e.g. the n8n 2.0 breaking changes) on an unplanned pod reschedule. See <https://docs.n8n.io/2-0-breaking-changes/> for the n8n 2.x migration guide."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_image_tag))
    error_message = "n8n_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"1.2.3\", \"1.2.3-alpine\"). Set to null to use the chart's default (stable)."
  }
}

variable "n8n_image_repository" {
  description = "Container image repository for the n8n application, without a tag (e.g. \"registry.example.com/n8n\"). When it is null (the default), the Helm chart's own repository applies (currently `docker.n8n.io/n8nio/n8n`). Point this at a custom image built from the n8n base image to bake community packages into the image itself, which removes the boot-time npm install that n8n_reinstall_missing_packages performs on every pod start. Set the tag through n8n_image_tag, not here. Two things come with a custom image: the image has to be pullable from the cluster, so a private registry needs its credentials listed in n8n_image_pull_secrets unless your nodes are already authenticated to it; and when the tag is not a published n8n version, also set n8n_task_runner_image_tag, because the chart derives the task runner sidecar's tag from this image's tag."
  type        = string
  default     = null

  validation {
    # Docker's own reference grammar (distribution/reference), narrowed to the
    # repository half: no tag, no digest. Reading it in pieces, since it is one
    # long line by necessity (a validation condition cannot reference a local):
    #
    #   label = [A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?
    #   ipv6  = \[[0-9A-Fa-f:]+\]
    #   host  = (label(.label)* | ipv6)(:port)?
    #   sep   = __ | [._] | -+
    #   comp  = [a-z0-9]+(sep[a-z0-9]+)*
    #   ref   = (host/)? comp(/comp)*
    #
    # Every accept and reject below was read off docker's exit code rather than
    # inferred, because two earlier attempts at this validation got the rules
    # backwards in both directions.
    #
    # The host is deliberately permissive about case while path components are
    # not, and that asymmetry is Docker's, not ours. splitDockerDomain treats a
    # first component as a registry host when it contains a dot or a colon, is
    # localhost, *or contains an uppercase letter*, so N8NIO/n8n and MYREG/n8n
    # are pullable while myorg/N8N is not ("repository name must be lowercase")
    # and FOO/BAR is not. Path components may carry doubled separators
    # (my--repo, my__repo, a---b) which an earlier version wrongly rejected.
    #
    # What stays rejected is a reference no registry could serve: a scheme
    # prefix, a second colon, an empty label (a..b, a trailing slash, a doubled
    # slash), a label ending in a hyphen, and an IPv6 zone ID. Each of those
    # otherwise reaches the chart and surfaces as ImagePullBackOff only after
    # the cluster is up, which is the whole point of checking at plan time.
    #
    # The bracketed host is hex and colons only, no dots, which is Docker's
    # grammar exactly: it rejects [....], [a:b.c] and even the IPv4-mapped
    # [::ffff:1.2.3.4], while accepting the structurally meaningless [::::].
    # Matching that is deliberate. Being stricter than docker here would reject
    # an address a registry would have answered on, and this validation has no
    # override.
    condition = var.n8n_image_repository == null ? true : (
      length(var.n8n_image_repository) <= 255 &&
      can(regex("^(?:(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*|\\[[0-9A-Fa-f:]+\\])(?::[0-9]+)?/)?[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*)*$", var.n8n_image_repository))
    )
    error_message = "n8n_image_repository must be a bare image repository reference that Docker can pull: an optional registry host with an optional port, then one or more lowercase path components (e.g. \"myregistry.example.com/n8n\", \"registry.internal:5000/n8n\", \"n8nio/n8n\", \"[2001:db8::1]:5000/n8n\"). No scheme (\"https://\"), no whitespace, no uppercase path components, and no empty label anywhere, which rules out a trailing slash, a doubled slash, and a doubled dot. Set to null to use the chart's default (docker.n8n.io/n8nio/n8n)."
  }

  validation {
    # The chart renders `image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"`,
    # so a tag or digest carried in the repository string would render an
    # unpullable reference like "myrepo/n8n:1.2.3:stable". Catch it at plan time
    # and point at the right input instead of failing at pod start.
    condition     = var.n8n_image_repository == null ? true : !can(regex(":", reverse(split("/", var.n8n_image_repository))[0]))
    error_message = "n8n_image_repository must not include a tag or digest, because the chart appends the tag itself. Pass the version via n8n_image_tag instead (e.g. n8n_image_repository = \"myregistry.example.com/n8n\", n8n_image_tag = \"2.27.4\")."
  }
}

variable "n8n_image_pull_secrets" {
  description = "Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in var.k8s_namespace, that the n8n pods authenticate to their image registry with. Leave empty (the default) for a public registry, or where the nodes themselves are already authenticated to the registry through the kubelet's credential provider. Setting this changes who owns the ServiceAccount: the pinned chart renders imagePullSecrets nowhere, so the module creates the account itself, attaches these secrets to it, and passes serviceAccount.create = false, an arrangement the chart documents and supports. The module's account takes a different name from the chart's, so that turning this on for a deployment that already exists does not collide with the account Helm still owns. Creating and rotating the secrets stays the caller's job, because a dockerconfigjson generated here would sit in plaintext in Terraform state; kubectl create secret docker-registry, or an operator like External Secrets, are the usual routes. This is also the wrong tool for a registry whose authorization tokens expire on a schedule: prefer node-level authentication, or a controller that refreshes the Secret, over a value Terraform would have to re-apply."
  type        = list(string)
  default     = []

  validation {
    # A secret name is a DNS-1123 subdomain. Rejecting a malformed one here
    # beats the alternative: the ServiceAccount apply fails partway through,
    # after the cluster and the namespace already exist.
    condition = alltrue([
      for name in var.n8n_image_pull_secrets :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", name))
    ])
    error_message = "Every n8n_image_pull_secrets entry must be a DNS-1123 subdomain, which is what Kubernetes requires of a secret name: lowercase alphanumerics, hyphens and dots, starting and ending with an alphanumeric, with no empty label (e.g. \"ecr-cross-account\"). Pass the secret's name, not its contents."
  }

  validation {
    condition = alltrue([
      for name in var.n8n_image_pull_secrets : length(name) <= 253
    ])
    error_message = "Every n8n_image_pull_secrets entry must be 253 characters or fewer, the Kubernetes limit on a secret name."
  }

  validation {
    # Kubernetes tolerates a repeated imagePullSecrets entry, but a duplicate
    # here is far more likely to be a copy-paste slip than an intent.
    condition     = length(distinct(var.n8n_image_pull_secrets)) == length(var.n8n_image_pull_secrets)
    error_message = "n8n_image_pull_secrets must not repeat a secret name. Listing one twice adds nothing, since the kubelet tries each entry once."
  }
}

variable "n8n_helm_timeout" {
  description = "Seconds Terraform waits for the n8n Helm release to converge. Increase for large deployments where rolling out 50+ pods (workers + webhook processors + main) exceeds the default. 600s is fine for the default/medium examples; large deployments at 250+ pods need ~1800s."
  type        = number
  default     = 600

  validation {
    condition     = var.n8n_helm_timeout >= 60
    error_message = "n8n_helm_timeout must be at least 60 seconds."
  }
}

variable "n8n_timezone" {
  description = "Timezone for n8n (e.g. UTC, America/New_York, Europe/London)"
  type        = string
  default     = "UTC"
}

variable "n8n_log_level" {
  description = "n8n log level. Maps to the N8N_LOG_LEVEL environment variable. One of: silent, error, warn, info, debug, verbose."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["silent", "error", "warn", "info", "debug", "verbose"], var.n8n_log_level)
    error_message = "n8n_log_level must be one of: silent, error, warn, info, debug, verbose."
  }
}

variable "n8n_log_output" {
  description = "n8n log output destination(s). Maps to the N8N_LOG_OUTPUT environment variable. Comma-separated subset of: console, file (e.g. \"console\", \"file\", \"console,file\"). Note: this variable does NOT control log *format*: setting an invalid value (e.g. \"json\") leaves Winston with no transport and silently drops all logs. To emit JSON-formatted logs, configure n8n's logging block separately; this env var only selects destinations."
  type        = string
  default     = "console"

  validation {
    condition     = alltrue([for v in split(",", var.n8n_log_output) : contains(["console", "file"], trimspace(v))])
    error_message = "n8n_log_output only accepts console and/or file (comma-separated, e.g. \"console\" or \"console,file\")."
  }
}

variable "valkey_chart_version" {
  description = "Version of the valkey-io/valkey-helm chart to install. Only used when redis_backend = \"valkey\"."
  type        = string
  default     = "0.11.0"
  nullable    = false
}

# ── n8n resource requests and limits ──────────────────────────────────────────

variable "n8n_main_cpu_request" {
  description = "CPU request for n8n main pods (e.g. 1000m, 500m)"
  type        = string
  default     = "1000m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_main_cpu_request))
    error_message = "n8n_main_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_main_cpu_limit" {
  description = "CPU limit for n8n main pods (e.g. 2000m, 1000m)"
  type        = string
  default     = "2000m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_main_cpu_limit))
    error_message = "n8n_main_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_main_memory_request" {
  description = "Memory request for n8n main pods (e.g. 2Gi, 1Gi)"
  type        = string
  default     = "2Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_main_memory_request))
    error_message = "n8n_main_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_main_memory_limit" {
  description = "Memory limit for n8n main pods (e.g. 4Gi, 2Gi)"
  type        = string
  default     = "4Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_main_memory_limit))
    error_message = "n8n_main_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_worker_cpu_request" {
  description = "CPU request for n8n worker pods (e.g. 500m, 1000m)"
  type        = string
  default     = "500m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_worker_cpu_request))
    error_message = "n8n_worker_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_worker_cpu_limit" {
  description = "CPU limit for n8n worker pods (e.g. 1000m, 2000m)"
  type        = string
  default     = "1000m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_worker_cpu_limit))
    error_message = "n8n_worker_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_worker_memory_request" {
  description = "Memory request for n8n worker pods (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_worker_memory_request))
    error_message = "n8n_worker_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_worker_memory_limit" {
  description = "Memory limit for n8n worker pods (e.g. 2Gi, 4Gi)"
  type        = string
  default     = "2Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_worker_memory_limit))
    error_message = "n8n_worker_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_webhook_cpu_request" {
  description = "CPU request for n8n webhook processor pods (e.g. 300m, 500m). This default is sized for typical webhook traffic, not for n8n_reinstall_missing_packages = true: a low request against an npm-install CPU spike is what drives the CPU-based HPA into a scale-up-on-every-rollout loop. Raise to at least 800m when that toggle is on; see n8n_reinstall_missing_packages and docs/troubleshooting.md."
  type        = string
  default     = "300m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_webhook_cpu_request))
    error_message = "n8n_webhook_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_webhook_cpu_limit" {
  description = "CPU limit for n8n webhook processor pods (e.g. 800m, 1000m). Raise to at least 1500m when n8n_reinstall_missing_packages = true; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "800m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_webhook_cpu_limit))
    error_message = "n8n_webhook_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_webhook_memory_request" {
  description = "Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi). Raise to at least 1Gi when n8n_reinstall_missing_packages = true; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_webhook_memory_request))
    error_message = "n8n_webhook_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_webhook_memory_limit" {
  description = "Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi). This default is too low for n8n_reinstall_missing_packages = true: concurrent npm installs plus the n8n baseline can exceed it and OOMKill the pod mid-install into a reinstall/broadcast crash loop. Raise to at least 2Gi when that toggle is on; see that variable and docs/troubleshooting.md."
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_webhook_memory_limit))
    error_message = "n8n_webhook_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

# ── Execution settings ────────────────────────────────────────────────────────

variable "n8n_worker_concurrency" {
  description = "Number of jobs each worker pod can process simultaneously"
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_worker_concurrency >= 1
    error_message = "Worker concurrency must be at least 1."
  }
}

variable "n8n_execution_timeout" {
  description = "Default execution timeout in seconds (-1 to disable)"
  type        = number
  default     = 7200
}

variable "n8n_execution_timeout_max" {
  description = "Maximum execution timeout users can configure in seconds"
  type        = number
  default     = 7200
}

variable "n8n_execution_concurrency_limit" {
  description = "Maximum concurrent production executions (-1 to disable)"
  type        = number
  default     = 100
}

variable "n8n_pruning_max_age" {
  description = "Maximum age of execution records to retain, in hours (336 = 14 days)"
  type        = number
  default     = 336
}

variable "n8n_pruning_max_count" {
  description = "Maximum number of execution records to retain (0 = no limit)"
  type        = number
  default     = 10000
}

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n stores the data of each new execution. Maps to N8N_EXECUTION_DATA_STORAGE_MODE. 'database' (the default) keeps execution data in PostgreSQL, matching n8n's own default, and emits no env var. 'filesystem' is deliberately not accepted: pod filesystems are ephemeral and unshared in this module's queue-mode topology, so execution data written there would be lost on reschedule and invisible to the other pods. Object-storage offload is not offered on this platform either: the module provisions no bucket, because it will not own a stateful data service on a cluster whose lifecycle it does not control. Execution-data writes are usually the dominant write load on the n8n database at volume, so if that becomes the constraint, the lever is pruning (n8n_pruning_max_age / n8n_pruning_max_count) or an external Postgres sized for it."
  type        = string
  default     = "database"
  nullable    = false

  validation {
    condition     = var.n8n_execution_data_storage_mode == "database"
    error_message = "n8n_execution_data_storage_mode must be \"database\" (n8n's default, execution data in PostgreSQL). \"filesystem\" is unsupported because pod filesystems are ephemeral and unshared in queue mode, and \"s3\" because this module provisions no bucket and disables the chart's object-storage block, so setting it would tell n8n to offload to storage that was never configured. Wire an external bucket by hand instead: see docs/operations.md."
  }
}

# ── Graceful shutdown ─────────────────────────────────────────────────────────

variable "n8n_termination_grace_period" {
  description = "Seconds Kubernetes waits after SIGTERM before force-killing pods. MINIMUM: do not lower below 60. Workers need time to finish in-flight executions before being terminated."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_termination_grace_period >= 60
    error_message = "Termination grace period must be at least 60 seconds to allow in-flight executions to complete."
  }
}

variable "n8n_prestop_sleep" {
  description = "Seconds the preStop hook sleeps before SIGTERM is sent, giving the load balancer time to drain the pod. MINIMUM: do not lower below 10."
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_prestop_sleep >= 10
    error_message = "Pre-stop sleep must be at least 10 seconds for load balancer drain."
  }
}

# ── Task runners ──────────────────────────────────────────────────────────────

variable "n8n_task_runners_enabled" {
  description = "Enable task runner sidecars for isolated JavaScript and Python code execution"
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_task_runner_image_tag" {
  description = "Image tag for the task runner sidecar (`n8nio/runners`). When it is null (the default), the chart falls back to the n8n application image's tag, which is the right behavior as long as that tag is a published n8n version. Set this to the underlying n8n version when running a custom application image whose tag is not one (e.g. n8n_image_tag = \"2.27.4-mypackages\" together with n8n_task_runner_image_tag = \"2.27.4\"); otherwise the sidecar tries to pull `n8nio/runners:2.27.4-mypackages` and every main and worker pod stays in ImagePullBackOff. Reproduced on a live cluster, where kubelet reported `docker.io/n8nio/runners:<tag>: not found`; because the release waits for readiness, the apply blocks and then fails rather than completing with broken pods, and webhook processors are unaffected since they run no runner sidecar. The tag should match the n8n version in the application image, since the runner protocol is versioned with n8n. Ignored when n8n_task_runners_enabled = false."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_task_runner_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_task_runner_image_tag))
    error_message = "n8n_task_runner_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"2.27.4\"). Set to null to inherit the n8n application image's tag."
  }
}

variable "n8n_task_runner_cpu_request" {
  description = "CPU request for task runner sidecar containers (e.g. 200m, 500m)"
  type        = string
  default     = "200m"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_task_runner_cpu_request))
    error_message = "n8n_task_runner_cpu_request must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_task_runner_cpu_limit" {
  description = "CPU limit for task runner sidecar containers (e.g. 1, 2000m). Size this against Python workloads specifically: the Python runner executes each task in a forked child process (multiprocessing with the forkserver start method), so it is genuinely CPU-hungry in a way that \"it's only a sidecar\" does not suggest. On a Python Code-node benchmark this was the dominant of the two runner-throughput levers, worth 3.8x on its own against 2.2x for n8n_task_runner_max_concurrency, and 6.6x with both raised. JavaScript Code nodes on the same workload ran roughly 20x faster than Python ones and are not where this bites."
  type        = string
  default     = "1"

  validation {
    # The subset of Kubernetes' quantity grammar that scaling.tf's capacity
    # model can read. Restricting to it is the point: an unreadable quantity
    # makes local.n8n_cpu_requests_readable false, which collapses the peak-CPU
    # figure to zero and lets check.autoscaling_maxima_fit_node_capacity pass
    # vacuously. Kubernetes would still reject the value at apply, but only
    # after a plan that claimed the maxima fit.
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_task_runner_cpu_limit))
    error_message = "n8n_task_runner_cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"). Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted."
  }
}

variable "n8n_task_runner_memory_request" {
  description = "Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_task_runner_memory_request))
    error_message = "n8n_task_runner_memory_request must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_task_runner_memory_limit" {
  description = "Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", var.n8n_task_runner_memory_limit))
    error_message = "n8n_task_runner_memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes). \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }
}

variable "n8n_task_runner_auto_shutdown_timeout" {
  description = "Seconds of inactivity before an idle task-runner process exits. Maps to taskRunners.launcher.autoShutdownTimeout, which the chart renders into the task-runner SIDECAR's environment as N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT — not into the n8n containers, where the launcher does not run. Set to 0 to disable idle shutdown entirely: the runner process the launcher spawns checks `idleTimeout === 0` and skips arming its timer. The trade is a resident runner process against cold-start latency, and the cold start is not small — a Code node that takes ~17ms on a warm runner takes several seconds on a cold one, because the launcher has to start the Node or Python process before the task can run. Leave the default if runner memory matters more than first-request latency; set 0 for latency-sensitive workflows that fire intermittently."
  type        = number
  default     = 15
}

variable "n8n_task_runner_max_concurrency" {
  description = "Maximum number of tasks a single task-runner process will execute at once, wired to N8N_RUNNERS_MAX_CONCURRENCY through the env-overrides block of the n8n-task-runners.json ConfigMap the release mounts, which is what puts it in the runner process rather than in the n8n containers where nothing reads it. Applies to both the JavaScript and the Python runner. Leave null (the default) to keep each runner's own default, which are not the same number: 10 for JavaScript, 5 for Python. Raising it is the cheaper of the two runner-throughput levers, because more overlap costs no extra CPU request where n8n_task_runner_cpu_limit does, but it is the smaller one: on a Python Code-node benchmark, 5 to 15 alone gave 2.2x, the CPU limit alone gave 3.8x, and both together 6.6x. Note that runner saturation is invisible to queue-depth autoscaling — at 5 concurrent the Redis queue never grew while requests still took 17s, so KEDA saw nothing to scale. Per-pod runner capacity and pod count are not substitutes for each other."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_task_runner_max_concurrency == null || try(var.n8n_task_runner_max_concurrency >= 1, false)
    error_message = "n8n_task_runner_max_concurrency must be at least 1, or null to leave each runner on its own default. 0 would render a runner that accepts no tasks."
  }
}

variable "n8n_task_runner_request_timeout" {
  description = "Seconds n8n waits for a task runner to accept a Code node task. Wired to the N8N_RUNNERS_TASK_REQUEST_TIMEOUT env var on the main pod. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar). This governs the wait for a runner to pick the task up; n8n_task_runner_timeout governs how long the task may then run."
  type        = number
  default     = 300
}

variable "n8n_task_runner_python_enabled" {
  description = "Enable the native Python runner (beta). Required for Python code execution in workflows."
  type        = bool
  default     = true
}

variable "n8n_python_stdlib_allow" {
  description = "Comma-separated stdlib modules the Python task runner may import. Chart default is empty (blocks everything, including basic modules like time / math). '*' allows all stdlib. Renders into the n8n-task-runners.json ConfigMap the release mounts."
  type        = string
  default     = "*"
  nullable    = false
}

variable "n8n_python_external_allow" {
  description = "Comma-separated PyPI packages the Python task runner may import. Empty (the default) restricts imports to stdlib only."
  type        = string
  default     = ""
  nullable    = false
}

variable "n8n_js_builtin_allow" {
  description = "Node.js builtins allowed inside Code (JavaScript) nodes. Chart default: 'crypto'."
  type        = string
  default     = "crypto"
  nullable    = false
}

variable "n8n_js_external_allow" {
  description = "External npm modules allowed inside Code (JavaScript) nodes. Chart default: 'moment'."
  type        = string
  default     = "moment"
  nullable    = false
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────

variable "postgres_backend" {
  description = "Which Postgres backend n8n connects to. \"cnpg\" (the default) deploys an in-cluster CloudNativePG Cluster CR (postgres_cnpg.tf) and requires the CNPG operator installed cluster-wide; the operator generates the credentials into its own \"<cluster>-app\" Secret, so no password input is needed. \"external\" is the bring-your-own path: no module-managed database, caller supplies db_host + db_password (or db_password_secret_ref)."
  type        = string
  default     = "cnpg"
  nullable    = false

  validation {
    condition     = contains(["cnpg", "external"], var.postgres_backend)
    error_message = "postgres_backend must be one of: cnpg, external."
  }
}

variable "cnpg_instances" {
  description = "Number of CNPG Postgres instances (primary + replicas). Only used when postgres_backend = \"cnpg\"."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.cnpg_instances >= 1
    error_message = "cnpg_instances must be at least 1."
  }
}

variable "cnpg_storage_size" {
  description = "PVC size for each CNPG Postgres instance. Only used when postgres_backend = \"cnpg\"."
  type        = string
  default     = "10Gi"
  nullable    = false
}

variable "cnpg_storage_class" {
  description = "StorageClass for CNPG PVCs. Empty string uses the cluster default. Only used when postgres_backend = \"cnpg\"."
  type        = string
  default     = ""
  nullable    = false
}

variable "cnpg_postgres_image_tag" {
  description = "Postgres image tag for CNPG (ghcr.io/cloudnative-pg/postgresql:<tag>). Only used when postgres_backend = \"cnpg\"."
  type        = string
  default     = "16"
  nullable    = false
}

variable "cnpg_lan_expose" {
  description = "Expose the CloudNativePG read-write endpoint on a LoadBalancer address so clients outside the cluster (Grafana, a migration tool) can reach it without kubectl port-forward. Ignored when postgres_backend != \"cnpg\". Set enabled = false (the default) to skip. Requesting a specific address is allocator-specific: ip is rendered as the io.cilium/lb-ipam-ips annotation, which only Cilium LB-IPAM reads, so on MetalLB, kube-vip or a cloud controller set annotations instead with whatever key that allocator honours (metallb.universe.tf/loadBalancerIPs, kube-vip.io/loadbalancerIPs, and so on) and leave ip empty. Setting neither still creates the Service and lets the allocator pick an address. Nothing authenticates in front of this Service: PostgreSQL still demands its password, but the endpoint is reachable by anything on that network, so keep it on a trusted one."
  type = object({
    enabled      = optional(bool, false)
    ip           = optional(string, "")
    service_name = optional(string, "")
    annotations  = optional(map(string), {})
  })
  default  = {}
  nullable = false
}

variable "cnpg_database_name" {
  description = "Postgres database name CloudNativePG bootstraps for n8n. Only used when postgres_backend = \"cnpg\". Changing it on a live deployment does not rename anything: the operator bootstraps the database once, at cluster creation."
  type        = string
  default     = "n8n"
  nullable    = false
}

variable "cnpg_database_owner" {
  description = "Postgres role CNPG initdb creates as the database owner and that n8n connects as. Only used when postgres_backend = \"cnpg\"."
  type        = string
  default     = "n8n"
  nullable    = false
}

variable "cnpg_max_connections" {
  description = "max_connections on the CNPG Postgres cluster. Only used when postgres_backend = \"cnpg\". The default of 200 is well above Postgres's own 100 because a queue-mode deployment's connection count is pod count times db_postgresdb_pool_size, and pod count belongs to an autoscaler. Every backend costs memory whether it is busy or not, so raising this is not free: it moves the wall to the next scale-up rather than removing it, which is what cnpg_pooler_enabled does instead. This value is also the budget cnpg_pooler_pool_size is validated against, so the two cannot drift."
  type        = number
  default     = 200
  nullable    = false

  validation {
    condition     = var.cnpg_max_connections == floor(var.cnpg_max_connections) && var.cnpg_max_connections >= 25 && var.cnpg_max_connections <= 262143
    error_message = "cnpg_max_connections must be a whole number between 25 and 262143. Below 25, Postgres's own superuser_reserved_connections and CNPG's instance manager leave too little for n8n to start reliably. Above 262143 is past what Postgres accepts for max_connections at all, and the value goes straight into the Cluster spec, so the instance refuses to start rather than the plan refusing the number. Long before either bound the limit stops being the useful lever: every backend costs memory whether it is busy or not, which is what cnpg_pooler_enabled exists to avoid needing."
  }
}

variable "cnpg_pooler_enabled" {
  description = "Whether to put a PgBouncer connection pooler in front of the CNPG cluster and point n8n at it instead of the rw Service. Only used when postgres_backend = \"cnpg\". Off by default: a pooler is a second thing to run, and a deployment that never scales its workers past a handful of pods does not need one. Turn it on when pod count starts to drive the connection budget. Each n8n pod holds db_postgresdb_pool_size connections, so a worker tier autoscaling to 16 alongside webhook processors can demand several hundred against a max_connections that is 100 or 200 by default; past that limit new pods fail to initialise their pool and CrashLoop rather than degrading. The pooler breaks that coupling: pods connect to PgBouncer, PgBouncer holds cnpg_pooler_pool_size real connections per instance, and pod count stops being a term in the arithmetic. Enabling this requires db_postgresdb_ssl_enabled = false, and the module refuses the combination at plan time: PgBouncer serves its clients in plaintext and encrypts its own leg to Postgres, so leaving TLS on has n8n negotiate against a listener that does not speak it."
  type        = bool
  default     = false
  nullable    = false

  validation {
    # The CNPG Pooler serves its clients in plaintext and terminates TLS on its
    # own upstream leg to Postgres. Leaving db_postgresdb_ssl_enabled true has
    # n8n try to negotiate TLS against a listener that does not speak it, and
    # the failure surfaces as a connection error with nothing naming the
    # pooler. Refuse the combination at plan time rather than at 3am.
    condition     = !var.cnpg_pooler_enabled || var.db_postgresdb_ssl_enabled == false
    error_message = "cnpg_pooler_enabled = true requires db_postgresdb_ssl_enabled = false: the CNPG Pooler serves clients in plaintext and encrypts its own connection to Postgres."
  }

  validation {
    condition     = !var.cnpg_pooler_enabled || var.postgres_backend == "cnpg"
    error_message = "cnpg_pooler_enabled = true requires postgres_backend = \"cnpg\": the Pooler is a CloudNativePG resource and attaches to the Cluster this module creates. For an external Postgres, point db_host at a pooler you run yourself."
  }
}

variable "cnpg_pooler_instances" {
  description = "PgBouncer replicas. Two by default so a pooler restart does not take the database path down with it. Note this does not make the database highly available: cnpg_instances governs that separately, and one Postgres behind two poolers still has one Postgres. Raising this multiplies the real connections Postgres sees, because each instance holds its own pool of cnpg_pooler_pool_size."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.cnpg_pooler_instances == floor(var.cnpg_pooler_instances) && var.cnpg_pooler_instances >= 1
    error_message = "cnpg_pooler_instances must be a whole number of at least 1."
  }
}

variable "cnpg_pooler_mode" {
  description = "PgBouncer pool mode. \"transaction\" (the default) returns the server connection after each transaction, which is the only mode that decouples client count from server connections and therefore the only one that solves the problem this pooler exists for. \"session\" holds a server connection for the life of the client session; because n8n's TypeORM pool is long-lived, that reproduces the original connection count and changes nothing. Transaction mode costs session-scoped state: server-side named prepared statements, LISTEN/NOTIFY, session-level advisory locks and SET. n8n in queue mode uses Redis for queueing and leader election rather than Postgres LISTEN, and node-postgres issues unnamed portals by default, so the usual paths are unaffected."
  type        = string
  default     = "transaction"
  nullable    = false

  validation {
    condition     = contains(["transaction", "session"], var.cnpg_pooler_mode)
    error_message = "cnpg_pooler_mode must be one of: transaction, session. PgBouncer also offers \"statement\", which forbids multi-statement transactions; n8n runs its TypeORM migrations in one, so that mode cannot boot the release and is not offered here."
  }
}

variable "cnpg_pooler_pool_size" {
  description = "Real Postgres connections each PgBouncer instance holds open, per user/database pair (PgBouncer's default_pool_size). This, multiplied by cnpg_pooler_instances, is what Postgres actually sees, and it replaces pod count as the number to check against max_connections. The default of 25 across 2 instances is 50 connections, comfortably inside the 100 a stock Postgres allows once superuser_reserved_connections is deducted."
  type        = number
  default     = 25
  nullable    = false

  validation {
    condition     = var.cnpg_pooler_pool_size == floor(var.cnpg_pooler_pool_size) && var.cnpg_pooler_pool_size >= 1
    error_message = "cnpg_pooler_pool_size must be a whole number of at least 1."
  }

  validation {
    # The pooler exists to keep pod count out of the connection budget, and it
    # does that by making cnpg_pooler_pool_size x cnpg_pooler_instances the
    # whole of what Postgres sees. That product is therefore the number to
    # check, and nothing else checks it: an otherwise valid plan can size the
    # pool past the Cluster's own limit and recreate the exhaustion the pooler
    # was added to remove, one hop upstream and harder to read.
    #
    # Three quarters of cnpg_max_connections rather than a literal, so the cap
    # follows the Cluster's own limit instead of restating it from another
    # file. At the default 200 that is 150, which leaves roughly 47 once
    # Postgres reserves 3 for superusers: enough for CNPG's instance manager on
    # each pod, streaming replication when cnpg_instances > 1, a metrics
    # scraper, and whatever maintenance connects through postgres_direct_host.
    #
    # Two numbers, and the one that matters is the worse one. Sized to the cap,
    # 200 - 150 leaves 50, or 47 once Postgres reserves 3 for superusers; at
    # the default pool of 25 x 2 it is 200 - 50 - 3 = 147. The validation has
    # to hold at the cap, so 47 is the figure it is chosen against. Measured
    # overhead on a single-instance cluster was 11-13, so even the worse number
    # is deliberately generous, and a caller who genuinely needs a larger pool
    # raises cnpg_max_connections and gets the headroom with it.
    condition     = !var.cnpg_pooler_enabled || var.cnpg_pooler_pool_size * var.cnpg_pooler_instances <= floor(var.cnpg_max_connections * 0.75)
    error_message = "cnpg_pooler_pool_size x cnpg_pooler_instances is what Postgres actually sees, and it must stay at or below three quarters of cnpg_max_connections. CNPG's own instance manager, replication and metrics connections come out of the rest, along with the 3 Postgres reserves for superusers. Lower the pool size or the instance count, or raise cnpg_max_connections."
  }
}

variable "cnpg_pooler_max_client_conn" {
  description = "Client connections each PgBouncer instance will accept (PgBouncer's max_client_conn). These are cheap, unlike server connections, so this should sit well above what any plausible scale-up asks for: pods x db_postgresdb_pool_size. Running out reproduces the exact failure the pooler was added to remove, with the queue moved one hop closer to the caller."
  type        = number
  default     = 500
  nullable    = false

  validation {
    condition     = var.cnpg_pooler_max_client_conn == floor(var.cnpg_pooler_max_client_conn) && var.cnpg_pooler_max_client_conn >= 1
    error_message = "cnpg_pooler_max_client_conn must be a whole number of at least 1."
  }
}

variable "db_host" {
  description = "External database host. Required when postgres_backend = 'external', ignored otherwise. Any PostgreSQL endpoint reachable from the cluster. Pointing this at a host that already runs an n8n deployment from this module shares the exact database and tables, not merely the server, which is the supported 'migrate to a new deployment, keep the same database' pattern (stop the old writer first, then cut over), not concurrent multi-tenant sharing, which this module does not support."
  type        = string
  default     = null

  validation {
    # On the cnpg path the module derives the Postgres host from the CNPG rw
    # Service DNS (local.k8s_pg_host in locals.tf); only the external path
    # needs the caller to supply one.
    condition     = var.postgres_backend != "external" || var.db_host != null
    error_message = "db_host is required when postgres_backend = \"external\"."
  }
}

variable "db_port" {
  description = "Port the external database listens on. External path only: on the cnpg path the operator's rw Service always listens on 5432. Defaults to the PostgreSQL default, so a caller running on it need not set this."
  type        = number
  default     = 5432
  nullable    = false

  validation {
    condition     = var.db_port == floor(var.db_port) && var.db_port >= 1 && var.db_port <= 65535
    error_message = "db_port must be a whole TCP port between 1 and 65535."
  }
}

variable "db_name" {
  description = "Database n8n connects to on the external server. External path only: the cnpg path bootstraps its database from cnpg_database_name, which this deliberately does not reuse: the two are different servers owned by different parties, and one input governing both made a variable documented as CNPG-only silently decide an external deployment's database. The default matches cnpg_database_name's, so the two paths behave alike until a caller needs otherwise."
  type        = string
  default     = "n8n"
  nullable    = false

  validation {
    condition     = length(var.db_name) > 0
    error_message = "db_name must not be empty; PostgreSQL has no unnamed database to fall back to."
  }
}

variable "db_user" {
  description = "Role n8n authenticates as against the external server, paired with db_password. External path only; the cnpg path uses cnpg_database_owner, the role CNPG's initdb creates. The module does not create this role: it must already exist and own db_name, or n8n's first migration fails on permissions rather than on connectivity."
  type        = string
  default     = "n8n"
  nullable    = false

  validation {
    condition     = length(var.db_user) > 0
    error_message = "db_user must not be empty; PostgreSQL requires a role name to authenticate."
  }
}

variable "db_password" {
  description = "Password for the external database specified by db_host. Required when postgres_backend = \"external\", unless db_password_secret_ref supplies it instead; see that variable, which owns the combined validation to avoid a validation dependency cycle between the two. Ignored on the cnpg path, where the operator generates the credentials into its own Secret."
  type        = string
  default     = null
  sensitive   = true
}

variable "db_password_secret_ref" {
  description = "Existing Kubernetes Secret carrying the external database password, instead of supplying the value through db_password. name is the Secret's name in var.k8s_namespace; key defaults to \"password\", matching the chart's database.passwordSecret.key default. External-database path only: on the cnpg path CloudNativePG owns the credentials outright. Setting this gates kubernetes_secret.n8n_db to zero and points the chart's database.passwordSecret at your Secret instead. Setting it alongside db_password is rejected at plan time, and so is setting neither on the external path; both checks live here rather than split across the two variables, which would form a validation dependency cycle. The module does not verify that the named Secret exists or carries this key: a typo surfaces only as a pod stuck in CreateContainerConfigError, not as a Terraform error, because reading the Secret to check would put the password back into Terraform state, which defeats the reason this input exists."
  type = object({
    name = string
    key  = optional(string)
  })
  default = null

  validation {
    condition     = var.db_password_secret_ref == null || var.db_password == null
    error_message = "Both db_password and db_password_secret_ref are set. Only one may supply the database password: remove db_password to consume the referenced Secret, or remove db_password_secret_ref to keep passing the value directly."
  }

  validation {
    # On the cnpg path the CNPG operator writes the app-user credentials into
    # "<cluster>-app" (locals.tf), so neither db_password nor
    # db_password_secret_ref is required from the caller.
    condition     = var.postgres_backend != "external" || var.db_password_secret_ref != null || var.db_password != null
    error_message = "db_password or db_password_secret_ref is required when postgres_backend = \"external\"."
  }
}

variable "db_postgresdb_pool_size" {
  description = "Number of TypeORM connection pool slots per n8n pod. Each pod holds this many persistent PostgreSQL connections. Rule of thumb: pool_size >= worker_concurrency / 4. With PgBouncer in transaction mode a lower value (5) is sufficient; without PgBouncer use a value matching concurrency (10-20)."
  type        = number
  default     = 10

  validation {
    condition     = var.db_postgresdb_pool_size >= 1
    error_message = "db_postgresdb_pool_size must be at least 1."
  }
}

variable "db_postgresdb_ssl_enabled" {
  description = "Whether n8n connects to the database over TLS. True (the default) also sets DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false, because an in-cluster CloudNativePG cluster serves a certificate signed by an authority Node.js has no reason to trust, and the traffic never leaves the cluster network. Set false when n8n connects through a connection pooler (e.g. PgBouncer) that terminates TLS on its own upstream leg. Rendered explicitly either way rather than omitted, so the deployed value states the choice instead of falling back to n8n's own default."
  type        = bool
  default     = true
}

# ── Redis / queue ─────────────────────────────────────────────────────────────

variable "redis_backend" {
  description = "Which Redis-wire-compatible backend n8n uses for the Bull queue. \"valkey\" (the default) deploys the valkey-io/valkey-helm chart in-cluster (redis_valkey.tf). Valkey rather than Redis because Redis Ltd relicensed Redis at 7.4 under RSALv2/SSPLv1; Valkey is the Linux Foundation fork that stayed BSD and speaks the same wire protocol n8n's Bull queue uses. \"external\" is the bring-your-own path: no module-managed backend, caller supplies redis_host."
  type        = string
  default     = "valkey"
  nullable    = false

  validation {
    condition     = contains(["valkey", "external"], var.redis_backend)
    error_message = "redis_backend must be one of: valkey, external."
  }
}

variable "valkey_storage_size" {
  description = "PVC size for the Valkey standalone instance. Only used when redis_backend = \"valkey\"."
  type        = string
  default     = "8Gi"
  nullable    = false
}

variable "valkey_storage_class" {
  description = "StorageClass for the Valkey PVC. Empty string uses the cluster default. Only used when redis_backend = \"valkey\"."
  type        = string
  default     = ""
  nullable    = false
}

variable "metrics_lan_expose" {
  description = "Expose n8n-main port 5678 on a LoadBalancer address so a Prometheus outside the cluster can scrape /metrics without k8s-API-proxy setup. Requires n8n_metrics_enabled = true to serve useful data. Requesting a specific address is allocator-specific, exactly as for cnpg_lan_expose: ip renders the io.cilium/lb-ipam-ips annotation that only Cilium LB-IPAM reads, and annotations carries whatever key another allocator honours. n8n's metrics endpoint is unauthenticated by design, so this belongs on a trusted network or not at all."
  # ponytail: this reads like an Observability input, but it lives here next to
  # cnpg_lan_expose, its structural twin, so the two LAN-exposure objects
  # can be compared without jumping banners.
  type = object({
    enabled      = optional(bool, false)
    ip           = optional(string, "")
    service_name = optional(string, "")
    annotations  = optional(map(string), {})
  })
  default  = {}
  nullable = false
}

variable "n8n_redis_timeout_threshold" {
  description = "Milliseconds n8n keeps trying to reach Redis before it gives up and exits the process, wired to QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD. Leave null (the default) to use the chart's 10000, which is n8n's own default. Raise it if you would rather n8n rode out a brief queue outage than restarted: a failover on an external endpoint, or a Valkey pod reschedule. Pick the value deliberately, because the budget is coarser than it looks: n8n does not set ioredis's connectTimeout, so it stays at 10s, and a connect to an endpoint that is up but not serving hangs for that full 10s before failing. Each failed attempt therefore spends about 11.1s of this budget, making the effective values roughly 11.1s, 33.2s and 66.4s for settings of 10s, 30s and 60s. 30000 was measured failing by 1.1 seconds against a 25 second outage; 60000 survived every case measured, with about 20 seconds of headroom against a 48 second one. That is a small number of observed events, so treat it as a good default rather than a guarantee."
  type        = number
  default     = null

  # Below about 2s a single connect timeout (10s, see above) blows the entire
  # budget before ioredis has re-resolved DNS even once, so the process exits on
  # any blip rather than reconnecting. The upper bound is a typo guard: values
  # this large mean a genuinely dead Redis goes unnoticed for many minutes.
  validation {
    condition     = var.n8n_redis_timeout_threshold == null || try(var.n8n_redis_timeout_threshold >= 2000 && var.n8n_redis_timeout_threshold <= 600000, false)
    error_message = "n8n_redis_timeout_threshold must be between 2000 and 600000 milliseconds, or null to leave the chart default (10000) in place."
  }

  validation {
    condition     = var.n8n_redis_timeout_threshold == null || try(var.n8n_redis_timeout_threshold == floor(var.n8n_redis_timeout_threshold), false)
    error_message = "n8n_redis_timeout_threshold must be a whole number of milliseconds."
  }
}

variable "redis_transit_encryption_enabled" {
  description = "Declares that the Redis endpoint at redis_host speaks TLS, and configures n8n and the KEDA scaler accordingly. External path only: this is an assertion about an endpoint the module does not manage, not something it provisions: setting it against a plaintext endpoint is a connection failure rather than a security hole, and leaving it false against a TLS-only endpoint fails the same way in reverse. The module generates no credential for a Redis it does not own; supply one via redis_auth_token or redis_auth_token_secret_ref if the endpoint requires AUTH. Worker queue-depth autoscaling picks up TLS, and the AUTH token when active, through KEDA's Redis trigger."
  type        = bool
  default     = false

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise propagate null into local.redis_tls_active and the other
  # boolean expressions in locals.tf that key off this variable, and die with
  # an opaque "Invalid value for operand". See AGENTS.md on nullable.
  nullable = false
}

variable "redis_host" {
  description = "Redis-compatible endpoint n8n and KEDA connect to. Required when redis_backend = 'external', ignored otherwise; on the valkey path the module derives the in-cluster Service DNS name. Must be reachable from the cluster on redis_port. AUTH (redis_auth_token / redis_auth_token_secret_ref) and TLS (redis_transit_encryption_enabled) are both optional, matching what the endpoint actually requires: leave them unset if it accepts unauthenticated, non-TLS connections. For a replicated endpoint, use the name that follows the primary across a failover rather than a node address."
  type        = string
  default     = null

  # Blank is rejected as well as null. An empty string satisfies "is set" but
  # reaches n8n and KEDA as an empty host, so the apply succeeds and the queue
  # has nowhere to connect: the same succeeds-then-fails-at-runtime shape the
  # check blocks in redis.tf exist to prevent.
  #
  # Written as nested ternaries rather than `||` and `&&` because Terraform 1.9,
  # which CI pins, does not short-circuit either operator. trimspace(null) is a
  # hard error, so the null test has to gate the blank test structurally rather
  # than by evaluation order. See AGENTS.md.
  validation {
    # On the valkey path the module derives the Redis host from the Valkey
    # Service DNS (local.k8s_redis_host in locals.tf) rather than reading
    # var.redis_host, so only the external path needs one supplied.
    condition = var.redis_backend != "external" ? true : (
      var.redis_host != null ? trimspace(var.redis_host) != "" : false
    )
    error_message = "redis_host is required, and must not be blank, when redis_backend = \"external\"."
  }

  # A padded host such as " redis.internal.example.com " survives the blank test
  # above, because that one only inspects the trimmed value. The module consumes
  # the RAW value: local.redis_host feeds n8n's host field and is interpolated
  # into KEDA's "${local.redis_host}:${local.redis_port}", so the padding is
  # emitted literally and the address never resolves. Rejected rather than
  # trimmed in locals.tf, so that the value the caller sets is the value that
  # gets deployed and a stray space is corrected at its source instead of being
  # silently swallowed. Split from the blank test rather than folded into it so
  # the two mistakes get their own error message.
  #
  # null passes here; the validation above owns that case.
  validation {
    condition     = var.redis_host != null ? var.redis_host == trimspace(var.redis_host) : true
    error_message = "redis_host must not have leading or trailing whitespace, because the module wires it into n8n and KEDA verbatim."
  }
}

variable "redis_port" {
  description = "Port of the external Redis specified by redis_host. Ignored when redis_backend = \"valkey\", where the in-cluster Service listens on 6379."
  type        = number
  default     = 6379

  # null is not meaningful here: a caller writing `x = null` in a module block
  # would otherwise reach `null >= 1` in the validation below and die with an
  # opaque comparison error instead of a clean message. See AGENTS.md.
  nullable = false

  validation {
    condition     = var.redis_port >= 1 && var.redis_port <= 65535
    error_message = "redis_port must be a TCP port between 1 and 65535."
  }

  validation {
    condition     = var.redis_port == floor(var.redis_port)
    error_message = "redis_port must be a whole number."
  }
}

variable "redis_auth_token" {
  description = "AUTH token for an external Redis supplied via redis_host. Optional: leave null if that endpoint accepts unauthenticated connections, or supply the token through redis_auth_token_secret_ref instead. Ignored on the valkey path, where the chart manages its own credential. Wired to n8n and KEDA as a Kubernetes Secret referenced by name (QUEUE_BULL_REDIS_PASSWORD), never inlined into the Helm release values or the KEDA ScaledObject manifest."
  type        = string
  sensitive   = true
  default     = null
}

variable "redis_auth_token_secret_ref" {
  description = "Existing Kubernetes Secret carrying the external Redis AUTH token, instead of supplying the value through redis_auth_token. name is the Secret's name in var.k8s_namespace; key defaults to \"password\", matching the chart's redis.passwordSecret.key default. External path only, and optional there exactly as redis_auth_token is: leave both null if the endpoint accepts unauthenticated connections. Points the chart's redis.passwordSecret, and KEDA's queue-depth trigger, at your Secret. Because the module never reads the value inside it, it cannot roll the pods when that value changes; rolling them after you rotate the Secret's contents is your responsibility. Setting this alongside redis_auth_token is rejected at plan time. The module does not verify that the named Secret exists or carries this key."
  type = object({
    name = string
    key  = optional(string)
  })
  default = null

  validation {
    condition     = var.redis_auth_token_secret_ref == null || var.redis_auth_token == null
    error_message = "Both redis_auth_token and redis_auth_token_secret_ref are set. Only one may supply the Redis AUTH token: remove redis_auth_token to consume the referenced Secret, or remove redis_auth_token_secret_ref to keep passing the value directly."
  }
}

variable "redis_username" {
  description = "ACL username for an external Redis supplied via redis_host. Leave null (the default) and both n8n and KEDA authenticate as Redis's default user, which is what most self-hosted setups use. Set it when the endpoint authenticates against a named Redis 6+ ACL user, in which case redis_auth_token carries that user's password. Reaches n8n as QUEUE_BULL_REDIS_USERNAME (n8n's own config marks it \"Redis 6.0 or higher required\") and reaches the KEDA worker trigger as the redis scaler's username field, so autoscaling authenticates as the same user n8n does. A username is not treated as a secret the way the token is: it is a plain value in the release and in the ScaledObject, which is also what lets KEDA read it without resolving anything. The ACL user must be able to run the commands BullMQ uses against the bull:* keyspace, and must be able to run LLEN on bull:jobs:wait and bull:jobs:active for autoscaling to work; an ACL that authenticates but cannot read those keys leaves the scaler reporting <unknown> and the worker count frozen."
  type        = string
  default     = null

  # Blank is rejected as well as null, for the same reason redis_host rejects it:
  # an empty string satisfies "is set" and then reaches n8n and KEDA as an empty
  # username, which authenticates as nobody. Nested ternaries rather than `&&`,
  # per AGENTS.md's consistency rule for guard-style conditions: the null test
  # gates the blank test structurally (trimspace(null) is a hard error) rather
  # than relying on short-circuit evaluation.
  validation {
    condition     = var.redis_username != null ? trimspace(var.redis_username) != "" : true
    error_message = "redis_username must not be blank. Leave it null to authenticate as Redis's default user."
  }

  # Redis ACL usernames cannot contain whitespace, so any is a copy-paste
  # artifact rather than a name. Rejected rather than trimmed, so the value the
  # caller sets is the value that gets deployed.
  validation {
    condition     = var.redis_username != null ? can(regex("^[^[:space:]]+$", var.redis_username)) : true
    error_message = "redis_username must not contain whitespace: Redis ACL usernames cannot, and the module wires this value into n8n and KEDA verbatim."
  }
}

variable "redis_key_prefix" {
  description = "Prefix for every Redis key this n8n deployment uses: both n8n's own key prefix (N8N_REDIS_KEY_PREFIX, n8n's default 'n8n') and the Bull queue's prefix (QUEUE_BULL_PREFIX, n8n's default 'bull'), which this module sets together so one input keeps them in sync. Leave null (the default) to keep n8n's own defaults. Set it to a value unique per deployment whenever two or more n8n deployments share ONE Redis endpoint, which the module cannot detect or prevent: without distinct prefixes, n8n's scaling-mode pub/sub command channel ('<prefix>:n8n.commands') is not scoped per deployment, so one deployment's workflow-activation broadcast reaches every other deployment on that endpoint, each of which looks the workflow up in its own database, fails, and publishes an error back onto the same shared channel. Confirmed live, not theoretical. An in-cluster Valkey release is already dedicated to one deployment, so this has nothing to fix there. Also updates the KEDA ScaledObject's listName metadata to '<prefix>:jobs:wait' / '<prefix>:jobs:active': leaving those at the literal 'bull:jobs:*' while Bull writes under a different prefix leaves KEDA reading an empty list and queue-depth autoscaling frozen at zero."
  type        = string
  default     = null

  validation {
    condition     = var.redis_key_prefix != null ? trimspace(var.redis_key_prefix) != "" : true
    error_message = "redis_key_prefix must not be blank. Leave it null to keep n8n's own default prefixes."
  }

  # n8n and Bull both use ":" as their own internal key-segment delimiter
  # (e.g. "<prefix>:n8n.commands", "<prefix>:jobs:wait"), so a prefix that
  # itself contains ":", whitespace, or other Redis key-pattern metacharacters
  # would produce a technically-valid but confusing key namespace. Restricted
  # to what both n8n's own default ("n8n") and Bull's ("bull") already look
  # like: alphanumerics, hyphens and underscores.
  validation {
    condition     = var.redis_key_prefix != null ? can(regex("^[A-Za-z0-9_-]+$", var.redis_key_prefix)) : true
    error_message = "redis_key_prefix must contain only letters, digits, hyphens and underscores: it becomes a literal Redis key segment (e.g. \"<prefix>:n8n.commands\", \"<prefix>:jobs:wait\"), and \":\" or whitespace in it would produce a confusing or malformed key namespace."
  }
}

# ── HPA: main pods ────────────────────────────────────────────────────────────

# ── HPA: webhook processor pods ───────────────────────────────────────────────

variable "n8n_webhook_hpa_enabled" {
  description = "When true (the default), the module creates kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook, a CPU-based HPA for the webhook processor deployment. The n8n Helm chart skips creating its own webhook HPA whenever keda.enabled is true, which this module always sets, so this module-managed HPA is otherwise the only thing that scales webhook processors at all. Set to false to bring your own autoscaling policy (e.g. a VPA, a custom-metrics HPA, or one managed outside Terraform) for the n8n-webhook-processor Deployment instead. With this false and nothing else targeting that Deployment, it stays fixed at n8n_webhook_hpa_min_replicas: the chart renders webhookProcessor.replicaCount from that same variable unconditionally, so disabling this HPA does not leave the deployment without a replica count, only without anything that changes it."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_webhook_hpa_min_replicas" {
  description = "Minimum replicas for n8n webhook processor pods. HPA will not scale below this. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back. Webhook processors take production webhook traffic, so a warm floor is what keeps a traffic ramp from queueing behind pod startup."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas <= var.n8n_webhook_hpa_max_replicas
    error_message = "n8n_webhook_hpa_min_replicas must not exceed n8n_webhook_hpa_max_replicas; Kubernetes rejects an HPA whose minReplicas is above its maxReplicas."
  }

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas == floor(var.n8n_webhook_hpa_min_replicas) && var.n8n_webhook_hpa_min_replicas >= 1
    error_message = "n8n_webhook_hpa_min_replicas must be a whole number of replicas, 1 or greater. Kubernetes rejects an HPA whose minReplicas is below 1 (scale-to-zero needs the HPAScaleToZero feature gate, which is alpha and off by default)."
  }
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Maximum replicas for n8n webhook processor pods. HPA will not scale above this. The default of 8 is sized to the default node group (node_max × node_instance_type), alongside the main and worker ceilings. Webhook processors are the cheapest pod family to scale (no task runner sidecar, 300m by default), so this is usually the first ceiling to raise once node_max goes up. See n8n_main_hpa_max_replicas and README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 8
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_max_replicas == floor(var.n8n_webhook_hpa_max_replicas) && var.n8n_webhook_hpa_max_replicas >= 1
    error_message = "n8n_webhook_hpa_max_replicas must be a whole number of replicas, 1 or greater. Kubernetes rejects an HPA whose maxReplicas is below 1, and a fractional value is not a replica count."
  }
}

variable "n8n_webhook_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n webhook pods."
  type        = number
  default     = 65

  validation {
    condition     = var.n8n_webhook_hpa_cpu_threshold == floor(var.n8n_webhook_hpa_cpu_threshold) && var.n8n_webhook_hpa_cpu_threshold >= 1 && var.n8n_webhook_hpa_cpu_threshold <= 100
    error_message = "n8n_webhook_hpa_cpu_threshold is a target average CPU utilization percentage, so it must be a whole number between 1 and 100. Values above 100 are accepted by Kubernetes but mean the HPA only scales once pods exceed their own CPU request, which is not what this input is for."
  }
}

variable "n8n_webhook_hpa_scale_up_stabilization_window_seconds" {
  description = "Seconds the webhook processor HPA looks back before scaling up, via the HPA's behavior.scaleUp.stabilizationWindowSeconds. Kubernetes' own default is 0 (scale up immediately), which this module preserves by default. A short CPU spike right after a pod boots (e.g. from N8N_REINSTALL_MISSING_PACKAGES=true reinstalling community packages, see n8n_reinstall_missing_packages) can read as sustained high utilization and trigger a scale-up that a slightly longer window would absorb. Raise this (e.g. to 300) to require CPU to stay above threshold for that long before adding pods. Must be between 0 and 3600, the range the Kubernetes API enforces."
  type        = number
  default     = 0

  validation {
    condition     = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds >= 0 && var.n8n_webhook_hpa_scale_up_stabilization_window_seconds <= 3600
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds must be between 0 and 3600 seconds, the range the Kubernetes HPA API enforces."
  }
}

# ── Observability ─────────────────────────────────────────────────────────────

variable "n8n_metrics_enabled" {
  description = "Enable n8n's built-in Prometheus metrics endpoint. When true, the module appends three env vars to the n8n Helm release's config.extraEnv, which the chart applies to every n8n container (main, worker, webhook processor): N8N_METRICS=true, N8N_METRICS_INCLUDE_QUEUE_METRICS=true and N8N_METRICS_INCLUDE_CACHE_METRICS=true. The latter two are on because queue and cache depth are the numbers that make a queue-mode deployment legible. All three are reserved names, so set them through this input rather than n8n_extra_env. Note that the endpoint being on is not the same as the metrics being on: n8n gates its metric families behind separate N8N_METRICS_INCLUDE_* toggles and most default to false, so with only these three set the endpoint answers while reporting nothing about webhooks, the scheduler, the DB pool, SSRF blocks or DNS cache. Those remaining groups stay the caller's to set through n8n_extra_env; on n8n 2.34.6 turning all of them on took one instance from 66 to 127 distinct metric names, for roughly 1,700 extra series. n8n exposes /metrics on its existing HTTP port (5678), the same port and service the chart already publishes for the UI/API. The n8n Helm chart at the currently pinned version (see n8n_chart_version) exposes no top-level metrics / serviceMonitor block of its own, so this toggle is intentionally env-var-only. Scrape configuration (Prometheus scrape annotations or a ServiceMonitor CR) is left to the caller's monitoring stack; in practice the main pod's Service is the meaningful scrape target. Defaults to false; when false the env var is omitted entirely so n8n's own defaults apply."
  type        = bool
  default     = false
}

variable "n8n_templates_enabled" {
  description = "Enable n8n's workflow templates and template suggestions. Maps to N8N_TEMPLATES_ENABLED. When false, sets N8N_TEMPLATES_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default. Note that explicitly setting true emits no env var (n8n's default already applies). Set to false to hide the templates library, e.g. when enforcing curated internal workflows."
  type        = bool
  default     = true
}

variable "n8n_personalization_enabled" {
  description = "Whether n8n asks users personalization survey questions and tailors content/recommendations based on the answers. Maps to N8N_PERSONALIZATION_ENABLED. When false, sets N8N_PERSONALIZATION_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default. Note that explicitly setting true emits no env var (n8n's default already applies). Set to false to skip the personalization survey, e.g. on shared or ephemeral instances."
  type        = bool
  default     = true
}

# ── Community packages ────────────────────────────────────────────────────────

variable "n8n_reinstall_missing_packages" {
  description = "Reinstall community packages that are recorded in the database but missing from a pod's local filesystem at startup. Maps to N8N_REINSTALL_MISSING_PACKAGES. n8n stores installed community packages on the pod's filesystem, which is ephemeral, so a rescheduled or newly scaled-up worker comes up without them and nodes installed through the UI fail to load on that pod. Enabling this makes every pod (main, worker and webhook processor) reinstall the recorded packages on boot, which is what lets community nodes work reliably in queue mode. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. When true, size the webhook processor above this module's defaults: every pod runs npm installs at boot and n8n rebroadcasts installs to all pods over pubsub, so a rolling restart makes every webhook pod install repeatedly at once. Against low CPU and memory this causes HPA thrash and OOMKilled crash loops; see n8n_webhook_cpu_request, n8n_webhook_memory_limit and docs/troubleshooting.md."
  type        = bool
  default     = false
}

variable "n8n_community_packages_registry" {
  description = "npm registry community packages are installed from (e.g. <https://npm.internal.example.com>). Maps to N8N_COMMUNITY_PACKAGES_REGISTRY, which n8n gates behind a specific licensed feature rather than a license key alone: any value other than <https://registry.npmjs.org> makes installs throw FeatureNotLicensedError unless the instance is entitled to COMMUNITY_NODES_CUSTOM_REGISTRY (`getNpmRegistry` in community-packages.service.ts). Confirm that entitlement before setting this, since an unentitled instance breaks community-package installs instead of falling back to the public registry. Point this at a private mirror to install community nodes from an internal registry instead of the public npm one, e.g. when egress to registry.npmjs.org is blocked or packages are vendored. n8n defaults to <https://registry.npmjs.org>; when this is null (the default) the env var is omitted entirely so n8n's own default applies. A mirror that requires authentication also needs N8N_COMMUNITY_PACKAGES_AUTH_TOKEN, which this module does not manage; pass it via n8n_extra_env, keeping in mind that n8n_extra_env values are stored in plaintext in the Helm release and Terraform state. Baking packages into a custom image via n8n_image_repository avoids registry access at pod start entirely."
  type        = string
  default     = null

  validation {
    # A scheme check alone accepted a bare "https://", which n8n only rejects
    # when it first tries to install a package. Require a host, and a numeric
    # port if one is given, so a truncated value fails at plan instead.
    condition     = var.n8n_community_packages_registry == null ? true : can(regex("^https?://[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.n8n_community_packages_registry))
    error_message = "n8n_community_packages_registry must be a registry URL with a host, starting with http:// or https://, with an optional numeric port and path, and no whitespace (e.g. https://npm.internal.example.com, https://npm.internal.example.com:4873/repository/npm-group). Set to null to use n8n's default (https://registry.npmjs.org)."
  }
}

variable "n8n_custom_extensions_path" {
  description = "Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. \"/opt/n8n-nodes\"). Maps to N8N_CUSTOM_EXTENSIONS, and is set on every pod type (main, worker, webhook processor). This is the supported way to ship nodes baked into a custom image: since n8n 1.0 the loader no longer picks up nodes from the image's global node_modules, so a plain npm install into the image is never seen (n8n v10 migration guide, and packages/cli/src/load-nodes-and-credentials.ts). Something has to put files at this path, so either set n8n_image_repository to an image that baked them in, or mount a volume that carries them with n8n_extra_volumes and n8n_extra_volume_mounts; a path with neither behind it warns at plan time. The path must be outside /home/node/.n8n, which the chart mounts over on main pods (see the validation below). Two caveats that no Terraform input can fix. First, nodes loaded this way are registered under the package name CUSTOM, so a node whose type was n8n-nodes-example.myNode when installed from npm becomes CUSTOM.myNode, and existing workflows referencing the npm-qualified type will not resolve. Second, only one directory is exposed even though n8n accepts a semicolon-separated list, because every custom directory is registered under the same CUSTOM key and each one overwrites the last, so all but the final directory are silently dropped. Leave null (the default) to omit the env var entirely."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : can(regex("^/[^[:space:];]*$", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be an absolute container path with no whitespace and no semicolon (e.g. \"/opt/n8n-nodes\"). n8n splits N8N_CUSTOM_EXTENSIONS on \";\", so a semicolon here would be parsed as two directories and silently drop all but the last."
  }

  validation {
    # The shadowing check below is a string comparison, so it only holds if the
    # mounted directory has a single spelling. /home/node//.n8n/custom,
    # /home/node/./.n8n/custom and /opt/../home/node/.n8n/custom all resolve
    # inside the mount in the container while slipping past a startswith() on
    # the raw value. Requiring a canonical path is the sound fix: abspath()
    # would normalize against the machine running Terraform rather than the
    # container filesystem, and rewrites separators on Windows.
    condition     = var.n8n_custom_extensions_path == null ? true : !can(regex("//|/\\.\\.?(/|$)", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be a canonical path: no repeated slashes and no \".\" or \"..\" components (e.g. \"/opt/n8n-nodes\"). Those spellings resolve to the same directory inside the container but would slip past the /home/node/.n8n shadowing check."
  }

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : (var.n8n_custom_extensions_path == "/" || !endswith(var.n8n_custom_extensions_path, "/"))
    error_message = "n8n_custom_extensions_path must not end in a trailing slash (e.g. \"/opt/n8n-nodes\", not \"/opt/n8n-nodes/\"). Same reason as the canonical-path rule above: the two spellings are the same directory to the container but different strings to the coverage check in n8n.tf, which compares this path against n8n_extra_volume_mounts entries literally."
  }

  validation {
    # The chart mounts the `data` volume at /home/node/.n8n on the main
    # deployment only (templates/deployment-main.yaml), and the module leaves
    # persistence.enabled at the chart default, so that volume is an emptyDir.
    # Anything the image placed under that path is therefore hidden on mains
    # while still present on workers and webhook processors: the nodes load on
    # some pod types and not others, which surfaces as workflows that run on a
    # worker but fail to open in the editor.
    condition = var.n8n_custom_extensions_path == null ? true : !(
      var.n8n_custom_extensions_path == "/home/node/.n8n" ||
      startswith(var.n8n_custom_extensions_path, "/home/node/.n8n/")
    )
    error_message = "n8n_custom_extensions_path must not be inside /home/node/.n8n. The chart mounts an emptyDir there on main pods, which hides whatever the image baked in, so the nodes would load on workers and webhook processors but not on mains. Use a path outside it, for example /opt/n8n-nodes."
  }
}

variable "n8n_binary_data_mode" {
  description = "Where n8n writes the binary payloads a workflow produces: \"database\" stores them as base64 inside the execution row, \"filesystem\" writes them to disk under n8n_binary_data_path. Defaults to \"database\", which is what n8n itself does in queue mode and therefore what this module has always produced; changing it is opt-in. The default is safe rather than good. Every binary a workflow touches is base64 in a Postgres row, so a 10MB attachment is roughly 13MB of WAL, replication traffic and backup, and execution pruning becomes the only thing reclaiming it. \"filesystem\" avoids that, and in queue mode it needs a volume all three pod types share: main, worker and webhook-processor each handle different stages of the same execution, and a payload written to one pod's local disk does not exist for the next. The module refuses filesystem without a mount covering the path, because that combination reports success and loses data."
  type        = string
  default     = "database"
  nullable    = false

  validation {
    condition     = contains(["database", "filesystem"], var.n8n_binary_data_mode)
    error_message = "n8n_binary_data_mode must be one of: database, filesystem. n8n also supports \"s3\", which this module does not configure: it pins s3.enabled false with no input to turn it on, so selecting it here would name a backend that was never set up."
  }

  validation {
    # The failure this prevents is silent. Filesystem mode with no shared
    # volume gives every pod its own empty directory, so a worker writes a
    # payload the main pod cannot read and the execution reports success with
    # a broken reference. Nothing errors, nothing logs, and the loss surfaces
    # whenever someone opens an old execution.
    condition = var.n8n_binary_data_mode != "filesystem" || anytrue([
      for mount in var.n8n_extra_volume_mounts :
      mount.read_only == false && (
        var.n8n_binary_data_path == mount.mount_path ||
        startswith(var.n8n_binary_data_path, "${mount.mount_path}/")
      )
    ])
    error_message = "n8n_binary_data_mode = \"filesystem\" needs a writable mount in n8n_extra_volume_mounts covering n8n_binary_data_path, backed by an RWX volume in n8n_extra_volumes. This module always runs queue mode, where main, worker and webhook-processor handle different stages of one execution, so a payload on one pod's local disk is invisible to the next. Without the shared mount the execution still reports success and the data is gone. Add the volume and the mount, or leave the mode at \"database\"."
  }
}

variable "n8n_binary_data_path" {
  description = "Directory n8n writes binary payloads to when n8n_binary_data_mode is \"filesystem\", rendered as N8N_STORAGE_PATH with n8n appending its own storage/ subdirectory. Ignored in database mode. Keep it outside /home/node/.n8n: the chart already mounts its own data volume there on the main pod, and nesting one mount inside another is a way to lose track of which pod sees what. Note the task-runner sidecar does not receive n8n_extra_volume_mounts, so this path exists in the n8n container only."
  type        = string
  default     = "/opt/n8n-shared"
  nullable    = false

  validation {
    # Written with strcontains and split rather than one regex: an HCL string
    # is not a raw literal, so the backslashes a path regex needs are an
    # escape-sequence trap for the next person to touch this.
    condition = alltrue([
      startswith(var.n8n_binary_data_path, "/"),
      !can(regex("[[:space:]]", var.n8n_binary_data_path)),
      !strcontains(var.n8n_binary_data_path, "//"),
      !contains(split("/", var.n8n_binary_data_path), "."),
      !contains(split("/", var.n8n_binary_data_path), ".."),
    ])
    error_message = "n8n_binary_data_path must be an absolute path with no whitespace, no empty segments and no . or .. components."
  }
}

variable "n8n_extra_volumes" {
  description = "Volumes to add to the main, worker and webhook-processor pods, mapped to the chart's extraVolumes. Each entry needs a name and exactly one source: config_map, secret, or persistent_volume_claim. Those three are the sources that can carry files into a pod on their own, which is the point of the input: paired with n8n_extra_volume_mounts and n8n_custom_extensions_path, they load community nodes from a ConfigMap or a shared ReadWriteMany claim instead of from a custom image, which is the alternative to rebuilding an image for every package change. Other uses fit too, a CA bundle from a secret being the common one. default_mode is an octal string (\"0644\"), not a number, because Terraform reads a leading zero as decimal and would silently apply the wrong permissions. Volume sources beyond those three (csi, nfs, projected) are not exposed. Names must be unique, and \"data\" and \"task-runner-config\" are reserved by the chart."
  type = list(object({
    name = string
    config_map = optional(object({
      name         = string
      default_mode = optional(string)
    }))
    secret = optional(object({
      secret_name  = string
      default_mode = optional(string)
    }))
    persistent_volume_claim = optional(object({
      claim_name = string
      read_only  = optional(bool)
    }))
  }))
  default = []

  validation {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", volume.name)) && length(volume.name) <= 63
    ])
    error_message = "Every n8n_extra_volumes name must be a DNS-1123 label, which is what Kubernetes requires of a volume name: 63 characters or fewer of lowercase alphanumerics and hyphens, starting and ending with an alphanumeric (e.g. \"custom-nodes\")."
  }

  validation {
    condition     = length(distinct([for volume in var.n8n_extra_volumes : volume.name])) == length(var.n8n_extra_volumes)
    error_message = "n8n_extra_volumes names must be unique. Kubernetes rejects a pod spec with two volumes of the same name, so the whole release fails to render rather than one entry losing out."
  }

  validation {
    # `data` is the chart's own volume, mounted at /home/node/.n8n on main pods.
    # `task-runner-config` appears when taskRunners.customConfig is enabled.
    # Reusing either name collides inside the rendered pod spec.
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      !contains(["data", "task-runner-config"], volume.name)
    ])
    error_message = "n8n_extra_volumes must not use the names \"data\" or \"task-runner-config\". The chart declares both itself (data is the n8n home volume on main pods), and a duplicate volume name makes Kubernetes reject the whole pod spec. Pick another name."
  }

  validation {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      length([
        for source in [volume.config_map, volume.secret, volume.persistent_volume_claim] :
        source if source != null
      ]) == 1
    ])
    error_message = "Every n8n_extra_volumes entry must set exactly one of config_map, secret or persistent_volume_claim. A volume with no source, or with two, is not a thing Kubernetes can mount."
  }

  validation {
    # The `if` filters run before the mode is read, so an entry whose source is
    # a persistent_volume_claim never has default_mode looked up on a null.
    condition = alltrue([
      for mode in concat(
        [for volume in var.n8n_extra_volumes : volume.config_map.default_mode if volume.config_map != null],
        [for volume in var.n8n_extra_volumes : volume.secret.default_mode if volume.secret != null],
      ) : mode == null ? true : can(regex("^0?[0-7]{3}$", mode))
    ])
    error_message = "Every default_mode in n8n_extra_volumes must be a three-digit octal string, optionally with a leading zero (e.g. \"0644\" or \"755\"). It is a string on purpose: Terraform reads the number 0644 as decimal 644, which is octal 1204, so the files would land with permissions nobody asked for."
  }
}

variable "n8n_extra_volume_mounts" {
  description = "Where the n8n container mounts the volumes declared in n8n_extra_volumes, mapped to the chart's extraVolumeMounts. Applies to the main, worker and webhook-processor pods alike, and to the n8n container only, not the task runner sidecar. Every name here must match a name in n8n_extra_volumes, which is checked at plan time rather than left to fail at pod start. read_only defaults to true, so a mount that has to be written needs to say so. Use this with n8n_custom_extensions_path to load community nodes from a volume rather than from a custom image; when a mount covers that path, the module stops warning that the path has nothing behind it."
  type = list(object({
    name       = string
    mount_path = string
    sub_path   = optional(string)
    read_only  = optional(bool, true)
  }))
  default = []

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      contains([for volume in var.n8n_extra_volumes : volume.name], mount.name)
    ])
    error_message = "Every n8n_extra_volume_mounts name must match a volume declared in n8n_extra_volumes. A mount referring to a volume that does not exist leaves the pods stuck in CreateContainerConfigError, which is a slow way to learn about a typo."
  }

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      can(regex("^/[^[:space:]]*$", mount.mount_path)) && !can(regex("//|/\\.\\.?(/|$)", mount.mount_path))
    ])
    error_message = "Every n8n_extra_volume_mounts mount_path must be a canonical absolute path with no whitespace: no repeated slashes and no \".\" or \"..\" components (e.g. \"/opt/n8n-nodes\"). The canonical form is what makes the collision checks below comparisons rather than guesses."
  }

  validation {
    # Every other rule here is a string comparison, so one directory has to have
    # one spelling. "/home/node/.n8n/" is the same mount target as
    # "/home/node/.n8n" and would slip past the check below it, and a trailing
    # slash also breaks the prefix test that decides whether a mount covers
    # n8n_custom_extensions_path, turning a working config into a warning.
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      !endswith(mount.mount_path, "/")
    ])
    error_message = "No n8n_extra_volume_mounts mount_path may end in a slash: write \"/opt/n8n-nodes\", not \"/opt/n8n-nodes/\". The two name the same directory, so allowing both would let a mount collide with one the chart already declares while comparing as different, and would break the test for whether a mount covers n8n_custom_extensions_path. Mounting at \"/\" is rejected by the same rule, which is intended."
  }

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      mount.mount_path != "/home/node/.n8n"
    ])
    error_message = "n8n_extra_volume_mounts must not mount at /home/node/.n8n exactly. The chart already mounts its own `data` volume there on main pods, and Kubernetes rejects a container with two mounts on the same path, so the release would fail to apply. A path underneath it is fine, as is any path outside it."
  }

  validation {
    condition     = length(distinct([for mount in var.n8n_extra_volume_mounts : mount.mount_path])) == length(var.n8n_extra_volume_mounts)
    error_message = "n8n_extra_volume_mounts mount_path values must be unique. Two mounts on one path is a pod spec Kubernetes rejects outright."
  }
}

# ── Sidecars ──────────────────────────────────────────────────────────────────
# The chart's extraContainers/extraInitContainers, typed to the fields a sidecar
# actually uses rather than to the whole Kubernetes container schema. That is
# the same trade n8n_extra_volumes makes by exposing three volume sources out of
# a dozen: a typed subset validates at plan time and reads as documentation,
# where `any` would accept a misspelt key and fail at pod start. Anything the
# subset does not cover is still reachable through n8n_extra_helm_values.

variable "n8n_extra_containers" {
  description = "Sidecar containers to add to the main, worker and webhook-processor pods, mapped to the chart's extraContainers. Each entry needs a name and an image; everything else is optional. A sidecar shares the pod's network namespace, so it reaches n8n on localhost:5678 without any service in between, which is what makes a log shipper, an auth proxy or a metrics exporter work. Mount a volume declared in n8n_extra_volumes with volume_mounts, using the same names. Field coverage is deliberately partial: probes, lifecycle hooks and securityContext are not exposed, and a sidecar needing those belongs in n8n_extra_helm_values. Names must not collide with the containers the chart already runs (n8n, and the task runner when enabled)."
  type = list(object({
    name    = string
    image   = string
    command = optional(list(string))
    args    = optional(list(string))
    env = optional(list(object({
      name  = string
      value = string
    })), [])
    ports = optional(list(object({
      name           = optional(string)
      container_port = number
    })), [])
    volume_mounts = optional(list(object({
      name       = string
      mount_path = string
      sub_path   = optional(string)
      read_only  = optional(bool, true)
    })), [])
    resources = optional(object({
      cpu_request    = optional(string)
      cpu_limit      = optional(string)
      memory_request = optional(string)
      memory_limit   = optional(string)
    }))
  }))
  default = []

  validation {
    condition     = length(distinct([for c in var.n8n_extra_containers : c.name])) == length(var.n8n_extra_containers)
    error_message = "Every n8n_extra_containers name must be unique: Kubernetes rejects a pod with two containers of the same name, and the rejection names the pod rather than this input."
  }

  validation {
    condition = alltrue([
      for c in var.n8n_extra_containers :
      !contains(["n8n", "task-runner"], c.name)
    ])
    error_message = "n8n_extra_containers may not use the names \"n8n\" or \"task-runner\": the chart already runs those, and a duplicate name fails at pod admission rather than at plan time."
  }

  validation {
    condition = alltrue([
      for c in var.n8n_extra_containers :
      alltrue([for m in c.volume_mounts : startswith(m.mount_path, "/") && !endswith(m.mount_path, "/")])
    ])
    error_message = "Every n8n_extra_containers volume_mounts mount_path must be absolute and must not end in a slash (e.g. \"/var/log/n8n\"), matching the rule n8n_extra_volume_mounts follows."
  }
}

variable "n8n_extra_init_containers" {
  description = "Init containers to add to the main, worker and webhook-processor pods, mapped to the chart's extraInitContainers. Same shape as n8n_extra_containers, and the same partial field coverage. These run to completion before n8n starts, so use them to prepare a volume: fetch a CA bundle, warm a cache, or unpack community nodes into a shared claim. A failing init container holds the pod in Init state indefinitely rather than crash-looping, which reads as a stuck rollout, so keep them short and make them idempotent."
  type = list(object({
    name    = string
    image   = string
    command = optional(list(string))
    args    = optional(list(string))
    env = optional(list(object({
      name  = string
      value = string
    })), [])
    volume_mounts = optional(list(object({
      name       = string
      mount_path = string
      sub_path   = optional(string)
      read_only  = optional(bool, false)
    })), [])
    resources = optional(object({
      cpu_request    = optional(string)
      cpu_limit      = optional(string)
      memory_request = optional(string)
      memory_limit   = optional(string)
    }))
  }))
  default = []

  validation {
    condition     = length(distinct([for c in var.n8n_extra_init_containers : c.name])) == length(var.n8n_extra_init_containers)
    error_message = "Every n8n_extra_init_containers name must be unique: Kubernetes rejects a pod with two init containers of the same name."
  }
}


variable "n8n_community_packages_prevent_loading" {
  description = "Prevent installed community packages from being loaded at runtime. Maps to N8N_COMMUNITY_PACKAGES_PREVENT_LOADING. When true, n8n leaves the community-packages management surface in place but skips loading the package code, which is useful for locking an instance down without uninstalling. Leave false (the default) for community nodes to load and execute. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies."
  type        = bool
  default     = false
}

# n8n defaults scheduled to change
# n8n warns on every pod start that the defaults behind these four variables will
# be reduced or flipped in a future version, and asks operators to set them
# explicitly to keep the current behavior (see DeprecationService in
# packages/cli/src/deprecation/deprecation.service.ts). The warnings fire because
# nothing sets the variables, not because setting them is wrong.
#
# Only the task timeout is pinned by default here. Its change is a pure
# functional regression: nothing about a five-minute Code node task becomes
# unsafe, it simply stops working. The other three are n8n deliberately
# tightening a security posture (unverified packages, and two zip-bomb limits on
# the Compression node), so this module leaves them at whatever n8n decides and
# exposes the lever rather than freezing the weaker value on every deployment's
# behalf. Setting one of them is an operator saying "my workflows need this",
# which is a claim the module cannot make for them.

variable "n8n_task_runner_timeout" {
  description = "Seconds a Code node task may run in a task runner before n8n aborts it. Maps to N8N_RUNNERS_TASK_TIMEOUT, and applies to every pod type. Not to be confused with n8n_task_runner_request_timeout, which is how long n8n waits for a runner to *accept* a task rather than how long the task may then run. Defaults to 300, which is n8n's own current default, and the module sets it explicitly rather than omitting it: n8n has announced this default will drop to 60 in a future version, which would abort any Code node task running longer than a minute after an n8n upgrade that changed nothing else. Pinning it here means an upgrade cannot move it silently. Set it to 60 to adopt n8n's future default early, or raise it for genuinely long-running tasks."
  type        = number
  default     = 300

  validation {
    condition     = var.n8n_task_runner_timeout > 0
    error_message = "n8n_task_runner_timeout must be greater than 0 seconds."
  }
}

variable "n8n_unverified_packages_enabled" {
  description = "Allow installing community packages that n8n has not verified. Maps to N8N_UNVERIFIED_PACKAGES_ENABLED. Null (the default) omits the env var so n8n's own default applies, which is currently true but which n8n has announced will become false in a future version. Set this to true to keep installing unverified packages across that change, or to false to adopt the stricter behavior now. The module does not pin it, because unlike the task timeout this is n8n tightening a security default, and freezing the permissive value on every deployment's behalf is not a decision this module should make."
  type        = bool
  default     = null
}

variable "n8n_compression_max_decompressed_size_bytes" {
  description = "Largest decompressed payload the Compression node will produce, in bytes. Maps to N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES. Null (the default) omits the env var so n8n's own default applies, which is currently 2 GiB (2147483648) and which n8n has announced will drop to 256 MiB (268435456) in a future version. This is a zip-bomb limit, so the reduction is a hardening rather than a regression; set this only if workflows genuinely decompress archives larger than n8n's default allows, and set it to the value those workflows need rather than to the old default."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_compression_max_decompressed_size_bytes == null ? true : var.n8n_compression_max_decompressed_size_bytes > 0
    error_message = "n8n_compression_max_decompressed_size_bytes must be greater than 0 bytes when set."
  }
}

variable "n8n_compression_max_zip_entries" {
  description = "Largest number of entries the Compression node will extract from one archive. Maps to N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES. Null (the default) omits the env var so n8n's own default applies, which is currently 5000 and which n8n has announced will drop to 1000 in a future version. Like n8n_compression_max_decompressed_size_bytes this is a zip-bomb limit, so the reduction hardens rather than breaks; set it only for workflows that genuinely process archives with more entries than n8n's default allows."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_compression_max_zip_entries == null ? true : var.n8n_compression_max_zip_entries > 0
    error_message = "n8n_compression_max_zip_entries must be greater than 0 entries when set."
  }
}

# OpenTelemetry tracing
# Wired to N8N_OTEL_* env vars on the n8n Helm release's config.extraEnv block,
# which the chart applies to every n8n container (main, worker, webhook
# processor). This matches the n8n OpenTelemetry docs' queue-mode requirement:
# https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/
#
# The collector / Jaeger receiver itself is intentionally out of scope for this
# module. Deploy it via a separate Terraform module (or directly) and point
# n8n_otel_exporter_otlp_endpoint at it.
#
# When n8n_otel_enabled = false (the default), no N8N_OTEL_* env vars are
# emitted at all and the OpenTelemetry SDK is not loaded. The individual tuning
# variables (endpoint, headers, service name, sample rate, span inclusion,
# outbound injection, production-only filtering) default to null; when an
# individual value is null the corresponding env var is omitted entirely so
# n8n's own default applies. Only set the values you actually need to override.

variable "n8n_otel_enabled" {
  description = "Master switch for n8n's OpenTelemetry workflow + node tracing. When true, the module sets N8N_OTEL_ENABLED=true on all n8n containers (main, worker, webhook processor) via the Helm release's config.extraEnv block. When false (the default), no OpenTelemetry env vars are emitted and the SDK is not loaded. The OpenTelemetry collector / Jaeger receiver is out of scope for this module. Deploy it separately and point n8n_otel_exporter_otlp_endpoint at it. See <https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/> for the underlying n8n contract."
  type        = bool
  default     = false
}

variable "n8n_otel_exporter_otlp_endpoint" {
  description = "Base URL of the OTLP HTTP endpoint to export traces to (e.g. <http://otel-collector.observability.svc.cluster.local:4318> for an in-cluster collector). When set, maps to N8N_OTEL_EXPORTER_OTLP_ENDPOINT. n8n appends /v1/traces to this value internally, so point at the base URL, not the traces path. Leave null to use n8n's default (<http://localhost:4318>), which only works if a sidecar collector is colocated in each n8n pod (this module does not deploy one). Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null

  # Null-safe ternary (see n8n_otel_traces_sample_rate for the Terraform 1.9.x
  # short-circuit rationale): only validate the scheme when a value is set.
  validation {
    condition = var.n8n_otel_exporter_otlp_endpoint == null ? true : (
      startswith(var.n8n_otel_exporter_otlp_endpoint, "http://") ||
      startswith(var.n8n_otel_exporter_otlp_endpoint, "https://")
    )
    error_message = "n8n_otel_exporter_otlp_endpoint must be a base URL starting with http:// or https:// (n8n appends /v1/traces itself), or null to use n8n's default."
  }
}

variable "n8n_otel_exporter_otlp_headers" {
  description = "Comma-separated list of key=value pairs sent as HTTP headers with each OTLP request (e.g. `authorization=Bearer <token>,x-tenant=acme`). Use this for collector authentication or multi-tenant routing. Maps to N8N_OTEL_EXPORTER_OTLP_HEADERS. Leave null to send no extra headers. Marked sensitive so the value is redacted from CLI and plan output, but note it is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). The chart's config.extraEnv does not support secretKeyRef, so restrict access to state and the n8n namespace accordingly. Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null
  sensitive   = true
}

variable "n8n_otel_exporter_service_name" {
  description = "Value of the service.name resource attribute on exported spans. Maps to N8N_OTEL_EXPORTER_SERVICE_NAME. Leave null to use n8n's default ('n8n'). Set this to differentiate multiple n8n deployments sending traces to the same collector (e.g. 'n8n-prod', 'n8n-staging'). Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null
}

variable "n8n_otel_traces_sample_rate" {
  description = "Fraction of traces to export, between 0 and 1 inclusive. Maps to N8N_OTEL_TRACES_SAMPLE_RATE. n8n uses a trace-ID-ratio sampler, so the same trace ID is either fully sampled or fully dropped across all spans. Leave null to use n8n's default (1.0, every trace exported). Lower for high-volume installs where the collector or backend can't handle every workflow execution as a trace. Ignored when n8n_otel_enabled = false."
  type        = number
  default     = null

  # Use a ternary rather than `null || numeric_op` here: Terraform 1.9.x
  # eagerly evaluates both sides of the logical OR during validation, so the
  # `null >= 0` branch errors with 'argument must not be null.' even when
  # the variable is null. Ternaries DO short-circuit, so wrapping the numeric
  # comparison in `var == null ? true : (...)` keeps the null path entirely
  # off the numeric-op branch.
  validation {
    condition = var.n8n_otel_traces_sample_rate == null ? true : (
      var.n8n_otel_traces_sample_rate >= 0 && var.n8n_otel_traces_sample_rate <= 1
    )
    error_message = "n8n_otel_traces_sample_rate must be between 0 and 1 inclusive, or null to use n8n's default."
  }
}

variable "n8n_otel_traces_include_node_spans" {
  description = "Whether to emit a node.execute span for each node execution. Maps to N8N_OTEL_TRACES_INCLUDE_NODE_SPANS. Leave null to use n8n's default (true, one span per node per execution). Set to false to export workflow-level spans only, a common volume-reduction lever for workflows with many small nodes. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_inject_outbound" {
  description = "Whether n8n's HTTP-helper-based nodes (HTTP Request and similar) inject W3C traceparent / tracestate headers into outbound requests. Maps to N8N_OTEL_TRACES_INJECT_OUTBOUND. Leave null to use n8n's default (true, propagate context to downstream services). Set to false when calling external systems that misbehave on unexpected headers, or when you don't want trace context leaving your boundary. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_production_only" {
  description = "Whether to export traces for production workflow executions only. Maps to N8N_OTEL_TRACES_PRODUCTION_ONLY. Leave null to use n8n's default (true, only production executions are traced). Set to false to also trace manual/test executions run from the editor, which helps while developing instrumentation but is noisy in production. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

variable "n8n_extra_env" {
  description = "Additional environment variables to inject into all n8n pods (main, worker, and webhook-processor) via the Helm chart's config.extraEnv list. Each entry is an object with name and value string attributes. config.extraEnv is appended last in every container's env list, so by Kubernetes' last-wins rule any name here overrides the chart's value for that name. To prevent silently breaking the deployment, an entry is rejected at plan time when its name collides with a connection, identity, storage, topology, or routing variable the module manages: any name starting with DB_, QUEUE_, N8N_RUNNERS_, or N8N_ENDPOINT_, plus names like N8N_ENCRYPTION_KEY, N8N_HOST, WEBHOOK_URL, and EXECUTIONS_MODE. N8N_ENDPOINT_ is reserved because the module hardcodes the path segments n8n serves and then publishes them in n8n_webhook_path_prefixes and n8n_oauth_callback_url, which callers route on their own Ingress; repointing one leaves that routing and those outputs advertising a path n8n no longer answers on. Use the dedicated module inputs for those. Object-storage names (N8N_EXTERNAL_STORAGE_S3_*, AWS_*) are deliberately allowed: the module provisions no bucket and sets none of them, so pointing n8n at your own is a supported configuration rather than a collision. Do not put secret values here, because they render into the Helm release and are stored in plaintext in Terraform state; instead pass a *_FILE companion (e.g. a name ending in _FILE) pointing at a mounted Kubernetes secret, or use n8n credentials. Example: [{name = \"N8N_DEFAULT_LOCALE\", value = \"de\"}]."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for e in var.n8n_extra_env : e.name != "" && e.name == trimspace(e.name)])
    error_message = "Each n8n_extra_env entry must have a non-empty name with no leading or trailing whitespace. Whitespace-padded names would bypass the duplicate and module-managed guards while rendering as a distinct, ignored env var."
  }

  validation {
    condition     = length(distinct([for e in var.n8n_extra_env : e.name])) == length(var.n8n_extra_env)
    error_message = "n8n_extra_env contains duplicate names; each environment variable may be set only once."
  }

  validation {
    condition = alltrue([
      for e in var.n8n_extra_env : !(
        contains(local.n8n_managed_env_names, e.name) ||
        anytrue([for p in local.n8n_managed_env_prefixes : startswith(e.name, p)])
      )
    ])
    error_message = "n8n_extra_env must not set module-managed variables. Reserved: any name starting with one of ${join(", ", local.n8n_managed_env_prefixes)} (connection, queue, runner and endpoint-path families), plus the exact names ${join(", ", local.n8n_managed_env_names)}. config.extraEnv is appended last and would otherwise silently override these (Kubernetes last-wins). Use the dedicated module inputs (e.g. n8n_log_level, n8n_metrics_enabled) instead."
  }
}

variable "n8n_extra_env_from_secret" {
  description = "Additional environment variables sourced from keys of existing Kubernetes Secrets, injected into all n8n pods (main, worker, and webhook-processor) alongside n8n_extra_env. Each entry names the environment variable, the Secret, and the key within it, and renders as a valueFrom.secretKeyRef entry in the chart's config.extraEnv list. This is the input to use for anything sensitive: unlike n8n_extra_env, no value passes through Terraform, so nothing lands in the Helm release or in state, and rotating the value is a Secret edit plus a pod restart rather than an apply. The Secret must already exist in the same namespace as the n8n pods and is neither created nor read by this module, which is what keeps its value out of state; a name or key that does not exist leaves the pods in CreateContainerConfigError rather than failing the apply, because Kubernetes resolves the reference at container start and Helm has already reported success by then. Reserved names are rejected exactly as they are for n8n_extra_env, and a name may not appear in both inputs. Example: [{name = \"N8N_INSTANCE_AI_MODEL_API_KEY\", secret_name = \"ai-assistant-secrets\", secret_key = \"anthropic-api-key\"}]."
  type = list(object({
    name        = string
    secret_name = string
    secret_key  = string
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for e in var.n8n_extra_env_from_secret :
      e.name != "" && e.name == trimspace(e.name)
    ])
    error_message = "Each n8n_extra_env_from_secret entry must have a non-empty name with no leading or trailing whitespace. Whitespace-padded names would bypass the duplicate and module-managed guards while rendering as a distinct, ignored env var."
  }

  validation {
    # RFC 1123 subdomain for the Secret name, and the character class the API
    # server accepts for a key. Checked here rather than left to the apply
    # because the reference is resolved at container start: a malformed name
    # produces a stuck pod long after Helm has reported the release installed.
    #
    # Matched label by label rather than as one character class. A single class
    # of [a-z0-9.-] admits "a..b" and "a-.b", which the API server rejects --
    # so the guard would have passed exactly the names it exists to catch.
    condition = alltrue([
      for e in var.n8n_extra_env_from_secret :
      length(e.secret_name) <= 253 &&
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", e.secret_name)) &&
      can(regex("^[a-zA-Z0-9._-]{1,253}$", e.secret_key))
    ])
    error_message = "Each n8n_extra_env_from_secret entry needs a secret_name that is a valid RFC 1123 subdomain (lowercase alphanumerics, - and ., starting and ending alphanumeric) and a secret_key made only of alphanumerics, -, _ and . (both non-empty)."
  }

  validation {
    condition = length(distinct([
      for e in var.n8n_extra_env_from_secret : e.name
    ])) == length(var.n8n_extra_env_from_secret)
    error_message = "n8n_extra_env_from_secret contains duplicate names; each environment variable may be set only once."
  }

  validation {
    # Across the two inputs, not just within this one. Both land in the same
    # config.extraEnv list, where a repeated name is not an error: Kubernetes
    # takes the last entry and discards the first silently, so the caller would
    # get whichever one this module happened to concat second.
    condition = length(setintersection(
      toset([for e in var.n8n_extra_env_from_secret : e.name]),
      toset([for e in var.n8n_extra_env : e.name]),
    )) == 0
    error_message = "n8n_extra_env_from_secret and n8n_extra_env must not set the same variable name. Both render into config.extraEnv, where Kubernetes silently keeps the last entry, so the winner would be an artifact of concat order rather than a choice. Set each name in exactly one of the two."
  }

  validation {
    condition = alltrue([
      for e in var.n8n_extra_env_from_secret : !(
        contains(local.n8n_managed_env_names, e.name) ||
        anytrue([for p in local.n8n_managed_env_prefixes : startswith(e.name, p)])
      )
    ])
    error_message = "n8n_extra_env_from_secret must not set module-managed variables. Reserved: any name starting with one of ${join(", ", local.n8n_managed_env_prefixes)} (connection, queue, runner and endpoint-path families), plus the exact names ${join(", ", local.n8n_managed_env_names)}. config.extraEnv is appended last and would otherwise silently override these (Kubernetes last-wins). Use the dedicated module inputs (e.g. n8n_log_level, n8n_metrics_enabled) instead."
  }
}

# ── External Secrets ──────────────────────────────────────────────────────────
# n8n's own External Secrets feature resolves *workflow credential* values from
# an external vault at runtime (Settings -> External Secrets in the n8n UI),
# keeping them out of n8n's Postgres and out from under N8N_ENCRYPTION_KEY.
# This is unrelated to the module's own secrets (DB password, Redis AUTH
# token, encryption key, task runner token, licence key): those stay
# Kubernetes Secrets, unaffected by anything below.
#
# n8n gates the feature behind the feat:externalSecrets licence entitlement
# (@BackendModule in module-registry.ts). Without that entitlement the feature
# is inert regardless of these inputs, so n8n_external_secrets_enabled is an
# explicit opt-out rather than a required guard, and Community-licensed
# deployments can leave both inputs here at their defaults.

variable "n8n_external_secrets_enabled" {
  description = "Whether n8n's own External Secrets module may load. When false, appends \"external-secrets\" to N8N_DISABLED_MODULES, which disables the feature (and its Settings UI) even under a licence that includes it. When true (the default), no env var is emitted and n8n's own default applies: the module stays enabled, but inert on Community licences without the feat:externalSecrets entitlement. This input does not create a vault connection; that remains a manual step in the n8n UI regardless of this setting."
  type        = bool
  default     = true
}

# External secret providers (Vault, Infisical, AWS Secrets Manager, Azure Key
# Vault, GCP Secrets Manager, 1Password) take their connection settings inside
# n8n itself, and n8n gates the feature behind an entitlement this module does
# not supply. The input above is therefore a disable switch, not an enable one.

variable "k8s_capacity_check_enabled" {
  description = "Reads allocatable CPU from the cluster's schedulable nodes at plan time and warns when the autoscaler ceilings add up to more than the cluster can hold. Cordoned nodes and nodes carrying a NoSchedule taint are excluded, so a cluster with dedicated control planes is not counted at more than its usable size. Advisory only: it never fails a plan, and it stays silent when the cluster reports no schedulable nodes. Set false where the plan runs somewhere the cluster is unreachable or the credentials cannot list nodes cluster-wide (a plan-only CI job is the realistic case), since the node read is an ordinary data source and a failed read fails the plan. Setting false removes the read itself, not just the warning."
  type        = bool
  default     = true
  nullable    = false
}

# ── KEDA: worker pods ─────────────────────────────────────────────────────────

variable "k8s_keda_installed" {
  description = "Attests that the KEDA operator is already installed cluster-wide, which lets the module scale workers on Redis queue depth instead of CPU. Default false: the chart's CPU-based worker HPA scales workers, which lags a burst because queued executions do not raise worker CPU until a worker picks them up. Set true and the chart renders a KEDA ScaledObject bounded by the same n8n_worker_keda_* inputs, and its CPU worker HPA is disabled so the two never both own the worker Deployment. This is an attestation rather than a lookup on purpose: a data source probing for the KEDA CRD resolves at refresh time, which would make the whole scaling branch unknown at plan and defeat the mocked test suite. The module does not install KEDA: it installs no cluster-wide operator it does not own. If this is true and KEDA is absent, the ScaledObject applies and never reconciles: workers stay pinned at their floor. tests/scripts/smoke-test.sh asserts the ScaledObject's Ready condition for exactly that reason."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_worker_keda_min_replicas" {
  description = "Minimum worker replicas. KEDA keeps at least this many workers running even when the queue is empty. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_min_replicas <= var.n8n_worker_keda_max_replicas
    error_message = "n8n_worker_keda_min_replicas must not exceed n8n_worker_keda_max_replicas; KEDA rejects a ScaledObject whose minReplicaCount is above its maxReplicaCount."
  }

  validation {
    condition     = var.n8n_worker_keda_min_replicas == floor(var.n8n_worker_keda_min_replicas) && var.n8n_worker_keda_min_replicas >= 0
    error_message = "n8n_worker_keda_min_replicas must be a whole number of replicas, 0 or greater. 0 is allowed here, unlike the two HPA floors: KEDA scales a ScaledObject to zero natively."
  }
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum worker replicas KEDA may scale to. Workers compete for the same nodes as the main and webhook pods, and each carries a task runner sidecar, so this ceiling counts against the same node group budget as the two HPA maxima. See README.md → \"Sizing autoscaling against node capacity\"."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_max_replicas == floor(var.n8n_worker_keda_max_replicas) && var.n8n_worker_keda_max_replicas >= 1
    error_message = "n8n_worker_keda_max_replicas must be a whole number of replicas, 1 or greater. KEDA rejects a ScaledObject whose maxReplicaCount is below 1, and a fractional value is not a replica count."
  }
}

variable "n8n_worker_keda_jobs_per_replica" {
  description = "Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue_depth / jobs_per_replica) replicas."
  type        = number
  default     = 5

  validation {
    condition     = var.n8n_worker_keda_jobs_per_replica == floor(var.n8n_worker_keda_jobs_per_replica) && var.n8n_worker_keda_jobs_per_replica >= 1
    error_message = "n8n_worker_keda_jobs_per_replica must be a whole number of jobs, 1 or greater. KEDA divides the queue depth by this value, so 0 is not a threshold it can act on."
  }
}
