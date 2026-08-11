# =============================================================================
# split-state.jq — partition a Terraform v4 state file by resource address
# =============================================================================
# Input : the monolith state, as exported by
#           gcloud infra-manager deployments export-statefile
# Args  : --argjson keep '["<type>.<name>", ...]'   base addresses to RETAIN
#         --argjson bump <int>                      amount to raise .serial by
# Output: the same state containing only the retained managed resources.
#
# WHY jq AND NOT `terraform state rm`
# -----------------------------------
# This is a pure partition: no address is rewritten, nothing is renamed, every
# resource lands in exactly one output. That makes the transformation simple
# enough to be auditable by reading it, and it avoids needing an initialised
# working directory (and therefore a full provider download) just to slice a
# JSON file. migration.sh diffs the address lists before and after as an
# independent check that the partition did what it claims.
#
# WHAT GETS DROPPED, AND WHY IT IS SAFE
# -------------------------------------
# * mode == "data" — data sources are re-read on every plan and are never
#   authoritative in state. Both new root modules declare their own; carrying
#   the monolith's over would be noise at best and a stale read at worst.
#
# * outputs — each new root module has its own outputs.tf. Stale outputs from
#   the monolith would linger until the first apply and could be read by an
#   operator as current. Cleared.
#
# * check_results — plan-time artefacts of the previous run; meaningless in a
#   state that is about to be planned by a different configuration.
#
# * cross-state dependency edges — an instance's "dependencies" list may name
#   resources that landed in the OTHER half of the split (e.g. the platforma
#   half's helm_release depending on the infra half's cluster). Terraform
#   recomputes dependencies on the next apply, so pruning the dangling edges
#   here is both safe and tidier than leaving references to addresses that no
#   longer exist in this state.
#
# The `.serial` bump exists because the target deployment already holds a
# state (the seed's empty one). Raising the serial well above it prevents any
# chance of the import being treated as stale.
# =============================================================================

# Base address of a resource block, index-free: "google_storage_bucket.primary".
def addr: "\(.type).\(.name)";

# Strip a `["key"]` or `[0]` index off a dependency reference so it can be
# compared against the index-free keep list.
def base: split("[")[0];

  .resources = [
    .resources[]
    | select(.mode == "managed")
    | select(addr as $a | $keep | index($a))
    | .instances = [
        .instances[]
        | if has("dependencies")
          then .dependencies = [ .dependencies[] | select(base as $d | $keep | index($d)) ]
          else .
          end
      ]
  ]
| .outputs       = {}
| .check_results = null
| .serial        = (.serial + $bump)
