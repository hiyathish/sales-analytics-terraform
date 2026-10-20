# Sales analytics: Terraform

Creates the Glue database, Athena workgroup, read-only group and users
for the sales analytics pipeline. Run per environment: dev, qa, prod.

Run order for each environment:
1. scripts/bootstrap.sh <env>   (once per environment)
2. scripts/init.sh <env>
3. scripts/plan.sh <env>        (review <env>.plan.txt)
4. scripts/apply.sh <env>