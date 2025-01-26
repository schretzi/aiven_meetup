data "aiven_organization" "self" {
  id = local.organization
}

data "aiven_billing_group" "self" {
  billing_group_id = local.billing_group_id
}
