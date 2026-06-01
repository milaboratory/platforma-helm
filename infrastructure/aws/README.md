# Platforma on AWS EKS

Two ways to deploy Platforma on a new EKS cluster. Both create the same cluster, controllers, and Platforma release — pick the one that fits how your team works.

| Path | Use when | Guide |
|------|----------|-------|
| **CloudFormation** | You want a point-and-click, single-stack quickstart driven by CodeBuild. | [cloudformation/](cloudformation/README.md) |
| **Terraform / OpenTofu** | You manage infrastructure as code and want a deployment you can read, diff, and adapt. | [terraform/](terraform/README.md) |

Both are greenfield: they create and own a brand-new EKS cluster end to end. To integrate the Helm chart into a cluster you already manage, see the manual install path in [cloudformation/advanced-installation.md](cloudformation/advanced-installation.md).
