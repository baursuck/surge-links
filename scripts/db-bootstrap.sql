-- Day-0, run once per database by an admin with the master credentials from Secrets Manager:
--   psql "host=<db_endpoint> dbname=surge_links user=dbadmin sslmode=require" -f scripts/db-bootstrap.sql
-- Creates the user the pods log in as with IAM tokens (no password).
CREATE USER app_user;
GRANT rds_iam TO app_user;
GRANT CONNECT ON DATABASE surge_links TO app_user;
-- The app owns its schema so the migration job (same user) can create and alter tables.
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION app_user;
ALTER ROLE app_user SET search_path = app;
