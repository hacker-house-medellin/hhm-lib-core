-- Supabase-only overlay. Apply after schema/schema.sql to the HHaus project.
-- The bucket is private; the server creates short-lived signed upload URLs.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'hhm-intake-private',
  'hhm-intake-private',
  false,
  10485760,
  ARRAY[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'image/jpeg',
    'image/png',
    'image/heic'
  ]
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- No anon/authenticated object policy is created. Uploads and signed reads are
-- mediated by the API's service role after Turnstile/auth and authorization.

