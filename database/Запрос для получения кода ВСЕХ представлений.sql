SELECT 
    c.relname AS view_name,
    pg_get_viewdef(c.oid, true) AS view_sql
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind = 'v' AND n.nspname = 'public';