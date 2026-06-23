ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS sku varchar(255) NOT NULL;

CREATE INDEX IF NOT EXISTS subscriptions_sku_idx ON subscriptions (sku);

CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_tenant_env_customer_sku_active_idx
    ON subscriptions (tenant_id, environment_id, customer_id, sku)
    WHERE subscription_status = 'active' AND status = 'published';
