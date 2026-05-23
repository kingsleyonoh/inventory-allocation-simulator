CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    legal_name TEXT NOT NULL,
    full_legal_name TEXT NOT NULL,
    display_name TEXT NOT NULL,
    address JSONB NOT NULL DEFAULT '{}',
    registration JSONB NOT NULL DEFAULT '{}',
    contact JSONB NOT NULL DEFAULT '{}',
    wordmark TEXT NULL,
    api_key_hash TEXT NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tenants_api_key_hash_idx ON tenants (api_key_hash);
CREATE INDEX IF NOT EXISTS tenants_active_created_idx ON tenants (is_active, created_at);

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    email TEXT NOT NULL,
    name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('admin', 'planner', 'viewer')),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS users_tenant_email_idx ON users (tenant_id, email);
CREATE INDEX IF NOT EXISTS users_tenant_role_idx ON users (tenant_id, role);

CREATE TABLE IF NOT EXISTS warehouses (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    region TEXT NOT NULL,
    latitude NUMERIC(9,6) NULL,
    longitude NUMERIC(9,6) NULL,
    capacity_units NUMERIC(14,2) NOT NULL,
    handling_cost_cents INTEGER NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS warehouses_tenant_code_idx ON warehouses (tenant_id, code);
CREATE INDEX IF NOT EXISTS warehouses_tenant_region_idx ON warehouses (tenant_id, region);
CREATE INDEX IF NOT EXISTS warehouses_tenant_active_idx ON warehouses (tenant_id, active);

CREATE TABLE IF NOT EXISTS skus (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    sku_code TEXT NOT NULL,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    unit_volume NUMERIC(12,4) NOT NULL DEFAULT 1,
    unit_margin_cents INTEGER NOT NULL DEFAULT 0,
    stockout_cost_cents INTEGER NOT NULL DEFAULT 0,
    holding_cost_cents INTEGER NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS skus_tenant_sku_code_idx ON skus (tenant_id, sku_code);
CREATE INDEX IF NOT EXISTS skus_tenant_category_idx ON skus (tenant_id, category);
CREATE INDEX IF NOT EXISTS skus_tenant_active_idx ON skus (tenant_id, active);

CREATE TABLE IF NOT EXISTS inventory_positions (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    sku_id UUID NOT NULL REFERENCES skus(id),
    on_hand_units NUMERIC(14,2) NOT NULL DEFAULT 0,
    reserved_units NUMERIC(14,2) NOT NULL DEFAULT 0,
    inbound_units NUMERIC(14,2) NOT NULL DEFAULT 0,
    safety_stock_units NUMERIC(14,2) NOT NULL DEFAULT 0,
    as_of TIMESTAMP NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('manual', 'csv', 'api', 'simulation')),
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS inventory_positions_tenant_warehouse_sku_idx ON inventory_positions (tenant_id, warehouse_id, sku_id);
CREATE INDEX IF NOT EXISTS inventory_positions_tenant_sku_idx ON inventory_positions (tenant_id, sku_id);
CREATE INDEX IF NOT EXISTS inventory_positions_tenant_as_of_idx ON inventory_positions (tenant_id, as_of);

CREATE TABLE IF NOT EXISTS demand_history (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    sku_id UUID NOT NULL REFERENCES skus(id),
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    demand_units NUMERIC(14,2) NOT NULL,
    lost_sales_units NUMERIC(14,2) NOT NULL DEFAULT 0,
    source TEXT NOT NULL CHECK (source IN ('csv', 'api', 'manual')),
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS demand_history_tenant_sku_warehouse_period_idx ON demand_history (tenant_id, sku_id, warehouse_id, period_start);
CREATE INDEX IF NOT EXISTS demand_history_tenant_period_idx ON demand_history (tenant_id, period_start, period_end);

CREATE TABLE IF NOT EXISTS transfer_lanes (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    from_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    to_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    lead_time_days INTEGER NOT NULL CHECK (lead_time_days >= 0),
    cost_per_unit_cents INTEGER NOT NULL DEFAULT 0,
    capacity_units_day NUMERIC(14,2) NULL,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS transfer_lanes_tenant_from_to_idx ON transfer_lanes (tenant_id, from_warehouse_id, to_warehouse_id);
CREATE INDEX IF NOT EXISTS transfer_lanes_tenant_active_idx ON transfer_lanes (tenant_id, active);
