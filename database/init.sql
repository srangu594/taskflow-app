-- Runs automatically on first postgres container startup
-- Tables are created by SQLAlchemy (models.Base.metadata.create_all)
-- This file handles extensions and read-only role setup

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Read-only role for monitoring / reporting tools
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'readonly') THEN
    CREATE ROLE readonly;
  END IF;
END $$;

GRANT CONNECT ON DATABASE taskflow_db TO readonly;
GRANT USAGE   ON SCHEMA public TO readonly;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly;
