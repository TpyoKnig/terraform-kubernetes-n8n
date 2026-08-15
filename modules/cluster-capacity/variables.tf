# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

variable "peak_cpu_request_millis" {
  description = "CPU, in millicores, that the n8n pod families request in total when every autoscaler sits at its ceiling simultaneously. Compared against the cluster's allocatable CPU to produce an advisory warning. The root module computes it from the per-pod CPU requests and the autoscaler maxima."
  type        = number
  nullable    = false
}

variable "demand_breakdown" {
  description = "Human-readable breakdown of how peak_cpu_request_millis was reached, interpolated into the warning message. Passed in rather than rebuilt here so this submodule needs none of the pod-sizing inputs, only the arithmetic they produce."
  type        = string
  nullable    = false
}

variable "model_readable" {
  description = "Whether the caller could parse every CPU quantity that feeds peak_cpu_request_millis. False silences the check entirely: an unreadable quantity makes the demand figure meaningless, and a wrong capacity warning is worse than none. Mirrors local.n8n_capacity_model_readable in the root module."
  type        = bool
  nullable    = false
}

variable "docs_reference" {
  description = "Where the warning points the operator for the full sizing discussion. Kept as an input so the root module names its own docs without this submodule hardcoding a path relative to a repository it may not be vendored into."
  type        = string
  default     = "docs/operations.md → \"Sizing against cluster capacity\""
  nullable    = false
}
