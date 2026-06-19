ALTER TABLE plans ADD COLUMN IF NOT EXISTS sku varchar(255) NOT NULL;
CREATE INDEX IF NOT EXISTS plans_tenant_env_sku_idx ON plans (tenant_id, environment_id, sku);
