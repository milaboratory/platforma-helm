# gen-imports.jq — emit Terraform `import {}` blocks that adopt existing
# resources into a split IM deployment, one block per resource *instance* in
# the exported monolith state.
#
# Config-driven import (Terraform 1.5+, which Infra Manager runs) reads each
# existing object into state on the first apply instead of creating it — so the
# split deployment is "born" managing the live resources, with no create and no
# destroy. See migration.md.
#
# Inputs (all via --argjson / --arg):
#   $keep : array of BASE addresses ("type.name") this half owns.
#   $skip : array of resource TYPES that have no importer and must be recreated
#           instead (state-only: null_resource, terraform_data). They are left
#           out here and show up as benign CREATEs in the preview.
#
# Import-ID rules are per resource type — most google resources use the state
# `.id`, but a handful need a constructed, provider-specific id. Every rule here
# was validated live against Infra Manager + TF 1.5.7 (see migration.md
# "Adoption probe"). Anything wrong is caught, non-destructively, by the preview
# gate before any apply.

# Instance address including the count/for_each index, e.g.
#   google_project_service.enabled["dns.googleapis.com"]
#   google_compute_global_address.ingress[0]
# NB: the parameter must not be named $type — that shadows jq's `type` builtin
# used just below, and the index suffix silently comes out empty.
def instance_address($rtype; $name; $inst):
  "\($rtype).\($name)" +
  ( $inst.index_key
    | if   type == "string" then "[\"\(.)\"]"
      elif type == "number" then "[\(.)]"
      else "" end );

# The provider-specific Terraform import id for one instance.
def import_id($rtype; $a):
  if   $rtype == "helm_release" then
        "\($a.namespace)/\($a.name)"
  elif $rtype == "kubectl_manifest" then
        # gavinbunney/kubectl: apiVersion//kind//name[//namespace]
        "\($a.api_version)//\($a.kind)//\($a.name)" +
        ( if ($a.namespace // "") == "" then "" else "//\($a.namespace)" end )
  elif $rtype == "random_password" then
        $a.result
  elif $rtype == "google_service_account_iam_member" then
        "\($a.service_account_id) \($a.role) \($a.member)"
  elif $rtype == "google_storage_bucket_iam_member" then
        # .bucket already carries the "b/" prefix in state.
        "\($a.bucket) \($a.role) \($a.member)"
  else  $a.id
  end;

[ .resources[]
  | select(.mode == "managed")
  | . as $res
  | select( ("\($res.type).\($res.name)") as $base | ($keep | index($base)) )
  | select( $skip | index($res.type) | not )
  | $res.type as $type
  | $res.name as $name
  | $res.instances[]
  | "import {\n  to = \(instance_address($type; $name; .))\n  id = \(import_id($type; .attributes) | @json)\n}"
]
| join("\n")
| . + "\n"
