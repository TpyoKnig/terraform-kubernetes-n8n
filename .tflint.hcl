# tflint config for terraform-kubernetes-n8n.
#
# Lives at the module root and is shared by every lint target (the four
# examples and both submodules) through TFLINT_CONFIG_FILE in
# .github/workflows/terraform-tests.yml. One file rather than seven copies, so
# a rule enabled here cannot silently apply to the root and miss an example.
#
# Without this file tflint runs only its small built-in default set. The
# `terraform` ruleset below is where the rules that matter to a published
# module live: terraform_documented_variables and terraform_documented_outputs
# (every input and output carries a description, a Registry quality criterion),
# terraform_unused_declarations (a variable nothing reads is a promise the
# module does not keep), terraform_naming_convention, and the deprecated-syntax
# checks. None of them were running before.
#
# No provider ruleset. Unlike the major cloud providers, the kubernetes and
# helm providers have no published tflint plugin, so the rules above are the
# whole ruleset available to this module. That is a reason to run all of it,
# not a reason to skip it.

config {
  # Follow `source = "./modules/..."` and `source = "../.."` so a rule
  # violation inside a submodule surfaces when the caller is linted, instead of
  # only when the submodule is linted directly.
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
