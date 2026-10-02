CREATE TABLE IF NOT EXISTS audit_log (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  source_ip TEXT,
  rule_description TEXT,
  score INTEGER,
  severity TEXT,
  action TEXT,
  status TEXT,
  summary TEXT
);
